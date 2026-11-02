using Dino.Entities;

using Crypto;
using Omemo;
using Xmpp;

namespace Dino.Plugins.Omemo {

public class OmemoHttpFileReceiveData : HttpFileReceiveData {
  public string original_url;
}

public class OmemoFileDecryptor : FileDecryptor, Object {

  private const uint KEY_SIZE = 32;

  // Historically Dino expected the iv+key fragment to be hex. Some clients (e.g. Conversations)
  // may use different encodings (base64 or url-safe base64). We therefore only validate the
  // scheme/fragment structure and decode the secret more flexibly.
  private Regex url_regex = /^aesgcm:\/\/([^\s#]+)#([^\s]+)$/; // vala-lint=space-before-paren

  public Encryption get_encryption () {
    return Encryption.OMEMO;
  }

  public FileReceiveData prepare_get_meta_info (Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
    // ESFS data is already ready -- URL is https://, key/iv are stored
    if ((receive_data as EsfsHttpFileReceiveData) != null) return receive_data;

    HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
    if (http_receive_data == null) {
      warning ("OMEMO: prepare_get_meta_info called with non-HTTP receive data");
      return receive_data;
    }
    if ((receive_data as OmemoHttpFileReceiveData) != null) return receive_data;

    var omemo_http_receive_data = new OmemoHttpFileReceiveData ();
    omemo_http_receive_data.url = aesgcm_to_https_link (http_receive_data.url);
    omemo_http_receive_data.original_url = http_receive_data.url;

    return omemo_http_receive_data;
  }

  public FileMeta prepare_download_file (Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
    if (file_meta.file_name != null) {
      file_meta.file_name = file_meta.file_name.split ("#")[0];
    }
    return file_meta;
  }

  public bool can_decrypt_file (Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
    // ESFS encrypted transfers (XEP-0448)
    if ((receive_data as EsfsHttpFileReceiveData) != null) return true;

    HttpFileReceiveData? http_file_receive = receive_data as HttpFileReceiveData;
    if (http_file_receive == null) return false;

    if ((receive_data as OmemoHttpFileReceiveData) != null) return true;
    return this.url_regex.match (http_file_receive.url);
  }

  public bool decrypts_before_return () {
    return false;
  }

  public async InputStream decrypt_file (InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError {
    try {
      // ESFS (XEP-0448) decryption -- key/iv from SFS metadata
      EsfsHttpFileReceiveData? esfs_data = receive_data as EsfsHttpFileReceiveData;
      if (esfs_data != null) {
        string esfs_cipher = esfs_data.esfs_cipher.down ();
        bool esfs_cbc = esfs_cipher.contains ("aes-256-cbc");
        if (esfs_cbc && !has_supported_hash (file_transfer)) {
          throw new FileReceiveError.DECRYPTION_FAILED ("OMEMO ESFS CBC file has no supported integrity hash");
        }
        if (file_transfer.encryption == Encryption.NONE) {
          file_transfer.encryption = Encryption.OMEMO;
        }
        debug ("ESFS: Decrypting file %s cipher=%s key_len=%d iv_len=%d",
               file_transfer.file_name, esfs_data.esfs_cipher,
               esfs_data.esfs_key.length, esfs_data.esfs_iv.length);
        return decrypt_esfs_stream (encrypted_stream, esfs_data);
      }

      // Legacy aesgcm:// decryption
      OmemoHttpFileReceiveData? omemo_http_receive_data = receive_data as OmemoHttpFileReceiveData;
      if (omemo_http_receive_data == null) {
          throw new FileReceiveError.DECRYPTION_FAILED ("Missing OMEMO receive data");
      }

      uint8[] iv;
      uint8[] key;
      if (!try_extract_iv_and_key (omemo_http_receive_data.original_url, out iv, out key)) {
        throw new FileReceiveError.DECRYPTION_FAILED ("Unsupported aesgcm:// secret encoding");
      }

      // Only set encryption if not already determined by the file provider
      // (e.g. PGP conversations also use aesgcm:// for file transport)
      if (file_transfer.encryption == Encryption.NONE) {
          file_transfer.encryption = Encryption.OMEMO;
      }
      debug ("Decrypting file %s from %s (encryption=%d)", file_transfer.file_name, file_transfer.server_file_name, (int) file_transfer.encryption);

      SymmetricCipher cipher = new SymmetricCipher ("AES-GCM");
      cipher.set_key (key);
      cipher.set_iv (iv);
      return new ConverterInputStream (encrypted_stream, new SymmetricCipherDecrypter ((owned) cipher, 16));

    } catch (GLib.Error e) {
      throw new FileReceiveError.DECRYPTION_FAILED ("OMEMO file decryption error: %s".printf (e.message));
    }
  }

  private bool try_extract_iv_and_key (string aesgcm_link, out uint8[] iv, out uint8[] key) {
    iv = new uint8[0];
    key = new uint8[0];

    MatchInfo match_info;
    if (!this.url_regex.match (aesgcm_link, 0, out match_info)) {
      return false;
    }

    string secret = match_info.fetch (2);
    uint8[] iv_and_key;
    if (!try_decode_secret (secret, out iv_and_key)) {
      return false;
    }

    // Supported layouts: iv(12)+key(32)=44 bytes, iv(16)+key(32)=48 bytes.
    if (iv_and_key.length != 44 && iv_and_key.length != 48) {
      return false;
    }
    if (iv_and_key.length <= KEY_SIZE) {
      return false;
    }

    iv = iv_and_key[0:iv_and_key.length - KEY_SIZE];
    key = iv_and_key[iv_and_key.length - KEY_SIZE:iv_and_key.length];
    return true;
  }

  private bool try_decode_secret (string secret, out uint8[] bytes) {
    bytes = new uint8[0];

    // Fast path: hex (legacy)
    if (is_hex (secret) && (secret.length % 2) == 0) {
      bytes = hex_to_bin (secret.up ());
      return true;
    }

    // Fallback: base64 / url-safe base64 (common in other clients)
    string normalized = normalize_base64 (secret);
    bytes = Base64.decode (normalized);
    return bytes.length > 0;
  }

  internal static bool is_hex (string s) {
    for (int i = 0; i < s.length; i++) {
      unichar c = s.get_char (i);
      bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
      if (!ok) return false;
    }
    return s.length > 0;
  }

  internal static uint8[] hex_to_bin (string hex) {
    uint8[] bin = new uint8[hex.length / 2];
    const string HEX = "0123456789ABCDEF";
    for (int i = 0; i < hex.length / 2; i++) {
      bin[i] = (uint8) (HEX.index_of_char (hex[i * 2]) << 4) | HEX.index_of_char (hex[i * 2 + 1]);
    }
    return bin;
  }

  internal static string normalize_base64 (string input) {
    // Convert url-safe base64 to standard base64 and add padding.
    string s = input.replace ("-", "+").replace ("_", "/");
    int rem = s.length % 4;
    if (rem == 2) s += "==";
    else if (rem == 3) s += "=";
    else if (rem != 0) {
      // RFC 4648: length ≡ 1 (mod 4) is always invalid base64.
      // Return empty string so try_decode_secret() fails gracefully.
      return "";
    }
    return s;
  }

  internal string aesgcm_to_https_link (string aesgcm_link) {
    MatchInfo match_info;
    if (!this.url_regex.match (aesgcm_link, 0, out match_info)) {
      return aesgcm_link;
    }
    return "https://" + match_info.fetch (1);
  }

  /**
   * Decrypt an ESFS (XEP-0448) encrypted file stream.
   * Supports aes-256-cbc-pkcs7 (Kaidan) and aes-256-gcm-nopadding (DinoX).
   */
  private InputStream decrypt_esfs_stream (InputStream encrypted_stream, EsfsHttpFileReceiveData esfs_data) throws GLib.Error {
    uint8[] key = esfs_data.esfs_key;
    uint8[] iv = esfs_data.esfs_iv;
    string cipher_uri = esfs_data.esfs_cipher.down ();

    if (cipher_uri.contains ("aes-256-cbc-pkcs7") || cipher_uri.contains ("aes-256-cbc")) {
      // AES-256-CBC with PKCS7 padding
      // AES block size is 16 bytes, so IV must be 16 bytes
      uint8[] cbc_iv = iv;
      if (iv.length > 16) {
        cbc_iv = iv[0:16];
        debug ("ESFS: Truncating CBC IV from %d to 16 bytes", iv.length);
      }

      return decrypt_esfs_cbc_stream (encrypted_stream, key, cbc_iv);

    } else if (cipher_uri.contains ("aes-256-gcm")) {
      return decrypt_esfs_gcm_stream (encrypted_stream, key, iv);

    } else {
      throw new GLib.Error (Quark.from_string ("esfs"), 2,
          "ESFS: Unsupported or missing cipher: %s", cipher_uri);
    }
  }

  internal static InputStream decrypt_esfs_gcm_stream (InputStream encrypted_stream, uint8[] key, uint8[] iv) throws GLib.Error {
    SymmetricCipher cipher = new SymmetricCipher ("AES256-GCM");
    cipher.set_key (key);
    cipher.set_iv (iv);
    return new ConverterInputStream (encrypted_stream, new SymmetricCipherDecrypter ((owned) cipher, 16));
  }

  internal static InputStream decrypt_esfs_cbc_stream (InputStream encrypted_stream, uint8[] key, uint8[] iv) throws GLib.Error {
    return new EsfsCbcPkcs7DecryptInputStream (encrypted_stream, key, iv);
  }

  private static bool has_supported_hash (FileTransfer file_transfer) {
    return !Xmpp.Xep.CryptographicHashes.get_supported_hashes (file_transfer.hashes).is_empty;
  }
}

internal class EsfsCbcPkcs7DecryptInputStream : DinoNative.InputStream {
  private const int BLOCK_SIZE = 16;
  private const int READ_BUFFER_SIZE = 65536;

  private InputStream inner;
  private SymmetricCipher cipher;
  private uint8[] encrypted_tail = new uint8[0];
  private uint8[] pending = new uint8[0];
  private int pending_offset = 0;
  private uint8[]? held_plain_block = null;
  private bool finished = false;
  private bool closed = false;

  public EsfsCbcPkcs7DecryptInputStream (InputStream inner, uint8[] key, uint8[] iv) throws GLib.Error {
    if (key.length != 32) {
      throw new IOError.FAILED ("ESFS AES-256-CBC key must be 32 bytes");
    }
    if (iv.length != BLOCK_SIZE) {
      throw new IOError.FAILED ("ESFS AES-256-CBC IV must be 16 bytes");
    }

    this.inner = inner;
    this.cipher = new SymmetricCipher ("AES256-CBC");
    this.cipher.set_key (key);
    this.cipher.set_iv (iv);
  }

  public override ssize_t read ([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
    if (closed) throw new IOError.CLOSED ("ESFS CBC stream is closed");
    if (buffer.length == 0) return 0;

    while (pending_available () == 0 && !finished) {
      produce_more (cancellable);
    }

    int available = pending_available ();
    if (available == 0) return 0;

    int to_copy = int.min ((int) buffer.length, available);
    Memory.copy (buffer, (void*) ((uint8*) pending + pending_offset), (size_t) to_copy);
    pending_offset += to_copy;
    if (pending_offset >= pending.length) {
      pending = new uint8[0];
      pending_offset = 0;
    }
    return to_copy;
  }

  public override bool close (Cancellable? cancellable = null) throws IOError {
    if (closed) return true;
    closed = true;
    return inner.close (cancellable);
  }

  public override async bool close_async (int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
    if (closed) return true;
    closed = true;
    return yield inner.close_async (io_priority, cancellable);
  }

  private int pending_available () {
    return pending.length - pending_offset;
  }

  private void produce_more (Cancellable? cancellable) throws IOError {
    uint8[] chunk = new uint8[READ_BUFFER_SIZE];
    ssize_t read_bytes = inner.read (chunk, cancellable);
    if (read_bytes > 0) {
      process_ciphertext (chunk[0:(int) read_bytes]);
      return;
    }

    finish_stream ();
  }

  private void process_ciphertext (uint8[] bytes) throws IOError {
    int combined_len = encrypted_tail.length + bytes.length;
    uint8[] combined = new uint8[combined_len];
    if (encrypted_tail.length > 0) {
      Memory.copy (combined, encrypted_tail, encrypted_tail.length);
    }
    if (bytes.length > 0) {
      Memory.copy ((void*) ((uint8*) combined + encrypted_tail.length), bytes, bytes.length);
    }

    int process_len = combined_len - (combined_len % BLOCK_SIZE);
    if (process_len > 0) {
      uint8[] clear_blocks = new uint8[process_len];

      try {
        cipher.decrypt (clear_blocks, combined[0:process_len]);
      } catch (Crypto.Error e) {
        throw new IOError.FAILED ("ESFS AES-256-CBC decryption failed: %s".printf (e.message));
      }

      if (held_plain_block != null) {
        append_pending ((!) held_plain_block);
      }

      if (process_len > BLOCK_SIZE) {
        append_pending (clear_blocks[0:process_len - BLOCK_SIZE]);
      }
      held_plain_block = clear_blocks[process_len - BLOCK_SIZE:process_len];
    }

    encrypted_tail = combined[process_len:combined_len];
  }

  private void finish_stream () throws IOError {
    if (encrypted_tail.length != 0) {
      throw new IOError.FAILED ("ESFS AES-256-CBC ciphertext length is not block aligned");
    }
    if (held_plain_block == null) {
      throw new IOError.FAILED ("ESFS AES-256-CBC ciphertext is empty");
    }

    uint8[] final_block = (!) held_plain_block;
    int pad = final_block[BLOCK_SIZE - 1];
    bool valid = pad >= 1 && pad <= BLOCK_SIZE;
    uint8 pad_check = 0;
    if (valid) {
      for (int i = BLOCK_SIZE - pad; i < BLOCK_SIZE; i++) {
        pad_check |= (uint8) (final_block[i] ^ pad);
      }
    }
    if (!valid || pad_check != 0) {
      throw new IOError.FAILED ("ESFS AES-256-CBC-PKCS7 padding is invalid");
    }

    int clear_len = BLOCK_SIZE - pad;
    if (clear_len > 0) {
      append_pending (final_block[0:clear_len]);
    }
    held_plain_block = null;
    finished = true;
  }

  private void append_pending (uint8[] bytes) {
    if (bytes.length == 0) return;

    int available = pending_available ();
    uint8[] next = new uint8[available + bytes.length];
    if (available > 0) {
      Memory.copy (next, (void*) ((uint8*) pending + pending_offset), (size_t) available);
    }
    Memory.copy ((void*) ((uint8*) next + available), bytes, bytes.length);
    pending = next;
    pending_offset = 0;
  }
}

}
