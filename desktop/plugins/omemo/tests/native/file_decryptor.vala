/**
 * Security audit tests for OMEMO file decryptor helper functions.
 *
 * Tests the pure functions: is_hex, hex_to_bin, normalize_base64,
 * aesgcm_to_https_link, and the URL→key extraction pipeline.
 *
 * These functions were originally private. Changed to internal static
 * for testability (Bug #15: normalize_base64 rem==1 silently passes).
 */

using Crypto;
using Dino.Plugins.Omemo;
using Dino.Entities;
using Xmpp;

namespace Omemo.Test {

class FileDecryptorTest : Gee.TestCase {

    public FileDecryptorTest() {
        base("FileDecryptor");

        /* is_hex */
        add_test("RFC_is_hex_valid_lowercase", test_is_hex_valid_lowercase);
        add_test("RFC_is_hex_valid_uppercase", test_is_hex_valid_uppercase);
        add_test("RFC_is_hex_valid_mixed", test_is_hex_valid_mixed);
        add_test("RFC_is_hex_empty_is_false", test_is_hex_empty_is_false);
        add_test("RFC_is_hex_non_hex_char_false", test_is_hex_non_hex_char_false);
        add_test("RFC_is_hex_space_is_false", test_is_hex_space_is_false);
        add_test("RFC_is_hex_url_safe_base64_is_false", test_is_hex_url_safe_base64);

        /* hex_to_bin */
        add_test("RFC_hex_to_bin_known_vector", test_hex_to_bin_known_vector);
        add_test("RFC_hex_to_bin_empty", test_hex_to_bin_empty);
        add_test("RFC_hex_to_bin_all_ff", test_hex_to_bin_all_ff);
        add_test("RFC_hex_to_bin_all_00", test_hex_to_bin_all_00);

        /* normalize_base64 */
        add_test("RFC4648_normalize_base64_rem_0_unchanged", test_normalize_base64_rem_0);
        add_test("RFC4648_normalize_base64_rem_2_adds_double_pad", test_normalize_base64_rem_2);
        add_test("RFC4648_normalize_base64_rem_3_adds_single_pad", test_normalize_base64_rem_3);
        add_test("RFC4648_normalize_base64_rem_1_is_invalid", test_normalize_base64_rem_1);
        add_test("RFC4648_normalize_base64_url_safe_to_standard", test_normalize_base64_url_safe);
        add_test("RFC4648_normalize_base64_empty_string", test_normalize_base64_empty);

        /* aesgcm → https */
        add_test("XEP0454_aesgcm_to_https_strips_fragment", test_aesgcm_to_https_basic);
        add_test("XEP0454_aesgcm_to_https_preserves_path", test_aesgcm_to_https_path);
        add_test("XEP0454_aesgcm_to_https_non_aesgcm_unchanged", test_aesgcm_to_https_non_aesgcm);

        /* ESFS GCM stream decrypt */
        add_test("XEP0448_esfs_gcm_stream_decrypts_authenticated_data", test_esfs_gcm_stream_decrypts_authenticated_data);
        add_test("XEP0448_esfs_gcm_stream_rejects_tampered_tag", test_esfs_gcm_stream_rejects_tampered_tag);
        add_test("XEP0448_esfs_gcm_tampered_tag_never_releases_plaintext", test_esfs_gcm_tampered_tag_never_releases_plaintext_sync);

        /* ESFS CBC stream decrypt */
        add_test("XEP0448_esfs_cbc_stream_decrypts_pkcs7_data", test_esfs_cbc_stream_decrypts_pkcs7_data);
        add_test("XEP0448_esfs_cbc_stream_decrypts_empty_plaintext", test_esfs_cbc_stream_decrypts_empty_plaintext);
        add_test("XEP0448_esfs_cbc_stream_rejects_tampered_padding", test_esfs_cbc_stream_rejects_tampered_padding);
        add_test("XEP0448_esfs_cbc_stream_rejects_unaligned_ciphertext", test_esfs_cbc_stream_rejects_unaligned_ciphertext);

        add_test("FileEncryptor_requires_http_file_sender", test_file_encryptor_requires_http_file_sender);
        add_test("FileEncryptor_preprocess_rewrites_http_url_to_aesgcm", test_file_encryptor_preprocess_rewrites_http_url_to_aesgcm);
        add_test("FileEncryptor_preprocess_rejects_non_omemo_meta", test_file_encryptor_preprocess_rejects_non_omemo_meta);
    }

