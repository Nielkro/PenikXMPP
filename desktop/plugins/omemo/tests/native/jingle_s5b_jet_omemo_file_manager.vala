using Dino;
using Dino.Entities;
using Gee;
using Omemo;
using Qlite;
using Xmpp;
using Xmpp.Xep;

namespace Omemo.Test {

class JingleS5bJetOmemoFileManagerTest : Gee.TestCase {
    private const string AES_128_GCM_URI = "urn:xmpp:ciphers:aes-128-gcm-nopadding";
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OMEMO_V2 = "urn:xmpp:omemo:2";
    private const int JINGLE_PROVIDER_ID = 1;

    private delegate bool WaitCondition();

    public JingleS5bJetOmemoFileManagerTest() {
        base("JingleS5bJetOmemoFileManager");
        add_test("OMEMO1_JET_S5B_receive_store_uses_real_envelope_and_aes_gcm",
            test_omemo1_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm_sync);
        add_test("OMEMO1_JET_S5B_tampered_tag_fails_before_store_release",
            test_omemo1_jet_s5b_tampered_tag_fails_before_store_release_sync);
        add_test("OMEMO1_send_rejects_lost_JET_capability_without_plaintext_offer",
            () => test_omemo1_send_rejects_missing_encryption_sync(false));
        add_test("OMEMO1_send_rejects_missing_helper_without_plaintext_offer",
            () => test_omemo1_send_rejects_missing_encryption_sync(true));
        add_test("OMEMO2_JET_S5B_receive_store_uses_real_envelope_and_aes_gcm",
            test_omemo2_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm_sync);
        add_test("OMEMO2_JET_S5B_receive_store_rejects_incompatible_legacy_sender_session",
            test_omemo2_jet_s5b_receive_store_rejects_incompatible_legacy_sender_session_sync);
        add_test("OMEMO2_JET_S5B_tampered_tag_fails_before_store_release",
            test_omemo2_jet_s5b_tampered_tag_fails_before_store_release_sync);
    }

