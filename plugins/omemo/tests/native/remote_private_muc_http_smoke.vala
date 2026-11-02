using Dino;
using Dino.Entities;
using Dino.Plugins.HttpFiles;
using Gee;
using Qlite;
using Xmpp;

namespace Omemo.Test {

class RemotePrivateMucHttpSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 120;
    private const string MUC_OWNER_NS_URI = "http://jabber.org/protocol/muc#owner";
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OMEMO_V2 = "urn:xmpp:omemo:2";

    private enum OmemoSmokeProtocol {
        OMEMO1,
        OMEMO2
    }

    private enum OmemoSmokeKeySetup {
        SEEDED,
        PUBSUB_DISCOVERY
    }

    public RemotePrivateMucHttpSmokeTest() {
        base("RemoteOmemoPrivateMucHttpSmoke");
        add_test("private_muc_omemo1_http_send_receive_env", test_private_muc_omemo1_http_send_receive_env_sync);
        add_test("private_muc_omemo1_pubsub_http_send_receive_env", test_private_muc_omemo1_pubsub_http_send_receive_env_sync);
        add_test("private_muc_omemo2_http_send_receive_env", test_private_muc_omemo2_http_send_receive_env_sync);
        add_test("private_muc_omemo2_pubsub_http_send_receive_env", test_private_muc_omemo2_pubsub_http_send_receive_env_sync);
    }

    private void test_private_muc_omemo1_http_send_receive_env_sync() {
        test_private_muc_omemo_http_send_receive_env_sync(OmemoSmokeProtocol.OMEMO1, OmemoSmokeKeySetup.SEEDED);
    }

    private void test_private_muc_omemo1_pubsub_http_send_receive_env_sync() {
        test_private_muc_omemo_http_send_receive_env_sync(OmemoSmokeProtocol.OMEMO1, OmemoSmokeKeySetup.PUBSUB_DISCOVERY);
    }

    private void test_private_muc_omemo2_http_send_receive_env_sync() {
        test_private_muc_omemo_http_send_receive_env_sync(OmemoSmokeProtocol.OMEMO2, OmemoSmokeKeySetup.SEEDED);
    }

    private void test_private_muc_omemo2_pubsub_http_send_receive_env_sync() {
        test_private_muc_omemo_http_send_receive_env_sync(OmemoSmokeProtocol.OMEMO2, OmemoSmokeKeySetup.PUBSUB_DISCOVERY);
    }

