using Dino.Entities;
using Dino;
using Gee;
using Xmpp;

namespace OpenPgp.Test {

class RemoteOpenPgpPrivateMucHttpSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 120;
    private const string MUC_ADMIN_NS_URI = "http://jabber.org/protocol/muc#admin";
    private const string MUC_OWNER_NS_URI = "http://jabber.org/protocol/muc#owner";
    private const string NS_OPENPGP = "urn:xmpp:openpgp:0";
    private const string NS_OPENPGP_LEGACY = "jabber:x:encrypted";

    private enum OpenPgpSmokeKeySetup {
        SEEDED,
        PUBSUB_DISCOVERY,
        LEGACY_XEP0027
    }

    public RemoteOpenPgpPrivateMucHttpSmokeTest() {
        base("RemoteOpenPgpPrivateMucHttpSmoke");
        add_test("private_muc_xep0374_http_send_receive_env", test_private_muc_xep0374_http_send_receive_env_sync);
        add_test("private_muc_xep0374_pubsub_http_send_receive_env", test_private_muc_xep0374_pubsub_http_send_receive_env_sync);
        add_test("private_muc_xep0027_http_send_receive_env", test_private_muc_xep0027_http_send_receive_env_sync);
        add_test("direct_xep0374_http_sender_env", test_direct_xep0374_http_sender_env_sync);
        add_test("direct_xep0027_http_sender_env", test_direct_xep0027_http_sender_env_sync);
    }

    private void test_private_muc_xep0374_http_send_receive_env_sync() {
        run_private_muc_xep0374_http_send_receive_env_sync(OpenPgpSmokeKeySetup.SEEDED);
    }

    private void test_private_muc_xep0374_pubsub_http_send_receive_env_sync() {
        run_private_muc_xep0374_http_send_receive_env_sync(OpenPgpSmokeKeySetup.PUBSUB_DISCOVERY);
    }

    private void test_private_muc_xep0027_http_send_receive_env_sync() {
        run_private_muc_xep0374_http_send_receive_env_sync(OpenPgpSmokeKeySetup.LEGACY_XEP0027);
    }

    private void test_direct_xep0374_http_sender_env_sync() {
        run_direct_openpgp_http_sender_env_sync(false);
    }

    private void test_direct_xep0027_http_sender_env_sync() {
        run_direct_openpgp_http_sender_env_sync(true);
    }