    private void test_file_encryptor_requires_http_file_sender() {
        OmemoFileEncryptor encryptor = new OmemoFileEncryptor();

        fail_if_not_eq_int(encryptor.get_required_file_sender_id(), Dino.FileManager.HTTP_PROVIDER_ID,
            "OMEMO HTTP file encryption must require the HTTP Upload sender");
    }

    private void test_file_encryptor_preprocess_rewrites_http_url_to_aesgcm() {
        try {
            OmemoFileEncryptor encryptor = new OmemoFileEncryptor();
            Conversation conversation = create_test_conversation();
            FileTransfer transfer = create_test_transfer();
            var send_data = new Dino.HttpFileSendData();
            send_data.url_down = "https://upload.example.test/path/photo.jpg";
            send_data.encrypt_message = false;
            var meta = new OmemoHttpFileMeta();
            meta.iv = make_sequence(12, 17);
            meta.key = make_sequence(32, 31);

            Dino.FileSendData? result = encryptor.preprocess_send_file(conversation, transfer, send_data, meta);

            fail_if(result == null,
                "OMEMO file encryptor must accept HTTP send data with OMEMO file metadata");
            fail_if(result != send_data,
                "OMEMO file encryptor must preserve the selected HTTP send data instance");
            fail_if_not(send_data.url_down.has_prefix("aesgcm://upload.example.test/path/photo.jpg#"),
                "OMEMO file encryptor must move the transport URL into an aesgcm body URL");
            fail_if(!send_data.encrypt_message,
                "OMEMO file encryptor must force the body-url announcement through message encryption");
        } catch (GLib.Error e) {
            fail_if_reached(@"OMEMO file encryptor preprocess test failed: $(e.message)");
        }
    }

    private void test_file_encryptor_preprocess_rejects_non_omemo_meta() {
        try {
            OmemoFileEncryptor encryptor = new OmemoFileEncryptor();
            Conversation conversation = create_test_conversation();
            FileTransfer transfer = create_test_transfer();
            var send_data = new Dino.HttpFileSendData();
            send_data.url_down = "https://upload.example.test/path/photo.jpg";

            Dino.FileSendData? result = encryptor.preprocess_send_file(conversation, transfer, send_data, new Dino.FileMeta());

            fail_if(result != null,
                "OMEMO file encryptor must reject non-OMEMO metadata so keyless URLs are not announced");
        } catch (GLib.Error e) {
            fail_if_reached(@"OMEMO file encryptor preprocess negative test failed: $(e.message)");
        }
    }

    /* ===== is_hex tests ===== */

    private void test_is_hex_valid_lowercase() {
        fail_if_not(OmemoFileDecryptor.is_hex("0123456789abcdef"),
            "lowercase hex must be accepted");
    }

    private void test_is_hex_valid_uppercase() {
        fail_if_not(OmemoFileDecryptor.is_hex("AABBCCDD"),
            "uppercase hex must be accepted");
    }

    private void test_is_hex_valid_mixed() {
        fail_if_not(OmemoFileDecryptor.is_hex("aAbBcC01"),
            "mixed case hex must be accepted");
    }

    private void test_is_hex_empty_is_false() {
        fail_if(OmemoFileDecryptor.is_hex(""),
            "empty string is NOT valid hex");
    }

    private void test_is_hex_non_hex_char_false() {
        fail_if(OmemoFileDecryptor.is_hex("ZZZZ"),
            "non-hex chars must be rejected");
    }

    private void test_is_hex_space_is_false() {
        fail_if(OmemoFileDecryptor.is_hex("AA BB"),
            "spaces in hex must be rejected");
    }

    private void test_is_hex_url_safe_base64() {
        // URL-safe base64 contains chars like - and _ which are NOT hex
        fail_if(OmemoFileDecryptor.is_hex("abc-def_ghi"),
            "URL-safe base64 chars (-_) must not be accepted as hex");
    }

    /* ===== hex_to_bin tests ===== */

