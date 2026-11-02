using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Plugins.OpenPgp {

public class PgpFileDecryptor : FileDecryptor, Object {

    private const string PGP_MIME_TYPE = "application/pgp-encrypted";
    private const string PGP_EXTENSION_MIME_TYPE = "application/x-ext-pgp";
    private StreamInteractor? stream_interactor;
    private Database? db;

    public PgpFileDecryptor(StreamInteractor? stream_interactor = null, Database? db = null) {
        this.stream_interactor = stream_interactor;
        this.db = db;
    }

    public Encryption get_encryption() {
        return Encryption.PGP;
    }

    public FileReceiveData prepare_get_meta_info(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        ensure_transfer_protocol(conversation, file_transfer);
        return receive_data;
    }

    public FileMeta prepare_download_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
        if (file_transfer.encryption == Encryption.NONE && looks_like_pgp_file(file_transfer, receive_data, file_meta)) {
            file_transfer.encryption = Encryption.PGP;
        }
        ensure_transfer_protocol(conversation, file_transfer);
        return file_meta;
    }

    public bool can_decrypt_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        return looks_like_pgp_file(file_transfer, receive_data, null);
    }

    public bool decrypts_before_return() {
        return true;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError {
        TransferTempDirectory? encrypted_temp_dir = null;
        Dino.PlaintextFileLeaseTarget? plaintext_target = null;
        string? temp_in = null;
        string? temp_out = null;
        try {
            encrypted_temp_dir = new TransferTempDirectory("dinox-pgp-dec");
            temp_in = ((!) encrypted_temp_dir).child("input.gpg");
            plaintext_target = Dino.FileManager.create_plaintext_file_lease_target("pgp-receive", secure_delete_plaintext_file);
            File clear_temp_file = ((!) plaintext_target).file;
            temp_out = clear_temp_file.get_path();
            if (temp_out == null || ((!) temp_out) == "") {
                throw new IOError.FAILED("PGP plaintext lease output path missing");
            }

            yield copy_stream_to_private_file(encrypted_stream, (!) temp_in, file_transfer.cancellable);
            yield close_encrypted_input_stream(encrypted_stream, file_transfer.cancellable);

            GPGHelper.DecryptedFile clear_file = yield decrypt_file_to_path_async((!) temp_in, (!) temp_out);
            GPGHelper.secure_delete_file((!) temp_in);
            temp_in = null;
            ((!) encrypted_temp_dir).remove_if_empty();
            encrypted_temp_dir = null;

            validate_file_signature_values(conversation, file_transfer, clear_file.signer_fingerprint, clear_file.signature_valid);
            if (file_transfer.encryption == Encryption.NONE) {
                file_transfer.encryption = Encryption.PGP;
            }
            ensure_transfer_protocol(conversation, file_transfer);

            VerifiedPlaintextMeta plaintext_meta = make_verified_plaintext_meta(clear_file.path, clear_file.filename, file_transfer, receive_data);
            if (plaintext_meta.file_name != null && plaintext_meta.file_name != "") {
                debug("Decrypting file %s from %s", plaintext_meta.file_name, file_transfer.file_name);
            }

            InputStream clear_stream = ((!) plaintext_target).open_input_stream(plaintext_meta);
            plaintext_target = null;
            temp_out = null;
            return clear_stream;
        } catch (Error e) {
            if (temp_in != null) GPGHelper.secure_delete_file((!) temp_in);
            if (plaintext_target != null) {
                ((!) plaintext_target).discard();
            } else if (temp_out != null) {
                GPGHelper.secure_delete_file((!) temp_out);
            }
            if (encrypted_temp_dir != null) ((!) encrypted_temp_dir).remove_if_empty();
            throw new FileReceiveError.DECRYPTION_FAILED("PGP file decryption error: %s".printf(e.message));
        }
    }

    private async GPGHelper.DecryptedFile decrypt_file_to_path_async(string encrypted_path, string output_path) throws GLib.Error {
        GPGHelper.DecryptedFile? clear_file = null;
        yield Dino.FileTransferWorker.run("pgp-file-decrypt", () => {
            clear_file = GPGHelper.decrypt_file_to_path(encrypted_path, output_path);
        });

        return (!) clear_file;
    }

    private static void secure_delete_plaintext_file(File file) throws Error {
        string? path = file.get_path();
        if (path != null && path != "") {
            GPGHelper.secure_delete_file((!) path);
        }
    }

    private async void copy_stream_to_private_file(InputStream input, string output_path, Cancellable? cancellable = null) throws GLib.Error {
        File file = File.new_for_path(output_path);
        OutputStream? output = null;
        try {
            output = file.create(FileCreateFlags.PRIVATE);
            uint8[] buffer = new uint8[65536];
            while (true) {
                ssize_t read = yield input.read_async(buffer, GLib.Priority.LOW, cancellable);
                if (read <= 0) break;
                yield ((!) output).write_all_async(buffer[0:(int) read], GLib.Priority.LOW, cancellable, null);
            }
        } finally {
            if (output != null) {
                try {
                    yield ((!) output).close_async(GLib.Priority.LOW, cancellable);
                } catch (Error e) {
                    debug("PGP file decryptor: failed to close encrypted temp file: %s", e.message);
                }
            }
        }
    }

    private async void close_encrypted_input_stream(InputStream input, Cancellable? cancellable = null) {
        try {
            yield input.close_async(GLib.Priority.LOW, cancellable);
        } catch (Error e) {
            debug("PGP file decryptor: failed to close encrypted input stream: %s", e.message);
        }
    }

    internal void validate_file_signature(Conversation conversation, FileTransfer file_transfer, GPGHelper.DecryptedData clear_data) throws FileReceiveError {
        validate_file_signature_values(conversation, file_transfer, clear_data.signer_fingerprint, clear_data.signature_valid);
    }

    private void validate_file_signature_values(Conversation conversation, FileTransfer file_transfer, string? signer_fingerprint, bool signature_valid) throws FileReceiveError {
        file_transfer.set_transfer_phase(FileTransfer.Phase.VERIFYING);

        if (db == null) {
            throw new FileReceiveError.DECRYPTION_FAILED("OpenPGP trust database is not available for file signature verification");
        }

        if (!signature_valid || signer_fingerprint == null || signer_fingerprint.length == 0) {
            throw new FileReceiveError.DECRYPTION_FAILED("PGP file signature missing or invalid");
        }

        string? expected_key = get_expected_signer_key(conversation, file_transfer);
        if (expected_key == null || expected_key.length == 0) {
            throw new FileReceiveError.DECRYPTION_FAILED("No trusted OpenPGP key for file sender in the selected OpenPGP mode");
        }

        if (!openpgp_key_ids_match(expected_key, signer_fingerprint)) {
            Jid? expected_signer = get_expected_signer_jid(conversation, file_transfer);
            debug("PGP file signature mismatch: sender=%s expected=%s signer=%s",
                    expected_signer != null ? ((!) expected_signer).to_string() : "(unresolved)", expected_key, signer_fingerprint);
            throw new FileReceiveError.DECRYPTION_FAILED("PGP file signature does not match the expected sender key");
        }
    }

    private string? get_expected_signer_key(Conversation conversation, FileTransfer file_transfer) {
        Database db_ref = (!) db;
        string fallback_mode = db_ref.get_account_key_mode(conversation.account);
        string mode = Manager.file_protocol_to_key_mode(file_transfer.encryption_protocol, fallback_mode);
        if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            return db_ref.get_account_key_for_mode(conversation.account, mode);
        }

        Jid? expected_signer = get_expected_signer_jid(conversation, file_transfer);
        if (expected_signer == null) return null;
        return db_ref.get_contact_key_for_mode(conversation.account, (!) expected_signer, mode);
    }

    private void ensure_transfer_protocol(Conversation conversation, FileTransfer file_transfer) {
        if (file_transfer.encryption != Encryption.PGP) return;
        if (file_transfer.encryption_protocol != null && file_transfer.encryption_protocol != "") return;
        if (db == null) return;

        string mode = ((!) db).get_account_key_mode(conversation.account);
        file_transfer.encryption_protocol = Manager.key_mode_to_file_protocol(mode);
    }

    private Jid? get_expected_signer_jid(Conversation conversation, FileTransfer file_transfer) {
        if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            return conversation.account.bare_jid;
        }

        Jid sender = file_transfer.counterpart ?? conversation.counterpart;
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (sender.resourcepart == null || !sender.bare_jid.equals_bare(conversation.counterpart.bare_jid)) {
                return null;
            }
            if (stream_interactor == null) return null;

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) return null;

            Jid? real_jid = ((!) muc_manager).get_real_jid(sender, conversation.account);
            return real_jid != null ? ((!) real_jid).bare_jid : null;
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT &&
                sender.resourcepart != null &&
                sender.bare_jid.equals_bare(conversation.counterpart.bare_jid)) {
            if (stream_interactor == null) return null;

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) return null;

            Jid? real_jid = ((!) muc_manager).get_real_jid(sender, conversation.account);
            return real_jid != null ? ((!) real_jid).bare_jid : null;
        }

        return sender.bare_jid;
    }

    private static string? guess_decrypted_mime_type(string? file_name, uint8[] data) {
        bool data_uncertain;
        string? by_data = Dino.normalize_display_mime_type(ContentType.guess(null, data, out data_uncertain), file_name);
        if (by_data != null && by_data != "application/octet-stream" && !data_uncertain) {
            return by_data;
        }

        bool name_uncertain;
        string? by_name = Dino.normalize_display_mime_type(ContentType.guess(file_name, null, out name_uncertain), file_name);
        if (by_name != null && by_name != "application/octet-stream") {
            return by_name;
        }

        if (by_data != null && by_data != "application/octet-stream") {
            return by_data;
        }

        return null;
    }

    internal static VerifiedPlaintextMeta make_verified_plaintext_meta(string clear_path, string? plaintext_name, FileTransfer file_transfer, FileReceiveData receive_data) throws GLib.Error {
        var meta = new VerifiedPlaintextMeta();

        string? decrypted_name = get_decrypted_file_name(plaintext_name, file_transfer, receive_data);
        if (decrypted_name != null && decrypted_name != "") {
            meta.file_name = decrypted_name;
        }

        uint8[] preview_bytes = read_file_prefix(clear_path, 8192);
        string? mime_file_name = meta.file_name ?? file_transfer.file_name;
        string? guessed_type = guess_decrypted_mime_type(mime_file_name, preview_bytes);
        if (guessed_type != null && guessed_type != "application/octet-stream") {
            meta.mime_type = guessed_type;
        } else if (is_pgp_mime(file_transfer.mime_type)) {
            meta.mime_type = "application/octet-stream";
        }

        return meta;
    }

    private static uint8[] read_file_prefix(string path, size_t max_bytes) throws GLib.Error {
        File file = File.new_for_path(path);
        InputStream input = file.read();
        GLib.Error? read_error = null;
        ssize_t read = 0;
        uint8[] buffer = new uint8[max_bytes];

        try {
            read = input.read(buffer);
        } catch (GLib.Error e) {
            read_error = e;
        }

        try {
            input.close();
        } catch (GLib.Error close_error) {
            if (read_error == null) throw close_error;
        }

        if (read_error != null) throw (!) read_error;
        if (read <= 0) return new uint8[0];
        return buffer[0:(int) read];
    }

    private static bool looks_like_pgp_file(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta? file_meta) {
        if (file_transfer.encryption == Encryption.PGP) return true;
        if (has_pgp_suffix(file_transfer.file_name) || is_pgp_mime(file_transfer.mime_type)) return true;

        if (file_meta != null) {
            if (file_meta.encryption == Encryption.PGP) return true;
            if (has_pgp_suffix(file_meta.file_name) || is_pgp_mime(file_meta.mime_type)) return true;
        }

        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data != null && has_pgp_suffix(get_url_basename(http_receive_data.url))) return true;

        return false;
    }

    private static string? get_decrypted_file_name(string? plaintext_name, FileTransfer file_transfer, FileReceiveData receive_data) {
        if (plaintext_name != null && plaintext_name != "") {
            string name = Path.get_basename(plaintext_name);
            return strip_pgp_suffix(name) ?? name;
        }

        string? stripped_name = strip_pgp_suffix(file_transfer.file_name);
        if (stripped_name != null) return stripped_name;

        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data != null) {
            return strip_pgp_suffix(get_url_basename(http_receive_data.url));
        }

        return null;
    }

    private static bool is_pgp_mime(string? mime_type) {
        if (mime_type == null) return false;
        string normalized = mime_type.ascii_down().strip();
        return normalized == PGP_MIME_TYPE || normalized == PGP_EXTENSION_MIME_TYPE;
    }

    private static bool has_pgp_suffix(string? file_name) {
        if (file_name == null) return false;
        string lower_name = file_name.ascii_down();
        return lower_name.has_suffix(".pgp") || lower_name.has_suffix(".gpg");
    }

    private static string? strip_pgp_suffix(string? file_name) {
        if (file_name == null || !has_pgp_suffix(file_name)) return null;
        return file_name.substring(0, file_name.length - 4);
    }

    private static string? get_url_basename(string? url) {
        if (url == null || url == "") return null;

        string clean_url = url;
        int fragment_index = clean_url.index_of("#");
        if (fragment_index >= 0) clean_url = clean_url.substring(0, fragment_index);

        int query_index = clean_url.index_of("?");
        if (query_index >= 0) clean_url = clean_url.substring(0, query_index);

        return Path.get_basename(clean_url);
    }
}

}
