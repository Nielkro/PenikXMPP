using Dino;
using Dino.Entities;
using Dino.Plugins.OpenPgp;
using Xmpp;

namespace OpenPgp.Test {

class FileDecryptorTest : Gee.TestCase {

    private Conversation conversation;
    private Dino.Plugins.OpenPgp.Database? db;

    public FileDecryptorTest() {
        base("FileDecryptor");

        add_test("detects_transfer_marked_as_pgp", test_detects_transfer_marked_as_pgp);
        add_test("encryptor_uses_transfer_encryption_for_pgp_mismatch", test_encryptor_uses_transfer_encryption_for_pgp_mismatch);
        add_test("encryptor_rejects_non_pgp_transfer_after_conversation_toggle", test_encryptor_rejects_non_pgp_transfer_after_conversation_toggle);
        add_test("encryptor_rejects_groupchat_file_sends", test_encryptor_rejects_groupchat_file_sends);
        add_test("encryptor_rejects_private_muc_file_sends", test_encryptor_rejects_private_muc_file_sends);
        add_test("encryptor_directly_rejects_groupchat_file_sends", test_encryptor_directly_rejects_groupchat_file_sends_sync);
        add_test("encryptor_directly_rejects_private_muc_file_sends", test_encryptor_directly_rejects_private_muc_file_sends_sync);
        add_test("encryptor_requires_http_file_sender", test_encryptor_requires_http_file_sender);
        add_test("encryptor_preprocess_marks_http_body_message_encrypted", test_encryptor_preprocess_marks_http_body_message_encrypted);
        add_test("encryptor_preprocess_rejects_non_http_send_data", test_encryptor_preprocess_rejects_non_http_send_data);
        add_test("detects_pgp_mime_type", test_detects_pgp_mime_type);
        add_test("detects_pgp_url_suffix", test_detects_pgp_url_suffix);
        add_test("prepare_download_marks_pgp_transfer", test_prepare_download_marks_pgp_transfer);
        add_test("prepare_download_sets_transfer_protocol", test_prepare_download_sets_transfer_protocol);
        add_test("requires_trust_db_for_file_signature", test_requires_trust_db_for_file_signature);
        add_test("validates_file_signature_for_legacy_mode", test_validates_file_signature_for_legacy_mode);
        add_test("validates_file_signature_for_xmpp_mode", test_validates_file_signature_for_xmpp_mode);
        add_test("validates_file_signature_from_transfer_protocol", test_validates_file_signature_from_transfer_protocol);
        add_test("sets_verifying_phase_for_file_signature_validation", test_sets_verifying_phase_for_file_signature_validation);
        add_test("sets_verifying_phase_for_rejected_file_signature", test_sets_verifying_phase_for_rejected_file_signature);
        add_test("rejects_unsigned_file", test_rejects_unsigned_file);
        add_test("rejects_file_without_trusted_sender_key", test_rejects_file_without_trusted_sender_key);
        add_test("rejects_file_signature_from_wrong_key", test_rejects_file_signature_from_wrong_key);
        add_test("filemanager_rejects_xep0027_no_trusted_key_before_publish", test_filemanager_rejects_xep0027_no_trusted_key_before_publish_sync);
        add_test("filemanager_rejects_xep0027_wrong_signer_before_publish", test_filemanager_rejects_xep0027_wrong_signer_before_publish_sync);
        add_test("filemanager_rejects_xep0374_no_trusted_key_before_publish", test_filemanager_rejects_xep0374_no_trusted_key_before_publish_sync);
        add_test("filemanager_rejects_xep0374_wrong_signer_before_publish", test_filemanager_rejects_xep0374_wrong_signer_before_publish_sync);
        add_test("verified_plaintext_meta_does_not_mutate_transfer", test_verified_plaintext_meta_does_not_mutate_transfer);
        add_test("send_temp_stream_close_deletes_file_and_dir", test_send_temp_stream_close_deletes_file_and_dir);
        add_test("send_temp_stream_close_async_deletes_file_and_dir", test_send_temp_stream_close_async_deletes_file_and_dir);
    }