    private void test_hex_to_bin_known_vector() {
        uint8[] result = OmemoFileDecryptor.hex_to_bin("AABBCCDD");
        fail_if_not_eq_int(result.length, 4, "length must be 4");
        fail_if_not_eq_int(result[0], 0xAA, "byte 0 must be 0xAA");
        fail_if_not_eq_int(result[1], 0xBB, "byte 1 must be 0xBB");
        fail_if_not_eq_int(result[2], 0xCC, "byte 2 must be 0xCC");
        fail_if_not_eq_int(result[3], 0xDD, "byte 3 must be 0xDD");
    }

    private void test_hex_to_bin_empty() {
        uint8[] result = OmemoFileDecryptor.hex_to_bin("");
        fail_if_not_eq_int(result.length, 0, "empty hex must produce empty array");
    }

    private void test_hex_to_bin_all_ff() {
        uint8[] result = OmemoFileDecryptor.hex_to_bin("FFFF");
        fail_if_not_eq_int(result.length, 2, "length must be 2");
        fail_if_not_eq_int(result[0], 0xFF, "byte 0 must be 0xFF");
        fail_if_not_eq_int(result[1], 0xFF, "byte 1 must be 0xFF");
    }

    private void test_hex_to_bin_all_00() {
        uint8[] result = OmemoFileDecryptor.hex_to_bin("0000");
        fail_if_not_eq_int(result.length, 2, "length must be 2");
        fail_if_not_eq_int(result[0], 0x00, "byte 0 must be 0x00");
        fail_if_not_eq_int(result[1], 0x00, "byte 1 must be 0x00");
    }

    /* ===== normalize_base64 tests ===== */

    private void test_normalize_base64_rem_0() {
        // length=4, rem=0 → no padding needed
        string result = OmemoFileDecryptor.normalize_base64("AAAA");
        fail_if_not_eq_str(result, "AAAA",
            "RFC 4648: rem=0 must stay unchanged");
    }

    private void test_normalize_base64_rem_2() {
        // length=2, rem=2 → append "=="
        string result = OmemoFileDecryptor.normalize_base64("AA");
        fail_if_not_eq_str(result, "AA==",
            "RFC 4648: rem=2 must get == padding");
    }

    private void test_normalize_base64_rem_3() {
        // length=3, rem=3 → append "="
        string result = OmemoFileDecryptor.normalize_base64("AAA");
        fail_if_not_eq_str(result, "AAA=",
            "RFC 4648: rem=3 must get = padding");
    }

    /**
     * BUG #15 (FIXED): normalize_base64 with rem==1 now returns "".
     *
     * Base64 can NEVER have length ≡ 1 (mod 4). A valid base64 string
     * encodes 6 bits per character; groups of 4 chars = 24 bits = 3 bytes.
     * Remainder 1 means 6 bits, which is less than 1 byte — impossible.
     *
     * RFC 4648 S3.5: "Implementations MUST reject the encoded data
     * if it contains characters outside the base alphabet."
     *
     * Previously the code returned the malformed input, causing
     * Base64.decode() to produce garbage. Now returns "" so
     * try_decode_secret() fails gracefully.
     */
    private void test_normalize_base64_rem_1() {
        // length=1, rem=1 → INVALID base64 length → must return ""
        string result = OmemoFileDecryptor.normalize_base64("A");
        fail_if_not_eq_str(result, "",
            "RFC 4648: rem=1 is invalid, must return empty string");
        // Also test with length=5 (rem=1)
        string result5 = OmemoFileDecryptor.normalize_base64("ABCDE");
        fail_if_not_eq_str(result5, "",
            "RFC 4648: length 5 (rem=1) is invalid, must return empty string");
    }

    private void test_normalize_base64_url_safe() {
        // URL-safe chars: - → +, _ → /
        string result = OmemoFileDecryptor.normalize_base64("ab-_");
        fail_if_not_eq_str(result, "ab+/",
            "RFC 4648 S5: URL-safe chars must be converted to standard base64");
    }

    private void test_normalize_base64_empty() {
        string result = OmemoFileDecryptor.normalize_base64("");
        fail_if_not_eq_str(result, "",
            "empty string rem=0 must return empty");
    }

    /* ===== aesgcm_to_https_link tests ===== */