    private void test_omemo1_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm_sync() {
        MainLoop loop = new MainLoop();
        test_omemo1_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm.begin((obj, res) => {
            try {
                test_omemo1_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm.end(res);
            } catch (Error e) {
                fail_if_reached(@"real OMEMO1/JET S5B FileManager receive-store proof failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_omemo1_send_rejects_missing_encryption_sync(bool remove_helper) {
        var loop = new MainLoop();
        test_omemo1_send_rejects_missing_encryption.begin(remove_helper, (obj, res) => {
            try {
                test_omemo1_send_rejects_missing_encryption.end(res);
            } catch (Error e) {
                fail_if_reached(@"OMEMO1 Jingle encryption loss regression failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void test_omemo1_send_rejects_missing_encryption(bool remove_helper) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-jingle-encryption-loss-" + Uuid.string_random());
        Dino.Database? db = null;
        var registry = Dino.JingleFileHelperRegistry.instance;
        Dino.JingleFileEncryptionHelper? previous_helper = registry.get_encryption_helper(Encryption.OMEMO);
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "jingle-encryption-loss-test");
            var interactor = new StreamInteractor.for_tests((!) db);
            PresenceManager.start(interactor);
            var account = new Account(new Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var peer = new Jid("bob@example.test/phone");
            var local_jid = new Jid("alice@example.test/dinox");
            var conversation = new Conversation(peer.bare_jid, account, Conversation.Type.CHAT);
            conversation.encryption = Encryption.OMEMO;

            var stream = new JingleS5bJetOmemoTestStream(new Jid("example.test"));
            var bind = new Bind.Flag();
            bind.my_jid = local_jid;
            stream.add_flag(bind);
            var presence = new Presence.Flag();
            var available = new Presence.Stanza();
            available.from = peer;
            available.to = local_jid;
            presence.add_presence(available);
            stream.add_flag(presence);
            var caps = new JingleEncryptionLossCapsCache();
            var discovery = new ServiceDiscovery.Module.with_identity("client", "pc", "DinoX test");
            discovery.cache = caps;
            stream.add_module(discovery);
            stream.add_module(new Jingle.Module());
            stream.add_module(new JingleFileTransfer.Module());
            stream.add_module(new Jet.Module());
            stream.add_module(new Dino.Plugins.JetOmemo.Module());
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            registry.add_encryption_helper(Encryption.OMEMO, new Dino.Plugins.JetOmemo.EncryptionHelper(interactor));
            var sender = new Dino.JingleFileSender(interactor);
            var payload = new MemoryInputStream.from_bytes(new Bytes("private test payload".data));
            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = account;
            transfer.counterpart = peer.bare_jid;
            transfer.ourpart = account.bare_jid;
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            transfer.encryption = Encryption.OMEMO;
            transfer.file_name = "private.txt";
            transfer.input_stream = payload;
            var meta = new FileMeta();
            meta.size = "private test payload".length;

            // FileManager can select the sender without an external file
            // encryptor after this succeeds. Lose encryption before send_file.
            fail_if(!(yield sender.can_encrypt(conversation, transfer)),
                "the real OMEMO helper must initially advertise encrypted transport");
            if (remove_helper) registry.encryption_helpers.unset(Encryption.OMEMO);
            else caps.has_jet = false;

            bool encryption_failed = false;
            try {
                yield sender.send_file(conversation, transfer, new FileSendData(), meta);
            } catch (FileSendError e) {
                encryption_failed = e.code == FileSendError.ENCRYPTION_FAILED;
            }
            fail_if(!encryption_failed,
                "loss of OMEMO transport support must reject the send as an encryption failure");
            foreach (StanzaNode node in stream.written_nodes) {
                fail_if(node.get_subnode("jingle", Jingle.NS_URI) != null,
                    "an OMEMO file must not emit an unencrypted Jingle offer when encryption disappears");
            }
            fail_if(((Seekable) payload).tell() != 0,
                "rejected OMEMO sends must not consume plaintext input");
            payload.close();
        } finally {
            restore_jingle_file_encryption_helper(previous_helper);
            if (db != null) ((!) db).close();
            try { delete_file_tree(File.new_for_path(temp_dir)); }
            catch (Error e) { fail_if_reached(@"encryption-loss fixture cleanup failed: $(e.message)"); }
        }
    }

    private void test_omemo1_jet_s5b_tampered_tag_fails_before_store_release_sync() {
        MainLoop loop = new MainLoop();
        test_omemo1_jet_s5b_tampered_tag_fails_before_store_release.begin((obj, res) => {
            try {
                test_omemo1_jet_s5b_tampered_tag_fails_before_store_release.end(res);
            } catch (Error e) {
                fail_if_reached(@"tampered OMEMO1/JET S5B FileManager receive-store proof failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_omemo2_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm_sync() {
        MainLoop loop = new MainLoop();
        test_omemo2_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm.begin((obj, res) => {
            try {
                test_omemo2_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm.end(res);
            } catch (Error e) {
                fail_if_reached(@"real OMEMO2/JET S5B FileManager receive-store proof failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_omemo2_jet_s5b_receive_store_rejects_incompatible_legacy_sender_session_sync() {
        MainLoop loop = new MainLoop();
        test_omemo2_jet_s5b_receive_store_rejects_incompatible_legacy_sender_session.begin((obj, res) => {
            try {
                test_omemo2_jet_s5b_receive_store_rejects_incompatible_legacy_sender_session.end(res);
            } catch (Error e) {
                fail_if_reached(@"OMEMO2/JET S5B incompatible-session rejection proof failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_omemo2_jet_s5b_tampered_tag_fails_before_store_release_sync() {
        MainLoop loop = new MainLoop();
        test_omemo2_jet_s5b_tampered_tag_fails_before_store_release.begin((obj, res) => {
            try {
                test_omemo2_jet_s5b_tampered_tag_fails_before_store_release.end(res);
            } catch (Error e) {
                fail_if_reached(@"tampered OMEMO2/JET S5B FileManager receive-store proof failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void test_omemo1_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm() throws Error {
        yield run_omemo_jet_s5b_receive_store(false, false);
    }

    private async void test_omemo1_jet_s5b_tampered_tag_fails_before_store_release() throws Error {
        yield run_omemo_jet_s5b_receive_store(true, false);
    }

    private async void test_omemo2_jet_s5b_receive_store_uses_real_envelope_and_aes_gcm() throws Error {
        yield run_omemo_jet_s5b_receive_store(false, true);
    }

    private async void test_omemo2_jet_s5b_receive_store_rejects_incompatible_legacy_sender_session() throws Error {
        yield run_omemo_jet_s5b_receive_store(false, true, true);
    }

    private async void test_omemo2_jet_s5b_tampered_tag_fails_before_store_release() throws Error {
        yield run_omemo_jet_s5b_receive_store(true, true);
    }

    private async void run_omemo_jet_s5b_receive_store(bool tamper_tag, bool use_omemo2,
            bool seed_legacy_sender_session = false) throws Error {
        if (!local_s5b_direct_listener_available_or_skip()) return;
        if (!process_xdg_dirs_are_isolated_or_skip()) return;

        string protocol_label = use_omemo2 ? "OMEMO2" : "OMEMO1";
        string protocol_slug = use_omemo2 ? "omemo2" : "omemo1";
        string envelope_type_uri = use_omemo2 ? NS_OMEMO_V2 : NS_OMEMO_LEGACY;
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-omemo-jingle-s5b-jet-" + Uuid.string_random());
        string dino_db_path = Path.build_filename(temp_dir, "dino.db");
        string omemo_db_path = Path.build_filename(temp_dir, "omemo.db");

        Dino.Database? dino_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        FileManager? file_manager = null;
        SocketConnection? peer_connection = null;
        Dino.JingleFileEncryptionHelper? previous_jingle_encryption_helper = null;
        JingleFileTransfer.Module? jingle_file_module = null;
        XmppStreamModule? receiver_omemo_module = null;
        JingleS5bJetOmemoTestStream? receiver_stream = null;
        ulong received_handler = 0;
        ulong incoming_handler = 0;
        ulong device_list_handler = 0;
        string? stored_path = null;
        string? storage_dir = null;
        string? plaintext_lease_root = null;
        Address? seeded_legacy_address = null;
        uint8[]? seeded_legacy_session = null;
        HashSet<string> tmp_ciphertext_files_before = snapshot_temp_files_with_prefix(Environment.get_tmp_dir(), "dinox-jet-omemo-ciphertext-");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage();
            plaintext_lease_root = get_checked_plaintext_lease_root(temp_dir, (!) storage_dir);
            if (plaintext_lease_root == null) return;

            fail_if(!Dino.Plugins.Omemo.Plugin.ensure_context(),
                @"real $protocol_label/JET S5B FileManager proof requires libomemo context");
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            dino_db = new Dino.Database(dino_db_path, "omemo-jingle-s5b-jet-filemanager-test");
            omemo_db = new Dino.Plugins.Omemo.Database(omemo_db_path);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            var file_encryption = new Security.FileEncryption("omemo-jingle-s5b-jet-filemanager-test");
            start_minimal_file_modules(stream_interactor, (!) dino_db, file_encryption);
            file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
            fail_if(file_manager == null, "test setup must start FileManager");

            var alice_account = new Account(new Jid("alice@example.test"), "secret");
            alice_account.persist((!) dino_db);
            var bob_account = new Account(new Jid("bob@example.test"), "secret");
            bob_account.persist((!) dino_db);
            seed_trusted_roster_contact((!) dino_db, alice_account, bob_account.bare_jid);

            var conversation = new Conversation(bob_account.bare_jid, alice_account, Conversation.Type.CHAT);
            conversation.persist((!) dino_db);

            Store alice_store = setup_test_store_context(context);
            Store bob_store = setup_test_store_context(context);
            if (use_omemo2) {
                prepare_pre_key_session_v2(context, bob_store, alice_account.bare_jid, alice_store, 61001, 62001);
                if (seed_legacy_sender_session) {
                    prepare_pre_key_session(context, alice_store, bob_account.bare_jid, bob_store, 61002, 62002);
                    seeded_legacy_address = new Address(bob_account.bare_jid.to_string(),
                        (int) bob_store.local_registration_id);
                    seeded_legacy_session = alice_store.session_store.load_session(
                        (!) seeded_legacy_address);
                    fail_if(seeded_legacy_session == null,
                        "test setup must contain the seeded incompatible legacy sender session");
                }
            } else {
                prepare_pre_key_session(context, bob_store, alice_account.bare_jid, alice_store, 61001, 62001);
            }

            int alice_identity_id = install_identity((!) omemo_db, alice_account, alice_store);
            int bob_identity_id = install_identity((!) omemo_db, bob_account, bob_store);
            if (use_omemo2) {
                add_trusted_omemo2_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
                add_trusted_omemo2_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);
            } else {
                add_trusted_omemo1_device((!) omemo_db, alice_identity_id, bob_account.bare_jid, bob_store);
                add_trusted_omemo1_device((!) omemo_db, bob_identity_id, alice_account.bare_jid, alice_store);
            }

            stream_interactor.module_manager.initialize(alice_account);
            Jid alice_full_jid = new Jid("alice@example.test/dinox");
            Jid bob_full_jid = new Jid("bob@example.test/phone");
            var alice_stream = new JingleS5bJetOmemoTestStream(new Jid("example.test"));
            receiver_stream = alice_stream;
            attach_receiver_modules(stream_interactor, alice_account, alice_stream, alice_full_jid,
                alice_store, (!) omemo_db);
            bool device_list_loaded = false;
            Jid sender_jid = bob_account.bare_jid;
            int32 sender_device_id = (int32) bob_store.local_registration_id;
            alice_stream.set_device_list(sender_jid, sender_device_id, use_omemo2);
            if (use_omemo2) {
                var module = alice_stream.get_module<Dino.Plugins.Omemo.StreamModule2>(
                    Dino.Plugins.Omemo.StreamModule2.IDENTITY);
                receiver_omemo_module = module;
                device_list_handler = module.device_list_loaded.connect((jid, devices) => {
                    fail_if(!jid.equals_bare(sender_jid) || devices.size != 1 ||
                            !devices.contains(sender_device_id),
                        "OMEMO2 PREKEY refresh must return the real sender device from the fixture");
                    device_list_loaded = true;
                });
            } else {
                var module = alice_stream.get_module<Dino.Plugins.Omemo.StreamModule>(
                    Dino.Plugins.Omemo.StreamModule.IDENTITY);
                receiver_omemo_module = module;
                device_list_handler = module.device_list_loaded.connect((jid, devices) => {
                    fail_if(!jid.equals_bare(sender_jid) || devices.size != 1 ||
                            !devices.contains(sender_device_id),
                        "PREKEY refresh must return the real sender device from the fixture");
                    device_list_loaded = true;
                });
            }
            stream_interactor.connection_manager.set_connected_stream_for_tests(alice_account, alice_stream);
            stream_interactor.account_added(alice_account);

            previous_jingle_encryption_helper = register_real_jingle_file_encryption_helper(stream_interactor);

            var bob_interactor = new Dino.StreamInteractor.for_tests((!) dino_db);
            Dino.MessageProcessor.start(bob_interactor, (!) dino_db);
            var bob_trust_manager = new Dino.Plugins.Omemo.TrustManager(bob_interactor, (!) omemo_db);
            var bob_stream = new JingleS5bJetOmemoTestStream(new Jid("example.test"));
            if (use_omemo2) {
                bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule2(bob_store));
                bob_stream.add_module(new Dino.Plugins.Omemo.Omemo2Encrypt(bob_account, bob_trust_manager, bob_store));
            } else {
                bob_stream.add_module(new Dino.Plugins.Omemo.StreamModule(bob_store));
                bob_stream.add_module(new Dino.Plugins.Omemo.OmemoEncryptor(bob_account, bob_trust_manager, bob_store));
            }

            var sender_jet_module = new Jet.Module();
            var jet_omemo_module = new Dino.Plugins.JetOmemo.Module();
            sender_jet_module.register_envelop_encoding(jet_omemo_module);
            sender_jet_module.register_envelop_encoding(new Dino.Plugins.JetOmemo.Omemo2EnvelopeEncoding());
            sender_jet_module.register_cipher(new Dino.Plugins.JetOmemo.AesGcmCipher(16, 12, AES_128_GCM_URI));

            Jingle.SecurityParameters? created_security = sender_jet_module.create_security_parameters(bob_stream,
                bob_full_jid, alice_full_jid, new Jet.Options(envelope_type_uri, AES_128_GCM_URI));
            Jet.SecurityParameters sender_security = (Jet.SecurityParameters) ((!) created_security);
            StanzaNode security_node = sender_security.to_security_stanza_node(bob_stream, bob_full_jid, alice_full_jid);
            assert_real_jet_omemo_security_node(security_node, sender_security, alice_account.bare_jid,
                alice_store, envelope_type_uri, protocol_label);

            Dino.Entities.FileTransfer? published_transfer = null;
            Conversation? published_conversation = null;
            received_handler = ((!) file_manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
            });

            Jet.SecurityParameters? observed_security = null;
            string? observed_transport_ns_uri = null;
            jingle_file_module = stream_interactor.module_manager.get_module<JingleFileTransfer.Module>(
                alice_account, JingleFileTransfer.Module.IDENTITY);
            fail_if(jingle_file_module == null, "test setup must provide the Jingle file-transfer module");
            incoming_handler = ((!) jingle_file_module).file_incoming.connect((stream, jingle_transfer) => {
                if (!jingle_transfer.peer.equals_bare(bob_account.bare_jid)) return;
                observed_security = jingle_transfer.security as Jet.SecurityParameters;
                observed_transport_ns_uri = jingle_transfer.transport_ns_uri;
            });

            uint8[] payload = @"real $protocol_label JET over Jingle S5B FileManager payload\n".data;
            uint8[] encrypted_payload = encrypt_payload_with_cipher(sender_security.cipher, sender_security.secret, payload);
            fail_if(encrypted_payload.length != payload.length + 16,
                @"real $protocol_label/JET S5B wire payload must include the AES-GCM authentication tag");
            fail_if(bytes_equal(encrypted_payload[0:payload.length], payload),
                @"real $protocol_label/JET S5B wire payload must not expose plaintext bytes");
            if (tamper_tag) {
                encrypted_payload[encrypted_payload.length - 1] = (uint8) (encrypted_payload[encrypted_payload.length - 1] ^ 0x01);
            }

            string incoming_file_name = "incoming-real-" + protocol_slug + "-jet-s5b-" + Uuid.string_random() + ".txt";
            string jingle_sid = "real-" + protocol_slug + "-jet-s5b-" + Uuid.string_random();
            string s5b_sid = "real-" + protocol_slug + "-jet-s5b-transport-" + Uuid.string_random();
            string content_name = "incoming-file";
            StanzaNode iq = build_incoming_jingle_s5b_iq(alice_full_jid, bob_full_jid, jingle_sid,
                content_name, s5b_sid, incoming_file_name, payload.length, security_node);
            try {
                run_jingle_iq_set(alice_stream, iq);
            } catch (Error e) {
                if (!seed_legacy_sender_session) throw e;

                uint8[]? current_session = alice_store.session_store.load_session(
                    (!) seeded_legacy_address);
                fail_if(current_session == null,
                    "rejected OMEMO2 PREKEY must preserve the incompatible legacy session");
                fail_if(!bytes_equal((!) seeded_legacy_session, (!) current_session),
                    "rejected OMEMO2 PREKEY must preserve the legacy session byte-for-byte");
                fail_if(!e.message.contains("Not encrypted for targeted device"),
                    @"unexpected incompatible-session rejection: $(e.message)");
                fail_if(alice_stream.device_list_request_count != 0 || device_list_loaded,
                    "rejected OMEMO2 PREKEY must not start a device-list refresh");
                return;
            }
            fail_if(seed_legacy_sender_session,
                "OMEMO2 PREKEY must fail closed while an incompatible legacy sender session exists");

            fail_if(!(yield wait_for_condition(5, () => device_list_loaded)),
                @"$protocol_label PREKEY device-list IQ must complete in its own fixture instead of timing out in a later test");
            fail_if(alice_stream.device_list_request_count != 1,
                @"$protocol_label PREKEY must complete exactly one sender device-list refresh");
            if (!use_omemo2) {
                fail_if(!(yield wait_for_condition(5, () => alice_stream.own_bundle != null)),
                    "committed legacy JET PREKEY consumption must finish its own fake PEP publication");
                var refreshed = new Dino.Plugins.Omemo.Bundle((!) alice_stream.own_bundle);
                fail_if(refreshed.pre_keys.size != 100,
                    "the receiver's fake PEP bundle must contain 100 available replacement prekeys");
                foreach (Dino.Plugins.Omemo.Bundle.PreKey key in refreshed.pre_keys) {
                    fail_if(key.key_id < 0 || !alice_store.contains_pre_key(key.key_id) ||
                            key.key == null || alice_store.load_pre_key(key.key_id).key_pair.public.compare(key.key) != 0,
                        "every fake PEP prekey must match the receiver's native private-key store");
                }
            }

            fail_if(!(yield wait_for_condition(5, () => published_transfer != null)),
                @"real $protocol_label/JET S5B FileManager proof must publish the incoming transfer shell");
            FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                @"real $protocol_label/JET S5B FileManager proof must publish the expected one-to-one conversation");
            fail_if(observed_security == null,
                @"real $protocol_label/JET S5B incoming offer must parse JET security parameters");
            fail_if(observed_transport_ns_uri != JingleSocks5Bytestreams.Module.IDENTITY.ns,
                @"real $protocol_label/JET S5B incoming offer must use S5B transport");
            fail_if(file_transfer.encryption != Encryption.OMEMO,
                @"real $protocol_label/JET S5B FileManager proof must classify the transfer as OMEMO");
            fail_if(file_transfer.provider != JINGLE_PROVIDER_ID,
                @"real $protocol_label/JET S5B FileManager proof must keep the Jingle provider id");
            if (tamper_tag) {
                file_transfer.notify["phase"].connect(() => {
                    fail_if(file_transfer.phase == FileTransfer.Phase.PREVIEWING,
                        @"tampered $protocol_label/JET S5B receive-store must not expose PREVIEWING");
                    fail_if(file_transfer.phase == FileTransfer.Phase.COMPLETE,
                        @"tampered $protocol_label/JET S5B receive-store must not expose COMPLETE");
                });
                GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Error downloading file: JET-OMEMO AES-GCM authentication failed*");
            }

            fail_if(!wait_for_written_jingle_action(alice_stream, jingle_sid, "session-accept", 5000),
                @"real $protocol_label/JET S5B FileManager proof must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(alice_stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", Jingle.NS_URI);
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                @"real $protocol_label/JET S5B session-accept must keep the S5B sid");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                @"real $protocol_label/JET S5B session-accept must publish dstaddr");
            assert_only_s5b_candidate_type(accept_transport, "direct");
            StanzaNode candidate_node = get_single_candidate_by_type(accept_transport, "direct");
            var local_candidate = JingleSocks5Bytestreams.Candidate.parse(candidate_node);

            peer_connection = run_connect_to_socks5(local_candidate, (!) dstaddr);
            drain_s5b_listener_bookkeeping();
            run_jingle_iq_set(alice_stream,
                build_s5b_candidate_used_transport_info(alice_full_jid, bob_full_jid, jingle_sid,
                    content_name, s5b_sid, local_candidate.cid));
            run_write_all_stream(((!) peer_connection).output_stream, encrypted_payload);

            if (tamper_tag) {
                fail_if(!(yield wait_for_condition(5, () => file_transfer.phase == FileTransfer.Phase.FAILED)),
                    @"tampered $protocol_label/JET S5B FileManager proof must fail before publish");
                GLib.Test.assert_expected_messages();
                validate_failed_transfer((!) dino_db, file_transfer);
                assert_no_receive_temp_files((!) storage_dir, incoming_file_name,
                    @"tampered $protocol_label/JET S5B FileManager proof must not leave pending receive files");
                assert_directory_empty_or_missing((!) plaintext_lease_root,
                    @"tampered $protocol_label/JET S5B FileManager proof must not leave plaintext lease files");
                assert_no_new_temp_files_with_prefix(tmp_ciphertext_files_before,
                    "dinox-jet-omemo-ciphertext-",
                    @"tampered $protocol_label/JET S5B FileManager proof must not leave JET ciphertext temp files");
                fail_if(!wait_for_written_jingle_action(alice_stream, jingle_sid, "session-terminate", 5000),
                    @"tampered $protocol_label/JET S5B FileManager proof must terminate the Jingle session");
                assert_last_session_terminate_reason(alice_stream, jingle_sid, bob_full_jid, "failed-transport");
                assert_no_jingle_session_state(alice_stream, jingle_sid);
                return;
            }

            fail_if(!(yield wait_for_condition(5, () => file_transfer.phase == FileTransfer.Phase.COMPLETE ||
                    file_transfer.phase == FileTransfer.Phase.FAILED)),
                @"real $protocol_label/JET S5B FileManager proof must settle the receive-store transfer");
            fail_if(file_transfer.phase == FileTransfer.Phase.FAILED,
                @"real $protocol_label/JET S5B FileManager receive-store failed: " + (file_transfer.phase_error ?? "no phase error"));
            stored_path = file_transfer.path;

            validate_completed_transfer((!) dino_db, file_transfer, conversation, bob_account.bare_jid,
                incoming_file_name, payload.length);
            yield validate_stored_payload(file_encryption, file_transfer, payload);
            assert_no_receive_temp_files((!) storage_dir, incoming_file_name,
                @"real $protocol_label/JET S5B FileManager proof must not leave pending receive files");
            assert_directory_empty_or_missing((!) plaintext_lease_root,
                @"real $protocol_label/JET S5B FileManager proof must release plaintext lease files");
            assert_no_new_temp_files_with_prefix(tmp_ciphertext_files_before,
                "dinox-jet-omemo-ciphertext-",
                @"real $protocol_label/JET S5B FileManager proof must not leave JET ciphertext temp files");
            assert_last_session_terminate_reason(alice_stream, jingle_sid, bob_full_jid, "success");
            assert_no_jingle_session_state(alice_stream, jingle_sid);
        } finally {
            if (peer_connection != null) {
                try { ((!) peer_connection).close(); } catch (Error e) {}
            }
            if (received_handler != 0 && file_manager != null) {
                ((!) file_manager).disconnect(received_handler);
            }
            if (incoming_handler != 0 && jingle_file_module != null) {
                ((!) jingle_file_module).disconnect(incoming_handler);
            }
            if (device_list_handler != 0 && receiver_omemo_module != null) {
                ((!) receiver_omemo_module).disconnect(device_list_handler);
            }
            if (receiver_stream != null) {
                var stream = (!) receiver_stream;
                stream.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY).detach(stream);
                stream.get_module<Dino.Plugins.Omemo.StreamModule2>(Dino.Plugins.Omemo.StreamModule2.IDENTITY).detach(stream);
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
                stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).detach(stream);
            }
            restore_jingle_file_encryption_helper(previous_jingle_encryption_helper);
            if (dino_db != null) ((!) dino_db).close();
            if (omemo_db != null) ((!) omemo_db).close();
            if (stored_path != null && storage_dir != null) {
                FileUtils.remove(Path.build_filename((!) storage_dir, (!) stored_path));
            }
            if (storage_dir != null) {
                delete_receive_pending_files_for_basename((!) storage_dir, "incoming-real-" + protocol_slug + "-jet-s5b");
            }
            cleanup_file(omemo_db_path);
            cleanup_file(omemo_db_path + "-shm");
            cleanup_file(omemo_db_path + "-wal");
            cleanup_file(dino_db_path);
            cleanup_file(dino_db_path + "-shm");
            cleanup_file(dino_db_path + "-wal");
            try {
                delete_file_tree(File.new_for_path(temp_dir));
            } catch (Error e) {
                GLib.Test.message(@"Could not clean real $protocol_label/JET S5B temp dir: $(e.message)");
            }
        }
    }

    private static bool local_s5b_direct_listener_available_or_skip() {
        SocketListener listener = new SocketListener();
        try {
            SocketAddress effective_any;
            listener.add_address(new InetSocketAddress.from_string("127.0.0.1", 0),
                SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
            listener.close();
            return true;
        } catch (Error e) {
            listener.close();
            GLib.Test.skip("Local S5B direct-listener test sockets unavailable: %s".printf(e.message));
            return false;
        }
    }

    private static void start_minimal_file_modules(StreamInteractor stream_interactor, Dino.Database db,
            Security.FileEncryption file_encryption) {
        MessageStorage.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        MessageProcessor.start(stream_interactor, db);
        MessageProcessor? message_processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        if (message_processor != null) ((!) message_processor).history_sync.auto_fetch_enabled = false;
        EntityInfo.start(stream_interactor, db);
        RosterManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        MucManager.start(stream_interactor);
        FileManager.start(stream_interactor, db, file_encryption);
    }

    private static void attach_receiver_modules(StreamInteractor stream_interactor, Account account,
            JingleS5bJetOmemoTestStream stream, Jid local_full_jid, Store store,
            Dino.Plugins.Omemo.Database omemo_db) {
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = local_full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);
        stream.set_own_bundle_owner(local_full_jid, (int32) store.local_registration_id);

        var socks5 = stream_interactor.module_manager.get_module<Socks5Bytestreams.Module>(
            account, Socks5Bytestreams.Module.IDENTITY);
        fail_if(socks5 == null, "test setup must provide the SOCKS5 bytestreams module");
        ((!) socks5).set_local_ip_address_handler(() => {
            var addresses = new ArrayList<string>();
            addresses.add("127.0.0.1");
            return addresses;
        });
        stream.add_module((!) socks5);
        stream.add_flag(new Socks5Bytestreams.Flag());

        var iq = stream_interactor.module_manager.get_module<Iq.Module>(account, Iq.Module.IDENTITY);
        fail_if(iq == null, "test setup must provide the IQ module");
        stream.add_module((!) iq);
        ((!) iq).attach(stream);

        var message_module = stream_interactor.module_manager.get_module<MessageModule>(account, MessageModule.IDENTITY);
        fail_if(message_module == null, "test setup must provide the message module");
        stream.add_module((!) message_module);
        ((!) message_module).attach(stream);

        var pubsub = stream_interactor.module_manager.get_module<Pubsub.Module>(account, Pubsub.Module.IDENTITY);
        fail_if(pubsub == null, "test setup must provide the PubSub module");
        stream.add_module((!) pubsub);
        ((!) pubsub).attach(stream);

        var service_discovery = stream_interactor.module_manager.get_module<ServiceDiscovery.Module>(
            account, ServiceDiscovery.Module.IDENTITY);
        fail_if(service_discovery == null, "test setup must provide the service-discovery module");
        stream.add_module((!) service_discovery);
        ((!) service_discovery).attach(stream);

        var jingle = stream_interactor.module_manager.get_module<Jingle.Module>(account, Jingle.Module.IDENTITY);
        fail_if(jingle == null, "test setup must provide the Jingle module");
        stream.add_module((!) jingle);
        ((!) jingle).attach(stream);

        var file_transfer = stream_interactor.module_manager.get_module<JingleFileTransfer.Module>(
            account, JingleFileTransfer.Module.IDENTITY);
        fail_if(file_transfer == null, "test setup must provide the Jingle file-transfer module");
        stream.add_module((!) file_transfer);
        ((!) file_transfer).attach(stream);

        var jingle_s5b = stream_interactor.module_manager.get_module<JingleSocks5Bytestreams.Module>(
            account, JingleSocks5Bytestreams.Module.IDENTITY);
        fail_if(jingle_s5b == null, "test setup must provide the Jingle S5B module");
        stream.add_module((!) jingle_s5b);
        ((!) jingle_s5b).attach(stream);

        var jet = stream_interactor.module_manager.get_module<Jet.Module>(account, Jet.Module.IDENTITY);
        fail_if(jet == null, "test setup must provide the JET module");
        stream.add_module((!) jet);
        ((!) jet).attach(stream);

        var stream_module = new Dino.Plugins.Omemo.StreamModule(store);
        stream.add_module(stream_module);
        stream_module.attach(stream);
        var stream_module2 = new Dino.Plugins.Omemo.StreamModule2(store);
        stream.add_module(stream_module2);
        stream_module2.attach(stream);

        var trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, omemo_db);
        stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(account, stream_interactor, trust_manager, omemo_db, store));
        stream.add_module(new Dino.Plugins.Omemo.Omemo2Decrypt(account, stream_interactor, trust_manager, omemo_db, store));

        var jet_omemo = new Dino.Plugins.JetOmemo.Module();
        stream.add_module(jet_omemo);
        jet_omemo.attach(stream);
    }

    private static Dino.JingleFileEncryptionHelper? register_real_jingle_file_encryption_helper(StreamInteractor stream_interactor) {
        var registry = Dino.JingleFileHelperRegistry.instance;
        Dino.JingleFileEncryptionHelper? previous_helper = registry.get_encryption_helper(Encryption.OMEMO);
        registry.add_encryption_helper(Encryption.OMEMO, new Dino.Plugins.JetOmemo.EncryptionHelper(stream_interactor));
        return previous_helper;
    }

    private static void restore_jingle_file_encryption_helper(Dino.JingleFileEncryptionHelper? previous_helper) {
        var registry = Dino.JingleFileHelperRegistry.instance;
        if (previous_helper != null) {
            registry.add_encryption_helper(Encryption.OMEMO, (!) previous_helper);
        } else {
            registry.encryption_helpers.unset(Encryption.OMEMO);
        }
    }

    private static void assert_real_jet_omemo_security_node(StanzaNode security_node,
            Jet.SecurityParameters sender_security, Jid receiver_jid, Store receiver_store,
            string envelope_type_uri, string protocol_label) {
        fail_if(security_node.ns_uri != Jet.NS_URI,
            @"real $protocol_label/JET S5B proof must use the XEP-0391 security namespace");
        fail_if(security_node.get_attribute("cipher") != AES_128_GCM_URI,
            @"real $protocol_label/JET S5B proof must advertise AES-GCM");
        fail_if(security_node.get_attribute("type") != envelope_type_uri,
            @"real $protocol_label/JET S5B proof must advertise the expected OMEMO envelope type");
        StanzaNode? encrypted_node = security_node.get_subnode("encrypted", envelope_type_uri);
        fail_if(encrypted_node == null,
            @"real $protocol_label/JET S5B proof must contain an OMEMO encrypted key node");
        if (encrypted_node == null) return;
        if (envelope_type_uri == NS_OMEMO_V2) {
            assert_only_omemo2_key_recipient((!) encrypted_node, receiver_jid,
                (int) receiver_store.local_registration_id,
                @"real $protocol_label/JET S5B proof must target the receiver device");
        } else {
            assert_only_omemo_key_recipient((!) encrypted_node, (int) receiver_store.local_registration_id,
                @"real $protocol_label/JET S5B proof must target the receiver device");
        }
        fail_if(((!) encrypted_node).get_subnode("payload", envelope_type_uri) != null,
            @"real $protocol_label/JET S5B security node must carry only transport-secret keys, not a message payload");
        fail_if(security_node.to_string().contains(Base64.encode(sender_security.secret.transport_key)),
            @"real $protocol_label/JET S5B security node must not expose the transport key");
    }

    private static uint8[] encrypt_payload_with_cipher(Jet.Cipher cipher, Jet.TransportSecret secret,
            uint8[] plaintext) throws Error {
        var encrypted_output = new MemoryOutputStream.resizable();
        OutputStream encrypted_stream = cipher.wrap_output_stream(encrypted_output, secret);
        size_t written;
        encrypted_stream.write_all(plaintext, out written);
        fail_if(written != plaintext.length,
            "real OMEMO1/JET S5B cipher must accept the complete plaintext");
        encrypted_stream.close();

        uint8[] encrypted = encrypted_output.steal_data();
        encrypted.length = (int) encrypted_output.get_data_size();
        return encrypted;
    }

    private static StanzaNode build_incoming_jingle_s5b_iq(Jid local_full_jid, Jid peer_full_jid,
            string sid, string content_name, string s5b_sid, string file_name, int64 file_size,
            StanzaNode security) throws Error {
        string dstaddr = JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer_full_jid, local_full_jid);
        StanzaNode transport = new StanzaNode.build("transport", JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr);
        StanzaNode content = new StanzaNode.build("content", Jingle.NS_URI)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_jingle_file_description(file_name, file_size.to_string()))
            .put_node(transport)
            .put_node(security);
        StanzaNode jingle = new StanzaNode.build("jingle", Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer_full_jid.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "omemo-real-jet-incoming-jingle-s5b")
            .put_attribute("from", peer_full_jid.to_string())
            .put_attribute("to", local_full_jid.to_string())
            .put_node(jingle);
    }

    private static StanzaNode build_jingle_file_description(string file_name, string file_size) {
        var description = new StanzaNode.build("description", JingleFileTransfer.Module.IDENTITY.ns).add_self_xmlns();
        var file = new StanzaNode.build("file", JingleFileTransfer.Module.IDENTITY.ns)
            .put_node(new StanzaNode.build("name", JingleFileTransfer.Module.IDENTITY.ns)
                .put_node(new StanzaNode.text(file_name)))
            .put_node(new StanzaNode.build("size", JingleFileTransfer.Module.IDENTITY.ns)
                .put_node(new StanzaNode.text(file_size)));
        description.put_node(file);
        return description;
    }

    private static StanzaNode build_s5b_candidate_used_transport_info(Jid local_full_jid, Jid peer_full_jid,
            string sid, string content_name, string s5b_sid, string cid) {
        StanzaNode transport = new StanzaNode.build("transport", JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("sid", s5b_sid)
            .put_node(new StanzaNode.build("candidate-used", JingleSocks5Bytestreams.Module.IDENTITY.ns)
                .put_attribute("cid", cid));
        StanzaNode content = new StanzaNode.build("content", Jingle.NS_URI)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", peer_full_jid.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "omemo-real-jet-s5b-candidate-used")
            .put_attribute("from", peer_full_jid.to_string())
            .put_attribute("to", local_full_jid.to_string())
            .put_node(jingle);
    }

    private static void run_jingle_iq_set(JingleS5bJetOmemoTestStream stream, StanzaNode iq_node) throws Error {
        var jingle = stream.get_module<Jingle.Module>(Jingle.Module.IDENTITY);
        fail_if(jingle == null, "test setup must attach the Jingle module");
        var iq = new Iq.Stanza.from_stanza(iq_node, stream.get_flag(Bind.Flag.IDENTITY).my_jid);

        Error? failure = null;
        MainLoop loop = new MainLoop();
        ((!) jingle).handle_iq_set.begin(stream, iq, (_, res) => {
            try {
                ((!) jingle).handle_iq_set.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) throw (!) failure;
    }

    private static bool wait_for_written_jingle_action(JingleS5bJetOmemoTestStream stream,
            string sid, string action, uint timeout_ms) {
        if (find_written_jingle_action(stream, sid, action) != null) return true;

        MainLoop loop = new MainLoop();
        bool found = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            found = find_written_jingle_action(stream, sid, action) != null;
            if (found) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();
        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return found || find_written_jingle_action(stream, sid, action) != null;
    }

    private static StanzaNode? find_written_jingle_action(JingleS5bJetOmemoTestStream stream,
            string sid, string action) {
        foreach (StanzaNode iq in stream.written_nodes) {
            StanzaNode? jingle = iq.get_subnode("jingle", Jingle.NS_URI);
            if (jingle != null &&
                    ((!) jingle).get_attribute("sid") == sid &&
                    ((!) jingle).get_attribute("action") == action) {
                return (!) jingle;
            }
        }
        return null;
    }

    private static StanzaNode require_written_jingle_action(JingleS5bJetOmemoTestStream stream,
            string sid, string action) {
        StanzaNode? result = find_written_jingle_action(stream, sid, action);
        fail_if(result == null, @"expected written Jingle $action for sid $sid");
        return (!) result;
    }

    private static StanzaNode get_required_subnode(StanzaNode node, string name, string ns_uri) {
        StanzaNode? child = node.get_subnode(name, ns_uri);
        fail_if(child == null, @"expected <$name/> child in namespace $ns_uri");
        return (!) child;
    }

    private static StanzaNode get_single_candidate_by_type(StanzaNode transport, string type_) {
        StanzaNode? result = null;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", JingleSocks5Bytestreams.Module.IDENTITY.ns)) {
            if (candidate.get_attribute("type") != type_) continue;
            fail_if(result != null, @"expected only one $type_ S5B candidate");
            result = candidate;
        }
        fail_if(result == null, @"expected one $type_ S5B candidate");
        return (!) result;
    }

    private static void assert_only_s5b_candidate_type(StanzaNode transport, string type_) {
        int count = 0;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", JingleSocks5Bytestreams.Module.IDENTITY.ns)) {
            count++;
            fail_if(candidate.get_attribute("type") != type_,
                @"real OMEMO1/JET S5B proof must publish only $type_ candidates");
        }
        fail_if(count != 1, @"real OMEMO1/JET S5B proof must publish exactly one $type_ candidate");
    }

    private static SocketConnection run_connect_to_socks5(JingleSocks5Bytestreams.Candidate candidate,
            string dstaddr) throws Error {
        SocketConnection? result = null;
        Error? failure = null;
        Cancellable cancellable = new Cancellable();
        bool timed_out = false;
        MainLoop loop = new MainLoop();
        uint timeout_source = 0;

        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            loop.quit();
            return Source.REMOVE;
        });

        connect_to_socks5.begin(candidate, dstaddr, cancellable, (_, res) => {
            try {
                result = connect_to_socks5.end(res);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out) {
            if (result != null) {
                try { ((!) result).close(); } catch (Error e) {}
            }
            throw new IOError.TIMED_OUT("Timed out completing S5B listener handshake");
        }
        if (failure != null) throw (!) failure;
        return (!) result;
    }

    private static async SocketConnection connect_to_socks5(JingleSocks5Bytestreams.Candidate candidate,
            string dstaddr, Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=2 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection? conn = null;
        try {
            conn = yield socket_client.connect_to_host_async(@"[$(candidate.host)]:$(candidate.port)", 0, cancellable);

            size_t written;
            size_t read;
            uint8[] read_buffer = new uint8[1024];
            ByteArray write_buffer = new ByteArray();

            yield ((!) conn).output_stream.write_all_async({0x05, 0x01, 0x00}, Priority.DEFAULT, cancellable, out written);
            yield ((!) conn).input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, cancellable, out read);
            if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
                throw new IOError.PROXY_FAILED("S5B listener did not accept null authentication");
            }

            write_buffer.append({0x05, 0x01, 0x00, 0x03});
            write_buffer.append({(uint8) dstaddr.length});
            write_buffer.append(dstaddr.data);
            write_buffer.append({0x00, 0x00});
            yield ((!) conn).output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, cancellable, out written);
            yield ((!) conn).input_stream.read_all_async(read_buffer[0:write_buffer.len], Priority.DEFAULT, cancellable, out read);
            if (read != write_buffer.len || read_buffer[0] != 0x05 || read_buffer[1] != 0x00 || read_buffer[3] != 0x03) {
                throw new IOError.PROXY_FAILED("S5B listener did not complete the connect handshake");
            }
            if (read_buffer[4] != (uint8) dstaddr.length ||
                    !JingleSocks5Bytestreams.bytes_equal(read_buffer[5:5 + dstaddr.length], dstaddr.data) ||
                    read_buffer[5 + dstaddr.length] != 0x00 ||
                    read_buffer[5 + dstaddr.length + 1] != 0x00) {
                throw new IOError.PROXY_FAILED("S5B listener returned an unexpected dstaddr success response");
            }

            SocketConnection result = (!) conn;
            conn = null;
            return result;
        } catch (Error e) {
            if (conn != null) {
                try { ((!) conn).close(); } catch (Error close_error) {}
            }
            throw e;
        }
    }

    private static void drain_s5b_listener_bookkeeping() {
        MainContext context = MainContext.default();
        int iterations = 0;
        while (context.pending() && iterations < 100) {
            context.iteration(false);
            iterations++;
        }
    }

    private static void run_write_all_stream(OutputStream output, uint8[] payload) throws Error {
        Error? failure = null;
        bool timed_out = false;
        uint timeout_source = 0;
        size_t written = 0;
        Cancellable cancellable = new Cancellable();
        MainLoop loop = new MainLoop();

        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            loop.quit();
            return Source.REMOVE;
        });
        output.write_all_async.begin(payload, Priority.DEFAULT, cancellable, (_, res) => {
            try {
                output.write_all_async.end(res, out written);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out) throw new IOError.TIMED_OUT("Timed out writing S5B payload");
        if (failure != null) throw (!) failure;
        fail_if(written != payload.length, "S5B payload write must complete");
    }

    private async bool wait_for_condition(uint timeout_seconds, WaitCondition condition) {
        if (condition()) return true;

        bool completed = false;
        bool success = false;
        SourceFunc resume = wait_for_condition.callback;
        uint poll_id = 0;
        uint timeout_id = 0;

        poll_id = Timeout.add(100, () => {
            if (!condition()) return Source.CONTINUE;
            completed = true;
            success = true;
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            poll_id = 0;
            resume();
            return Source.REMOVE;
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            if (poll_id != 0) {
                Source.remove(poll_id);
                poll_id = 0;
            }
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        yield;
        if (poll_id != 0) Source.remove(poll_id);
        if (timeout_id != 0) Source.remove(timeout_id);
        return success;
    }

    private static void validate_completed_transfer(Dino.Database db, FileTransfer file_transfer,
            Conversation expected_conversation, Jid expected_sender, string expected_name, int64 expected_size) throws Error {
        fail_if(file_transfer.id == -1,
            "real OMEMO1/JET S5B receive-store must publish a persisted transfer");
        fail_if(file_transfer.direction != FileTransfer.DIRECTION_RECEIVED,
            "real OMEMO1/JET S5B receive-store must publish a received transfer");
        fail_if(!file_transfer.counterpart.equals_bare(expected_sender),
            "real OMEMO1/JET S5B receive-store must keep the expected sender");
        fail_if(file_transfer.file_name != expected_name,
            "real OMEMO1/JET S5B receive-store must keep the offered file name");
        fail_if(file_transfer.size != expected_size,
            "real OMEMO1/JET S5B receive-store must publish the plaintext size");
        fail_if(file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE,
            "real OMEMO1/JET S5B receive-store must finish COMPLETE");
        fail_if(file_transfer.phase_error != null,
            "real OMEMO1/JET S5B receive-store must not retain a phase error");
        fail_if(file_transfer.path == null || ((!) file_transfer.path) == "",
            "real OMEMO1/JET S5B receive-store must publish a storage path");
        fail_if(!file_transfer.is_plaintext_release_allowed(),
            "real OMEMO1/JET S5B receive-store must only allow plaintext release after completion");

        RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", file_transfer.id)
            .single()
            .row();
        fail_if(!row.is_present(), "real OMEMO1/JET S5B transfer must have a database row");
        FileTransfer.State persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        string? persisted_path = ((!) row.inner)[db.file_transfer.path];
        int64 persisted_size = ((!) row.inner)[db.file_transfer.size];
        fail_if(persisted_state != FileTransfer.State.COMPLETE,
            "real OMEMO1/JET S5B transfer must persist COMPLETE state");
        fail_if(persisted_path == null || ((!) persisted_path) == "",
            "real OMEMO1/JET S5B transfer must persist the storage path");
        fail_if(persisted_size != expected_size,
            "real OMEMO1/JET S5B transfer must persist the plaintext size");
        fail_if(expected_conversation.id < 0,
            "test setup must persist the expected conversation");
    }

    private async void validate_stored_payload(Security.FileEncryption file_encryption, FileTransfer file_transfer,
            uint8[] expected_plaintext) throws Error {
        File? stored_file = file_transfer.get_file();
        fail_if(stored_file == null || !((!) stored_file).query_exists(),
            "real OMEMO1/JET S5B receive-store must write the verified local file");

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();
        fail_if(!bytes_equal(expected_plaintext, decrypted),
            "real OMEMO1/JET S5B receive-store must persist the decrypted S5B payload");
    }

    private static void validate_failed_transfer(Dino.Database db, FileTransfer file_transfer) throws Error {
        fail_if(file_transfer.id == -1,
            "tampered OMEMO1/JET S5B transfer must keep a persisted audit row");
        fail_if(file_transfer.state == FileTransfer.State.COMPLETE || file_transfer.phase == FileTransfer.Phase.COMPLETE,
            "tampered OMEMO1/JET S5B transfer must not complete");
        fail_if(file_transfer.state != FileTransfer.State.FAILED || file_transfer.phase != FileTransfer.Phase.FAILED,
            "tampered OMEMO1/JET S5B transfer must fail in memory");
        fail_if(file_transfer.path != null && ((!) file_transfer.path) != "",
            "tampered OMEMO1/JET S5B transfer must not publish a storage path");
        fail_if(file_transfer.is_plaintext_release_allowed(),
            "tampered OMEMO1/JET S5B transfer must not allow plaintext release");

        RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", file_transfer.id)
            .single()
            .row();
        fail_if(!row.is_present(), "tampered OMEMO1/JET S5B transfer must have a database row");
        FileTransfer.State persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        string? persisted_path = ((!) row.inner)[db.file_transfer.path];
        fail_if(persisted_state == FileTransfer.State.COMPLETE,
            "tampered OMEMO1/JET S5B transfer must not persist COMPLETE");
        fail_if(persisted_state != FileTransfer.State.FAILED,
            "tampered OMEMO1/JET S5B transfer must persist FAILED");
        fail_if(persisted_path != null && ((!) persisted_path) != "",
            "tampered OMEMO1/JET S5B transfer must not persist a storage path");
    }

    private static void assert_last_session_terminate_reason(JingleS5bJetOmemoTestStream stream,
            string sid, Jid peer, string reason_name) {
        fail_if(stream.written_nodes.is_empty,
            "real OMEMO1/JET S5B proof must write a final Jingle stanza");
        StanzaNode iq = stream.written_nodes[stream.written_nodes.size - 1];
        fail_if(iq.name != "iq", "final Jingle stanza must be an IQ");
        fail_if(iq.get_attribute("type") != "set", "final Jingle stanza must be an IQ set");
        fail_if(iq.get_attribute("to") != peer.to_string(), "final Jingle stanza must target the sender");
        StanzaNode jingle = get_required_subnode(iq, "jingle", Jingle.NS_URI);
        fail_if(jingle.get_attribute("action") != "session-terminate",
            "real OMEMO1/JET S5B proof must terminate the session after store");
        fail_if(jingle.get_attribute("sid") != sid,
            "real OMEMO1/JET S5B proof must terminate the original SID");
        StanzaNode reason = get_required_subnode(jingle, "reason", Jingle.NS_URI);
        fail_if(reason.get_subnode(reason_name, Jingle.NS_URI) == null,
            "real OMEMO1/JET S5B proof must terminate with the expected reason");
    }

    private static void assert_no_jingle_session_state(JingleS5bJetOmemoTestStream stream, string sid) {
        var jingle_flag = stream.get_flag<Jingle.Flag>(Jingle.Flag.IDENTITY);
        fail_if(jingle_flag != null && ((!) jingle_flag).promises.has_key(sid),
            "real OMEMO1/JET S5B proof must not leave promise state after termination");
        fail_if(jingle_flag != null && ((!) jingle_flag).sessions.has_key(sid),
            "real OMEMO1/JET S5B proof must not leave session state after termination");
    }

    private static void prepare_pre_key_session(Context context, Store sender_store, Jid peer_jid, Store peer_store,
            uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private,
            peer_signed_pre_key_pair.public.serialize());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id,
            (int) peer_store.local_registration_id, pre_key_id, peer_pre_key_pair.public,
            signed_pre_key_id, peer_signed_pre_key_pair.public, peer_signed_pre_key_signature,
            peer_identity_key_pair.public);

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

    private static void prepare_pre_key_session_v2(Context context, Store sender_store, Jid peer_jid, Store peer_store,
            uint32 pre_key_id, int signed_pre_key_id) throws Error {
        ECKeyPair peer_pre_key_pair = context.generate_key_pair();
        ECKeyPair peer_signed_pre_key_pair = context.generate_key_pair();
        IdentityKeyPair peer_identity_key_pair = peer_store.identity_key_pair;
        uint8[] peer_signed_pre_key_signature = context.calculate_signature(peer_identity_key_pair.private,
            peer_signed_pre_key_pair.public.serialize_omemo());
        PreKeyBundle peer_pre_key = create_pre_key_bundle(peer_store.local_registration_id,
            (int) peer_store.local_registration_id, pre_key_id, peer_pre_key_pair.public,
            signed_pre_key_id, peer_signed_pre_key_pair.public, peer_signed_pre_key_signature,
            peer_identity_key_pair.public);

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
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, new uint8[1],
            peer_signed_pre_key_signature));
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

    private static void assert_only_omemo_key_recipient(StanzaNode encrypted_node, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_LEGACY);
        fail_if(header_node == null, reason + ": missing OMEMO header");
        if (header_node == null) return;

        int key_count = 0;
        foreach (StanzaNode key_node in ((!) header_node).get_subnodes("key", NS_OMEMO_LEGACY)) {
            key_count++;
            int rid = key_node.get_attribute_int("rid");
            fail_if(rid != device_id, @"$reason: unexpected OMEMO recipient device $rid");
        }
        fail_if(key_count != 1, @"$reason: expected exactly one OMEMO key recipient, got $key_count");
    }

    private static void assert_only_omemo2_key_recipient(StanzaNode encrypted_node, Jid jid, int device_id, string reason) {
        StanzaNode? header_node = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        fail_if(header_node == null, reason + ": missing OMEMO2 header");
        if (header_node == null) return;

        int key_count = 0;
        string jid_string = jid.bare_jid.to_string();
        foreach (StanzaNode keys_node in ((!) header_node).get_subnodes("keys", NS_OMEMO_V2)) {
            fail_if(keys_node.get_attribute("jid") != jid_string,
                @"$reason: unexpected OMEMO2 recipient JID $(keys_node.get_attribute("jid") ?? "(null)")");
            foreach (StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                key_count++;
                int rid = key_node.get_attribute_int("rid");
                fail_if(rid != device_id, @"$reason: unexpected OMEMO2 recipient device $rid");
            }
        }
        fail_if(key_count != 1, @"$reason: expected exactly one OMEMO2 key recipient, got $key_count");
    }

    private static void seed_trusted_roster_contact(Dino.Database db, Account account, Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, jid.bare_jid.to_string())
            .value(db.roster.subscription, Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private static int count_receive_temp_files_for_basename(string directory_path, string basename) throws Error {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return 0;

        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            string name = ((!) child_info).get_name();
            if ((name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) ||
                    name.has_prefix(".download-encrypted-")) {
                count++;
            }
        }
        enumerator.close();
        return count;
    }

    private static void assert_no_receive_temp_files(string directory_path, string basename, string reason) throws Error {
        fail_if(count_receive_temp_files_for_basename(directory_path, basename) != 0, reason);
    }

    private static void assert_directory_empty_or_missing(string directory_path, string reason) throws Error {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return;
        fail_if(count_files_recursively(directory) != 0, reason);
    }

    private static int count_files_recursively(File file) throws Error {
        if (!file.query_exists()) return 0;
        FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type != FileType.DIRECTORY) return 1;

        FileEnumerator enumerator = file.enumerate_children(
            FileAttribute.STANDARD_NAME,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? info;
        while ((info = enumerator.next_file()) != null) {
            count += count_files_recursively(file.get_child(((!) info).get_name()));
        }
        enumerator.close();
        return count;
    }

    private static HashSet<string> snapshot_temp_files_with_prefix(string directory_path, string prefix) {
        var result = new HashSet<string>();
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return result;

        FileEnumerator? enumerator = null;
        try {
            enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = ((!) enumerator).next_file()) != null) {
                string name = ((!) child_info).get_name();
                if (name.has_prefix(prefix)) result.add(name);
            }
        } catch (Error e) {
            return result;
        } finally {
            if (enumerator != null) {
                try { ((!) enumerator).close(null); } catch (Error e) {}
            }
        }
        return result;
    }

    private static void assert_no_new_temp_files_with_prefix(HashSet<string> before, string prefix, string reason) {
        foreach (string name in snapshot_temp_files_with_prefix(Environment.get_tmp_dir(), prefix)) {
            fail_if(!before.contains(name), reason + @": $name");
        }
    }

    private static void delete_receive_pending_files_for_basename(string directory_path, string basename) {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return;

        FileEnumerator? enumerator = null;
        try {
            enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = ((!) enumerator).next_file()) != null) {
                string name = ((!) child_info).get_name();
                if (name.has_prefix(".download-") && name.contains(basename)) {
                    try {
                        directory.get_child(name).delete(null);
                    } catch (Error e) {
                    }
                }
            }
        } catch (Error e) {
        } finally {
            if (enumerator != null) {
                try { ((!) enumerator).close(null); } catch (Error e) {}
            }
        }
    }

    private static string configure_isolated_storage() throws IOError {
        string storage_dir = FileManager.get_storage_dir();
        if (!is_meson_test_storage_dir(storage_dir)) {
            throw new IOError.PERMISSION_DENIED(@"real OMEMO1/JET S5B FileManager proof refuses to use non-test storage directory '$storage_dir'");
        }
        return storage_dir;
    }

    private static bool process_xdg_dirs_are_isolated_or_skip() {
        string? xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        if (xdg_data_home != null &&
                xdg_cache_home != null &&
                Path.get_basename((!) xdg_data_home) == "test-xdg-data" &&
                Path.get_basename((!) xdg_cache_home) == "test-xdg-cache") {
            return true;
        }

        GLib.Test.skip("Run through Meson or start the process with XDG_DATA_HOME ending in test-xdg-data and XDG_CACHE_HOME ending in test-xdg-cache");
        return false;
    }

    private static bool is_path_at_or_below(string path, string parent) {
        string normalized_parent = parent.has_suffix(Path.DIR_SEPARATOR_S) ? parent.substring(0, parent.length - 1) : parent;
        return path == normalized_parent || path.has_prefix(normalized_parent + Path.DIR_SEPARATOR_S);
    }

    private static bool is_meson_test_storage_dir(string storage_dir) {
        return Path.get_basename(storage_dir) == "files" &&
            Path.get_basename(Path.get_dirname(storage_dir)) == "dinox" &&
            Path.get_basename(Path.get_dirname(Path.get_dirname(storage_dir))) == "test-xdg-data";
    }

    private static string? get_checked_plaintext_lease_root(string temp_dir, string storage_dir) throws IOError {
        string root = Path.build_filename(Environment.get_user_cache_dir(), "dinox", "temp_plaintext");
        string expected_xdg_cache_home = Path.build_filename(temp_dir, "xdg-cache");
        if (!is_path_at_or_below(root, expected_xdg_cache_home) && !is_meson_test_plaintext_lease_root(root)) {
            if (is_path_at_or_below(storage_dir, Path.build_filename(temp_dir, "xdg-data"))) {
                GLib.Test.skip(@"GLib cached user cache root '$root' before the test could isolate XDG_CACHE_HOME; run through meson test or set XDG_CACHE_HOME before process start");
                return null;
            }
            throw new IOError.PERMISSION_DENIED(@"real OMEMO1/JET S5B FileManager proof refuses to use non-test plaintext lease root '$root'");
        }
        return root;
    }

    private static bool is_meson_test_plaintext_lease_root(string root) {
        return Path.get_basename(root) == "temp_plaintext" &&
            Path.get_basename(Path.get_dirname(root)) == "dinox" &&
            Path.get_basename(Path.get_dirname(Path.get_dirname(root))) == "test-xdg-cache";
    }

    private static void cleanup_file(string path) {
        if (FileUtils.test(path, FileTest.EXISTS)) {
            FileUtils.remove(path);
        }
    }

    private static void delete_file_tree(File file) throws Error {
        if (!file.query_exists()) return;
        FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            FileEnumerator enumerator = file.enumerate_children(
                FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = enumerator.next_file()) != null) {
                delete_file_tree(file.get_child(((!) info).get_name()));
            }
            enumerator.close();
        }
        file.delete();
    }