    public override void set_up() {
        try {
            Account account = new Account(new Jid("alice@example.test"), "secret");
            conversation = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            db = new Dino.Plugins.OpenPgp.Database(Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-file-test-%u.db".printf(Random.next_int())), null);
        } catch (Error e) {
            GLib.Test.message("Failed creating test conversation: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_detects_transfer_marked_as_pgp() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor();
        FileTransfer transfer = make_transfer("photo.jpg");
        transfer.encryption = Encryption.PGP;

        fail_if_not(decryptor.can_decrypt_file(conversation, transfer, new FileReceiveData()),
            "PGP encrypted file transfers must be decrypted even without .pgp filename metadata");
    }

    private void test_encryptor_uses_transfer_encryption_for_pgp_mismatch() {
        conversation.encryption = Encryption.OMEMO;
        FileTransfer transfer = make_transfer("document.pdf");
        transfer.encryption = Encryption.PGP;

        fail_if_not(PgpFileEncryptor.can_encrypt_transfer(transfer.encryption),
            "PGP file encryption must be selected from the frozen transfer encryption even if the conversation toggled to OMEMO");
    }

    private void test_encryptor_rejects_non_pgp_transfer_after_conversation_toggle() {
        conversation.encryption = Encryption.PGP;
        FileTransfer transfer = make_transfer("document.pdf");
        transfer.encryption = Encryption.OMEMO;

        fail_if(PgpFileEncryptor.can_encrypt_transfer(transfer.encryption),
            "PgpFileEncryptor must not claim OMEMO transfers even if the conversation later toggled to PGP");
    }

    private void test_encryptor_rejects_groupchat_file_sends() {
        try {
            var groupchat = new Conversation(new Jid("room@conference.example.test"), conversation.account, Conversation.Type.GROUPCHAT);
            groupchat.encryption = Encryption.PGP;
            FileTransfer transfer = make_transfer("document.pdf");
            transfer.encryption = Encryption.PGP;
            PgpFileEncryptor encryptor = new PgpFileEncryptor(null);

            fail_if(encryptor.can_encrypt_file(groupchat, transfer),
                "PgpFileEncryptor must fail closed for MUC file sends without verified private-MUC recipient readiness");
        } catch (Error e) {
            fail_if(true, @"OpenPGP groupchat file-send boundary test failed: $(e.message)");
        }
    }

    private void test_encryptor_rejects_private_muc_file_sends() {
        try {
            var private_muc = new Conversation(new Jid("room@conference.example.test/bob"), conversation.account, Conversation.Type.GROUPCHAT_PM);
            private_muc.encryption = Encryption.PGP;
            FileTransfer transfer = make_transfer("document.pdf");
            transfer.encryption = Encryption.PGP;
            PgpFileEncryptor encryptor = new PgpFileEncryptor(null);

            fail_if(encryptor.can_encrypt_file(private_muc, transfer),
                "PgpFileEncryptor must fail closed for private-MUC file sends until OpenPGP PM recipient semantics are proven");
        } catch (Error e) {
            fail_if(true, @"OpenPGP private-MUC file-send boundary test failed: $(e.message)");
        }
    }

    private void test_encryptor_directly_rejects_groupchat_file_sends_sync() {
        var loop = new MainLoop();
        test_encryptor_directly_rejects_muc_file_sends.begin(Conversation.Type.GROUPCHAT, "room@conference.example.test", (obj, res) => {
            test_encryptor_directly_rejects_muc_file_sends.end(res);
            loop.quit();
        });
        loop.run();
    }

    private void test_encryptor_directly_rejects_private_muc_file_sends_sync() {
        var loop = new MainLoop();
        test_encryptor_directly_rejects_muc_file_sends.begin(Conversation.Type.GROUPCHAT_PM, "room@conference.example.test/bob", (obj, res) => {
            test_encryptor_directly_rejects_muc_file_sends.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_encryptor_directly_rejects_muc_file_sends(Conversation.Type conversation_type, string jid) {
        try {
            var muc_conversation = new Conversation(new Jid(jid), conversation.account, conversation_type);
            muc_conversation.encryption = Encryption.PGP;
            FileTransfer transfer = make_transfer("document.pdf");
            transfer.encryption = Encryption.PGP;
            transfer.input_stream = new MemoryInputStream.from_data("must not be encrypted\n".data);
            PgpFileEncryptor encryptor = new PgpFileEncryptor(null);

            bool rejected = false;
            try {
                yield encryptor.encrypt_file(muc_conversation, transfer);
            } catch (FileSendError.ENCRYPTION_FAILED e) {
                rejected = true;
                fail_if(!e.message.contains("OpenPGP manager not available"),
                    "PgpFileEncryptor.encrypt_file must fail at the expected MUC safety boundary");
            }

            fail_if(!rejected,
                "PgpFileEncryptor.encrypt_file must fail closed for MUC semantic conversations even when called directly");
        } catch (Error e) {
            fail_if(true, @"OpenPGP direct MUC file-send rejection test failed: $(e.message)");
        }
    }

    private void test_encryptor_requires_http_file_sender() {
        PgpFileEncryptor encryptor = new PgpFileEncryptor(null);

        fail_if_not_eq_int(encryptor.get_required_file_sender_id(), Dino.FileManager.HTTP_PROVIDER_ID,
            "PGP HTTP file encryption must require the HTTP Upload sender");
    }

    private void test_encryptor_preprocess_marks_http_body_message_encrypted() {
        try {
            PgpFileEncryptor encryptor = new PgpFileEncryptor(null);
            FileTransfer transfer = make_transfer("document.pdf");
            transfer.encryption = Encryption.PGP;
            var send_data = new HttpFileSendData();
            send_data.encrypt_message = false;

            FileSendData? result = encryptor.preprocess_send_file(conversation, transfer, send_data, new FileMeta());

            fail_if(result == null, "PGP file encryptor must accept HTTP send data for body-url encryption");
            fail_if(result != send_data, "PGP file encryptor must preserve the selected HTTP send data instance");
            fail_if(!send_data.encrypt_message,
                "PGP file encryptor must force the HTTP body-url announcement through message encryption");
        } catch (Error e) {
            fail_if(true, @"PGP file encryptor preprocess test failed: $(e.message)");
        }
    }

    private void test_encryptor_preprocess_rejects_non_http_send_data() {
        try {
            PgpFileEncryptor encryptor = new PgpFileEncryptor(null);
            FileTransfer transfer = make_transfer("document.pdf");
            transfer.encryption = Encryption.PGP;

            FileSendData? result = encryptor.preprocess_send_file(conversation, transfer, new FileSendData(), new FileMeta());

            fail_if(result != null,
                "PGP file encryptor must reject non-HTTP send data so encrypted URLs are not announced through an incompatible sender");
        } catch (Error e) {
            fail_if(true, @"PGP file encryptor preprocess negative test failed: $(e.message)");
        }
    }

    private void test_detects_pgp_mime_type() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor();
        FileTransfer transfer = make_transfer("uploaded-file");
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        Intl.setlocale(LocaleCategory.CTYPE, "");
        try {
            foreach (string mime in new string[] { "application/pgp-encrypted", "APPLICATION/PGP-ENCRYPTED" }) {
                transfer.mime_type = mime;
                fail_if_not(decryptor.can_decrypt_file(conversation, transfer, new FileReceiveData()),
                    "PGP MIME type must select the decryptor independently of locale and ASCII case");
            }
        } finally {
            Intl.setlocale(LocaleCategory.CTYPE, previous);
        }
    }

    private void test_detects_pgp_url_suffix() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor();
        FileTransfer transfer = make_transfer("download");
        HttpFileReceiveData receive_data = new HttpFileReceiveData() {
            url = "https://upload.example.test/path/photo.jpg.pgp?download=1#fragment"
        };

        fail_if_not(decryptor.can_decrypt_file(conversation, transfer, receive_data),
            "PGP suffix in HTTP receive URL must select the PGP file decryptor");
    }

    private void test_prepare_download_marks_pgp_transfer() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor();
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        FileMeta meta = new FileMeta();

        decryptor.prepare_download_file(conversation, transfer, new FileReceiveData(), meta);

        fail_if_not_eq_int((int) transfer.encryption, (int) Encryption.PGP,
            "prepare_download_file must mark detected PGP transfers as PGP");
    }

    private void test_prepare_download_sets_transfer_protocol() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        FileMeta meta = new FileMeta();
        db.set_account_legacy_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

        decryptor.prepare_download_file(conversation, transfer, new FileReceiveData(), meta);

        fail_if_not_eq_int((int) transfer.encryption, (int) Encryption.PGP,
            "prepare_download_file must mark detected PGP transfers as PGP");
        fail_if_not_eq_str(transfer.encryption_protocol, Manager.FILE_PROTOCOL_XEP0027,
            "prepare_download_file must preserve the OpenPGP account mode used for file signature checks");
    }

    private void test_requires_trust_db_for_file_signature() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor();
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = true
        };

        bool rejected = false;
        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (FileReceiveError e) {
            rejected = true;
        }
        fail_if_not(rejected, "PGP file signatures must fail closed when the OpenPGP trust DB is unavailable");
    }