    private void test_private_muc_omemo_http_send_receive_env_sync(OmemoSmokeProtocol protocol, OmemoSmokeKeySetup key_setup) {
        RemoteOmemoPrivateMucHttpSmokeConfig? config = RemoteOmemoPrivateMucHttpSmokeConfig.from_env(protocol, key_setup);
        if (config == null) return;

        // Match production for legacy tests: do not publish/query v2 nodes.
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(protocol == OmemoSmokeProtocol.OMEMO2);
        MainLoop loop = new MainLoop();
        run_private_muc_omemo_http_send_receive.begin((!) config, protocol, key_setup, (obj, res) => {
            try {
                run_private_muc_omemo_http_send_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote $(protocol_label(protocol)) $(key_setup_label(key_setup)) private-MUC HTTP file send/receive smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private async void run_private_muc_omemo_http_send_receive(RemoteOmemoPrivateMucHttpSmokeConfig config,
            OmemoSmokeProtocol protocol, OmemoSmokeKeySetup key_setup) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-omemo-muc-http-smoke-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Dino.Database? core_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        StreamInteractor? stream_interactor = null;
        Account? sender_account = null;
        Account? receiver_account = null;
        Account? extra_receiver_account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        XmppStream? sender_stream = null;
        Xep.Muc.Module? sender_muc_module = null;
        Dino.Plugins.HttpFiles.FileProvider? http_provider = null;
        HttpFileSender? http_sender = null;
        FileTransfer? sent_transfer = null;
        FileTransfer? received_transfer = null;
        FileTransfer? extra_received_transfer = null;
        Conversation? sender_conversation = null;
        Conversation? receiver_conversation = null;
        Conversation? extra_receiver_conversation = null;
        Store? sender_store = null;
        Store? receiver_store = null;
        Store? extra_receiver_store = null;
        Store? sender_own_secondary_store = null;
        Dino.Entities.Message? captured_body_url_message = null;
        string? captured_outer_body = null;
        Jid? captured_stanza_to = null;
        string? captured_stanza_type = null;
        Xmpp.StanzaNode? captured_legacy_omemo_encrypted_node = null;
        Xmpp.StanzaNode? captured_omemo2_encrypted_node = null;
        bool captured_has_outer_oob = false;
        bool captured_has_outer_sfs = false;
        bool captured_has_outer_sources = false;
        bool captured_has_outer_attach = false;
        Error? captured_stanza_error = null;
        Error? pending_error = null;
        Error? cleanup_error = null;
        Error? temp_cleanup_error = null;
        ulong received_handler = 0;
        ulong pre_message_send_handler = 0;
        Context? omemo_context = null;
        OmemoRuntime? runtime = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            configure_isolated_storage(temp_dir);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("OMEMO context could not be initialized");
            }
            omemo_context = Dino.Plugins.Omemo.Plugin.get_context();
            Context context = (!) omemo_context;

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-omemo-private-muc-http-smoke");
            omemo_db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            Security.FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption);

            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OMEMO private-MUC HTTP file smoke");
            }
            runtime = install_omemo_runtime((!) stream_interactor, (!) omemo_db, (!) file_manager,
                !(protocol == OmemoSmokeProtocol.OMEMO2 && key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY));
            http_provider = new Dino.Plugins.HttpFiles.FileProvider((!) stream_interactor, (!) core_db);
            http_sender = new HttpFileSender((!) stream_interactor, (!) core_db);
            ((!) file_manager).add_provider((!) http_provider);
            ((!) file_manager).add_sender((!) http_sender);

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

            if (config.extra_receiver_jid != null && config.extra_receiver_password != null) {
                extra_receiver_account = new Account(((!) config.extra_receiver_jid).bare_jid, (!) config.extra_receiver_password);
                ((!) extra_receiver_account).enabled = true;
                ((!) extra_receiver_account).custom_host = config.custom_host;
                ((!) extra_receiver_account).custom_port = config.custom_port;
                config.apply_account_proxy((!) extra_receiver_account);
                persist_remote_smoke_account_without_password((!) core_db, (!) extra_receiver_account);
            }

            seed_trusted_roster_contact((!) core_db, (!) sender_account, config.receiver_jid);
            seed_trusted_roster_contact((!) core_db, (!) receiver_account, config.sender_jid);
            if (extra_receiver_account != null && config.extra_receiver_jid != null) {
                seed_trusted_roster_contact((!) core_db, (!) sender_account, (!) config.extra_receiver_jid);
                seed_trusted_roster_contact((!) core_db, (!) extra_receiver_account, config.sender_jid);
            }

            if (protocol == OmemoSmokeProtocol.OMEMO2 && key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY) {
                seed_identity_for_manual_pubsub_fixture(context, (!) omemo_db, (!) sender_account);
                seed_identity_for_manual_pubsub_fixture(context, (!) omemo_db, (!) receiver_account);
                if (extra_receiver_account != null) {
                    seed_identity_for_manual_pubsub_fixture(context, (!) omemo_db, (!) extra_receiver_account);
                }
            }

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) sender_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) receiver_account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }
            if (extra_receiver_account != null) {
                if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) extra_receiver_account, config.timeout_seconds, out connect_failure))) {
                    throw new IOError.TIMED_OUT(connect_failure);
                }
            }

            sender_store = yield wait_for_omemo_store((!) stream_interactor, (!) omemo_db, (!) sender_account, config.timeout_seconds);
            receiver_store = yield wait_for_omemo_store((!) stream_interactor, (!) omemo_db, (!) receiver_account, config.timeout_seconds);
            if (extra_receiver_account != null && config.extra_receiver_jid != null) {
                extra_receiver_store = yield wait_for_omemo_store((!) stream_interactor, (!) omemo_db, (!) extra_receiver_account, config.timeout_seconds);
            }
            int sender_identity_id = ((!) omemo_db).identity.get_id(((!) sender_account).id);
            int receiver_identity_id = ((!) omemo_db).identity.get_id(((!) receiver_account).id);
            if (sender_identity_id < 0 || receiver_identity_id < 0) {
                throw new IOError.FAILED("remote OMEMO smoke could not resolve account identities");
            }

            if (protocol == OmemoSmokeProtocol.OMEMO2) {
                sender_own_secondary_store = setup_test_store_context(context);
            }

            if (key_setup == OmemoSmokeKeySetup.SEEDED) {
                if (protocol == OmemoSmokeProtocol.OMEMO2) {
                    prepare_pre_key_session_v2(context, (!) sender_store, ((!) receiver_account).bare_jid, (!) receiver_store, 51001, 52001);
                    prepare_pre_key_session_v2(context, (!) sender_store, ((!) sender_account).bare_jid, (!) sender_own_secondary_store, 51090, 52090);
                } else {
                    prepare_pre_key_session(context, (!) sender_store, ((!) receiver_account).bare_jid, (!) receiver_store, 51001, 52001);
                }
                if (protocol == OmemoSmokeProtocol.OMEMO2) {
                    add_trusted_omemo2_device((!) omemo_db, sender_identity_id, ((!) receiver_account).bare_jid, (!) receiver_store);
                    add_trusted_omemo2_device((!) omemo_db, sender_identity_id, ((!) sender_account).bare_jid, (!) sender_own_secondary_store);
                    add_trusted_omemo2_device((!) omemo_db, receiver_identity_id, ((!) sender_account).bare_jid, (!) sender_store);
                } else {
                    add_trusted_omemo1_device((!) omemo_db, sender_identity_id, ((!) receiver_account).bare_jid, (!) receiver_store);
                    add_trusted_omemo1_device((!) omemo_db, receiver_identity_id, ((!) sender_account).bare_jid, (!) sender_store);
                }
                if (extra_receiver_account != null && extra_receiver_store != null) {
                    int extra_receiver_identity_id = ((!) omemo_db).identity.get_id(((!) extra_receiver_account).id);
                    if (extra_receiver_identity_id < 0) {
                        throw new IOError.FAILED("remote OMEMO smoke could not resolve extra receiver identity");
                    }
                    if (protocol == OmemoSmokeProtocol.OMEMO2) {
                        prepare_pre_key_session_v2(context, (!) sender_store, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store, 51002, 52002);
                        add_trusted_omemo2_device((!) omemo_db, sender_identity_id, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store);
                        add_trusted_omemo2_device((!) omemo_db, extra_receiver_identity_id, ((!) sender_account).bare_jid, (!) sender_store);
                    } else {
                        prepare_pre_key_session(context, (!) sender_store, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store, 51002, 52002);
                        add_trusted_omemo1_device((!) omemo_db, sender_identity_id, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store);
                        add_trusted_omemo1_device((!) omemo_db, extra_receiver_identity_id, ((!) sender_account).bare_jid, (!) sender_store);
                    }
                }
            }

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) {
                throw new IOError.FAILED("MucManager was not started for remote OMEMO private-MUC HTTP file smoke");
            }
            ConversationManager? conversation_manager = ((!) stream_interactor).get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (conversation_manager == null) {
                throw new IOError.FAILED("ConversationManager was not started for remote OMEMO private-MUC HTTP file smoke");
            }
            MessageProcessor? message_processor = ((!) stream_interactor).get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            if (message_processor == null) {
                throw new IOError.FAILED("MessageProcessor was not started for remote OMEMO private-MUC HTTP file smoke");
            }

            sender_stream = ((!) stream_interactor).get_stream((!) sender_account);
            if (sender_stream == null) {
                throw new IOError.NOT_CONNECTED("No sender stream after XMPP negotiation");
            }
            sender_muc_module = ((!) sender_stream).get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            if (sender_muc_module == null) {
                throw new IOError.FAILED("XEP-0045 MUC module is not attached to sender stream");
            }

            yield join_generated_room((!) sender_stream, (!) sender_muc_module, config);
            Xep.DataForms.DataForm? data_form = yield ((!) sender_muc_module).get_config_form((!) sender_stream, config.room_jid.bare_jid);
            if (data_form == null) {
                throw new IOError.FAILED("remote generated OMEMO private-MUC config form was not available");
            }
            configure_generated_private_room((!) data_form);
            yield set_config_form_checked((!) sender_stream, config.room_jid.bare_jid, (!) data_form);
            yield change_affiliation_checked((!) sender_stream, config.room_jid.bare_jid, config.receiver_jid.bare_jid, "member");
            if (config.extra_receiver_jid != null) {
                yield change_affiliation_checked((!) sender_stream, config.room_jid.bare_jid, ((!) config.extra_receiver_jid).bare_jid, "member");
            }

            yield join_room((!) muc_manager, (!) receiver_account, config.room_jid.bare_jid, config.receiver_nick, config.timeout_seconds);
            if (extra_receiver_account != null) {
                yield join_room((!) muc_manager, (!) extra_receiver_account, config.room_jid.bare_jid, config.extra_receiver_nick, config.timeout_seconds);
            }

            sender_conversation = ((!) conversation_manager).create_conversation(
                    config.room_jid.bare_jid, (!) sender_account, Conversation.Type.GROUPCHAT);
            ((!) sender_conversation).nickname = config.sender_nick;
            ((!) sender_conversation).encryption = Encryption.OMEMO;
            ((!) sender_conversation).send_typing = Conversation.Setting.OFF;
            ((!) sender_conversation).send_marker = Conversation.Setting.OFF;

            Conversation? maybe_receiver_conversation = ((!) conversation_manager).get_conversation(
                    config.room_jid.bare_jid, (!) receiver_account, Conversation.Type.GROUPCHAT);
            if (maybe_receiver_conversation == null) {
                throw new IOError.FAILED("receiver account did not create the private-MUC conversation after join");
            }
            receiver_conversation = (!) maybe_receiver_conversation;
            ((!) receiver_conversation).send_typing = Conversation.Setting.OFF;
            ((!) receiver_conversation).send_marker = Conversation.Setting.OFF;
            if (extra_receiver_account != null) {
                Conversation? maybe_extra_receiver_conversation = ((!) conversation_manager).get_conversation(
                        config.room_jid.bare_jid, (!) extra_receiver_account, Conversation.Type.GROUPCHAT);
                if (maybe_extra_receiver_conversation == null) {
                    throw new IOError.FAILED("extra receiver account did not create the private-MUC conversation after join");
                }
                extra_receiver_conversation = (!) maybe_extra_receiver_conversation;
                ((!) extra_receiver_conversation).send_typing = Conversation.Setting.OFF;
                ((!) extra_receiver_conversation).send_marker = Conversation.Setting.OFF;
            }

            Gee.List<Jid>? snapshot = yield wait_for_configured_private_muc_snapshot((!) muc_manager,
                (!) sender_muc_module, (!) sender_stream, (!) sender_account, config);
            validate_private_muc_snapshot((!) muc_manager, (!) sender_account, config.room_jid.bare_jid, snapshot, config);
            if (protocol == OmemoSmokeProtocol.OMEMO2 && key_setup == OmemoSmokeKeySetup.SEEDED) {
                replace_own_omemo2_devices_for_smoke((!) omemo_db, sender_identity_id, (!) sender_account, (!) sender_own_secondary_store);
            }
            if (key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY) {
                if (protocol == OmemoSmokeProtocol.OMEMO2) {
                    yield prepare_omemo2_pubsub_discovery(context, (!) stream_interactor, (!) omemo_db,
                        (!) sender_conversation,
                        (!) sender_account, (!) sender_store, (!) sender_own_secondary_store,
                        (!) receiver_account, (!) receiver_store,
                        extra_receiver_account, extra_receiver_store, config.timeout_seconds);
                } else {
                    yield prepare_omemo1_pubsub_discovery((!) stream_interactor, (!) omemo_db,
                        (!) sender_conversation,
                        (!) sender_account, (!) sender_store, (!) receiver_account, (!) receiver_store,
                        extra_receiver_account, extra_receiver_store, config.timeout_seconds);
                }
            }
            assert_sender_omemo_readiness((!) runtime, (!) sender_account, config.receiver_jid, config.extra_receiver_jid, protocol);

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
                    // received_file follows persistence. Model the recipient's
                    // Download action; fresh MUC accounts need not auto-download.
                    if (file_transfer.state == FileTransfer.State.NOT_STARTED) {
                        ((!) file_manager).download_file.begin(file_transfer);
                    }
                } else if (extra_receiver_account != null &&
                        Account.equals_func(file_transfer.account, (!) extra_receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
                    extra_received_transfer = file_transfer;
                    extra_receiver_conversation = conversation;
                    if (file_transfer.state == FileTransfer.State.NOT_STARTED) {
                        ((!) file_manager).download_file.begin(file_transfer);
                    }
                }
            });
            pre_message_send_handler = ((!) message_processor).pre_message_send.connect((message, stanza, conversation) => {
                // Deferred session setup retries this message with a fresh stanza.
                // Keep the latest attempt so assertions inspect the stanza sent.
                if (captured_body_url_message != null && captured_body_url_message != message) return;
                if (sender_conversation == null || conversation != (!) sender_conversation) return;
                if (message.encryption != Encryption.OMEMO) return;
                if (message.body == null || !((string) message.body).has_prefix("aesgcm://")) return;
                captured_body_url_message = message;
                captured_outer_body = stanza.body;
                captured_stanza_to = stanza.to;
                captured_stanza_type = stanza.type_;
                captured_has_outer_oob = stanza.stanza.get_subnode("x", Xmpp.Xep.OutOfBandData.NS_URI) != null;
                captured_has_outer_sfs = stanza.stanza.get_subnode("file-sharing", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_sources = stanza.stanza.get_subnode("sources", Xmpp.Xep.StatelessFileSharing.NS_URI) != null;
                captured_has_outer_attach = stanza.stanza.get_subnode("attach-to", Xmpp.Xep.MessageAttaching.NS_URI) != null;
                captured_legacy_omemo_encrypted_node = stanza.stanza.get_subnode("encrypted", NS_OMEMO_LEGACY);
                captured_omemo2_encrypted_node = stanza.stanza.get_subnode("encrypted", NS_OMEMO_V2);
                captured_stanza_error = null;
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
                    (config.extra_receiver_jid == null ||
                        (extra_received_transfer != null &&
                        ((!) extra_received_transfer).state == FileTransfer.State.COMPLETE &&
                        ((!) extra_received_transfer).phase == FileTransfer.Phase.COMPLETE)) &&
                    captured_body_url_message != null &&
                    message_reached_remote_send_boundary((!) captured_body_url_message)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote OMEMO private-MUC HTTP send/receive completion (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)), extra=$(format_transfer_state(extra_received_transfer)), message=$(format_message_marked(captured_body_url_message)))");
            }
            if (captured_stanza_error != null) throw (!) captured_stanza_error;
            drain_pending_events();

            if (protocol == OmemoSmokeProtocol.OMEMO1 && key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY) {
                assert_omemo1_session_state((!) sender_store, ((!) receiver_account).bare_jid, (!) receiver_store, true);
                assert_omemo1_session_state((!) receiver_store, ((!) sender_account).bare_jid, (!) sender_store, true);
                if (extra_receiver_account != null && extra_receiver_store != null) {
                    assert_omemo1_session_state((!) sender_store, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store, true);
                    assert_omemo1_session_state((!) extra_receiver_store, ((!) sender_account).bare_jid, (!) sender_store, true);
                }
            }

            FileTransfer sender_transfer = (!) sent_transfer;
            FileTransfer receiver_transfer = (!) received_transfer;
            string body_url = require_aesgcm_body_url((!) captured_body_url_message);
            string download_url = aesgcm_to_https_link(body_url);
            validate_sent_transfer(sender_transfer, (!) sender_conversation, config, download_url);
            validate_received_transfer(receiver_transfer, (!) receiver_conversation, config);
            validate_captured_omemo_body_url_message((!) captured_body_url_message, captured_outer_body,
                captured_stanza_to, captured_stanza_type, captured_legacy_omemo_encrypted_node,
                captured_omemo2_encrypted_node, captured_has_outer_oob,
                captured_has_outer_sfs, captured_has_outer_sources, captured_has_outer_attach, body_url,
                download_url, config, (!) sender_store, (!) receiver_store, extra_receiver_store,
                sender_own_secondary_store, protocol, key_setup);
            yield validate_stored_payload(file_encryption, receiver_transfer, config.payload_text.length, expected_sha256);
            if (extra_received_transfer != null && extra_receiver_conversation != null) {
                validate_received_transfer((!) extra_received_transfer, (!) extra_receiver_conversation, config);
                yield validate_stored_payload(file_encryption, (!) extra_received_transfer, config.payload_text.length, expected_sha256);
            }
            assert_phase_order(phases, FileTransfer.Phase.STORING, FileTransfer.Phase.REQUESTING_SLOT,
                "remote OMEMO send must store the local copy before requesting the XEP-0363 slot");
            assert_phase_order(phases, FileTransfer.Phase.REQUESTING_SLOT, FileTransfer.Phase.UPLOADING,
                "remote OMEMO send must request the slot before HTTPS upload");
            assert_phase_order(phases, FileTransfer.Phase.UPLOADING, FileTransfer.Phase.ANNOUNCING,
                "remote OMEMO send must upload before the encrypted body-url announcement");
            assert_phase_order(phases, FileTransfer.Phase.ANNOUNCING, FileTransfer.Phase.COMPLETE,
                "remote OMEMO send must finish after the encrypted body-url announcement");
            if (count_pending_receive_files((!) core_db) != 0) {
                throw new IOError.FAILED("remote OMEMO private-MUC HTTP receive-store left pending receive files");
            }

            if (received_handler != 0) {
                SignalHandler.disconnect((!) file_manager, received_handler);
                received_handler = 0;
            }
            if (pre_message_send_handler != 0) {
                SignalHandler.disconnect((!) message_processor, pre_message_send_handler);
                pre_message_send_handler = 0;
            }
            GLib.Test.message(@"Remote $(protocol_label(protocol)) $(key_setup_label(key_setup)) private-MUC HTTP send/receive smoke passed for generated room $(config.room_jid.bare_jid.to_string())");
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

        if (sender_stream != null && sender_muc_module != null) {
            try {
                yield ((!) sender_muc_module).destroy_room((!) sender_stream, config.room_jid.bare_jid, "DinoX remote OMEMO private-MUC HTTP file smoke cleanup");
            } catch (Error e) {
                cleanup_error = e;
                GLib.Test.message(@"Could not destroy generated remote OMEMO private-MUC HTTP smoke room $(config.room_jid.bare_jid.to_string()): $(e.message)");
                ((!) sender_muc_module).exit((!) sender_stream, config.room_jid.bare_jid);
            }
        }
        if (protocol == OmemoSmokeProtocol.OMEMO2 && key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY &&
                stream_interactor != null && sender_account != null && sender_store != null &&
                receiver_account != null && receiver_store != null && omemo_context != null) {
            try {
                yield restore_omemo2_pubsub_discovery_state((!) omemo_context, (!) stream_interactor,
                    (!) sender_account, (!) sender_store, sender_own_secondary_store,
                    (!) receiver_account, (!) receiver_store, extra_receiver_account, extra_receiver_store);
            } catch (Error e) {
                if (cleanup_error == null) cleanup_error = e;
                GLib.Test.message(@"Could not restore remote OMEMO2 PubSub smoke device state: $(e.message)");
            }
        }
        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) receiver_account);
        }
        if (stream_interactor != null && extra_receiver_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) extra_receiver_account);
        }
        if (stream_interactor != null && sender_account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) sender_account);
        }
        restore_default_application(application, previous_application);
        if (omemo_db != null) {
            ((!) omemo_db).close();
            omemo_db = null;
        }
        if (core_db != null) {
            ((!) core_db).close();
            core_db = null;
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote OMEMO private-MUC HTTP smoke temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, cleanup_error, temp_cleanup_error, config.room_jid.bare_jid, temp_dir);
    }

    private static void start_remote_file_modules(StreamInteractor stream_interactor, Dino.Database db,
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
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor);
        FileManager.start(stream_interactor, db, file_encryption);
        CallStore.start(stream_interactor, db);
        ContentItemStore.start(stream_interactor, db);
        StatelessFileSharing.start(stream_interactor, db);
    }

    private static OmemoRuntime install_omemo_runtime(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, FileManager file_manager, bool auto_publish_own_device_lists = true) {
        OmemoRuntime runtime = new OmemoRuntime();
        runtime.trust_manager = new Dino.Plugins.Omemo.TrustManager(stream_interactor, omemo_db);
        runtime.decryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoDecryptor>(Account.hash_func, Account.equals_func);
        runtime.encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(Account.hash_func, Account.equals_func);
        runtime.decryptors_v2 = new HashMap<Account, Dino.Plugins.Omemo.Omemo2Decrypt>(Account.hash_func, Account.equals_func);
        runtime.encryptors_v2 = new HashMap<Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Account.hash_func, Account.equals_func);
        _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule));
        _force_class_init(typeof(Dino.Plugins.Omemo.StreamModule2));
        _force_class_init(typeof(Dino.Plugins.Omemo.Manager));

        stream_interactor.module_manager.initialize_account_modules.connect((account, modules) => {
            Store store = Dino.Plugins.Omemo.Plugin.get_context().create_store();
            var stream_module = new Dino.Plugins.Omemo.StreamModule(store);
            stream_module.auto_publish_own_device_list = auto_publish_own_device_lists;
            modules.add(stream_module);
            if (runtime.trust_manager.omemo2_enabled) {
                var stream_module2 = new Dino.Plugins.Omemo.StreamModule2(store);
                stream_module2.auto_publish_own_device_list = auto_publish_own_device_lists;
                modules.add(stream_module2);
            }
            runtime.decryptors[account] = new Dino.Plugins.Omemo.OmemoDecryptor(
                account, stream_interactor, runtime.trust_manager, omemo_db, store);
            modules.add(runtime.decryptors[account]);
            runtime.encryptors[account] = new Dino.Plugins.Omemo.OmemoEncryptor(account, runtime.trust_manager, store);
            modules.add(runtime.encryptors[account]);
            if (runtime.trust_manager.omemo2_enabled) {
                runtime.decryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Decrypt(
                    account, stream_interactor, runtime.trust_manager, omemo_db, store);
                modules.add(runtime.decryptors_v2[account]);
                runtime.encryptors_v2[account] = new Dino.Plugins.Omemo.Omemo2Encrypt(account, runtime.trust_manager, store);
                modules.add(runtime.encryptors_v2[account]);
            }
        });

        MessageProcessor? message_processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        if (message_processor != null) {
            ((!) message_processor).received_pipeline.connect(new Dino.Plugins.Omemo.DecryptMessageListener(runtime.decryptors));
            if (runtime.trust_manager.omemo2_enabled) {
                ((!) message_processor).received_pipeline.connect(new Dino.Plugins.Omemo.Omemo2DecryptMessageListener(runtime.decryptors_v2));
            }
        }
        file_manager.add_file_decryptor(new Dino.Plugins.Omemo.OmemoFileDecryptor());
        file_manager.add_file_encryptor(new Dino.Plugins.Omemo.OmemoFileEncryptor());
        runtime.manager = Dino.Plugins.Omemo.Manager.start(stream_interactor, omemo_db, runtime.trust_manager,
            runtime.encryptors, runtime.encryptors_v2);
        runtime.manager.auto_publish_own_device_lists = auto_publish_own_device_lists;
        return runtime;
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
            throw new IOError.PERMISSION_DENIED(@"remote OMEMO private-MUC HTTP smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
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

    private async Store wait_for_omemo_store(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, Account account, uint timeout_seconds) throws Error {
        Store? store = null;
        bool success = yield wait_for_condition(timeout_seconds, () => {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return false;
            Dino.Plugins.Omemo.StreamModule? module = ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule>(
                Dino.Plugins.Omemo.StreamModule.IDENTITY);
            if (module == null) return false;
            if (((!) module).store.local_registration_id == 0) return false;
            if (!((!) module).store.is_persistence_ready || ((!) module).store.registration_pending) return false;
            if (omemo_db.identity.get_id(account.id) < 0) return false;
            store = ((!) module).store;
            return true;
        });
        if (!success || store == null) {
            throw new IOError.TIMED_OUT("timed out waiting for persistent OMEMO identity and confirmed device registration");
        }
        return (!) store;
    }

    private async void prepare_omemo1_pubsub_discovery(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, Conversation sender_conversation,
            Account sender_account, Store sender_store, Account receiver_account, Store receiver_store,
            Account? extra_receiver_account, Store? extra_receiver_store, uint timeout_seconds) throws Error {
        Dino.Plugins.Omemo.Manager? manager =
            stream_interactor.get_module<Dino.Plugins.Omemo.Manager>(Dino.Plugins.Omemo.Manager.IDENTITY);
        if (manager == null) {
            throw new IOError.FAILED("OMEMO manager was not started for remote PubSub discovery smoke");
        }

        // Kick the production private-MUC key discovery path, then assert the
        // stronger identity/trust state below because the helper may return
        // after a device-list result before bundle fetch completes.
        bool initial_probe = yield ensure_get_keys_for_conversation_with_timeout((!) manager, sender_conversation, 10);
        if (!initial_probe) {
            GLib.Test.message("Initial OMEMO1 private-MUC PubSub discovery probe returned false; continuing until identity/trust proof timeout");
        }

        yield wait_for_omemo1_pubsub_metadata(stream_interactor, omemo_db, (!) manager,
            sender_account, sender_store, receiver_account.bare_jid, receiver_store,
            timeout_seconds, "sender-to-receiver");
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield wait_for_omemo1_pubsub_metadata(stream_interactor, omemo_db, (!) manager,
                sender_account, sender_store, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store,
                timeout_seconds, "sender-to-extra-receiver");
        }

        yield wait_for_omemo1_pubsub_metadata(stream_interactor, omemo_db, (!) manager,
            receiver_account, receiver_store, sender_account.bare_jid, sender_store,
            timeout_seconds, "receiver-to-sender");
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield wait_for_omemo1_pubsub_metadata(stream_interactor, omemo_db, (!) manager,
                (!) extra_receiver_account, (!) extra_receiver_store, sender_account.bare_jid, sender_store,
                timeout_seconds, "extra-receiver-to-sender");
        }
    }

    private async void wait_for_omemo1_pubsub_metadata(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, Dino.Plugins.Omemo.Manager manager,
            Account local_account, Store local_store, Jid remote_jid, Store remote_store,
            uint timeout_seconds, string label) throws Error {
        if (remote_store.local_registration_id == 0) {
            throw new IOError.FAILED(@"remote OMEMO1 PubSub discovery target $label has no local registration id");
        }

        int32 remote_device_id = (int32) remote_store.local_registration_id;
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        bool saw_device_in_devicelist = false;
        while (get_monotonic_time() < deadline) {
            if (saw_device_in_devicelist &&
                    is_omemo1_pubsub_metadata_ready(omemo_db, local_account, remote_jid, remote_store)) {
                assert_omemo1_session_state(local_store, remote_jid, remote_store, false);
                return;
            }

            XmppStream? stream = stream_interactor.get_stream(local_account);
            if (stream == null) {
                throw new IOError.NOT_CONNECTED(@"remote OMEMO1 PubSub discovery lost stream for $label");
            }
            Dino.Plugins.Omemo.StreamModule? module =
                ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
            if (module == null) {
                throw new IOError.FAILED(@"remote OMEMO1 PubSub discovery has no legacy module for $label");
            }

            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            yield ensure_get_keys_for_jid_with_timeout(manager, local_account, remote_jid.bare_jid, step_timeout);
            Gee.ArrayList<int32>? device_list = yield request_omemo1_devicelist_with_timeout(
                (!) module, (!) stream, remote_jid.bare_jid, step_timeout);
            if (device_list != null && contains_device_id((!) device_list, remote_device_id)) {
                saw_device_in_devicelist = true;
                ((!) module).fetch_bundle_info((!) stream, remote_jid.bare_jid, remote_device_id, false);
            }

            if (saw_device_in_devicelist &&
                    is_omemo1_pubsub_metadata_ready(omemo_db, local_account, remote_jid, remote_store)) {
                assert_omemo1_session_state(local_store, remote_jid, remote_store, false);
                return;
            }

            Timeout.add(500, () => {
                wait_for_omemo1_pubsub_metadata.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT(@"timed out waiting for remote OMEMO1 PubSub device-list/identity/trust discovery ($label)");
    }

    private async bool ensure_get_keys_for_conversation_with_timeout(Dino.Plugins.Omemo.Manager manager,
            Conversation conversation, uint timeout_seconds) {
        bool completed = false;
        bool result = false;
        SourceFunc resume = ensure_get_keys_for_conversation_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        manager.ensure_get_keys_for_conversation.begin(conversation, (obj, res) => {
            bool async_result = manager.ensure_get_keys_for_conversation.end(res);
            if (completed) return;
            completed = true;
            result = async_result;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return result;
    }

    private async bool ensure_get_keys_for_jid_with_timeout(Dino.Plugins.Omemo.Manager manager,
            Account account, Jid jid, uint timeout_seconds) {
        bool completed = false;
        bool result = false;
        SourceFunc resume = ensure_get_keys_for_jid_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        manager.ensure_get_keys_for_jid.begin(account, jid, (obj, res) => {
            bool async_result = manager.ensure_get_keys_for_jid.end(res);
            if (completed) return;
            completed = true;
            result = async_result;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return result;
    }

    private async Gee.ArrayList<int32>? request_omemo1_devicelist_with_timeout(
            Dino.Plugins.Omemo.StreamModule module, XmppStream stream, Jid jid, uint timeout_seconds) {
        bool completed = false;
        Gee.ArrayList<int32>? result = null;
        SourceFunc resume = request_omemo1_devicelist_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        module.request_user_devicelist.begin(stream, jid, (obj, res) => {
            Gee.ArrayList<int32> async_result = module.request_user_devicelist.end(res);
            if (completed) return;
            completed = true;
            result = async_result;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return result;
    }

    private static uint remaining_timeout_seconds(int64 deadline, uint max_seconds) {
        int64 remaining_us = deadline - get_monotonic_time();
        if (remaining_us <= 0) return 0;
        int64 remaining_seconds = (remaining_us + 999999) / 1000000;
        if (remaining_seconds < 1) return 1;
        if (remaining_seconds > max_seconds) return max_seconds;
        return (uint) remaining_seconds;
    }

    private static bool contains_device_id(Gee.List<int32> device_list, int32 device_id) {
        foreach (int32 listed_device_id in device_list) {
            if (listed_device_id == device_id) return true;
        }
        return false;
    }

    private static bool is_omemo1_pubsub_metadata_ready(Dino.Plugins.Omemo.Database omemo_db,
            Account local_account, Jid remote_jid, Store remote_store) {
        int32 remote_device_id = (int32) remote_store.local_registration_id;
        int identity_id = omemo_db.identity.get_id(local_account.id);
        if (identity_id < 0 || remote_device_id <= 0) return false;

        Row? device = omemo_db.identity_meta.get_device(identity_id, remote_jid.bare_jid.to_string(), remote_device_id);
        if (device == null) return false;
        Row device_row = (!) device;
        string? identity_key = device_row[omemo_db.identity_meta.identity_key_public_base64];
        if (identity_key == null || ((!) identity_key).length == 0) return false;
        if (identity_key != Base64.encode(remote_store.identity_key_store.identity_key_public.get_data())) return false;
        if (device_row[omemo_db.identity_meta.identity_key_changed]) return false;
        if (!device_row[omemo_db.identity_meta.now_active]) return false;
        if (!device_row[omemo_db.identity_meta.supports_omemo1]) return false;
        if ((Dino.Plugins.Omemo.TrustLevel) device_row[omemo_db.identity_meta.trust_level] != Dino.Plugins.Omemo.TrustLevel.TRUSTED) {
            return false;
        }

        return true;
    }

    private static void assert_omemo1_session_state(Store local_store, Jid remote_jid,
            Store remote_store, bool expected) throws Error {
        Address address = new Address(remote_jid.bare_jid.to_string(), (int32) remote_store.local_registration_id);
        try {
            bool has_session = local_store.contains_session(address);
            if (has_session != expected) {
                throw new IOError.FAILED(expected
                    ? "the first encrypted file send/receive must establish the native OMEMO1 session"
                    : "OMEMO1 discovery must not create a native session before the first encrypted send");
            }
        } finally {
            address.device_id = 0;
        }
    }

    private static void seed_identity_for_manual_pubsub_fixture(Context context,
            Dino.Plugins.Omemo.Database db, Account account) throws Error {
        // Only v2-only fixtures with automatic publication disabled use an
        // existing local identity. Legacy runs exercise real first registration.
        if (db.identity.get_id_checked(account.id) > 0) {
            throw new IOError.FAILED("manual PubSub fixture identity must be fresh");
        }
        ECKeyPair key_pair = context.generate_key_pair();
        db.identity.upsert()
            .value(db.identity.account_id, account.id, true)
            .value(db.identity.device_id, Random.int_range(1, int32.MAX))
            .value(db.identity.registration_pending, false)
            .value(db.identity.identity_key_private_base64, Base64.encode(key_pair.private.serialize()))
            .value(db.identity.identity_key_public_base64, Base64.encode(key_pair.public.serialize()))
            .perform_checked();
    }

    private async void prepare_omemo2_pubsub_discovery(Context context, StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, Conversation sender_conversation,
            Account sender_account, Store sender_store, Store sender_own_secondary_store,
            Account receiver_account, Store receiver_store,
            Account? extra_receiver_account, Store? extra_receiver_store, uint timeout_seconds) throws Error {
        Dino.Plugins.Omemo.Manager? manager =
            stream_interactor.get_module<Dino.Plugins.Omemo.Manager>(Dino.Plugins.Omemo.Manager.IDENTITY);
        if (manager == null) {
            throw new IOError.FAILED("OMEMO manager was not started for remote OMEMO2 PubSub discovery smoke");
        }

        yield publish_omemo2_v2_only_state(context, stream_interactor, sender_account, sender_store,
            sender_own_secondary_store, 61000);
        yield publish_omemo2_v2_only_state(context, stream_interactor, receiver_account, receiver_store,
            null, 62000);
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield publish_omemo2_v2_only_state(context, stream_interactor, (!) extra_receiver_account,
                (!) extra_receiver_store, null, 63000);
        }

        clear_omemo_address_state(omemo_db, sender_account, sender_account.bare_jid);
        clear_omemo_address_state(omemo_db, sender_account, receiver_account.bare_jid);
        clear_omemo_address_state(omemo_db, receiver_account, sender_account.bare_jid);
        if (extra_receiver_account != null) {
            clear_omemo_address_state(omemo_db, sender_account, ((!) extra_receiver_account).bare_jid);
            clear_omemo_address_state(omemo_db, (!) extra_receiver_account, sender_account.bare_jid);
        }

        bool initial_probe = yield ensure_get_keys_for_conversation_with_timeout((!) manager, sender_conversation, 10);
        if (!initial_probe) {
            GLib.Test.message("Initial OMEMO2 private-MUC PubSub discovery probe returned false; continuing until bundle/session proof timeout");
        }

        yield wait_for_omemo2_pubsub_session(stream_interactor, omemo_db, (!) manager,
            sender_account, sender_store, receiver_account.bare_jid, receiver_store,
            timeout_seconds, "sender-to-receiver");
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield wait_for_omemo2_pubsub_session(stream_interactor, omemo_db, (!) manager,
                sender_account, sender_store, ((!) extra_receiver_account).bare_jid, (!) extra_receiver_store,
                timeout_seconds, "sender-to-extra-receiver");
        }
        yield wait_for_omemo2_pubsub_session(stream_interactor, omemo_db, (!) manager,
            sender_account, sender_store, sender_account.bare_jid, sender_own_secondary_store,
            timeout_seconds, "sender-to-own-secondary");
        // Do not seed or wait for a session to the current sender. Discovery
        // may cache one, but outgoing delivery must not depend on it.
        yield wait_for_omemo2_pubsub_session(stream_interactor, omemo_db, (!) manager,
            receiver_account, receiver_store, sender_account.bare_jid, sender_store,
            timeout_seconds, "receiver-to-sender");
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield wait_for_omemo2_pubsub_session(stream_interactor, omemo_db, (!) manager,
                (!) extra_receiver_account, (!) extra_receiver_store, sender_account.bare_jid, sender_store,
                timeout_seconds, "extra-receiver-to-sender");
        }
    }

    private async void publish_omemo2_v2_only_state(Context context, StreamInteractor stream_interactor,
            Account account, Store current_store, Store? secondary_store, uint32 key_id_base) throws Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("remote OMEMO2 PubSub discovery lost stream before publish");
        Dino.Plugins.Omemo.StreamModule2? module2 =
            ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule2>(Dino.Plugins.Omemo.StreamModule2.IDENTITY);
        if (module2 == null) throw new IOError.FAILED("remote OMEMO2 PubSub discovery has no OMEMO2 stream module");

        yield publish_empty_omemo1_device_list((!) stream, account.bare_jid);

        var device_ids = new ArrayList<int32>();
        device_ids.add((int32) current_store.local_registration_id);
        yield publish_omemo2_bundle_for_store(context, (!) module2, (!) stream, current_store, key_id_base, (int) key_id_base + 500);
        if (secondary_store != null) {
            device_ids.add((int32) ((!) secondary_store).local_registration_id);
            yield publish_secondary_omemo2_bundle_for_store(context, (!) stream, account,
                current_store, (!) secondary_store, key_id_base + 100, (int) key_id_base + 600);
        }
        yield publish_omemo2_device_list((!) stream, account.bare_jid, device_ids);
    }

    private async void publish_empty_omemo1_device_list(XmppStream stream, Jid owner_jid) throws Error {
        var device_ids = new ArrayList<int32>();
        yield publish_omemo1_device_list(stream, owner_jid, device_ids);
    }

    private async void publish_omemo1_device_list(XmppStream stream, Jid owner_jid, Gee.List<int32> device_ids) throws Error {
        StanzaNode list_node = new StanzaNode.build("list", NS_OMEMO_LEGACY).add_self_xmlns();
        foreach (int32 device_id in device_ids) {
            list_node.put_node(new StanzaNode.build("device", NS_OMEMO_LEGACY)
                .put_attribute("id", device_id.to_string()));
        }
        var publish_options = new Xep.Pubsub.PublishOptions()
            .set_access_model(Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);
        bool ok = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY).publish(stream,
            owner_jid.bare_jid, NS_OMEMO_LEGACY + ".devicelist", "current", list_node, publish_options);
        if (!ok) throw new IOError.FAILED("server rejected temporary OMEMO1 device-list publish");
    }

    private async void publish_omemo2_device_list(XmppStream stream, Jid owner_jid, Gee.List<int32> device_ids) throws Error {
        StanzaNode devices_node = new StanzaNode.build("devices", NS_OMEMO_V2).add_self_xmlns();
        foreach (int32 device_id in device_ids) {
            devices_node.put_node(new StanzaNode.build("device", NS_OMEMO_V2)
                .put_attribute("id", device_id.to_string()));
        }
        var publish_options = new Xep.Pubsub.PublishOptions()
            .set_access_model(Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);
        bool ok = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY).publish(stream,
            owner_jid.bare_jid, Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", devices_node, publish_options);
        if (!ok) throw new IOError.FAILED("server rejected temporary OMEMO2 device-list publish");
    }

    private async void publish_omemo2_bundle_for_store(Context context, Dino.Plugins.Omemo.StreamModule2 module2,
            XmppStream stream, Store store, uint32 pre_key_base, int signed_pre_key_id) throws Error {
        SignedPreKeyRecord signed_pre_key_record;
        Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord>();
        ensure_omemo2_bundle_material(context, store, pre_key_base, signed_pre_key_id,
            out signed_pre_key_record, pre_key_records);
        bool published = yield module2.publish_bundle_v2(stream, signed_pre_key_record, store.identity_key_pair,
            pre_key_records, (int32) store.local_registration_id);
        if (!published) {
            throw new IOError.FAILED("remote OMEMO2 PubSub fixture current-device bundle publication failed");
        }
    }

    private async void publish_secondary_omemo2_bundle_for_store(Context context, XmppStream stream,
            Account account, Store current_store, Store secondary_store, uint32 pre_key_base,
            int signed_pre_key_id) throws Error {
        // This fixture models another device of the same account. The
        // production module correctly refuses to publish material owned by
        // that different Store; use a test-only PubSub fixture publication.
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        Jid? bound_jid = bind != null ? ((!) bind).my_jid : null;
        if (bound_jid == null || !((!) bound_jid).equals_bare(account.bare_jid) ||
                secondary_store == current_store || secondary_store.local_registration_id == 0 ||
                secondary_store.local_registration_id == current_store.local_registration_id ||
                secondary_store.identity_key_pair.public.compare(current_store.identity_key_pair.public) == 0) {
            throw new IOError.INVALID_DATA("remote OMEMO2 secondary-device fixture has an invalid account/key owner");
        }

        SignedPreKeyRecord signed_pre_key_record;
        Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord>();
        ensure_omemo2_bundle_material(context, secondary_store, pre_key_base, signed_pre_key_id,
            out signed_pre_key_record, pre_key_records);
        IdentityKeyPair identity_key_pair = secondary_store.identity_key_pair;
        ECKeyPair signed_key_pair = signed_pre_key_record.key_pair;
        StanzaNode bundle = new StanzaNode.build("bundle", NS_OMEMO_V2).add_self_xmlns()
            .put_node(new StanzaNode.build("spk", NS_OMEMO_V2)
                .put_attribute("id", signed_pre_key_record.id.to_string())
                .put_node(new StanzaNode.text(Base64.encode(signed_key_pair.public.mont.data))))
            .put_node(new StanzaNode.build("spks", NS_OMEMO_V2)
                .put_node(new StanzaNode.text(Base64.encode(signed_pre_key_record.signature_omemo))))
            .put_node(new StanzaNode.build("ik", NS_OMEMO_V2)
                .put_node(new StanzaNode.text(Base64.encode(identity_key_pair.public.ed.data))));
        StanzaNode prekeys = new StanzaNode.build("prekeys", NS_OMEMO_V2);
        foreach (PreKeyRecord pre_key_record in pre_key_records) {
            prekeys.put_node(new StanzaNode.build("pk", NS_OMEMO_V2)
                .put_attribute("id", pre_key_record.id.to_string())
                .put_node(new StanzaNode.text(Base64.encode(pre_key_record.key_pair.public.mont.data))));
        }
        bundle.put_node(prekeys);
        if (!Dino.Plugins.Omemo.StreamModule2.is_valid_omemo2_bundle(new Dino.Plugins.Omemo.Bundle2(bundle))) {
            throw new IOError.INVALID_DATA("remote OMEMO2 secondary-device fixture native bundle/signature is invalid");
        }

        var publish_options = new Xep.Pubsub.PublishOptions()
            .set_access_model(Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("max")
            .set_persist_items(true);
        bool published = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY).publish(stream,
            null, Xmpp.Xep.Omemo.NODE_BUNDLES_V2, ((int) secondary_store.local_registration_id).to_string(),
            bundle, publish_options);
        if (!published) {
            throw new IOError.FAILED("server rejected remote OMEMO2 secondary-device fixture bundle publication");
        }
    }

    private async void publish_omemo1_bundle_for_store(Context context, Dino.Plugins.Omemo.StreamModule module,
            XmppStream stream, Store store, uint32 pre_key_base, int signed_pre_key_id) throws Error {
        SignedPreKeyRecord signed_pre_key_record;
        Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord>();
        ensure_omemo1_bundle_material(context, store, pre_key_base, signed_pre_key_id,
            out signed_pre_key_record, pre_key_records);
        yield module.publish_bundles(stream, signed_pre_key_record, store.identity_key_pair,
            pre_key_records, (int32) store.local_registration_id);
    }

    private static void ensure_omemo1_bundle_material(Context context, Store store, uint32 pre_key_base,
            int signed_pre_key_id, out SignedPreKeyRecord signed_pre_key_record,
            Set<PreKeyRecord> pre_key_records) throws Error {
        ECKeyPair signed_pre_key_pair = context.generate_key_pair();
        uint8[] signed_pre_key_signature = context.calculate_signature(store.identity_key_pair.private,
            signed_pre_key_pair.public.serialize());
        throw_by_code(SignedPreKeyRecord.create(out signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), signed_pre_key_pair, signed_pre_key_signature, null));
        store.store_signed_pre_key(signed_pre_key_record);

        for (uint32 i = 0; i < 5; i++) {
            ECKeyPair pre_key_pair = context.generate_key_pair();
            PreKeyRecord pre_key_record;
            throw_by_code(PreKeyRecord.create(out pre_key_record, pre_key_base + i, pre_key_pair));
            store.store_pre_key(pre_key_record);
            pre_key_records.add(pre_key_record);
        }
    }

    private static void ensure_omemo2_bundle_material(Context context, Store store, uint32 pre_key_base,
            int signed_pre_key_id, out SignedPreKeyRecord signed_pre_key_record,
            Set<PreKeyRecord> pre_key_records) throws Error {
        ECKeyPair signed_pre_key_pair = context.generate_key_pair();
        uint8[] signed_pre_key_signature = context.calculate_signature(store.identity_key_pair.private,
            signed_pre_key_pair.public.serialize_omemo());
        throw_by_code(SignedPreKeyRecord.create(out signed_pre_key_record, signed_pre_key_id,
            new DateTime.now_utc().to_unix(), signed_pre_key_pair, new uint8[1], signed_pre_key_signature));
        store.store_signed_pre_key(signed_pre_key_record);

        for (uint32 i = 0; i < 5; i++) {
            ECKeyPair pre_key_pair = context.generate_key_pair();
            PreKeyRecord pre_key_record;
            throw_by_code(PreKeyRecord.create(out pre_key_record, pre_key_base + i, pre_key_pair));
            store.store_pre_key(pre_key_record);
            pre_key_records.add(pre_key_record);
        }
    }

    private static void clear_omemo_address_state(Dino.Plugins.Omemo.Database omemo_db, Account account, Jid jid) {
        int identity_id = omemo_db.identity.get_id(account.id);
        if (identity_id < 0) return;
        string address_name = jid.bare_jid.to_string();
        omemo_db.identity_meta.delete()
            .with(omemo_db.identity_meta.identity_id, "=", identity_id)
            .with(omemo_db.identity_meta.address_name, "=", address_name)
            .perform();
        omemo_db.session.delete()
            .with(omemo_db.session.identity_id, "=", identity_id)
            .with(omemo_db.session.address_name, "=", address_name)
            .perform();
        omemo_db.trust.delete()
            .with(omemo_db.trust.identity_id, "=", identity_id)
            .with(omemo_db.trust.address_name, "=", address_name)
            .perform();
    }

    private async void restore_omemo2_pubsub_discovery_state(Context context, StreamInteractor stream_interactor,
            Account sender_account, Store sender_store, Store? sender_own_secondary_store,
            Account receiver_account, Store receiver_store,
            Account? extra_receiver_account, Store? extra_receiver_store) throws Error {
        yield restore_omemo_pubsub_account_state(context, stream_interactor, sender_account, sender_store,
            sender_own_secondary_store, 71000);
        yield restore_omemo_pubsub_account_state(context, stream_interactor, receiver_account, receiver_store,
            null, 72000);
        if (extra_receiver_account != null && extra_receiver_store != null) {
            yield restore_omemo_pubsub_account_state(context, stream_interactor, (!) extra_receiver_account,
                (!) extra_receiver_store, null, 73000);
        }
    }

    private async void restore_omemo_pubsub_account_state(Context context, StreamInteractor stream_interactor,
            Account account, Store current_store, Store? secondary_store, uint32 key_id_base) throws Error {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("remote OMEMO PubSub smoke lost stream before device-state restore");
        Dino.Plugins.Omemo.StreamModule? module =
            ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
        Dino.Plugins.Omemo.StreamModule2? module2 =
            ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule2>(Dino.Plugins.Omemo.StreamModule2.IDENTITY);
        if (module == null || module2 == null) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke cannot restore device state without OMEMO stream modules");
        }

        var device_ids = new ArrayList<int32>();
        device_ids.add((int32) current_store.local_registration_id);
        int legacy_signed_pre_key_id = (int) key_id_base + 500;
        int omemo2_signed_pre_key_id = (int) key_id_base + 600;
        yield publish_omemo1_bundle_for_store(context, (!) module, (!) stream, current_store,
            key_id_base, legacy_signed_pre_key_id);
        yield publish_omemo2_bundle_for_store(context, (!) module2, (!) stream, current_store,
            key_id_base + 100, omemo2_signed_pre_key_id);
        yield publish_omemo1_device_list((!) stream, account.bare_jid, device_ids);
        yield publish_omemo2_device_list((!) stream, account.bare_jid, device_ids);

        if (secondary_store != null) {
            Xep.Pubsub.RetractResult retracted = yield ((!) stream).get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY).retract_item_with_result((!) stream,
                null, Xmpp.Xep.Omemo.NODE_BUNDLES_V2, ((int) ((!) secondary_store).local_registration_id).to_string(), false);
            if (!retracted.ok && !retracted.is_item_not_found()) {
                throw new IOError.FAILED("remote OMEMO PubSub smoke could not retract the temporary own secondary OMEMO2 bundle during restore: " + retracted.describe_error());
            }
        }

        yield verify_restored_omemo_pubsub_account_state((!) stream, (!) module, (!) module2, account, current_store,
            legacy_signed_pre_key_id, omemo2_signed_pre_key_id);
    }

    private async void verify_restored_omemo_pubsub_account_state(XmppStream stream,
            Dino.Plugins.Omemo.StreamModule module, Dino.Plugins.Omemo.StreamModule2 module2,
            Account account, Store current_store, int expected_legacy_signed_pre_key_id,
            int expected_omemo2_signed_pre_key_id) throws Error {
        int32 current_device_id = (int32) current_store.local_registration_id;
        if (current_device_id <= 0) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke cannot verify restored state without a current device id");
        }

        Gee.ArrayList<int32> legacy_devices = yield module.request_user_devicelist(stream, account.bare_jid);
        if (!device_list_matches_single_device(legacy_devices, current_device_id)) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke did not restore the legacy OMEMO device-list to the current device");
        }

        StanzaNode? legacy_bundle_node = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .request_item(stream, account.bare_jid, NS_OMEMO_LEGACY + ".bundles:" + current_device_id.to_string(), "current");
        if (legacy_bundle_node == null || new Dino.Plugins.Omemo.Bundle((!) legacy_bundle_node).signed_pre_key_id != expected_legacy_signed_pre_key_id) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke did not restore the legacy OMEMO current-device bundle");
        }

        Gee.ArrayList<int32> omemo2_devices = yield module2.request_user_devicelist(stream, account.bare_jid);
        if (!device_list_matches_single_device(omemo2_devices, current_device_id)) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke did not restore the OMEMO2 device-list to the current device");
        }

        StanzaNode? omemo2_bundle_node = yield stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY)
            .request_item(stream, account.bare_jid, Xmpp.Xep.Omemo.NODE_BUNDLES_V2, current_device_id.to_string());
        if (omemo2_bundle_node == null || new Dino.Plugins.Omemo.Bundle2((!) omemo2_bundle_node).signed_pre_key_id != expected_omemo2_signed_pre_key_id) {
            throw new IOError.FAILED("remote OMEMO PubSub smoke did not restore the OMEMO2 current-device bundle");
        }
    }

    private static bool device_list_matches_single_device(Gee.List<int32> devices, int32 expected_device_id) {
        if (devices.size != 1) return false;
        return devices[0] == expected_device_id;
    }

    private async void wait_for_omemo2_pubsub_session(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, Dino.Plugins.Omemo.Manager manager,
            Account local_account, Store local_store, Jid remote_jid, Store remote_store,
            uint timeout_seconds, string label) throws Error {
        if (remote_store.local_registration_id == 0) {
            throw new IOError.FAILED(@"remote OMEMO2 PubSub discovery target $label has no local registration id");
        }

        int32 remote_device_id = (int32) remote_store.local_registration_id;
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        bool saw_device_in_devicelist = false;
        while (get_monotonic_time() < deadline) {
            if (saw_device_in_devicelist &&
                    is_omemo2_pubsub_session_ready(omemo_db, local_account, local_store, remote_jid, remote_device_id)) {
                return;
            }

            XmppStream? stream = stream_interactor.get_stream(local_account);
            if (stream == null) {
                throw new IOError.NOT_CONNECTED(@"remote OMEMO2 PubSub discovery lost stream for $label");
            }
            Dino.Plugins.Omemo.StreamModule2? module2 =
                ((!) stream).get_module<Dino.Plugins.Omemo.StreamModule2>(Dino.Plugins.Omemo.StreamModule2.IDENTITY);
            if (module2 == null) {
                throw new IOError.FAILED(@"remote OMEMO2 PubSub discovery has no OMEMO2 module for $label");
            }

            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            yield ensure_get_keys_for_jid_with_timeout(manager, local_account, remote_jid.bare_jid, step_timeout);
            Gee.ArrayList<int32>? device_list = yield request_omemo2_devicelist_with_timeout(
                (!) module2, (!) stream, remote_jid.bare_jid, step_timeout);
            if (device_list != null && contains_device_id((!) device_list, remote_device_id)) {
                saw_device_in_devicelist = true;
                ((!) module2).fetch_bundle((!) stream, remote_jid.bare_jid, remote_device_id, false);
            }

            if (saw_device_in_devicelist &&
                    is_omemo2_pubsub_session_ready(omemo_db, local_account, local_store, remote_jid, remote_device_id)) {
                return;
            }

            Timeout.add(500, () => {
                wait_for_omemo2_pubsub_session.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT(@"timed out waiting for remote OMEMO2 PubSub device-list/bundle/session discovery ($label)");
    }

    private async Gee.ArrayList<int32>? request_omemo2_devicelist_with_timeout(
            Dino.Plugins.Omemo.StreamModule2 module, XmppStream stream, Jid jid, uint timeout_seconds) {
        bool completed = false;
        Gee.ArrayList<int32>? result = null;
        SourceFunc resume = request_omemo2_devicelist_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        module.request_user_devicelist.begin(stream, jid, (obj, res) => {
            Gee.ArrayList<int32> async_result = module.request_user_devicelist.end(res);
            if (completed) return;
            completed = true;
            result = async_result;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return result;
    }

    private static bool is_omemo2_pubsub_session_ready(Dino.Plugins.Omemo.Database omemo_db,
            Account local_account, Store local_store, Jid remote_jid, int32 remote_device_id) {
        int identity_id = omemo_db.identity.get_id(local_account.id);
        if (identity_id < 0 || remote_device_id <= 0) return false;

        Row? device = omemo_db.identity_meta.get_device(identity_id, remote_jid.bare_jid.to_string(), remote_device_id);
        if (device == null) return false;
        Row device_row = (!) device;
        string? identity_key = device_row[omemo_db.identity_meta.identity_key_public_base64];
        if (identity_key == null || ((!) identity_key).length == 0) return false;
        if (!device_row[omemo_db.identity_meta.now_active]) return false;
        if (device_row[omemo_db.identity_meta.supports_omemo1]) return false;
        if (!device_row[omemo_db.identity_meta.supports_omemo2]) return false;
        if ((Dino.Plugins.Omemo.TrustLevel) device_row[omemo_db.identity_meta.trust_level] != Dino.Plugins.Omemo.TrustLevel.TRUSTED) {
            return false;
        }

        Address address = new Address(remote_jid.bare_jid.to_string(), remote_device_id);
        try {
            bool has_session = local_store.contains_session(address);
            address.device_id = 0;
            return has_session;
        } catch (Error e) {
            address.device_id = 0;
            return false;
        }
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
            new DateTime.now_utc().to_unix(), peer_signed_pre_key_pair, new uint8[1], peer_signed_pre_key_signature));
        peer_store.store_signed_pre_key(peer_signed_pre_key_record);
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

    private static void replace_own_omemo2_devices_for_smoke(Dino.Plugins.Omemo.Database db, int identity_id,
            Account account, Store seeded_own_store) {
        db.identity_meta.delete()
            .with(db.identity_meta.identity_id, "=", identity_id)
            .with(db.identity_meta.address_name, "=", account.bare_jid.to_string())
            .perform();
        add_trusted_omemo2_device(db, identity_id, account.bare_jid, seeded_own_store);
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

    private async void join_generated_room(XmppStream stream, Xep.Muc.Module muc_module, RemoteOmemoPrivateMucHttpSmokeConfig config) throws Error {
        Xep.Muc.JoinResult? result = yield muc_module.enter(
            stream,
            config.room_jid.bare_jid,
            config.sender_nick,
            null,
            null,
            false,
            null);
        validate_join_result(result, "remote generated OMEMO private-MUC sender join");
        if (!((!) result).newly_created) {
            throw new IOError.FAILED("remote generated OMEMO private-MUC smoke room already existed");
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
        if (result == null) throw new IOError.TIMED_OUT("timed out waiting for remote OMEMO private-MUC receiver join");
        validate_join_result(result, "remote generated OMEMO private-MUC receiver join");
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
        set_config_text_if_present(data_form, "muc#roomconfig_roomname", "DinoX remote OMEMO private-MUC HTTP file smoke");
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
        throw_if_iq_error(result, "set generated OMEMO private-MUC smoke config");
    }

    private async void change_affiliation_checked(XmppStream stream, Jid room_jid, Jid member_jid, string affiliation) throws Error {
        // A raw setup IQ bypassed the production module's confirmed cache
        // delta and affiliation signal. An automatic join snapshot could
        // therefore still reflect setup before the extra member was added.
        yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).change_affiliation(stream,
            room_jid.bare_jid, member_jid.bare_jid, null, affiliation);
    }

    private async Gee.List<Jid>? wait_for_configured_private_muc_snapshot(MucManager muc_manager,
            Xep.Muc.Module muc_module, XmppStream stream, Account sender_account,
            RemoteOmemoPrivateMucHttpSmokeConfig config) throws Error {
        if (!(yield wait_for_condition(config.timeout_seconds, () =>
                muc_manager.has_live_private_room_features(sender_account, config.room_jid.bare_jid)))) {
            throw new IOError.TIMED_OUT("remote OMEMO private-MUC fixture did not establish current private-room features");
        }
        // Refresh once after every acknowledged affiliation mutation and
        // receiver join. A completed automatic snapshot from an earlier
        // setup stage is not proof of the final configured recipient set.
        if (!(yield muc_module.query_member_affiliation_snapshot(stream, config.room_jid.bare_jid, true))) {
            throw new IOError.FAILED("remote OMEMO private-MUC fixture final member/admin/owner refresh failed");
        }
        Gee.List<Jid>? snapshot = null;
        bool ready = yield wait_for_condition(config.timeout_seconds, () => {
            if (!muc_manager.has_live_private_room_features(sender_account, config.room_jid.bare_jid) ||
                    !muc_manager.has_complete_private_muc_affiliation_snapshot(sender_account, config.room_jid.bare_jid)) {
                return false;
            }
            snapshot = muc_manager.get_private_muc_member_affiliation_snapshot(sender_account, config.room_jid.bare_jid);
            return snapshot != null && contains_bare_jid((!) snapshot, config.sender_jid) &&
                contains_bare_jid((!) snapshot, config.receiver_jid) &&
                (config.extra_receiver_jid == null || contains_bare_jid((!) snapshot, (!) config.extra_receiver_jid));
        });
        if (!ready) {
            throw new IOError.TIMED_OUT("remote OMEMO private-MUC fixture final authoritative snapshot omitted an expected member");
        }
        return snapshot;
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
            Gee.List<Jid>? snapshot, RemoteOmemoPrivateMucHttpSmokeConfig config) throws Error {
        if (snapshot == null) {
            throw new IOError.FAILED("remote OMEMO private-MUC smoke snapshot query returned no complete member/admin/owner result");
        }
        if (!muc_manager.has_live_private_room_features(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC smoke room does not have live members-only plus non-anonymous features");
        }
        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC smoke snapshot did not become complete");
        }
        if (!contains_bare_jid((!) snapshot, config.sender_jid) ||
                !contains_bare_jid((!) snapshot, config.receiver_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC smoke snapshot did not contain sender and receiver");
        }
        if (config.extra_receiver_jid != null && !contains_bare_jid((!) snapshot, (!) config.extra_receiver_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC smoke snapshot did not contain the extra receiver");
        }
    }

    private static void assert_sender_omemo_readiness(OmemoRuntime runtime, Account sender_account, Jid receiver_jid,
            Jid? extra_receiver_jid, OmemoSmokeProtocol protocol) throws Error {
        Gee.List<Jid> recipients = new ArrayList<Jid>(Jid.equals_bare_func);
        recipients.add(receiver_jid.bare_jid);
        if (protocol == OmemoSmokeProtocol.OMEMO2) {
            if (runtime.trust_manager.get_trusted_devices_omemo2(sender_account, receiver_jid.bare_jid).size == 0) {
                throw new IOError.FAILED("remote OMEMO sender has no trusted OMEMO2 receiver device before send");
            }
            if (runtime.trust_manager.get_trusted_devices_omemo1(sender_account, receiver_jid.bare_jid).size != 0) {
                throw new IOError.FAILED("remote OMEMO2 smoke must not seed legacy OMEMO1 receiver devices");
            }
        } else {
            if (runtime.trust_manager.get_trusted_devices_omemo1(sender_account, receiver_jid.bare_jid).size == 0) {
                throw new IOError.FAILED("remote OMEMO sender has no trusted OMEMO1 receiver device before send");
            }
        }
        if (extra_receiver_jid != null) {
            recipients.add(((!) extra_receiver_jid).bare_jid);
            if (protocol == OmemoSmokeProtocol.OMEMO2) {
                if (runtime.trust_manager.get_trusted_devices_omemo2(sender_account, ((!) extra_receiver_jid).bare_jid).size == 0) {
                    throw new IOError.FAILED("remote OMEMO sender has no trusted OMEMO2 extra receiver device before send");
                }
                if (runtime.trust_manager.get_trusted_devices_omemo1(sender_account, ((!) extra_receiver_jid).bare_jid).size != 0) {
                    throw new IOError.FAILED("remote OMEMO2 smoke must not seed legacy OMEMO1 extra receiver devices");
                }
            } else {
                if (runtime.trust_manager.get_trusted_devices_omemo1(sender_account, ((!) extra_receiver_jid).bare_jid).size == 0) {
                    throw new IOError.FAILED("remote OMEMO sender has no trusted OMEMO1 extra receiver device before send");
                }
            }
        }
        bool should_use_omemo2 = runtime.trust_manager.should_use_omemo2(sender_account, recipients);
        if (protocol == OmemoSmokeProtocol.OMEMO2 && !should_use_omemo2) {
            throw new IOError.FAILED("remote OMEMO2 smoke must select OMEMO2/SCE before send");
        }
        if (protocol == OmemoSmokeProtocol.OMEMO1 && should_use_omemo2) {
            throw new IOError.FAILED("remote OMEMO smoke is scoped to legacy OMEMO1 and must not select OMEMO2/SCE");
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
            RemoteOmemoPrivateMucHttpSmokeConfig config, string download_url) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP send must publish a persisted outgoing transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer must be outgoing");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer must target the generated room");
        }
        if (file_transfer.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer must be marked OMEMO");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer kept a phase error");
        }
        if (file_transfer.info == null || file_transfer.info == "") {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender transfer must link the encrypted body-url message");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT || conversation.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP sender conversation must be OMEMO GROUPCHAT");
        }
        assert_single_http_source(file_transfer, download_url,
            "remote OMEMO private-MUC HTTP sender transfer must keep one fragment-free HTTP source");
    }

    private static void validate_received_transfer(FileTransfer file_transfer, Conversation conversation,
            RemoteOmemoPrivateMucHttpSmokeConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receive must publish a persisted incoming transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must be incoming");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must come from the generated room");
        }
        if (file_transfer.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must be marked OMEMO");
        }
        if (file_transfer.file_name != config.payload_name) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver file name did not match expected payload");
        }
        if (file_transfer.size != config.payload_text.length) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer published the wrong plaintext size");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer kept a phase error");
        }
        if (file_transfer.path == null || file_transfer.path == "") {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver transfer must only allow plaintext release after completion");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receiver conversation must be GROUPCHAT");
        }
    }

    private static string require_aesgcm_body_url(Dino.Entities.Message message) throws Error {
        if (message.body == null || !((string) message.body).has_prefix("aesgcm://")) {
            throw new IOError.FAILED("remote OMEMO body-url message did not carry an aesgcm URL before encryption");
        }
        return (string) message.body;
    }

    private static string aesgcm_to_https_link(string aesgcm_link) throws Error {
        if (!aesgcm_link.has_prefix("aesgcm://")) {
            throw new IOError.FAILED("remote OMEMO body URL must use aesgcm://");
        }
        int hash = aesgcm_link.index_of("#");
        if (hash < 0) {
            throw new IOError.FAILED("remote OMEMO aesgcm URL must carry a secret fragment");
        }
        return "https://" + aesgcm_link.substring("aesgcm://".length, hash - "aesgcm://".length);
    }

    private static void validate_captured_omemo_body_url_message(Dino.Entities.Message message, string? outer_body,
            Jid? stanza_to, string? stanza_type, Xmpp.StanzaNode? legacy_encrypted_node,
            Xmpp.StanzaNode? omemo2_encrypted_node, bool has_outer_oob, bool has_outer_sfs,
            bool has_outer_sources, bool has_outer_attach, string body_url, string download_url,
            RemoteOmemoPrivateMucHttpSmokeConfig config,
            Store sender_store, Store receiver_store, Store? extra_receiver_store,
            Store? sender_own_secondary_store, OmemoSmokeProtocol protocol,
            OmemoSmokeKeySetup key_setup) throws Error {
        if (!message_reached_remote_send_boundary(message)) {
            throw new IOError.FAILED("remote OMEMO body-url message must be marked sent or echoed by the private MUC");
        }
        if (message.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO body-url message must be marked OMEMO");
        }
        if (stanza_to == null || !((!) stanza_to).equals_bare(config.room_jid.bare_jid) || stanza_type != Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            throw new IOError.FAILED("remote OMEMO body-url stanza must be a groupchat addressed to the private room");
        }
        if (outer_body == null || ((!) outer_body) == "" || ((!) outer_body).contains(body_url) || ((!) outer_body).contains(download_url)) {
            throw new IOError.FAILED("remote OMEMO body-url stanza must not expose the transfer URL in the fallback body");
        }
        if (has_outer_oob || has_outer_sfs || has_outer_sources || has_outer_attach) {
            throw new IOError.FAILED("remote OMEMO body-url stanza must not expose outer OOB/SFS/attachment URL metadata");
        }

        if (protocol == OmemoSmokeProtocol.OMEMO2) {
            if (omemo2_encrypted_node == null) {
                throw new IOError.FAILED("remote OMEMO2 body-url stanza must carry an OMEMO2/SCE encrypted node");
            }
            if (legacy_encrypted_node != null) {
                throw new IOError.FAILED("remote OMEMO2 body-url stanza must not fall back to legacy OMEMO");
            }
            assert_omemo2_key_recipient((!) omemo2_encrypted_node, config.receiver_jid,
                (int) receiver_store.local_registration_id,
                "remote OMEMO2 body-url stanza must encrypt to the receiver device");
            int expected_recipients = 1;
            if (extra_receiver_store != null) {
                assert_omemo2_key_recipient((!) omemo2_encrypted_node, (!) config.extra_receiver_jid,
                    (int) ((!) extra_receiver_store).local_registration_id,
                    "remote OMEMO2 body-url stanza must encrypt to the extra receiver device");
                expected_recipients++;
            }
            if (sender_own_secondary_store == null) {
                throw new IOError.FAILED("remote OMEMO2 body-url stanza requires a seeded own secondary device");
            }
            assert_omemo2_key_recipient((!) omemo2_encrypted_node, message.account.bare_jid,
                (int) ((!) sender_own_secondary_store).local_registration_id,
                "remote OMEMO2 body-url stanza must encrypt to the sender own secondary device");
            expected_recipients++;
            assert_omemo2_key_recipient_absent((!) omemo2_encrypted_node, message.account.bare_jid,
                (int) sender_store.local_registration_id,
                "remote OMEMO2 body-url stanza must not wrap a key for the current sending device");
            if (count_omemo2_key_recipients((!) omemo2_encrypted_node) != expected_recipients) {
                throw new IOError.FAILED("remote OMEMO2 body-url stanza must target exactly the configured receiver devices and expected own devices");
            }
        } else {
            if (legacy_encrypted_node == null) {
                throw new IOError.FAILED("remote OMEMO body-url stanza must carry a legacy OMEMO encrypted node");
            }
            if (omemo2_encrypted_node != null) {
                throw new IOError.FAILED("remote OMEMO1 body-url stanza must not use OMEMO2/SCE");
            }
            assert_omemo_key_recipient((!) legacy_encrypted_node, (int) receiver_store.local_registration_id,
                "remote OMEMO body-url stanza must encrypt to the receiver device");
            if (extra_receiver_store != null) {
                assert_omemo_key_recipient((!) legacy_encrypted_node, (int) ((!) extra_receiver_store).local_registration_id,
                    "remote OMEMO body-url stanza must encrypt to the extra receiver device");
            }
        }
    }

    private static void assert_omemo_key_recipient(Xmpp.StanzaNode encrypted_node, int device_id, string reason) throws Error {
        Xmpp.StanzaNode? header = encrypted_node.get_subnode("header", NS_OMEMO_LEGACY);
        if (header == null) throw new IOError.FAILED(reason);
        foreach (Xmpp.StanzaNode key_node in ((!) header).get_subnodes("key", NS_OMEMO_LEGACY)) {
            if (key_node.get_attribute_int("rid") == device_id) return;
        }
        throw new IOError.FAILED(reason);
    }

    private static void assert_omemo2_key_recipient(Xmpp.StanzaNode encrypted_node, Jid jid, int device_id, string reason) throws Error {
        Xmpp.StanzaNode? header = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        if (header == null) throw new IOError.FAILED(reason);
        string jid_string = jid.bare_jid.to_string();
        foreach (Xmpp.StanzaNode keys_node in ((!) header).get_subnodes("keys", NS_OMEMO_V2)) {
            if (keys_node.get_attribute("jid") != jid_string) continue;
            foreach (Xmpp.StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                if (key_node.get_attribute_int("rid") == device_id) return;
            }
        }
        throw new IOError.FAILED(reason);
    }

    private static void assert_omemo2_key_recipient_absent(Xmpp.StanzaNode encrypted_node,
            Jid jid, int device_id, string reason) throws Error {
        Xmpp.StanzaNode? header = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        if (header == null) throw new IOError.FAILED(reason + ": missing header");
        foreach (Xmpp.StanzaNode keys_node in ((!) header).get_subnodes("keys", NS_OMEMO_V2)) {
            if (keys_node.get_attribute("jid") != jid.bare_jid.to_string()) continue;
            foreach (Xmpp.StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                if (key_node.get_attribute_int("rid") == device_id) throw new IOError.FAILED(reason);
            }
        }
    }

    private static int count_omemo2_key_recipients(Xmpp.StanzaNode encrypted_node) throws Error {
        Xmpp.StanzaNode? header = encrypted_node.get_subnode("header", NS_OMEMO_V2);
        if (header == null) throw new IOError.FAILED("remote OMEMO2 body-url stanza must carry a header");
        int count = 0;
        foreach (Xmpp.StanzaNode keys_node in ((!) header).get_subnodes("keys", NS_OMEMO_V2)) {
            foreach (Xmpp.StanzaNode key_node in keys_node.get_subnodes("key", NS_OMEMO_V2)) {
                if (key_node.name == "key") count++;
            }
        }
        return count;
    }

    private async void validate_stored_payload(Security.FileEncryption file_encryption, FileTransfer file_transfer,
            int64 expected_size, string expected_sha256) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED("remote OMEMO private-MUC HTTP receive-store must write the verified local file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();
        if (decrypted.length != expected_size) {
            throw new IOError.FAILED(@"decrypted remote OMEMO private-MUC HTTP payload size $(decrypted.length) did not match $(expected_size)");
        }
        string actual_sha256 = Checksum.compute_for_data(ChecksumType.SHA256, decrypted);
        if (actual_sha256.down() != expected_sha256.down()) {
            throw new IOError.FAILED("decrypted remote OMEMO private-MUC HTTP payload SHA-256 did not match expected payload");
        }
    }

    private static int count_pending_receive_files(Dino.Database db) {
        return (int) db.file_transfer.select()
            .with(db.file_transfer.direction, "=", FileTransfer.DIRECTION_RECEIVED)
            .with(db.file_transfer.state, "=", FileTransfer.State.IN_PROGRESS)
            .count();
    }

    private static void assert_single_http_source(FileTransfer file_transfer, string expected_url, string reason) throws Error {
        if (file_transfer.sfs_sources.size != 1) {
            throw new IOError.FAILED(reason);
        }
        Xep.StatelessFileSharing.HttpSource? http_source = file_transfer.sfs_sources[0] as Xep.StatelessFileSharing.HttpSource;
        if (http_source == null || ((!) http_source).url == null || ((!) http_source).url == "") {
            throw new IOError.FAILED(reason);
        }
        string url = ((!) http_source).url;
        if (url != expected_url || url.index_of("#") >= 0) {
            throw new IOError.FAILED(reason);
        }
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

    private static void drain_pending_events() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
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
            append_error_segment(builder, ref has_segment, @"remote generated-room cleanup failure for $room: $(error.message)");
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

    private class OmemoRuntime : Object {
        public Dino.Plugins.Omemo.Manager manager;
        public Dino.Plugins.Omemo.TrustManager trust_manager;
        public HashMap<Account, Dino.Plugins.Omemo.OmemoDecryptor> decryptors;
        public HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor> encryptors;
        public HashMap<Account, Dino.Plugins.Omemo.Omemo2Decrypt> decryptors_v2;
        public HashMap<Account, Dino.Plugins.Omemo.Omemo2Encrypt> encryptors_v2;
    }

    private static string protocol_label(OmemoSmokeProtocol protocol) {
        return protocol == OmemoSmokeProtocol.OMEMO2 ? "OMEMO2/SCE" : "OMEMO1";
    }

    private static string key_setup_label(OmemoSmokeKeySetup key_setup) {
        return key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY ? "PubSub-discovered" : "seeded";
    }

    private class RemoteOmemoPrivateMucHttpSmokeConfig : Object {
        public Jid sender_jid;
        public string sender_password;
        public Jid receiver_jid;
        public string receiver_password;
        public Jid? extra_receiver_jid = null;
        public string? extra_receiver_password = null;
        public Jid service_jid;
        public Jid room_jid;
        public string? custom_host = null;
        public int custom_port = 0;
        public string account_proxy_type = "none";
        public string? account_proxy_host = null;
        public int account_proxy_port = 0;
        public string sender_nick = "dinox-omemo-smoke-sender";
        public string receiver_nick = "dinox-omemo-smoke-receiver";
        public string extra_receiver_nick = "dinox-omemo-smoke-extra-receiver";
        public string payload_name = "dinox-remote-omemo-private-muc-http-smoke.txt";
        public string payload_text = "DinoX remote OMEMO private-MUC HTTP file smoke payload\n";
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemoteOmemoPrivateMucHttpSmokeConfig? from_env(OmemoSmokeProtocol protocol, OmemoSmokeKeySetup key_setup) {
            if (Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE") != "1") {
                GLib.Test.skip(@"Set DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE=1 with sender, receiver and MUC service env to run the remote $(protocol_label(protocol)) private-MUC HTTP file-send smoke");
                return null;
            }
            if (protocol == OmemoSmokeProtocol.OMEMO2 && key_setup == OmemoSmokeKeySetup.PUBSUB_DISCOVERY &&
                    Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION") != "1") {
                fail_if(true, "DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1 must be set for the OMEMO2 PubSub discovery smoke because it temporarily rewrites disposable account PEP nodes");
                return null;
            }

            string? sender_env = require_env("DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID");
            string? sender_password_env = require_env("DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD");
            string? receiver_env = require_env("DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID");
            string? receiver_password_env = require_env("DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD");
            string? service_env = require_env("DINOX_REMOTE_OMEMO_MUC_SERVICE");
            string? extra_receiver_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID"));
            string? extra_receiver_password_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD"));
            if (sender_env == null || sender_password_env == null || receiver_env == null ||
                    receiver_password_env == null || service_env == null) {
                return null;
            }
            if ((extra_receiver_env == null) != (extra_receiver_password_env == null)) {
                fail_if(true, "DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID and DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD must be set together");
                return null;
            }

            RemoteOmemoPrivateMucHttpSmokeConfig config = new RemoteOmemoPrivateMucHttpSmokeConfig();
            try {
                config.sender_jid = new Jid((!) sender_env);
                config.receiver_jid = new Jid((!) receiver_env);
                if (extra_receiver_env != null) {
                    config.extra_receiver_jid = new Jid((!) extra_receiver_env);
                }
                config.service_jid = new Jid((!) service_env);
                if (config.sender_jid.resourcepart != null || config.receiver_jid.resourcepart != null ||
                        (config.extra_receiver_jid != null && ((!) config.extra_receiver_jid).resourcepart != null)) {
                    fail_if(true, "remote OMEMO private-MUC HTTP file smoke requires bare sender and receiver account JIDs");
                    return null;
                }
                if (!config.service_jid.is_domain()) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_MUC_SERVICE must be a domain JID such as conference.example.test");
                    return null;
                }
                if (config.sender_jid.bare_jid.equals(config.receiver_jid.bare_jid)) {
                    fail_if(true, "remote OMEMO private-MUC HTTP file smoke requires distinct sender and receiver accounts");
                    return null;
                }
                if (config.extra_receiver_jid != null &&
                        (config.sender_jid.bare_jid.equals(((!) config.extra_receiver_jid).bare_jid) ||
                        config.receiver_jid.bare_jid.equals(((!) config.extra_receiver_jid).bare_jid))) {
                    fail_if(true, "remote OMEMO private-MUC HTTP file smoke requires distinct sender, receiver and extra receiver accounts");
                    return null;
                }
                config.sender_password = (!) sender_password_env;
                config.receiver_password = (!) receiver_password_env;
                config.extra_receiver_password = extra_receiver_password_env;

                string room_prefix = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX")) ?? "dinox-remote-omemo-muc-http-smoke";
                config.room_jid = new Jid(@"$room_prefix-$(Uuid.string_random())@$(config.service_jid.domainpart)").bare_jid;
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote OMEMO private-MUC HTTP file smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_HOST"));
            config.sender_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK")) ?? config.sender_nick;
            config.receiver_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK")) ?? config.receiver_nick;
            config.extra_receiver_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK")) ?? config.extra_receiver_nick;
            config.payload_name = FileTransfer.sanitize_file_name(
                    empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_NAME")) ?? config.payload_name);
            config.payload_text = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT")) ?? config.payload_text;

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_MUC_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 900) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900");
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

        private static bool parse_account_proxy_env(RemoteOmemoPrivateMucHttpSmokeConfig config) {
            string? proxy_type = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE"));
            if (proxy_type == null) return true;
            proxy_type = ((!) proxy_type).down();
            if (proxy_type != "none" && proxy_type != "socks5" && proxy_type != "tor") {
                fail_if(true, "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE must be none, socks5 or tor");
                return false;
            }
            config.account_proxy_type = (!) proxy_type;
            if (config.account_proxy_type == "none") return true;

            config.account_proxy_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST"));
            string? proxy_port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT"));
            if (config.account_proxy_type == "socks5" && config.account_proxy_host == null) {
                fail_if(true, "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST must be set for socks5 account proxy");
                return false;
            }
            if (proxy_port_env != null) {
                int parsed_proxy_port = 0;
                if (!int.try_parse((!) proxy_port_env, out parsed_proxy_port, null, 10) || parsed_proxy_port < 1 || parsed_proxy_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535");
                    return false;
                }
                config.account_proxy_port = parsed_proxy_port;
            }
            if (config.account_proxy_type == "socks5" && config.account_proxy_port == 0) {
                fail_if(true, "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT must be set for socks5 account proxy");
                return false;
            }
            return true;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE=1");
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
            Object(application_id: "im.dinox.remote-omemo-private-muc-http-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-omemo-private-muc-http-smoke-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}