    private void run_direct_openpgp_http_sender_env_sync(bool legacy_xep0027) {
        RemoteOpenPgpDirectHttpSenderConfig? config = RemoteOpenPgpDirectHttpSenderConfig.from_env(legacy_xep0027);
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_direct_openpgp_http_sender.begin((!) config, (obj, res) => {
            try {
                run_direct_openpgp_http_sender.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OpenPGP $(config.key_setup_label()) direct HTTP sender-only smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void run_private_muc_xep0374_http_send_receive_env_sync(OpenPgpSmokeKeySetup key_setup) {
        RemoteOpenPgpPrivateMucHttpSmokeConfig? config = RemoteOpenPgpPrivateMucHttpSmokeConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_private_muc_xep0374_http_send.begin((!) config, key_setup, (obj, res) => {
            try {
                run_private_muc_xep0374_http_send.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OpenPGP $(key_setup_label(key_setup)) private-MUC HTTP file send smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_private_muc_xep0374_http_send(RemoteOpenPgpPrivateMucHttpSmokeConfig config,
            OpenPgpSmokeKeySetup key_setup) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-openpgp-muc-http-smoke-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        string? previous_gnupg_home = Environment.get_variable("GNUPGHOME");
        string? previous_isolated_gnupg = Environment.get_variable("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME");
        string? previous_helper_gnupg_home = GPGHelper.get_homedir_path();
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        StreamInteractor? stream_interactor = null;
        Account? sender_account = null;
        Account? receiver_account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        XmppStream? sender_stream = null;
        XmppStream? receiver_stream = null;
        Dino.Plugins.OpenPgp.Module? sender_openpgp_module_detached = null;
        Dino.Plugins.OpenPgp.Xep0373KeyManager? xep0373_manager = null;
        Xep.Muc.Module? sender_muc_module = null;
        Dino.Plugins.HttpFiles.FileProvider? http_provider = null;
        Dino.Plugins.HttpFiles.HttpFileSender? http_sender = null;
        FileTransfer? sent_transfer = null;
        FileTransfer? received_transfer = null;
        Conversation? sender_conversation = null;
        Conversation? receiver_conversation = null;
        Dino.Entities.Message? captured_body_url_message = null;
        string? captured_body_url = null;
        string? captured_openpgp_payload = null;
        string? captured_legacy_payload = null;
        string? captured_outer_body = null;
        string? captured_message_protocol = null;
        Jid? captured_stanza_to = null;
        string? captured_stanza_type = null;
        bool captured_has_outer_oob = false;
        bool captured_has_outer_sfs = false;
        bool captured_has_outer_sources = false;
        bool captured_has_outer_attach = false;
        Error? captured_stanza_error = null;
        Error? pending_error = null;
        Error? cleanup_error = null;
        Error? temp_cleanup_error = null;
        string sender_fpr = "";
        string receiver_fpr = "";
        ulong received_handler = 0;
        ulong pre_message_send_handler = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            configure_isolated_storage(temp_dir);
            string gnupg_home = Path.build_filename(temp_dir, "gnupg");
            DirUtils.create_with_parents(gnupg_home, 0700);
            Environment.set_variable("GNUPGHOME", gnupg_home, true);
            Environment.set_variable("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME", "1", true);
            GPGHelper.set_homedir_path_for_tests(gnupg_home);

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-openpgp-private-muc-http-smoke");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(Path.build_filename(temp_dir, "openpgp.db"), null);
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            Security.FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption, (!) openpgp_db);

            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OpenPGP private-MUC HTTP file smoke");
            }
            http_sender = new Dino.Plugins.HttpFiles.HttpFileSender((!) stream_interactor, (!) core_db);
            http_provider = new Dino.Plugins.HttpFiles.FileProvider((!) stream_interactor, (!) core_db);
            ((!) file_manager).add_provider((!) http_provider);
            ((!) file_manager).add_sender((!) http_sender);
            ((!) file_manager).add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor((!) stream_interactor));
            ((!) file_manager).add_file_decryptor(new Dino.Plugins.OpenPgp.PgpFileDecryptor((!) stream_interactor, (!) openpgp_db));

            sender_account = new Account(config.sender_jid.bare_jid, config.sender_password);
            ((!) sender_account).enabled = true;
            ((!) sender_account).custom_host = config.custom_host;
            ((!) sender_account).custom_port = config.custom_port;
            config.apply_account_proxy((!) sender_account);
            persist_remote_smoke_account_without_password((!) core_db, (!) sender_account);

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            config.apply_account_proxy((!) receiver_account);
            persist_remote_smoke_account_without_password((!) core_db, (!) receiver_account);

            seed_trusted_roster_contact((!) core_db, (!) sender_account, config.receiver_jid);
            seed_trusted_roster_contact((!) core_db, (!) receiver_account, config.sender_jid);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) stream_interactor).get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager was not started for remote OpenPGP private-MUC HTTP file smoke");
            }
            install_openpgp_account_modules((!) stream_interactor, (!) openpgp_db, (!) pgp_manager);

            if (key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027) {
                sender_fpr = generate_temporary_legacy_key_for(config.sender_jid, "DinoX remote legacy OpenPGP sender");
                receiver_fpr = generate_temporary_legacy_key_for(config.receiver_jid, "DinoX remote legacy OpenPGP receiver");
            } else {
                sender_fpr = generate_temporary_xmpp_key_for(config.sender_jid, "DinoX remote OpenPGP sender");
                receiver_fpr = generate_temporary_xmpp_key_for(config.receiver_jid, "DinoX remote OpenPGP receiver");
            }
            if (sender_fpr == receiver_fpr) {
                throw new IOError.FAILED("temporary OpenPGP test keys must be distinct");
            }
            string? sender_key_data_base64 = null;
            string? receiver_key_data_base64 = null;
            if (key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027) {
                ((!) openpgp_db).set_account_legacy_key((!) sender_account, sender_fpr);
                ((!) openpgp_db).set_account_legacy_key((!) receiver_account, receiver_fpr);
                ((!) openpgp_db).set_contact_key((!) sender_account, config.receiver_jid.bare_jid, receiver_fpr,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
                ((!) openpgp_db).set_contact_key((!) receiver_account, config.sender_jid.bare_jid, sender_fpr,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
                if (((!) openpgp_db).has_contact_xmpp_key((!) sender_account, config.receiver_jid.bare_jid) ||
                        ((!) openpgp_db).has_contact_xmpp_key((!) receiver_account, config.sender_jid.bare_jid)) {
                    throw new IOError.FAILED("remote OpenPGP XEP-0027 smoke must not seed XEP-0373/XEP-0374 contact-key state");
                }
            } else {
                ((!) openpgp_db).set_account_xmpp_key((!) sender_account, sender_fpr);
                ((!) openpgp_db).set_account_xmpp_key((!) receiver_account, receiver_fpr);
            }
            if (key_setup == OpenPgpSmokeKeySetup.SEEDED) {
                ((!) openpgp_db).set_contact_key((!) sender_account, config.receiver_jid.bare_jid, receiver_fpr,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
                ((!) openpgp_db).set_contact_key((!) receiver_account, config.sender_jid.bare_jid, sender_fpr,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
                ((!) openpgp_db).mark_contact_xmpp_key_verified((!) sender_account, config.receiver_jid.bare_jid);
                ((!) pgp_manager).mark_xep0373_key_received((!) sender_account, config.receiver_jid.bare_jid);
                ((!) openpgp_db).mark_contact_xmpp_key_verified((!) receiver_account, config.sender_jid.bare_jid);
                ((!) pgp_manager).mark_xep0373_key_received((!) receiver_account, config.sender_jid.bare_jid);
            } else if (key_setup == OpenPgpSmokeKeySetup.PUBSUB_DISCOVERY) {
                sender_key_data_base64 = export_public_key_data_base64_checked(sender_fpr, "sender");
                receiver_key_data_base64 = export_public_key_data_base64_checked(receiver_fpr, "receiver");
            }

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) sender_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) receiver_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) {
                throw new IOError.FAILED("MucManager was not started for remote OpenPGP private-MUC HTTP file smoke");
            }
            ConversationManager? conversation_manager = ((!) stream_interactor).get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (conversation_manager == null) {
                throw new IOError.FAILED("ConversationManager was not started for remote OpenPGP private-MUC HTTP file smoke");
            }
            MessageProcessor? message_processor = ((!) stream_interactor).get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            if (message_processor == null) {
                throw new IOError.FAILED("MessageProcessor was not started for remote OpenPGP private-MUC HTTP file smoke");
            }

            sender_stream = ((!) stream_interactor).get_stream((!) sender_account);
            if (sender_stream == null) {
                throw new IOError.NOT_CONNECTED("No sender stream after XMPP negotiation");
            }
            receiver_stream = ((!) stream_interactor).get_stream((!) receiver_account);
            if (receiver_stream == null) {
                throw new IOError.NOT_CONNECTED("No receiver stream after XMPP negotiation");
            }
            if (key_setup == OpenPgpSmokeKeySetup.PUBSUB_DISCOVERY) {
                xep0373_manager = install_xep0373_key_manager_for_smoke((!) stream_interactor, (!) openpgp_db, (!) pgp_manager);
                yield prepare_xep0373_pubsub_discovery((!) openpgp_db, (!) pgp_manager, (!) xep0373_manager,
                    (!) sender_account, (!) sender_stream, sender_fpr, (!) sender_key_data_base64,
                    (!) receiver_account, (!) receiver_stream, receiver_fpr, (!) receiver_key_data_base64,
                    config.timeout_seconds);
            } else if (key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027) {
                yield wait_for_legacy_presence_discovery((!) openpgp_db, (!) sender_account, (!) receiver_account, config, config.timeout_seconds);
            }
            sender_muc_module = ((!) sender_stream).get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            if (sender_muc_module == null) {
                throw new IOError.FAILED("XEP-0045 MUC module is not attached to sender stream");
            }

            yield join_generated_room((!) sender_stream, (!) sender_muc_module, config);
            Xep.DataForms.DataForm? data_form = yield ((!) sender_muc_module).get_config_form((!) sender_stream, config.room_jid.bare_jid);
            if (data_form == null) {
                throw new IOError.FAILED("remote generated OpenPGP private-MUC config form was not available");
            }
            configure_generated_private_room((!) data_form);
            yield set_config_form_checked((!) sender_stream, config.room_jid.bare_jid, (!) data_form);
            yield change_affiliation_checked((!) sender_stream, config.room_jid.bare_jid, config.receiver_jid.bare_jid, "member");

            yield join_room((!) muc_manager, (!) receiver_account, config.room_jid.bare_jid, config.receiver_nick, config.timeout_seconds);

            sender_conversation = ((!) conversation_manager).create_conversation(
                    config.room_jid.bare_jid, (!) sender_account, Conversation.Type.GROUPCHAT);
            ((!) sender_conversation).nickname = config.sender_nick;
            ((!) sender_conversation).encryption = Encryption.PGP;
            ((!) sender_conversation).send_typing = Conversation.Setting.OFF;
            ((!) sender_conversation).send_marker = Conversation.Setting.OFF;

            Conversation? maybe_receiver_conversation = ((!) conversation_manager).get_conversation(
                    config.room_jid.bare_jid, (!) receiver_account, Conversation.Type.GROUPCHAT);
            if (maybe_receiver_conversation == null) {
                throw new IOError.FAILED("receiver account did not create the private-MUC conversation after join");
            }
            receiver_conversation = (!) maybe_receiver_conversation;
            ((!) receiver_conversation).encryption = Encryption.PGP;
            ((!) receiver_conversation).send_typing = Conversation.Setting.OFF;
            ((!) receiver_conversation).send_marker = Conversation.Setting.OFF;

            Gee.List<Jid>? snapshot = yield ((!) muc_manager).query_private_muc_affiliation_snapshot((!) sender_account, config.room_jid.bare_jid);
            validate_private_muc_snapshot((!) muc_manager, (!) sender_account, config.room_jid.bare_jid, snapshot, config);
            string readiness_reason = "";
            Gee.List<Jid> recipients;
            if (!((!) pgp_manager).try_get_private_muc_file_recipient_key_readiness((!) sender_conversation, out recipients, out readiness_reason)) {
                throw new IOError.FAILED("OpenPGP private-MUC recipient key readiness failed before send: " + readiness_reason);
            }
            if (recipients.size != 1 || !recipients[0].bare_jid.equals(config.receiver_jid.bare_jid)) {
                throw new IOError.FAILED("OpenPGP private-MUC recipient readiness did not resolve exactly the configured receiver");
            }
            if (!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode((!) sender_conversation, out readiness_reason)) {
                throw new IOError.FAILED("OpenPGP selected-mode readiness failed before send");
            }

            Jid sender_occupant_jid = config.room_jid.bare_jid.with_resource(config.sender_nick);
            if (!(yield wait_for_condition(config.timeout_seconds, () => {
                    Jid? sender_real_jid = ((!) muc_manager).get_real_jid(sender_occupant_jid, (!) receiver_account);
                    return sender_real_jid != null && ((!) sender_real_jid).bare_jid.equals(config.sender_jid.bare_jid);
                }))) {
                throw new IOError.TIMED_OUT("timed out waiting for receiver-side private-MUC real-JID mapping for the sender occupant");
            }

            if (key_setup != OpenPgpSmokeKeySetup.LEGACY_XEP0027) {
                // Keep the receiver connected for the real incoming decrypt/download path, and
                // detach only the sender module's receive hooks while keeping it available for
                // Manager.check_encypt() -> Module.encrypt_0374().
                sender_openpgp_module_detached = ((!) sender_stream).get_module<Dino.Plugins.OpenPgp.Module>(
                    Dino.Plugins.OpenPgp.Module.IDENTITY);
                if (sender_openpgp_module_detached == null) {
                    throw new IOError.FAILED("OpenPGP stream module is not attached to sender stream");
                }
                ((!) sender_openpgp_module_detached).detach((!) sender_stream);
            }

            if (!(yield wait_for_upload_available((!) file_manager, (!) sender_conversation, config.timeout_seconds))) {
                throw new IOError.TIMED_OUT("timed out waiting for HTTP upload availability on sender account");
            }

            var phases = new Gee.ArrayList<FileTransfer.Phase>();
            received_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (!conversation.counterpart.equals_bare(config.room_jid.bare_jid)) return;
                if (Account.equals_func(file_transfer.account, (!) sender_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_SENT) {
                    sent_transfer = file_transfer;
                } else if (Account.equals_func(file_transfer.account, (!) receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
                    received_transfer = file_transfer;
                    receiver_conversation = conversation;
                }
            });
            pre_message_send_handler = ((!) message_processor).pre_message_send.connect((message, stanza, conversation) => {
                if (captured_body_url_message != null) return;
                if (sender_conversation == null || conversation != (!) sender_conversation) return;
                if (message.encryption != Encryption.PGP) return;
                if (message.body == null || !(((string) message.body).has_prefix("http://") || ((string) message.body).has_prefix("https://"))) return;
                captured_body_url_message = message;
                captured_body_url = message.body;
                captured_outer_body = stanza.body;
                captured_message_protocol = message.encryption_protocol;
                captured_stanza_to = stanza.to;
                captured_stanza_type = stanza.type_;
                captured_has_outer_oob = stanza.stanza.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null;
                captured_has_outer_sfs = stanza.stanza.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_sources = stanza.stanza.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_attach = stanza.stanza.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null;
                Xmpp.StanzaNode? openpgp_node = stanza.stanza.get_subnode("openpgp", NS_OPENPGP);
                captured_openpgp_payload = openpgp_node != null ? ((!) openpgp_node).get_string_content() : null;
                Xmpp.StanzaNode? legacy_node = stanza.stanza.get_subnode("x", NS_OPENPGP_LEGACY);
                captured_legacy_payload = legacy_node != null ? ((!) legacy_node).get_string_content() : null;
                try {
                    stanza.stanza.to_xml();
                } catch (Error e) {
                    captured_stanza_error = e;
                }
            });

            string payload_path = Path.build_filename(temp_dir, config.payload_name);
            FileUtils.set_contents(payload_path, config.payload_text);
            string expected_sha256 = Checksum.compute_for_string(ChecksumType.SHA256, config.payload_text);
            yield ((!) file_manager).send_file(File.new_for_path(payload_path), (!) sender_conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });
            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    sent_transfer != null &&
                    ((!) sent_transfer).state == FileTransfer.State.COMPLETE &&
                    ((!) sent_transfer).phase == FileTransfer.Phase.COMPLETE &&
                    received_transfer != null &&
                    ((!) received_transfer).state == FileTransfer.State.COMPLETE &&
                    ((!) received_transfer).phase == FileTransfer.Phase.COMPLETE &&
                    captured_body_url_message != null &&
                    message_reached_remote_send_boundary((!) captured_body_url_message)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote OpenPGP private-MUC HTTP send/receive completion (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)), message=$(format_message_marked(captured_body_url_message)))");
            }
            if (captured_stanza_error != null) throw (!) captured_stanza_error;
            drain_pending_events();

            FileTransfer transfer = (!) sent_transfer;
            FileTransfer receiver_transfer = (!) received_transfer;
            validate_sent_transfer(transfer, (!) sender_conversation, config, key_setup);
            validate_received_transfer(receiver_transfer, (!) receiver_conversation, config, key_setup);
            assert_phase_order(phases, FileTransfer.Phase.STORING, FileTransfer.Phase.ENCRYPTING,
                "remote OpenPGP send must store the local copy before PGP encryption");
            assert_phase_order(phases, FileTransfer.Phase.ENCRYPTING, FileTransfer.Phase.REQUESTING_SLOT,
                "remote OpenPGP send must encrypt before requesting the XEP-0363 slot");
            assert_phase_order(phases, FileTransfer.Phase.REQUESTING_SLOT, FileTransfer.Phase.UPLOADING,
                "remote OpenPGP send must request the slot before HTTPS upload");
            assert_phase_order(phases, FileTransfer.Phase.UPLOADING, FileTransfer.Phase.ANNOUNCING,
                "remote OpenPGP send must upload before the body-url announcement");
            assert_phase_order(phases, FileTransfer.Phase.ANNOUNCING, FileTransfer.Phase.COMPLETE,
                "remote OpenPGP send must finish after the encrypted body-url announcement");

            string download_url = require_single_http_source(transfer);
            if (captured_body_url == null || ((!) captured_body_url) != download_url) {
                throw new IOError.FAILED("remote OpenPGP body-url message did not use the persisted HTTP source URL");
            }
            if (key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027) {
                validate_captured_legacy_body_url_message((!) captured_body_url_message, captured_openpgp_payload,
                    (!) captured_legacy_payload, captured_outer_body, captured_message_protocol, captured_stanza_to,
                    captured_stanza_type, captured_has_outer_oob, captured_has_outer_sfs, captured_has_outer_sources,
                    captured_has_outer_attach, download_url, config.room_jid.bare_jid, sender_fpr, receiver_fpr);
            } else {
                validate_captured_openpgp_body_url_message((!) captured_body_url_message, (!) captured_openpgp_payload,
                    captured_outer_body, captured_message_protocol, captured_stanza_to, captured_stanza_type,
                    captured_has_outer_oob, captured_has_outer_sfs,
                    captured_has_outer_sources, captured_has_outer_attach, download_url, config.room_jid.bare_jid,
                    sender_fpr, receiver_fpr);
            }

            uint8[] uploaded_pgp = yield download_remote_pgp(download_url, config.timeout_seconds);
            validate_downloaded_pgp_upload(temp_dir, uploaded_pgp, config, sender_fpr, receiver_fpr);
            yield validate_stored_payload(file_encryption, receiver_transfer, config.payload_text.length, expected_sha256);
            if (count_pending_receive_files((!) core_db) != 0) {
                throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receive-store left pending receive files");
            }

            if (received_handler != 0) {
                SignalHandler.disconnect((!) file_manager, received_handler);
                received_handler = 0;
            }
            if (pre_message_send_handler != 0) {
                SignalHandler.disconnect((!) message_processor, pre_message_send_handler);
                pre_message_send_handler = 0;
            }
            if (sender_openpgp_module_detached != null && sender_stream != null) {
                ((!) sender_openpgp_module_detached).attach((!) sender_stream);
                sender_openpgp_module_detached = null;
            }
            GLib.Test.message(@"Remote OpenPGP $(key_setup_label(key_setup)) private-MUC HTTP send/receive smoke passed for generated room $(config.room_jid.bare_jid.to_string())");
        } catch (Error e) {
            pending_error = e;
        }

        if (stream_interactor != null) {
            MessageProcessor? message_processor = ((!) stream_interactor).get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            if (message_processor != null && pre_message_send_handler != 0) {
                SignalHandler.disconnect((!) message_processor, pre_message_send_handler);
                pre_message_send_handler = 0;
            }
            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager != null && received_handler != 0) {
                SignalHandler.disconnect((!) file_manager, received_handler);
                received_handler = 0;
            }
        }
        if (http_sender != null) ((!) http_sender).shutdown();
        if (http_provider != null) ((!) http_provider).shutdown();
        if (sender_openpgp_module_detached != null && sender_stream != null) {
            ((!) sender_openpgp_module_detached).attach((!) sender_stream);
            sender_openpgp_module_detached = null;
        }

        if (sender_stream != null && sender_muc_module != null) {
            try {
                yield ((!) sender_muc_module).destroy_room((!) sender_stream, config.room_jid.bare_jid, "DinoX remote OpenPGP private-MUC HTTP file smoke cleanup");
            } catch (Error e) {
                cleanup_error = e;
                GLib.Test.message(@"Could not destroy generated remote OpenPGP private-MUC HTTP smoke room $(config.room_jid.bare_jid.to_string()): $(e.message)");
                ((!) sender_muc_module).exit((!) sender_stream, config.room_jid.bare_jid);
            }
        }
        if (key_setup == OpenPgpSmokeKeySetup.PUBSUB_DISCOVERY) {
            if (sender_stream != null && sender_fpr != "") {
                if (!(yield unpublish_xep0373_key((!) sender_stream, sender_fpr))) {
                    GLib.Test.message("Could not retract sender XEP-0373 key metadata after remote OpenPGP PubSub smoke");
                    if (cleanup_error == null) {
                        cleanup_error = new IOError.FAILED("could not retract sender XEP-0373 key metadata after remote OpenPGP PubSub smoke");
                    }
                }
            }
            if (receiver_stream != null && receiver_fpr != "") {
                if (!(yield unpublish_xep0373_key((!) receiver_stream, receiver_fpr))) {
                    GLib.Test.message("Could not retract receiver XEP-0373 key metadata after remote OpenPGP PubSub smoke");
                    if (cleanup_error == null) {
                        cleanup_error = new IOError.FAILED("could not retract receiver XEP-0373 key metadata after remote OpenPGP PubSub smoke");
                    }
                }
            }
        }
        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) receiver_account);
        }
        if (stream_interactor != null && sender_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) sender_account);
        }
        restore_default_application(application, previous_application);
        if (openpgp_db != null) {
            ((!) openpgp_db).close();
            openpgp_db = null;
        }
        if (core_db != null) {
            ((!) core_db).close();
            core_db = null;
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);
        restore_env_var("GNUPGHOME", previous_gnupg_home);
        restore_env_var("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME", previous_isolated_gnupg);
        GPGHelper.set_homedir_path_for_tests(previous_helper_gnupg_home);
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote OpenPGP private-MUC HTTP smoke temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, cleanup_error, temp_cleanup_error, config.room_jid.bare_jid, temp_dir);
    }

    private async void run_direct_openpgp_http_sender(RemoteOpenPgpDirectHttpSenderConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-openpgp-direct-http-sender-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        string? previous_gnupg_home = Environment.get_variable("GNUPGHOME");
        string? previous_isolated_gnupg = Environment.get_variable("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME");
        string? previous_helper_gnupg_home = GPGHelper.get_homedir_path();
        Dino.Database? core_db = null;
        Dino.Plugins.OpenPgp.Database? openpgp_db = null;
        StreamInteractor? stream_interactor = null;
        Account? sender_account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        XmppStream? sender_stream = null;
        Dino.Plugins.HttpFiles.FileProvider? http_provider = null;
        Dino.Plugins.HttpFiles.HttpFileSender? http_sender = null;
        FileTransfer? sent_transfer = null;
        Conversation? sender_conversation = null;
        Dino.Entities.Message? captured_body_url_message = null;
        string? captured_body_url = null;
        string? captured_openpgp_payload = null;
        string? captured_legacy_payload = null;
        string? captured_outer_body = null;
        string? captured_message_protocol = null;
        Jid? captured_stanza_to = null;
        string? captured_stanza_type = null;
        bool captured_has_outer_oob = false;
        bool captured_has_outer_sfs = false;
        bool captured_has_outer_sources = false;
        bool captured_has_outer_attach = false;
        Error? captured_stanza_error = null;
        Error? pending_error = null;
        Error? cleanup_error = null;
        Error? temp_cleanup_error = null;
        bool sender_key_published = false;
        ulong sent_handler = 0;
        ulong pre_message_send_handler = 0;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            configure_isolated_storage(temp_dir);
            string gnupg_home = Path.build_filename(temp_dir, "gnupg");
            DirUtils.create_with_parents(gnupg_home, 0700);
            Environment.set_variable("GNUPGHOME", gnupg_home, true);
            Environment.set_variable("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME", "1", true);
            GPGHelper.set_homedir_path_for_tests(gnupg_home);

            import_armored_key_file(config.sender_secret_key_file, "sender secret key");
            import_armored_key_file(config.receiver_public_key_file, "receiver public key");
            if (config.legacy_xep0027) {
                assert_openpgp_private_legacy_key_ready(config.sender_fingerprint, "sender");
                assert_openpgp_public_legacy_key_ready(config.receiver_fingerprint, "receiver");
            } else {
                assert_openpgp_private_xmpp_key_ready(config.sender_fingerprint, config.sender_jid, "sender");
                assert_openpgp_public_xmpp_key_ready(config.receiver_fingerprint, config.receiver_jid, "receiver");
            }

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-openpgp-direct-http-sender");
            openpgp_db = new Dino.Plugins.OpenPgp.Database(Path.build_filename(temp_dir, "openpgp.db"), null);
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            Security.FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption, (!) openpgp_db);

            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OpenPGP direct HTTP sender smoke");
            }
            http_sender = new Dino.Plugins.HttpFiles.HttpFileSender((!) stream_interactor, (!) core_db);
            http_provider = new Dino.Plugins.HttpFiles.FileProvider((!) stream_interactor, (!) core_db);
            ((!) file_manager).add_provider((!) http_provider);
            ((!) file_manager).add_sender((!) http_sender);
            ((!) file_manager).add_file_encryptor(new Dino.Plugins.OpenPgp.PgpFileEncryptor((!) stream_interactor));

            sender_account = new Account(config.sender_jid.bare_jid, config.sender_password);
            ((!) sender_account).enabled = true;
            ((!) sender_account).custom_host = config.custom_host;
            ((!) sender_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) core_db, (!) sender_account);
            seed_trusted_roster_contact((!) core_db, (!) sender_account, config.receiver_jid);

            Dino.Plugins.OpenPgp.Manager? pgp_manager = ((!) stream_interactor).get_module<Dino.Plugins.OpenPgp.Manager>(
                Dino.Plugins.OpenPgp.Manager.IDENTITY);
            if (pgp_manager == null) {
                throw new IOError.FAILED("OpenPGP manager was not started for remote OpenPGP direct HTTP sender smoke");
            }
            install_openpgp_account_modules((!) stream_interactor, (!) openpgp_db, (!) pgp_manager);
            if (config.legacy_xep0027) {
                ((!) openpgp_db).set_account_legacy_key((!) sender_account, config.sender_fingerprint);
                ((!) openpgp_db).set_contact_key((!) sender_account, config.receiver_jid.bare_jid, config.receiver_fingerprint,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false, false);
                if (((!) openpgp_db).has_contact_xmpp_key((!) sender_account, config.receiver_jid.bare_jid)) {
                    throw new IOError.FAILED("remote OpenPGP direct XEP-0027 sender smoke must not seed XEP-0373/XEP-0374 contact-key state");
                }
            } else {
                ((!) openpgp_db).set_account_xmpp_key((!) sender_account, config.sender_fingerprint);
                ((!) openpgp_db).set_contact_key((!) sender_account, config.receiver_jid.bare_jid, config.receiver_fingerprint,
                    Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
                ((!) openpgp_db).mark_contact_xmpp_key_verified((!) sender_account, config.receiver_jid.bare_jid);
                ((!) pgp_manager).mark_xep0373_key_received((!) sender_account, config.receiver_jid.bare_jid);
            }

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) sender_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }
            if (config.legacy_xep0027) {
                yield wait_for_direct_legacy_presence_discovery((!) openpgp_db, (!) sender_account, config, config.timeout_seconds);
            }
            yield wait_for_direct_before_send_gate(config);
            assert_direct_after_send_hold_not_released(config);

            ConversationManager? conversation_manager = ((!) stream_interactor).get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (conversation_manager == null) {
                throw new IOError.FAILED("ConversationManager was not started for remote OpenPGP direct HTTP sender smoke");
            }
            MessageProcessor? message_processor = ((!) stream_interactor).get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            if (message_processor == null) {
                throw new IOError.FAILED("MessageProcessor was not started for remote OpenPGP direct HTTP sender smoke");
            }
            sender_stream = ((!) stream_interactor).get_stream((!) sender_account);
            if (sender_stream == null) {
                throw new IOError.NOT_CONNECTED("No sender stream after XMPP negotiation");
            }
            if (config.publish_sender_key) {
                Xmpp.Xep.OpenPgp.Module? openpgp_pubsub_module = ((!) sender_stream).get_module<Xmpp.Xep.OpenPgp.Module>(
                    Xmpp.Xep.OpenPgp.Module.IDENTITY);
                if (openpgp_pubsub_module == null) {
                    throw new IOError.FAILED("OpenPGP PubSub module is not attached to sender stream");
                }
                string sender_key_data_base64 = export_public_key_data_base64_checked(config.sender_fingerprint, "direct sender");
                if (!(yield ((!) openpgp_pubsub_module).publish_key_data((!) sender_stream, config.sender_fingerprint, sender_key_data_base64))) {
                    throw new IOError.FAILED("remote OpenPGP direct sender could not publish the sender XEP-0373 key");
                }
                sender_key_published = true;
            }

            sender_conversation = ((!) conversation_manager).create_conversation(
                    config.receiver_jid.bare_jid, (!) sender_account, Conversation.Type.CHAT);
            ((!) sender_conversation).encryption = Encryption.PGP;
            ((!) sender_conversation).send_typing = Conversation.Setting.OFF;
            ((!) sender_conversation).send_marker = Conversation.Setting.OFF;

            string readiness_reason = "";
            if (!((!) pgp_manager).can_encrypt_for_selected_openpgp_mode((!) sender_conversation, out readiness_reason)) {
                throw new IOError.FAILED("OpenPGP selected-mode readiness failed before direct sender-only send");
            }
            if (!(yield wait_for_upload_available((!) file_manager, (!) sender_conversation, config.timeout_seconds))) {
                throw new IOError.TIMED_OUT("timed out waiting for HTTP upload availability on sender account");
            }

            var phases = new Gee.ArrayList<FileTransfer.Phase>();
            sent_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (conversation != (!) sender_conversation) return;
                if (Account.equals_func(file_transfer.account, (!) sender_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_SENT) {
                    sent_transfer = file_transfer;
                }
            });
            pre_message_send_handler = ((!) message_processor).pre_message_send.connect((message, stanza, conversation) => {
                if (captured_body_url_message != null) return;
                if (sender_conversation == null || conversation != (!) sender_conversation) return;
                if (message.encryption != Encryption.PGP) return;
                if (message.body == null || !(((string) message.body).has_prefix("http://") || ((string) message.body).has_prefix("https://"))) return;
                captured_body_url_message = message;
                captured_body_url = message.body;
                captured_outer_body = stanza.body;
                captured_message_protocol = message.encryption_protocol;
                captured_stanza_to = stanza.to;
                captured_stanza_type = stanza.type_;
                captured_has_outer_oob = stanza.stanza.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null;
                captured_has_outer_sfs = stanza.stanza.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_sources = stanza.stanza.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_attach = stanza.stanza.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null;
                Xmpp.StanzaNode? openpgp_node = stanza.stanza.get_subnode("openpgp", NS_OPENPGP);
                captured_openpgp_payload = openpgp_node != null ? ((!) openpgp_node).get_string_content() : null;
                Xmpp.StanzaNode? legacy_node = stanza.stanza.get_subnode("x", NS_OPENPGP_LEGACY);
                captured_legacy_payload = legacy_node != null ? ((!) legacy_node).get_string_content() : null;
                try {
                    stanza.stanza.to_xml();
                } catch (Error e) {
                    captured_stanza_error = e;
                }
            });

            string payload_path = Path.build_filename(temp_dir, config.payload_name);
            FileUtils.set_contents(payload_path, config.payload_text);

            yield ((!) file_manager).send_file(File.new_for_path(payload_path), (!) sender_conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });
            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    sent_transfer != null &&
                    ((!) sent_transfer).state == FileTransfer.State.COMPLETE &&
                    ((!) sent_transfer).phase == FileTransfer.Phase.COMPLETE &&
                    captured_body_url_message != null &&
                    message_reached_remote_send_boundary((!) captured_body_url_message)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote OpenPGP direct HTTP sender completion (sent=$(format_transfer_state(sent_transfer)), message=$(format_message_marked(captured_body_url_message)))");
            }
            if (captured_stanza_error != null) throw (!) captured_stanza_error;
            drain_pending_events();

            FileTransfer transfer = (!) sent_transfer;
            validate_direct_sent_transfer(transfer, (!) sender_conversation, config);
            assert_phase_order(phases, FileTransfer.Phase.STORING, FileTransfer.Phase.ENCRYPTING,
                "remote OpenPGP direct send must store the local copy before PGP encryption");
            assert_phase_order(phases, FileTransfer.Phase.ENCRYPTING, FileTransfer.Phase.REQUESTING_SLOT,
                "remote OpenPGP direct send must encrypt before requesting the XEP-0363 slot");
            assert_phase_order(phases, FileTransfer.Phase.REQUESTING_SLOT, FileTransfer.Phase.UPLOADING,
                "remote OpenPGP direct send must request the slot before HTTPS upload");
            assert_phase_order(phases, FileTransfer.Phase.UPLOADING, FileTransfer.Phase.ANNOUNCING,
                "remote OpenPGP direct send must upload before the body-url announcement");
            assert_phase_order(phases, FileTransfer.Phase.ANNOUNCING, FileTransfer.Phase.COMPLETE,
                "remote OpenPGP direct send must finish after the encrypted body-url announcement");

            string download_url = require_single_http_source(transfer);
            if (captured_body_url == null || ((!) captured_body_url) != download_url) {
                throw new IOError.FAILED("remote OpenPGP direct body-url message did not use the persisted HTTP source URL");
            }
            if (!config.legacy_xep0027 && captured_openpgp_payload == null) {
                throw new IOError.FAILED("remote OpenPGP direct body-url stanza did not carry an XEP-0374 payload");
            }
            if (config.legacy_xep0027) {
                if (captured_legacy_payload == null) {
                    throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza did not carry a legacy encrypted payload");
                }
                validate_captured_direct_legacy_body_url_message((!) captured_body_url_message, captured_openpgp_payload,
                    (!) captured_legacy_payload, captured_outer_body, captured_message_protocol, captured_stanza_to,
                    captured_stanza_type, captured_has_outer_oob, captured_has_outer_sfs, captured_has_outer_sources,
                    captured_has_outer_attach, download_url, config.receiver_jid.bare_jid,
                    config.sender_fingerprint, config.receiver_fingerprint);
            } else {
                validate_captured_direct_openpgp_body_url_message((!) captured_body_url_message, (!) captured_openpgp_payload,
                    captured_outer_body, captured_message_protocol, captured_stanza_to, captured_stanza_type,
                    captured_has_outer_oob, captured_has_outer_sfs, captured_has_outer_sources, captured_has_outer_attach,
                    download_url, config.receiver_jid.bare_jid, config.sender_fingerprint, config.receiver_fingerprint);
            }

            uint8[] uploaded_pgp = yield download_remote_pgp(download_url, config.timeout_seconds);
            validate_downloaded_direct_pgp_upload(temp_dir, uploaded_pgp, config, config.sender_fingerprint, config.receiver_fingerprint);
            GLib.Test.message(@"Remote OpenPGP $(config.key_setup_label()) direct HTTP sender-only smoke passed");
            yield wait_for_direct_after_send_hold(config);
        } catch (Error e) {
            pending_error = e;
        }

        if (stream_interactor != null) {
            MessageProcessor? message_processor = ((!) stream_interactor).get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            if (message_processor != null && pre_message_send_handler != 0) {
                SignalHandler.disconnect((!) message_processor, pre_message_send_handler);
                pre_message_send_handler = 0;
            }
            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager != null && sent_handler != 0) {
                SignalHandler.disconnect((!) file_manager, sent_handler);
                sent_handler = 0;
            }
        }
        if (http_sender != null) ((!) http_sender).shutdown();
        if (http_provider != null) ((!) http_provider).shutdown();
        if (sender_key_published && !config.keep_published_sender_key && sender_stream != null) {
            if (!(yield unpublish_xep0373_key((!) sender_stream, config.sender_fingerprint))) {
                cleanup_error = new IOError.FAILED("could not retract sender XEP-0373 key metadata after remote OpenPGP direct sender smoke");
                GLib.Test.message("Could not retract sender XEP-0373 key metadata after remote OpenPGP direct sender smoke");
            }
        }
        if (stream_interactor != null && sender_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) sender_account);
        }
        restore_default_application(application, previous_application);
        if (openpgp_db != null) {
            ((!) openpgp_db).close();
            openpgp_db = null;
        }
        if (core_db != null) {
            ((!) core_db).close();
            core_db = null;
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);
        restore_env_var("GNUPGHOME", previous_gnupg_home);
        restore_env_var("DINOX_OPENPGP_TEST_ISOLATED_GNUPGHOME", previous_isolated_gnupg);
        GPGHelper.set_homedir_path_for_tests(previous_helper_gnupg_home);
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote OpenPGP direct HTTP sender temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, cleanup_error, temp_cleanup_error, config.receiver_jid.bare_jid, temp_dir);
    }

    private static void start_remote_file_modules(StreamInteractor stream_interactor, Dino.Database db,
            Security.FileEncryption file_encryption, Dino.Plugins.OpenPgp.Database openpgp_db) {
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
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor);
        Dino.Plugins.OpenPgp.Manager.start(stream_interactor, openpgp_db);
        FileManager.start(stream_interactor, db, file_encryption);
        CallStore.start(stream_interactor, db);
        ContentItemStore.start(stream_interactor, db);
        StatelessFileSharing.start(stream_interactor, db);
    }

    private static void install_openpgp_account_modules(StreamInteractor stream_interactor,
            Dino.Plugins.OpenPgp.Database openpgp_db, Dino.Plugins.OpenPgp.Manager pgp_manager) {
        PresenceManager? presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        stream_interactor.module_manager.initialize_account_modules.connect((account, modules) => {
            modules.add(new Dino.Plugins.OpenPgp.Module(openpgp_db, account,
                openpgp_db.get_account_legacy_key_for_presence(account), pgp_manager, presence_manager));
            modules.add(new Xmpp.Xep.OpenPgp.Module());
            modules.add(new Xmpp.Xep.OpenPgpContent.Module());
        });
    }

    private static Dino.Plugins.OpenPgp.Xep0373KeyManager install_xep0373_key_manager_for_smoke(
            StreamInteractor stream_interactor, Dino.Plugins.OpenPgp.Database openpgp_db,
            Dino.Plugins.OpenPgp.Manager pgp_manager) {
        var xep0373_manager = new Dino.Plugins.OpenPgp.Xep0373KeyManager(stream_interactor, openpgp_db);
        xep0373_manager.auto_publish_own_key = false;
        pgp_manager.xep0373_manager = xep0373_manager;
        xep0373_manager.key_received.connect((account, jid, fingerprint, key_data) => {
            openpgp_db.set_contact_key(account, jid.bare_jid, fingerprint,
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, false);
            pgp_manager.mark_xep0373_key_received(account, jid.bare_jid);
            pgp_manager.notify_key_state_changed(account, jid.bare_jid);
        });
        xep0373_manager.key_cleared.connect((account, jid) => {
            openpgp_db.clear_contact_xmpp_key(account, jid.bare_jid);
            pgp_manager.forget_xep0373_key_refresh(account, jid.bare_jid);
            pgp_manager.notify_key_state_changed(account, jid.bare_jid);
        });
        return xep0373_manager;
    }

    private async void prepare_xep0373_pubsub_discovery(Dino.Plugins.OpenPgp.Database openpgp_db,
            Dino.Plugins.OpenPgp.Manager pgp_manager, Dino.Plugins.OpenPgp.Xep0373KeyManager xep0373_manager,
            Account sender_account, XmppStream sender_stream, string sender_fpr, string sender_key_data_base64,
            Account receiver_account, XmppStream receiver_stream, string receiver_fpr, string receiver_key_data_base64,
            uint timeout_seconds) throws Error {
        if (openpgp_db.has_contact_xmpp_key(sender_account, receiver_account.bare_jid) ||
                openpgp_db.has_contact_xmpp_key(receiver_account, sender_account.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP XEP-0373 PubSub discovery smoke must start without seeded contact keys");
        }

        if (!(yield publish_xep0373_key(sender_stream, sender_fpr, sender_key_data_base64))) {
            throw new IOError.FAILED("failed to publish sender XEP-0373 key data to remote PubSub");
        }
        if (!(yield publish_xep0373_key(receiver_stream, receiver_fpr, receiver_key_data_base64))) {
            throw new IOError.FAILED("failed to publish receiver XEP-0373 key data to remote PubSub");
        }

        if (!(yield request_xep0373_key(xep0373_manager, sender_account, receiver_account.bare_jid))) {
            throw new IOError.FAILED("failed to fetch receiver XEP-0373 key data from remote PubSub");
        }
        assert_xep0373_contact_key_ready(openpgp_db, pgp_manager, sender_account,
            receiver_account.bare_jid, receiver_fpr, "sender-to-receiver");

        if (!(yield request_xep0373_key(xep0373_manager, receiver_account, sender_account.bare_jid))) {
            throw new IOError.FAILED("failed to fetch sender XEP-0373 key data from remote PubSub");
        }
        assert_xep0373_contact_key_ready(openpgp_db, pgp_manager, receiver_account,
            sender_account.bare_jid, sender_fpr, "receiver-to-sender");
        // Simulate explicit verification only after checking both fetched fingerprints
        // against the disposable keys generated for this test.
        openpgp_db.mark_contact_xmpp_key_verified(sender_account, receiver_account.bare_jid);
        openpgp_db.mark_contact_xmpp_key_verified(receiver_account, sender_account.bare_jid);
    }

    private async bool publish_xep0373_key(XmppStream stream, string fingerprint, string key_data_base64) {
        Xmpp.Xep.OpenPgp.Module? module = stream.get_module<Xmpp.Xep.OpenPgp.Module>(Xmpp.Xep.OpenPgp.Module.IDENTITY);
        if (module == null) return false;

        return yield ((!) module).publish_key_data(stream, fingerprint, key_data_base64);
    }

    private async bool request_xep0373_key(Dino.Plugins.OpenPgp.Xep0373KeyManager xep0373_manager,
            Account account, Jid jid) {
        return yield xep0373_manager.request_keys_if_needed(account, jid.bare_jid);
    }

    private async bool unpublish_xep0373_key(XmppStream stream, string fingerprint) {
        Xmpp.Xep.OpenPgp.Module? module = stream.get_module<Xmpp.Xep.OpenPgp.Module>(Xmpp.Xep.OpenPgp.Module.IDENTITY);
        if (module == null) return false;

        return yield ((!) module).unpublish_key(stream, fingerprint);
    }

    private static void assert_xep0373_contact_key_ready(Dino.Plugins.OpenPgp.Database openpgp_db,
            Dino.Plugins.OpenPgp.Manager pgp_manager, Account account, Jid jid,
            string expected_fingerprint, string label) throws Error {
        string? contact_key = openpgp_db.get_contact_xmpp_key(account, jid.bare_jid);
        if (contact_key == null || normalize_openpgp_fingerprint((!) contact_key) != expected_fingerprint) {
            throw new IOError.FAILED(@"remote OpenPGP XEP-0373 PubSub discovery stored the wrong contact key for $label");
        }
        if (openpgp_db.get_contact_key_source(account, jid.bare_jid) != Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373) {
            throw new IOError.FAILED(@"remote OpenPGP XEP-0373 PubSub discovery did not store XEP-0373 contact-key source for $label");
        }
        if (openpgp_db.has_contact_legacy_key(account, jid.bare_jid)) {
            throw new IOError.FAILED(@"remote OpenPGP XEP-0373 PubSub discovery must not populate legacy contact-key state for $label");
        }
        if (!pgp_manager.contact_xmpp_key_was_refreshed_this_session(account, jid.bare_jid)) {
            throw new IOError.FAILED(@"remote OpenPGP XEP-0373 PubSub discovery did not mark contact key fresh for $label");
        }
    }

    private async void wait_for_legacy_presence_discovery(Dino.Plugins.OpenPgp.Database openpgp_db,
            Account sender_account, Account receiver_account, RemoteOpenPgpPrivateMucHttpSmokeConfig config,
            uint timeout_seconds) throws Error {
        if (!(yield wait_for_condition(timeout_seconds, () =>
                openpgp_db.contact_legacy_key_is_announced(sender_account, config.receiver_jid.bare_jid) &&
                openpgp_db.contact_legacy_key_is_announced(receiver_account, config.sender_jid.bare_jid)))) {
            throw new IOError.TIMED_OUT("timed out waiting for remote OpenPGP XEP-0027 signed-presence activity in both directions");
        }
        if (openpgp_db.has_contact_xmpp_key(sender_account, config.receiver_jid.bare_jid) ||
                openpgp_db.has_contact_xmpp_key(receiver_account, config.sender_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 signed-presence discovery must not populate XEP-0373/XEP-0374 contact-key state");
        }
    }

    private async void wait_for_direct_legacy_presence_discovery(Dino.Plugins.OpenPgp.Database openpgp_db,
            Account sender_account, RemoteOpenPgpDirectHttpSenderConfig config, uint timeout_seconds) throws Error {
        if (!(yield wait_for_condition(timeout_seconds, () =>
                openpgp_db.contact_legacy_key_is_announced(sender_account, config.receiver_jid.bare_jid)))) {
            throw new IOError.TIMED_OUT("timed out waiting for remote OpenPGP direct XEP-0027 signed-presence activity from the receiver");
        }
        if (openpgp_db.has_contact_xmpp_key(sender_account, config.receiver_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 signed-presence discovery must not populate XEP-0373/XEP-0374 contact-key state");
        }
    }

    private async void wait_for_direct_before_send_gate(RemoteOpenPgpDirectHttpSenderConfig config) throws Error {
        if (config.before_send_gate_file == null) return;

        string gate_file = (!) config.before_send_gate_file;
        if (!(yield wait_for_condition(config.timeout_seconds, () => FileUtils.test(gate_file, FileTest.EXISTS | FileTest.IS_REGULAR)))) {
            throw new IOError.TIMED_OUT("timed out waiting for remote OpenPGP direct receiver readiness before sending");
        }
    }

    private async void wait_for_direct_after_send_hold(RemoteOpenPgpDirectHttpSenderConfig config) throws Error {
        if (config.after_send_hold_file == null) return;

        string hold_file = (!) config.after_send_hold_file;
        if (!(yield wait_for_condition(config.timeout_seconds, () => FileUtils.test(hold_file, FileTest.EXISTS | FileTest.IS_REGULAR)))) {
            throw new IOError.TIMED_OUT("timed out waiting for remote OpenPGP direct sender hold release after sending");
        }
    }

    private void assert_direct_after_send_hold_not_released(RemoteOpenPgpDirectHttpSenderConfig config) throws Error {
        if (config.after_send_hold_file == null) return;

        string hold_file = (!) config.after_send_hold_file;
        if (FileUtils.test(hold_file, FileTest.EXISTS)) {
            throw new IOError.FAILED("remote OpenPGP direct sender hold release file already existed before sending");
        }
    }

    private static string export_public_key_data_base64_checked(string fingerprint, string label) throws Error {
        string? key_data_base64 = GPGHelper.export_public_key_data_base64(fingerprint);
        if (key_data_base64 == null || ((!) key_data_base64).length == 0) {
            throw new IOError.FAILED(@"remote OpenPGP PubSub discovery could not export $label public key data");
        }
        return (!) key_data_base64;
    }

    private static void import_armored_key_file(string path, string label) throws Error {
        string armored_key;
        FileUtils.get_contents(path, out armored_key);
        if (!GPGHelper.import_key(armored_key)) {
            throw new IOError.FAILED(@"remote OpenPGP direct sender could not import $label");
        }
    }

    private static void assert_openpgp_private_xmpp_key_ready(string fingerprint, Jid jid, string label) throws Error {
        string expected_fingerprint = normalize_openpgp_fingerprint(fingerprint);
        if (!is_full_openpgp_fingerprint(expected_fingerprint)) {
            throw new IOError.FAILED(@"remote OpenPGP direct sender $label fingerprint must be a full 40-hex fingerprint");
        }

        bool found_secret = false;
        foreach (GPGHelper.Key key in GPGHelper.get_keylist(null, true)) {
            if (key.fpr == null || key.fpr == "") continue;
            string key_fingerprint = normalize_openpgp_fingerprint(key.fpr);
            if (key_fingerprint != expected_fingerprint) continue;

            found_secret = true;
            if (!GPGHelper.key_has_xmpp_uid(key_fingerprint, jid.bare_jid.to_string())) {
                throw new IOError.FAILED(@"remote OpenPGP direct sender $label key does not contain the required xmpp user ID");
            }
            return;
        }

        if (!found_secret) {
            throw new IOError.FAILED(@"remote OpenPGP direct sender $label secret key is not available in the isolated keyring");
        }
    }

    private static void assert_openpgp_public_xmpp_key_ready(string fingerprint, Jid jid, string label) throws Error {
        string expected_fingerprint = normalize_openpgp_fingerprint(fingerprint);
        if (!is_full_openpgp_fingerprint(expected_fingerprint)) {
            throw new IOError.FAILED(@"remote OpenPGP direct sender $label fingerprint must be a full 40-hex fingerprint");
        }

        bool found_public = false;
        foreach (GPGHelper.Key key in GPGHelper.get_keylist(null, false)) {
            if (key.fpr == null || key.fpr == "") continue;
            string key_fingerprint = normalize_openpgp_fingerprint(key.fpr);
            if (key_fingerprint != expected_fingerprint) continue;

            found_public = true;
            if (!GPGHelper.key_has_xmpp_uid(key_fingerprint, jid.bare_jid.to_string())) {
                throw new IOError.FAILED(@"remote OpenPGP direct sender $label public key does not contain the required xmpp user ID");
            }
            return;
        }

        if (!found_public) {
            throw new IOError.FAILED(@"remote OpenPGP direct sender $label public key is not available in the isolated keyring");
        }
    }

    private static void assert_openpgp_private_legacy_key_ready(string fingerprint, string label) throws Error {
        string expected_fingerprint = normalize_openpgp_fingerprint(fingerprint);
        if (!is_full_openpgp_fingerprint(expected_fingerprint)) {
            throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label fingerprint must be a full 40-hex fingerprint");
        }

        bool found_secret = false;
        foreach (GPGHelper.Key key in GPGHelper.get_keylist(null, true)) {
            if (key.fpr == null || key.fpr == "") continue;
            string key_fingerprint = normalize_openpgp_fingerprint(key.fpr);
            if (key_fingerprint != expected_fingerprint) continue;

            found_secret = true;
            if (!GPGHelper.key_has_email_uid(key_fingerprint)) {
                throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label key does not contain an email user ID");
            }
            return;
        }

        if (!found_secret) {
            throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label secret key is not available in the isolated keyring");
        }
    }

    private static void assert_openpgp_public_legacy_key_ready(string fingerprint, string label) throws Error {
        string expected_fingerprint = normalize_openpgp_fingerprint(fingerprint);
        if (!is_full_openpgp_fingerprint(expected_fingerprint)) {
            throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label fingerprint must be a full 40-hex fingerprint");
        }

        bool found_public = false;
        foreach (GPGHelper.Key key in GPGHelper.get_keylist(null, false)) {
            if (key.fpr == null || key.fpr == "") continue;
            string key_fingerprint = normalize_openpgp_fingerprint(key.fpr);
            if (key_fingerprint != expected_fingerprint) continue;

            found_public = true;
            if (!GPGHelper.key_has_email_uid(key_fingerprint)) {
                throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label public key does not contain an email user ID");
            }
            return;
        }

        if (!found_public) {
            throw new IOError.FAILED(@"remote OpenPGP direct XEP-0027 sender $label public key is not available in the isolated keyring");
        }
    }

    private static string configure_isolated_storage(string temp_dir) throws IOError {
        string xdg_data_home = Path.build_filename(temp_dir, "xdg-data");
        string xdg_cache_home = Path.build_filename(temp_dir, "xdg-cache");
        DirUtils.create_with_parents(xdg_data_home, 0700);
        DirUtils.create_with_parents(xdg_cache_home, 0700);
        Environment.set_variable("XDG_DATA_HOME", xdg_data_home, true);
        Environment.set_variable("XDG_CACHE_HOME", xdg_cache_home, true);

        string storage_dir = FileManager.get_storage_dir();
        if (!is_path_at_or_below(storage_dir, xdg_data_home) && !is_meson_test_storage_dir(storage_dir)) {
            throw new IOError.PERMISSION_DENIED(@"remote OpenPGP private-MUC HTTP smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
        }
        return storage_dir;
    }

    private static bool is_path_at_or_below(string path, string parent) {
        string normalized_parent = parent.has_suffix(Path.DIR_SEPARATOR_S) ? parent.substring(0, parent.length - 1) : parent;
        return path == normalized_parent || path.has_prefix(normalized_parent + Path.DIR_SEPARATOR_S);
    }

    private static bool is_meson_test_storage_dir(string storage_dir) {
        return Path.get_basename(storage_dir) == "dinox" &&
            Path.get_basename(Path.get_dirname(storage_dir)) == "test-xdg-data";
    }

    private static void restore_env_var(string name, string? previous_value) {
        if (previous_value == null) {
            Environment.unset_variable(name);
        } else {
            Environment.set_variable(name, (!) previous_value, true);
        }
    }

    private static void persist_remote_smoke_account_without_password(Dino.Database db, Account account) {
        if (account.id > 0) return;
        account.id = (int) db.account.insert()
            .value(db.account.bare_jid, account.bare_jid.to_string())
            .value(db.account.resourcepart, account.resourcepart)
            .value(db.account.password, (string?) null)
            .value(db.account.alias, account.alias)
            .value(db.account.enabled, account.enabled)
            .value(db.account.roster_version, account.roster_version)
            .value(db.account.custom_host, account.custom_host)
            .value(db.account.custom_port, account.custom_port)
            .value(db.account.proxy_type, account.proxy_type)
            .value(db.account.proxy_host, account.proxy_host)
            .value(db.account.proxy_port, account.proxy_port)
            .value(db.account.proxy_user, account.proxy_user)
            .value(db.account.proxy_pass, account.proxy_pass)
            .value(db.account.require_channel_binding, account.require_channel_binding)
            .perform();
    }

    private static void seed_trusted_roster_contact(Dino.Database db, Account account, Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, jid.bare_jid.to_string())
            .value(db.roster.subscription, Xmpp.Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private static string generate_temporary_xmpp_key_for(Jid jid, string name) throws Error {
        string stdout_str;
        string stderr_str;
        bool ok = GPGHelper.generate_xmpp_secret_key(name, jid.bare_jid.to_string(), "", out stdout_str, out stderr_str);
        if (!ok) {
            throw new IOError.FAILED("temporary OpenPGP XMPP key generation failed");
        }

        Gee.List<GPGHelper.Key> keys = GPGHelper.get_keylist(null, true);
        foreach (GPGHelper.Key key in keys) {
            if (key.fpr == null || key.fpr == "") continue;
            if (GPGHelper.key_has_xmpp_uid(key.fpr, jid.bare_jid.to_string())) {
                string fingerprint = normalize_openpgp_fingerprint(key.fpr);
                if (!is_full_openpgp_fingerprint(fingerprint)) {
                    throw new IOError.FAILED("temporary OpenPGP XMPP key did not resolve to a full primary fingerprint");
                }
                return fingerprint;
            }
        }
        throw new IOError.FAILED("temporary OpenPGP XMPP key was generated without a matching xmpp user ID");
    }

    private static string generate_temporary_legacy_key_for(Jid jid, string name) throws Error {
        string stdout_str;
        string stderr_str;
        bool ok = GPGHelper.generate_secret_key(name, jid.bare_jid.to_string(), "", out stdout_str, out stderr_str);
        if (!ok) {
            throw new IOError.FAILED("temporary legacy OpenPGP key generation failed");
        }

        Gee.List<GPGHelper.Key> keys = GPGHelper.get_keylist(null, true);
        foreach (GPGHelper.Key key in keys) {
            if (key.fpr == null || key.fpr == "") continue;
            string fingerprint = normalize_openpgp_fingerprint(key.fpr);
            if (!is_full_openpgp_fingerprint(fingerprint)) continue;
            if (key.email == jid.bare_jid.to_string() && GPGHelper.key_has_email_uid(fingerprint)) {
                return fingerprint;
            }
        }
        throw new IOError.FAILED("temporary legacy OpenPGP key was generated without an email user ID");
    }

    private async bool connect_and_wait_for_negotiation(StreamInteractor stream_interactor, Account account, uint timeout_seconds, out string failure_reason) {
        failure_reason = "";
        string local_failure_reason = "";
        bool completed = false;
        bool success = false;
        SourceFunc resume = connect_and_wait_for_negotiation.callback;
        uint timeout_id = 0;
        ulong negotiated_id = 0;
        ulong error_id = 0;

        negotiated_id = stream_interactor.stream_negotiated.connect((seen_account, stream) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = true;
            remove_source(ref timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        error_id = stream_interactor.connection_manager.connection_error.connect((seen_account, error) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = false;
            local_failure_reason = format_connection_error(error);
            remove_source(ref timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            local_failure_reason = "timed out waiting for XMPP stream negotiation";
            timeout_id = 0;
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
            return Source.REMOVE;
        });

        stream_interactor.connect_account(account);
        yield;
        failure_reason = local_failure_reason;
        return success;
    }

    private async void join_generated_room(XmppStream stream, Xep.Muc.Module muc_module, RemoteOpenPgpPrivateMucHttpSmokeConfig config) throws Error {
        Xep.Muc.JoinResult? result = yield muc_module.enter(
            stream,
            config.room_jid.bare_jid,
            config.sender_nick,
            null,
            null,
            false,
            null);
        validate_join_result(result, "remote generated OpenPGP private-MUC sender join");
        if (!((!) result).newly_created) {
            throw new IOError.FAILED("remote generated OpenPGP private-MUC smoke room already existed");
        }
    }

    private async void join_room(MucManager muc_manager, Account account, Jid room_jid, string nick, uint timeout_seconds) throws Error {
        bool completed = false;
        SourceFunc resume = join_room.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });
        Xep.Muc.JoinResult? result = null;
        muc_manager.join.begin(account, room_jid.bare_jid, nick, null, true, null, false, false, (obj, res) => {
            if (completed) return;
            result = muc_manager.join.end(res);
            completed = true;
            remove_source(ref timeout_id);
            resume();
        });
        yield;
        if (result == null) throw new IOError.TIMED_OUT("timed out waiting for remote OpenPGP private-MUC receiver join");
        validate_join_result(result, "remote generated OpenPGP private-MUC receiver join");
    }

    private static void validate_join_result(Xep.Muc.JoinResult? result, string context) throws Error {
        if (result == null) {
            throw new IOError.FAILED(@"$context returned no result");
        }
        if (((!) result).muc_error != null) {
            throw new IOError.FAILED(@"$context failed with MUC error $(((!) result).muc_error.to_string())");
        }
        if (((!) result).stanza_error != null) {
            throw new IOError.FAILED(@"$context failed with stanza error $(((!) result).stanza_error)");
        }
        if (((!) result).nick == null) {
            throw new IOError.FAILED(@"$context did not confirm an occupant nick");
        }
    }

    private static void configure_generated_private_room(Xep.DataForms.DataForm data_form) throws Error {
        set_config_text_if_present(data_form, "muc#roomconfig_roomname", "DinoX remote OpenPGP private-MUC HTTP file smoke");
        set_config_bool(data_form, "muc#roomconfig_membersonly", true, true);
        set_config_list_single(data_form, "muc#roomconfig_whois", "anyone", true);
        set_config_bool(data_form, "muc#roomconfig_publicroom", false, false);
        set_config_bool(data_form, "muc#roomconfig_persistentroom", false, false);
    }

    private static bool set_config_bool(Xep.DataForms.DataForm data_form, string field_var, bool value, bool required) throws Error {
        Xep.DataForms.DataForm.Field? maybe_field = find_config_field(data_form, field_var);
        if (maybe_field == null) {
            if (required) throw new IOError.FAILED(@"room config form did not include required field $field_var");
            return false;
        }
        Xep.DataForms.DataForm.Field field = (!) maybe_field;
        if (field.type_ != Xep.DataForms.DataForm.Type.BOOLEAN) {
            if (required) throw new IOError.FAILED(@"room config field $field_var is not boolean");
            return false;
        }
        ((Xep.DataForms.DataForm.BooleanField) field).value = value;
        return true;
    }

    private static bool set_config_list_single(Xep.DataForms.DataForm data_form, string field_var, string value, bool required) throws Error {
        Xep.DataForms.DataForm.Field? maybe_field = find_config_field(data_form, field_var);
        if (maybe_field == null) {
            if (required) throw new IOError.FAILED(@"room config form did not include required field $field_var");
            return false;
        }
        Xep.DataForms.DataForm.Field field = (!) maybe_field;
        if (field.type_ != Xep.DataForms.DataForm.Type.LIST_SINGLE) {
            if (required) throw new IOError.FAILED(@"room config field $field_var is not list-single");
            return false;
        }
        ((Xep.DataForms.DataForm.ListSingleField) field).value = value;
        return true;
    }

    private static bool set_config_text_if_present(Xep.DataForms.DataForm data_form, string field_var, string value) {
        Xep.DataForms.DataForm.Field? maybe_field = find_config_field(data_form, field_var);
        if (maybe_field == null) return false;

        Xep.DataForms.DataForm.Field field = (!) maybe_field;
        switch (field.type_) {
            case Xep.DataForms.DataForm.Type.TEXT_SINGLE:
                ((Xep.DataForms.DataForm.TextSingleField) field).value = value;
                return true;
            case Xep.DataForms.DataForm.Type.TEXT_MULTI:
                Gee.List<string> values = new ArrayList<string>();
                values.add(value);
                ((Xep.DataForms.DataForm.TextMultiField) field).value = values;
                return true;
            default:
                return false;
        }
    }

    private static Xep.DataForms.DataForm.Field? find_config_field(Xep.DataForms.DataForm data_form, string field_var) {
        foreach (Xep.DataForms.DataForm.Field field in data_form.fields) {
            if (field.var == field_var) return field;
        }
        return null;
    }

    private async void set_config_form_checked(XmppStream stream, Jid room_jid, Xep.DataForms.DataForm data_form) throws Error {
        StanzaNode query = new StanzaNode.build("query", MUC_OWNER_NS_URI).add_self_xmlns().put_node(data_form.get_submit_node());
        Iq.Stanza set_iq = new Iq.Stanza.set(query) { to=room_jid.bare_jid };
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, set_iq);
        throw_if_iq_error(result, "set generated OpenPGP private-MUC smoke config");
    }

    private async void change_affiliation_checked(XmppStream stream, Jid room_jid, Jid member_jid, string affiliation) throws Error {
        StanzaNode item = new StanzaNode.build("item", MUC_ADMIN_NS_URI)
                .put_attribute("affiliation", affiliation, MUC_ADMIN_NS_URI)
                .put_attribute("jid", member_jid.bare_jid.to_string(), MUC_ADMIN_NS_URI);
        StanzaNode query = new StanzaNode.build("query", MUC_ADMIN_NS_URI).add_self_xmlns().put_node(item);
        Iq.Stanza set_iq = new Iq.Stanza.set(query) { to=room_jid.bare_jid };
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, set_iq);
        throw_if_iq_error(result, "set generated OpenPGP private-MUC smoke affiliation");
    }

    private static void throw_if_iq_error(Iq.Stanza result, string context) throws Error {
        if (!result.is_error()) return;

        ErrorStanza? error_stanza = result.get_error();
        string detail = "unknown stanza error";
        if (error_stanza != null) {
            ErrorStanza error = (!) error_stanza;
            detail = error.condition;
            if (error.text != null && error.text != "") {
                detail += @": $(error.text)";
            }
        }
        throw new IOError.FAILED(@"server rejected $context: $detail");
    }

    private static void validate_private_muc_snapshot(MucManager muc_manager, Account sender_account, Jid room_jid,
            Gee.List<Jid>? snapshot, RemoteOpenPgpPrivateMucHttpSmokeConfig config) throws Error {
        if (snapshot == null) {
            throw new IOError.FAILED("remote OpenPGP private-MUC smoke snapshot query returned no complete member/admin/owner result");
        }
        if (!muc_manager.has_live_private_room_features(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP private-MUC smoke room does not have live members-only plus non-anonymous features");
        }
        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP private-MUC smoke snapshot did not become complete");
        }
        if (!contains_bare_jid((!) snapshot, config.sender_jid) ||
                !contains_bare_jid((!) snapshot, config.receiver_jid)) {
            throw new IOError.FAILED("remote OpenPGP private-MUC smoke snapshot did not contain sender and receiver");
        }
    }

    private async bool wait_for_upload_available(FileManager file_manager, Conversation conversation, uint timeout_seconds) {
        bool completed = false;
        bool success = false;
        SourceFunc resume = wait_for_upload_available.callback;
        uint timeout_id = 0;
        uint poll_id = 0;

        poll_id = Timeout.add(100, () => {
            file_manager.is_upload_available.begin(conversation, (obj, res) => {
                if (completed) return;
                bool available = file_manager.is_upload_available.end(res);
                if (!available) return;

                completed = true;
                success = true;
                remove_source(ref timeout_id);
                remove_source(ref poll_id);
                resume();
            });
            return !completed;
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            remove_source(ref poll_id);
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        yield;
        remove_source(ref poll_id);
        remove_source(ref timeout_id);
        return success;
    }

    private async bool wait_for_condition(uint timeout_seconds, owned ConditionCheck condition) {
        bool completed = false;
        bool success = false;
        SourceFunc resume = wait_for_condition.callback;
        uint timeout_id = 0;
        uint poll_id = 0;

        poll_id = Timeout.add(100, () => {
            if (condition()) {
                completed = true;
                success = true;
                remove_source(ref timeout_id);
                poll_id = 0;
                resume();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            remove_source(ref poll_id);
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        yield;
        remove_source(ref poll_id);
        remove_source(ref timeout_id);
        return success;
    }

    private delegate bool ConditionCheck();

    private static void remove_source(ref uint source_id) {
        if (source_id == 0) return;
        uint id = source_id;
        source_id = 0;
        Source.remove(id);
    }

    private static void validate_sent_transfer(FileTransfer file_transfer, Conversation conversation,
            RemoteOpenPgpPrivateMucHttpSmokeConfig config, OpenPgpSmokeKeySetup key_setup) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP send must publish a persisted outgoing transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must be outgoing");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must target the generated room");
        }
        if (file_transfer.encryption != Encryption.PGP) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must be marked PGP");
        }
        string expected_protocol = expected_file_protocol(key_setup);
        if (file_transfer.encryption_protocol != expected_protocol) {
            throw new IOError.FAILED(@"remote OpenPGP private-MUC HTTP sender transfer must record $expected_protocol");
        }
        if (!file_transfer.server_file_name.has_suffix(".pgp")) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must request a .pgp server filename");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer kept a phase error");
        }
        if (file_transfer.info == null || file_transfer.info == "") {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must link the encrypted body-url message");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT || conversation.encryption != Encryption.PGP) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender conversation must be PGP GROUPCHAT");
        }
    }

    private static void validate_direct_sent_transfer(FileTransfer file_transfer, Conversation conversation,
            RemoteOpenPgpDirectHttpSenderConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP send must publish a persisted outgoing transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must be outgoing");
        }
        if (!file_transfer.counterpart.equals_bare(config.receiver_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must target the configured receiver");
        }
        if (file_transfer.encryption != Encryption.PGP) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must be marked PGP");
        }
        string expected_protocol = config.expected_file_protocol();
        if (file_transfer.encryption_protocol != expected_protocol) {
            throw new IOError.FAILED(@"remote OpenPGP direct HTTP sender transfer must record $expected_protocol");
        }
        if (!file_transfer.server_file_name.has_suffix(".pgp")) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must request a .pgp server filename");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer kept a phase error");
        }
        if (file_transfer.info == null || file_transfer.info == "") {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender transfer must link the encrypted body-url message");
        }
        if (conversation.type_ != Conversation.Type.CHAT || conversation.encryption != Encryption.PGP) {
            throw new IOError.FAILED("remote OpenPGP direct HTTP sender conversation must be a PGP one-to-one chat");
        }
    }

    private static void validate_received_transfer(FileTransfer file_transfer, Conversation conversation,
            RemoteOpenPgpPrivateMucHttpSmokeConfig config, OpenPgpSmokeKeySetup key_setup) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receive must publish a persisted incoming transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must be incoming");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must come from the generated room");
        }
        if (file_transfer.encryption != Encryption.PGP) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must be marked PGP");
        }
        string expected_protocol = expected_file_protocol(key_setup);
        if (file_transfer.encryption_protocol != expected_protocol) {
            throw new IOError.FAILED(@"remote OpenPGP private-MUC HTTP receiver transfer must record $expected_protocol");
        }
        if (file_transfer.file_name != config.payload_name) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver file name did not match expected payload");
        }
        if (file_transfer.size != config.payload_text.length) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer published the wrong plaintext size");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer kept a phase error");
        }
        if (file_transfer.path == null || file_transfer.path == "") {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver transfer must only allow plaintext release after completion");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receiver conversation must be GROUPCHAT");
        }
    }

    private static string require_single_http_source(FileTransfer file_transfer) throws Error {
        if (file_transfer.sfs_sources.size != 1) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer must keep exactly one local HTTP source");
        }
        Xep.StatelessFileSharing.HttpSource? http_source = file_transfer.sfs_sources[0] as Xep.StatelessFileSharing.HttpSource;
        if (http_source == null || ((!) http_source).url == null || ((!) http_source).url == "") {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender transfer did not expose a local HTTP source URL");
        }
        string url = ((!) http_source).url;
        if (!(url.has_prefix("http://") || url.has_prefix("https://")) || url.index_of("#") >= 0) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP sender source URL must be fragment-free HTTP(S)");
        }
        return url;
    }

    private static bool message_reached_remote_send_boundary(Dino.Entities.Message message) {
        switch (message.marked) {
            case Dino.Entities.Message.Marked.SENT:
            case Dino.Entities.Message.Marked.RECEIVED:
            case Dino.Entities.Message.Marked.READ:
            case Dino.Entities.Message.Marked.ACKNOWLEDGED:
                return true;
            default:
                return false;
        }
    }

    private static void validate_captured_openpgp_body_url_message(Dino.Entities.Message message, string openpgp_payload,
            string? outer_body, string? message_protocol, Jid? stanza_to, string? stanza_type, bool has_outer_oob, bool has_outer_sfs,
            bool has_outer_sources, bool has_outer_attach, string download_url, Jid room_jid,
            string sender_fpr, string receiver_fpr) throws Error {
        if (!message_reached_remote_send_boundary(message)) {
            throw new IOError.FAILED("remote OpenPGP body-url message must be marked sent or echoed by the private MUC");
        }
        if (message.encryption != Encryption.PGP || message.encryption_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374 ||
                message_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374) {
            throw new IOError.FAILED("remote OpenPGP body-url message must record XEP-0374");
        }
        if (stanza_to == null || !((!) stanza_to).equals_bare(room_jid.bare_jid) || stanza_type != Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            throw new IOError.FAILED("remote OpenPGP body-url stanza must be a groupchat addressed to the private room");
        }
        if (outer_body == null || ((!) outer_body) == "" || ((!) outer_body) == download_url || ((!) outer_body).contains(download_url)) {
            throw new IOError.FAILED("remote OpenPGP body-url stanza must not expose the HTTP URL in the fallback body");
        }
        if (has_outer_oob || has_outer_sfs || has_outer_sources || has_outer_attach) {
            throw new IOError.FAILED("remote OpenPGP body-url stanza must not expose outer OOB/SFS/attachment URL metadata");
        }
        if (openpgp_payload == "") {
            throw new IOError.FAILED("remote OpenPGP body-url stanza must carry an XEP-0374 payload");
        }

        uint8[] encrypted_signcrypt = Base64.decode(openpgp_payload);
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, sender_fpr,
            "remote OpenPGP body-url signcrypt packet must include the account recipient key");
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, receiver_fpr,
            "remote OpenPGP body-url signcrypt packet must include the receiver recipient key");
        GPGHelper.DecryptedData decrypted = GPGHelper.decrypt_data(encrypted_signcrypt);
        if (!decrypted.signature_valid || decrypted.signer_fingerprint == null ||
                normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != sender_fpr) {
            throw new IOError.FAILED("remote OpenPGP body-url signcrypt must carry the sender signature");
        }

        string signcrypt_xml = (string) decrypted.data;
        Xmpp.StanzaNode signcrypt_node = parse_stanza_node_sync(signcrypt_xml);
        Xmpp.Xep.OpenPgpContent.SigncryptElement? signcrypt = Xmpp.Xep.OpenPgpContent.SigncryptElement.from_stanza_node(signcrypt_node);
        if (signcrypt == null) {
            throw new IOError.FAILED("remote OpenPGP body-url decrypted payload must be a signcrypt element");
        }
        if (((!) signcrypt).to == null || !((!) ((!) signcrypt).to).equals_bare(room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP body-url signcrypt recipient must be the private room JID");
        }
        if (((!) signcrypt).get_body_text() != download_url) {
            throw new IOError.FAILED("remote OpenPGP body-url signcrypt body must contain the HTTP download URL");
        }
    }

    private static void validate_captured_direct_openpgp_body_url_message(Dino.Entities.Message message, string openpgp_payload,
            string? outer_body, string? message_protocol, Jid? stanza_to, string? stanza_type, bool has_outer_oob, bool has_outer_sfs,
            bool has_outer_sources, bool has_outer_attach, string download_url, Jid receiver_jid,
            string sender_fpr, string receiver_fpr) throws Error {
        if (!message_reached_remote_send_boundary(message)) {
            throw new IOError.FAILED("remote OpenPGP direct body-url message must be marked sent or acknowledged");
        }
        if (message.encryption != Encryption.PGP || message.encryption_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374 ||
                message_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374) {
            throw new IOError.FAILED("remote OpenPGP direct body-url message must record XEP-0374");
        }
        if (stanza_to == null || !((!) stanza_to).equals_bare(receiver_jid.bare_jid) || stanza_type != Xmpp.MessageStanza.TYPE_CHAT) {
            throw new IOError.FAILED("remote OpenPGP direct body-url stanza must be a chat addressed to the receiver");
        }
        if (outer_body == null || ((!) outer_body) == "" || ((!) outer_body) == download_url || ((!) outer_body).contains(download_url)) {
            throw new IOError.FAILED("remote OpenPGP direct body-url stanza must not expose the HTTP URL in the fallback body");
        }
        if (has_outer_oob || has_outer_sfs || has_outer_sources || has_outer_attach) {
            throw new IOError.FAILED("remote OpenPGP direct body-url stanza must not expose outer OOB/SFS/attachment URL metadata");
        }
        if (openpgp_payload == "") {
            throw new IOError.FAILED("remote OpenPGP direct body-url stanza must carry an XEP-0374 payload");
        }

        uint8[] encrypted_signcrypt = Base64.decode(openpgp_payload);
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, sender_fpr,
            "remote OpenPGP direct body-url signcrypt packet must include the account recipient key");
        assert_encrypted_packet_data_contains_recipient_key(encrypted_signcrypt, receiver_fpr,
            "remote OpenPGP direct body-url signcrypt packet must include the receiver recipient key");
        GPGHelper.DecryptedData decrypted = GPGHelper.decrypt_data(encrypted_signcrypt);
        if (!decrypted.signature_valid || decrypted.signer_fingerprint == null ||
                normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != sender_fpr) {
            throw new IOError.FAILED("remote OpenPGP direct body-url signcrypt must carry the sender signature");
        }

        string signcrypt_xml = (string) decrypted.data;
        Xmpp.StanzaNode signcrypt_node = parse_stanza_node_sync(signcrypt_xml);
        Xmpp.Xep.OpenPgpContent.SigncryptElement? signcrypt = Xmpp.Xep.OpenPgpContent.SigncryptElement.from_stanza_node(signcrypt_node);
        if (signcrypt == null) {
            throw new IOError.FAILED("remote OpenPGP direct body-url decrypted payload must be a signcrypt element");
        }
        if (((!) signcrypt).to == null || !((!) ((!) signcrypt).to).equals_bare(receiver_jid.bare_jid)) {
            throw new IOError.FAILED("remote OpenPGP direct body-url signcrypt recipient must be the receiver JID");
        }
        if (((!) signcrypt).get_body_text() != download_url) {
            throw new IOError.FAILED("remote OpenPGP direct body-url signcrypt body must contain the HTTP download URL");
        }
    }

    private static void validate_captured_direct_legacy_body_url_message(Dino.Entities.Message message, string? openpgp_payload,
            string legacy_payload, string? outer_body, string? message_protocol, Jid? stanza_to, string? stanza_type,
            bool has_outer_oob, bool has_outer_sfs, bool has_outer_sources, bool has_outer_attach,
            string download_url, Jid receiver_jid, string sender_fpr, string receiver_fpr) throws Error {
        if (!message_reached_remote_send_boundary(message)) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url message must be marked sent or acknowledged");
        }
        if (message.encryption != Encryption.PGP || message.encryption_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027 ||
                message_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027) {
            throw new IOError.FAILED("remote OpenPGP direct body-url message must record XEP-0027");
        }
        if (stanza_to == null || !((!) stanza_to).equals_bare(receiver_jid.bare_jid) || stanza_type != Xmpp.MessageStanza.TYPE_CHAT) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza must be a chat addressed to the receiver");
        }
        if (outer_body == null || ((!) outer_body) != "[This message is OpenPGP encrypted (see XEP-0027)]" ||
                ((!) outer_body).contains(download_url)) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza must expose only the legacy fallback body");
        }
        if (has_outer_oob || has_outer_sfs || has_outer_sources || has_outer_attach) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza must not expose outer OOB/SFS/attachment URL metadata");
        }
        if (openpgp_payload != null && ((!) openpgp_payload) != "") {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza must not carry XEP-0374 payload markup");
        }
        if (legacy_payload == "") {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url stanza must carry a legacy encrypted payload");
        }

        string encrypted_body_url_armor = build_legacy_openpgp_armor(legacy_payload);
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, sender_fpr,
            "remote OpenPGP direct XEP-0027 body-url packet must include the account recipient key");
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, receiver_fpr,
            "remote OpenPGP direct XEP-0027 body-url packet must include the receiver recipient key");

        string decrypted_body_url = GPGHelper.decrypt(encrypted_body_url_armor);
        if (decrypted_body_url != download_url) {
            throw new IOError.FAILED("remote OpenPGP direct XEP-0027 body-url encrypted payload must contain only the HTTP download URL");
        }
    }

    private static void validate_captured_legacy_body_url_message(Dino.Entities.Message message, string? openpgp_payload,
            string legacy_payload, string? outer_body, string? message_protocol, Jid? stanza_to, string? stanza_type,
            bool has_outer_oob, bool has_outer_sfs, bool has_outer_sources, bool has_outer_attach,
            string download_url, Jid room_jid, string sender_fpr, string receiver_fpr) throws Error {
        if (!message_reached_remote_send_boundary(message)) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url message must be marked sent or echoed by the private MUC");
        }
        if (message.encryption != Encryption.PGP || message.encryption_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027 ||
                message_protocol != Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027) {
            throw new IOError.FAILED("remote OpenPGP body-url message must record XEP-0027");
        }
        if (stanza_to == null || !((!) stanza_to).equals_bare(room_jid.bare_jid) || stanza_type != Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url stanza must be a groupchat addressed to the private room");
        }
        if (outer_body == null || ((!) outer_body) != "[This message is OpenPGP encrypted (see XEP-0027)]" ||
                ((!) outer_body).contains(download_url)) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url stanza must expose only the legacy fallback body");
        }
        if (has_outer_oob || has_outer_sfs || has_outer_sources || has_outer_attach) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url stanza must not expose outer OOB/SFS/attachment URL metadata");
        }
        if (openpgp_payload != null && ((!) openpgp_payload) != "") {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url stanza must not carry XEP-0374 payload markup");
        }
        if (legacy_payload == "") {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url stanza must carry a legacy encrypted payload");
        }

        string encrypted_body_url_armor = build_legacy_openpgp_armor(legacy_payload);
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, sender_fpr,
            "remote OpenPGP XEP-0027 body-url packet must include the account recipient key");
        assert_encrypted_armor_contains_recipient_key(encrypted_body_url_armor, receiver_fpr,
            "remote OpenPGP XEP-0027 body-url packet must include the receiver recipient key");

        string decrypted_body_url = GPGHelper.decrypt(encrypted_body_url_armor);
        if (decrypted_body_url != download_url) {
            throw new IOError.FAILED("remote OpenPGP XEP-0027 body-url encrypted payload must contain only the HTTP download URL");
        }
    }

    private static string build_legacy_openpgp_armor(string packet_text) {
        return "-----BEGIN PGP MESSAGE-----\n\n" + packet_text.strip() + "\n-----END PGP MESSAGE-----";
    }

    private async uint8[] download_remote_pgp(string download_url, uint timeout_seconds) throws Error {
        var session = new Soup.Session();
        var message = new Soup.Message("GET", download_url);
        Cancellable cancellable = new Cancellable();
        uint timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            cancellable.cancel();
            return Source.REMOVE;
        });
        try {
            Bytes bytes = yield session.send_and_read_async(message, Priority.DEFAULT, cancellable);
            if (message.status_code < 200 || message.status_code >= 300) {
                throw new IOError.FAILED("remote OpenPGP HTTP upload download returned a non-success status");
            }
            return copy_bytes(bytes);
        } catch (Error e) {
            throw new IOError.FAILED("remote OpenPGP HTTP upload download failed");
        } finally {
            remove_source(ref timeout_id);
            session.abort();
        }
    }

    private static uint8[] copy_bytes(Bytes bytes) {
        unowned uint8[]? raw_maybe = bytes.get_data();
        if (raw_maybe == null) return new uint8[0];

        unowned uint8[] raw = (!) raw_maybe;
        uint8[] copy = new uint8[raw.length];
        for (int i = 0; i < raw.length; i++) {
            copy[i] = raw[i];
        }
        return copy;
    }

    private static void validate_downloaded_pgp_upload(string temp_dir, uint8[] uploaded_pgp,
            RemoteOpenPgpPrivateMucHttpSmokeConfig config, string sender_fpr, string receiver_fpr) throws Error {
        if (uploaded_pgp.length == 0) {
            throw new IOError.FAILED("remote OpenPGP uploaded PGP body must not be empty");
        }
        if (contains_bytes(uploaded_pgp, config.payload_text.data)) {
            throw new IOError.FAILED("remote OpenPGP uploaded PGP body must not contain plaintext payload bytes");
        }
        string uploaded_path = Path.build_filename(temp_dir, "remote-openpgp-uploaded-body.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "remote-openpgp-decrypted-body.txt");
        FileUtils.set_data(uploaded_path, uploaded_pgp);
        GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_path, decrypted_path);
        string decrypted_text;
        FileUtils.get_contents(decrypted_path, out decrypted_text);
        if (decrypted_text != config.payload_text) {
            throw new IOError.FAILED("remote OpenPGP uploaded PGP body did not decrypt to the original payload");
        }
        if (decrypted.filename != config.payload_name) {
            throw new IOError.FAILED("remote OpenPGP uploaded PGP body did not preserve the original filename");
        }
        if (!decrypted.signature_valid || decrypted.signer_fingerprint == null ||
                normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != sender_fpr) {
            throw new IOError.FAILED("remote OpenPGP uploaded PGP body must carry the sender signature");
        }
        assert_encrypted_packet_contains_recipient_key(uploaded_path, sender_fpr,
            "remote OpenPGP uploaded PGP packet must include the account recipient key");
        assert_encrypted_packet_contains_recipient_key(uploaded_path, receiver_fpr,
            "remote OpenPGP uploaded PGP packet must include the receiver recipient key");
    }

    private static void validate_downloaded_direct_pgp_upload(string temp_dir, uint8[] uploaded_pgp,
            RemoteOpenPgpDirectHttpSenderConfig config, string sender_fpr, string receiver_fpr) throws Error {
        if (uploaded_pgp.length == 0) {
            throw new IOError.FAILED("remote OpenPGP direct uploaded PGP body must not be empty");
        }
        if (contains_bytes(uploaded_pgp, config.payload_text.data)) {
            throw new IOError.FAILED("remote OpenPGP direct uploaded PGP body must not contain plaintext payload bytes");
        }
        string uploaded_path = Path.build_filename(temp_dir, "remote-openpgp-direct-uploaded-body.pgp");
        string decrypted_path = Path.build_filename(temp_dir, "remote-openpgp-direct-decrypted-body.txt");
        FileUtils.set_data(uploaded_path, uploaded_pgp);
        GPGHelper.DecryptedFile decrypted = GPGHelper.decrypt_file_to_path(uploaded_path, decrypted_path);
        string decrypted_text;
        FileUtils.get_contents(decrypted_path, out decrypted_text);
        if (decrypted_text != config.payload_text) {
            throw new IOError.FAILED("remote OpenPGP direct uploaded PGP body did not decrypt to the original payload");
        }
        if (decrypted.filename != config.payload_name) {
            throw new IOError.FAILED("remote OpenPGP direct uploaded PGP body did not preserve the original filename");
        }
        if (!decrypted.signature_valid || decrypted.signer_fingerprint == null ||
                normalize_openpgp_fingerprint((!) decrypted.signer_fingerprint) != sender_fpr) {
            throw new IOError.FAILED("remote OpenPGP direct uploaded PGP body must carry the sender signature");
        }
        assert_encrypted_packet_contains_recipient_key(uploaded_path, sender_fpr,
            "remote OpenPGP direct uploaded PGP packet must include the account recipient key");
        assert_encrypted_packet_contains_recipient_key(uploaded_path, receiver_fpr,
            "remote OpenPGP direct uploaded PGP packet must include the receiver recipient key");
    }

    private async void validate_stored_payload(Security.FileEncryption file_encryption, FileTransfer file_transfer,
            int64 expected_size, string expected_sha256) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED("remote OpenPGP private-MUC HTTP receive-store must write the verified local file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();
        if (decrypted.length != expected_size) {
            throw new IOError.FAILED(@"decrypted remote OpenPGP private-MUC HTTP payload size $(decrypted.length) did not match $(expected_size)");
        }
        string actual_sha256 = Checksum.compute_for_data(ChecksumType.SHA256, decrypted);
        if (actual_sha256.down() != expected_sha256.down()) {
            throw new IOError.FAILED("decrypted remote OpenPGP private-MUC HTTP payload SHA-256 did not match expected payload");
        }
    }

    private static int count_pending_receive_files(Dino.Database db) {
        return (int) db.file_transfer.select()
            .with(db.file_transfer.direction, "=", FileTransfer.DIRECTION_RECEIVED)
            .with(db.file_transfer.state, "=", FileTransfer.State.IN_PROGRESS)
            .count();
    }

    private static bool contains_bytes(uint8[] haystack, uint8[] needle) {
        if (needle.length == 0) return true;
        if (needle.length > haystack.length) return false;

        for (int i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (int j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    private static void assert_phase_order(Gee.List<FileTransfer.Phase> phases, FileTransfer.Phase before,
            FileTransfer.Phase after, string reason) throws Error {
        int before_index = -1;
        int after_index = -1;
        for (int i = 0; i < phases.size; i++) {
            if (before_index < 0 && phases[i] == before) before_index = i;
            if (after_index < 0 && phases[i] == after) after_index = i;
        }
        if (before_index < 0 || after_index < 0 || before_index >= after_index) {
            throw new IOError.FAILED(reason);
        }
    }

    private static Xmpp.StanzaNode parse_stanza_node_sync(string xml) throws Error {
        var reader = new Xmpp.StanzaReader.for_string(xml);
        var loop = new MainLoop();
        Xmpp.StanzaNode? node = null;
        Error? parse_error = null;
        reader.read_stanza_node.begin((obj, res) => {
            try {
                node = reader.read_stanza_node.end(res);
            } catch (Error e) {
                parse_error = e;
            }
            loop.quit();
        });
        loop.run();
        if (parse_error != null) throw (!) parse_error;
        if (node == null) throw new IOError.FAILED("Failed to parse OpenPGP signcrypt XML");
        return (!) node;
    }

    private static void drain_pending_events() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }

    private static void assert_encrypted_packet_data_contains_recipient_key(uint8[] encrypted_data, string recipient_fingerprint,
            string reason) throws Error {
        string temp_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-remote-packet-" + Uuid.string_random() + ".pgp");
        try {
            FileUtils.set_data(temp_path, encrypted_data);
            assert_encrypted_packet_contains_recipient_key(temp_path, recipient_fingerprint, reason);
        } finally {
            GPGHelper.secure_delete_file(temp_path);
        }
    }

    private static void assert_encrypted_armor_contains_recipient_key(string encrypted_armor, string recipient_fingerprint,
            string reason) throws Error {
        string temp_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-remote-packet-" + Uuid.string_random() + ".asc");
        try {
            FileUtils.set_contents(temp_path, encrypted_armor);
            assert_encrypted_packet_contains_recipient_key(temp_path, recipient_fingerprint, reason);
        } finally {
            GPGHelper.secure_delete_file(temp_path);
        }
    }

    private static void assert_encrypted_packet_contains_recipient_key(string encrypted_path, string recipient_fingerprint,
            string reason) throws Error {
        Gee.HashSet<string> recipient_key_ids = collect_public_key_ids(recipient_fingerprint);
        Gee.HashSet<string> packet_key_ids = collect_encrypted_packet_key_ids(encrypted_path);

        foreach (string recipient_key_id in recipient_key_ids) {
            if (packet_key_ids.contains(recipient_key_id)) return;
        }
        throw new IOError.FAILED(reason);
    }

    private static Gee.HashSet<string> collect_public_key_ids(string fingerprint) throws Error {
        string output = run_gpg_capture({ "--with-colons", "--with-fingerprint", "--list-keys", fingerprint });
        var key_ids = new Gee.HashSet<string>();
        foreach (string line in output.split("\n")) {
            string[] parts = line.split(":");
            if ((parts[0] == "pub" || parts[0] == "sub") && parts.length > 4 && parts[4].length > 0) {
                key_ids.add(normalize_openpgp_key_id(parts[4]));
            } else if (parts[0] == "fpr" && parts.length > 9 && parts[9].length >= 16) {
                string fpr = normalize_openpgp_fingerprint(parts[9]);
                key_ids.add(fpr.substring(fpr.length - 16));
            }
        }
        if (key_ids.size == 0) {
            throw new IOError.FAILED("Could not resolve OpenPGP recipient packet key ids");
        }
        return key_ids;
    }

    private static Gee.HashSet<string> collect_encrypted_packet_key_ids(string encrypted_path) throws Error {
        string output = run_gpg_capture({ "--list-packets", "--list-only", encrypted_path });
        var key_ids = new Gee.HashSet<string>();
        foreach (string raw_line in output.split("\n")) {
            string line = raw_line.strip();
            int keyid_pos = line.index_of("keyid ");
            if (keyid_pos < 0) continue;
            string value = line.substring(keyid_pos + "keyid ".length).strip();
            int end = 0;
            while (end < value.length && is_openpgp_hex_char(value[end])) {
                end++;
            }
            if (end > 0) key_ids.add(normalize_openpgp_key_id(value.substring(0, end)));
        }
        if (key_ids.size == 0) {
            throw new IOError.FAILED("Could not parse OpenPGP encrypted packet recipients");
        }
        return key_ids;
    }

    private static string run_gpg_capture(string[] extra_args) throws Error {
        string gpg = GPGHelper.get_binary_path();
        string? homedir = GPGHelper.get_homedir_path();
        int prefix_len = homedir != null && ((!) homedir) != "" ? 5 : 2;
        string[] argv = new string[prefix_len + extra_args.length + 1];
        argv[0] = gpg;
        argv[1] = "--batch";
        int offset = 2;
        if (homedir != null && ((!) homedir) != "") {
            argv[2] = "--homedir";
            argv[3] = (!) homedir;
            argv[4] = "--no-secmem-warning";
            offset = 5;
        }
        for (int i = 0; i < extra_args.length; i++) {
            argv[offset + i] = extra_args[i];
        }
        argv[offset + extra_args.length] = null;

        string stdout_str;
        string stderr_str;
        int exit_status;
        Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out exit_status);
        if (exit_status != 0) {
            throw new IOError.FAILED("GPG packet inspection failed");
        }
        return stdout_str + "\n" + stderr_str;
    }

    private static bool is_full_openpgp_fingerprint(string value) {
        if (value.length != 40) return false;
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
        }
        return true;
    }

    private static bool is_openpgp_hex_char(char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private static string normalize_openpgp_fingerprint(string value) {
        return normalize_openpgp_key_id(value);
    }

    private static string normalize_openpgp_key_id(string value) {
        return value.replace(" ", "").replace(":", "").up();
    }

    private static string key_setup_label(OpenPgpSmokeKeySetup key_setup) {
        if (key_setup == OpenPgpSmokeKeySetup.PUBSUB_DISCOVERY) return "PubSub-discovered";
        if (key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027) return "legacy XEP-0027";
        return "seeded";
    }

    private static string expected_file_protocol(OpenPgpSmokeKeySetup key_setup) {
        return key_setup == OpenPgpSmokeKeySetup.LEGACY_XEP0027
            ? Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027
            : Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;
    }

    private static bool contains_bare_jid(Gee.List<Jid> jids, Jid expected) {
        foreach (Jid jid in jids) {
            if (jid.bare_jid.equals(expected.bare_jid)) return true;
        }
        return false;
    }

    private static string format_transfer_state(FileTransfer? transfer) {
        if (transfer == null) return "(none)";
        return @"state=$((int) ((!) transfer).state),phase=$((int) ((!) transfer).phase),error=$(((!) transfer).phase_error ?? "none")";
    }

    private static string format_message_marked(Dino.Entities.Message? message) {
        if (message == null) return "(none)";
        return @"marked=$((int) ((!) message).marked)";
    }

    private static string format_connection_error(ConnectionManager.ConnectionError error) {
        string text = @"XMPP connection error: $(error.source.to_string())";
        if (error.identifier != null) {
            text += @"/$((!) error.identifier)";
        }
        if (error.tls_flags != 0) {
            text += @" TLS flags $(error.tls_flags.to_string())";
        }
        return text;
    }

    private static void restore_default_application(TestApplication? application, GLib.Application? previous_application) {
        if (application == null) return;
        if (GLib.Application.get_default() == (!) application) {
            GLib.Application.set_default(previous_application);
        }
    }

    private static void throw_final_errors(Error? primary_error, Error? remote_cleanup_error, Error? temp_cleanup_error, Jid? generated_room_jid, string temp_dir) throws Error {
        if (primary_error == null && remote_cleanup_error == null && temp_cleanup_error == null) return;
        if (remote_cleanup_error == null && temp_cleanup_error == null) throw (!) primary_error;

        StringBuilder builder = new StringBuilder();
        bool has_segment = false;
        if (primary_error != null) {
            Error error = (!) primary_error;
            append_error_segment(builder, ref has_segment, @"primary failure: $(error.message)");
        }
        if (remote_cleanup_error != null) {
            Error error = (!) remote_cleanup_error;
            string room = generated_room_jid != null ? ((!) generated_room_jid).bare_jid.to_string() : "(unknown room)";
            append_error_segment(builder, ref has_segment, @"remote cleanup failure for $room: $(error.message)");
        }
        if (temp_cleanup_error != null) {
            Error error = (!) temp_cleanup_error;
            append_error_segment(builder, ref has_segment, @"credential-bearing temp cleanup failure for $temp_dir: $(error.message)");
        }
        throw new IOError.FAILED(builder.str);
    }

    private static void append_error_segment(StringBuilder builder, ref bool has_segment, string text) {
        if (has_segment) builder.append("; ");
        builder.append(text);
        has_segment = true;
    }

    private static void delete_file_tree(File file) throws Error {
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

    private class RemoteOpenPgpDirectHttpSenderConfig : Object {
        public Jid sender_jid;
        public string sender_password;
        public Jid receiver_jid;
        public string sender_secret_key_file;
        public string receiver_public_key_file;
        public string sender_fingerprint;
        public string receiver_fingerprint;
        public string? custom_host = null;
        public int custom_port = 0;
        public bool legacy_xep0027 = false;
        public bool publish_sender_key = false;
        public bool keep_published_sender_key = false;
        public string? before_send_gate_file = null;
        public string? after_send_hold_file = null;
        public string payload_name = "dinox-remote-openpgp-direct-http-sender.txt";
        public string payload_text = "DinoX remote OpenPGP direct HTTP sender-only payload\n";
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public string expected_file_protocol() {
            return legacy_xep0027
                ? Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0027
                : Dino.Plugins.OpenPgp.Manager.FILE_PROTOCOL_XEP0374;
        }

        public string key_setup_label() {
            return legacy_xep0027 ? "XEP-0027" : "XEP-0374";
        }

        public static RemoteOpenPgpDirectHttpSenderConfig? from_env(bool legacy_xep0027 = false) {
            if (Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SMOKE=1 with sender, receiver, key files and fingerprints to run the remote OpenPGP direct HTTP sender smoke");
                return null;
            }

            string? sender_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID");
            string? sender_password_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD");
            string? receiver_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID");
            string? sender_key_file_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE");
            string? receiver_key_file_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE");
            string? sender_fingerprint_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT");
            string? receiver_fingerprint_env = require_env("DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT");
            if (sender_env == null || sender_password_env == null || receiver_env == null ||
                    sender_key_file_env == null || receiver_key_file_env == null ||
                    sender_fingerprint_env == null || receiver_fingerprint_env == null) {
                return null;
            }

            RemoteOpenPgpDirectHttpSenderConfig config = new RemoteOpenPgpDirectHttpSenderConfig();
            try {
                config.sender_jid = new Jid((!) sender_env);
                config.receiver_jid = new Jid((!) receiver_env);
                if (config.sender_jid.resourcepart != null || config.receiver_jid.resourcepart != null) {
                    fail_if(true, "remote OpenPGP direct HTTP sender smoke requires bare sender and receiver account JIDs");
                    return null;
                }
                if (config.sender_jid.bare_jid.equals(config.receiver_jid.bare_jid)) {
                    fail_if(true, "remote OpenPGP direct HTTP sender smoke requires distinct sender and receiver accounts");
                    return null;
                }
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote OpenPGP direct HTTP sender smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.sender_password = (!) sender_password_env;
            config.sender_secret_key_file = (!) sender_key_file_env;
            config.receiver_public_key_file = (!) receiver_key_file_env;
            config.legacy_xep0027 = legacy_xep0027;
            config.sender_fingerprint = normalize_env_fingerprint((!) sender_fingerprint_env);
            config.receiver_fingerprint = normalize_env_fingerprint((!) receiver_fingerprint_env);
            if (!is_valid_env_fingerprint(config.sender_fingerprint) || !is_valid_env_fingerprint(config.receiver_fingerprint)) {
                fail_if(true, "remote OpenPGP direct HTTP sender smoke requires full 40-hex sender and receiver fingerprints");
                return null;
            }
            if (config.sender_fingerprint == config.receiver_fingerprint) {
                fail_if(true, "remote OpenPGP direct HTTP sender smoke requires distinct sender and receiver OpenPGP keys");
                return null;
            }
            if (!FileUtils.test(config.sender_secret_key_file, FileTest.EXISTS | FileTest.IS_REGULAR) ||
                    !FileUtils.test(config.receiver_public_key_file, FileTest.EXISTS | FileTest.IS_REGULAR)) {
                fail_if(true, "remote OpenPGP direct HTTP sender smoke sender secret-key and receiver public-key files must exist and be regular files");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_HOST"));
            string? publish_sender_key_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY"));
            if (publish_sender_key_env != null && publish_sender_key_env != "1") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY must be 1 when set");
                return null;
            }
            string? allow_pep_mutation_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION"));
            if (allow_pep_mutation_env != null && allow_pep_mutation_env != "1") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION must be 1 when set");
                return null;
            }
            if (publish_sender_key_env != null && allow_pep_mutation_env != "1") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY requires DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION=1 for disposable test accounts");
                return null;
            }
            config.publish_sender_key = publish_sender_key_env == "1";
            string? keep_published_sender_key_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY"));
            if (keep_published_sender_key_env != null && keep_published_sender_key_env != "1") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY must be 1 when set");
                return null;
            }
            if (legacy_xep0027 && (allow_pep_mutation_env != null || publish_sender_key_env != null || keep_published_sender_key_env != null)) {
                fail_if(true, "remote OpenPGP direct XEP-0027 sender smoke must not mutate XEP-0373 PubSub state");
                return null;
            }
            config.keep_published_sender_key = keep_published_sender_key_env == "1";
            if (config.keep_published_sender_key && !config.publish_sender_key) {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY requires DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY=1");
                return null;
            }
            config.before_send_gate_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE"));
            config.after_send_hold_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE"));
            config.payload_name = FileTransfer.sanitize_file_name(
                    empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME")) ?? config.payload_name);
            if (config.payload_name == "" || config.payload_name == "." || config.payload_name == "..") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME must resolve to a simple file name");
                return null;
            }
            config.payload_text = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_PAYLOAD_TEXT")) ?? config.payload_text;

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 900) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS must be an integer between 5 and 900");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            return config;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SMOKE=1");
                return null;
            }
            return value;
        }

        private static string normalize_env_fingerprint(string value) {
            return value.replace(" ", "").replace(":", "").up();
        }

        private static bool is_valid_env_fingerprint(string value) {
            if (value.length != 40) return false;
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
            }
            return true;
        }

        private static string? empty_to_null(string? value) {
            if (value == null) return null;
            string stripped = ((!) value).strip();
            return stripped == "" ? null : stripped;
        }
    }

    private class RemoteOpenPgpPrivateMucHttpSmokeConfig : Object {
        public Jid sender_jid;
        public string sender_password;
        public Jid receiver_jid;
        public string receiver_password;
        public Jid service_jid;
        public Jid room_jid;
        public string? custom_host = null;
        public int custom_port = 0;
        public string account_proxy_type = "none";
        public string? account_proxy_host = null;
        public int account_proxy_port = 0;
        public string sender_nick = "dinox-openpgp-smoke-sender";
        public string receiver_nick = "dinox-openpgp-smoke-receiver";
        public string payload_name = "dinox-remote-openpgp-private-muc-http-smoke.txt";
        public string payload_text = "DinoX remote OpenPGP private-MUC HTTP file smoke payload\n";
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemoteOpenPgpPrivateMucHttpSmokeConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE=1 with sender, receiver and MUC service env to run the remote OpenPGP private-MUC HTTP file-send smoke");
                return null;
            }

            string? sender_env = require_env("DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID");
            string? sender_password_env = require_env("DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD");
            string? receiver_env = require_env("DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID");
            string? receiver_password_env = require_env("DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD");
            string? service_env = require_env("DINOX_REMOTE_OPENPGP_MUC_SERVICE");
            if (sender_env == null || sender_password_env == null || receiver_env == null ||
                    receiver_password_env == null || service_env == null) {
                return null;
            }

            RemoteOpenPgpPrivateMucHttpSmokeConfig config = new RemoteOpenPgpPrivateMucHttpSmokeConfig();
            try {
                config.sender_jid = new Jid((!) sender_env);
                config.receiver_jid = new Jid((!) receiver_env);
                config.service_jid = new Jid((!) service_env);
                if (config.sender_jid.resourcepart != null || config.receiver_jid.resourcepart != null) {
                    fail_if(true, "remote OpenPGP private-MUC HTTP file smoke requires bare sender and receiver account JIDs");
                    return null;
                }
                if (!config.service_jid.is_domain()) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_SERVICE must be a domain JID such as conference.example.test");
                    return null;
                }
                if (config.sender_jid.bare_jid.equals(config.receiver_jid.bare_jid)) {
                    fail_if(true, "remote OpenPGP private-MUC HTTP file smoke requires distinct sender and receiver accounts");
                    return null;
                }
                config.sender_password = (!) sender_password_env;
                config.receiver_password = (!) receiver_password_env;

                string room_prefix = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX")) ?? "dinox-remote-openpgp-muc-http-smoke";
                config.room_jid = new Jid(@"$room_prefix-$(Uuid.string_random())@$(config.service_jid.domainpart)").bare_jid;
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote OpenPGP private-MUC HTTP file smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_HOST"));
            config.sender_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK")) ?? config.sender_nick;
            config.receiver_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK")) ?? config.receiver_nick;
            config.payload_name = FileTransfer.sanitize_file_name(
                    empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_FILE_NAME")) ?? config.payload_name);
            config.payload_text = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT")) ?? config.payload_text;

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 900) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            if (!parse_account_proxy_env(config)) {
                return null;
            }

            return config;
        }

        public void apply_account_proxy(Account account) {
            account.proxy_type = account_proxy_type;
            account.proxy_host = account_proxy_host;
            account.proxy_port = account_proxy_port;
        }

        private static bool parse_account_proxy_env(RemoteOpenPgpPrivateMucHttpSmokeConfig config) {
            string? proxy_type = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE"));
            if (proxy_type == null) return true;
            proxy_type = ((!) proxy_type).down();
            if (proxy_type != "none" && proxy_type != "socks5" && proxy_type != "tor") {
                fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE must be none, socks5 or tor");
                return false;
            }
            config.account_proxy_type = (!) proxy_type;
            if (config.account_proxy_type == "none") return true;

            config.account_proxy_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST"));
            string? proxy_port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT"));
            if (config.account_proxy_type == "socks5" && config.account_proxy_host == null) {
                fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST must be set for socks5 account proxy");
                return false;
            }
            if (proxy_port_env != null) {
                int parsed_proxy_port = 0;
                if (!int.try_parse((!) proxy_port_env, out parsed_proxy_port, null, 10) || parsed_proxy_port < 1 || parsed_proxy_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535");
                    return false;
                }
                config.account_proxy_port = parsed_proxy_port;
            }
            if (config.account_proxy_type == "socks5" && config.account_proxy_port == 0) {
                fail_if(true, "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT must be set for socks5 account proxy");
                return false;
            }
            return true;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE=1");
                return null;
            }
            return value;
        }

        private static string? empty_to_null(string? value) {
            if (value == null) return null;
            string stripped = ((!) value).strip();
            return stripped == "" ? null : stripped;
        }
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Dino.Database db { get; set; }
        public string? db_key { get; set; }
        public Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Dino.Database db, StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.remote-openpgp-private-muc-http-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-openpgp-private-muc-http-smoke-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}