    private void test_validates_file_signature_for_legacy_mode() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        db.set_account_legacy_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = true
        };

        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("Expected matching legacy OpenPGP file signature to validate: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_validates_file_signature_for_xmpp_mode() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            signature_valid = true
        };

        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("Expected matching XMPP OpenPGP file signature to validate: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_validates_file_signature_from_transfer_protocol() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        transfer.encryption = Encryption.PGP;
        transfer.encryption_protocol = Manager.FILE_PROTOCOL_XEP0027;

        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);
        db.set_contact_key(conversation.account, conversation.counterpart, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = true
        };

        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("Expected stored legacy transfer protocol to select the legacy signer key despite current XMPP mode: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_sets_verifying_phase_for_file_signature_validation() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        transfer.set_transfer_phase(FileTransfer.Phase.DECRYPTING);
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = true
        };

        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (Error e) {
            GLib.Test.message("Expected matching OpenPGP file signature to validate: %s", e.message);
            GLib.Test.fail();
        }

        fail_if_not(transfer.phase == FileTransfer.Phase.VERIFYING,
            "PGP file signature validation must expose VERIFYING phase");
    }

    private void test_sets_verifying_phase_for_rejected_file_signature() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        transfer.set_transfer_phase(FileTransfer.Phase.DECRYPTING);
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            signature_valid = true
        };

        bool rejected = false;
        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (FileReceiveError e) {
            rejected = true;
        }

        fail_if_not(rejected, "PGP file signature mismatch must be rejected");
        fail_if_not(transfer.phase == FileTransfer.Phase.VERIFYING,
            "rejected PGP file signature validation must still expose VERIFYING phase");
    }

    private void test_rejects_unsigned_file() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = false
        };

        bool rejected = false;
        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (FileReceiveError e) {
            rejected = true;
        }
        fail_if_not(rejected, "PGP files without a valid signature must be rejected");
    }

    private void test_rejects_file_without_trusted_sender_key() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            signature_valid = true
        };

        bool rejected = false;
        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (FileReceiveError e) {
            rejected = true;
        }
        fail_if_not(rejected, "PGP files must be rejected when no trusted sender key exists for the selected mode");
    }

    private void test_rejects_file_signature_from_wrong_key() {
        PgpFileDecryptor decryptor = new PgpFileDecryptor(null, db);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

        var clear_data = new GPGHelper.DecryptedData() {
            data = {},
            filename = "document.pdf",
            signer_fingerprint = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            signature_valid = true
        };

        bool rejected = false;
        try {
            decryptor.validate_file_signature(conversation, transfer, clear_data);
        } catch (FileReceiveError e) {
            rejected = true;
        }
        fail_if_not(rejected, "PGP file signature from a different key must be rejected");
    }

    private void test_filemanager_rejects_xep0027_no_trusted_key_before_publish_sync() {
        var loop = new MainLoop();
        test_filemanager_rejects_xep0027_no_trusted_key_before_publish.begin((obj, res) => {
            test_filemanager_rejects_xep0027_no_trusted_key_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_filemanager_rejects_xep0027_no_trusted_key_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-filemanager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db.set_account_legacy_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

            var clear_data = new GPGHelper.DecryptedData() {
                data = "verified plaintext must not be stored\n".data,
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };
            yield assert_filemanager_rejects_pgp_signature_before_publish(
                temp_dir,
                Manager.FILE_PROTOCOL_XEP0027,
                clear_data,
                "OpenPGP XEP-0027 file without trusted sender key must fail before FileManager publish");
        } catch (Error e) {
            GLib.Test.message("OpenPGP FileManager XEP-0027 no-trusted-key integration failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_filemanager_rejects_xep0027_wrong_signer_before_publish_sync() {
        var loop = new MainLoop();
        test_filemanager_rejects_xep0027_wrong_signer_before_publish.begin((obj, res) => {
            test_filemanager_rejects_xep0027_wrong_signer_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_filemanager_rejects_xep0027_wrong_signer_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-filemanager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db.set_account_legacy_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
            db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);

            var clear_data = new GPGHelper.DecryptedData() {
                data = "verified plaintext must not be stored\n".data,
                filename = "document.pdf",
                signer_fingerprint = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                signature_valid = true
            };
            yield assert_filemanager_rejects_pgp_signature_before_publish(
                temp_dir,
                Manager.FILE_PROTOCOL_XEP0027,
                clear_data,
                "OpenPGP XEP-0027 file signed by the wrong key must fail before FileManager publish");
        } catch (Error e) {
            GLib.Test.message("OpenPGP FileManager XEP-0027 wrong-signer integration failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_filemanager_rejects_xep0374_no_trusted_key_before_publish_sync() {
        var loop = new MainLoop();
        test_filemanager_rejects_xep0374_no_trusted_key_before_publish.begin((obj, res) => {
            test_filemanager_rejects_xep0374_no_trusted_key_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_filemanager_rejects_xep0374_no_trusted_key_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-filemanager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

            var clear_data = new GPGHelper.DecryptedData() {
                data = "verified plaintext must not be stored\n".data,
                filename = "document.pdf",
                signer_fingerprint = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                signature_valid = true
            };
            yield assert_filemanager_rejects_pgp_signature_before_publish(
                temp_dir,
                Manager.FILE_PROTOCOL_XEP0374,
                clear_data,
                "OpenPGP XEP-0373/XEP-0374 file without trusted sender key must fail before FileManager publish");
        } catch (Error e) {
            GLib.Test.message("OpenPGP FileManager XEP-0373/XEP-0374 no-trusted-key integration failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    private void test_filemanager_rejects_xep0374_wrong_signer_before_publish_sync() {
        var loop = new MainLoop();
        test_filemanager_rejects_xep0374_wrong_signer_before_publish.begin((obj, res) => {
            test_filemanager_rejects_xep0374_wrong_signer_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    private async void test_filemanager_rejects_xep0374_wrong_signer_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-filemanager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db.set_account_xmpp_key(conversation.account, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
            db.set_contact_key(conversation.account, conversation.counterpart, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);

            var clear_data = new GPGHelper.DecryptedData() {
                data = "verified plaintext must not be stored\n".data,
                filename = "document.pdf",
                signer_fingerprint = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                signature_valid = true
            };
            yield assert_filemanager_rejects_pgp_signature_before_publish(
                temp_dir,
                Manager.FILE_PROTOCOL_XEP0374,
                clear_data,
                "OpenPGP XEP-0373/XEP-0374 file signed by the wrong key must fail before FileManager publish");
        } catch (Error e) {
            GLib.Test.message("OpenPGP FileManager XEP-0373/XEP-0374 wrong-signer integration failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    private async void assert_filemanager_rejects_pgp_signature_before_publish(
        string temp_dir,
        string file_protocol,
        GPGHelper.DecryptedData clear_data,
        string message) throws Error {
        string plaintext_lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        uint8[] encrypted_payload = "synthetic OpenPGP encrypted payload\n".data;
        var decryptor = new TestPgpSignatureFileDecryptor((!) db, clear_data, plaintext_lease_root);
        FileTransfer transfer = make_transfer("document.pdf.pgp");
        transfer.direction = FileTransfer.DIRECTION_RECEIVED;
        transfer.counterpart = conversation.counterpart;
        transfer.encryption = Encryption.PGP;
        transfer.encryption_protocol = file_protocol;
        transfer.mime_type = "application/pgp-encrypted";
        transfer.size = 98765;
        string original_name = transfer.file_name;
        string? original_mime_type = transfer.mime_type;
        int64 original_size = transfer.size;

        var file_meta = new FileMeta();
        file_meta.file_name = transfer.file_name;
        file_meta.mime_type = transfer.mime_type;
        file_meta.size = encrypted_payload.length;

        bool saw_verifying_phase = false;
        transfer.notify["phase"].connect(() => {
            if (transfer.phase == FileTransfer.Phase.VERIFYING) {
                saw_verifying_phase = true;
                fail_if(transfer.path != null,
                    "OpenPGP file signature verification must not publish path");
                fail_if_not_eq_str(transfer.file_name, original_name,
                    "OpenPGP file signature verification must not publish plaintext filename");
                fail_if_not_eq_str(transfer.mime_type, original_mime_type,
                    "OpenPGP file signature verification must not publish plaintext MIME type");
                fail_if(transfer.size != original_size,
                    "OpenPGP file signature verification must not publish plaintext size");
                fail_if(transfer.is_plaintext_release_allowed(),
                    "OpenPGP file signature verification must not allow plaintext release");
            }
            fail_if(transfer.phase == FileTransfer.Phase.PREVIEWING,
                "rejected OpenPGP file signature must not expose preview phase");
            fail_if(transfer.phase == FileTransfer.Phase.COMPLETE,
                "rejected OpenPGP file signature must not expose complete phase");
        });

        bool rejected = false;
        try {
            yield Dino.FileManager.decrypt_and_store_received_file_for_tests(
                new Dino.Security.FileEncryption("openpgp-filemanager-signature-test"),
                transfer,
                conversation,
                new MemoryInputStream.from_data(encrypted_payload),
                file_meta,
                decryptor,
                temp_dir);
            GLib.Test.message("%s", message);
            GLib.Test.fail();
        } catch (FileReceiveError.DECRYPTION_FAILED e) {
            rejected = true;
        }

        fail_if(!rejected, "%s".printf(message));
        fail_if(!decryptor.called, "OpenPGP FileManager signature test decryptor must be called");
        fail_if(!decryptor.saw_decrypting_phase, "OpenPGP FileManager signature test must expose DECRYPTING before verification");
        fail_if(!saw_verifying_phase, "OpenPGP FileManager signature test must expose VERIFYING before rejection");
        fail_if_not_eq_str(transfer.file_name, original_name,
            "rejected OpenPGP file signature must not change filename");
        fail_if_not_eq_str(transfer.mime_type, original_mime_type,
            "rejected OpenPGP file signature must not change MIME type");
        fail_if(transfer.size != original_size,
            "rejected OpenPGP file signature must not publish plaintext size");
        fail_if(transfer.path != null,
            "rejected OpenPGP file signature must not publish storage path");
        fail_if(transfer.phase == FileTransfer.Phase.PREVIEWING || transfer.phase == FileTransfer.Phase.COMPLETE,
            "rejected OpenPGP file signature must not expose preview or complete phases");
        fail_if(transfer.is_plaintext_release_allowed(),
            "rejected OpenPGP file signature must not allow plaintext release");
        fail_if(!directory_is_empty_or_missing(Path.build_filename(plaintext_lease_root, "pgp-receive")),
            "rejected OpenPGP file signature must not leave plaintext lease entries");
        remove_empty_plaintext_parent_dirs(temp_dir);
        fail_if(count_directory_entries(temp_dir) != 0,
            "rejected OpenPGP file signature must clean encrypted download, pending store and plaintext lease files");
    }

    private void test_verified_plaintext_meta_does_not_mutate_transfer() {
        string? temp_dir = null;
        try {
            temp_dir = DirUtils.make_tmp("dinox-pgp-meta-test-XXXXXX");
            string clear_path = Path.build_filename((!) temp_dir, "clear.txt");
            FileUtils.set_contents(clear_path, "hello\n");

            FileTransfer transfer = make_transfer("report.txt.pgp");
            transfer.mime_type = "application/pgp-encrypted";

            VerifiedPlaintextMeta meta = PgpFileDecryptor.make_verified_plaintext_meta(
                clear_path, "report.txt", transfer, new FileReceiveData());

            fail_if_not_eq_str(transfer.file_name, "report.txt.pgp",
                "Verified plaintext metadata creation must not change the transfer filename before FileManager commit");
            fail_if_not_eq_str(transfer.mime_type, "application/pgp-encrypted",
                "Verified plaintext metadata creation must not change the transfer MIME before FileManager commit");
            fail_if_not_eq_str((!) meta.file_name, "report.txt",
                "Verified plaintext filename must be carried separately");
            fail_if_not_eq_str((!) meta.mime_type, "text/plain",
                "Verified plaintext MIME must be carried separately");
        } catch (Error e) {
            GLib.Test.message("Expected verified plaintext metadata setup to succeed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (temp_dir != null) {
                FileUtils.remove(Path.build_filename((!) temp_dir, "clear.txt"));
                DirUtils.remove((!) temp_dir);
            }
        }
    }

    private void test_send_temp_stream_close_deletes_file_and_dir() {
        string? temp_dir = null;
        string? encrypted_path = null;
        InputStream? stream = null;
        try {
            stream = make_send_temp_stream("dinox-pgp-close-test-XXXXXX", out temp_dir, out encrypted_path);

            fail_if_not(FileUtils.test((!) encrypted_path, FileTest.EXISTS),
                "Send temp file must exist before closing the stream");
            fail_if_not(FileUtils.test((!) temp_dir, FileTest.IS_DIR),
                "Send temp directory must exist before closing the stream");

            ((!) stream).close();
            stream = null;

            fail_if(FileUtils.test((!) encrypted_path, FileTest.EXISTS),
                "TempFileInputStream.close() must delete the send temp file");
            fail_if(FileUtils.test((!) temp_dir, FileTest.EXISTS),
                "TempFileInputStream.close() must remove the send temp directory");
            encrypted_path = null;
            temp_dir = null;
        } catch (Error e) {
            GLib.Test.message("Expected synchronous send temp stream cleanup to succeed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            cleanup_temp_path(encrypted_path, temp_dir);
        }
    }

    private void test_send_temp_stream_close_async_deletes_file_and_dir() {
        string? temp_dir = null;
        string? encrypted_path = null;
        InputStream? stream = null;
        try {
            stream = make_send_temp_stream("dinox-pgp-close-async-test-XXXXXX", out temp_dir, out encrypted_path);

            fail_if_not(FileUtils.test((!) encrypted_path, FileTest.EXISTS),
                "Send temp file must exist before asynchronously closing the stream");
            fail_if_not(FileUtils.test((!) temp_dir, FileTest.IS_DIR),
                "Send temp directory must exist before asynchronously closing the stream");

            Error? close_error = null;
            bool close_result = false;
            MainLoop loop = new MainLoop();
            ((!) stream).close_async.begin(GLib.Priority.DEFAULT, null, (obj, res) => {
                try {
                    close_result = ((!) stream).close_async.end(res);
                } catch (Error e) {
                    close_error = e;
                }
                loop.quit();
            });
            loop.run();
            stream = null;

            if (close_error != null) {
                throw (!) close_error;
            }
            fail_if_not(close_result, "TempFileInputStream.close_async() must report successful close");
            fail_if(FileUtils.test((!) encrypted_path, FileTest.EXISTS),
                "TempFileInputStream.close_async() must delete the send temp file");
            fail_if(FileUtils.test((!) temp_dir, FileTest.EXISTS),
                "TempFileInputStream.close_async() must remove the send temp directory");
            encrypted_path = null;
            temp_dir = null;
        } catch (Error e) {
            GLib.Test.message("Expected asynchronous send temp stream cleanup to succeed: %s", e.message);
            GLib.Test.fail();
        } finally {
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            cleanup_temp_path(encrypted_path, temp_dir);
        }
    }

    private InputStream make_send_temp_stream(string tmp_template, out string temp_dir, out string encrypted_path) throws Error {
        temp_dir = DirUtils.make_tmp(tmp_template);
        encrypted_path = Path.build_filename(temp_dir, "encrypted.pgp");
        FileUtils.set_contents(encrypted_path, "encrypted payload\n");
        return new TempFileInputStream(File.new_for_path(encrypted_path), temp_dir);
    }

    private void cleanup_temp_path(string? clear_path, string? temp_dir) {
        if (clear_path != null) {
            FileUtils.remove((!) clear_path);
        }
        if (temp_dir != null) {
            DirUtils.remove((!) temp_dir);
        }
    }

    private FileTransfer make_transfer(string file_name) {
        FileTransfer transfer = new FileTransfer();
        transfer.file_name = file_name;
        transfer.encryption = Encryption.NONE;
        return transfer;
    }

    private static int count_directory_entries(string directory_path) throws Error {
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
                try { directory.get_child(((!) child_info).get_name()).delete(null); } catch (Error e) {}
            }
            enumerator.close();
        } catch (Error e) {}
        DirUtils.remove(temp_dir);
    }

    private static bool directory_is_empty_or_missing(string directory_path) throws Error {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return true;

        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child_info = enumerator.next_file();
        enumerator.close();
        return child_info == null;
    }

    private static void remove_empty_plaintext_parent_dirs(string temp_dir) {
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext", "pgp-receive"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox"));
    }
}

private class TestPgpSignatureFileDecryptor : Object, Dino.FileDecryptor {
    private PgpFileDecryptor real;
    private GPGHelper.DecryptedData clear_data;
    private string plaintext_lease_root;
    public bool called { get; private set; default = false; }
    public bool saw_decrypting_phase { get; private set; default = false; }

    public TestPgpSignatureFileDecryptor(Dino.Plugins.OpenPgp.Database db, GPGHelper.DecryptedData clear_data, string plaintext_lease_root) {
        real = new PgpFileDecryptor(null, db);
        this.clear_data = clear_data;
        this.plaintext_lease_root = plaintext_lease_root;
    }

    public Encryption get_encryption() {
        return Encryption.PGP;
    }

    public FileReceiveData prepare_get_meta_info(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        return receive_data;
    }

    public FileMeta prepare_download_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        return true;
    }

    public bool decrypts_before_return() {
        return true;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError {
        called = true;
        saw_decrypting_phase = file_transfer.phase == FileTransfer.Phase.DECRYPTING;
        Dino.PlaintextFileLeaseTarget? target = null;
        uint8[] buffer = new uint8[1];
        try {
            yield encrypted_stream.read_async(buffer, Priority.LOW, file_transfer.cancellable);
            target = Dino.FileManager.create_plaintext_file_lease_target_for_tests("pgp-receive", plaintext_lease_root);
            string? output_path = ((!) target).file.get_path();
            if (output_path == null || ((!) output_path) == "") {
                throw new IOError.FAILED("synthetic PGP plaintext lease output path missing");
            }
            FileUtils.set_data((!) output_path, clear_data.data);
            real.validate_file_signature(conversation, file_transfer, clear_data);
            InputStream stream = ((!) target).open_input_stream(null);
            target = null;
            return stream;
        } catch (FileReceiveError e) {
            if (target != null) ((!) target).discard();
            throw e;
        } catch (Error e) {
            if (target != null) ((!) target).discard();
            throw new FileReceiveError.DECRYPTION_FAILED("synthetic PGP file decryptor failed: %s".printf(e.message));
        }
    }
}

}
