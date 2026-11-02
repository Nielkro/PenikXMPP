using Dino;
using Dino.Entities;
using Dino.Security;
using Gee;
using Omemo;
using Qlite;
using Xmpp;
using Xmpp.Xep;

namespace Omemo.Test {

private enum RemotePubsubItemSnapshotStatus {
    PRESENT,
    ABSENT,
    UNKNOWN
}

private class RemotePubsubItemSnapshot : Object {
    public RemotePubsubItemSnapshotStatus status { get; private set; }
    public StanzaNode? item { get; private set; }

    public RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus status, StanzaNode? item = null) {
        this.status = status;
        this.item = item;
    }
}

class RemoteOmemoJingleS5bSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 120;
    private const string AES_128_GCM_URI = "urn:xmpp:ciphers:aes-128-gcm-nopadding";
    private const string NS_OMEMO_LEGACY = "eu.siacs.conversations.axolotl";
    private const string NS_OMEMO_V2 = "urn:xmpp:omemo:2";
    private const string OMEMO1_NODE_DEVICELIST = NS_OMEMO_LEGACY + ".devicelist";
    private const int JINGLE_PROVIDER_ID = 1;

    private delegate bool WaitCondition();

    public RemoteOmemoJingleS5bSmokeTest() {
        base("RemoteOmemoJingleS5bSmoke");
        add_test("omemo1_jingle_s5b_send_receive_env", test_omemo1_jingle_s5b_send_receive_env_sync);
        add_test("omemo2_jingle_s5b_send_receive_env", test_omemo2_jingle_s5b_send_receive_env_sync);
        add_test("omemo1_jingle_s5b_sender_env", test_omemo1_jingle_s5b_sender_env_sync);
        add_test("omemo2_jingle_s5b_sender_env", test_omemo2_jingle_s5b_sender_env_sync);
        add_test("omemo1_jingle_s5b_receive_env", test_omemo1_jingle_s5b_receive_env_sync);
        add_test("omemo2_jingle_s5b_receive_env", test_omemo2_jingle_s5b_receive_env_sync);
        add_test("omemo2_external_receiver_v2_only_guard_env", test_omemo2_external_receiver_v2_only_guard_env_sync);
    }

    private void test_omemo1_jingle_s5b_send_receive_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env();
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(false);
        MainLoop loop = new MainLoop();
        run_omemo1_jingle_s5b_send_receive.begin((!) config, (obj, res) => {
            try {
                run_omemo1_jingle_s5b_send_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO1/JET Jingle S5B send/receive smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo2_jingle_s5b_send_receive_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(false, true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
        MainLoop loop = new MainLoop();
        run_omemo1_jingle_s5b_send_receive.begin((!) config, (obj, res) => {
            try {
                run_omemo1_jingle_s5b_send_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO2/JET Jingle S5B send/receive smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo1_jingle_s5b_sender_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(false, false, true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(false);
        MainLoop loop = new MainLoop();
        run_omemo_jingle_s5b_sender.begin((!) config, (obj, res) => {
            try {
                run_omemo_jingle_s5b_sender.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO1/JET Jingle S5B sender-only smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo2_jingle_s5b_sender_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(false, true, true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
        MainLoop loop = new MainLoop();
        run_omemo_jingle_s5b_sender.begin((!) config, (obj, res) => {
            try {
                run_omemo_jingle_s5b_sender.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO2/JET Jingle S5B sender-only smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo1_jingle_s5b_receive_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(false);
        MainLoop loop = new MainLoop();
        run_omemo_jingle_s5b_receive.begin((!) config, (obj, res) => {
            try {
                run_omemo_jingle_s5b_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO1/JET Jingle S5B receive-only smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo2_jingle_s5b_receive_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(true, true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
        MainLoop loop = new MainLoop();
        run_omemo_jingle_s5b_receive.begin((!) config, (obj, res) => {
            try {
                run_omemo_jingle_s5b_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO2/JET Jingle S5B receive-only smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private void test_omemo2_external_receiver_v2_only_guard_env_sync() {
        RemoteOmemoJingleS5bSmokeConfig? config = RemoteOmemoJingleS5bSmokeConfig.from_env(false, true, false, true);
        if (config == null) return;

        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
        MainLoop loop = new MainLoop();
        run_external_receiver_v2_only_guard.begin((!) config, (obj, res) => {
            try {
                run_external_receiver_v2_only_guard.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote OMEMO2/JET external receiver v2-only guard failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
        Dino.Plugins.Omemo.TrustManager.set_omemo2_runtime_test_override(true);
    }

    private async void run_omemo1_jingle_s5b_send_receive(RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-omemo-jingle-s5b-smoke-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Dino.Database? core_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        StreamInteractor? stream_interactor = null;
        FileManager? file_manager = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        Account? sender_account = null;
        Account? receiver_account = null;
        XmppStream? sender_stream = null;
        XmppStream? receiver_stream = null;
        FileTransfer? sent_transfer = null;
        FileTransfer? received_transfer = null;
        Conversation? received_conversation = null;
        string? sent_stored_path = null;
        string? received_stored_path = null;
        string? storage_dir = null;
        ulong received_handler = 0;
        ulong incoming_handler = 0;
        ulong session_handler = 0;
        RemoteOmemoJingleIncomingObservation incoming_observation = new RemoteOmemoJingleIncomingObservation();
        RemoteOmemoJingleReceiveObservation receive_observation = new RemoteOmemoJingleReceiveObservation();
        Dino.JingleFileEncryptionHelper? previous_jingle_helper = null;
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage(temp_dir);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("OMEMO context could not be initialized");
            }
            Context context = Dino.Plugins.Omemo.Plugin.get_context();

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-omemo-jingle-s5b-smoke");
            omemo_db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption);
            file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OMEMO Jingle S5B smoke");
            }
            OmemoJingleRuntime runtime = install_omemo_jingle_runtime(
                (!) stream_interactor, (!) omemo_db, (!) file_manager, !config.use_omemo2);
            previous_jingle_helper = runtime.previous_jingle_helper;

            sender_account = new Account(config.sender_jid.bare_jid, config.sender_password);
            ((!) sender_account).enabled = true;
            ((!) sender_account).custom_host = config.custom_host;
            ((!) sender_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) core_db, (!) sender_account);

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) core_db, (!) receiver_account);

            seed_trusted_roster_contact((!) core_db, (!) sender_account, config.receiver_jid);
            seed_trusted_roster_contact((!) core_db, (!) receiver_account, config.sender_jid);
            if (config.use_omemo2) {
                seed_identity_for_manual_pubsub_fixture(context, (!) omemo_db, (!) sender_account);
                seed_identity_for_manual_pubsub_fixture(context, (!) omemo_db, (!) receiver_account);
            }

            Conversation sender_conversation = new Conversation(
                ((!) receiver_account).bare_jid, (!) sender_account, Conversation.Type.CHAT);
            sender_conversation.persist((!) core_db);
            sender_conversation.encryption = Encryption.OMEMO;
            sender_conversation.send_typing = Conversation.Setting.OFF;
            sender_conversation.send_marker = Conversation.Setting.OFF;

            Conversation receiver_conversation = new Conversation(
                ((!) sender_account).bare_jid, (!) receiver_account, Conversation.Type.CHAT);
            receiver_conversation.persist((!) core_db);
            receiver_conversation.encryption = Encryption.OMEMO;
            receiver_conversation.send_typing = Conversation.Setting.OFF;
            receiver_conversation.send_marker = Conversation.Setting.OFF;

            string? connect_failure = yield connect_and_wait_for_negotiation(
                (!) stream_interactor, (!) sender_account, config.timeout_seconds);
            if (connect_failure != null) {
                throw new IOError.TIMED_OUT("sender " + (!) connect_failure);
            }
            connect_failure = yield connect_and_wait_for_negotiation(
                (!) stream_interactor, (!) receiver_account, config.timeout_seconds);
            if (connect_failure != null) {
                throw new IOError.TIMED_OUT("receiver " + (!) connect_failure);
            }

            Store sender_store = yield wait_for_omemo_store(
                (!) stream_interactor, (!) omemo_db, (!) sender_account, config.timeout_seconds);
            Store receiver_store = yield wait_for_omemo_store(
                (!) stream_interactor, (!) omemo_db, (!) receiver_account, config.timeout_seconds);
            int sender_identity_id = ((!) omemo_db).identity.get_id(((!) sender_account).id);
            int receiver_identity_id = ((!) omemo_db).identity.get_id(((!) receiver_account).id);
            if (sender_identity_id < 0 || receiver_identity_id < 0) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B smoke could not resolve account identities");
            }

            if (config.use_omemo2) {
                prepare_pre_key_session_v2(context, sender_store, ((!) receiver_account).bare_jid, receiver_store, 65001, 66001);
                add_trusted_omemo2_device((!) omemo_db, sender_identity_id, ((!) receiver_account).bare_jid, receiver_store);
                add_trusted_omemo2_device((!) omemo_db, receiver_identity_id, ((!) sender_account).bare_jid, sender_store);
            } else {
                prepare_pre_key_session(context, sender_store, ((!) receiver_account).bare_jid, receiver_store, 65001, 66001);
                add_trusted_omemo1_device((!) omemo_db, sender_identity_id, ((!) receiver_account).bare_jid, receiver_store);
                add_trusted_omemo1_device((!) omemo_db, receiver_identity_id, ((!) sender_account).bare_jid, sender_store);
            }

            sender_stream = ((!) stream_interactor).get_stream((!) sender_account);
            receiver_stream = ((!) stream_interactor).get_stream((!) receiver_account);
            if (sender_stream == null || receiver_stream == null) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B smoke lost a negotiated stream");
            }
            Jid sender_full_jid = get_bound_full_jid((!) sender_stream);
            Jid receiver_full_jid = get_bound_full_jid((!) receiver_stream);
            inject_available_resource((!) sender_stream, receiver_full_jid, sender_full_jid);

            if (!(yield wait_for_upload_available((!) file_manager, sender_conversation, config.timeout_seconds))) {
                throw new IOError.TIMED_OUT("timed out waiting for OMEMO-capable Jingle S5B upload availability");
            }

            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<JingleFileTransfer.Module>(
                (!) receiver_account, JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module == null) {
                throw new IOError.FAILED("receiver Jingle file-transfer module was not available");
            }
            incoming_handler = ((!) jingle_file_module).file_incoming.connect((stream, jingle_transfer) => {
                if (!jingle_transfer.peer.equals_bare(((!) sender_account).bare_jid)) return;
                incoming_observation.count++;
                incoming_observation.peer = jingle_transfer.peer;
                incoming_observation.file_name = jingle_transfer.file_name;
                incoming_observation.size = jingle_transfer.size;
                incoming_observation.transport_ns_uri = jingle_transfer.transport_ns_uri;
                incoming_observation.security = jingle_transfer.security as Jet.SecurityParameters;
            });

            var receiver_jingle_module = ((!) receiver_stream).get_module<Jingle.Module>(Jingle.Module.IDENTITY);
            if (receiver_jingle_module == null) {
                throw new IOError.FAILED("receiver Jingle module was not attached");
            }
            session_handler = ((!) receiver_jingle_module).session_initiate_received.connect((seen_stream, session) => {
                if (!session.peer_full_jid.equals_bare(((!) sender_account).bare_jid)) return;
                incoming_observation.session_sid = session.sid;
                session.terminated.connect((terminated_stream, we_terminated, reason_name, reason_text) => {
                    incoming_observation.session_terminate_reason = reason_name;
                });
            });

            var phases = new Gee.ArrayList<FileTransfer.Phase>();
            received_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (Account.equals_func(file_transfer.account, (!) sender_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_SENT &&
                        file_transfer.counterpart.equals_bare(((!) receiver_account).bare_jid)) {
                    sent_transfer = file_transfer;
                    sent_stored_path = file_transfer.path;
                } else if (Account.equals_func(file_transfer.account, (!) receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
                        file_transfer.counterpart.equals_bare(((!) sender_account).bare_jid) &&
                        file_transfer.file_name == config.payload_name) {
                    received_transfer = file_transfer;
                    received_conversation = conversation;
                    received_stored_path = file_transfer.path;
                    observe_received_transfer_publication(file_transfer, receive_observation);
                    file_transfer.notify["phase"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    file_transfer.notify["state"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    file_transfer.notify["path"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    // Fresh test accounts may require the user's explicit accept.
                    if (file_transfer.state == FileTransfer.State.NOT_STARTED) {
                        ((!) file_manager).download_file.begin(file_transfer);
                    }
                }
            });

            string payload_path = Path.build_filename(temp_dir, config.payload_name);
            FileUtils.set_contents(payload_path, config.payload_text);
            uint8[] payload = config.payload_text.data;

            yield ((!) file_manager).send_file(File.new_for_path(payload_path), sender_conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });

            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    sent_transfer != null &&
                    received_transfer != null &&
                    (((!) sent_transfer).phase == FileTransfer.Phase.COMPLETE ||
                        ((!) sent_transfer).phase == FileTransfer.Phase.FAILED) &&
                    (((!) received_transfer).phase == FileTransfer.Phase.COMPLETE ||
                        ((!) received_transfer).phase == FileTransfer.Phase.FAILED)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote OMEMO1/JET Jingle S5B completion (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)), incoming=$(format_incoming_observation(incoming_observation)))");
            }
            drain_pending_events();

            if (sent_transfer == null || received_transfer == null) {
                throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B did not publish both transfer objects (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)))");
            }
            FileTransfer sender_transfer = (!) sent_transfer;
            FileTransfer receiver_transfer = (!) received_transfer;
            if (sender_transfer.phase == FileTransfer.Phase.FAILED || receiver_transfer.phase == FileTransfer.Phase.FAILED) {
                throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B failed (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)))");
            }

            validate_incoming_observation(incoming_observation, config, receiver_store);
            validate_receive_publication_observation(receive_observation);
            validate_sent_transfer((!) core_db, sender_transfer, sender_conversation, config);
            validate_received_transfer((!) core_db, receiver_transfer, (!) received_conversation,
                receiver_conversation, config);
            yield validate_stored_payload(file_encryption, sender_transfer, payload, "sent local copy");
            yield validate_stored_payload(file_encryption, receiver_transfer, payload, "received local copy");
            assert_phase_order(phases, FileTransfer.Phase.STORING, FileTransfer.Phase.REQUESTING_SLOT,
                "remote OMEMO1/JET Jingle S5B send must store the local copy before requesting transport");
            assert_phase_order(phases, FileTransfer.Phase.REQUESTING_SLOT, FileTransfer.Phase.UPLOADING,
                "remote OMEMO1/JET Jingle S5B send must request transport before upload");
            assert_phase_order(phases, FileTransfer.Phase.UPLOADING, FileTransfer.Phase.COMPLETE,
                "remote OMEMO1/JET Jingle S5B send must complete after upload");

            if (count_receive_pending_files_for_basename((!) storage_dir, config.payload_name) != 0) {
                throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B receive-store left pending receive files");
            }
            if (incoming_observation.session_sid == null) {
                throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B did not observe a receiver Jingle session id");
            }
            string session_sid = (!) incoming_observation.session_sid;
            if (has_jingle_session_state((!) receiver_stream, session_sid) ||
                    has_jingle_session_state((!) sender_stream, session_sid)) {
                throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B left Jingle session state");
            }
            if (incoming_observation.session_terminate_reason != Jingle.ReasonElement.SUCCESS) {
                throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B terminated with $(incoming_observation.session_terminate_reason ?? "(none)") instead of success");
            }

            GLib.Test.message("Remote OMEMO1/JET Jingle S5B send/receive smoke passed");
        } catch (Error e) {
            pending_error = e;
        }

        if (pending_error != null) {
            cancel_observed_transfer(sent_transfer);
            cancel_observed_transfer(received_transfer);
            terminate_jingle_session_if_present(sender_stream, incoming_observation.session_sid);
            terminate_jingle_session_if_present(receiver_stream, incoming_observation.session_sid);
            yield wait_for_condition(5, () => transfer_is_quiescent(sent_transfer) &&
                transfer_is_quiescent(received_transfer));
            drain_pending_events();
        }

        if (stream_interactor != null && receiver_account != null && incoming_handler != 0) {
            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<JingleFileTransfer.Module>(
                (!) receiver_account, JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module != null) SignalHandler.disconnect((!) jingle_file_module, incoming_handler);
            incoming_handler = 0;
        }
        if (receiver_stream != null && session_handler != 0) {
            var receiver_jingle_module = ((!) receiver_stream).get_module<Jingle.Module>(Jingle.Module.IDENTITY);
            if (receiver_jingle_module != null) SignalHandler.disconnect((!) receiver_jingle_module, session_handler);
            session_handler = 0;
        }
        if (file_manager != null && received_handler != 0) {
            SignalHandler.disconnect((!) file_manager, received_handler);
            received_handler = 0;
        }
        restore_jingle_file_encryption_helper(previous_jingle_helper);

        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) receiver_account);
        }
        if (stream_interactor != null && sender_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) sender_account);
        }
        restore_default_application(application, previous_application);
        if (sent_stored_path != null && storage_dir != null) {
            FileUtils.remove(Path.build_filename((!) storage_dir, (!) sent_stored_path));
        }
        if (received_stored_path != null && storage_dir != null && received_stored_path != sent_stored_path) {
            FileUtils.remove(Path.build_filename((!) storage_dir, (!) received_stored_path));
        }
        if (storage_dir != null) {
            delete_receive_pending_files_for_basename((!) storage_dir, config.payload_name);
        }
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
            GLib.Test.message(@"Could not clean remote OMEMO Jingle S5B smoke temp dir: $(e.message)");
        }

        if (pending_error != null) throw (!) pending_error;
        if (temp_cleanup_error != null) throw (!) temp_cleanup_error;
    }

    private async void run_omemo_jingle_s5b_sender(RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-omemo-jingle-s5b-sender-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Dino.Database? core_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        StreamInteractor? stream_interactor = null;
        FileManager? file_manager = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        Account? sender_account = null;
        XmppStream? sender_stream = null;
        FileTransfer? sent_transfer = null;
        string? sent_stored_path = null;
        string? storage_dir = null;
        ulong sent_handler = 0;
        Iq.Module? sender_iq_module = null;
        ulong sender_iq_outgoing_handler = 0;
        ulong sender_iq_incoming_handler = 0;
        RemoteOmemoJingleS5bTransportObservation transport_observation =
            new RemoteOmemoJingleS5bTransportObservation();
        Dino.JingleFileEncryptionHelper? previous_jingle_helper = null;
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            if (config.receiver_full_jid == null) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B sender-only smoke requires a receiver full JID");
            }

            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage(temp_dir);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("OMEMO context could not be initialized");
            }

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-omemo-jingle-s5b-sender");
            omemo_db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption);
            file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OMEMO Jingle S5B sender-only smoke");
            }
            OmemoJingleRuntime runtime = install_omemo_jingle_runtime(
                (!) stream_interactor, (!) omemo_db, (!) file_manager, !config.use_omemo2);
            previous_jingle_helper = runtime.previous_jingle_helper;

            sender_account = new Account(config.sender_jid.bare_jid, config.sender_password);
            ((!) sender_account).enabled = true;
            ((!) sender_account).custom_host = config.custom_host;
            ((!) sender_account).custom_port = config.custom_port;
            apply_sender_proxy_config((!) sender_account, config);
            persist_remote_smoke_account_without_password((!) core_db, (!) sender_account);
            if (config.use_omemo2) {
                seed_identity_for_manual_pubsub_fixture(Dino.Plugins.Omemo.Plugin.get_context(), (!) omemo_db, (!) sender_account);
            }

            seed_trusted_roster_contact((!) core_db, (!) sender_account, config.receiver_jid);

            Conversation sender_conversation = new Conversation(
                config.receiver_jid.bare_jid, (!) sender_account, Conversation.Type.CHAT);
            sender_conversation.persist((!) core_db);
            sender_conversation.encryption = Encryption.OMEMO;
            sender_conversation.send_typing = Conversation.Setting.OFF;
            sender_conversation.send_marker = Conversation.Setting.OFF;

            string? connect_failure = yield connect_and_wait_for_negotiation(
                (!) stream_interactor, (!) sender_account, config.timeout_seconds);
            if (connect_failure != null) {
                throw new IOError.TIMED_OUT("sender " + (!) connect_failure);
            }

            Store sender_store = yield wait_for_omemo_store(
                (!) stream_interactor, (!) omemo_db, (!) sender_account, config.timeout_seconds);
            sender_stream = ((!) stream_interactor).get_stream((!) sender_account);
            if (sender_stream == null) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B sender-only smoke lost the sender stream");
            }
            apply_jingle_s5b_account_network_policy((!) sender_account, (!) sender_stream, "sender", config);
            sender_iq_module = ((!) sender_stream).get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (sender_iq_module == null) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B sender-only smoke has no IQ module");
            }
            sender_iq_outgoing_handler = ((!) sender_iq_module).preprocess_outgoing_iq_set_get.connect((stream, iq_stanza) => {
                observe_sender_s5b_transport_iq(transport_observation, config, iq_stanza, true);
            });
            sender_iq_incoming_handler = ((!) sender_iq_module).preprocess_incoming_iq_set_get.connect((stream, iq_stanza) => {
                observe_sender_s5b_transport_iq(transport_observation, config, iq_stanza, false);
            });

            if (config.sender_expects_v2_only_receiver) {
                yield assert_external_receiver_v2_only_pubsub_visible((!) sender_stream,
                    config.receiver_jid.bare_jid, config.receiver_omemo2_device_id, config.timeout_seconds);
            }
            if (config.use_omemo2) {
                yield wait_for_sender_omemo2_ready((!) omemo_db, runtime,
                    (!) sender_account, sender_store, config.receiver_jid.bare_jid, config.timeout_seconds);
            } else {
                yield wait_for_sender_omemo1_ready((!) omemo_db, runtime,
                    (!) sender_account, sender_store, config.receiver_jid.bare_jid, config.timeout_seconds);
            }

            Jid sender_full_jid = get_bound_full_jid((!) sender_stream);
            replace_available_resource((!) sender_stream, (!) config.receiver_full_jid, sender_full_jid);

            if (!(yield wait_for_upload_available((!) file_manager, sender_conversation, config.timeout_seconds))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for $(config.protocol_label())/JET Jingle S5B upload availability to external receiver");
            }

            var phases = new Gee.ArrayList<FileTransfer.Phase>();
            sent_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (Account.equals_func(file_transfer.account, (!) sender_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_SENT &&
                        file_transfer.counterpart.equals_bare(config.receiver_jid) &&
                        file_transfer.file_name == config.payload_name) {
                    sent_transfer = file_transfer;
                    sent_stored_path = file_transfer.path;
                    phases.add(file_transfer.phase);
                    file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
                }
            });

            string payload_path = Path.build_filename(temp_dir, config.payload_name);
            FileUtils.set_contents(payload_path, config.payload_text);
            uint8[] payload = config.payload_text.data;

            yield ((!) file_manager).send_file(File.new_for_path(payload_path), sender_conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });

            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    sent_transfer != null &&
                    (((!) sent_transfer).phase == FileTransfer.Phase.COMPLETE ||
                        ((!) sent_transfer).phase == FileTransfer.Phase.FAILED)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote $(config.protocol_label())/JET Jingle S5B sender-only completion (sent=$(format_transfer_state(sent_transfer)))");
            }
            drain_pending_events();

            if (sent_transfer == null) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B sender-only did not publish a sent transfer object");
            }
            FileTransfer sender_transfer = (!) sent_transfer;
            if (sender_transfer.phase == FileTransfer.Phase.FAILED) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B sender-only failed (sent=$(format_transfer_state(sent_transfer)))");
            }

            validate_sent_transfer((!) core_db, sender_transfer, sender_conversation, config);
            if (!config.use_omemo2 && !has_ready_omemo_session((!) omemo_db,
                    (!) sender_account, sender_store, config.receiver_jid.bare_jid,
                    runtime.trust_manager.get_trusted_devices_omemo1((!) sender_account, config.receiver_jid.bare_jid))) {
                throw new IOError.FAILED("the first JET-OMEMO file send must establish the recipient session");
            }
            yield validate_stored_payload(file_encryption, sender_transfer, payload, "sent local copy");
            assert_phase_order(phases, FileTransfer.Phase.STORING, FileTransfer.Phase.REQUESTING_SLOT,
                @"remote $(config.protocol_label())/JET Jingle S5B sender-only must store the local copy before requesting transport");
            assert_phase_order(phases, FileTransfer.Phase.REQUESTING_SLOT, FileTransfer.Phase.UPLOADING,
                @"remote $(config.protocol_label())/JET Jingle S5B sender-only must request transport before upload");
            assert_phase_order(phases, FileTransfer.Phase.UPLOADING, FileTransfer.Phase.COMPLETE,
                @"remote $(config.protocol_label())/JET Jingle S5B sender-only must complete after upload");
            validate_sender_s5b_transport_observation(transport_observation, config);

            GLib.Test.message(@"Remote $(config.protocol_label())/JET Jingle S5B sender-only smoke passed");
        } catch (Error e) {
            pending_error = e;
        }

        if (pending_error != null) {
            cancel_observed_transfer(sent_transfer);
            yield wait_for_condition(5, () => transfer_is_quiescent(sent_transfer));
            drain_pending_events();
        }

        if (file_manager != null && sent_handler != 0) {
            SignalHandler.disconnect((!) file_manager, sent_handler);
            sent_handler = 0;
        }
        if (sender_iq_module != null && sender_iq_outgoing_handler != 0) {
            SignalHandler.disconnect((!) sender_iq_module, sender_iq_outgoing_handler);
            sender_iq_outgoing_handler = 0;
        }
        if (sender_iq_module != null && sender_iq_incoming_handler != 0) {
            SignalHandler.disconnect((!) sender_iq_module, sender_iq_incoming_handler);
            sender_iq_incoming_handler = 0;
        }
        restore_jingle_file_encryption_helper(previous_jingle_helper);

        if (stream_interactor != null && sender_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) sender_account);
        }
        restore_default_application(application, previous_application);
        if (sent_stored_path != null && storage_dir != null) {
            FileUtils.remove(Path.build_filename((!) storage_dir, (!) sent_stored_path));
        }
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
            GLib.Test.message(@"Could not clean remote OMEMO Jingle S5B sender-only temp dir: $(e.message)");
        }

        if (pending_error != null) throw (!) pending_error;
        if (temp_cleanup_error != null) throw (!) temp_cleanup_error;
    }

    private async void run_omemo_jingle_s5b_receive(RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-omemo-jingle-s5b-receive-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Dino.Database? core_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        StreamInteractor? stream_interactor = null;
        FileManager? file_manager = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        Account? receiver_account = null;
        XmppStream? receiver_stream = null;
        FileTransfer? received_transfer = null;
        Conversation? received_conversation = null;
        string? received_stored_path = null;
        string? storage_dir = null;
        ulong received_handler = 0;
        ulong incoming_handler = 0;
        ulong session_handler = 0;
        RemoteOmemoJingleIncomingObservation incoming_observation = new RemoteOmemoJingleIncomingObservation();
        RemoteOmemoJingleReceiveObservation receive_observation = new RemoteOmemoJingleReceiveObservation();
        Dino.JingleFileEncryptionHelper? previous_jingle_helper = null;
        RemotePubsubItemSnapshot? original_omemo1_devicelist = null;
        RemotePubsubItemSnapshot? original_omemo2_devicelist = null;
        RemotePubsubItemSnapshot? original_omemo2_bundle = null;
        bool omemo1_devicelist_overridden = false;
        bool omemo2_devicelist_overridden = false;
        bool omemo2_bundle_overridden = false;
        int32 receiver_omemo2_device_id = 0;
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage(temp_dir);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("OMEMO context could not be initialized");
            }

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-omemo-jingle-s5b-receive");
            omemo_db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption);
            file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OMEMO Jingle S5B receive-only smoke");
            }
            OmemoJingleRuntime runtime = install_omemo_jingle_runtime(
                (!) stream_interactor, (!) omemo_db, (!) file_manager, true, config.use_omemo2);
            previous_jingle_helper = runtime.previous_jingle_helper;

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) core_db, (!) receiver_account);

            seed_trusted_roster_contact((!) core_db, (!) receiver_account, config.sender_jid);
            if (config.use_omemo2) {
                seed_identity_for_manual_pubsub_fixture(Dino.Plugins.Omemo.Plugin.get_context(), (!) omemo_db, (!) receiver_account);
            }

            Conversation receiver_conversation = new Conversation(
                config.sender_jid.bare_jid, (!) receiver_account, Conversation.Type.CHAT);
            receiver_conversation.persist((!) core_db);
            receiver_conversation.encryption = Encryption.OMEMO;
            receiver_conversation.send_typing = Conversation.Setting.OFF;
            receiver_conversation.send_marker = Conversation.Setting.OFF;

            string? connect_failure = yield connect_and_wait_for_negotiation(
                (!) stream_interactor, (!) receiver_account, config.timeout_seconds);
            if (connect_failure != null) {
                throw new IOError.TIMED_OUT("receiver " + (!) connect_failure);
            }

            Store receiver_store = yield wait_for_omemo_store(
                (!) stream_interactor, (!) omemo_db, (!) receiver_account, config.timeout_seconds);
            receiver_stream = ((!) stream_interactor).get_stream((!) receiver_account);
            if (receiver_stream == null) {
                throw new IOError.FAILED("remote OMEMO Jingle S5B receive-only smoke lost the receiver stream");
            }
            if (config.use_omemo2) {
                uint snapshot_timeout = config.timeout_seconds < 10 ? config.timeout_seconds : 10;
                if (snapshot_timeout == 0) snapshot_timeout = 1;
                original_omemo1_devicelist = yield request_pubsub_item_snapshot_with_timeout((!) receiver_stream,
                    (!) receiver_account, OMEMO1_NODE_DEVICELIST, "current", snapshot_timeout);
                if (((!) original_omemo1_devicelist).status == RemotePubsubItemSnapshotStatus.UNKNOWN) {
                    throw new IOError.FAILED("could not safely snapshot receiver OMEMO1 device list before v2-only receive smoke");
                }
                original_omemo2_devicelist = yield request_pubsub_item_snapshot_with_timeout((!) receiver_stream,
                    (!) receiver_account, Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", snapshot_timeout);
                if (((!) original_omemo2_devicelist).status == RemotePubsubItemSnapshotStatus.UNKNOWN) {
                    throw new IOError.FAILED("could not safely snapshot receiver OMEMO2 device list before v2-only receive smoke");
                }
                receiver_omemo2_device_id = (int32) receiver_store.local_registration_id;
                original_omemo2_bundle = yield request_pubsub_item_snapshot_with_timeout((!) receiver_stream,
                    (!) receiver_account, Xmpp.Xep.Omemo.NODE_BUNDLES_V2,
                    receiver_omemo2_device_id.to_string(), snapshot_timeout);
                if (((!) original_omemo2_bundle).status == RemotePubsubItemSnapshotStatus.UNKNOWN) {
                    throw new IOError.FAILED("could not safely snapshot receiver OMEMO2 bundle before v2-only receive smoke");
                }
                omemo2_bundle_overridden = true;
                yield wait_for_own_omemo2_pubsub_ready((!) receiver_stream, (!) omemo_db,
                    (!) receiver_account, receiver_store, config.timeout_seconds);
                yield publish_single_omemo2_devicelist_for_v2_only_receive((!) receiver_stream,
                    (!) receiver_account, (int32) receiver_store.local_registration_id, config.timeout_seconds);
                omemo2_devicelist_overridden = true;
                yield publish_empty_omemo1_devicelist_for_v2_only_receive((!) receiver_stream,
                    (!) receiver_account, config.timeout_seconds);
                omemo1_devicelist_overridden = true;
            } else {
                yield wait_for_own_omemo1_pubsub_ready((!) receiver_stream, (!) omemo_db,
                    (!) receiver_account, receiver_store, config.timeout_seconds);
            }

            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<JingleFileTransfer.Module>(
                (!) receiver_account, JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module == null) {
                throw new IOError.FAILED("receiver Jingle file-transfer module was not available");
            }
            incoming_handler = ((!) jingle_file_module).file_incoming.connect((stream, jingle_transfer) => {
                if (!jingle_transfer.peer.equals_bare(config.sender_jid)) return;
                incoming_observation.count++;
                incoming_observation.peer = jingle_transfer.peer;
                incoming_observation.file_name = jingle_transfer.file_name;
                incoming_observation.size = jingle_transfer.size;
                incoming_observation.transport_ns_uri = jingle_transfer.transport_ns_uri;
                incoming_observation.security = jingle_transfer.security as Jet.SecurityParameters;
            });

            var receiver_jingle_module = ((!) receiver_stream).get_module<Jingle.Module>(Jingle.Module.IDENTITY);
            if (receiver_jingle_module == null) {
                throw new IOError.FAILED("receiver Jingle module was not attached");
            }
            session_handler = ((!) receiver_jingle_module).session_initiate_received.connect((seen_stream, session) => {
                if (!session.peer_full_jid.equals_bare(config.sender_jid)) return;
                incoming_observation.session_sid = session.sid;
                session.terminated.connect((terminated_stream, we_terminated, reason_name, reason_text) => {
                    incoming_observation.session_terminate_reason = reason_name;
                });
            });

            received_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (Account.equals_func(file_transfer.account, (!) receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
                        file_transfer.counterpart.equals_bare(config.sender_jid) &&
                        file_transfer.file_name == config.payload_name) {
                    received_transfer = file_transfer;
                    received_conversation = conversation;
                    received_stored_path = file_transfer.path;
                    observe_received_transfer_publication(file_transfer, receive_observation);
                    file_transfer.notify["phase"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    file_transfer.notify["state"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    file_transfer.notify["path"].connect(() => observe_received_transfer_publication(file_transfer, receive_observation));
                    // Exercise the regular explicit receive path if auto-download is off.
                    if (file_transfer.state == FileTransfer.State.NOT_STARTED) {
                        ((!) file_manager).download_file.begin(file_transfer);
                    }
                }
            });

            if (config.use_omemo2) {
                yield publish_single_omemo2_devicelist_for_v2_only_receive((!) receiver_stream,
                    (!) receiver_account, (int32) receiver_store.local_registration_id, config.timeout_seconds);
                yield publish_empty_omemo1_devicelist_for_v2_only_receive((!) receiver_stream,
                    (!) receiver_account, config.timeout_seconds);
                yield wait_for_v2_only_receive_pubsub_state((!) receiver_stream, (!) receiver_account,
                    (int32) receiver_store.local_registration_id, config.timeout_seconds);
            }
            publish_ready_message((!) stream_interactor, (!) receiver_account, receiver_store, config);

            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    received_transfer != null &&
                    (((!) received_transfer).phase == FileTransfer.Phase.COMPLETE ||
                        ((!) received_transfer).phase == FileTransfer.Phase.FAILED)))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote $(config.protocol_label())/JET Jingle S5B receive-only completion (received=$(format_transfer_state(received_transfer)), incoming=$(format_incoming_observation(incoming_observation)))");
            }
            drain_pending_events();

            if (received_transfer == null) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only smoke did not publish a transfer object (received=$(format_transfer_state(received_transfer)))");
            }
            FileTransfer receiver_transfer = (!) received_transfer;
            if (receiver_transfer.phase == FileTransfer.Phase.FAILED) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only failed (received=$(format_transfer_state(received_transfer)))");
            }
            if (received_conversation == null) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only did not publish a conversation");
            }

            validate_incoming_observation(incoming_observation, config, receiver_store);
            validate_receive_publication_observation(receive_observation);
            validate_received_transfer((!) core_db, receiver_transfer, (!) received_conversation,
                receiver_conversation, config);
            uint8[] payload = config.payload_text.data;
            yield validate_stored_payload(file_encryption, receiver_transfer, payload, "received local copy");

            if (count_receive_pending_files_for_basename((!) storage_dir, config.payload_name) != 0) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only left pending receive files");
            }
            if (incoming_observation.session_sid == null) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only did not observe a receiver Jingle session id");
            }
            string session_sid = (!) incoming_observation.session_sid;
            if (has_jingle_session_state((!) receiver_stream, session_sid)) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only left receiver Jingle session state");
            }
            if (incoming_observation.session_terminate_reason != Jingle.ReasonElement.SUCCESS) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B receive-only terminated with $(incoming_observation.session_terminate_reason ?? "(none)") instead of success");
            }

            GLib.Test.message(@"Remote $(config.protocol_label())/JET Jingle S5B receive-only smoke passed");
            // A separate v2-only guard must inspect PEP before this receiver
            // restores its temporary device list and bundle during cleanup.
            if (config.receive_release_file != null &&
                    !(yield wait_for_condition(config.timeout_seconds, () =>
                        FileUtils.test((!) config.receive_release_file, FileTest.EXISTS)))) {
                throw new IOError.TIMED_OUT("timed out waiting for receive-only cleanup release");
            }
        } catch (Error e) {
            pending_error = e;
        }

        if (pending_error != null) {
            cancel_observed_transfer(received_transfer);
            terminate_jingle_session_if_present(receiver_stream, incoming_observation.session_sid);
            yield wait_for_condition(5, () => transfer_is_quiescent(received_transfer));
            drain_pending_events();
        }

        if (stream_interactor != null && receiver_account != null && incoming_handler != 0) {
            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<JingleFileTransfer.Module>(
                (!) receiver_account, JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module != null) SignalHandler.disconnect((!) jingle_file_module, incoming_handler);
            incoming_handler = 0;
        }
        if (receiver_stream != null && session_handler != 0) {
            var receiver_jingle_module = ((!) receiver_stream).get_module<Jingle.Module>(Jingle.Module.IDENTITY);
            if (receiver_jingle_module != null) SignalHandler.disconnect((!) receiver_jingle_module, session_handler);
            session_handler = 0;
        }
        if (file_manager != null && received_handler != 0) {
            SignalHandler.disconnect((!) file_manager, received_handler);
            received_handler = 0;
        }
        restore_jingle_file_encryption_helper(previous_jingle_helper);

        if (config.use_omemo2 && omemo2_bundle_overridden && receiver_stream != null && receiver_account != null &&
                original_omemo2_bundle != null) {
            try {
                if (receiver_omemo2_device_id == 0) {
                    throw new IOError.FAILED("receiver OMEMO2 device id was missing during bundle cleanup");
                }
                string bundle_item_id = receiver_omemo2_device_id.to_string();
                if (((!) original_omemo2_bundle).status == RemotePubsubItemSnapshotStatus.PRESENT) {
                    yield restore_omemo2_bundle_after_v2_only_receive((!) receiver_stream,
                        (!) receiver_account, bundle_item_id, (!) ((!) original_omemo2_bundle).item, config.timeout_seconds);
                } else {
                    if (!(yield retract_pubsub_item_with_timeout((!) receiver_stream, (!) receiver_account,
                            Xmpp.Xep.Omemo.NODE_BUNDLES_V2, bundle_item_id, config.timeout_seconds))) {
                        throw new IOError.FAILED("could not retract receiver OMEMO2 bundle after OMEMO2 receive-only smoke");
                    }
                }
            } catch (Error e) {
                GLib.Test.message(@"Could not restore receiver OMEMO2 bundle after OMEMO2 receive-only smoke: $(e.message)");
                if (pending_error == null) pending_error = e;
            }
        }

        if (config.use_omemo2 && omemo2_devicelist_overridden && receiver_stream != null && receiver_account != null) {
            try {
                if (original_omemo2_devicelist == null) {
                    throw new IOError.FAILED("receiver OMEMO2 device-list snapshot was missing during cleanup");
                } else if (((!) original_omemo2_devicelist).status == RemotePubsubItemSnapshotStatus.PRESENT) {
                    yield restore_omemo2_devicelist_after_v2_only_receive((!) receiver_stream,
                        (!) receiver_account, (!) ((!) original_omemo2_devicelist).item, config.timeout_seconds);
                } else {
                    if (!(yield retract_pubsub_item_with_timeout((!) receiver_stream, (!) receiver_account,
                            Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", config.timeout_seconds))) {
                        throw new IOError.FAILED("could not retract receiver OMEMO2 device list after OMEMO2 receive-only smoke");
                    }
                }
            } catch (Error e) {
                GLib.Test.message(@"Could not restore receiver OMEMO2 device list after OMEMO2 receive-only smoke: $(e.message)");
                if (pending_error == null) pending_error = e;
            }
        }

        if (config.use_omemo2 && omemo1_devicelist_overridden && receiver_stream != null && receiver_account != null) {
            try {
                if (original_omemo1_devicelist == null) {
                    throw new IOError.FAILED("receiver OMEMO1 device-list snapshot was missing during cleanup");
                } else if (((!) original_omemo1_devicelist).status == RemotePubsubItemSnapshotStatus.PRESENT) {
                    yield restore_omemo1_devicelist_after_v2_only_receive((!) receiver_stream,
                        (!) receiver_account, (!) ((!) original_omemo1_devicelist).item, config.timeout_seconds);
                } else {
                    if (!(yield retract_pubsub_item_with_timeout((!) receiver_stream, (!) receiver_account,
                            OMEMO1_NODE_DEVICELIST, "current", config.timeout_seconds))) {
                        throw new IOError.FAILED("could not retract receiver OMEMO1 device list after OMEMO2 receive-only smoke");
                    }
                }
            } catch (Error e) {
                GLib.Test.message(@"Could not restore receiver OMEMO1 device list after OMEMO2 receive-only smoke: $(e.message)");
                if (pending_error == null) pending_error = e;
            }
        }

        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) receiver_account);
        }
        restore_default_application(application, previous_application);
        if (received_stored_path != null && storage_dir != null) {
            FileUtils.remove(Path.build_filename((!) storage_dir, (!) received_stored_path));
        }
        if (storage_dir != null) {
            delete_receive_pending_files_for_basename((!) storage_dir, config.payload_name);
        }
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
            GLib.Test.message(@"Could not clean remote OMEMO Jingle S5B receive-only temp dir: $(e.message)");
        }

        if (pending_error != null) throw (!) pending_error;
        if (temp_cleanup_error != null) throw (!) temp_cleanup_error;
    }

    private async void run_external_receiver_v2_only_guard(RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-omemo-jingle-s5b-v2-only-guard-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Dino.Database? core_db = null;
        Dino.Plugins.Omemo.Database? omemo_db = null;
        StreamInteractor? stream_interactor = null;
        FileManager? file_manager = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        Account? receiver_account = null;
        XmppStream? receiver_stream = null;
        Dino.JingleFileEncryptionHelper? previous_jingle_helper = null;
        RemotePubsubItemSnapshot? original_omemo1_devicelist = null;
        RemotePubsubItemSnapshot? original_omemo2_devicelist = null;
        bool omemo1_devicelist_overridden = false;
        bool omemo2_devicelist_overridden = false;
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            configure_isolated_storage(temp_dir);

            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("OMEMO context could not be initialized");
            }

            core_db = new Dino.Database(Path.build_filename(temp_dir, "dino.db"), "remote-omemo-jingle-s5b-v2-only-guard");
            omemo_db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            stream_interactor = new StreamInteractor.for_tests((!) core_db);
            application = new TestApplication((!) core_db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) core_db, file_encryption);
            file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote OMEMO2 external receiver v2-only guard");
            }
            OmemoJingleRuntime runtime = install_omemo_jingle_runtime(
                (!) stream_interactor, (!) omemo_db, (!) file_manager, false);
            previous_jingle_helper = runtime.previous_jingle_helper;

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) core_db, (!) receiver_account);

            string? connect_failure = yield connect_and_wait_for_negotiation((!) stream_interactor,
                (!) receiver_account, config.timeout_seconds, false);
            if (connect_failure != null) {
                throw new IOError.TIMED_OUT("receiver v2-only guard " + (!) connect_failure);
            }

            receiver_stream = ((!) stream_interactor).get_stream((!) receiver_account);
            if (receiver_stream == null) {
                throw new IOError.FAILED("remote OMEMO2 external receiver v2-only guard lost the receiver stream");
            }

            uint snapshot_timeout = config.timeout_seconds < 10 ? config.timeout_seconds : 10;
            if (snapshot_timeout == 0) snapshot_timeout = 1;
            original_omemo1_devicelist = yield request_pubsub_item_snapshot_with_timeout((!) receiver_stream,
                (!) receiver_account, OMEMO1_NODE_DEVICELIST, "current", snapshot_timeout);
            if (((!) original_omemo1_devicelist).status == RemotePubsubItemSnapshotStatus.UNKNOWN) {
                throw new IOError.FAILED("could not safely snapshot external receiver OMEMO1 device list before v2-only guard");
            }
            if (((!) original_omemo1_devicelist).status != RemotePubsubItemSnapshotStatus.PRESENT) {
                throw new IOError.FAILED("external receiver OMEMO1 device list must already exist before v2-only guard to avoid creating a PEP node that cannot be fully restored");
            }

            Gee.ArrayList<int32>? omemo2_device_list = yield request_raw_omemo2_devicelist_with_timeout(
                (!) receiver_stream, ((!) receiver_account).bare_jid, snapshot_timeout);
            if (omemo2_device_list == null || ((!) omemo2_device_list).size == 0) {
                throw new IOError.FAILED("external receiver has no visible OMEMO2 device list for v2-only guard");
            }

            Gee.ArrayList<int32> expected_omemo2_device_list = new Gee.ArrayList<int32>();
            if (config.receiver_omemo2_device_id > 0) {
                original_omemo2_devicelist = yield request_pubsub_item_snapshot_with_timeout((!) receiver_stream,
                    (!) receiver_account, Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", snapshot_timeout);
                if (((!) original_omemo2_devicelist).status == RemotePubsubItemSnapshotStatus.UNKNOWN) {
                    throw new IOError.FAILED("could not safely snapshot external receiver OMEMO2 device list before targeted v2-only guard");
                }
                if (((!) original_omemo2_devicelist).status != RemotePubsubItemSnapshotStatus.PRESENT) {
                    throw new IOError.FAILED("external receiver OMEMO2 device list must already exist before targeted v2-only guard");
                }
                if (!contains_device_id((!) omemo2_device_list, config.receiver_omemo2_device_id)) {
                    throw new IOError.FAILED("external receiver target OMEMO2 device id is not present in the visible OMEMO2 device list");
                }
                expected_omemo2_device_list.add(config.receiver_omemo2_device_id);
                yield publish_single_omemo2_devicelist_for_v2_only_receive((!) receiver_stream,
                    (!) receiver_account, config.receiver_omemo2_device_id, config.timeout_seconds);
                omemo2_devicelist_overridden = true;
            } else {
                foreach (int32 device_id in (!) omemo2_device_list) {
                    expected_omemo2_device_list.add(device_id);
                }
            }

            foreach (int32 device_id in expected_omemo2_device_list) {
                if (!(yield omemo2_bundle_payload_visible_with_timeout((!) receiver_stream,
                        (!) receiver_account, device_id, snapshot_timeout))) {
                    throw new IOError.FAILED(@"external receiver OMEMO2 bundle for device $device_id is not visible");
                }
            }

            yield publish_empty_omemo1_devicelist_for_v2_only_receive((!) receiver_stream,
                (!) receiver_account, config.timeout_seconds);
            omemo1_devicelist_overridden = true;
            yield force_external_receiver_v2_only_pubsub_state((!) receiver_stream,
                (!) receiver_account, expected_omemo2_device_list, omemo2_devicelist_overridden,
                config.timeout_seconds);

            publish_v2_only_guard_ready_message(config, expected_omemo2_device_list);

            if (!(yield maintain_external_receiver_v2_only_guard_until_done((!) receiver_stream,
                    (!) receiver_account, expected_omemo2_device_list,
                    omemo2_devicelist_overridden, config))) {
                throw new IOError.TIMED_OUT("timed out waiting for external receiver v2-only guard done file");
            }

            GLib.Test.message("Remote OMEMO2/JET external receiver v2-only guard passed");
        } catch (Error e) {
            pending_error = e;
        }

        restore_jingle_file_encryption_helper(previous_jingle_helper);

        if (omemo2_devicelist_overridden && receiver_stream != null && receiver_account != null &&
                original_omemo2_devicelist != null) {
            try {
                if (((!) original_omemo2_devicelist).status == RemotePubsubItemSnapshotStatus.PRESENT) {
                    yield restore_omemo2_devicelist_after_v2_only_receive((!) receiver_stream,
                        (!) receiver_account, (!) ((!) original_omemo2_devicelist).item, config.timeout_seconds);
                } else {
                    if (!(yield retract_pubsub_item_with_timeout((!) receiver_stream, (!) receiver_account,
                            Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", config.timeout_seconds))) {
                        throw new IOError.FAILED("could not retract external receiver OMEMO2 device list after v2-only guard");
                    }
                }
                yield verify_pubsub_item_snapshot_restored((!) receiver_stream, (!) receiver_account,
                    Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", (!) original_omemo2_devicelist,
                    config.timeout_seconds, "external receiver OMEMO2 device list");
            } catch (Error e) {
                GLib.Test.message(@"Could not restore external receiver OMEMO2 device list after v2-only guard: $(e.message)");
                if (pending_error == null) pending_error = e;
            }
        }

        if (omemo1_devicelist_overridden && receiver_stream != null && receiver_account != null &&
                original_omemo1_devicelist != null) {
            try {
                if (((!) original_omemo1_devicelist).status == RemotePubsubItemSnapshotStatus.PRESENT) {
                    yield restore_omemo1_devicelist_after_v2_only_receive((!) receiver_stream,
                        (!) receiver_account, (!) ((!) original_omemo1_devicelist).item, config.timeout_seconds);
                } else {
                    if (!(yield retract_pubsub_item_with_timeout((!) receiver_stream, (!) receiver_account,
                            OMEMO1_NODE_DEVICELIST, "current", config.timeout_seconds))) {
                        throw new IOError.FAILED("could not retract external receiver OMEMO1 device list after v2-only guard");
                    }
                }
                yield verify_pubsub_item_snapshot_restored((!) receiver_stream, (!) receiver_account,
                    OMEMO1_NODE_DEVICELIST, "current", (!) original_omemo1_devicelist,
                    config.timeout_seconds, "external receiver OMEMO1 device list");
            } catch (Error e) {
                GLib.Test.message(@"Could not restore external receiver OMEMO1 device list after v2-only guard: $(e.message)");
                if (pending_error == null) pending_error = e;
            }
        }

        if (stream_interactor != null && receiver_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) receiver_account);
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
            GLib.Test.message(@"Could not clean remote OMEMO2 external receiver v2-only guard temp dir: $(e.message)");
        }

        if (pending_error != null) throw (!) pending_error;
        if (temp_cleanup_error != null) throw (!) temp_cleanup_error;
    }

    private static void start_remote_file_modules(StreamInteractor stream_interactor, Dino.Database db,
            FileEncryption file_encryption) {
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
        ContentItemStore.start(stream_interactor, db);
    }

    private static OmemoJingleRuntime install_omemo_jingle_runtime(StreamInteractor stream_interactor,
            Dino.Plugins.Omemo.Database omemo_db, FileManager file_manager, bool auto_publish_own_device_lists,
            bool receive_only_omemo2_v2_only = false) {
        OmemoJingleRuntime runtime = new OmemoJingleRuntime();
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
            stream_module.auto_publish_own_device_list =
                auto_publish_own_device_lists && !receive_only_omemo2_v2_only;
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
            modules.add(new Dino.Plugins.JetOmemo.Module());
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
        var registry = Dino.JingleFileHelperRegistry.instance;
        runtime.previous_jingle_helper = registry.get_encryption_helper(Encryption.OMEMO);
        registry.add_encryption_helper(Encryption.OMEMO, new Dino.Plugins.JetOmemo.EncryptionHelper(stream_interactor, runtime.trust_manager));
        runtime.manager = Dino.Plugins.Omemo.Manager.start(stream_interactor, omemo_db, runtime.trust_manager,
            runtime.encryptors, runtime.encryptors_v2);
        runtime.manager.auto_publish_own_device_lists =
            auto_publish_own_device_lists && !receive_only_omemo2_v2_only;
        return runtime;
    }

    private static void restore_jingle_file_encryption_helper(Dino.JingleFileEncryptionHelper? previous_helper) {
        var registry = Dino.JingleFileHelperRegistry.instance;
        if (previous_helper != null) {
            registry.add_encryption_helper(Encryption.OMEMO, (!) previous_helper);
        } else {
            registry.encryption_helpers.unset(Encryption.OMEMO);
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
            throw new IOError.PERMISSION_DENIED(@"remote OMEMO Jingle S5B smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
        }
        return storage_dir;
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
            .value(db.roster.subscription, Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private async string? connect_and_wait_for_negotiation(StreamInteractor stream_interactor,
            Account account, uint timeout_seconds, bool advertise_presence = true) {
        string local_failure_reason = "";
        bool completed = false;
        bool success = false;
        SourceFunc resume = connect_and_wait_for_negotiation.callback;
        uint timeout_id = 0;
        ulong negotiated_id = 0;
        ulong error_id = 0;
        ulong stream_opened_id = 0;

        if (!advertise_presence) {
            stream_opened_id = stream_interactor.connection_manager.stream_opened.connect((seen_account, stream) => {
                if (!Account.equals_func(seen_account, account)) return;
                Presence.Module? presence_module = stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
                if (presence_module != null) {
                    ((!) presence_module).available_resource = false;
                }
            });
        }

        negotiated_id = stream_interactor.stream_negotiated.connect((seen_account, stream) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = true;
            remove_source(ref timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            if (stream_opened_id != 0) {
                SignalHandler.disconnect(stream_interactor.connection_manager, stream_opened_id);
                stream_opened_id = 0;
            }
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
            if (stream_opened_id != 0) {
                SignalHandler.disconnect(stream_interactor.connection_manager, stream_opened_id);
                stream_opened_id = 0;
            }
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
            if (stream_opened_id != 0) {
                SignalHandler.disconnect(stream_interactor.connection_manager, stream_opened_id);
                stream_opened_id = 0;
            }
            resume();
            return Source.REMOVE;
        });

        stream_interactor.connect_account(account);
        yield;
        if (stream_opened_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, stream_opened_id);
        return success ? null : local_failure_reason;
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

    private static void seed_identity_for_manual_pubsub_fixture(Context context,
            Dino.Plugins.Omemo.Database db, Account account) throws Error {
        // Manually managed v2 fixtures model an existing local identity; the
        // five legacy cases must pass the real first-registration gate.
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

    private async void wait_for_own_omemo1_pubsub_ready(XmppStream stream,
            Dino.Plugins.Omemo.Database omemo_db, Account account, Store store,
            uint timeout_seconds) throws Error {
        if (!(yield wait_for_own_omemo1_device(omemo_db, account, store, timeout_seconds))) {
            throw new IOError.TIMED_OUT("timed out waiting for receiver OMEMO1 own-device local state");
        }
        Dino.Plugins.Omemo.StreamModule? module =
            stream.get_module<Dino.Plugins.Omemo.StreamModule>(Dino.Plugins.Omemo.StreamModule.IDENTITY);
        if (module == null) {
            throw new IOError.FAILED("receiver OMEMO1 stream module was not available");
        }

        int32 own_device_id = (int32) store.local_registration_id;
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        uint trigger_timeout = remaining_timeout_seconds(deadline, 10);
        if (trigger_timeout == 0) {
            throw new IOError.TIMED_OUT("timed out before receiver OMEMO1 device-list publish trigger");
        }
        yield request_omemo1_devicelist_with_timeout((!) module, stream, account.bare_jid, trigger_timeout);

        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            Gee.ArrayList<int32>? device_list = yield request_raw_omemo1_devicelist_with_timeout(
                stream, account.bare_jid, step_timeout);
            if (device_list != null && contains_device_id((!) device_list, own_device_id) &&
                    yield wait_for_omemo1_bundle_with_timeout((!) module, stream,
                        account.bare_jid, own_device_id, step_timeout)) {
                return;
            }

            Timeout.add(500, () => {
                wait_for_own_omemo1_pubsub_ready.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out waiting for receiver OMEMO1 device-list and bundle PubSub visibility");
    }

    private async void publish_empty_omemo1_devicelist_for_v2_only_receive(XmppStream stream,
            Account account, uint timeout_seconds) throws Error {
        var publish_options = new Xmpp.Xep.Pubsub.PublishOptions()
            .set_access_model(Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);
        StanzaNode list_node = new StanzaNode.build("list", NS_OMEMO_LEGACY).add_self_xmlns();

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            if (yield publish_pubsub_item_with_timeout(stream, account.bare_jid,
                    OMEMO1_NODE_DEVICELIST, "current", list_node, publish_options, step_timeout)) return;

            Timeout.add(500, () => {
                publish_empty_omemo1_devicelist_for_v2_only_receive.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out publishing v2-only receiver empty OMEMO1 device list");
    }

    private async void restore_omemo1_devicelist_after_v2_only_receive(XmppStream stream,
            Account account, StanzaNode original_list_node, uint timeout_seconds) throws Error {
        var publish_options = new Xmpp.Xep.Pubsub.PublishOptions()
            .set_access_model(Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            if (yield publish_pubsub_item_with_timeout(stream, account.bare_jid,
                    OMEMO1_NODE_DEVICELIST, "current", original_list_node, publish_options, step_timeout)) return;

            Timeout.add(500, () => {
                restore_omemo1_devicelist_after_v2_only_receive.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out restoring receiver OMEMO1 device list after OMEMO2 receive-only smoke");
    }

    private async void publish_single_omemo2_devicelist_for_v2_only_receive(XmppStream stream,
            Account account, int32 own_device_id, uint timeout_seconds) throws Error {
        var publish_options = new Xmpp.Xep.Pubsub.PublishOptions()
            .set_access_model(Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);
        StanzaNode devices_node = new StanzaNode.build("devices", NS_OMEMO_V2).add_self_xmlns()
            .put_node(new StanzaNode.build("device", NS_OMEMO_V2)
                .put_attribute("id", own_device_id.to_string()));

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            if (yield publish_pubsub_item_with_timeout(stream, account.bare_jid,
                    Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", devices_node, publish_options, step_timeout)) return;

            Timeout.add(500, () => {
                publish_single_omemo2_devicelist_for_v2_only_receive.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out publishing v2-only receiver OMEMO2 device list");
    }

    private async void restore_omemo2_devicelist_after_v2_only_receive(XmppStream stream,
            Account account, StanzaNode original_devices_node, uint timeout_seconds) throws Error {
        var publish_options = new Xmpp.Xep.Pubsub.PublishOptions()
            .set_access_model(Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("1")
            .set_persist_items(true);

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            if (yield publish_pubsub_item_with_timeout(stream, account.bare_jid,
                    Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", original_devices_node, publish_options, step_timeout)) return;

            Timeout.add(500, () => {
                restore_omemo2_devicelist_after_v2_only_receive.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out restoring receiver OMEMO2 device list after OMEMO2 receive-only smoke");
    }

    private async void restore_omemo2_bundle_after_v2_only_receive(XmppStream stream,
            Account account, string item_id, StanzaNode original_bundle_node, uint timeout_seconds) throws Error {
        var publish_options = new Xmpp.Xep.Pubsub.PublishOptions()
            .set_access_model(Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("max")
            .set_persist_items(true);

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            if (yield publish_pubsub_item_with_timeout(stream, account.bare_jid,
                    Xmpp.Xep.Omemo.NODE_BUNDLES_V2, item_id, original_bundle_node, publish_options, step_timeout)) return;

            Timeout.add(500, () => {
                restore_omemo2_bundle_after_v2_only_receive.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out restoring receiver OMEMO2 bundle after OMEMO2 receive-only smoke");
    }

    private async void wait_for_v2_only_receive_pubsub_state(XmppStream stream, Account account,
            int32 own_device_id, uint timeout_seconds) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            Gee.ArrayList<int32>? omemo2_device_list = yield request_raw_omemo2_devicelist_with_timeout(
                stream, account.bare_jid, step_timeout);

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            Gee.ArrayList<int32>? omemo1_device_list = yield request_raw_omemo1_devicelist_with_timeout(
                stream, account.bare_jid, step_timeout);

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            bool bundle_visible = yield omemo2_bundle_payload_visible_with_timeout(
                stream, account, own_device_id, step_timeout);

            if (omemo2_device_list != null && ((!) omemo2_device_list).size == 1 &&
                    contains_device_id((!) omemo2_device_list, own_device_id) &&
                    omemo1_device_list != null && ((!) omemo1_device_list).size == 0 &&
                    bundle_visible) {
                return;
            }

            Timeout.add(500, () => {
                wait_for_v2_only_receive_pubsub_state.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out waiting for receiver OMEMO2 v2-only PubSub readback");
    }

    private async void wait_for_external_receiver_v2_only_pubsub_state(XmppStream stream, Account account,
            Gee.List<int32> expected_omemo2_device_list, bool strict_omemo2_device_list,
            uint timeout_seconds) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            if (yield external_receiver_v2_only_pubsub_state_is_current(stream, account,
                    expected_omemo2_device_list, strict_omemo2_device_list, step_timeout)) {
                return;
            }

            Timeout.add(500, () => {
                wait_for_external_receiver_v2_only_pubsub_state.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out waiting for external receiver OMEMO2 v2-only PubSub readback");
    }

    private async void force_external_receiver_v2_only_pubsub_state(XmppStream stream, Account account,
            Gee.List<int32> expected_omemo2_device_list, bool publish_expected_omemo2_device_list,
            uint timeout_seconds) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            if (publish_expected_omemo2_device_list) {
                yield publish_expected_external_receiver_omemo2_devicelist(stream, account,
                    expected_omemo2_device_list, step_timeout);
            }

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            yield publish_empty_omemo1_devicelist_for_v2_only_receive(stream, account, step_timeout);

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            if (yield external_receiver_v2_only_pubsub_state_is_current(stream, account,
                    expected_omemo2_device_list, !publish_expected_omemo2_device_list, step_timeout)) {
                return;
            }

            Timeout.add(500, () => {
                force_external_receiver_v2_only_pubsub_state.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out forcing external receiver OMEMO2 v2-only PubSub readback");
    }

    private async bool maintain_external_receiver_v2_only_guard_until_done(XmppStream stream, Account account,
            Gee.List<int32> expected_omemo2_device_list, bool publish_expected_omemo2_device_list,
            RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) config.timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            if (config.done_file != null && FileUtils.test((!) config.done_file, FileTest.EXISTS)) return true;

            uint step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            if (publish_expected_omemo2_device_list) {
                yield publish_expected_external_receiver_omemo2_devicelist(stream, account,
                    expected_omemo2_device_list, step_timeout);
            }

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            yield publish_empty_omemo1_devicelist_for_v2_only_receive(stream, account, step_timeout);

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            if (!(yield external_receiver_v2_only_pubsub_state_is_current(stream, account,
                    expected_omemo2_device_list, !publish_expected_omemo2_device_list, step_timeout))) {
                if (publish_expected_omemo2_device_list) {
                    yield publish_expected_external_receiver_omemo2_devicelist(stream, account,
                        expected_omemo2_device_list, step_timeout);
                }
                yield publish_empty_omemo1_devicelist_for_v2_only_receive(stream, account, step_timeout);
                yield wait_for_external_receiver_v2_only_pubsub_state(stream, account,
                    expected_omemo2_device_list, !publish_expected_omemo2_device_list, step_timeout);
            }

            if (config.done_file != null && FileUtils.test((!) config.done_file, FileTest.EXISTS)) return true;

            Timeout.add(250, () => {
                maintain_external_receiver_v2_only_guard_until_done.callback();
                return Source.REMOVE;
            });
            yield;
        }

        return false;
    }

    private async bool external_receiver_v2_only_pubsub_state_is_current(XmppStream stream, Account account,
            Gee.List<int32> expected_omemo2_device_list, bool strict_omemo2_device_list,
            uint timeout_seconds) throws Error {
        Gee.ArrayList<int32>? omemo2_device_list = yield request_raw_omemo2_devicelist_with_timeout(
            stream, account.bare_jid, timeout_seconds);
        if (omemo2_device_list == null || ((!) omemo2_device_list).size == 0) return false;
        if (!omemo2_device_lists_equal((!) omemo2_device_list, expected_omemo2_device_list)) {
            if (strict_omemo2_device_list) {
                throw new IOError.FAILED("external receiver OMEMO2 device list changed during v2-only guard");
            }
            return false;
        }

        Gee.ArrayList<int32>? omemo1_device_list = yield request_raw_omemo1_devicelist_with_timeout(
            stream, account.bare_jid, timeout_seconds);
        if (omemo1_device_list == null) return false;

        foreach (int32 device_id in expected_omemo2_device_list) {
            if (!(yield omemo2_bundle_payload_visible_with_timeout(stream, account, device_id, timeout_seconds))) {
                throw new IOError.FAILED(@"external receiver OMEMO2 bundle for device $device_id disappeared during v2-only guard");
            }
        }

        return ((!) omemo1_device_list).size == 0;
    }

    private async void publish_expected_external_receiver_omemo2_devicelist(XmppStream stream, Account account,
            Gee.List<int32> expected_omemo2_device_list, uint timeout_seconds) throws Error {
        if (expected_omemo2_device_list.size != 1) {
            throw new IOError.FAILED("targeted external receiver OMEMO2 device-list guard requires exactly one expected OMEMO2 device");
        }
        yield publish_single_omemo2_devicelist_for_v2_only_receive(stream, account,
            expected_omemo2_device_list[0], timeout_seconds);
    }

    private async bool omemo2_bundle_payload_visible_with_timeout(XmppStream stream, Account account,
            int32 own_device_id, uint timeout_seconds) {
        RemotePubsubItemSnapshot snapshot = yield request_pubsub_item_snapshot_with_timeout(
            stream, account, Xmpp.Xep.Omemo.NODE_BUNDLES_V2, own_device_id.to_string(), timeout_seconds);
        return omemo2_bundle_payload_snapshot_is_valid(snapshot);
    }

    private async bool omemo2_bundle_payload_visible_for_jid_with_timeout(XmppStream stream, Jid jid,
            int32 own_device_id, uint timeout_seconds) {
        RemotePubsubItemSnapshot snapshot = yield request_pubsub_item_snapshot_for_jid_with_timeout(
            stream, jid.bare_jid, Xmpp.Xep.Omemo.NODE_BUNDLES_V2, own_device_id.to_string(), timeout_seconds);
        return omemo2_bundle_payload_snapshot_is_valid(snapshot);
    }

    private static bool omemo2_bundle_payload_snapshot_is_valid(RemotePubsubItemSnapshot snapshot) {
        if (snapshot.status != RemotePubsubItemSnapshotStatus.PRESENT || snapshot.item == null) return false;

        Dino.Plugins.Omemo.Bundle2 bundle = new Dino.Plugins.Omemo.Bundle2((!) snapshot.item);
        return bundle.identity_key != null &&
            bundle.signed_pre_key != null &&
            bundle.signed_pre_key_signature != null &&
            bundle.pre_keys.size > 0;
    }

    private async bool publish_pubsub_item_with_timeout(XmppStream stream, Jid? jid,
            string node_id, string item_id, StanzaNode content,
            Xmpp.Xep.Pubsub.PublishOptions publish_options, uint timeout_seconds) {
        bool completed = false;
        bool success = false;
        SourceFunc resume = publish_pubsub_item_with_timeout.callback;
        uint timeout_id = 0;

        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY).publish.begin(
            stream, jid, node_id, item_id, content, publish_options, false, (obj, res) => {
                if (completed) return;
                success = stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY).publish.end(res);
                completed = true;
                remove_source(ref timeout_id);
                resume();
            });

        yield;
        remove_source(ref timeout_id);
        return success;
    }

    private async RemotePubsubItemSnapshot request_pubsub_item_snapshot_with_timeout(XmppStream stream, Account account,
            string node_id, string item_id, uint timeout_seconds) {
        return yield request_pubsub_item_snapshot_for_jid_with_timeout(stream, account.bare_jid,
            node_id, item_id, timeout_seconds);
    }

    private async RemotePubsubItemSnapshot request_pubsub_item_snapshot_for_jid_with_timeout(XmppStream stream, Jid jid,
            string node_id, string item_id, uint timeout_seconds) {
        bool completed = false;
        RemotePubsubItemSnapshot result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.UNKNOWN);
        SourceFunc resume = request_pubsub_item_snapshot_for_jid_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        StanzaNode pubsub_node = new StanzaNode.build("pubsub", Pubsub.NS_URI).add_self_xmlns();
        StanzaNode items_node = new StanzaNode.build("items", Pubsub.NS_URI).put_attribute("node", node_id);
        items_node.put_node(new StanzaNode.build("item", Pubsub.NS_URI).put_attribute("id", item_id));
        pubsub_node.put_node(items_node);
        Iq.Stanza request_iq = new Iq.Stanza.get(pubsub_node);
        request_iq.to = jid.bare_jid;

        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async.begin(stream, request_iq,
                Priority.DEFAULT, null, (obj, res) => {
            RemotePubsubItemSnapshot async_result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.UNKNOWN);
            try {
                Iq.Stanza? iq_res = stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async.end(res);
                if (iq_res != null) {
                    if (((!) iq_res).is_error()) {
                        ErrorStanza? error = ((!) iq_res).get_error();
                        if (error != null && ((!) error).condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
                            async_result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.ABSENT);
                        }
                    } else {
                        StanzaNode? response_pubsub = ((!) iq_res).stanza.get_subnode("pubsub", Pubsub.NS_URI);
                        StanzaNode? response_items = response_pubsub != null ?
                            ((!) response_pubsub).get_subnode("items", Pubsub.NS_URI) : null;
                        StanzaNode? response_item = response_items != null ?
                            ((!) response_items).get_subnode("item", Pubsub.NS_URI) : null;
                        if (response_item == null || ((!) response_item).sub_nodes.size == 0) {
                            async_result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.ABSENT);
                        } else {
                            async_result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.PRESENT,
                                ((!) response_item).sub_nodes[0]);
                        }
                    }
                }
            } catch (Error e) {
                async_result = new RemotePubsubItemSnapshot(RemotePubsubItemSnapshotStatus.UNKNOWN);
            }
            if (completed) return;
            result = async_result;
            completed = true;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return result;
    }

    private async void verify_pubsub_item_snapshot_restored(XmppStream stream, Account account,
            string node_id, string item_id, RemotePubsubItemSnapshot expected,
            uint timeout_seconds, string description) throws Error {
        RemotePubsubItemSnapshot actual = yield request_pubsub_item_snapshot_with_timeout(
            stream, account, node_id, item_id, timeout_seconds);
        if (!pubsub_item_snapshots_equal(expected, actual)) {
            throw new IOError.FAILED(@"$description restore readback did not match the original PubSub item");
        }
    }

    private static bool pubsub_item_snapshots_equal(RemotePubsubItemSnapshot expected,
            RemotePubsubItemSnapshot actual) {
        if (expected.status != actual.status) return false;
        if (expected.status == RemotePubsubItemSnapshotStatus.UNKNOWN) return false;
        if (expected.status == RemotePubsubItemSnapshotStatus.ABSENT) return true;
        if (expected.item == null || actual.item == null) return false;
        return ((!) expected.item).to_string() == ((!) actual.item).to_string();
    }

    private async bool retract_pubsub_item_with_timeout(XmppStream stream, Account account,
            string node_id, string item_id, uint timeout_seconds) {
        Pubsub.Module? pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
        if (pubsub == null) return false;

        bool completed = false;
        bool success = false;
        SourceFunc resume = retract_pubsub_item_with_timeout.callback;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            resume();
            return Source.REMOVE;
        });

        ((!) pubsub).retract_item_with_result.begin(stream, account.bare_jid, node_id, item_id, false, (obj, res) => {
            Pubsub.RetractResult result = ((!) pubsub).retract_item_with_result.end(res);
            if (completed) return;
            // Cleanup is idempotent only for a confirmed absent item. IQ,
            // transport and permission failures must remain visible failures.
            success = result.ok || result.is_item_not_found();
            if (!success) GLib.Test.message("Remote PubSub cleanup failed: " + result.describe_error());
            completed = true;
            remove_source(ref timeout_id);
            resume();
        });

        yield;
        remove_source(ref timeout_id);
        return success;
    }

    private async bool wait_for_own_omemo1_device(Dino.Plugins.Omemo.Database omemo_db,
            Account account, Store store, uint timeout_seconds) {
        return yield wait_for_condition(timeout_seconds, () => {
            int identity_id = omemo_db.identity.get_id(account.id);
            if (identity_id < 0 || store.local_registration_id == 0) return false;
            Row? row = omemo_db.identity_meta.get_device(identity_id,
                account.bare_jid.to_string(), (int) store.local_registration_id);
            if (row == null) return false;
            Row device = (!) row;
            string? key = device[omemo_db.identity_meta.identity_key_public_base64];
            return key != null && ((!) key) != "" &&
                device[omemo_db.identity_meta.now_active] &&
                device[omemo_db.identity_meta.supports_omemo1];
        });
    }

    private async void wait_for_own_omemo2_pubsub_ready(XmppStream stream,
            Dino.Plugins.Omemo.Database omemo_db, Account account, Store store,
            uint timeout_seconds) throws Error {
        if (!(yield wait_for_condition(timeout_seconds, () =>
                store.local_registration_id != 0 &&
                omemo_db.identity.get_id(account.id) >= 0))) {
            throw new IOError.TIMED_OUT("timed out waiting for receiver OMEMO2 local identity state");
        }
        Dino.Plugins.Omemo.StreamModule2? module =
            stream.get_module<Dino.Plugins.Omemo.StreamModule2>(Dino.Plugins.Omemo.StreamModule2.IDENTITY);
        if (module == null) {
            throw new IOError.FAILED("receiver OMEMO2 stream module was not available");
        }

        // The v2-only receiver deliberately disables automatic publication
        // in Manager so it cannot restore a legacy device list. Requesting
        // the v2 list therefore cannot bootstrap its bundle. Publish the
        // current persistent Store explicitly through the production owner
        // checks, then require actual server readback instead of sleeping.
        Context context = Dino.Plugins.Omemo.Plugin.get_context();
        int64 signed_id = (int64) store.signed_pre_key_store.get_max_key_id() + 1;
        if (signed_id > int.MAX) throw new IOError.INVALID_DATA("receiver OMEMO2 signed pre-key ID range is exhausted");
        SignedPreKeyRecord signed = context.generate_signed_pre_key(store.identity_key_pair, (int32) signed_id);
        if (signed.signature_omemo.length == 0) {
            throw_by_code(Protocol.KeyHelper.upgrade_signed_pre_key(ref signed,
                store.identity_key_pair, context.native_context));
        }
        store.store_signed_pre_key(signed);
        uint32 first_key_id;
        Dino.Plugins.Omemo.BackedPreKeyStore? backed_keys = store.pre_key_store as Dino.Plugins.Omemo.BackedPreKeyStore;
        if (backed_keys != null) {
            first_key_id = ((!) backed_keys).reserve_key_ids(100, 0);
        } else {
            int64 first = (int64) store.pre_key_store.get_max_key_id() + 1;
            if (first <= 0xFFFFFF && first + 99 >= 0xFFFFFF) first = 0x1000000;
            if (first + 99 > int.MAX) throw new IOError.INVALID_DATA("receiver OMEMO2 pre-key ID range is exhausted");
            first_key_id = (uint32) first;
        }
        Set<PreKeyRecord> records = context.generate_pre_keys(first_key_id, 100);
        foreach (PreKeyRecord record in records) store.store_pre_key(record);
        bool published = yield ((!) module).publish_bundle_v2(stream, signed, store.identity_key_pair,
            records, (int32) store.local_registration_id);
        if (!published) throw new IOError.FAILED("receiver OMEMO2 current-device bundle publication failed");

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;
            RemotePubsubItemSnapshot snapshot = yield request_pubsub_item_snapshot_with_timeout(stream, account,
                Xmpp.Xep.Omemo.NODE_BUNDLES_V2, ((int) store.local_registration_id).to_string(), step_timeout);
            if (snapshot.status == RemotePubsubItemSnapshotStatus.PRESENT && snapshot.item != null) {
                var bundle = new Dino.Plugins.Omemo.Bundle2((!) snapshot.item);
                if (Dino.Plugins.Omemo.StreamModule2.is_valid_omemo2_bundle(bundle) &&
                        bundle.identity_key != null && bundle.identity_key.compare(store.identity_key_pair.public) == 0 &&
                        bundle.signed_pre_key_id == (int32) signed.id && bundle.signed_pre_key != null &&
                        bundle.signed_pre_key.compare(signed.key_pair.public) == 0 && bundle.pre_keys.size == records.size) {
                    bool matches_private_material = true;
                    var seen_ids = new HashSet<int>();
                    foreach (Dino.Plugins.Omemo.Bundle2.PreKey2 key in bundle.pre_keys) {
                        if (!seen_ids.add(key.key_id) || key.key == null || !store.contains_pre_key(key.key_id) ||
                                store.load_pre_key(key.key_id).key_pair.public.compare((!) key.key) != 0) {
                            matches_private_material = false;
                            break;
                        }
                    }
                    if (matches_private_material) {
                        GLib.Test.message("Receiver OMEMO2 own bundle publication and native private-material readback passed");
                        return;
                    }
                }
            }
            Timeout.add(500, () => {
                wait_for_own_omemo2_pubsub_ready.callback();
                return Source.REMOVE;
            });
            yield;
        }
        throw new IOError.TIMED_OUT("timed out confirming receiver OMEMO2 current-device bundle publication");
    }

    private async void wait_for_sender_omemo1_ready(Dino.Plugins.Omemo.Database omemo_db,
            OmemoJingleRuntime runtime,
            Account sender_account, Store sender_store, Jid receiver_jid,
            uint timeout_seconds) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            yield ensure_get_keys_for_jid_with_timeout(runtime.manager, sender_account,
                receiver_jid.bare_jid, step_timeout);

            if (has_ready_omemo1_devices(runtime, omemo_db, sender_account, sender_store,
                        receiver_jid.bare_jid)) {
                foreach (int32 device_id in runtime.trust_manager.get_trusted_devices_omemo1(sender_account, receiver_jid.bare_jid)) {
                    Address address = new Address(receiver_jid.bare_jid.to_string(), device_id);
                    try {
                        if (sender_store.contains_session(address)) {
                            throw new IOError.FAILED("OMEMO1 discovery must not build a native session before the first JET file send");
                        }
                    } finally {
                        address.device_id = 0;
                    }
                }
                return;
            }

            Timeout.add(500, () => {
                wait_for_sender_omemo1_ready.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out waiting for sender OMEMO1 trusted device identities");
    }

    private async void wait_for_sender_omemo2_ready(Dino.Plugins.Omemo.Database omemo_db,
            OmemoJingleRuntime runtime,
            Account sender_account, Store sender_store, Jid receiver_jid,
            uint timeout_seconds) throws Error {
        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        bool saw_legacy_devices = false;
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 10);
            if (step_timeout == 0) break;

            yield ensure_get_keys_for_jid_with_timeout(runtime.manager, sender_account,
                receiver_jid.bare_jid, step_timeout);

            if (runtime.trust_manager.get_trusted_devices_omemo1(sender_account,
                        receiver_jid.bare_jid).size > 0) {
                saw_legacy_devices = true;
                Timeout.add(500, () => {
                    wait_for_sender_omemo2_ready.callback();
                    return Source.REMOVE;
                });
                yield;
                continue;
            }

            Gee.List<Jid> recipients = new ArrayList<Jid>(Jid.equals_bare_func);
            recipients.add(receiver_jid.bare_jid);
            if (runtime.trust_manager.should_use_omemo2(sender_account, recipients) &&
                    has_ready_omemo2_session(runtime, omemo_db, sender_account, sender_store,
                        receiver_jid.bare_jid)) {
                return;
            }

            Timeout.add(500, () => {
                wait_for_sender_omemo2_ready.callback();
                return Source.REMOVE;
            });
            yield;
        }

        if (saw_legacy_devices) {
            throw new IOError.TIMED_OUT("timed out waiting for sender OMEMO2 trusted devices and sessions; legacy OMEMO1 devices remained visible");
        }
        throw new IOError.TIMED_OUT("timed out waiting for sender OMEMO2 trusted devices and sessions");
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

    private async void assert_external_receiver_v2_only_pubsub_visible(
            XmppStream stream, Jid receiver_jid, int32 expected_omemo2_device_id,
            uint timeout_seconds) throws Error {
        if (expected_omemo2_device_id <= 0) {
            throw new IOError.FAILED("external receiver v2-only proof requires the expected OMEMO2 device id");
        }

        int64 deadline = get_monotonic_time() + ((int64) timeout_seconds * 1000000);
        while (get_monotonic_time() < deadline) {
            uint step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;

            Gee.ArrayList<int32>? omemo1_device_list = yield request_raw_omemo1_devicelist_with_timeout(
                stream, receiver_jid.bare_jid, step_timeout);
            if (omemo1_device_list == null) {
                Timeout.add(500, () => {
                    assert_external_receiver_v2_only_pubsub_visible.callback();
                    return Source.REMOVE;
                });
                yield;
                continue;
            }

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            Gee.ArrayList<int32>? omemo2_device_list = yield request_raw_omemo2_devicelist_with_timeout(
                stream, receiver_jid.bare_jid, step_timeout);

            step_timeout = remaining_timeout_seconds(deadline, 5);
            if (step_timeout == 0) break;
            bool bundle_visible = yield omemo2_bundle_payload_visible_for_jid_with_timeout(
                stream, receiver_jid.bare_jid, expected_omemo2_device_id, step_timeout);

            if (((!) omemo1_device_list).size == 0 &&
                    omemo2_device_list != null && ((!) omemo2_device_list).size == 1 &&
                    contains_device_id((!) omemo2_device_list, expected_omemo2_device_id) &&
                    bundle_visible) {
                return;
            }

            Timeout.add(500, () => {
                assert_external_receiver_v2_only_pubsub_visible.callback();
                return Source.REMOVE;
            });
            yield;
        }

        throw new IOError.TIMED_OUT("timed out waiting for sender-visible external receiver v2-only PubSub state");
    }

    private static bool has_ready_omemo1_devices(OmemoJingleRuntime runtime,
            Dino.Plugins.Omemo.Database omemo_db, Account account, Store store, Jid jid) {
        return has_ready_omemo_session(omemo_db, account, store, jid,
            runtime.trust_manager.get_trusted_devices_omemo1(account, jid), false);
    }

    private static bool has_ready_omemo2_session(OmemoJingleRuntime runtime,
            Dino.Plugins.Omemo.Database omemo_db, Account account, Store store, Jid jid) {
        return has_ready_omemo_session(omemo_db, account, store, jid,
            runtime.trust_manager.get_trusted_devices_omemo2(account, jid));
    }

    private static bool has_ready_omemo_session(Dino.Plugins.Omemo.Database omemo_db,
            Account account, Store store, Jid jid, Gee.List<int32> trusted_devices,
            bool require_session = true) {
        int identity_id = omemo_db.identity.get_id(account.id);
        if (identity_id < 0 || trusted_devices.size == 0) return false;

        foreach (int32 device_id in trusted_devices) {
            Row? device = omemo_db.identity_meta.get_device(identity_id, jid.bare_jid.to_string(), device_id);
            if (device == null) continue;
            Row device_row = (!) device;
            string? identity_key = device_row[omemo_db.identity_meta.identity_key_public_base64];
            if (identity_key == null || ((!) identity_key).length == 0 ||
                    !device_row[omemo_db.identity_meta.now_active] ||
                    device_row[omemo_db.identity_meta.identity_key_changed]) {
                continue;
            }
            if (!require_session) return true;

            Address address = new Address(jid.bare_jid.to_string(), device_id);
            try {
                bool has_session = store.contains_session(address);
                address.device_id = 0;
                if (has_session) return true;
            } catch (Error e) {
                address.device_id = 0;
            }
        }
        return false;
    }

    private async Gee.ArrayList<int32>? request_omemo1_devicelist_with_timeout(
            Dino.Plugins.Omemo.StreamModule module, XmppStream stream, Jid jid,
            uint timeout_seconds) {
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

    private async Gee.ArrayList<int32>? request_raw_omemo1_devicelist_with_timeout(
            XmppStream stream, Jid jid, uint timeout_seconds) {
        RemotePubsubItemSnapshot snapshot = yield request_pubsub_item_snapshot_for_jid_with_timeout(
            stream, jid.bare_jid, OMEMO1_NODE_DEVICELIST, "current", timeout_seconds);
        if (snapshot.status == RemotePubsubItemSnapshotStatus.UNKNOWN) return null;
        if (snapshot.status == RemotePubsubItemSnapshotStatus.ABSENT || snapshot.item == null) {
            return new Gee.ArrayList<int32>();
        }
        return parse_omemo1_devicelist_node((!) snapshot.item);
    }

    private async Gee.ArrayList<int32>? request_raw_omemo2_devicelist_with_timeout(
            XmppStream stream, Jid jid, uint timeout_seconds) {
        RemotePubsubItemSnapshot snapshot = yield request_pubsub_item_snapshot_for_jid_with_timeout(
            stream, jid.bare_jid, Xmpp.Xep.Omemo.NODE_DEVICELIST_V2, "current", timeout_seconds);
        if (snapshot.status == RemotePubsubItemSnapshotStatus.UNKNOWN) return null;
        if (snapshot.status == RemotePubsubItemSnapshotStatus.ABSENT || snapshot.item == null) {
            return new Gee.ArrayList<int32>();
        }
        return parse_omemo2_devicelist_node((!) snapshot.item);
    }

    private static Gee.ArrayList<int32> parse_omemo1_devicelist_node(StanzaNode list_node) {
        var device_list = new Gee.ArrayList<int32>();
        if (list_node.name != "list" || list_node.ns_uri != NS_OMEMO_LEGACY) return device_list;
        foreach (StanzaNode device_node in list_node.get_subnodes("device", NS_OMEMO_LEGACY)) {
            int32 device_id = device_node.get_attribute_int("id");
            if (device_id != 0 && !contains_device_id(device_list, device_id)) {
                device_list.add(device_id);
            }
        }
        return device_list;
    }

    private static Gee.ArrayList<int32> parse_omemo2_devicelist_node(StanzaNode devices_node) {
        var device_list = new Gee.ArrayList<int32>();
        if (devices_node.name != "devices" || devices_node.ns_uri != NS_OMEMO_V2) return device_list;
        foreach (StanzaNode device_node in devices_node.get_subnodes("device", NS_OMEMO_V2)) {
            int32 device_id = device_node.get_attribute_int("id");
            if (device_id != 0 && !contains_device_id(device_list, device_id)) {
                device_list.add(device_id);
            }
        }
        return device_list;
    }

    private async bool wait_for_omemo1_bundle_with_timeout(
            Dino.Plugins.Omemo.StreamModule module, XmppStream stream, Jid jid,
            int32 device_id, uint timeout_seconds) {
        bool completed = false;
        bool success = false;
        SourceFunc resume = wait_for_omemo1_bundle_with_timeout.callback;
        uint timeout_id = 0;
        ulong fetched_id = 0;
        ulong failed_id = 0;

        fetched_id = module.bundle_fetched.connect((seen_jid, seen_device_id, bundle) => {
            if (completed || !seen_jid.equals_bare(jid) || seen_device_id != device_id) return;
            completed = true;
            success = bundle.identity_key != null &&
                bundle.signed_pre_key != null &&
                bundle.signed_pre_key_signature != null &&
                bundle.pre_keys.size > 0;
            remove_source(ref timeout_id);
            if (fetched_id != 0) {
                SignalHandler.disconnect(module, fetched_id);
                fetched_id = 0;
            }
            if (failed_id != 0) {
                SignalHandler.disconnect(module, failed_id);
                failed_id = 0;
            }
            resume();
        });
        failed_id = module.bundle_fetch_failed.connect((seen_jid, seen_device_id) => {
            if (completed || !seen_jid.equals_bare(jid) || seen_device_id != device_id) return;
            completed = true;
            success = false;
            remove_source(ref timeout_id);
            if (fetched_id != 0) {
                SignalHandler.disconnect(module, fetched_id);
                fetched_id = 0;
            }
            if (failed_id != 0) {
                SignalHandler.disconnect(module, failed_id);
                failed_id = 0;
            }
            resume();
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            timeout_id = 0;
            if (fetched_id != 0) {
                SignalHandler.disconnect(module, fetched_id);
                fetched_id = 0;
            }
            if (failed_id != 0) {
                SignalHandler.disconnect(module, failed_id);
                failed_id = 0;
            }
            resume();
            return Source.REMOVE;
        });

        module.reset_bundle_request(jid, device_id);
        module.fetch_bundle_info(stream, jid, device_id, false);
        yield;
        remove_source(ref timeout_id);
        if (fetched_id != 0) SignalHandler.disconnect(module, fetched_id);
        if (failed_id != 0) SignalHandler.disconnect(module, failed_id);
        return success;
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

    private static bool omemo2_device_lists_equal(Gee.List<int32> actual, Gee.List<int32> expected) {
        if (actual.size != expected.size) return false;
        foreach (int32 expected_device_id in expected) {
            if (!contains_device_id(actual, expected_device_id)) return false;
        }
        return true;
    }

    private static Jid get_bound_full_jid(XmppStream stream) throws IOError {
        var bind_flag = stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
        if (bind_flag == null || ((!) bind_flag).my_jid == null) {
            throw new IOError.FAILED("stream did not expose a bound full JID");
        }
        return (!) ((!) bind_flag).my_jid;
    }

    private static void inject_available_resource(XmppStream stream, Jid peer_full_jid, Jid local_full_jid) throws IOError {
        var presence_flag = stream.get_flag<Presence.Flag>(Presence.Flag.IDENTITY);
        if (presence_flag == null) {
            throw new IOError.FAILED("sender stream did not expose a presence flag");
        }
        var presence = new Presence.Stanza();
        presence.from = peer_full_jid;
        presence.to = local_full_jid;
        presence.type_ = Presence.Stanza.TYPE_AVAILABLE;
        ((!) presence_flag).add_presence(presence);
    }

    private static void replace_available_resource(XmppStream stream, Jid peer_full_jid, Jid local_full_jid) throws IOError {
        var presence_flag = stream.get_flag<Presence.Flag>(Presence.Flag.IDENTITY);
        if (presence_flag == null) {
            throw new IOError.FAILED("sender stream did not expose a presence flag");
        }
        ((!) presence_flag).remove_presence(peer_full_jid.bare_jid);
        inject_available_resource(stream, peer_full_jid, local_full_jid);
    }

    private async bool wait_for_upload_available(FileManager file_manager,
            Conversation conversation, uint timeout_seconds) {
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

    private static void publish_ready_message(StreamInteractor stream_interactor,
            Account account, Store store, RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        string bound_jid = account.full_jid.to_string();
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null && ((!) stream).has_flag(Xmpp.Bind.Flag.IDENTITY)) {
            Jid? my_jid = ((!) stream).get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid;
            if (my_jid != null) bound_jid = ((!) my_jid).to_string();
        }

        string protocol_slug = config.use_omemo2 ? "omemo2" : "omemo1";
        string message = @"remote-$protocol_slug-jingle-s5b-receive-ready\n" +
            @"account=$(account.bare_jid.to_string())\n" +
            @"bound_jid=$bound_jid\n" +
            @"device_id=$((int) store.local_registration_id)\n" +
            @"protocol=$(config.protocol_label())\n" +
            @"jet_type=$(config.expected_envelope_type_uri())\n" +
            @"expected_sender=$(config.sender_jid.bare_jid.to_string())\n" +
            @"expected_name=$(config.payload_name)\n" +
            @"expected_size=$(config.payload_text.length)\n";
        GLib.Test.message(message.strip());
        if (config.ready_file != null) {
            FileUtils.set_contents((!) config.ready_file, message);
        }
    }

    private static void publish_v2_only_guard_ready_message(RemoteOmemoJingleS5bSmokeConfig config,
            Gee.List<int32> omemo2_device_list) throws Error {
        string message = "remote-omemo2-jingle-s5b-external-receiver-v2-only-ready\n" +
            @"account=$(config.receiver_jid.bare_jid.to_string())\n" +
            @"omemo2_device_count=$(omemo2_device_list.size)\n" +
            @"protocol=$(config.protocol_label())\n" +
            @"jet_type=$(config.expected_envelope_type_uri())\n";
        GLib.Test.message(message.strip());
        if (config.ready_file != null) {
            FileUtils.set_contents((!) config.ready_file, message);
        }
    }

    private async bool wait_for_condition(uint timeout_seconds, owned WaitCondition condition) {
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
            remove_source(ref timeout_id);
            poll_id = 0;
            resume();
            return Source.REMOVE;
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

    private static void validate_incoming_observation(RemoteOmemoJingleIncomingObservation observation,
            RemoteOmemoJingleS5bSmokeConfig config, Store receiver_store) throws Error {
        if (observation.count != 1) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B expected one incoming Jingle offer, saw $(observation.count)");
        }
        if (observation.peer == null || !((!) observation.peer).equals_bare(config.sender_jid)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B observed the wrong sender");
        }
        if (observation.file_name != config.payload_name) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B observed file name '$(observation.file_name ?? "(null)")' instead of '$(config.payload_name)'");
        }
        if (observation.size != config.payload_text.length) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B observed size $(observation.size) instead of $(config.payload_text.length)");
        }
        if (observation.transport_ns_uri != JingleSocks5Bytestreams.Module.IDENTITY.ns) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B used transport '$(observation.transport_ns_uri ?? "(null)")' instead of S5B");
        }
        if (observation.security == null) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B did not parse JET security parameters");
        }
        Jet.SecurityParameters security = (!) observation.security;
        if (security.encoding.get_type_uri() != config.expected_envelope_type_uri()) {
            throw new IOError.FAILED(@"remote $(config.protocol_label())/JET Jingle S5B used JET encoding $(security.encoding.get_type_uri()) instead of $(config.expected_envelope_type_uri())");
        }
        if (security.cipher.get_cipher_uri() != AES_128_GCM_URI) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B used cipher $(security.cipher.get_cipher_uri()) instead of AES-128-GCM");
        }
        if (security.secret.transport_key.length != 16) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B receiver did not recover a 128-bit transport key");
        }
        if (security.secret.initialization_vector.length != 12) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B receiver did not recover a 96-bit IV");
        }
        if (receiver_store.local_registration_id == 0) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B receiver store has no device id");
        }
    }

    private static void observe_received_transfer_publication(FileTransfer file_transfer,
            RemoteOmemoJingleReceiveObservation observation) {
        observation.phases.add(file_transfer.phase);
        if (observation.publication_error != null) return;

        bool saw_verifying = observation.phases.contains(FileTransfer.Phase.VERIFYING);
        if (file_transfer.path != null && ((!) file_transfer.path) != "" && !saw_verifying) {
            observation.publication_error = new IOError.FAILED(
                "remote OMEMO1/JET Jingle S5B received transfer published a storage path before VERIFYING");
        } else if (file_transfer.is_plaintext_release_allowed() &&
                (file_transfer.phase != FileTransfer.Phase.COMPLETE || !saw_verifying)) {
            observation.publication_error = new IOError.FAILED(
                "remote OMEMO1/JET Jingle S5B received transfer allowed plaintext release before verified completion");
        }
    }

    private static void validate_receive_publication_observation(
            RemoteOmemoJingleReceiveObservation observation) throws Error {
        if (observation.publication_error != null) {
            throw (!) observation.publication_error;
        }
        assert_phase_order(observation.phases, FileTransfer.Phase.VERIFYING, FileTransfer.Phase.PREVIEWING,
            "remote OMEMO1/JET Jingle S5B receive must verify before plaintext publication");
        assert_phase_order(observation.phases, FileTransfer.Phase.PREVIEWING, FileTransfer.Phase.COMPLETE,
            "remote OMEMO1/JET Jingle S5B receive must preview only before completion");
    }

    private static void validate_sent_transfer(Dino.Database db, FileTransfer file_transfer, Conversation conversation,
            RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must be persisted");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer direction must be SENT");
        }
        if (!file_transfer.counterpart.equals_bare(config.receiver_jid)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer kept the wrong counterpart");
        }
        if (file_transfer.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must stay marked OMEMO");
        }
        if (file_transfer.provider != JINGLE_PROVIDER_ID) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must keep the Jingle provider id");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B sent transfer kept phase error '$(file_transfer.phase_error)'");
        }
        if (file_transfer.path == null || ((!) file_transfer.path) == "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must publish a local saved path");
        }
        if (conversation.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sender conversation must be OMEMO");
        }

        RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", file_transfer.id)
            .single()
            .row();
        if (!row.is_present()) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must have a database row");
        }
        FileTransfer.State persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        string? persisted_path = ((!) row.inner)[db.file_transfer.path];
        int64 persisted_size = ((!) row.inner)[db.file_transfer.size];
        int persisted_provider = ((!) row.inner)[db.file_transfer.provider];
        bool persisted_direction = ((!) row.inner)[db.file_transfer.direction];
        Encryption persisted_encryption = (Encryption) ((!) row.inner)[db.file_transfer.encryption];
        string? persisted_file_sharing_id = ((!) row.inner)[db.file_transfer.file_sharing_id];
        if (persisted_state != FileTransfer.State.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist COMPLETE state");
        }
        if (persisted_provider != JINGLE_PROVIDER_ID) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist Jingle provider");
        }
        if (persisted_direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist SENT direction");
        }
        if (persisted_path == null || ((!) persisted_path) == "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist the local saved path");
        }
        if (((!) persisted_path) != ((!) file_transfer.path)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer persisted path must match the runtime path");
        }
        if (persisted_size != config.payload_text.length) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist the plaintext size");
        }
        if (persisted_encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must persist OMEMO encryption");
        }
        if (persisted_file_sharing_id != null && ((!) persisted_file_sharing_id) != "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B sent transfer must not persist an SFS file-sharing id");
        }
    }

    private static void validate_received_transfer(Dino.Database db, FileTransfer file_transfer,
            Conversation published_conversation, Conversation expected_conversation,
            RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        if (published_conversation.id != expected_conversation.id) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B receiver published the wrong conversation");
        }
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must be persisted");
        }
        if (file_transfer.provider != JINGLE_PROVIDER_ID) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must keep the Jingle provider id");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer direction must be RECEIVED");
        }
        if (!file_transfer.counterpart.equals_bare(config.sender_jid)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer kept the wrong counterpart");
        }
        if (file_transfer.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must classify as OMEMO");
        }
        if (file_transfer.size != config.payload_text.length) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B received size $(file_transfer.size) instead of $(config.payload_text.length)");
        }
        if (file_transfer.file_name != config.payload_name) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B received file name '$(file_transfer.file_name)' instead of '$(config.payload_name)'");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B received transfer kept phase error '$(file_transfer.phase_error)'");
        }
        if (file_transfer.path == null || ((!) file_transfer.path) == "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must allow plaintext release only after completion");
        }

        RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", file_transfer.id)
            .single()
            .row();
        if (!row.is_present()) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must have a database row");
        }
        FileTransfer.State persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        string? persisted_path = ((!) row.inner)[db.file_transfer.path];
        int64 persisted_size = ((!) row.inner)[db.file_transfer.size];
        int persisted_provider = ((!) row.inner)[db.file_transfer.provider];
        bool persisted_direction = ((!) row.inner)[db.file_transfer.direction];
        Encryption persisted_encryption = (Encryption) ((!) row.inner)[db.file_transfer.encryption];
        string? persisted_file_name = ((!) row.inner)[db.file_transfer.file_name];
        string? persisted_file_sharing_id = ((!) row.inner)[db.file_transfer.file_sharing_id];
        int persisted_account_id = ((!) row.inner)[db.file_transfer.account_id];
        int persisted_counterpart_id = ((!) row.inner)[db.file_transfer.counterpart_id];
        if (persisted_state != FileTransfer.State.COMPLETE) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist COMPLETE state");
        }
        if (persisted_provider != JINGLE_PROVIDER_ID) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist Jingle provider");
        }
        if (persisted_direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist RECEIVED direction");
        }
        if (persisted_encryption != Encryption.OMEMO) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist OMEMO encryption");
        }
        if (persisted_file_name != config.payload_name) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist the expected file name");
        }
        if (persisted_file_sharing_id != null && ((!) persisted_file_sharing_id) != "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must not persist an SFS file-sharing id");
        }
        if (persisted_account_id != expected_conversation.account.id) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist the receiver account id");
        }
        if (persisted_counterpart_id != db.get_jid_id(config.sender_jid.bare_jid)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist the sender counterpart id");
        }
        if (persisted_path == null || ((!) persisted_path) == "") {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist the storage path");
        }
        if (((!) persisted_path) != ((!) file_transfer.path)) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer persisted path must match the runtime path");
        }
        if (persisted_size != config.payload_text.length) {
            throw new IOError.FAILED("remote OMEMO1/JET Jingle S5B received transfer must persist the plaintext size");
        }
    }

    private async void validate_stored_payload(FileEncryption file_encryption, FileTransfer file_transfer,
            uint8[] expected_payload, string label) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B $label must resolve to a stored file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();
        if (!bytes_equal(expected_payload, decrypted)) {
            string expected_hash = Checksum.compute_for_data(ChecksumType.SHA256, expected_payload);
            string actual_hash = Checksum.compute_for_data(ChecksumType.SHA256, decrypted);
            throw new IOError.FAILED(@"remote OMEMO1/JET Jingle S5B $label SHA-256 $actual_hash did not match $expected_hash");
        }
    }

    private static void assert_phase_order(Gee.List<FileTransfer.Phase> phases,
            FileTransfer.Phase earlier, FileTransfer.Phase later, string reason) throws Error {
        int earlier_index = -1;
        int later_index = -1;
        for (int i = 0; i < phases.size; i++) {
            if (phases[i] == earlier && earlier_index < 0) earlier_index = i;
            if (phases[i] == later && later_index < 0) later_index = i;
        }
        if (earlier_index < 0 || later_index < 0 || earlier_index >= later_index) {
            throw new IOError.FAILED(reason);
        }
    }

    private static bool has_jingle_session_state(XmppStream stream, string sid) {
        var jingle_flag = stream.get_flag<Jingle.Flag>(Jingle.Flag.IDENTITY);
        return jingle_flag != null && (((!) jingle_flag).promises.has_key(sid) ||
            ((!) jingle_flag).sessions.has_key(sid));
    }

    private static void terminate_jingle_session_if_present(XmppStream? stream, string? sid) {
        if (stream == null || sid == null) return;
        var jingle_flag = ((!) stream).get_flag<Jingle.Flag>(Jingle.Flag.IDENTITY);
        if (jingle_flag == null || !((!) jingle_flag).sessions.has_key((!) sid)) return;
        ((!) jingle_flag).sessions[(!) sid].terminate(Jingle.ReasonElement.CANCEL, null, "remote smoke cleanup");
    }

    private static void cancel_observed_transfer(FileTransfer? file_transfer) {
        if (file_transfer == null || ((!) file_transfer).cancellable.is_cancelled()) return;
        ((!) file_transfer).cancellable.cancel();
    }

    private static bool transfer_is_quiescent(FileTransfer? file_transfer) {
        if (file_transfer == null) return true;
        return ((!) file_transfer).state != FileTransfer.State.IN_PROGRESS;
    }

    private static void prepare_pre_key_session(Context context, Store sender_store, Jid peer_jid,
            Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
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

    private static void prepare_pre_key_session_v2(Context context, Store sender_store, Jid peer_jid,
            Store peer_store, uint32 pre_key_id, int signed_pre_key_id) throws Error {
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

    private static void add_trusted_omemo1_device(Dino.Plugins.Omemo.Database db, int identity_id,
            Jid jid, Store device_store) {
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

    private static void add_trusted_omemo2_device(Dino.Plugins.Omemo.Database db, int identity_id,
            Jid jid, Store device_store) {
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

    private static int count_receive_pending_files_for_basename(string directory_path, string basename) throws Error {
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

    private static void delete_receive_pending_files_for_basename(string directory_path, string basename) {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return;

        FileEnumerator? enumerator = null;
        try {
            enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = ((!) enumerator).next_file()) != null) {
                string name = ((!) child_info).get_name();
                if ((name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) ||
                        name.has_prefix(".download-encrypted-")) {
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

    private static bool bytes_equal(uint8[] a, uint8[] b) {
        if (a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    private static void drain_pending_events() {
        MainContext context = MainContext.default();
        int iterations = 0;
        while (context.pending() && iterations < 100) {
            context.iteration(false);
            iterations++;
        }
    }

    private static void remove_source(ref uint source_id) {
        if (source_id == 0) return;
        Source.remove(source_id);
        source_id = 0;
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

    private static void apply_sender_proxy_config(Account account, RemoteOmemoJingleS5bSmokeConfig config) {
        account.proxy_type = config.sender_proxy_type;
        if (config.sender_proxy_type == "none") {
            account.proxy_host = null;
            account.proxy_port = 0;
            account.proxy_user = null;
            account.proxy_pass = null;
            return;
        }
        account.proxy_host = config.sender_proxy_host;
        account.proxy_port = config.sender_proxy_port;
        account.proxy_user = null;
        account.proxy_pass = null;
    }

    private static void apply_jingle_s5b_account_network_policy(Account account, XmppStream stream,
            string label, RemoteOmemoJingleS5bSmokeConfig? config = null) throws Error {
        JingleSocks5Bytestreams.Module? module = stream.get_module<JingleSocks5Bytestreams.Module>(
            JingleSocks5Bytestreams.Module.IDENTITY);
        if (module == null) {
            throw new IOError.FAILED(@"remote OMEMO Jingle S5B $label stream has no S5B transport module");
        }
        if (config != null && ((!) config).has_sender_direct_candidate_override()) {
            ((!) module).set_direct_candidate_override_for_tests(
                (!) ((!) config).sender_direct_candidate_bind_host,
                (!) ((!) config).sender_direct_candidate_public_host,
                ((!) config).sender_direct_candidate_port);
        }
        string? proxy_uri = Dino.build_socks5_proxy_uri(account);
        if ((account.proxy_type == "socks5" || account.proxy_type == "tor") && proxy_uri == null) {
            throw new IOError.FAILED(@"remote OMEMO Jingle S5B $label account proxy configuration did not produce a SOCKS URI");
        }
        ((!) module).set_network_policy(proxy_uri == null, proxy_uri);
    }

    private static void observe_sender_s5b_transport_iq(RemoteOmemoJingleS5bTransportObservation observation,
            RemoteOmemoJingleS5bSmokeConfig config, Iq.Stanza iq_stanza, bool outgoing) {
        StanzaNode? jingle = iq_stanza.stanza.get_subnode("jingle", Jingle.NS_URI);
        if (jingle == null) return;
        string? action = ((!) jingle).get_attribute("action");
        if (outgoing && action == "session-initiate") {
            observe_s5b_transport_candidates(observation, config, (!) jingle, true);
        } else if (!outgoing && action == "session-accept") {
            observe_s5b_transport_candidates(observation, config, (!) jingle, false);
        } else if (!outgoing && action == "transport-info") {
            observe_receiver_candidate_used(observation, (!) jingle);
        }
    }

    private static void observe_s5b_transport_candidates(RemoteOmemoJingleS5bTransportObservation observation,
            RemoteOmemoJingleS5bSmokeConfig config, StanzaNode jingle, bool sender_session_initiate) {
        foreach (StanzaNode content in jingle.get_subnodes("content", Jingle.NS_URI)) {
            StanzaNode? transport = content.get_subnode("transport", JingleSocks5Bytestreams.Module.IDENTITY.ns);
            if (transport == null) continue;
            if (sender_session_initiate) {
                observation.saw_sender_s5b_session_initiate = true;
            } else {
                observation.saw_receiver_s5b_session_accept = true;
            }
            foreach (StanzaNode candidate in ((!) transport).get_subnodes("candidate", JingleSocks5Bytestreams.Module.IDENTITY.ns)) {
                string type_ = candidate.get_attribute("type") ?? "direct";
                string? cid = candidate.get_attribute("cid");
                if (sender_session_initiate) {
                    observation.sender_candidate_count++;
                    if (type_ == "direct") observation.sender_direct_candidate_count++;
                    if (cid != null) observation.sender_candidate_cids.add((!) cid);
                    if (candidate_matches_expected_sender_s5b_candidate(candidate, config)) {
                        observation.saw_expected_sender_candidate = true;
                        if (cid != null) observation.expected_sender_candidate_cids.add((!) cid);
                    }
                } else {
                    observation.receiver_candidate_count++;
                    if (type_ == "direct") observation.receiver_direct_candidate_count++;
                }
            }
        }
    }

    private static bool candidate_matches_expected_sender_s5b_candidate(StanzaNode candidate,
            RemoteOmemoJingleS5bSmokeConfig config) {
        if (!config.has_expected_sender_s5b_candidate()) return false;
        string type_ = candidate.get_attribute("type") ?? "direct";
        if (config.expected_sender_s5b_candidate_type != null &&
                type_ != (!) config.expected_sender_s5b_candidate_type) {
            return false;
        }
        string? expected_host = config.expected_sender_s5b_candidate_host;
        if (expected_host != null && candidate.get_attribute("host") != (!) expected_host) {
            return false;
        }
        string? expected_jid = config.expected_sender_s5b_candidate_jid;
        if (expected_jid != null) {
            string? candidate_jid = candidate.get_attribute("jid");
            if (candidate_jid == null) return false;
            try {
                Jid expected = new Jid((!) expected_jid);
                Jid actual = new Jid((!) candidate_jid);
                if (!actual.equals_bare(expected)) return false;
            } catch (InvalidJidError ignored) {
                if ((!) candidate_jid != (!) expected_jid) return false;
            }
        }
        if (config.expected_sender_s5b_candidate_port > 0 &&
                candidate.get_attribute_int("port") != config.expected_sender_s5b_candidate_port) {
            return false;
        }
        return true;
    }

    private static void observe_receiver_candidate_used(RemoteOmemoJingleS5bTransportObservation observation,
            StanzaNode jingle) {
        foreach (StanzaNode content in jingle.get_subnodes("content", Jingle.NS_URI)) {
            StanzaNode? transport = content.get_subnode("transport", JingleSocks5Bytestreams.Module.IDENTITY.ns);
            if (transport == null) continue;
            StanzaNode? candidate_used = ((!) transport).get_subnode("candidate-used", JingleSocks5Bytestreams.Module.IDENTITY.ns);
            if (candidate_used == null) continue;
            string? cid = ((!) candidate_used).get_attribute("cid");
            if (cid == null) continue;
            observation.receiver_selected_sender_candidate_cid = (!) cid;
            if (observation.expected_sender_candidate_cids.contains((!) cid)) {
                observation.receiver_selected_expected_sender_candidate = true;
            }
        }
    }

    private static void validate_sender_s5b_transport_observation(
            RemoteOmemoJingleS5bTransportObservation observation,
            RemoteOmemoJingleS5bSmokeConfig config) throws Error {
        if (!config.has_sender_s5b_transport_expectations()) return;
        if (!observation.saw_sender_s5b_session_initiate) {
            throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only did not observe an outgoing S5B session-initiate");
        }
        if (config.expect_sender_no_direct_candidates && observation.sender_direct_candidate_count != 0) {
            throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only published $(observation.sender_direct_candidate_count) direct S5B sender candidates");
        }
        if (config.has_expected_sender_s5b_candidate() && !observation.saw_expected_sender_candidate) {
            throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only did not publish the expected S5B sender candidate");
        }
        if (config.expect_receiver_no_direct_candidates) {
            if (!observation.saw_receiver_s5b_session_accept) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only did not observe an incoming S5B session-accept");
            }
            if (observation.receiver_direct_candidate_count != 0) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only observed $(observation.receiver_direct_candidate_count) direct S5B receiver candidates");
            }
        }
        bool require_selected_sender_candidate =
            config.expect_receiver_selected_sender_candidate ||
            config.has_expected_sender_s5b_candidate();
        if (require_selected_sender_candidate) {
            if (observation.receiver_selected_sender_candidate_cid == null) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only did not observe receiver candidate-used for a sender candidate");
            }
            string selected_cid = (!) observation.receiver_selected_sender_candidate_cid;
            if (!observation.sender_candidate_cids.contains(selected_cid)) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only receiver selected a candidate cid that was not published by the sender");
            }
            if (config.has_expected_sender_s5b_candidate() &&
                    !observation.expected_sender_candidate_cids.contains(selected_cid)) {
                throw new IOError.FAILED(@"remote $(config.protocol_label())/JET sender-only receiver selected an unexpected sender candidate");
            }
        }
    }

    private static string format_transfer_state(FileTransfer? transfer) {
        if (transfer == null) return "null";
        FileTransfer concrete = (!) transfer;
        return @"id=$(concrete.id) state=$((int) concrete.state) phase=$((int) concrete.phase) error=$(concrete.phase_error ?? "none")";
    }

    private static string format_incoming_observation(RemoteOmemoJingleIncomingObservation observation) {
        return @"count=$(observation.count) peer=$(observation.peer != null ? ((!) observation.peer).to_string() : "null") file=$(observation.file_name ?? "null") size=$(observation.size) transport=$(observation.transport_ns_uri ?? "null") security=$(observation.security != null ? "jet" : "null") sid=$(observation.session_sid ?? "null") reason=$(observation.session_terminate_reason ?? "null")";
    }

    private static string? empty_to_null(string? value) {
        if (value == null) return null;
        string stripped = ((!) value).strip();
        return stripped == "" ? null : stripped;
    }

    private static void restore_default_application(TestApplication? application, GLib.Application? previous_application) {
        if (application == null) return;
        if (GLib.Application.get_default() == (!) application) {
            GLib.Application.set_default(previous_application);
        }
    }

    private static void delete_file_tree(File file) throws Error {
        Error? last_error = null;
        for (int attempt = 0; attempt < 10; attempt++) {
            try {
                delete_file_tree_once(file);
                return;
            } catch (Error e) {
                last_error = e;
                Thread.usleep(100000);
            }
        }
        if (last_error != null) throw (!) last_error;
    }

    private static void delete_file_tree_once(File file) throws Error {
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

    private class RemoteOmemoJingleIncomingObservation : Object {
        public int count = 0;
        public Jid? peer = null;
        public string? file_name = null;
        public int64 size = -1;
        public string? transport_ns_uri = null;
        public Jet.SecurityParameters? security = null;
        public string? session_sid = null;
        public string? session_terminate_reason = null;
    }

    private class RemoteOmemoJingleReceiveObservation : Object {
        public ArrayList<FileTransfer.Phase> phases = new ArrayList<FileTransfer.Phase>();
        public Error? publication_error = null;
    }

    private class RemoteOmemoJingleS5bTransportObservation : Object {
        public bool saw_sender_s5b_session_initiate = false;
        public bool saw_receiver_s5b_session_accept = false;
        public int sender_candidate_count = 0;
        public int sender_direct_candidate_count = 0;
        public int receiver_candidate_count = 0;
        public int receiver_direct_candidate_count = 0;
        public bool saw_expected_sender_candidate = false;
        public HashSet<string> sender_candidate_cids = new HashSet<string>();
        public HashSet<string> expected_sender_candidate_cids = new HashSet<string>();
        public string? receiver_selected_sender_candidate_cid = null;
        public bool receiver_selected_expected_sender_candidate = false;
    }

    private class OmemoJingleRuntime : Object {
        public Dino.Plugins.Omemo.TrustManager trust_manager;
        public HashMap<Account, Dino.Plugins.Omemo.OmemoDecryptor> decryptors;
        public HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor> encryptors;
        public HashMap<Account, Dino.Plugins.Omemo.Omemo2Decrypt> decryptors_v2;
        public HashMap<Account, Dino.Plugins.Omemo.Omemo2Encrypt> encryptors_v2;
        public Dino.Plugins.Omemo.Manager manager;
        public Dino.JingleFileEncryptionHelper? previous_jingle_helper = null;
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Dino.Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Dino.Database db, StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.remote-omemo-jingle-s5b-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-omemo-jingle-s5b-smoke-test";
            this.file_encryption = new FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }

    private class RemoteOmemoJingleS5bSmokeConfig : Object {
        public Jid sender_jid;
        public string sender_password;
        public Jid receiver_jid;
        public string receiver_password;
        public Jid? receiver_full_jid = null;
        public string? custom_host = null;
        public int custom_port = 0;
        public string payload_name = "dinox-remote-omemo1-jingle-s5b.txt";
        public string payload_text = "DinoX remote OMEMO1 JET Jingle S5B file smoke payload\n";
        public string? ready_file = null;
        public string? done_file = null;
        public string? receive_release_file = null;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;
        public bool use_omemo2 = false;
        public bool sender_expects_v2_only_receiver = false;
        public int32 receiver_omemo2_device_id = 0;
        public string sender_proxy_type = "none";
        public string? sender_proxy_host = null;
        public int sender_proxy_port = 0;
        public string? sender_direct_candidate_bind_host = null;
        public string? sender_direct_candidate_public_host = null;
        public int sender_direct_candidate_port = 0;
        public bool expect_sender_no_direct_candidates = false;
        public string? expected_sender_s5b_candidate_type = null;
        public string? expected_sender_s5b_candidate_host = null;
        public int expected_sender_s5b_candidate_port = 0;
        public string? expected_sender_s5b_candidate_jid = null;
        public bool expect_receiver_no_direct_candidates = false;
        public bool expect_receiver_selected_sender_candidate = false;

        public static RemoteOmemoJingleS5bSmokeConfig? from_env(bool receive_only = false,
                bool use_omemo2 = false, bool sender_only = false, bool v2_only_guard = false) {
            string smoke_env = v2_only_guard
                ? "DINOX_REMOTE_OMEMO_JINGLE_S5B_V2_ONLY_GUARD_SMOKE"
                : sender_only
                ? "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_ONLY_SMOKE"
                : receive_only
                ? "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_ONLY_SMOKE"
                : "DINOX_REMOTE_OMEMO_JINGLE_S5B_SMOKE";
            if (Environment.get_variable(smoke_env) != "1") {
                GLib.Test.skip(@"Set $smoke_env=1 with sender and receiver env to run the remote $(use_omemo2 ? "OMEMO2" : "OMEMO1")/JET Jingle S5B smoke");
                return null;
            }
            if (v2_only_guard &&
                    Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION") != "1") {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION=1 is required for the external receiver v2-only guard");
                return null;
            }

            string? sender_env = v2_only_guard
                ? "v2-only-guard@example.invalid"
                : require_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID");
            string? sender_password_env = (receive_only || v2_only_guard) ? "" : require_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD");
            string? receiver_env = require_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID");
            string? receiver_password_env = (sender_only && !v2_only_guard) ? "" : require_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD");
            if (sender_env == null || sender_password_env == null ||
                    receiver_env == null || receiver_password_env == null) {
                return null;
            }

            RemoteOmemoJingleS5bSmokeConfig config = new RemoteOmemoJingleS5bSmokeConfig();
            config.use_omemo2 = use_omemo2;
            if (use_omemo2) {
                config.payload_name = "dinox-remote-omemo2-jingle-s5b.txt";
                config.payload_text = "DinoX remote OMEMO2 JET Jingle S5B file smoke payload\n";
            }
            try {
                config.sender_jid = new Jid((!) sender_env);
                config.receiver_jid = new Jid((!) receiver_env);
                if (config.sender_jid.resourcepart != null || config.receiver_jid.resourcepart != null) {
                    fail_if(true, "remote OMEMO Jingle S5B smoke requires bare sender and receiver account JIDs");
                    return null;
                }
                if (config.sender_jid.bare_jid.equals(config.receiver_jid.bare_jid)) {
                    fail_if(true, "remote OMEMO Jingle S5B smoke requires distinct sender and receiver accounts");
                    return null;
                }
                config.sender_password = (!) sender_password_env;
                config.receiver_password = (!) receiver_password_env;
                string? receiver_full_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID"));
                if (sender_only) {
                    if (receiver_full_env == null) {
                        fail_if(true, "remote OMEMO Jingle S5B sender-only smoke requires DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID");
                        return null;
                    }
                    config.receiver_full_jid = new Jid((!) receiver_full_env);
                    if (!((!) config.receiver_full_jid).equals_bare(config.receiver_jid) ||
                            ((!) config.receiver_full_jid).resourcepart == null) {
                        fail_if(true, "remote OMEMO Jingle S5B sender-only receiver full JID must match the receiver bare JID and include a resource");
                        return null;
                    }
                }
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote OMEMO Jingle S5B smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST"));
            config.payload_name = FileTransfer.sanitize_file_name(
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME")) ?? config.payload_name);
            config.payload_text = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT")) ?? config.payload_text;
            config.ready_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE"));
            config.done_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE"));
            config.receive_release_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_RELEASE_FILE"));
            string? sender_v2_only_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER"));
            if (sender_v2_only_env != null) {
                if ((!) sender_v2_only_env != "0" && (!) sender_v2_only_env != "1") {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER must be 0 or 1");
                    return null;
                }
                config.sender_expects_v2_only_receiver = (!) sender_v2_only_env == "1";
                if (config.sender_expects_v2_only_receiver && (!sender_only || !use_omemo2)) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER=1 requires the OMEMO2 sender-only smoke");
                    return null;
                }
            }
            string? receiver_omemo2_device_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID"));
            if (receiver_omemo2_device_env != null) {
                int parsed_device_id = 0;
                if (!int.try_parse((!) receiver_omemo2_device_env, out parsed_device_id, null, 10) || parsed_device_id <= 0) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID must be a positive integer");
                    return null;
                }
                config.receiver_omemo2_device_id = (int32) parsed_device_id;
            }
            if (v2_only_guard && config.receiver_omemo2_device_id <= 0) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID is required for the external receiver v2-only guard");
                return null;
            }
            if (v2_only_guard && (config.ready_file == null || config.done_file == null)) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE and DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE are required for the external receiver v2-only guard");
                return null;
            }
            if (v2_only_guard && (!) config.ready_file == (!) config.done_file) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE and DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE must be different paths");
                return null;
            }
            if (config.sender_expects_v2_only_receiver && config.receiver_omemo2_device_id <= 0) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID is required when the sender expects a v2-only receiver");
                return null;
            }

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            if (!parse_sender_proxy_config(config, sender_only)) return null;
            if (!parse_sender_direct_candidate_override(config, sender_only)) return null;
            if (!parse_sender_s5b_transport_expectations(config, sender_only)) return null;
            if (config.has_sender_direct_candidate_override() && config.expect_sender_no_direct_candidates) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES=1 conflicts with the sender direct candidate override");
                return null;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 900) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 900");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            return config;
        }

        public string expected_envelope_type_uri() {
            return use_omemo2 ? NS_OMEMO_V2 : NS_OMEMO_LEGACY;
        }

        public string protocol_label() {
            return use_omemo2 ? "OMEMO2" : "OMEMO1";
        }

        public bool has_expected_sender_s5b_candidate() {
            return expected_sender_s5b_candidate_type != null ||
                expected_sender_s5b_candidate_host != null ||
                expected_sender_s5b_candidate_port > 0 ||
                expected_sender_s5b_candidate_jid != null;
        }

        public bool has_complete_expected_sender_s5b_candidate() {
            return expected_sender_s5b_candidate_type != null &&
                expected_sender_s5b_candidate_host != null &&
                expected_sender_s5b_candidate_port > 0 &&
                expected_sender_s5b_candidate_jid != null;
        }

        public bool has_sender_direct_candidate_override() {
            return sender_direct_candidate_bind_host != null ||
                sender_direct_candidate_public_host != null ||
                sender_direct_candidate_port > 0;
        }

        public bool has_complete_sender_direct_candidate_override() {
            return sender_direct_candidate_bind_host != null &&
                sender_direct_candidate_public_host != null &&
                sender_direct_candidate_port > 0;
        }

        public bool has_sender_s5b_transport_expectations() {
            return expect_sender_no_direct_candidates ||
                has_expected_sender_s5b_candidate() ||
                expect_receiver_no_direct_candidates ||
                expect_receiver_selected_sender_candidate;
        }

        private static bool parse_sender_proxy_config(RemoteOmemoJingleS5bSmokeConfig config,
                bool sender_only) {
            string? proxy_type_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE"));
            string? proxy_host_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST"));
            string? proxy_port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT"));
            if (proxy_type_env == null && proxy_host_env == null && proxy_port_env == null) return true;
            if (!sender_only) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_* currently requires the sender-only smoke");
                return false;
            }
            string proxy_type = proxy_type_env ?? "none";
            if (proxy_type != "none" && proxy_type != "socks5" && proxy_type != "tor") {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE must be none, socks5 or tor");
                return false;
            }
            config.sender_proxy_type = proxy_type;
            if (proxy_type == "none") {
                if (proxy_host_env != null || proxy_port_env != null) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST/PORT require a non-none sender proxy type");
                    return false;
                }
                return true;
            }
            if (proxy_type == "socks5" && proxy_host_env == null) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST is required for sender socks5 proxy");
                return false;
            }
            int parsed_proxy_port = 0;
            if (proxy_port_env != null) {
                if (!int.try_parse((!) proxy_port_env, out parsed_proxy_port, null, 10) ||
                        parsed_proxy_port < 1 || parsed_proxy_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT must be an integer between 1 and 65535");
                    return false;
                }
            }
            if (proxy_type == "socks5" && parsed_proxy_port == 0) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT is required for sender socks5 proxy");
                return false;
            }
            config.sender_proxy_host = proxy_host_env;
            config.sender_proxy_port = parsed_proxy_port;
            return true;
        }

        private static bool parse_sender_direct_candidate_override(RemoteOmemoJingleS5bSmokeConfig config,
                bool sender_only) {
            config.sender_direct_candidate_bind_host =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST"));
            config.sender_direct_candidate_public_host =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST"));
            string? direct_port_env =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT"));
            if (direct_port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) direct_port_env, out parsed_port, null, 10) ||
                        parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT must be an integer between 1 and 65535");
                    return false;
                }
                config.sender_direct_candidate_port = parsed_port;
            }
            if (!config.has_sender_direct_candidate_override()) return true;
            if (!sender_only) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* currently requires the sender-only smoke");
                return false;
            }
            if (!config.has_complete_sender_direct_candidate_override()) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* requires BIND_HOST, PUBLIC_HOST and PORT together");
                return false;
            }
            if (config.sender_proxy_type != "none") {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* requires sender proxy type none");
                return false;
            }
            return true;
        }

        private static bool parse_sender_s5b_transport_expectations(RemoteOmemoJingleS5bSmokeConfig config,
                bool sender_only) {
            if (!parse_bool_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES",
                    out config.expect_sender_no_direct_candidates)) return false;
            if (!parse_bool_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES",
                    out config.expect_receiver_no_direct_candidates)) return false;
            if (!parse_bool_env("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE",
                    out config.expect_receiver_selected_sender_candidate)) return false;
            config.expected_sender_s5b_candidate_type =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE"));
            config.expected_sender_s5b_candidate_host =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST"));
            config.expected_sender_s5b_candidate_jid =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID"));
            string? expected_port_env =
                empty_to_null(Environment.get_variable("DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT"));
            if (expected_port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) expected_port_env, out parsed_port, null, 10) ||
                        parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT must be an integer between 1 and 65535");
                    return false;
                }
                config.expected_sender_s5b_candidate_port = parsed_port;
            }
            if (config.expected_sender_s5b_candidate_type != null &&
                    (!) config.expected_sender_s5b_candidate_type != "direct" &&
                    (!) config.expected_sender_s5b_candidate_type != "proxy" &&
                    (!) config.expected_sender_s5b_candidate_type != "assisted" &&
                    (!) config.expected_sender_s5b_candidate_type != "tunnel") {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE must be direct, proxy, assisted or tunnel");
                return false;
            }
            if (config.has_expected_sender_s5b_candidate() &&
                    !config.has_complete_expected_sender_s5b_candidate()) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_* requires TYPE, HOST, PORT and JID together");
                return false;
            }
            if (config.has_sender_s5b_transport_expectations() && !sender_only) {
                fail_if(true, "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_* transport checks currently require the sender-only smoke");
                return false;
            }
            return true;
        }

        private static bool parse_bool_env(string name, out bool result) {
            result = false;
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) return true;
            if ((!) value == "0") return true;
            if ((!) value == "1") {
                result = true;
                return true;
            }
            fail_if(true, @"$name must be 0 or 1");
            return false;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when the remote OMEMO/JET Jingle S5B smoke is enabled");
                return null;
            }
            return value;
        }
    }
}

}
