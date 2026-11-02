using Dino;
using Dino.Entities;
using Dino.Plugins.JetOmemo;
using Gee;
using Omemo;
using Qlite;
using Xmpp;
using Xmpp.Xep;

namespace Omemo.Test {

class JetOmemoTest : Gee.TestCase {
    private const string AES_128_GCM_URI = "urn:xmpp:ciphers:aes-128-gcm-nopadding";

    public JetOmemoTest() {
        base("JetOmemo");

        add_test("XEP0391_aes128gcm_limit_stream_decrypts_authenticated_payload", test_aes128gcm_limit_stream_decrypts_authenticated_payload);
        add_test("XEP0391_aes128gcm_limit_stream_rejects_tampered_tag_before_plaintext", test_aes128gcm_limit_stream_rejects_tampered_tag_before_plaintext);
        add_test("XEP0391_aes128gcm_declared_size_stops_at_tag", test_aes128gcm_declared_size_stops_at_tag);
        add_test("XEP0391_aes128gcm_async_uses_async_input", test_aes128gcm_async_uses_async_input);
        add_test("XEP0391_aes128gcm_empty_payload_authenticates_before_eof", test_aes128gcm_empty_payload_authenticates_before_eof);
        add_test("XEP0391_aes128gcm_empty_payload_rejects_tampered_tag", test_aes128gcm_empty_payload_rejects_tampered_tag);
        add_test("XEP0391_jingle_helper_options_default_to_legacy_and_select_omemo2_for_v2_only_recipient", test_jingle_helper_options_default_to_legacy_and_select_omemo2_for_v2_only_recipient);
        add_test("XEP0391_jet_omemo_legacy_envelope_roundtrips_transport_secret", test_jet_omemo_legacy_envelope_roundtrips_transport_secret);
        add_test("XEP0391_jet_omemo2_envelope_roundtrips_transport_secret", test_jet_omemo2_envelope_roundtrips_transport_secret);
        add_test("XEP0391_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_identity", test_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_identity);
        add_test("XEP0391_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_session", test_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_session);
        add_test("XEP0391_jet_omemo_encode_failure_rejects_missing_recipient_key", test_jet_omemo_encode_failure_rejects_missing_recipient_key);
    }

    private void test_aes128gcm_limit_stream_decrypts_authenticated_payload() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] plaintext = make_sequence(4099, 71);
            uint8[] encrypted = encrypt_payload(cipher, secret, plaintext);