    private void test_aesgcm_to_https_basic() {
        var dec = new OmemoFileDecryptor();
        string result = dec.aesgcm_to_https_link(
            "aesgcm://example.com/file.jpg#aabbccdd");
        fail_if_not_eq_str(result, "https://example.com/file.jpg",
            "XEP-0454: aesgcm URL must become https without fragment");
    }

    private void test_aesgcm_to_https_path() {
        var dec = new OmemoFileDecryptor();
        string result = dec.aesgcm_to_https_link(
            "aesgcm://upload.example.com/path/to/file.bin#0123456789abcdef");
        fail_if_not_eq_str(result, "https://upload.example.com/path/to/file.bin",
            "XEP-0454: full path must be preserved");
    }

    private void test_aesgcm_to_https_non_aesgcm() {
        var dec = new OmemoFileDecryptor();
        string result = dec.aesgcm_to_https_link("https://example.com/file.jpg");
        // Non-aesgcm URL should be returned unchanged
        fail_if_not_eq_str(result, "https://example.com/file.jpg",
            "non-aesgcm URL must pass through unchanged");
    }

    private void test_esfs_gcm_stream_decrypts_authenticated_data() {
        try {
            uint8[] key = make_sequence(32, 3);
            uint8[] iv = make_sequence(12, 17);
            uint8[] plaintext = make_sequence(1024 * 1024 + 37, 41);
            uint8[] encrypted = encrypt_gcm_with_tag(plaintext, key, iv);

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_gcm_stream(stream, key, iv);
            uint8[] decrypted = read_all(decrypted_stream);

            fail_if_not_eq_int(decrypted.length, plaintext.length,
                "streamed ESFS GCM plaintext length must match");
            for (int i = 0; i < plaintext.length; i++) {
                if (decrypted[i] != plaintext[i]) {
                    fail_if_reached("streamed ESFS GCM plaintext differs");
                    return;
                }
            }
        } catch (GLib.Error e) {
            fail_if_reached("streamed ESFS GCM decrypt failed: %s".printf(e.message));
        }
    }

    private void test_esfs_gcm_stream_rejects_tampered_tag() {
        try {
            uint8[] key = make_sequence(32, 7);
            uint8[] iv = make_sequence(12, 23);
            uint8[] plaintext = make_sequence(4099, 71);
            uint8[] encrypted = encrypt_gcm_with_tag(plaintext, key, iv);
            encrypted[encrypted.length - 1] ^= 0x01;

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_gcm_stream(stream, key, iv);
            read_all(decrypted_stream);
            fail_if_reached("tampered ESFS GCM tag must fail");
        } catch (GLib.Error e) {
            // Expected: the converter verifies the attached GCM tag at EOF.
        }
    }