    private static bool bytes_equal(uint8[] a, uint8[] b) {
        if (a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}

private class JingleS5bJetOmemoTestStream : XmppStream {
    public ArrayList<StanzaNode> written_nodes = new ArrayList<StanzaNode>();
    public int device_list_request_count { get; private set; default = 0; }
    private string? device_owner = null;
    private int32 device_id = 0;
    private bool device_list_uses_omemo2 = false;
    public StanzaNode? own_bundle { get; private set; default = null; }
    private string? own_owner = null;
    private string? own_bundle_node = null;

    public void set_own_bundle_owner(Jid owner, int32 own_device_id) {
        own_owner = owner.bare_jid.to_string();
        own_bundle_node = @"eu.siacs.conversations.axolotl.bundles:$own_device_id";
    }

    public JingleS5bJetOmemoTestStream(Jid remote_name) {
        base(remote_name);
    }

    public void set_device_list(Jid owner, int32 device_id, bool use_omemo2) {
        assert(device_id > 0);
        device_owner = owner.bare_jid.to_string();
        this.device_id = device_id;
        device_list_uses_omemo2 = use_omemo2;
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
        written_nodes.add(node);
        if (node.name != "iq") return;
        StanzaNode? pubsub = node.get_subnode("pubsub", Pubsub.NS_URI);
        if (respond_own_bundle(node, pubsub)) return;
        if (node.get_attribute("type") != Iq.Stanza.TYPE_GET) return;
        StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", Pubsub.NS_URI) : null;
        if (items == null) return;
        const string LEGACY_DEVICE_NODE = "eu.siacs.conversations.axolotl.devicelist";
        const string OMEMO2_DEVICE_NODE = "urn:xmpp:omemo:2:devices";
        string? requested_node = ((!) items).get_attribute("node");
        if (requested_node != LEGACY_DEVICE_NODE && requested_node != OMEMO2_DEVICE_NODE) return;
        device_list_request_count++;
        string expected_node = device_list_uses_omemo2 ? OMEMO2_DEVICE_NODE : LEGACY_DEVICE_NODE;
        // Unexpected refreshes must fail here rather than leave a timer in a later test.
        assert(device_owner != null && node.get_attribute("to") == device_owner);
        assert(requested_node == expected_node);
        string device_ns = device_list_uses_omemo2 ? "urn:xmpp:omemo:2" : "eu.siacs.conversations.axolotl";
        string payload_name = device_list_uses_omemo2 ? "devices" : "list";

        string? id = node.get_attribute("id");
        assert(id != null);
        var result = new StanzaNode.build("iq", "jabber:client")
            .put_attribute("type", Iq.Stanza.TYPE_RESULT)
            .put_attribute("id", (!) id)
            .put_attribute("from", (!) device_owner);
        string? from = node.get_attribute("from");
        if (from != null) result.put_attribute("to", (!) from);
        result.put_node(new StanzaNode.build("pubsub", Pubsub.NS_URI).add_self_xmlns()
            .put_node(new StanzaNode.build("items", Pubsub.NS_URI).put_attribute("node", expected_node)
                .put_node(new StanzaNode.build("item", Pubsub.NS_URI).put_attribute("id", "current")
                    .put_node(new StanzaNode.build(payload_name, device_ns).add_self_xmlns()
                        .put_node(new StanzaNode.build("device", device_ns)
                            .put_attribute("id", device_id.to_string()))))));
        received_iq_stanza(this, result);
    }

    private bool respond_own_bundle(StanzaNode request, StanzaNode? pubsub) {
        if (own_owner == null || own_bundle_node == null) return false;
        StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", Pubsub.NS_URI) : null;
        if (items != null && ((!) items).get_attribute("node") == own_bundle_node) {
            assert(request.get_attribute("to") == own_owner);
            var response_items = new StanzaNode.build("items", Pubsub.NS_URI)
                    .put_attribute("node", (!) own_bundle_node);
            if (own_bundle != null) {
                response_items.put_node(new StanzaNode.build("item", Pubsub.NS_URI)
                        .put_attribute("id", "current").put_node((!) own_bundle));
            }
            respond_iq(request, new StanzaNode.build("pubsub", Pubsub.NS_URI)
                    .add_self_xmlns().put_node(response_items));
            return true;
        }
        StanzaNode? publish = pubsub != null ? ((!) pubsub).get_subnode("publish", Pubsub.NS_URI) : null;
        if (publish != null && ((!) publish).get_attribute("node") == own_bundle_node) {
            StanzaNode? item = ((!) publish).get_subnode("item", Pubsub.NS_URI);
            assert(item != null);
            own_bundle = ((!) item).get_subnode("bundle", "eu.siacs.conversations.axolotl");
            assert(own_bundle != null);
            respond_iq(request, null);
            return true;
        }
        StanzaNode? retract = pubsub != null ? ((!) pubsub).get_subnode("retract", Pubsub.NS_URI) : null;
        if (retract != null && ((!) retract).get_attribute("node") == own_bundle_node) {
            respond_iq(request, null);
            return true;
        }
        const string OWNER_NS = "http://jabber.org/protocol/pubsub#owner";
        StanzaNode? owner = request.get_subnode("pubsub", OWNER_NS);
        StanzaNode? configure = owner != null ? ((!) owner).get_subnode("configure", OWNER_NS) : null;
        if (configure == null || ((!) configure).get_attribute("node") != own_bundle_node) return false;
        if (request.get_attribute("type") == Iq.Stanza.TYPE_GET) {
            const string FORM_NS = "jabber:x:data";
            var form = new StanzaNode.build("x", FORM_NS).add_self_xmlns().put_attribute("type", "form")
                    .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "FORM_TYPE")
                            .put_attribute("type", "hidden").put_node(new StanzaNode.build("value", FORM_NS)
                                    .put_node(new StanzaNode.text(Pubsub.NS_URI + "#node_config"))))
                    .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "pubsub#access_model")
                            .put_node(new StanzaNode.build("value", FORM_NS).put_node(new StanzaNode.text("open"))));
            respond_iq(request, new StanzaNode.build("pubsub", OWNER_NS).add_self_xmlns()
                    .put_node(new StanzaNode.build("configure", OWNER_NS)
                            .put_attribute("node", (!) own_bundle_node).put_node(form)));
        } else {
            respond_iq(request, null);
        }
        return true;
    }

    private void respond_iq(StanzaNode request, StanzaNode? payload) {
        string? id = request.get_attribute("id");
        assert(id != null);
        var result = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("type", Iq.Stanza.TYPE_RESULT).put_attribute("id", (!) id)
                .put_attribute("from", (!) own_owner);
        string? from = request.get_attribute("from");
        if (from != null) result.put_attribute("to", (!) from);
        if (payload != null) result.put_node((!) payload);
        received_iq_stanza(this, result);
    }

    public override async void setup() throws IOError {
    }
}

private class JingleEncryptionLossCapsCache : Object, ServiceDiscovery.CapsCache {
    public bool has_jet = true;

    public async bool has_entity_feature(Jid jid, string feature) {
        if (feature == "urn:xmpp:jingle:jet-omemo:0" || feature == Jet.NS_URI) return has_jet;
        return true;
    }

    public async Gee.Set<ServiceDiscovery.Identity> get_entity_identities(Jid jid) {
        return new HashSet<ServiceDiscovery.Identity>();
    }
}

}