            fail_if_not_eq_int(plaintext.length + 16, encrypted.length,
                "JET-OMEMO AES-GCM must append the 16-byte authentication tag");
            fail_if(bytes_equal(encrypted[0:plaintext.length], plaintext),
                "JET-OMEMO AES-GCM ciphertext must differ from plaintext");

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, new MemoryInputStream.from_data(encrypted), plaintext.length);
            InputStream limited_stream = new Dino.LimitInputStream(decrypted_stream, plaintext.length);
            uint8[] decrypted = read_all(limited_stream);

            assert_bytes_equal(plaintext, decrypted,
                "JET-OMEMO AES-GCM limited receive stream must decrypt authenticated payload");
        } catch (GLib.Error e) {
            fail_if_reached("JET-OMEMO AES-GCM payload decrypt failed: %s".printf(e.message));
        }
    }

    private void test_aes128gcm_limit_stream_rejects_tampered_tag_before_plaintext() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] plaintext = make_sequence(4099, 83);
            uint8[] encrypted = encrypt_payload(cipher, secret, plaintext);
            encrypted[encrypted.length - 1] ^= 0x01;

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, new MemoryInputStream.from_data(encrypted), plaintext.length);
            InputStream limited_stream = new Dino.LimitInputStream(decrypted_stream, plaintext.length);
            uint8[] buffer = new uint8[1];
            bool rejected = false;
            try {
                ssize_t read = limited_stream.read(buffer);
                fail_if(read > 0, "tampered JET-OMEMO AES-GCM must not return plaintext bytes");
            } catch (GLib.Error e) {
                rejected = true;
            } finally {
                try {
                    limited_stream.close();
                } catch (GLib.Error e) {
                }
            }

            fail_if(!rejected,
                "tampered JET-OMEMO AES-GCM must fail before the first plaintext byte is released");
        } catch (GLib.Error e) {
            fail_if_reached("JET-OMEMO AES-GCM tamper test setup failed: %s".printf(e.message));
        }
    }

    private void test_aes128gcm_declared_size_stops_at_tag() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] plaintext = make_sequence(777, 91);
            uint8[] encrypted = encrypt_payload(cipher, secret, plaintext);
            uint8[] encrypted_with_extra = append_extra(encrypted, {0x66, 0x77, 0x88, 0x99});
            CountingMemoryInputStream encrypted_input = new CountingMemoryInputStream(encrypted_with_extra);

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, encrypted_input, plaintext.length);
            uint8[] decrypted = read_all(decrypted_stream);

            assert_bytes_equal(plaintext, decrypted,
                "JET-OMEMO AES-GCM must decrypt exactly the declared plaintext");
            fail_if(encrypted_input.bytes_read != plaintext.length + 16,
                "JET-OMEMO AES-GCM must consume exactly declared plaintext size plus tag");
        } catch (GLib.Error e) {
            fail_if_reached("JET-OMEMO AES-GCM declared-size boundary failed: %s".printf(e.message));
        }
    }

    private void test_aes128gcm_async_uses_async_input() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] plaintext = make_sequence(2049, 107);
            uint8[] encrypted = encrypt_payload(cipher, secret, plaintext);
            AsyncOnlyMemoryInputStream encrypted_input = new AsyncOnlyMemoryInputStream(encrypted);

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, encrypted_input, plaintext.length);
            Error? async_error = null;
            uint8[]? decrypted = null;
            MainLoop loop = new MainLoop();
            read_all_async.begin(decrypted_stream, (obj, res) => {
                try {
                    decrypted = read_all_async.end(res);
                } catch (Error e) {
                    async_error = e;
                }
                loop.quit();
            });
            loop.run();
            if (async_error != null) {
                throw (!) async_error;
            }

            assert_bytes_equal(plaintext, (!) decrypted,
                "JET-OMEMO AES-GCM async receive must decrypt authenticated payload");
            fail_if(encrypted_input.sync_read_called,
                "JET-OMEMO AES-GCM async receive must not call synchronous read()");
        } catch (GLib.Error e) {
            fail_if_reached("JET-OMEMO AES-GCM async receive failed: %s".printf(e.message));
        }
    }

    private void test_aes128gcm_empty_payload_authenticates_before_eof() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] plaintext = new uint8[0];
            uint8[] encrypted = encrypt_payload(cipher, secret, plaintext);
            fail_if_not_eq_int(16, encrypted.length,
                "empty JET-OMEMO AES-GCM payload must still carry an authentication tag");

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, new MemoryInputStream.from_data(encrypted), plaintext.length);
            Jingle.AuthenticatedInputStream authenticated_stream = require_authenticated_stream(decrypted_stream, plaintext.length);
            authenticated_stream.authenticate();

            uint8[] buffer = new uint8[1];
            ssize_t read = decrypted_stream.read(buffer);
            fail_if(read != 0, "authenticated empty JET-OMEMO payload must read EOF");
            decrypted_stream.close();
        } catch (GLib.Error e) {
            fail_if_reached("empty JET-OMEMO AES-GCM payload auth failed: %s".printf(e.message));
        }
    }

    private void test_aes128gcm_empty_payload_rejects_tampered_tag() {
        try {
            AesGcmCipher cipher = create_cipher();
            Jet.TransportSecret secret = create_secret();
            uint8[] encrypted = encrypt_payload(cipher, secret, new uint8[0]);
            encrypted[encrypted.length - 1] ^= 0x01;

            InputStream decrypted_stream = wrap_decrypt_stream(cipher, secret, new MemoryInputStream.from_data(encrypted), 0);
            Jingle.AuthenticatedInputStream authenticated_stream = require_authenticated_stream(decrypted_stream, 0);

            bool rejected = false;
            try {
                ((!) authenticated_stream).authenticate();
            } catch (GLib.Error e) {
                rejected = true;
            } finally {
                try {
                    decrypted_stream.close();
                } catch (GLib.Error e) {
                }
            }

            fail_if(!rejected, "tampered empty JET-OMEMO AES-GCM tag must fail authentication");
        } catch (GLib.Error e) {
            fail_if_reached("empty JET-OMEMO AES-GCM tamper setup failed: %s".printf(e.message));
        }
    }

    private void test_jingle_helper_options_default_to_legacy_and_select_omemo2_for_v2_only_recipient() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo-helper-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");
        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            dino_db = new Dino.Database(dino_db_path, "jet-omemo-helper-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(stream_interactor, (!) dino_db);
            var helper = new Dino.Plugins.JetOmemo.EncryptionHelper(stream_interactor);
            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var conversation = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            var file_transfer = new FileTransfer();

            fail_if_not_eq_str(Jet.NS_URI, helper.get_precondition_name(conversation, file_transfer),
                "JET-OMEMO helper must advertise the XEP-0391 security precondition");
            Object? options_obj = helper.get_precondition_options(conversation, file_transfer);
            fail_if(!(options_obj is Jet.Options),
                "JET-OMEMO helper must return JET precondition options");
            Jet.Options options = (Jet.Options) ((!) options_obj);
            fail_if_not_eq_str(Xmpp.Xep.Omemo.NS_URI, options.type_uri,
                "JET-OMEMO helper without trust state must request the legacy OMEMO envelope type");
            fail_if_not_eq_str(AES_128_GCM_URI, options.cipher_uri,
                "JET-OMEMO helper must request the audited AES-GCM cipher");

            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            fail_if_not_eq_str(Xmpp.Xep.Omemo.NS_URI, jet_omemo_module.get_type_uri(),
                "JET-OMEMO module remains the legacy envelope encoding");

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO helper v2 proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();
            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            int alice_identity_id = install_identity((!) omemo_db, account, alice_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);

            var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, (!) omemo_db);
            var v2_helper = new Dino.Plugins.JetOmemo.EncryptionHelper(stream_interactor, trust_manager);
            Jet.Options v2_options = (Jet.Options) ((!) v2_helper.get_precondition_options(conversation, file_transfer));
            fail_if_not_eq_str(Xmpp.Xep.Omemo.NS_URI_V2, v2_options.type_uri,
                "JET-OMEMO helper must request OMEMO2/JET for a v2-only recipient");
            fail_if_not_eq_str(AES_128_GCM_URI, v2_options.cipher_uri,
                "JET-OMEMO2 helper must keep the audited AES-GCM cipher");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO helper type proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jet_omemo_legacy_envelope_roundtrips_transport_secret() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo-envelope-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO envelope proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "jet-omemo-envelope-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var alice_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(alice_interactor, (!) dino_db);
            var bob_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_interactor, (!) dino_db);

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 53001, 54001);

            int alice_identity_id = install_identity((!) omemo_db, alice_account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);

            var alice_trust_manager = new Dino.Plugins.Omemo.TrustManager(alice_interactor, (!) omemo_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_interactor, (!) omemo_db);

            Jid alice_full_jid = new Jid("alice@example.test/dinox-a");
            Jid bob_full_jid = new Jid("bob@example.test/dinox-b");

            var alice_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            alice_stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(alice_account, alice_trust_manager, alice_store));

            var bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_interactor, bob_trust_manager, (!) omemo_db, bob_store));

            var jet_module = new Jet.Module();
            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            AesGcmCipher aes_gcm_cipher = create_cipher();
            jet_module.register_envelop_encoding(jet_omemo_module);
            jet_module.register_cipher(aes_gcm_cipher);

            Jingle.SecurityParameters? created_security = jet_module.create_security_parameters(alice_stream,
                alice_full_jid, bob_full_jid, new Jet.Options(jet_omemo_module.get_type_uri(), aes_gcm_cipher.get_cipher_uri()));
            Jet.SecurityParameters sender_params = (Jet.SecurityParameters) ((!) created_security);
            StanzaNode security_node = sender_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);

            fail_if_not_eq_str(Jet.NS_URI, security_node.ns_uri,
                "JET-OMEMO security node must use the XEP-0391 namespace");
            fail_if_not_eq_str(aes_gcm_cipher.get_cipher_uri(), security_node.get_attribute("cipher"),
                "JET-OMEMO security node must advertise the AES-GCM cipher");
            fail_if_not_eq_str(jet_omemo_module.get_type_uri(), security_node.get_attribute("type"),
                "JET-OMEMO security node must advertise the OMEMO envelope type");

            StanzaNode? encrypted_node = security_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI);
            fail_if(encrypted_node == null,
                "real JET-OMEMO envelope must contain a legacy OMEMO encrypted key node");
            if (encrypted_node == null) return;
            assert_omemo_key_recipient((!) encrypted_node, (int) bob_store.local_registration_id,
                "real JET-OMEMO envelope must target Bob's trusted OMEMO1 device");
            fail_if(((!) encrypted_node).get_subnode("payload", Xmpp.Xep.Omemo.NS_URI) != null,
                "JET-OMEMO must wrap only the transport key and not add an OMEMO message payload");
            string wire = security_node.to_string();
            fail_if(wire.contains(Base64.encode(sender_params.secret.transport_key)),
                "real JET-OMEMO envelope must not expose the transport key in cleartext");

            Store wrong_bob_store = setup_test_store_context(context);
            var wrong_bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            wrong_bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(wrong_bob_store));
            wrong_bob_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_interactor, bob_trust_manager,
                (!) omemo_db, wrong_bob_store));
            bool wrong_device_rejected = false;
            try {
                jet_module.parse_security_parameters(wrong_bob_stream, bob_full_jid, alice_full_jid, security_node);
            } catch (Jingle.IqError e) {
                wrong_device_rejected = e.message.contains("targeted device");
            }
            fail_if(!wrong_device_rejected,
                "JET-OMEMO envelope must reject a Bob stream whose active device was not targeted");

            Jingle.SecurityParameters? parsed_security = jet_module.parse_security_parameters(bob_stream,
                bob_full_jid, alice_full_jid, security_node);
            Jet.SecurityParameters receiver_params = (Jet.SecurityParameters) ((!) parsed_security);
            assert_bytes_equal(sender_params.secret.transport_key, receiver_params.secret.transport_key,
                "Bob must recover the same JET-OMEMO transport key from the real OMEMO envelope");
            assert_bytes_equal(sender_params.secret.initialization_vector, receiver_params.secret.initialization_vector,
                "Bob must recover the same JET-OMEMO initialization vector from the real OMEMO envelope");

            uint8[] plaintext = make_sequence(1537, 131);
            uint8[] encrypted_payload = encrypt_payload_with_cipher(sender_params.cipher, sender_params.secret, plaintext);
            InputStream decrypted_stream = receiver_params.cipher.wrap_input_stream(new MemoryInputStream.from_data(encrypted_payload),
                receiver_params.secret);
            require_authenticated_stream(decrypted_stream, plaintext.length);
            uint8[] decrypted_payload = read_all(decrypted_stream);
            assert_bytes_equal(plaintext, decrypted_payload,
                "receiver params parsed from the real OMEMO envelope must decrypt the JET payload");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO real legacy envelope proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jet_omemo2_envelope_roundtrips_transport_secret() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo2-envelope-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO2 envelope proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "jet-omemo2-envelope-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var alice_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(alice_interactor, (!) dino_db);
            var bob_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_interactor, (!) dino_db);

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            prepare_pre_key_session_v2(context, alice_store, bob_account.bare_jid, bob_store, 63001, 64001);

            int alice_identity_id = install_identity((!) omemo_db, alice_account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo2_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);

            var alice_trust_manager = new Dino.Plugins.Omemo.TrustManager(alice_interactor, (!) omemo_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_interactor, (!) omemo_db);

            Jid alice_full_jid = new Jid("alice@example.test/dinox-a");
            Jid bob_full_jid = new Jid("bob@example.test/dinox-b");

            var alice_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            alice_stream.add_module(new Dino.Plugins.Omemo.StreamModule2(alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.Omemo2Encrypt(alice_account, alice_trust_manager, alice_store));

            var bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule2(bob_store));
            bob_stream.add_module(new Dino.Plugins.Omemo.Omemo2Decrypt(bob_account, bob_interactor, bob_trust_manager, (!) omemo_db, bob_store));

            var jet_module = new Jet.Module();
            var omemo2_encoding = new Dino.Plugins.JetOmemo.Omemo2EnvelopeEncoding();
            AesGcmCipher aes_gcm_cipher = create_cipher();
            jet_module.register_envelop_encoding(omemo2_encoding);
            jet_module.register_cipher(aes_gcm_cipher);

            Jingle.SecurityParameters? created_security = jet_module.create_security_parameters(alice_stream,
                alice_full_jid, bob_full_jid, new Jet.Options(omemo2_encoding.get_type_uri(), aes_gcm_cipher.get_cipher_uri()));
            Jet.SecurityParameters sender_params = (Jet.SecurityParameters) ((!) created_security);
            StanzaNode security_node = sender_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);

            fail_if_not_eq_str(Jet.NS_URI, security_node.ns_uri,
                "JET-OMEMO2 security node must use the XEP-0391 namespace");
            fail_if_not_eq_str(aes_gcm_cipher.get_cipher_uri(), security_node.get_attribute("cipher"),
                "JET-OMEMO2 security node must advertise the AES-GCM cipher");
            fail_if_not_eq_str(Xmpp.Xep.Omemo.NS_URI_V2, security_node.get_attribute("type"),
                "JET-OMEMO2 security node must advertise the OMEMO2 envelope type");
            fail_if(security_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI) != null,
                "JET-OMEMO2 security node must not publish a legacy OMEMO envelope");

            StanzaNode? encrypted_node = security_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI_V2);
            fail_if(encrypted_node == null,
                "real JET-OMEMO2 envelope must contain an OMEMO2 encrypted key node");
            if (encrypted_node == null) return;
            assert_omemo2_key_recipient((!) encrypted_node, bob_account.bare_jid, (int) bob_store.local_registration_id,
                "real JET-OMEMO2 envelope must target Bob's trusted OMEMO2 device");
            fail_if(((!) encrypted_node).get_subnode("payload", Xmpp.Xep.Omemo.NS_URI_V2) != null,
                "JET-OMEMO2 must wrap only the transport secret and not add an OMEMO2 message payload");
            string wire = security_node.to_string();
            fail_if(wire.contains(Base64.encode(sender_params.secret.transport_key)),
                "real JET-OMEMO2 envelope must not expose the transport key in cleartext");
            fail_if(wire.contains(Base64.encode(sender_params.secret.initialization_vector)),
                "real JET-OMEMO2 envelope must not expose the transport IV in cleartext");

            Store wrong_bob_store = setup_test_store_context(context);
            var wrong_bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            wrong_bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule2(wrong_bob_store));
            wrong_bob_stream.add_module(new Dino.Plugins.Omemo.Omemo2Decrypt(bob_account, bob_interactor, bob_trust_manager,
                (!) omemo_db, wrong_bob_store));
            bool wrong_device_rejected = false;
            try {
                jet_module.parse_security_parameters(wrong_bob_stream, bob_full_jid, alice_full_jid, security_node);
            } catch (Jingle.IqError e) {
                wrong_device_rejected = e.message.contains("targeted device");
            }
            fail_if(!wrong_device_rejected,
                "JET-OMEMO2 envelope must reject a Bob stream whose active device was not targeted");

            Jingle.SecurityParameters? parsed_security = jet_module.parse_security_parameters(bob_stream,
                bob_full_jid, alice_full_jid, security_node);
            Jet.SecurityParameters receiver_params = (Jet.SecurityParameters) ((!) parsed_security);
            assert_bytes_equal(sender_params.secret.transport_key, receiver_params.secret.transport_key,
                "Bob must recover the same JET-OMEMO2 transport key from the real OMEMO2 envelope");
            assert_bytes_equal(sender_params.secret.initialization_vector, receiver_params.secret.initialization_vector,
                "Bob must recover the same JET-OMEMO2 initialization vector from the real OMEMO2 envelope");

            uint8[] plaintext = make_sequence(1537, 139);
            uint8[] encrypted_payload = encrypt_payload_with_cipher(sender_params.cipher, sender_params.secret, plaintext);
            InputStream decrypted_stream = receiver_params.cipher.wrap_input_stream(new MemoryInputStream.from_data(encrypted_payload),
                receiver_params.secret);
            require_authenticated_stream(decrypted_stream, plaintext.length);
            uint8[] decrypted_payload = read_all(decrypted_stream);
            assert_bytes_equal(plaintext, decrypted_payload,
                "receiver params parsed from the real OMEMO2 envelope must decrypt the JET payload");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO2 real envelope proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_identity() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo-wrong-sender-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO wrong-sender proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "jet-omemo-wrong-sender-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var alice_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(alice_interactor, (!) dino_db);
            var bob_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_interactor, (!) dino_db);

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var mallory_account = new Account(new Jid("mallory@example.test"), "secret");
            mallory_account.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store mallory_store = setup_test_store_context(context);
            mallory_store.identity_key_store.local_registration_id = alice_store.local_registration_id;

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 55001, 56001);
            prepare_pre_key_session(context, bob_store, mallory_account.bare_jid, mallory_store, 57001, 58001);

            int alice_identity_id = install_identity((!) omemo_db, alice_account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, mallory_account.bare_jid, mallory_store);

            Address mallory_address = new Address(mallory_account.bare_jid.to_string(), (int) alice_store.local_registration_id);
            fail_if(!bob_store.contains_session(mallory_address),
                "test setup must keep a separate Bob->Mallory session for the colliding sender device id");
            mallory_address.device_id = 0;

            string mallory_identity_key = Base64.encode(mallory_store.identity_key_store.identity_key_public.get_data());
            assert_omemo1_device_state((!) omemo_db, bob_identity_id, mallory_account.bare_jid,
                (int) alice_store.local_registration_id, mallory_identity_key, Dino.Plugins.Omemo.TrustLevel.TRUSTED, false,
                "test setup must store Mallory's original trusted identity");

            var alice_trust_manager = new Dino.Plugins.Omemo.TrustManager(alice_interactor, (!) omemo_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_interactor, (!) omemo_db);

            Jid alice_full_jid = new Jid("alice@example.test/dinox-a");
            Jid bob_full_jid = new Jid("bob@example.test/dinox-b");
            Jid mallory_full_jid = new Jid("mallory@example.test/dinox-m");

            var alice_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            alice_stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(alice_account, alice_trust_manager, alice_store));

            var bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_interactor, bob_trust_manager, (!) omemo_db, bob_store));

            var jet_module = new Jet.Module();
            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            AesGcmCipher aes_gcm_cipher = create_cipher();
            jet_module.register_envelop_encoding(jet_omemo_module);
            jet_module.register_cipher(aes_gcm_cipher);

            Jingle.SecurityParameters? created_security = jet_module.create_security_parameters(alice_stream,
                alice_full_jid, bob_full_jid, new Jet.Options(jet_omemo_module.get_type_uri(), aes_gcm_cipher.get_cipher_uri()));
            Jet.SecurityParameters sender_params = (Jet.SecurityParameters) ((!) created_security);
            StanzaNode security_node = sender_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);

            StanzaNode? encrypted_node = security_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI);
            fail_if(encrypted_node == null,
                "wrong-sender JET-OMEMO proof must still build a real OMEMO envelope");
            if (encrypted_node == null) return;
            assert_omemo_key_recipient((!) encrypted_node, (int) bob_store.local_registration_id,
                "wrong-sender proof must not be a wrong-recipient-rid reject");

            bool wrong_sender_rejected = false;
            try {
                jet_module.parse_security_parameters(bob_stream, bob_full_jid, mallory_full_jid, security_node);
            } catch (Jingle.IqError e) {
                wrong_sender_rejected = true;
            }
            fail_if(!wrong_sender_rejected,
                "JET-OMEMO must reject a same-rid envelope when the declared sender identity does not match");

            assert_omemo1_device_state((!) omemo_db, bob_identity_id, mallory_account.bare_jid,
                (int) alice_store.local_registration_id, mallory_identity_key, Dino.Plugins.Omemo.TrustLevel.TRUSTED, false,
                "wrong-sender JET-OMEMO reject must not rewrite Mallory's device identity");
            mallory_address = new Address(mallory_account.bare_jid.to_string(), (int) alice_store.local_registration_id);
            fail_if(!bob_store.contains_session(mallory_address),
                "wrong-sender JET-OMEMO reject must not delete Mallory's existing session");
            mallory_address.device_id = 0;

            Jingle.SecurityParameters? parsed_security = jet_module.parse_security_parameters(bob_stream,
                bob_full_jid, alice_full_jid, security_node);
            Jet.SecurityParameters receiver_params = (Jet.SecurityParameters) ((!) parsed_security);
            assert_bytes_equal(sender_params.secret.transport_key, receiver_params.secret.transport_key,
                "same envelope must still decrypt for the real Alice sender");
            assert_bytes_equal(sender_params.secret.initialization_vector, receiver_params.secret.initialization_vector,
                "same envelope must still expose the original JET initialization vector for Alice");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO wrong-sender proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jet_omemo_legacy_envelope_rejects_same_rid_wrong_sender_session() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo-wrong-session-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO wrong-session proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "jet-omemo-wrong-session-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var alice_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(alice_interactor, (!) dino_db);
            var bob_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_interactor, (!) dino_db);
            var mallory_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(mallory_interactor, (!) dino_db);

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            var mallory_account = new Account(new Jid("mallory@example.test"), "secret");
            mallory_account.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            Store mallory_store = setup_test_store_context(context);
            alice_store.identity_key_store.local_registration_id = 6101;
            bob_store.identity_key_store.local_registration_id = 6201;
            mallory_store.identity_key_store.local_registration_id = alice_store.local_registration_id;

            prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 59001, 59002);
            prepare_pre_key_session(context, mallory_store, bob_account.bare_jid, bob_store, 59003, 59004);

            int alice_identity_id = install_identity((!) omemo_db, alice_account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            int mallory_identity_id = install_identity((!) omemo_db, mallory_account, mallory_store);
            add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, mallory_identity_id, bob_account.bare_jid, bob_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);
            add_trusted_omemo1_device((!) omemo_db, bob_identity_id, mallory_account.bare_jid, mallory_store);

            var alice_trust_manager = new Dino.Plugins.Omemo.TrustManager(alice_interactor, (!) omemo_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_interactor, (!) omemo_db);
            var mallory_trust_manager = new Dino.Plugins.Omemo.TrustManager(mallory_interactor, (!) omemo_db);

            Jid alice_full_jid = new Jid("alice@example.test/dinox-a");
            Jid bob_full_jid = new Jid("bob@example.test/dinox-b");
            Jid mallory_full_jid = new Jid("mallory@example.test/dinox-m");

            var alice_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            alice_stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(alice_account, alice_interactor, alice_trust_manager, (!) omemo_db, alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(alice_account, alice_trust_manager, alice_store));

            var bob_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
            bob_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(bob_account, bob_interactor, bob_trust_manager, (!) omemo_db, bob_store));
            bob_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(bob_account, bob_trust_manager, bob_store));

            var mallory_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            mallory_stream.add_module(new Dino.Plugins.Omemo.StreamModule(mallory_store));
            mallory_stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(mallory_account, mallory_interactor, mallory_trust_manager, (!) omemo_db, mallory_store));
            mallory_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(mallory_account, mallory_trust_manager, mallory_store));

            var jet_module = new Jet.Module();
            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            AesGcmCipher aes_gcm_cipher = create_cipher();
            jet_module.register_envelop_encoding(jet_omemo_module);
            jet_module.register_cipher(aes_gcm_cipher);

            Jet.SecurityParameters alice_initial_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, alice_stream, alice_full_jid, bob_full_jid);
            StanzaNode alice_initial_node = alice_initial_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);
            jet_module.parse_security_parameters(bob_stream, bob_full_jid, alice_full_jid, alice_initial_node);
            Jet.SecurityParameters bob_to_alice_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, bob_stream, bob_full_jid, alice_full_jid);
            StanzaNode bob_to_alice_node = bob_to_alice_params.to_security_stanza_node(bob_stream, bob_full_jid, alice_full_jid);
            jet_module.parse_security_parameters(alice_stream, alice_full_jid, bob_full_jid, bob_to_alice_node);

            Jet.SecurityParameters mallory_initial_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, mallory_stream, mallory_full_jid, bob_full_jid);
            StanzaNode mallory_initial_node = mallory_initial_params.to_security_stanza_node(mallory_stream, mallory_full_jid, bob_full_jid);
            jet_module.parse_security_parameters(bob_stream, bob_full_jid, mallory_full_jid, mallory_initial_node);
            Jet.SecurityParameters bob_to_mallory_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, bob_stream, bob_full_jid, mallory_full_jid);
            StanzaNode bob_to_mallory_node = bob_to_mallory_params.to_security_stanza_node(bob_stream, bob_full_jid, mallory_full_jid);
            jet_module.parse_security_parameters(mallory_stream, mallory_full_jid, bob_full_jid, bob_to_mallory_node);

            Address mallory_address = new Address(mallory_account.bare_jid.to_string(), (int) mallory_store.local_registration_id);
            fail_if(!bob_store.contains_session(mallory_address),
                "test setup must establish a Bob receiving session for Mallory's colliding sender device id");
            mallory_address.device_id = 0;

            string mallory_identity_key = Base64.encode(mallory_store.identity_key_store.identity_key_public.get_data());
            assert_omemo1_device_state((!) omemo_db, bob_identity_id, mallory_account.bare_jid,
                (int) mallory_store.local_registration_id, mallory_identity_key, Dino.Plugins.Omemo.TrustLevel.TRUSTED, false,
                "test setup must keep Mallory's original trusted identity before the wrong-session parse");

            Jet.SecurityParameters alice_normal_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, alice_stream, alice_full_jid, bob_full_jid);
            StanzaNode alice_normal_node = alice_normal_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);
            StanzaNode? alice_encrypted_node = alice_normal_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI);
            fail_if(alice_encrypted_node == null,
                "normal-session wrong-session proof must still build a real OMEMO envelope");
            if (alice_encrypted_node == null) return;
            assert_omemo_key_recipient_prekey((!) alice_encrypted_node, (int) bob_store.local_registration_id, false,
                "Alice's second JET-OMEMO envelope must use the normal-session key path");

            bool wrong_session_rejected = false;
            try {
                jet_module.parse_security_parameters(bob_stream, bob_full_jid, mallory_full_jid, alice_normal_node);
            } catch (Jingle.IqError e) {
                wrong_session_rejected = true;
            }
            fail_if(!wrong_session_rejected,
                "JET-OMEMO must reject a same-rid normal-session envelope when the declared sender session is wrong");

            assert_omemo1_device_state((!) omemo_db, bob_identity_id, mallory_account.bare_jid,
                (int) mallory_store.local_registration_id, mallory_identity_key, Dino.Plugins.Omemo.TrustLevel.TRUSTED, false,
                "wrong-session JET-OMEMO reject must not rewrite Mallory's device identity");
            mallory_address = new Address(mallory_account.bare_jid.to_string(), (int) mallory_store.local_registration_id);
            fail_if(!bob_store.contains_session(mallory_address),
                "wrong-session JET-OMEMO reject must not delete Mallory's existing normal session");
            mallory_address.device_id = 0;

            Jet.SecurityParameters mallory_normal_params = create_jet_security_params(jet_module, jet_omemo_module,
                aes_gcm_cipher, mallory_stream, mallory_full_jid, bob_full_jid);
            StanzaNode mallory_normal_node = mallory_normal_params.to_security_stanza_node(mallory_stream, mallory_full_jid, bob_full_jid);
            Jet.SecurityParameters mallory_receiver_params = (Jet.SecurityParameters) ((!) jet_module.parse_security_parameters(bob_stream,
                bob_full_jid, mallory_full_jid, mallory_normal_node));
            assert_bytes_equal(mallory_normal_params.secret.transport_key, mallory_receiver_params.secret.transport_key,
                "Mallory's normal session must remain decryptable after the rejected wrong-session parse");
            assert_bytes_equal(mallory_normal_params.secret.initialization_vector, mallory_receiver_params.secret.initialization_vector,
                "Mallory's normal session must keep the original JET IV after the rejected wrong-session parse");

            Jet.SecurityParameters alice_receiver_params = (Jet.SecurityParameters) ((!) jet_module.parse_security_parameters(bob_stream,
                bob_full_jid, alice_full_jid, alice_normal_node));
            assert_bytes_equal(alice_normal_params.secret.transport_key, alice_receiver_params.secret.transport_key,
                "same normal-session envelope must still decrypt for the real Alice sender");
            assert_bytes_equal(alice_normal_params.secret.initialization_vector, alice_receiver_params.secret.initialization_vector,
                "same normal-session envelope must still expose the original JET IV for Alice");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO wrong-session proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private void test_jet_omemo_encode_failure_rejects_missing_recipient_key() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jet-omemo-encode-failure-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                "JET-OMEMO encode-failure proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "jet-omemo-encode-failure-proof");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var alice_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(alice_interactor, (!) dino_db);

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            var alice_trust_manager = new Dino.Plugins.Omemo.TrustManager(alice_interactor, (!) omemo_db);

            Jid alice_full_jid = new Jid("alice@example.test/dinox-a");
            Jid bob_full_jid = new Jid("bob@example.test/dinox-b");

            var alice_stream = new JetOmemoTestXmppStream(new Jid("example.test"));
            alice_stream.add_module(new Dino.Plugins.Omemo.StreamModule(alice_store));
            alice_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(alice_account, alice_trust_manager, alice_store));

            var jet_module = new Jet.Module();
            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            AesGcmCipher aes_gcm_cipher = create_cipher();
            jet_module.register_envelop_encoding(jet_omemo_module);
            jet_module.register_cipher(aes_gcm_cipher);

            Jingle.SecurityParameters? created_security = jet_module.create_security_parameters(alice_stream,
                alice_full_jid, bob_full_jid, new Jet.Options(jet_omemo_module.get_type_uri(), aes_gcm_cipher.get_cipher_uri()));
            Jet.SecurityParameters sender_params = (Jet.SecurityParameters) ((!) created_security);

            bool security_node_rejected = false;
            try {
                sender_params.to_security_stanza_node(alice_stream, alice_full_jid, bob_full_jid);
            } catch (Jingle.Error e) {
                security_node_rejected = e.message.contains("No JET-OMEMO key encrypted");
            }
            fail_if(!security_node_rejected,
                "JET-OMEMO security node creation must fail when no recipient key can be encrypted");

            StanzaNode security_node = new StanzaNode.build("security", Jet.NS_URI)
                .add_self_xmlns()
                .put_attribute("cipher", aes_gcm_cipher.get_cipher_uri())
                .put_attribute("type", jet_omemo_module.get_type_uri());
            bool direct_encode_rejected = false;
            try {
                jet_omemo_module.encode_envelop(alice_stream, alice_full_jid, bob_full_jid, sender_params, security_node);
            } catch (Jingle.Error e) {
                direct_encode_rejected = e.message.contains("No JET-OMEMO key encrypted");
            }
            fail_if(!direct_encode_rejected,
                "JET-OMEMO envelope encoding must reject missing recipient keys");
            fail_if(security_node.get_subnode("encrypted", Xmpp.Xep.Omemo.NS_URI) != null,
                "failed JET-OMEMO envelope encoding must not publish an empty OMEMO envelope");
        } catch (Error e) {
            fail_if_reached("JET-OMEMO encode-failure proof failed: %s".printf(e.message));
        } finally {
            if (omemo_db != null) ((!) omemo_db).close();
            if (dino_db != null) ((!) dino_db).close();
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private static AesGcmCipher create_cipher() {
        return new AesGcmCipher(16, 12, AES_128_GCM_URI);
    }

    private static Jet.TransportSecret create_secret() {
        return new Jet.TransportSecret(make_sequence(16, 3), make_sequence(12, 41));
    }

    private static InputStream wrap_decrypt_stream(AesGcmCipher cipher, Jet.TransportSecret secret, InputStream encrypted_input, int64 plaintext_size) {
        InputStream decrypted_stream = cipher.wrap_input_stream(encrypted_input, secret);
        require_authenticated_stream(decrypted_stream, plaintext_size);
        return decrypted_stream;
    }

    private static Jingle.AuthenticatedInputStream require_authenticated_stream(InputStream stream, int64 plaintext_size) {
        Jingle.AuthenticatedInputStream? authenticated_stream = stream as Jingle.AuthenticatedInputStream;
        fail_if(authenticated_stream == null,
            "JET-OMEMO AES-GCM input stream must expose explicit authentication");
        ((!) authenticated_stream).set_expected_plaintext_size(plaintext_size);
        return (!) authenticated_stream;
    }

    private static Jet.SecurityParameters create_jet_security_params(Jet.Module jet_module, Jet.EnvelopEncoding envelope_encoding,
            AesGcmCipher aes_gcm_cipher, XmppStream stream, Jid local_full_jid, Jid peer_full_jid) throws Error {
        Jingle.SecurityParameters? created_security = jet_module.create_security_parameters(stream,
            local_full_jid, peer_full_jid, new Jet.Options(envelope_encoding.get_type_uri(), aes_gcm_cipher.get_cipher_uri()));
        return (Jet.SecurityParameters) ((!) created_security);
    }

    private static uint8[] encrypt_payload(Jet.Cipher cipher, Jet.TransportSecret secret, uint8[] plaintext) throws GLib.Error {
        return encrypt_payload_with_cipher(cipher, secret, plaintext);
    }

    private static uint8[] encrypt_payload_with_cipher(Jet.Cipher cipher, Jet.TransportSecret secret, uint8[] plaintext) throws GLib.Error {
        var encrypted_output = new MemoryOutputStream.resizable();
        OutputStream encrypted_stream = cipher.wrap_output_stream(encrypted_output, secret);
        size_t written;
        encrypted_stream.write_all(plaintext, out written);
        fail_if(written != plaintext.length,
            "JET-OMEMO AES-GCM output stream must accept the complete plaintext");
        encrypted_stream.close();

        uint8[] encrypted = encrypted_output.steal_data();
        encrypted.length = (int) encrypted_output.get_data_size();
        return encrypted;
    }

    private static void prepare_pre_key_session(Context context, Store sender_store, Jid peer_jid, Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private, peer_signed_pre_key_pair.public.serialize());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id, (int) peer_store.local_registration_id,
            pre_key_id, peer_pre_key_pair.public, signed_pre_key_id, peer_signed_pre_key_pair.public, peer_signed_pre_key_signature, peer_identity_key_pair.public);

        Address peer_address = new Address(peer_jid.bare_jid.to_string(), (int) peer_store.local_registration_id);
        sender_store.create_session_builder(peer_address).process_pre_key_bundle(peer_pre_key);
        peer_address.device_id = 0;

        PreKeyRecord peer_pre_key_record;
        throw_by_code(PreKeyRecord.create(out peer_pre_key_record, pre_key_id, peer_pre_key_pair));
        peer_store.store_pre_key(peer_pre_key_record);

        SignedPreKeyRecord peer_signed_pre_key_record;
        throw_by_code(SignedPreKeyRecord.create(out peer_signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, peer_signed_pre_key_signature, null));
        peer_store.store_signed_pre_key(peer_signed_pre_key_record);
    }

    private static void prepare_pre_key_session_v2(Context context, Store sender_store, Jid peer_jid, Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private,
            peer_signed_pre_key_pair.public.serialize_omemo());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id, (int) peer_store.local_registration_id,
            pre_key_id, peer_pre_key_pair.public, signed_pre_key_id, peer_signed_pre_key_pair.public,
            peer_signed_pre_key_signature, peer_identity_key_pair.public);

        Address peer_address = new Address(peer_jid.bare_jid.to_string(), (int) peer_store.local_registration_id);
        SessionBuilder builder = sender_store.create_session_builder(peer_address);
        builder.version = 4;
        builder.process_pre_key_bundle(peer_pre_key);
        peer_address.device_id = 0;

        PreKeyRecord peer_pre_key_record;
        throw_by_code(PreKeyRecord.create(out peer_pre_key_record, pre_key_id, peer_pre_key_pair));
        peer_store.store_pre_key(peer_pre_key_record);

        SignedPreKeyRecord peer_signed_pre_key_record;
        throw_by_code(SignedPreKeyRecord.create(out peer_signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, new uint8[1], peer_signed_pre_key_signature));
        peer_store.store_signed_pre_key(peer_signed_pre_key_record);
    }

    private static int install_identity(Dino.Plugins.Omemo.Database db, Account account, Store store) {
        return (int) db.identity.upsert()
            .value(db.identity.account_id, account.id, true)
            .value(db.identity.device_id, (int) store.local_registration_id)
            .value(db.identity.identity_key_private_base64, Base64.encode(store.identity_key_store.identity_key_private.get_data()))
            .value(db.identity.identity_key_public_base64, Base64.encode(store.identity_key_store.identity_key_public.get_data()))
            .perform();
    }

    private static void add_trusted_omemo1_device(Dino.Plugins.Omemo.Database db, int identity_id, Jid jid, Store device_store) {
        db.identity_meta.upsert()
            .value(db.identity_meta.identity_id, identity_id, true)
            .value(db.identity_meta.address_name, jid.bare_jid.to_string(), true)
            .value(db.identity_meta.device_id, (int) device_store.local_registration_id, true)
            .value(db.identity_meta.identity_key_public_base64, Base64.encode(device_store.identity_key_store.identity_key_public.get_data()))
            .value(db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.TRUSTED)
            .value(db.identity_meta.now_active, true)
            .value(db.identity_meta.supports_omemo1, true)
            .value(db.identity_meta.supports_omemo2, false)
            .value(db.identity_meta.last_active, (long) new DateTime.now_utc().to_unix())
            .perform();
    }

    private static void add_trusted_omemo2_device(Dino.Plugins.Omemo.Database db, int identity_id, Jid jid, Store device_store) {
        db.identity_meta.upsert()
            .value(db.identity_meta.identity_id, identity_id, true)
            .value(db.identity_meta.address_name, jid.bare_jid.to_string(), true)
            .value(db.identity_meta.device_id, (int) device_store.local_registration_id, true)
            .value(db.identity_meta.identity_key_public_base64, Base64.encode(device_store.identity_key_store.identity_key_public.get_data()))
            .value(db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.TRUSTED)
            .value(db.identity_meta.now_active, true)
            .value(db.identity_meta.supports_omemo1, false)
            .value(db.identity_meta.supports_omemo2, true)
            .value(db.identity_meta.last_active, (long) new DateTime.now_utc().to_unix())
            .perform();
    }

    private static void assert_omemo_key_recipient(StanzaNode encrypted_node, int device_id, string reason) {
        assert_omemo_key_recipient_prekey(encrypted_node, device_id, null, reason);
    }

    private static void assert_omemo_key_recipient_prekey(StanzaNode encrypted_node, int device_id, bool? expected_prekey, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", Xmpp.Xep.Omemo.NS_URI);
        fail_if(header_node == null, reason + ": missing OMEMO header");
        if (header_node == null) return;

        foreach (StanzaNode key_node in ((!) header_node).get_subnodes("key", Xmpp.Xep.Omemo.NS_URI)) {
            if (key_node.get_attribute_int("rid") == device_id) {
                if (expected_prekey != null) {
                    fail_if(key_node.get_attribute_bool("prekey", false) != (!) expected_prekey, reason + ": unexpected OMEMO prekey state");
                }
                return;
            }
        }
        fail_if(true, reason);
    }

    private static void assert_omemo1_device_state(Dino.Plugins.Omemo.Database db, int identity_id, Jid jid, int device_id,
            string expected_identity_key, Dino.Plugins.Omemo.TrustLevel expected_trust, bool expected_changed, string reason) {
        Row? device = db.identity_meta.get_device(identity_id, jid.bare_jid.to_string(), device_id);
        fail_if(device == null, reason + ": missing device row");
        if (device == null) return;

        fail_if_not_eq_str(expected_identity_key, ((!) device)[db.identity_meta.identity_key_public_base64], reason + ": identity key changed");
        fail_if((Dino.Plugins.Omemo.TrustLevel) ((!) device)[db.identity_meta.trust_level] != expected_trust, reason + ": trust level changed");
        fail_if(((!) device)[db.identity_meta.identity_key_changed] != expected_changed, reason + ": identity_key_changed flag changed");
    }

    private static void assert_omemo2_key_recipient(StanzaNode encrypted_node, Jid jid, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", Xmpp.Xep.Omemo.NS_URI_V2);
        fail_if(header_node == null, reason + ": missing OMEMO2 header");
        if (header_node == null) return;

        string jid_string = jid.bare_jid.to_string();
        foreach (StanzaNode keys_node in ((!) header_node).get_subnodes("keys", Xmpp.Xep.Omemo.NS_URI_V2)) {
            if (keys_node.get_attribute("jid") != jid_string) continue;
            foreach (StanzaNode key_node in keys_node.get_subnodes("key", Xmpp.Xep.Omemo.NS_URI_V2)) {
                if (key_node.get_attribute_int("rid") == device_id) return;
            }
        }
        fail_if(true, reason);
    }

    private static void cleanup_file(string path) {
        if (FileUtils.test(path, FileTest.EXISTS)) {
            FileUtils.remove(path);
        }
    }

    private static uint8[] read_all(InputStream stream) throws GLib.Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[257];
        while (true) {
            ssize_t read = stream.read(chunk);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        stream.close();
        return data.data;
    }

    private static async uint8[] read_all_async(InputStream stream) throws GLib.Error {
        var data = new GLib.ByteArray();
        uint8[] chunk = new uint8[257];
        while (true) {
            ssize_t read = yield stream.read_async(chunk, Priority.DEFAULT, null);
            if (read <= 0) break;
            data.append(chunk[0:(int) read]);
        }
        yield stream.close_async(Priority.DEFAULT, null);
        return data.data;
    }

    private static uint8[] append_extra(uint8[] source, uint8[] extra) {
        uint8[] result = new uint8[source.length + extra.length];
        if (source.length > 0) {
            Memory.copy(result, source, source.length);
        }
        if (extra.length > 0) {
            Memory.copy(result[source.length:result.length], extra, extra.length);
        }
        return result;
    }

    private static uint8[] make_sequence(int length, uint8 seed) {
        uint8[] data = new uint8[length];
        for (int i = 0; i < length; i++) {
            data[i] = (uint8) ((seed + (i * 31)) & 0xff);
        }
        return data;
    }

    private static bool bytes_equal(uint8[] a, uint8[] b) {
        if (a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    private static void assert_bytes_equal(uint8[] expected, uint8[] actual, string reason) {
        fail_if_not_eq_int(expected.length, actual.length, reason);
        for (int i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) {
                fail_if_reached(reason);
                return;
            }
        }
    }
}

private class CountingMemoryInputStream : DinoNative.InputStream {
    private MemoryInputStream inner;
    public int64 bytes_read { get; protected set; default = 0; }

    public CountingMemoryInputStream(uint8[] data) {
        inner = new MemoryInputStream.from_data(data);
    }

    public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        ssize_t read = inner.read(buffer, cancellable);
        if (read > 0) bytes_read += read;
        return read;
    }

    public override async ssize_t read_async([CCode (type = "void*")] uint8[]? buffer, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (buffer == null) return 0;
        ssize_t read = inner.read((!) buffer, cancellable);
        if (read > 0) bytes_read += read;
        return read;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }
}

private class AsyncOnlyMemoryInputStream : CountingMemoryInputStream {
    public bool sync_read_called { get; private set; default = false; }

    public AsyncOnlyMemoryInputStream(uint8[] data) {
        base(data);
    }

    public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        sync_read_called = true;
        throw new IOError.NOT_SUPPORTED("async-only test stream does not support read()");
    }
}

private class JetOmemoTestXmppStream : XmppStream {
    public JetOmemoTestXmppStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

}
