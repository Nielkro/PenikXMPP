using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Test {

class RemotePrivateMucSmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 60;
    private const string MUC_OWNER_NS_URI = "http://jabber.org/protocol/muc#owner";

    public RemotePrivateMucSmokeTest() {
        base("RemotePrivateMucSmoke");
        add_test("private_muc_affiliation_snapshot_env", test_private_muc_affiliation_snapshot_env_sync);
        add_test("private_muc_bootstrap_affiliation_snapshot_env", test_private_muc_bootstrap_affiliation_snapshot_env_sync);
    }

    private void test_private_muc_affiliation_snapshot_env_sync() {
        RemotePrivateMucSmokeConfig? config = RemotePrivateMucSmokeConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_private_muc_affiliation_snapshot.begin((!) config, (obj, res) => {
            try {
                run_private_muc_affiliation_snapshot.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote private-MUC affiliation smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private void test_private_muc_bootstrap_affiliation_snapshot_env_sync() {
        RemotePrivateMucBootstrapConfig? config = RemotePrivateMucBootstrapConfig.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_private_muc_bootstrap_affiliation_snapshot.begin((!) config, (obj, res) => {
            try {
                run_private_muc_bootstrap_affiliation_snapshot.end(res);
            } catch (Error e) {
                fail_if_reached(@"Remote private-MUC bootstrap smoke failed: $(e.message)");
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_private_muc_affiliation_snapshot(RemotePrivateMucSmokeConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-muc-smoke-" + Uuid.string_random());
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        Error? pending_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(Path.build_filename(temp_dir, "dino.db"), "remote-private-muc-smoke");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            application = new TestApplication((!) db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            start_minimal_muc_modules((!) stream_interactor, (!) db);

            account = new Account(config.account_jid.bare_jid, config.password);
            ((!) account).enabled = true;
            ((!) account).custom_host = config.custom_host;
            ((!) account).custom_port = config.custom_port;
            ((!) account).persist((!) db);

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) {
                throw new IOError.FAILED("MucManager was not started");
            }

            if (config.join_before_query) {
                yield join_room((!) muc_manager, (!) account, config);
            }

            Gee.List<Jid>? snapshot = yield ((!) muc_manager).query_private_muc_affiliation_snapshot((!) account, config.room_jid.bare_jid);
            if (snapshot == null) {
                throw new IOError.FAILED("remote private-MUC affiliation snapshot query returned no complete member/admin/owner result");
            }
            if (!((!) muc_manager).has_live_private_room_features((!) account, config.room_jid.bare_jid)) {
                throw new IOError.FAILED("remote room does not have live members-only plus non-anonymous features");
            }
            if (!((!) muc_manager).has_complete_private_muc_affiliation_snapshot((!) account, config.room_jid.bare_jid)) {
                throw new IOError.FAILED("remote private-MUC affiliation snapshot did not become complete");
            }

            Gee.List<Jid>? cached_snapshot = ((!) muc_manager).get_private_muc_member_affiliation_snapshot((!) account, config.room_jid.bare_jid);
            if (cached_snapshot == null) {
                throw new IOError.FAILED("completed remote private-MUC affiliation snapshot was not cached");
            }

            foreach (Jid expected_member in config.expected_members) {
                if (!contains_bare_jid((!) snapshot, expected_member)) {
                    throw new IOError.FAILED(@"expected remote member $(expected_member.bare_jid.to_string()) missing from live snapshot $(format_jids((!) snapshot))");
                }
                if (!contains_bare_jid((!) cached_snapshot, expected_member)) {
                    throw new IOError.FAILED(@"expected remote member $(expected_member.bare_jid.to_string()) missing from cached snapshot $(format_jids((!) cached_snapshot))");
                }
            }
        } catch (Error e) {
            pending_error = e;
        }

        if (stream_interactor != null && account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) account);
        }
        restore_default_application(application, previous_application);
        if (db != null) {
            ((!) db).close();
            db = null;
        }
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote private-MUC smoke temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, null, temp_cleanup_error, null, temp_dir);
    }

    private async void run_private_muc_bootstrap_affiliation_snapshot(RemotePrivateMucBootstrapConfig config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-remote-muc-bootstrap-smoke-" + Uuid.string_random());
        Database? db = null;
        StreamInteractor? stream_interactor = null;
        Account? account = null;
        TestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        XmppStream? stream = null;
        Xep.Muc.Module? muc_module = null;
        bool joined_room = false;
        Error? pending_error = null;
        Error? cleanup_error = null;
        Error? temp_cleanup_error = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(Path.build_filename(temp_dir, "dino.db"), "remote-private-muc-bootstrap-smoke");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            application = new TestApplication((!) db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            start_minimal_muc_modules((!) stream_interactor, (!) db);

            account = new Account(config.account_jid.bare_jid, config.password);
            ((!) account).enabled = true;
            ((!) account).custom_host = config.custom_host;
            ((!) account).custom_port = config.custom_port;
            ((!) account).persist((!) db);

            string connect_failure = "";
            if (!(yield connect_and_wait_for_negotiation((!) stream_interactor, (!) account, config.timeout_seconds, out connect_failure))) {
                throw new IOError.TIMED_OUT(connect_failure);
            }

            MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager == null) {
                throw new IOError.FAILED("MucManager was not started");
            }

            stream = ((!) stream_interactor).get_stream((!) account);
            if (stream == null) {
                throw new IOError.NOT_CONNECTED("No active stream after XMPP negotiation");
            }
            muc_module = ((!) stream).get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            if (muc_module == null) {
                throw new IOError.FAILED("XEP-0045 MUC module is not attached");
            }

            yield join_generated_room((!) stream, (!) muc_module, config);
            joined_room = true;

            Xep.DataForms.DataForm? data_form = yield ((!) muc_module).get_config_form((!) stream, config.room_jid.bare_jid);
            if (data_form == null) {
                throw new IOError.FAILED("remote generated private-MUC config form was not available");
            }
            configure_generated_private_room((!) data_form);
            yield set_config_form_checked((!) stream, config.room_jid.bare_jid, (!) data_form);

            foreach (Jid member_jid in config.member_jids) {
                yield change_affiliation_checked((!) stream, config.room_jid.bare_jid, member_jid.bare_jid, "member");
            }

            Gee.List<Jid>? snapshot = yield ((!) muc_manager).query_private_muc_affiliation_snapshot((!) account, config.room_jid.bare_jid);
            if (snapshot == null) {
                throw new IOError.FAILED("generated private-MUC affiliation snapshot query returned no complete member/admin/owner result");
            }
            if (!((!) muc_manager).has_live_private_room_features((!) account, config.room_jid.bare_jid)) {
                throw new IOError.FAILED("generated remote room does not have live members-only plus non-anonymous features");
            }
            if (!((!) muc_manager).has_complete_private_muc_affiliation_snapshot((!) account, config.room_jid.bare_jid)) {
                throw new IOError.FAILED("generated remote private-MUC affiliation snapshot did not become complete");
            }

            Gee.List<Jid>? cached_snapshot = ((!) muc_manager).get_private_muc_member_affiliation_snapshot((!) account, config.room_jid.bare_jid);
            if (cached_snapshot == null) {
                throw new IOError.FAILED("completed generated remote private-MUC affiliation snapshot was not cached");
            }

            foreach (Jid expected_member in config.expected_members) {
                if (!contains_bare_jid((!) snapshot, expected_member)) {
                    throw new IOError.FAILED(@"expected generated remote member $(expected_member.bare_jid.to_string()) missing from live snapshot $(format_jids((!) snapshot))");
                }
                if (!contains_bare_jid((!) cached_snapshot, expected_member)) {
                    throw new IOError.FAILED(@"expected generated remote member $(expected_member.bare_jid.to_string()) missing from cached snapshot $(format_jids((!) cached_snapshot))");
                }
            }

            GLib.Test.message(@"Generated remote private-MUC bootstrap smoke passed for room $(config.room_jid.bare_jid.to_string())");
        } catch (Error e) {
            pending_error = e;
        }

        if (stream != null && muc_module != null) {
            try {
                yield ((!) muc_module).destroy_room((!) stream, config.room_jid.bare_jid, "DinoX remote private-MUC bootstrap smoke cleanup");
            } catch (Error e) {
                cleanup_error = e;
                GLib.Test.message(@"Could not destroy generated remote private-MUC room $(config.room_jid.bare_jid.to_string()): $(e.message)");
                if (joined_room) {
                    ((!) muc_module).exit((!) stream, config.room_jid.bare_jid);
                }
            }
        }
        if (stream_interactor != null && account != null) {
            yield ((!) stream_interactor).connection_manager.disconnect_account((!) account);
        }
        restore_default_application(application, previous_application);
        if (db != null) {
            ((!) db).close();
            db = null;
        }
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error e) {
            temp_cleanup_error = e;
            GLib.Test.message(@"Could not clean remote private-MUC bootstrap smoke temp dir: $(e.message)");
        }

        throw_final_errors(pending_error, cleanup_error, temp_cleanup_error, config.room_jid.bare_jid, temp_dir);
    }

    private static void start_minimal_muc_modules(StreamInteractor stream_interactor, Database db) {
        MessageStorage.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        MessageProcessor.start(stream_interactor, db);
        EntityInfo.start(stream_interactor, db);
        RosterManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor);
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

    private async void join_generated_room(XmppStream stream, Xep.Muc.Module muc_module, RemotePrivateMucBootstrapConfig config) throws Error {
        Xmpp.Xep.Muc.JoinResult? result = yield muc_module.enter(
            stream,
            config.room_jid.bare_jid,
            config.nick,
            null,
            null,
            false,
            null);
        validate_join_result(result, "remote generated private-MUC join");
        if (!((!) result).newly_created) {
            throw new IOError.FAILED(@"remote generated private-MUC room already existed: $(config.room_jid.bare_jid.to_string())");
        }
    }

    private async void join_room(MucManager muc_manager, Account account, RemotePrivateMucSmokeConfig config) throws Error {
        Xmpp.Xep.Muc.JoinResult? result = yield muc_manager.join(
            account,
            config.room_jid.bare_jid,
            config.nick ?? account.localpart,
            config.room_password,
            true);
        validate_join_result(result, "remote private-MUC join");
    }

    private static void validate_join_result(Xmpp.Xep.Muc.JoinResult? result, string context) throws Error {
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
        set_config_text_if_present(data_form, "muc#roomconfig_roomname", "DinoX remote private-MUC bootstrap smoke");
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
        throw_if_iq_error(result, "set generated private-MUC config");
    }

    private async void change_affiliation_checked(XmppStream stream, Jid room_jid, Jid member_jid, string affiliation) throws Error {
        Xep.Muc.Module? module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_CONNECTED("XEP-0045 MUC module is not attached");
        // Exercise the checked room-admin mutation used by the application.
        // Its acknowledged result updates the cached affiliation baseline;
        // sending a raw IQ leaves the earlier join snapshot stale.
        yield ((!) module).change_affiliation(stream, room_jid.bare_jid,
            member_jid.bare_jid, null, affiliation);
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

    private class RemotePrivateMucSmokeConfig : Object {
        public Jid account_jid;
        public string password;
        public Jid room_jid;
        public ArrayList<Jid> expected_members = new ArrayList<Jid>(Jid.equals_bare_func);
        public string? custom_host = null;
        public int custom_port = 0;
        public string? nick = null;
        public string? room_password = null;
        public bool join_before_query = false;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemotePrivateMucSmokeConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_MUC_SMOKE") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_MUC_SMOKE=1 with DINOX_REMOTE_MUC_JID, DINOX_REMOTE_MUC_PASSWORD, DINOX_REMOTE_MUC_ROOM and DINOX_REMOTE_MUC_EXPECTED_MEMBERS to run the remote private-MUC smoke");
                return null;
            }

            string? account_env = require_env("DINOX_REMOTE_MUC_JID");
            string? password_env = require_env("DINOX_REMOTE_MUC_PASSWORD");
            string? room_env = require_env("DINOX_REMOTE_MUC_ROOM");
            string? expected_env = require_env("DINOX_REMOTE_MUC_EXPECTED_MEMBERS");
            if (account_env == null || password_env == null || room_env == null || expected_env == null) return null;

            RemotePrivateMucSmokeConfig config = new RemotePrivateMucSmokeConfig();
            try {
                config.account_jid = new Jid((!) account_env);
                config.room_jid = new Jid((!) room_env).bare_jid;
                config.password = (!) password_env;
                if (!parse_expected_members((!) expected_env, config.expected_members)) return null;
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote private-MUC smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_HOST"));
            config.nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_NICK"));
            config.room_password = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_ROOM_PASSWORD"));
            config.join_before_query = Environment.get_variable("DINOX_REMOTE_MUC_JOIN") == "1";

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
                fail_if(true, @"$name must be set when DINOX_REMOTE_MUC_SMOKE=1");
                return null;
            }
            return value;
        }

        private static bool parse_expected_members(string expected_env, ArrayList<Jid> expected_members) throws InvalidJidError {
            foreach (string raw_part in expected_env.split(",")) {
                string part = raw_part.strip();
                if (part == "") continue;
                Jid jid = new Jid(part).bare_jid;
                if (!expected_members.contains(jid)) expected_members.add(jid);
            }
            if (expected_members.size == 0) {
                fail_if(true, "DINOX_REMOTE_MUC_EXPECTED_MEMBERS must contain at least one bare JID");
                return false;
            }
            return true;
        }

        private static string? empty_to_null(string? value) {
            if (value == null) return null;
            string stripped = ((!) value).strip();
            return stripped == "" ? null : stripped;
        }
    }

    private class RemotePrivateMucBootstrapConfig : Object {
        public Jid account_jid;
        public string password;
        public Jid service_jid;
        public Jid room_jid;
        public ArrayList<Jid> member_jids = new ArrayList<Jid>(Jid.equals_bare_func);
        public ArrayList<Jid> expected_members = new ArrayList<Jid>(Jid.equals_bare_func);
        public string? custom_host = null;
        public int custom_port = 0;
        public string nick = "dinox-smoke-owner";
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;

        public static RemotePrivateMucBootstrapConfig? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_MUC_BOOTSTRAP") != "1") {
                GLib.Test.skip("Set DINOX_REMOTE_MUC_BOOTSTRAP=1 with DINOX_REMOTE_MUC_JID, DINOX_REMOTE_MUC_PASSWORD, DINOX_REMOTE_MUC_SERVICE and DINOX_REMOTE_MUC_MEMBER_JIDS to run the remote private-MUC bootstrap smoke");
                return null;
            }

            string? account_env = require_env("DINOX_REMOTE_MUC_JID");
            string? password_env = require_env("DINOX_REMOTE_MUC_PASSWORD");
            string? service_env = require_env("DINOX_REMOTE_MUC_SERVICE");
            string? members_env = require_env("DINOX_REMOTE_MUC_MEMBER_JIDS");
            if (account_env == null || password_env == null || service_env == null || members_env == null) return null;

            RemotePrivateMucBootstrapConfig config = new RemotePrivateMucBootstrapConfig();
            try {
                config.account_jid = new Jid((!) account_env);
                config.service_jid = new Jid((!) service_env);
                if (!config.service_jid.is_domain()) {
                    fail_if(true, "DINOX_REMOTE_MUC_SERVICE must be a domain JID such as conference.example.test");
                    return null;
                }
                config.password = (!) password_env;
                if (!parse_member_jids((!) members_env, config.member_jids)) return null;

                config.add_expected_member(config.account_jid.bare_jid);
                foreach (Jid member_jid in config.member_jids) {
                    config.add_expected_member(member_jid.bare_jid);
                }

                string room_prefix = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX")) ?? "dinox-remote-muc-smoke";
                config.room_jid = new Jid(@"$room_prefix-$(Uuid.string_random())@$(config.service_jid.domainpart)").bare_jid;
            } catch (InvalidJidError e) {
                fail_if(true, @"Remote private-MUC bootstrap smoke env contains an invalid JID: $(e.message)");
                return null;
            }

            config.custom_host = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_HOST"));
            config.nick = empty_to_null(Environment.get_variable("DINOX_REMOTE_MUC_NICK")) ?? config.nick;

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

        private void add_expected_member(Jid jid) {
            if (!expected_members.contains(jid.bare_jid)) expected_members.add(jid.bare_jid);
        }

        private static string? require_env(string name) {
            string? value = empty_to_null(Environment.get_variable(name));
            if (value == null) {
                fail_if(true, @"$name must be set when DINOX_REMOTE_MUC_BOOTSTRAP=1");
                return null;
            }
            return value;
        }

        private static bool parse_member_jids(string members_env, ArrayList<Jid> member_jids) throws InvalidJidError {
            foreach (string raw_part in members_env.split(",")) {
                string part = raw_part.strip();
                if (part == "") continue;
                Jid jid = new Jid(part).bare_jid;
                if (!member_jids.contains(jid)) member_jids.add(jid);
            }
            if (member_jids.size == 0) {
                fail_if(true, "DINOX_REMOTE_MUC_MEMBER_JIDS must contain at least one bare JID");
                return false;
            }
            return true;
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
            Object(application_id: "im.dinox.remote-private-muc-smoke-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "remote-private-muc-smoke-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}
