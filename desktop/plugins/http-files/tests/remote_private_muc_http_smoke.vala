using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Plugins.HttpFiles.Test {

class RemotePrivateMucHttpSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 90;
    private const string MUC_ADMIN_NS_URI = "http://jabber.org/protocol/muc#admin";
    private const string MUC_OWNER_NS_URI = "http://jabber.org/protocol/muc#owner";

    public RemotePrivateMucHttpSmokeTest() {
        base("RemotePrivateMucHttpSmoke");
        add_test("private_muc_unencrypted_http_send_receive_env", test_private_muc_unencrypted_http_send_receive_env_sync);
    }

    private void test_private_muc_unencrypted_http_send_receive_env_sync() {
        RemotePrivateMucHttpSmokeConfig? config = RemotePrivateMucHttpSmokeConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_private_muc_unencrypted_http_send_receive.begin((!) config, (obj, res) => {
            try {
                run_private_muc_unencrypted_http_send_receive.end(res);
            } catch (Error e) {
                fail_if(true, @"Remote private-MUC HTTP file smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_private_muc_unencrypted_http_send_receive(RemotePrivateMucHttpSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-muc-http-smoke-" + Uuid.string_random());
        string? previous_xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
        string? previous_xdg_cache_home = Environment.get_variable("XDG_CACHE_HOME");
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? sender_account = null;
        Account? receiver_account = null;
        Account? extra_receiver_account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        XmppStream? sender_stream = null;
        Xep.Muc.Module? sender_muc_module = null;
        FileProvider? http_provider = null;
        HttpFileSender? http_sender = null;
        FileTransfer? sent_transfer = null;
        FileTransfer? received_transfer = null;
        FileTransfer? extra_received_transfer = null;
        Conversation? receiver_conversation = null;
        Conversation? extra_receiver_conversation = null;
        Error? pending_error = null;
        Error? cleanup_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string storage_dir = configure_isolated_storage(temp_dir);
            db = new Database(Path.build_filename(temp_dir, "dino.db"), "remote-private-muc-http-smoke");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            application = new TestApplication((!) db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            Security.FileEncryption file_encryption = (!) application.file_encryption;
            start_remote_file_modules((!) stream_interactor, (!) db, file_encryption);

            FileManager? file_manager = ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
            if (file_manager == null) {
                throw new IOError.FAILED("FileManager was not started for remote private-MUC HTTP file smoke");
            }
            http_provider = new FileProvider((!) stream_interactor, (!) db);
            http_sender = new HttpFileSender((!) stream_interactor, (!) db);
            ((!) file_manager).add_provider((!) http_provider);
            ((!) file_manager).add_sender((!) http_sender);

            sender_account = new Account(config.sender_jid.bare_jid, config.sender_password);
            ((!) sender_account).enabled = true;
            ((!) sender_account).custom_host = config.custom_host;
            ((!) sender_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) db, (!) sender_account);

            receiver_account = new Account(config.receiver_jid.bare_jid, config.receiver_password);
            ((!) receiver_account).enabled = true;
            ((!) receiver_account).custom_host = config.custom_host;
            ((!) receiver_account).custom_port = config.custom_port;
            persist_remote_smoke_account_without_password((!) db, (!) receiver_account);

            if (config.extra_receiver_jid != null && config.extra_receiver_password != null) {
                extra_receiver_account = new Account(((!) config.extra_receiver_jid).bare_jid, (!) config.extra_receiver_password);
                ((!) extra_receiver_account).enabled = true;
                ((!) extra_receiver_account).custom_host = config.custom_host;
                ((!) extra_receiver_account).custom_port = config.custom_port;
                persist_remote_smoke_account_without_password((!) db, (!) extra_receiver_account);
            }

            seed_trusted_roster_contact((!) db, (!) sender_account, config.receiver_jid);
            seed_trusted_roster_contact((!) db, (!) receiver_account, config.sender_jid);
            if (extra_receiver_account != null && config.extra_receiver_jid != null) {
                seed_trusted_roster_contact((!) db, (!) sender_account, (!) config.extra_receiver_jid);
                seed_trusted_roster_contact((!) db, (!) extra_receiver_account, config.sender_jid);
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

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) {
                throw new IOError.FAILED("MucManager was not started for remote private-MUC HTTP file smoke");
            }
            ConversationManager? conversation_manager = ((!) stream_interactor).get_module<ConversationManager>(ConversationManager.IDENTITY);
            if (conversation_manager == null) {
                throw new IOError.FAILED("ConversationManager was not started for remote private-MUC HTTP file smoke");
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
                throw new IOError.FAILED("remote generated private-MUC config form was not available");
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

            Conversation sender_conversation = ((!) conversation_manager).create_conversation(
                    config.room_jid.bare_jid, (!) sender_account, Conversation.Type.GROUPCHAT);
            sender_conversation.nickname = config.sender_nick;
            sender_conversation.encryption = Encryption.NONE;
            sender_conversation.send_typing = Conversation.Setting.OFF;
            sender_conversation.send_marker = Conversation.Setting.OFF;

            Conversation? maybe_receiver_conversation = ((!) conversation_manager).get_conversation(
                    config.room_jid.bare_jid, (!) receiver_account, Conversation.Type.GROUPCHAT);
            if (maybe_receiver_conversation == null) {
                throw new IOError.FAILED("receiver account did not create the private-MUC conversation after join");
            }
            receiver_conversation = (!) maybe_receiver_conversation;
            if (extra_receiver_account != null) {
                Conversation? maybe_extra_receiver_conversation = ((!) conversation_manager).get_conversation(
                        config.room_jid.bare_jid, (!) extra_receiver_account, Conversation.Type.GROUPCHAT);
                if (maybe_extra_receiver_conversation == null) {
                    throw new IOError.FAILED("extra receiver account did not create the private-MUC conversation after join");
                }
                extra_receiver_conversation = (!) maybe_extra_receiver_conversation;
            }

            Gee.List<Jid>? snapshot = yield ((!) muc_manager).query_private_muc_affiliation_snapshot((!) sender_account, config.room_jid.bare_jid);
            validate_private_muc_snapshot((!) muc_manager, (!) sender_account, config.room_jid.bare_jid, snapshot, config);

            if (!(yield wait_for_upload_available((!) file_manager, sender_conversation, config.timeout_seconds))) {
                throw new IOError.TIMED_OUT("timed out waiting for HTTP upload availability on sender account");
            }

            ulong received_handler = ((!) file_manager).received_file.connect((file_transfer, conversation) => {
                if (!conversation.counterpart.equals_bare(config.room_jid.bare_jid)) return;
                if (Account.equals_func(file_transfer.account, (!) sender_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_SENT) {
                    sent_transfer = file_transfer;
                } else if (Account.equals_func(file_transfer.account, (!) receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
                    received_transfer = file_transfer;
                    receiver_conversation = conversation;
                } else if (extra_receiver_account != null &&
                        Account.equals_func(file_transfer.account, (!) extra_receiver_account) &&
                        file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
                    extra_received_transfer = file_transfer;
                    extra_receiver_conversation = conversation;
                }
            });

            string payload_path = Path.build_filename(temp_dir, config.payload_name);
            FileUtils.set_contents(payload_path, config.payload_text);
            string expected_sha256 = Checksum.compute_for_string(ChecksumType.SHA256, config.payload_text);

            yield ((!) file_manager).send_file(File.new_for_path(payload_path), sender_conversation);
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
                        ((!) extra_received_transfer).phase == FileTransfer.Phase.COMPLETE))))) {
                throw new IOError.TIMED_OUT(@"timed out waiting for remote private-MUC HTTP file-send completion (sent=$(format_transfer_state(sent_transfer)), received=$(format_transfer_state(received_transfer)), extra=$(format_transfer_state(extra_received_transfer)))");
            }

            validate_sent_transfer((!) sent_transfer, sender_conversation, config);
            validate_received_transfer((!) received_transfer, (!) receiver_conversation, config);
            yield validate_stored_payload(file_encryption, (!) received_transfer, config.payload_text.length, expected_sha256);
            if (extra_received_transfer != null && extra_receiver_conversation != null) {
                validate_received_transfer((!) extra_received_transfer, (!) extra_receiver_conversation, config);
                yield validate_stored_payload(file_encryption, (!) extra_received_transfer, config.payload_text.length, expected_sha256);
            }

            if (count_receive_pending_files_for_basename(storage_dir, config.payload_name) != 0) {
                throw new IOError.FAILED("remote private-MUC HTTP receive-store left pending receive files");
            }

            if (received_handler != 0) {
                SignalHandler.disconnect((!) file_manager, received_handler);
                received_handler = 0;
            }
            GLib.Test.message(@"Remote private-MUC HTTP file smoke passed for generated room $(config.room_jid.bare_jid.to_string())");
        } catch (Error e) {
            pending_error = e;
        }

        if (http_provider != null) ((!) http_provider).shutdown();
        if (http_sender != null) ((!) http_sender).shutdown();

        if (sender_stream != null && sender_muc_module != null) {
            try {
                yield ((!) sender_muc_module).destroy_room((!) sender_stream, config.room_jid.bare_jid, "DinoX remote private-MUC HTTP file smoke cleanup");
            } catch (Error e) {
                cleanup_error = e;
                GLib.Test.message(@"Could not destroy generated remote private-MUC HTTP smoke room $(config.room_jid.bare_jid.to_string()): $(e.message)");
                ((!) sender_muc_module).exit((!) sender_stream, config.room_jid.bare_jid);
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
        if (db != null) {
            ((!) db).close();
            db = null;
        }
        restore_env_var("XDG_DATA_HOME", previous_xdg_data_home);
        restore_env_var("XDG_CACHE_HOME", previous_xdg_cache_home);
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote private-MUC HTTP smoke temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, cleanup_error, temp_cleanup_error, config.room_jid.bare_jid, temp_dir);
    }

    private static void start_remote_file_modules(StreamInteractor stream_interactor, Database db, Security.FileEncryption file_encryption) {
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

    private static string configure_isolated_storage(string temp_dir) throws IOError {
        string xdg_data_home = Path.build_filename(temp_dir, "xdg-data");
        string xdg_cache_home = Path.build_filename(temp_dir, "xdg-cache");
        DirUtils.create_with_parents(xdg_data_home, 0700);
        DirUtils.create_with_parents(xdg_cache_home, 0700);
        Environment.set_variable("XDG_DATA_HOME", xdg_data_home, true);
        Environment.set_variable("XDG_CACHE_HOME", xdg_cache_home, true);

        string storage_dir = FileManager.get_storage_dir();
        if (!is_path_at_or_below(storage_dir, xdg_data_home) && !is_meson_test_storage_dir(storage_dir)) {
            throw new IOError.PERMISSION_DENIED(@"remote private-MUC HTTP smoke refuses to use non-test storage directory '$storage_dir'; run through meson test or start the process with an isolated XDG_DATA_HOME");
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

    private static void persist_remote_smoke_account_without_password(Database db, Account account) {
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

    private static void seed_trusted_roster_contact(Database db, Account account, Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, jid.bare_jid.to_string())
            .value(db.roster.subscription, Xmpp.Roster.Item.SUBSCRIPTION_BOTH)
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

    private async void join_generated_room(XmppStream stream, Xep.Muc.Module muc_module, RemotePrivateMucHttpSmokeConfig config) throws Error {
        Xep.Muc.JoinResult? result = yield muc_module.enter(
            stream,
            config.room_jid.bare_jid,
            config.sender_nick,
            null,
            null,
            false,
            null);
        validate_join_result(result, "remote generated private-MUC HTTP sender join");
        if (!((!) result).newly_created) {
            throw new IOError.FAILED(@"remote generated private-MUC HTTP smoke room already existed: $(config.room_jid.bare_jid.to_string())");
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
        if (result == null) throw new IOError.TIMED_OUT("timed out waiting for remote private-MUC receiver join");
        validate_join_result(result, "remote generated private-MUC HTTP receiver join");
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
        set_config_text_if_present(data_form, "muc#roomconfig_roomname", "DinoX remote private-MUC HTTP file smoke");
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
        throw_if_iq_error(result, "set generated private-MUC HTTP smoke config");
    }

    private async void change_affiliation_checked(XmppStream stream, Jid room_jid, Jid member_jid, string affiliation) throws Error {
        StanzaNode item = new StanzaNode.build("item", MUC_ADMIN_NS_URI)
                .put_attribute("affiliation", affiliation, MUC_ADMIN_NS_URI)
                .put_attribute("jid", member_jid.bare_jid.to_string(), MUC_ADMIN_NS_URI);
        StanzaNode query = new StanzaNode.build("query", MUC_ADMIN_NS_URI).add_self_xmlns().put_node(item);
        Iq.Stanza set_iq = new Iq.Stanza.set(query) { to=room_jid.bare_jid };
        Iq.Stanza result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, set_iq);
        throw_if_iq_error(result, @"set generated private-MUC HTTP smoke affiliation for $(member_jid.bare_jid.to_string())");
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
            Gee.List<Jid>? snapshot, RemotePrivateMucHttpSmokeConfig config) throws Error {
        if (snapshot == null) {
            throw new IOError.FAILED("remote private-MUC HTTP smoke snapshot query returned no complete member/admin/owner result");
        }
        if (!muc_manager.has_live_private_room_features(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote private-MUC HTTP smoke room does not have live members-only plus non-anonymous features");
        }
        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(sender_account, room_jid.bare_jid)) {
            throw new IOError.FAILED("remote private-MUC HTTP smoke snapshot did not become complete");
        }
        if (!contains_bare_jid((!) snapshot, config.sender_jid) ||
                !contains_bare_jid((!) snapshot, config.receiver_jid)) {
            throw new IOError.FAILED(@"remote private-MUC HTTP smoke snapshot did not contain sender and receiver: $(format_jids((!) snapshot))");
        }
        if (config.extra_receiver_jid != null && !contains_bare_jid((!) snapshot, (!) config.extra_receiver_jid)) {
            throw new IOError.FAILED(@"remote private-MUC HTTP smoke snapshot did not contain the extra receiver: $(format_jids((!) snapshot))");
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

    private static void validate_sent_transfer(FileTransfer file_transfer, Conversation conversation, RemotePrivateMucHttpSmokeConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote private-MUC HTTP send must publish a persisted outgoing transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_SENT) {
            throw new IOError.FAILED("remote private-MUC HTTP sender transfer must be outgoing");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote private-MUC HTTP sender transfer must target the generated room");
        }
        if (file_transfer.encryption != Encryption.NONE) {
            throw new IOError.FAILED("remote private-MUC HTTP smoke intentionally proves only unencrypted HTTP file sends");
        }
        if (file_transfer.file_name != config.payload_name) {
            throw new IOError.FAILED(@"remote private-MUC HTTP sender file name '$(file_transfer.file_name)' did not match expected payload");
        }
        if (file_transfer.size != config.payload_text.length) {
            throw new IOError.FAILED("remote private-MUC HTTP sender transfer published the wrong plaintext size");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote private-MUC HTTP sender transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"remote private-MUC HTTP sender transfer kept phase error '$(file_transfer.phase_error)'");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            throw new IOError.FAILED("remote private-MUC HTTP sender conversation must be GROUPCHAT");
        }
    }

    private static void validate_received_transfer(FileTransfer file_transfer, Conversation conversation, RemotePrivateMucHttpSmokeConfig config) throws Error {
        if (file_transfer.id == -1) {
            throw new IOError.FAILED("remote private-MUC HTTP receive must publish a persisted incoming transfer");
        }
        if (file_transfer.direction != FileTransfer.DIRECTION_RECEIVED) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must be incoming");
        }
        if (!file_transfer.counterpart.equals_bare(config.room_jid.bare_jid)) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must come from the generated room");
        }
        if (file_transfer.encryption != Encryption.NONE) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must stay unencrypted");
        }
        if (file_transfer.file_name != config.payload_name) {
            throw new IOError.FAILED(@"remote private-MUC HTTP receiver file name '$(file_transfer.file_name)' did not match expected payload");
        }
        if (file_transfer.size != config.payload_text.length) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer published the wrong plaintext size");
        }
        if (file_transfer.state != FileTransfer.State.COMPLETE || file_transfer.phase != FileTransfer.Phase.COMPLETE) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must finish COMPLETE");
        }
        if (file_transfer.phase_error != null) {
            throw new IOError.FAILED(@"remote private-MUC HTTP receiver transfer kept phase error '$(file_transfer.phase_error)'");
        }
        if (file_transfer.path == null || file_transfer.path == "") {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must publish a storage path");
        }
        if (!file_transfer.is_plaintext_release_allowed()) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver transfer must only allow plaintext release after completion");
        }
        if (conversation.type_ != Conversation.Type.GROUPCHAT) {
            throw new IOError.FAILED("remote private-MUC HTTP receiver conversation must be GROUPCHAT");
        }
    }

    private async void validate_stored_payload(Security.FileEncryption file_encryption, FileTransfer file_transfer, int64 expected_size, string expected_sha256) throws Error {
        File? stored_file = file_transfer.get_file();
        if (stored_file == null || !((!) stored_file).query_exists()) {
            throw new IOError.FAILED("remote private-MUC HTTP receive-store must write the verified local file");
        }

        var decrypted_output = new MemoryOutputStream.resizable();
        yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
        uint8[] decrypted = decrypted_output.steal_data();
        decrypted.length = (int) decrypted_output.get_data_size();

        if (decrypted.length != expected_size) {
            throw new IOError.FAILED(@"decrypted remote private-MUC HTTP payload size $(decrypted.length) did not match $(expected_size)");
        }
        string actual_sha256 = Checksum.compute_for_data(ChecksumType.SHA256, decrypted);
        if (actual_sha256.down() != expected_sha256.down()) {
            throw new IOError.FAILED("decrypted remote private-MUC HTTP payload SHA-256 did not match expected payload");
        }
    }

    private static string format_transfer_state(FileTransfer? transfer) {
        if (transfer == null) return "(none)";
        return @"state=$((int) ((!) transfer).state),phase=$((int) ((!) transfer).phase),error=$(((!) transfer).phase_error ?? "none")";
    }

    private static int count_receive_pending_files_for_basename(string storage_dir, string file_name) {
        int count = 0;
        File dir = File.new_for_path(storage_dir);
        try {
            FileEnumerator enumerator = dir.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = enumerator.next_file()) != null) {
                string name = ((!) info).get_name();
                if (name.has_prefix(file_name + ".") && name.has_suffix(".download")) count++;
            }
            enumerator.close();
        } catch (Error e) {
            GLib.Test.message(@"Could not count pending remote private-MUC HTTP receive files: $(e.message)");
        }
        return count;
    }

    private static bool contains_bare_jid(Gee.List<Jid> jids, Jid expected) {
        foreach (Jid jid in jids) {
            if (jid.bare_jid.equals(expected.bare_jid)) return true;
        }
        return false;
    }

    private static string format_jids(Gee.List<Jid> jids) {
        StringBuilder builder = new StringBuilder();
        bool first = true;
        foreach (Jid jid in jids) {
            if (!first) builder.append(", ");
            builder.append(jid.bare_jid.to_string());
            first = false;
        }
        return builder.str;
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

    private class RemotePrivateMucHttpSmokeConfig : Object {
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
        public string sender_nick = "dinox-smoke-sender";
        public string receiver_nick = "dinox-smoke-receiver";
        public string extra_receiver_nick = "dinox-smoke-extra-receiver";
        public string payload_name = "dinox-remote-private-muc-http-smoke.txt";
        public string payload_text = "DinoX remote private-MUC HTTP file smoke payload\n";
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemotePrivateMucHttpSmokeConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_MUC_HTTP_FILE_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_MUC_HTTP_FILE_SMOKE=1 with sender, receiver and MUC service env to run the remote private-MUC HTTP file smoke");
                return null;
            }

            string? sender_env = require_env("DINOX_REMOTE_MUC_FILE_SENDER_JID");
            string? sender_password_env = require_env("DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD");
            string? receiver_env = require_env("DINOX_REMOTE_MUC_FILE_RECEIVER_JID");
            string? receiver_password_env = require_env("DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD");
            string? service_env = require_env("DINOX_REMOTE_MUC_SERVICE");
            string? extra_receiver_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID"));
            string? extra_receiver_password_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD"));
            if (sender_env == null || sender_password_env == null || receiver_env == null ||
                    receiver_password_env == null || service_env == null) {
                return null;
            }
            if ((extra_receiver_env == null) != (extra_receiver_password_env == null)) {
                fail_if(true, "DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID and DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD must be set together");
                return null;
            }

            RemotePrivateMucHttpSmokeConfig config = new RemotePrivateMucHttpSmokeConfig();
            try {
                config.sender_jid = new Jid((!) sender_env);
                config.receiver_jid = new Jid((!) receiver_env);
                if (extra_receiver_env != null) {
                    config.extra_receiver_jid = new Jid((!) extra_receiver_env);
                }
                config.service_jid = new Jid((!) service_env);
                if (config.sender_jid.resourcepart != null || config.receiver_jid.resourcepart != null ||
                        (config.extra_receiver_jid != null && ((!) config.extra_receiver_jid).resourcepart != null)) {
                    fail_if(true, "remote private-MUC HTTP file smoke requires bare sender and receiver account JIDs");
                    return null;
                }
                if (!config.service_jid.is_domain()) {
                    fail_if(true, "DINOX_REMOTE_MUC_SERVICE must be a domain JID such as conference.example.test");
                    return null;
                }
                if (config.sender_jid.bare_jid.equals(config.receiver_jid.bare_jid)) {
                    fail_if(true, "remote private-MUC HTTP file smoke requires distinct sender and receiver accounts");
                    return null;
                }
                if (config.extra_receiver_jid != null &&
                        (config.sender_jid.bare_jid.equals(((!) config.extra_receiver_jid).bare_jid) ||
                        config.receiver_jid.bare_jid.equals(((!) config.extra_receiver_jid).bare_jid))) {
                    fail_if(true, "remote private-MUC HTTP file smoke requires distinct sender, receiver and extra receiver accounts");
                    return null;
                }
                config.sender_password = (!) sender_password_env;
                config.receiver_password = (!) receiver_password_env;
                config.extra_receiver_password = extra_receiver_password_env;

                string room_prefix = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX")) ?? "dinox-remote-muc-http-smoke";
                config.room_jid = new Jid(@"$room_prefix-$(Uuid.string_random())@$(config.service_jid.domainpart)").bare_jid;
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote private-MUC HTTP file smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_HOST"));
            config.sender_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_SENDER_NICK")) ?? config.sender_nick;
            config.receiver_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_RECEIVER_NICK")) ?? config.receiver_nick;
            config.extra_receiver_nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK")) ?? config.extra_receiver_nick;
            config.payload_name = FileTransfer.sanitize_file_name(
                    empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_NAME")) ?? config.payload_name);
            config.payload_text = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT")) ?? config.payload_text;

            string? port_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_PORT"));
            if (port_env != null) {
                int parsed_port = 0;
                if (!int.try_parse((!) port_env, out parsed_port, null, 10) || parsed_port < 1 || parsed_port > 65535) {
                    fail_if(true, "DINOX_REMOTE_MUC_PORT must be an integer between 1 and 65535");
                    return null;
                }
                config.custom_port = parsed_port;
            }

            string? timeout_env = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_TIMEOUT_SECONDS"));
            if (timeout_env != null) {
                uint parsed_timeout = 0;
                if (!uint.try_parse((!) timeout_env, out parsed_timeout, null, 10) || parsed_timeout < 5 || parsed_timeout > 600) {
                    fail_if(true, "DINOX_REMOTE_MUC_TIMEOUT_SECONDS must be an integer between 5 and 600");
                    return null;
                }
                config.timeout_seconds = parsed_timeout;
            }

            return config;
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_MUC_HTTP_FILE_SMOKE=1");
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
        public Database db { get; set; }
        public string? db_key { get; set; }
        public Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public TestApplication(Database db, StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.remote-private-muc-http-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-private-muc-http-smoke-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}