    private void test_esfs_gcm_tampered_tag_never_releases_plaintext_sync() {
        var loop = new MainLoop();
        test_esfs_gcm_tampered_tag_never_releases_plaintext.begin((obj, res) => {
            test_esfs_gcm_tampered_tag_never_releases_plaintext.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_esfs_gcm_tampered_tag_never_releases_plaintext() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-esfs-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            uint8[] key = make_sequence(32, 7);
            uint8[] iv = make_sequence(12, 23);
            uint8[] plaintext = make_sequence(4099, 71);
            uint8[] encrypted = encrypt_gcm_with_tag(plaintext, key, iv);
            encrypted[encrypted.length - 1] ^= 0x01;

            var account = new Account(new Jid("alice@example.test"), "secret");
            var conversation = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            var transfer = new FileTransfer();
            transfer.file_name = "esfs-tampered.bin";
            transfer.mime_type = "application/octet-stream";
            transfer.encryption = Encryption.OMEMO;
            transfer.size = 98765;
            string original_name = transfer.file_name;
            string? original_mime_type = transfer.mime_type;
            int64 original_size = transfer.size;

            var file_meta = new Dino.FileMeta();
            file_meta.file_name = transfer.file_name;
            file_meta.mime_type = transfer.mime_type;
            file_meta.size = encrypted.length;

            transfer.notify["phase"].connect(() => {
                fail_if(transfer.phase == FileTransfer.Phase.PREVIEWING,
                    "tampered ESFS GCM must not expose preview phase");
                fail_if(transfer.phase == FileTransfer.Phase.COMPLETE,
                    "tampered ESFS GCM must not expose complete phase");
            });

            var decryptor = new TestEsfsGcmTamperDecryptor(key, iv);
            bool rejected = false;
            try {
                yield Dino.FileManager.decrypt_and_store_received_file_for_tests(
                    new Dino.Security.FileEncryption("omemo-esfs-tamper-test"),
                    transfer,
                    conversation,
                    new MemoryInputStream.from_data(encrypted),
                    file_meta,
                    decryptor,
                    temp_dir);
                fail_if_reached("tampered ESFS GCM must fail before FileManager release");
            } catch (GLib.Error e) {
                rejected = true;
            }

            fail_if(!rejected, "tampered ESFS GCM must be rejected through the FileManager pipeline");
            fail_if_not_eq_str(transfer.file_name, original_name,
                "tampered ESFS GCM must not publish a new filename");
            fail_if_not_eq_str(transfer.mime_type, original_mime_type,
                "tampered ESFS GCM must not publish a new MIME type");
            fail_if(transfer.size != original_size,
                "tampered ESFS GCM must not publish plaintext size");
            fail_if(transfer.path != null,
                "tampered ESFS GCM must not publish a storage path");
            fail_if(transfer.phase == FileTransfer.Phase.PREVIEWING || transfer.phase == FileTransfer.Phase.COMPLETE,
                "tampered ESFS GCM must not expose preview or complete phases");
            fail_if(transfer.is_plaintext_release_allowed(),
                "tampered ESFS GCM must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0,
                "tampered ESFS GCM must clean encrypted download and pending store files");
        } catch (GLib.Error e) {
            fail_if_reached("tampered ESFS GCM FileManager integration failed: %s".printf(e.message));
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_esfs_cbc_stream_decrypts_pkcs7_data() {
        try {
            uint8[] key = make_sequence(32, 11);
            uint8[] iv = make_sequence(16, 29);
            uint8[] plaintext = make_sequence(1024 * 1024 + 31, 83);
            uint8[] encrypted = encrypt_cbc_pkcs7(plaintext, key, iv);

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_cbc_stream(stream, key, iv);
            uint8[] decrypted = read_all(decrypted_stream);

            fail_if_not_eq_int(decrypted.length, plaintext.length,
                "streamed ESFS CBC plaintext length must match");
            for (int i = 0; i < plaintext.length; i++) {
                if (decrypted[i] != plaintext[i]) {
                    fail_if_reached("streamed ESFS CBC plaintext differs");
                    return;
                }
            }
        } catch (GLib.Error e) {
            fail_if_reached("streamed ESFS CBC decrypt failed: %s".printf(e.message));
        }
    }

    private void test_esfs_cbc_stream_decrypts_empty_plaintext() {
        try {
            uint8[] key = make_sequence(32, 19);
            uint8[] iv = make_sequence(16, 41);
            uint8[] plaintext = new uint8[0];
            uint8[] encrypted = encrypt_cbc_pkcs7(plaintext, key, iv);

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_cbc_stream(stream, key, iv);
            uint8[] decrypted = read_all(decrypted_stream);

            fail_if_not_eq_int(decrypted.length, 0,
                "streamed ESFS CBC empty plaintext must decrypt to empty data");
        } catch (GLib.Error e) {
            fail_if_reached("streamed ESFS CBC empty plaintext decrypt failed: %s".printf(e.message));
        }
    }

    private void test_esfs_cbc_stream_rejects_tampered_padding() {
        try {
            uint8[] key = make_sequence(32, 13);
            uint8[] iv = make_sequence(16, 31);
            uint8[] plaintext = make_sequence(4093, 91);
            uint8[] encrypted = encrypt_cbc_pkcs7(plaintext, key, iv);
            encrypted[encrypted.length - 1] ^= 0x01;

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_cbc_stream(stream, key, iv);
            read_all(decrypted_stream);
            fail_if_reached("tampered ESFS CBC padding must fail");
        } catch (GLib.Error e) {
            // Expected: the stream validates PKCS7 padding at EOF.
        }
    }

    private void test_esfs_cbc_stream_rejects_unaligned_ciphertext() {
        try {
            uint8[] key = make_sequence(32, 17);
            uint8[] iv = make_sequence(16, 37);
            uint8[] encrypted = make_sequence(31, 97);

            InputStream stream = new MemoryInputStream.from_data(encrypted);
            InputStream decrypted_stream = OmemoFileDecryptor.decrypt_esfs_cbc_stream(stream, key, iv);
            read_all(decrypted_stream);
            fail_if_reached("unaligned ESFS CBC ciphertext must fail");
        } catch (GLib.Error e) {
            // Expected: CBC ciphertext must be block aligned.
        }
    }

    private static uint8[] make_sequence(int length, uint8 seed) {
        uint8[] data = new uint8[length];
        for (int i = 0; i < length; i++) {
            data[i] = (uint8) ((seed + (i * 31)) & 0xff);
        }
        return data;
    }

    private static Conversation create_test_conversation() throws GLib.Error {
        Account account = new Account(new Jid("alice@example.test"), "secret");
        return new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
    }

    private static FileTransfer create_test_transfer() {
        var transfer = new FileTransfer();
        transfer.encryption = Encryption.OMEMO;
        transfer.file_name = "photo.jpg";
        transfer.mime_type = "image/jpeg";
        transfer.size = 42;
        return transfer;
    }

    private static uint8[] encrypt_gcm_with_tag(uint8[] plaintext, uint8[] key, uint8[] iv) throws GLib.Error {
        SymmetricCipher cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(key);
        cipher.set_iv(iv);

        uint8[] ciphertext = new uint8[plaintext.length];
        cipher.encrypt(ciphertext, plaintext);
        uint8[] tag = cipher.get_tag(16);

        uint8[] encrypted = new uint8[ciphertext.length + tag.length];
        Memory.copy(encrypted, ciphertext, ciphertext.length);
        Memory.copy((void*) ((uint8*) encrypted + ciphertext.length), tag, tag.length);
        return encrypted;
    }

    private static uint8[] encrypt_cbc_pkcs7(uint8[] plaintext, uint8[] key, uint8[] iv) throws GLib.Error {
        uint8[] ciphertext;
        size_t ciphertext_len;
        int rc = omemo2_aes_256_cbc_pkcs7_encrypt(out ciphertext, out ciphertext_len, key, iv, plaintext);
        if (rc != 0) throw new IOError.FAILED("CBC-PKCS7 test encryption failed");
        ciphertext.length = (int) ciphertext_len;
        return ciphertext;
    }

    private static uint8[] read_all(InputStream stream) throws GLib.Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[65536];
        while (true) {
            ssize_t read = stream.read(chunk);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        stream.close();
        return data.data;
    }

    private static int count_directory_entries(string directory_path) throws GLib.Error {
        File directory = File.new_for_path(directory_path);
        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            count++;
        }
        enumerator.close();
        return count;
    }

    private static void cleanup_test_dir(string temp_dir) {
        File directory = File.new_for_path(temp_dir);
        try {
            FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = enumerator.next_file()) != null) {
                try { directory.get_child(((!) child_info).get_name()).delete(null); } catch (GLib.Error e) {}
            }
            enumerator.close();
        } catch (GLib.Error e) {}
        DirUtils.remove(temp_dir);
    }
}

private class TestEsfsGcmTamperDecryptor : Object, Dino.FileDecryptor {

    private OmemoFileDecryptor real = new OmemoFileDecryptor();
    private uint8[] key;
    private uint8[] iv;

    public TestEsfsGcmTamperDecryptor(uint8[] key, uint8[] iv) {
        this.key = key;
        this.iv = iv;
    }

    public Encryption get_encryption() {
        return Encryption.OMEMO;
    }

    public Dino.FileReceiveData prepare_get_meta_info(Conversation conversation, FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return receive_data;
    }

    public Dino.FileMeta prepare_download_file(Conversation conversation, FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Conversation conversation, FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return true;
    }

    public bool decrypts_before_return() {
        return false;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, Dino.FileReceiveData receive_data) throws Dino.FileReceiveError {
        var esfs_data = new Dino.EsfsHttpFileReceiveData();
        esfs_data.url = "https://upload.example.test/esfs-tampered.bin";
        esfs_data.esfs_key = key;
        esfs_data.esfs_iv = iv;
        esfs_data.esfs_cipher = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";

        return yield real.decrypt_file(encrypted_stream, conversation, file_transfer, esfs_data);
    }
}

}
