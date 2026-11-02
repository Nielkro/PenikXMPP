using Gee;
using Qlite;
using Xmpp;
using Dino.Entities;
using Dino.Security;

namespace Dino.Test {

class RemoteJingleS5bSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 120;
    private const int64 AUTO_DOWNLOAD_MAX_BYTES = 5000000;
    private const int JINGLE_PROVIDER_ID = 1;

    private delegate bool WaitCondition();

    public RemoteJingleS5bSmokeTest() {
        base("RemoteJingleS5bSmoke");
        add_test("incoming_foreign_client_s5b_env", test_incoming_foreign_client_s5b_env_sync);
        add_test("incoming_dinox_pair_s5b_env", test_incoming_dinox_pair_s5b_env_sync);
        add_test("incoming_raw_sender_s5b_env", test_incoming_raw_sender_s5b_env_sync);
        add_test("incoming_proxy_no_direct_s5b_env", test_incoming_proxy_no_direct_s5b_env_sync);
    }

    private void test_incoming_foreign_client_s5b_env_sync() {
        RemoteJingleS5bSmokeConfig? config = RemoteJingleS5bSmokeConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_incoming_foreign_client_s5b.begin((!) config, null, false, (obj, res) => {
            try {
                run_incoming_foreign_client_s5b.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote Jingle S5B smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_incoming_dinox_pair_s5b_env_sync() {
        RemoteJingleS5bPairSmokeConfig? pair_config = RemoteJingleS5bPairSmokeConfig.from_env();
        if (pair_config == null) return;

        MainLoop loop = new MainLoop();
        run_incoming_foreign_client_s5b.begin((!) pair_config.to_receiver_config(), pair_config, false, (obj, res) => {
            try {
                run_incoming_foreign_client_s5b.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote DinoX-pair Jingle S5B smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_incoming_raw_sender_s5b_env_sync() {
        RemoteJingleS5bPairSmokeConfig? raw_config = RemoteJingleS5bPairSmokeConfig.from_raw_env();
        if (raw_config == null) return;

        MainLoop loop = new MainLoop();
        run_incoming_foreign_client_s5b.begin((!) raw_config.to_receiver_config(), raw_config, true, (obj, res) => {
            try {
                run_incoming_foreign_client_s5b.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote scripted-raw Jingle S5B smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_incoming_proxy_no_direct_s5b_env_sync() {
        RemoteJingleS5bSmokeConfig? config = RemoteJingleS5bSmokeConfig.from_proxy_no_direct_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_incoming_foreign_client_s5b.begin((!) config, null, false, (obj, res) => {
            try {
                run_incoming_foreign_client_s5b.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote Jingle S5B proxy no-direct smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_incoming_foreign_client_s5b(RemoteJingleS5bSmokeConfig config,
            RemoteJingleS5bPairSmokeConfig? pair_config = null, bool scripted_raw_sender = false) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-jingle-s5b-smoke-" + Uuid.string_random());
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? account = null;
        Account? pair_sender_account = null;
        FileManager? manager = null;
        FileTransfer? active_transfer = null;
        XmppStream? negotiated_stream = null;
        RemoteJingleIncomingObservation? incoming_observation = null;
        string? stored_path = null;
        string? storage_dir = null;
        Cancellable? pair_sender_cancellable = null;
        bool pair_sender_done = true;
        ulong received_handler = 0;
        ulong xep_incoming_handler = 0;
        ulong session_handler = 0;
        bool active_transfer_settled = true;
        bool background_quiesced = true;
        Error? pending_error = null;
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            storage_dir = configure_isolated_storage(temp_dir);
            db = new Database(Path.build_filename(temp_dir, "dino.db"), "remote-jingle-s5b-smoke");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            var file_encryption = new FileEncryption("remote-jingle-s5b-smoke");
            start_minimal_file_modules((!) stream_interactor, (!) db, file_encryption);
            manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (manager == null) {
                throw new IOError.FAILED("FileManager was not started");
            }

            account = new Account(config.account_jid.bare_jid, config.password);
            ((!) account).enabled = true;
            ((!) account).custom_host = config.custom_host;
            ((!) account).custom_port = config.custom_port;
            ((!) account).proxy_type = config.receiver_proxy_type;
            ((!) account).proxy_host = config.receiver_proxy_host;
            ((!) account).proxy_port = config.receiver_proxy_port;
            persist_remote_smoke_account_without_password((!) db, (!) account);
            if (pair_config != null) {
                pair_sender_account = new Account(((!) pair_config).sender_jid.bare_jid, ((!) pair_config).sender_password);
                ((!) pair_sender_account).enabled = true;
                ((!) pair_sender_account).custom_host = config.custom_host;
                ((!) pair_sender_account).custom_port = config.custom_port;
                persist_remote_smoke_account_without_password((!) db, (!) pair_sender_account);
            }

            seed_trusted_roster_contact((!) db, (!) account, config.sender_jid);
            Conversation conversation = new Conversation(config.sender_jid.bare_jid, (!) account, Conversation.Type.CHAT);
            conversation.persist((!) db);

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }
            if (pair_sender_account != null) {
                string sender_connect_failure = "";
                if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) pair_sender_account, config.timeout_seconds, out sender_connect_failure))) {
                    throw new IOError.TIMED_OUT("DinoX-pair sender " + sender_connect_failure);
                }
            }

            var roster_manager = ((!) stream_interactor).get_module<RosterManager>(RosterManager.IDENTITY);
            if (roster_manager == null || ((!) roster_manager).get_roster_item((!) account, config.sender_jid) == null) {
                throw new IOError.FAILED("expected sender must be present in the account roster before auto-download can prove receive-store");
            }

            incoming_observation = new RemoteJingleIncomingObservation();
            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<Xmpp.Xep.JingleFileTransfer.Module>(
                    (!) account, Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module == null) {
                throw new IOError.FAILED("Jingle file-transfer module was not available");
            }
            xep_incoming_handler = ((!) jingle_file_module).file_incoming.connect((stream, jingle_transfer) => {
                if (!jingle_transfer.peer.equals_bare(config.sender_jid)) return;
                ((!) incoming_observation).count++;
                ((!) incoming_observation).peer = jingle_transfer.peer;
                ((!) incoming_observation).file_name = jingle_transfer.file_name;
                ((!) incoming_observation).size = jingle_transfer.size;
                ((!) incoming_observation).transport_ns_uri = jingle_transfer.transport_ns_uri;
            });

            XmppStream? stream = ((!) stream_interactor).get_stream((!) account);
            if (stream == null) {
                throw new IOError.FAILED("XMPP stream disappeared after negotiation");
            }
            negotiated_stream = (!) stream;
            apply_receiver_proxy_policy_if_requested((!) stream, (!) account, config);
            var jingle_module = ((!) stream).get_module<Xmpp.Xep.Jingle.Module>(Xmpp.Xep.Jingle.Module.IDENTITY);
            if (jingle_module == null) {
                throw new IOError.FAILED("Jingle module was not attached to the negotiated stream");
            }
            session_handler = ((!) jingle_module).session_initiate_received.connect((seen_stream, session) => {
                if (!session.peer_full_jid.equals_bare(config.sender_jid)) return;
                ((!) incoming_observation).session_sid = session.sid;
                session.terminated.connect((terminated_stream, we_terminated, reason_name, reason_text) => {
                    ((!) incoming_observation).session_terminate_reason = reason_name;
                });
            });
            if (config.expect_proxy_no_direct_failure) {
                GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Jingle session terminated: failed-transport*");
                GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Error downloading file: " +
                        FileManager.DIRECT_TRANSFER_UNAVAILABLE_ERROR + "*");
            }

            FileTransfer? published_transfer = null;
            Conversation? published_conversation = null;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                if (!file_transfer.counterpart.equals_bare(config.sender_jid)) return;
                published_transfer = file_transfer;
                published_conversation = received_conversation;
            });

            publish_ready_message((!) stream_interactor, (!) account, config);

            pair_sender_done = pair_config == null;
            Error? pair_sender_error = null;
            if (pair_config != null) {
                Jid receiver_full_jid = get_bound_full_jid((!) negotiated_stream);
                if (scripted_raw_sender) {
                    pair_sender_cancellable = new Cancellable();
                    start_scripted_s5b_sender.begin((!) stream_interactor, (!) pair_sender_account, receiver_full_jid,
                            config, (!) pair_config, (!) pair_sender_cancellable, (obj, res) => {
                        try {
                            start_scripted_s5b_sender.end(res);
                        } catch (Error e) {
                            pair_sender_error = e;
                        }
                        pair_sender_done = true;
                    });
                } else {
                    start_dinox_pair_sender.begin((!) stream_interactor, (!) pair_sender_account, receiver_full_jid, config, (!) pair_config, (obj, res) => {
                        try {
                            start_dinox_pair_sender.end(res);
                        } catch (Error e) {
                            pair_sender_error = e;
                        }
                        pair_sender_done = true;
                    });
                }
            }

            if (!(yield wait_for_condition(config.timeout_seconds, () =>
                    published_transfer != null ||
                    pair_sender_error != null ||
                    (pair_config != null && pair_sender_done)))) {
                throw new IOError.TIMED_OUT("timed out waiting for a Jingle file offer from the expected sender");
            }
            if (pair_sender_error != null) {
                throw new IOError.FAILED(@"$(scripted_raw_sender ? "scripted-raw sender" : "DinoX-pair sender") failed before receiver published the offer: $(( (!) pair_sender_error).message)");
            }
            if (published_transfer == null) {
                throw new IOError.FAILED(@"$(scripted_raw_sender ? "scripted-raw sender" : "DinoX-pair sender") finished before the receiver published an incoming offer");
            }
            FileTransfer file_transfer = (!) published_transfer;
            active_transfer = file_transfer;
            active_transfer_settled = !is_receive_transfer_active(file_transfer);
            Conversation received_conversation = (!) published_conversation;

            validate_incoming_observation((!) incoming_observation, config);
            validate_published_shell(file_transfer, received_conversation, conversation, config);

            if (config.expect_proxy_no_direct_failure) {
                if (!(yield wait_for_condition(config.timeout_seconds, () =>
                        file_transfer.phase == FileTransfer.Phase.FAILED ||
                        file_transfer.phase == FileTransfer.Phase.COMPLETE))) {
                    active_transfer_settled = yield request_active_transfer_shutdown(file_transfer, negotiated_stream, incoming_observation);
                    throw new IOError.TIMED_OUT(@"timed out waiting for FileManager to fail the proxy no-direct Jingle S5B receive-store (phase=$((int) file_transfer.phase), state=$((int) file_transfer.state), error=$(file_transfer.phase_error ?? "none"))");
                }
                active_transfer_settled = true;
                validate_proxy_no_direct_failed_transfer((!) db, file_transfer, (!) storage_dir, config);
                GLib.Test.assert_expected_messages();
            } else {
                if (!(yield wait_for_condition(config.timeout_seconds, () =>
                        file_transfer.phase == FileTransfer.Phase.COMPLETE ||
                        file_transfer.phase == FileTransfer.Phase.FAILED))) {
                    active_transfer_settled = yield request_active_transfer_shutdown(file_transfer, negotiated_stream, incoming_observation);
                    throw new IOError.TIMED_OUT("timed out waiting for FileManager to finish the incoming Jingle S5B receive-store");
                }
                active_transfer_settled = true;
                if (file_transfer.phase == FileTransfer.Phase.FAILED) {
                    throw new IOError.FAILED(@"incoming Jingle S5B receive-store failed: $(file_transfer.phase_error ?? "no phase error")");
                }

                stored_path = file_transfer.path;
                validate_completed_transfer((!) db, file_transfer, config);
                yield validate_stored_payload(file_encryption, file_transfer, config);
                if (count_receive_pending_files_for_basename((!) storage_dir, config.expected_file_name) != 0) {
                    throw new IOError.FAILED("incoming Jingle S5B receive-store left pending receive files");
                }
            }

            if (((!) incoming_observation).session_sid != null) {
                string sid = (!) ((!) incoming_observation).session_sid;
                yield wait_for_condition(5, () => !has_jingle_session_state((!) stream, sid));
                if (has_jingle_session_state((!) stream, sid)) {
                    throw new IOError.FAILED("incoming Jingle S5B session state remained after completion");
                }
            }

            if (pair_config != null) {
                yield wait_for_condition(10, () => pair_sender_done);
                if (pair_sender_error != null) {
                    throw new IOError.FAILED(@"$(scripted_raw_sender ? "scripted-raw sender" : "DinoX-pair sender") failed: $(( (!) pair_sender_error).message)");
                }
                if (!pair_sender_done) {
                    throw new IOError.TIMED_OUT(@"timed out waiting for the $(scripted_raw_sender ? "scripted-raw sender" : "DinoX-pair sender") to finish");
                }
            }
        } catch (Error e) {
            pending_error = e;
        }

        if (pair_sender_cancellable != null && !pair_sender_done) {
            ((!) pair_sender_cancellable).cancel();
        }
        if (active_transfer != null && !active_transfer_settled) {
            active_transfer_settled = yield request_active_transfer_shutdown((!) active_transfer, negotiated_stream, incoming_observation);
            if (!active_transfer_settled) {
                GLib.Test.message("Remote Jingle S5B smoke cleanup left the active receive pipeline unsettled; skipping storage/temp cleanup to avoid racing FileManager");
            }
        }
        if (xep_incoming_handler != 0) {
            var jingle_file_module = ((!) stream_interactor).module_manager.get_module<Xmpp.Xep.JingleFileTransfer.Module>(
                    (!) account, Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
            if (jingle_file_module != null) ((!) jingle_file_module).disconnect(xep_incoming_handler);
        }
        if (session_handler != 0 && stream_interactor != null && account != null) {
            XmppStream? stream = ((!) stream_interactor).get_stream((!) account);
            if (stream != null) {
                var jingle_module = ((!) stream).get_module<Xmpp.Xep.Jingle.Module>(Xmpp.Xep.Jingle.Module.IDENTITY);
                if (jingle_module != null) ((!) jingle_module).disconnect(session_handler);
            }
        }
        if (received_handler != 0 && manager != null) {
            ((!) manager).disconnect(received_handler);
        }
        if (stream_interactor != null) {
            cancel_history_sync_for_cleanup((!) stream_interactor, account);
            cancel_history_sync_for_cleanup((!) stream_interactor, pair_sender_account);
        }
        if (stream_interactor != null && pair_sender_account != null) {
            yield ((!) stream_interactor).disconnect_account((!) pair_sender_account);
        }
        if (stream_interactor != null && account != null) {
            yield ((!) stream_interactor).disconnect_account((!) account);
        }
        if (stream_interactor != null) {
            background_quiesced = yield wait_for_background_quiescence_for_cleanup((!) stream_interactor, account, pair_sender_account);
            if (!background_quiesced) {
                int pending_background = history_sync_pending_count_for_cleanup((!) stream_interactor, account) +
                    history_sync_pending_count_for_cleanup((!) stream_interactor, pair_sender_account);
                GLib.Test.message(@"Remote Jingle S5B smoke cleanup left $pending_background background task(s) unsettled; skipping storage/temp cleanup to avoid racing closed test resources");
            }
        }
        if (pair_sender_cancellable != null && !pair_sender_done) {
            yield wait_for_condition(5, () => pair_sender_done);
            if (!pair_sender_done) {
                GLib.Test.message("Remote Jingle S5B smoke cleanup left the scripted sender unsettled after cancellation");
            }
        }
        bool cleanup_safe = active_transfer_settled && background_quiesced;
        if (cleanup_safe && stored_path != null && storage_dir != null) {
            FileUtils.remove(Path.build_filename((!) storage_dir, (!) stored_path));
        }
        if (cleanup_safe && storage_dir != null) {
            delete_receive_pending_files_for_basename((!) storage_dir, config.expected_file_name);
        }
        if (cleanup_safe && db != null) {
            ((!) db).close();
        }
        if (cleanup_safe) {
            try {
                delete_file_tree(File.new_for_path(temp_dir));
            } catch (Error e) {
                GLib.Test.message(@"Could not clean remote Jingle S5B smoke temp dir: $(e.message)");
            }
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);

        if (pending_error != null) throw (!) pending_error;
    }

    private static Jid get_bound_full_jid(XmppStream stream) throws IOError {
        var bind_flag = stream.get_flag(Xmpp.Bind.Flag.IDENTITY);
        if (bind_flag == null || ((!) bind_flag).my_jid == null) {
            throw new IOError.FAILED("receiver stream did not expose a bound full JID");
        }
        return (!) ((!) bind_flag).my_jid;
    }

    private async void start_dinox_pair_sender(StreamInteractor stream_interactor, Account sender_account, Jid receiver_full_jid,
            RemoteJingleS5bSmokeConfig receiver_config, RemoteJingleS5bPairSmokeConfig pair_config) throws Error {
        XmppStream? sender_stream = stream_interactor.get_stream(sender_account);
        if (sender_stream == null) {
            throw new IOError.FAILED("DinoX-pair sender stream was not available");
        }

        var file_transfer_module = ((!) sender_stream).get_module<Xmpp.Xep.JingleFileTransfer.Module>(
                Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
        if (file_transfer_module == null) {
            throw new IOError.FAILED("DinoX-pair sender Jingle file-transfer module was not attached");
        }
        if (!(yield ((!) file_transfer_module).is_available((!) sender_stream, receiver_full_jid))) {
            throw new IOError.FAILED("DinoX-pair receiver full JID did not advertise Jingle S5B file-transfer availability");
        }

        var input_stream = new MemoryInputStream.from_data(pair_config.payload.data);
        yield ((!) file_transfer_module).offer_file_stream(
                (!) sender_stream,
                receiver_full_jid,
                input_stream,
                receiver_config.expected_file_name,
                receiver_config.expected_size);
    }

    private async void start_scripted_s5b_sender(StreamInteractor stream_interactor, Account sender_account, Jid receiver_full_jid,
            RemoteJingleS5bSmokeConfig receiver_config, RemoteJingleS5bPairSmokeConfig pair_config, Cancellable cancellable) throws Error {
        XmppStream? sender_stream = stream_interactor.get_stream(sender_account);
        if (sender_stream == null) {
            throw new IOError.FAILED("scripted-raw sender stream was not available");
        }
        throw_if_cancelled(cancellable, "scripted-raw sender");
        Xmpp.Iq.Module? iq_module = ((!) sender_stream).get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY);
        if (iq_module == null) {
            throw new IOError.FAILED("scripted-raw sender IQ module was not attached");
        }

        detach_dinox_jingle_handlers_for_scripted_sender((!) sender_stream);

        Jid sender_full_jid = get_bound_full_jid((!) sender_stream);
        string jingle_sid = "raw-jingle-s5b-" + Uuid.string_random();
        string s5b_sid = "raw-s5b-" + Uuid.string_random();
        string content_name = "raw-file-offer";
        string candidate_cid = "raw-sender-direct-" + Uuid.string_random();
        string sender_dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, sender_full_jid, receiver_full_jid);
        ScriptedS5bListener s5b_listener = new ScriptedS5bListener(sender_dstaddr, cancellable);
        ScriptedJingleSenderHandler raw_handler = new ScriptedJingleSenderHandler(jingle_sid, receiver_full_jid);

        ((!) iq_module).register_for_namespace(Xmpp.Xep.Jingle.NS_URI, raw_handler);
        try {
            s5b_listener.start();
            StanzaNode initiate = build_scripted_s5b_session_initiate(
                    sender_full_jid,
                    receiver_full_jid,
                    jingle_sid,
                    content_name,
                    s5b_sid,
                    receiver_config.expected_file_name,
                    receiver_config.expected_size,
                    candidate_cid,
                    "127.0.0.1",
                    s5b_listener.port);
            Xmpp.Iq.Stanza initiate_result = yield ((!) iq_module).send_iq_async(
                    (!) sender_stream,
                    new Xmpp.Iq.Stanza.set(initiate) { to = receiver_full_jid },
                    Priority.DEFAULT,
                    cancellable);
            throw_if_cancelled(cancellable, "scripted-raw sender");
            ensure_successful_iq_response(initiate_result, "scripted-raw session-initiate");

            if (!(yield wait_for_condition(receiver_config.timeout_seconds, () =>
                    raw_handler.session_accept_jingle != null || raw_handler.session_terminated, cancellable))) {
                throw_if_cancelled(cancellable, "scripted-raw sender");
                throw new IOError.TIMED_OUT("timed out waiting for scripted-raw session-accept");
            }
            if (raw_handler.session_terminated) {
                throw new IOError.FAILED(@"scripted-raw session terminated before accept: $(raw_handler.terminate_reason ?? "(none)")");
            }
            if (raw_handler.session_accept_count != 1) {
                throw new IOError.FAILED(@"scripted-raw sender observed $(raw_handler.session_accept_count) session-accept stanzas");
            }
            get_scripted_accept_s5b_transport((!) raw_handler.session_accept_jingle, content_name, s5b_sid);

            if (!(yield wait_for_condition(receiver_config.timeout_seconds, () =>
                    raw_handler.selected_candidate_cid == candidate_cid ||
                    raw_handler.session_terminated ||
                    s5b_listener.pending_error != null,
                    cancellable))) {
                throw_if_cancelled(cancellable, "scripted-raw sender");
                throw new IOError.TIMED_OUT("timed out waiting for DinoX to select the scripted-raw S5B candidate");
            }
            if (s5b_listener.pending_error != null) {
                throw new IOError.FAILED(@"scripted-raw S5B listener failed: $(( (!) s5b_listener.pending_error).message)");
            }
            if (raw_handler.session_terminated) {
                throw new IOError.FAILED(@"scripted-raw session terminated before candidate selection: $(raw_handler.terminate_reason ?? "(none)")");
            }
            if (!(yield wait_for_condition(receiver_config.timeout_seconds, () =>
                    s5b_listener.connection != null || s5b_listener.pending_error != null,
                    cancellable))) {
                throw_if_cancelled(cancellable, "scripted-raw sender");
                throw new IOError.TIMED_OUT("timed out waiting for DinoX to connect to the scripted-raw S5B listener");
            }
            if (s5b_listener.pending_error != null) {
                throw new IOError.FAILED(@"scripted-raw S5B listener failed: $(( (!) s5b_listener.pending_error).message)");
            }

            StanzaNode candidate_error = build_scripted_s5b_candidate_error(
                    sender_full_jid,
                    receiver_full_jid,
                    jingle_sid,
                    content_name,
                    s5b_sid);
            Xmpp.Iq.Stanza candidate_error_result = yield ((!) iq_module).send_iq_async(
                    (!) sender_stream,
                    new Xmpp.Iq.Stanza.set(candidate_error) { to = receiver_full_jid },
                    Priority.DEFAULT,
                    cancellable);
            throw_if_cancelled(cancellable, "scripted-raw sender");
            ensure_successful_iq_response(candidate_error_result, "scripted-raw candidate-error");

            size_t written = 0;
            yield ((!) ((!) s5b_listener.connection)).output_stream.write_all_async(
                    pair_config.payload.data,
                    Priority.DEFAULT,
                    cancellable,
                    out written);
            if (written != pair_config.payload.data.length) {
                throw new IOError.FAILED("scripted-raw sender wrote an incomplete payload to S5B");
            }
            yield ((!) ((!) s5b_listener.connection)).output_stream.close_async(Priority.DEFAULT, cancellable);

            if (!(yield wait_for_condition(receiver_config.timeout_seconds, () => raw_handler.session_terminated, cancellable))) {
                throw_if_cancelled(cancellable, "scripted-raw sender");
                throw new IOError.TIMED_OUT("timed out waiting for scripted-raw session-terminate");
            }
            if (raw_handler.terminate_reason != Xmpp.Xep.Jingle.ReasonElement.SUCCESS) {
                throw new IOError.FAILED(@"scripted-raw session terminated with reason $(raw_handler.terminate_reason ?? "(none)")");
            }
        } finally {
            ((!) iq_module).unregister_from_namespace(Xmpp.Xep.Jingle.NS_URI, raw_handler);
            s5b_listener.close();
        }
    }

    private static void detach_dinox_jingle_handlers_for_scripted_sender(XmppStream stream) {
        var jingle_file = stream.get_module<Xmpp.Xep.JingleFileTransfer.Module>(Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
        if (jingle_file != null) ((!) jingle_file).detach(stream);
        var jingle_s5b = stream.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
        if (jingle_s5b != null) ((!) jingle_s5b).detach(stream);
        var jingle_ibb = stream.get_module<Xmpp.Xep.JingleInBandBytestreams.Module>(Xmpp.Xep.JingleInBandBytestreams.Module.IDENTITY);
        if (jingle_ibb != null) ((!) jingle_ibb).detach(stream);
        var jingle = stream.get_module<Xmpp.Xep.Jingle.Module>(Xmpp.Xep.Jingle.Module.IDENTITY);
        if (jingle != null) ((!) jingle).detach(stream);
    }

    private static StanzaNode build_scripted_s5b_session_initiate(Jid sender_full_jid, Jid receiver_full_jid,
            string jingle_sid, string content_name, string s5b_sid, string file_name, int64 file_size,
            string candidate_cid, string candidate_host, int candidate_port) {
        string dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, sender_full_jid, receiver_full_jid);
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr)
            .put_node(new StanzaNode.build("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
                .put_attribute("cid", candidate_cid)
                .put_attribute("host", candidate_host)
                .put_attribute("jid", sender_full_jid.to_string())
                .put_attribute("port", candidate_port.to_string())
                .put_attribute("priority", "8267775")
                .put_attribute("type", "direct"));
        StanzaNode content = new StanzaNode.build("content", Xmpp.Xep.Jingle.NS_URI)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_scripted_file_description(file_name, file_size))
            .put_node(transport);
        return new StanzaNode.build("jingle", Xmpp.Xep.Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", sender_full_jid.to_string())
            .put_attribute("sid", jingle_sid)
            .put_node(content);
    }

    private static StanzaNode build_scripted_file_description(string file_name, int64 file_size) {
        return new StanzaNode.build("description", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("file", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                .put_node(new StanzaNode.build("name", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                    .put_node(new StanzaNode.text(file_name)))
                .put_node(new StanzaNode.build("size", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                    .put_node(new StanzaNode.text(file_size.to_string()))));
    }

    private static StanzaNode build_scripted_s5b_candidate_error(Jid sender_full_jid, Jid receiver_full_jid,
            string jingle_sid, string content_name, string s5b_sid) {
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("sid", s5b_sid)
            .put_node(new StanzaNode.build("candidate-error", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns));
        StanzaNode content = new StanzaNode.build("content", Xmpp.Xep.Jingle.NS_URI)
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        return new StanzaNode.build("jingle", Xmpp.Xep.Jingle.NS_URI)
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", sender_full_jid.to_string())
            .put_attribute("sid", jingle_sid)
            .put_node(content);
    }

    private static void throw_if_cancelled(Cancellable cancellable, string context) throws IOError {
        if (cancellable.is_cancelled()) {
            throw new IOError.CANCELLED(@"$context cancelled");
        }
    }

    private static StanzaNode get_scripted_accept_s5b_transport(StanzaNode accept_jingle, string content_name, string s5b_sid) throws Error {
        StanzaNode content = get_required_subnode(accept_jingle, "content", Xmpp.Xep.Jingle.NS_URI);
        if (content.get_attribute("name") != content_name) {
            throw new IOError.FAILED("scripted-raw session-accept used an unexpected content name");
        }
        StanzaNode transport = get_required_subnode(content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
        if (transport.get_attribute("sid") != s5b_sid) {
            throw new IOError.FAILED("scripted-raw session-accept used an unexpected S5B sid");
        }
        return transport;
    }

    private static StanzaNode get_required_subnode(StanzaNode node, string name, string ns_uri) throws IOError {
        StanzaNode? child = node.get_subnode(name, ns_uri);
        if (child == null) {
            throw new IOError.FAILED(@"missing required $name subnode");
        }
        return (!) child;
    }

    private static void ensure_successful_iq_response(Xmpp.Iq.Stanza iq, string context) throws IOError {
        if (!iq.is_error()) return;

        ErrorStanza? error = iq.get_error();
        string condition = error != null ? ((!) error).condition : "unknown-error";
        string? text = error != null ? ((!) error).text : null;
        throw new IOError.FAILED(@"$context returned XMPP error $condition$(text != null ? ": " + (!) text : "")");
    }

    private static void restore_env_var(string name, string? previous_value) {
        if (previous_value == null) {
            Environment.unset_variable(name);
        } else {
            Environment.set_variable(name, (!) previous_value, true);
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
            throw new IOError.PERMISSION_DENIED(@"remote Jingle S5B smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
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

    private static void start_minimal_file_modules(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
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

    private static void apply_receiver_proxy_policy_if_requested(XmppStream stream, Account account, RemoteJingleS5bSmokeConfig config) throws IOError {
        if (config.receiver_proxy_type == "none") return;
        var jingle_s5b = stream.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(
                Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
        if (jingle_s5b == null) {
            throw new IOError.FAILED("receiver proxy policy requested but Jingle S5B module was not attached");
        }
        string? proxy_uri = Dino.build_socks5_proxy_uri(account);
        if (proxy_uri == null || ((!) proxy_uri) == "") {
            throw new IOError.FAILED("receiver proxy policy requested but no SOCKS5 proxy URI could be built");
        }
        ((!) jingle_s5b).set_network_policy(false, proxy_uri);
    }

    private static void persist_remote_smoke_account_without_password(Database db, Account account) {
        if (account.id > 0) return;

        // These opt-in smokes use real credentials; keep passwords in memory only.
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
            if (timeout_id != 0) Source.remove(timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        error_id = stream_interactor.connection_manager.connection_error.connect((seen_account, error) => {
            if (completed || !Account.equals_func(seen_account, account)) return;
            completed = true;
            success = false;
            local_failure_reason = format_connection_error(error);
            if (timeout_id != 0) Source.remove(timeout_id);
            if (error_id != 0) SignalHandler.disconnect(stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(stream_interactor, negotiated_id);
            resume();
        });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            success = false;
            local_failure_reason = "timed out waiting for XMPP stream negotiation";
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

    private async bool wait_for_condition(uint timeout_seconds, WaitCondition condition, Cancellable? cancellable = null) {
        if (condition()) return true;
        if (cancellable != null && ((!) cancellable).is_cancelled()) return false;

        bool completed = false;
        bool success = false;
        SourceFunc resume = wait_for_condition.callback;
        uint poll_id = 0;
        uint timeout_id = 0;

        poll_id = Timeout.add(100, () => {
            if (completed) return Source.REMOVE;
            if (cancellable != null && ((!) cancellable).is_cancelled()) {
                completed = true;
                success = false;
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                    timeout_id = 0;
                }
                poll_id = 0;
                resume();
                return Source.REMOVE;
            }
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

    private static void cancel_history_sync_for_cleanup(StreamInteractor stream_interactor, Account? account) {
        if (account == null) return;

        MessageProcessor? processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        if (processor == null) return;

        HistorySync history_sync = ((!) processor).history_sync;
        if (!history_sync.cancellables.has_key((!) account)) return;

        foreach (Cancellable cancellable in history_sync.cancellables[(!) account].values) {
            cancellable.cancel();
        }
    }

    private async bool wait_for_background_quiescence_for_cleanup(StreamInteractor stream_interactor, Account? account, Account? pair_sender_account) {
        yield drain_main_context_for_cleanup();
        bool quiesced = yield wait_for_condition(30, () =>
            history_sync_quiesced_for_cleanup(stream_interactor, account) &&
            history_sync_quiesced_for_cleanup(stream_interactor, pair_sender_account)
        );
        yield drain_main_context_for_cleanup();
        return quiesced;
    }

    private static bool history_sync_quiesced_for_cleanup(StreamInteractor stream_interactor, Account? account) {
        return history_sync_pending_count_for_cleanup(stream_interactor, account) == 0;
    }

    private static int history_sync_pending_count_for_cleanup(StreamInteractor stream_interactor, Account? account) {
        if (account == null) return 0;

        MessageProcessor? processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        if (processor == null) return 0;

        HistorySync history_sync = ((!) processor).history_sync;
        if (!history_sync.cancellables.has_key((!) account)) return 0;
        return history_sync.cancellables[(!) account].size;
    }

    private async void drain_main_context_for_cleanup() {
        for (int i = 0; i < 5; i++) {
            Idle.add(drain_main_context_for_cleanup.callback, Priority.LOW);
            yield;
        }
    }

    private async bool request_active_transfer_shutdown(FileTransfer file_transfer, XmppStream? stream, RemoteJingleIncomingObservation? observation) {
        if (!is_receive_transfer_active(file_transfer)) return true;

        file_transfer.cancellable.cancel();
        if (stream != null && observation != null && ((!) observation).session_sid != null) {
            terminate_jingle_session_if_present((!) stream, (!) ((!) observation).session_sid);
        }

        yield wait_for_condition(5, () => !is_receive_transfer_active(file_transfer));
        return !is_receive_transfer_active(file_transfer);
    }

    private static bool is_receive_transfer_active(FileTransfer file_transfer) {
        return file_transfer.state == FileTransfer.State.IN_PROGRESS;
    }

    private static void terminate_jingle_session_if_present(XmppStream stream, string sid) {
        var jingle_flag = stream.get_flag(Xmpp.Xep.Jingle.Flag.IDENTITY);
        if (jingle_flag == null) return;
        if (((!) jingle_flag).sessions.has_key(sid)) {
            ((!) jingle_flag).sessions[sid].terminate(
                    Xmpp.Xep.Jingle.ReasonElement.FAILED_TRANSPORT,
                    "remote smoke cleanup",
                    "remote smoke cleanup");
        } else if (((!) jingle_flag).promises.has_key(sid)) {
            ((!) jingle_flag).remove_session(sid);
        }
    }

    private static void publish_ready_message(StreamInteractor stream_interactor, Account account, RemoteJingleS5bSmokeConfig config) throws Error {
        string bound_jid = account.full_jid.to_string();
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null && ((!) stream).has_flag(Xmpp.Bind.Flag.IDENTITY)) {
            Jid? my_jid = ((!) stream).get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid;
            if (my_jid != null) bound_jid = ((!) my_jid).to_string();
        }

        string message = "remote-jingle-s5b-smoke-ready\n" +
            @"account=$(account.bare_jid.to_string())\n" +
            @"bound_jid=$bound_jid\n" +
            @"expected_sender=$(config.sender_jid.bare_jid.to_string())\n" +
            @"expected_name=$(config.expected_file_name)\n" +
            @"expected_size=$(config.expected_size)\n";
        GLib.Test.message(message.strip());
        if (config.ready_file != null) {
            FileUtils.set_contents((!) config.ready_file, message);
        }
    }

    private static void validate_incoming_observation(RemoteJingleIncomingObservation observation, RemoteJingleS5bSmokeConfig config) throws IOError {
        if (observation.count == 0) {
            throw new IOError.FAILED("Jingle file-transfer hook did not observe the expected incoming offer");
        }
        if (observation.count != 1) {
            throw new IOError.FAILED(@"Jingle file-transfer hook observed $(observation.count) matching offers");
        }
        if (observation.peer == null || !((!) observation.peer).equals_bare(config.sender_jid)) {
            throw new IOError.FAILED("Jingle file-transfer hook observed the wrong sender");
        }
        if (observation.file_name != config.expected_file_name) {
            throw new IOError.FAILED(@"Jingle file-transfer hook observed file name '$(observation.file_name ?? "(null)")' instead of '$(config.expected_file_name)'");
        }
        if (observation.size != config.expected_size) {
            throw new IOError.FAILED(@"Jingle file-transfer hook observed size $(observation.size) instead of $(config.expected_size)");
        }
        if (observation.transport_ns_uri != Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns) {
            throw new IOError.FAILED(@"incoming Jingle offer used transport '$(observation.transport_ns_uri ?? "(null)")' instead of S5B");
        }
        if (observation.session_sid == null || ((!) observation.session_sid) == "") {
            throw new IOError.FAILED("Jingle session-initiate hook did not observe a session SID for the incoming offer");
        }
    }

    private static void validate_published_shell(FileTransfer file_transfer, Conversation received_conversation, Conversation expected_conversation, RemoteJingleS5bSmokeConfig config) throws IOError {
        if (received_conversation.id != expected_conversation.id) {
            throw new IOError.FAILED("FileManager published the incoming file on the wrong conversation");
        }
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("FileManager must publish a persisted incoming transfer");
        }
        if (file_transfer.provider != JINGLE_PROVIDER_ID) {
            throw new IOError.FAILED("FileManager must publish the Jingle provider id for incoming S5B");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("FileManager must publish the incoming Jingle S5B transfer as received");
        }
        if (!file_transfer.counterpart.equals_bare(config.sender_jid)) {
            throw new IOError.FAILED("FileManager must keep the expected sender as counterpart");
        }
        if (file_transfer.file_name != config.expected_file_name) {
            throw new IOError.FAILED(@"FileManager published file name '$(file_transfer.file_name)' instead of '$(config.expected_file_name)'");
        }
    }

    private static void validate_completed_transfer(Database db, FileTransfer file_transfer, RemoteJingleS5bSmokeConfig config) throws IOError {
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"incoming Jingle S5B receive-store kept phase error '$(file_transfer.phase_error)'");
        }
        if (file_transfer.size != config.expected_size) {
            throw new IOError.FAILED(@"FileManager published plaintext size $(file_transfer.size) instead of $(config.expected_size)");
        }
        if (file_transfer.path == null || file_transfer.path == "") {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must only allow plaintext release after completion");
        }

        RowOption row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", file_transfer.id)
                .single()
                .row();
        if (!row.is_present()) {
            throw new IOError.FAILED("incoming Jingle S5B transfer must have a database row");
        }
        var persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        string? persisted_path = ((!) row.inner)[db.file_transfer.path];
        int64 persisted_size = ((!) row.inner)[db.file_transfer.size];
        if (persisted_state != FileTransfer.State.COMPLETE) {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must persist COMPLETE state");
        }
        if (persisted_path == null || ((!) persisted_path) == "") {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must persist the storage path");
        }
        if (persisted_size != config.expected_size) {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must persist the plaintext size");
        }
    }

    private static void validate_proxy_no_direct_failed_transfer(Database db, FileTransfer file_transfer, string storage_dir,
            RemoteJingleS5bSmokeConfig config) throws Error {
        if (file_transfer.phase != FileTransfer.Phase.FAILED || file_transfer.state != FileTransfer.State.FAILED) {
            throw new IOError.FAILED("proxy no-direct smoke must leave the incoming transfer failed, not complete");
        }
        if (file_transfer.path != null && ((!) file_transfer.path) != "") {
            throw new IOError.FAILED("proxy no-direct smoke must not publish a verified storage path");
        }
        if (file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("proxy no-direct smoke must not allow plaintext release");
        }
        Qlite.RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", file_transfer.id)
            .single()
            .row();
        if (row.is_present()) {
            string? persisted_path = ((!) row.inner)[db.file_transfer.path];
            FileTransfer.State persisted_state = (FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
            if (persisted_state != FileTransfer.State.FAILED) {
                throw new IOError.FAILED("proxy no-direct smoke must persist FAILED state");
            }
            if (persisted_path != null && ((!) persisted_path) != "") {
                throw new IOError.FAILED("proxy no-direct smoke must not persist a storage path");
            }
        }
        if (count_receive_pending_files_for_basename(storage_dir, config.expected_file_name) != 0) {
            throw new IOError.FAILED("proxy no-direct smoke left pending receive files");
        }
    }

    private async void validate_stored_payload(FileEncryption file_encryption, FileTransfer file_transfer, RemoteJingleS5bSmokeConfig config) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED("incoming Jingle S5B receive-store must write the verified local file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();

        if (decrypted.length != config.expected_size) {
            throw new IOError.FAILED(@"decrypted incoming Jingle S5B payload size $(decrypted.length) did not match $(config.expected_size)");
        }
        string actual_sha256 = normalize_sha256(Checksum.compute_for_data(ChecksumType.SHA256, decrypted));
        if (actual_sha256 != config.expected_sha256) {
            throw new IOError.FAILED(@"decrypted incoming Jingle S5B payload SHA-256 $actual_sha256 did not match $(config.expected_sha256)");
        }
    }

    private static bool has_jingle_session_state(XmppStream stream, string sid) {
        var jingle_flag = stream.get_flag(Xmpp.Xep.Jingle.Flag.IDENTITY);
        return jingle_flag != null && (((!) jingle_flag).promises.has_key(sid) || ((!) jingle_flag).sessions.has_key(sid));
    }

    private static void seed_trusted_roster_contact(Database db, Account account, Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, jid.bare_jid.to_string())
            .value(db.roster.subscription, Xmpp.Roster.Item.SUBSCRIPTION_BOTH)
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
            if (name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) {
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
                if (name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) {
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

    private static string normalize_sha256(string value) {
        StringBuilder builder = new StringBuilder();
        string stripped = value.strip().down();
        for (int i = 0; i < stripped.length; i++) {
            char c = stripped[i];
            if (c == ':' || c == '-' || c == ' ') continue;
            builder.append_c(c);
        }
        return builder.str;
    }

    private class RemoteJingleIncomingObservation : Object {
        public int count = 0;
        public Jid? peer = null;
        public string? file_name = null;
        public int64 size = -1;
        public string? transport_ns_uri = null;
        public string? session_sid = null;
        public string? session_terminate_reason = null;
    }

    private class ScriptedS5bListener : Object {
        private SocketListener listener;
        private string dstaddr;
        private Cancellable cancellable;

        public int port { get; private set; }
        public SocketConnection? connection = null;
        public Error? pending_error = null;

        public ScriptedS5bListener(string dstaddr, Cancellable cancellable) throws Error {
            this.dstaddr = dstaddr;
            this.cancellable = cancellable;
            listener = new SocketListener();
            SocketAddress effective_any;
            listener.add_address(
                    new InetSocketAddress.from_string("127.0.0.1", 0),
                    SocketType.STREAM,
                    SocketProtocol.DEFAULT,
                    null,
                    out effective_any);
            port = (int) ((InetSocketAddress) effective_any).port;
        }

        public void start() {
            run.begin((obj, res) => {
                try {
                    run.end(res);
                } catch (Error e) {
                    pending_error = e;
                }
            });
        }

        public void close() {
            listener.close();
            if (connection != null) {
                try {
                    ((!) connection).close();
                } catch (Error e) {
                }
            }
        }

        private async void run() throws Error {
            Object source;
            SocketConnection accepted = yield listener.accept_async(cancellable, out source);
            yield handle_connection(accepted);
        }

        private async void handle_connection(SocketConnection accepted) throws Error {
            accepted.socket.timeout = 10;
            size_t read;
            size_t written;
            uint8[] read_buffer = new uint8[1024];
            ByteArray write_buffer = new ByteArray();

            yield accepted.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, cancellable, out read);
            if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
                throw new IOError.PROXY_FAILED("scripted-raw S5B listener received an invalid SOCKS5 hello");
            }
            int num_auth_methods = read_buffer[1];
            yield accepted.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, cancellable, out read);
            bool found_null_auth = false;
            for (int i = 0; i < read; i++) {
                if (read_buffer[i] == 0x00) {
                    found_null_auth = true;
                    break;
                }
            }
            if (read != num_auth_methods || !found_null_auth) {
                throw new IOError.PROXY_FAILED("scripted-raw S5B listener did not receive null-auth support");
            }
            yield accepted.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, cancellable, out written);

            yield accepted.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, cancellable, out read);
            if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[3] != 0x03) {
                throw new IOError.PROXY_FAILED("scripted-raw S5B listener received an invalid connect request");
            }
            yield accepted.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, cancellable, out read);
            if (read != 1) {
                throw new IOError.PROXY_FAILED("scripted-raw S5B listener did not receive a dstaddr length");
            }
            int dstaddr_len = read_buffer[0];
            yield accepted.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, cancellable, out read);
            if (read != dstaddr_len + 2 ||
                    dstaddr_len != dstaddr.length ||
                    !Xmpp.Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], dstaddr.data) ||
                    read_buffer[dstaddr_len] != 0x00 ||
                    read_buffer[dstaddr_len + 1] != 0x00) {
                throw new IOError.PROXY_FAILED("scripted-raw S5B listener received an unexpected dstaddr");
            }

            write_buffer.append({0x05, 0x00, 0x00, 0x03});
            write_buffer.append({(uint8) dstaddr.length});
            write_buffer.append(dstaddr.data);
            write_buffer.append({0x00, 0x00});
            yield accepted.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, cancellable, out written);
            accepted.socket.timeout = 0;
            connection = accepted;
        }
    }

    private class ScriptedJingleSenderHandler : Object, Xmpp.Iq.Handler {
        private string expected_sid;
        private Jid expected_peer;

        public StanzaNode? session_accept_jingle = null;
        public int session_accept_count = 0;
        public string? selected_candidate_cid = null;
        public bool session_terminated = false;
        public string? terminate_reason = null;

        public ScriptedJingleSenderHandler(string expected_sid, Jid expected_peer) {
            this.expected_sid = expected_sid;
            this.expected_peer = expected_peer;
        }

        public async void on_iq_set(XmppStream stream, Xmpp.Iq.Stanza iq) {
            StanzaNode? jingle = iq.stanza.get_subnode("jingle", Xmpp.Xep.Jingle.NS_URI);
            if (jingle == null || !is_expected_sender_iq(iq, (!) jingle)) {
                stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY).send_iq(
                        stream,
                        new Xmpp.Iq.Stanza.error(iq, new ErrorStanza.item_not_found()) { to = iq.from });
                return;
            }

            string? action = ((!) jingle).get_attribute("action");
            switch (action) {
                case "session-accept":
                    session_accept_jingle = (!) jingle;
                    session_accept_count++;
                    break;
                case "session-terminate":
                    session_terminated = true;
                    terminate_reason = parse_terminate_reason((!) jingle);
                    break;
                case "transport-info":
                    selected_candidate_cid = parse_candidate_used((!) jingle) ?? selected_candidate_cid;
                    break;
                case "session-info":
                    break;
                default:
                    break;
            }

            stream.get_module<Xmpp.Iq.Module>(Xmpp.Iq.Module.IDENTITY).send_iq(
                    stream,
                    new Xmpp.Iq.Stanza.result(iq) { to = iq.from });
        }

        private bool is_expected_sender_iq(Xmpp.Iq.Stanza iq, StanzaNode jingle) {
            string? sid = jingle.get_attribute("sid");
            if (sid != expected_sid) return false;
            if (iq.from == null) return false;
            return ((!) iq.from).equals_bare(expected_peer);
        }

        private static string? parse_candidate_used(StanzaNode jingle) {
            foreach (StanzaNode content in jingle.get_subnodes("content", Xmpp.Xep.Jingle.NS_URI)) {
                StanzaNode? transport = content.get_subnode("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
                if (transport == null) continue;
                StanzaNode? candidate_used = ((!) transport).get_subnode("candidate-used", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
                if (candidate_used == null) continue;
                return ((!) candidate_used).get_attribute("cid");
            }
            return null;
        }

        private static string? parse_terminate_reason(StanzaNode jingle) {
            StanzaNode? reason = jingle.get_subnode("reason", Xmpp.Xep.Jingle.NS_URI);
            if (reason == null) return null;
            foreach (StanzaNode child in ((!) reason).sub_nodes) {
                if (child.ns_uri == Xmpp.Xep.Jingle.NS_URI && child.name != "text") {
                    return child.name;
                }
            }
            return null;
        }
    }

    private class RemoteJingleS5bSmokeConfig : Object {
        public Jid account_jid;
        public string password;
        public Jid sender_jid;
        public string expected_file_name;
        public int64 expected_size = -1;
        public string expected_sha256;
        public string? custom_host = null;
        public int custom_port = 0;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;
        public string? ready_file = null;
        public bool expect_proxy_no_direct_failure = false;
        public string receiver_proxy_type = "none";
        public string? receiver_proxy_host = null;
        public int receiver_proxy_port = 0;

        public static RemoteJingleS5bSmokeConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_JINGLE_S5B_SMOKE=1 with DINOX_REMOTE_JINGLE_S5B_JID, DINOX_REMOTE_JINGLE_S5B_PASSWORD, DINOX_REMOTE_JINGLE_S5B_SENDER_JID, DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME, DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE and DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256 to run the remote Jingle S5B smoke");
                return null;
            }

            string? account_env = require_env("DINOX_REMOTE_JINGLE_S5B_JID");
            string? password_env = require_env("DINOX_REMOTE_JINGLE_S5B_PASSWORD");
            string? sender_env = require_env("DINOX_REMOTE_JINGLE_S5B_SENDER_JID");
            string? expected_name_env = require_env("DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME");
            string? expected_size_env = require_env("DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE");
            string? expected_sha256_env = require_env("DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256");
            if (account_env == null || password_env == null || sender_env == null ||
                    expected_name_env == null || expected_size_env == null || expected_sha256_env == null) {
                return null;
            }

            RemoteJingleS5bSmokeConfig config = new RemoteJingleS5bSmokeConfig();
            try {
                config.account_jid = new Jid((!) account_env);
                config.sender_jid = new Jid((!) sender_env).bare_jid;
                config.password = (!) password_env;
                config.expected_file_name = FileTransfer.sanitize_file_name((!) expected_name_env);
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote Jingle S5B smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            int64 parsed_size = -1;
            if (!int64.try_parse((!) expected_size_env, out parsed_size, null, 10) || parsed_size < 0 || parsed_size >= AUTO_DOWNLOAD_MAX_BYTES) {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE must be an integer between 0 and 4999999 for the FileManager auto-download proof");
                return null;
            }
            config.expected_size = parsed_size;

            string normalized_sha256 = normalize_sha256((!) expected_sha256_env);
            if (!is_sha256_hex(normalized_sha256)) {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256 must be a SHA-256 hex digest");
                return null;
            }
            config.expected_sha256 = normalized_sha256;

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_HOST"));
            config.ready_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_READY_FILE"));
            config.expect_proxy_no_direct_failure = Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT") == "1";

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_JINGLE_S5B_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 600) {
                    fail_if(true, "DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 600");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            if (!parse_receiver_proxy_env(config)) {
                return null;
            }
            if (config.expect_proxy_no_direct_failure && config.receiver_proxy_type == "none") {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT requires DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_TYPE=socks5 or tor");
                return null;
            }

            return config;
        }

        public static RemoteJingleS5bSmokeConfig? from_proxy_no_direct_env() {
            if (Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT=1 with the remote Jingle S5B smoke env and receiver proxy env to run the proxy no-direct smoke");
                return null;
            }
            return from_env();
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_JINGLE_S5B_SMOKE=1");
                return null;
            }
            return value;
        }

        private static string? empty_to_null(string? value) {
            if (value == null) return null;
            string stripped = ((!) value).strip();
            return stripped == "" ? null : stripped;
        }

        private static bool is_sha256_hex(string value) {
            if (value.length != 64) return false;
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                bool digit = c >= '0' && c <= '9';
                bool lower_hex = c >= 'a' && c <= 'f';
                if (!digit && !lower_hex) return false;
            }
            return true;
        }

        private static bool parse_receiver_proxy_env(RemoteJingleS5bSmokeConfig config) {
            string? proxy_type = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_TYPE"));
            if (proxy_type == null) return true;
            proxy_type = ((!) proxy_type).down();
            if (proxy_type != "none" && proxy_type != "socks5" && proxy_type != "tor") {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_TYPE must be none, socks5 or tor");
                return false;
            }
            config.receiver_proxy_type = (!) proxy_type;
            if (config.receiver_proxy_type == "none") return true;

            config.receiver_proxy_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_HOST"));
            string? proxy_port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_PORT"));
            if (config.receiver_proxy_type == "socks5" && config.receiver_proxy_host == null) {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_HOST must be set for socks5 receiver proxy");
                return false;
            }
            if (proxy_port_env != null) {
                int parsed_proxy_port = 0;
                if (!int.try_parse((!) proxy_port_env, out parsed_proxy_port, null, 10) || parsed_proxy_port < 1 || parsed_proxy_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_PORT must be an integer between 1 and 65535");
                    return false;
                }
                config.receiver_proxy_port = parsed_proxy_port;
            }
            if (config.receiver_proxy_type == "socks5" && config.receiver_proxy_port == 0) {
                fail_if(true, "DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_PORT must be set for socks5 receiver proxy");
                return false;
            }
            return true;
        }
    }

    private class RemoteJingleS5bPairSmokeConfig : Object {
        private const string DEFAULT_PAIR_FILE_NAME = "dinox-remote-jingle-s5b-pair.txt";
        private const string DEFAULT_RAW_FILE_NAME = "dinox-remote-jingle-s5b-raw.txt";
        private const string PAIR_PAYLOAD = "DinoX remote Jingle S5B pair smoke payload\n";
        private const string RAW_PAYLOAD = "DinoX remote Jingle S5B scripted raw sender smoke payload\n";

        public Jid account_jid;
        public string password;
        public Jid sender_jid;
        public string sender_password;
        public string expected_file_name;
        public int64 expected_size = -1;
        public string expected_sha256;
        public string payload;
        public string? custom_host = null;
        public int custom_port = 0;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;
        public string? ready_file = null;

        public static RemoteJingleS5bPairSmokeConfig? from_env() {
            return from_enabled_env(
                    "DINOX_REMOTE_JINGLE_S5B_DINOX_PAIR",
                    "remote DinoX-pair Jingle S5B smoke",
                    DEFAULT_PAIR_FILE_NAME,
                    PAIR_PAYLOAD,
                    "DINOX_REMOTE_JINGLE_S5B_PAIR_NAME");
        }

        public static RemoteJingleS5bPairSmokeConfig? from_raw_env() {
            return from_enabled_env(
                    "DINOX_REMOTE_JINGLE_S5B_RAW",
                    "remote scripted-raw Jingle S5B smoke",
                    DEFAULT_RAW_FILE_NAME,
                    RAW_PAYLOAD,
                    "DINOX_REMOTE_JINGLE_S5B_RAW_NAME");
        }

        private static RemoteJingleS5bPairSmokeConfig? from_enabled_env(string enabled_env, string mode_label,
                string default_file_name, string payload, string name_env) {
            if (Environment.get_variable(enabled_env) != "1") {
                GLib.Test.skip(@"Set $enabled_env=1 with DINOX_REMOTE_JINGLE_S5B_JID, DINOX_REMOTE_JINGLE_S5B_PASSWORD, DINOX_REMOTE_JINGLE_S5B_SENDER_JID and DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD to run the $mode_label");
                return null;
            }

            string? account_env = require_env("DINOX_REMOTE_JINGLE_S5B_JID", enabled_env);
            string? password_env = require_env("DINOX_REMOTE_JINGLE_S5B_PASSWORD", enabled_env);
            string? sender_env = require_env("DINOX_REMOTE_JINGLE_S5B_SENDER_JID", enabled_env);
            string? sender_password_env = require_env("DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD", enabled_env);
            if (account_env == null || password_env == null || sender_env == null || sender_password_env == null) {
                return null;
            }

            RemoteJingleS5bPairSmokeConfig config = new RemoteJingleS5bPairSmokeConfig();
            try {
                config.account_jid = new Jid((!) account_env);
                config.sender_jid = new Jid((!) sender_env).bare_jid;
                config.password = (!) password_env;
                config.sender_password = (!) sender_password_env;
            } catch (InvalidJidError e) {
                fail_if(true, @"$mode_label env contains an invalid JID: $(e.message)");
                return null;
            }
            if (config.account_jid.bare_jid.equals(config.sender_jid.bare_jid)) {
                fail_if(true, @"$mode_label requires two different bare JIDs");
                return null;
            }

            config.expected_file_name = FileTransfer.sanitize_file_name(
                    empty_to_null(Environment.get_variable(name_env)) ?? default_file_name);
            config.payload = payload;
            config.expected_size = config.payload.length;
            config.expected_sha256 = normalize_sha256(Checksum.compute_for_data(ChecksumType.SHA256, config.payload.data));
            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_HOST"));
            config.ready_file = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_READY_FILE"));

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_JINGLE_S5B_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 600) {
                    fail_if(true, "DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 600");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            return config;
        }

        public RemoteJingleS5bSmokeConfig to_receiver_config() {
            RemoteJingleS5bSmokeConfig config = new RemoteJingleS5bSmokeConfig();
            config.account_jid = account_jid;
            config.password = password;
            config.sender_jid = sender_jid;
            config.expected_file_name = expected_file_name;
            config.expected_size = expected_size;
            config.expected_sha256 = expected_sha256;
            config.custom_host = custom_host;
            config.custom_port = custom_port;
            config.timeout_seconds = timeout_seconds;
            config.ready_file = ready_file;
            return config;
        }

        private static string? require_env(string name, string enabled_env) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when $enabled_env=1");
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
}

}
