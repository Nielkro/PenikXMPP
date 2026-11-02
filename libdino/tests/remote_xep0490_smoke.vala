using Gee;
using Xmpp;
using Dino.Entities;

namespace Dino.Test {

/**
 * Opt-in live test for the regular XEP-0490 PEP path.
 *
 * Two independent DinoX stream interactors log in as separate resources of
 * the same account. This catches capability, PEP configuration, live-event,
 * sender-validation, persistence, and fetch-all failures without coupling the
 * normal test suite to a network service.
 */
class RemoteXep0490SmokeTest : Gee.TestCase {
    private const uint DEFAULT_TIMEOUT_SECONDS = 60;

    public RemoteXep0490SmokeTest() {
        base("RemoteXep0490Smoke");
        add_test("regular_pep_same_account_env",
            test_regular_pep_same_account_env_sync);
    }

    private void test_regular_pep_same_account_env_sync() {
        RemoteXep0490Config? config = RemoteXep0490Config.from_env();
        if (config == null) return;

        MainLoop loop = new MainLoop();
        run_regular_pep_same_account.begin((!) config, (_, result) => {
            try {
                run_regular_pep_same_account.end(result);
            } catch (Error error) {
                fail_if_reached("Remote XEP-0490 smoke failed: " +
                    error.message);
            }
            loop.quit();
        });
        loop.run();
    }

    private async void run_regular_pep_same_account(
            RemoteXep0490Config config) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-remote-xep0490-smoke-" + Uuid.string_random());
        Database? publisher_db = null;
        Database? subscriber_db = null;
        StreamInteractor? publisher_interactor = null;
        StreamInteractor? subscriber_interactor = null;
        Account? publisher_account = null;
        Account? subscriber_account = null;
        Xep.MessageDisplayedSynchronization.Module? subscriber_mds = null;
        ulong observed_handler_id = 0;
        Error? pending_error = null;
        Error? cleanup_error = null;

        try {
            string publisher_dir = Path.build_filename(temp_dir,
                "publisher");
            string subscriber_dir = Path.build_filename(temp_dir,
                "subscriber");
            DirUtils.create_with_parents(publisher_dir, 0700);
            DirUtils.create_with_parents(subscriber_dir, 0700);

            publisher_db = new Database(Path.build_filename(publisher_dir,
                "dino.db"), "remote-xep0490-publisher");
            subscriber_db = new Database(Path.build_filename(subscriber_dir,
                "dino.db"), "remote-xep0490-subscriber");
            publisher_interactor = new StreamInteractor.for_tests(
                (!) publisher_db);
            subscriber_interactor = new StreamInteractor.for_tests(
                (!) subscriber_db);
            RemoteXep0490CapsInstaller.start((!) publisher_interactor,
                (!) publisher_db);
            RemoteXep0490CapsInstaller.start((!) subscriber_interactor,
                (!) subscriber_db);

            publisher_account = config.make_account();
            subscriber_account = config.make_account();
            ((!) publisher_account).persist((!) publisher_db);
            ((!) subscriber_account).persist((!) subscriber_db);

            string failure_reason = "";
            if (!(yield connect_and_wait_for_negotiation(
                    (!) subscriber_interactor, (!) subscriber_account,
                    config.timeout_seconds, out failure_reason))) {
                throw new IOError.TIMED_OUT("subscriber " + failure_reason);
            }
            if (!(yield connect_and_wait_for_negotiation(
                    (!) publisher_interactor, (!) publisher_account,
                    config.timeout_seconds, out failure_reason))) {
                throw new IOError.TIMED_OUT("publisher " + failure_reason);
            }

            XmppStream? publisher_stream = ((!) publisher_interactor)
                .get_stream((!) publisher_account);
            XmppStream? subscriber_stream = ((!) subscriber_interactor)
                .get_stream((!) subscriber_account);
            if (publisher_stream == null || subscriber_stream == null) {
                throw new IOError.NOT_CONNECTED(
                    "one of the two DinoX resources has no active stream");
            }

            Xep.MessageDisplayedSynchronization.Module publisher_mds =
                ((!) publisher_stream).get_module<
                    Xep.MessageDisplayedSynchronization.Module>(
                        Xep.MessageDisplayedSynchronization.Module.IDENTITY);
            subscriber_mds =
                ((!) subscriber_stream).get_module<
                    Xep.MessageDisplayedSynchronization.Module>(
                        Xep.MessageDisplayedSynchronization.Module.IDENTITY);

            bool server_assist = yield publisher_mds
                .supports_server_assist((!) publisher_stream);
            GLib.Test.message("Account server-assist feature advertised: %s",
                server_assist ? "yes" : "no");

            Bind.Flag? subscriber_bind = ((!) subscriber_stream).get_flag(
                Bind.Flag.IDENTITY);
            if (subscriber_bind == null) {
                throw new IOError.NOT_CONNECTED(
                    "subscriber resource was not bound");
            }
            Xep.ServiceDiscovery.InfoResult? subscriber_info = yield
                ((!) publisher_stream).get_module<
                    Xep.ServiceDiscovery.Module>(
                        Xep.ServiceDiscovery.Module.IDENTITY)
                    .request_info_fresh((!) publisher_stream,
                        ((!) subscriber_bind).my_jid);
            if (subscriber_info == null ||
                    !((!) subscriber_info).features.contains(
                        Xep.MessageDisplayedSynchronization.NS_URI +
                            "+notify")) {
                throw new IOError.NOT_SUPPORTED(
                    "second DinoX resource did not advertise XEP-0490 +notify");
            }

            if (config.expected_existing != null) {
                Xep.MessageDisplayedSynchronization.FetchResult existing =
                    yield ((!) subscriber_mds).fetch_all(
                        (!) subscriber_stream);
                if (!existing.ok) {
                    throw new IOError.FAILED(
                        "pre-existing interop fetch-all failed: " +
                        (existing.error_condition ?? "unspecified error"));
                }
                var existing_items = new HashMap<string,
                    Xep.MessageDisplayedSynchronization.DisplayedItem>();
                foreach (Xep.MessageDisplayedSynchronization.DisplayedItem
                        item in existing.items) {
                    existing_items[item.chat.to_string()] = item;
                }
                assert_expected_item(existing_items,
                    (!) config.expected_existing,
                    "pre-existing external-client item");
                GLib.Test.message(
                    "DinoX accepted the expected external-client XEP-0490 item");
            }

            var expected = new ArrayList<ExpectedDisplayedItem>();
            string id_prefix = "dinox-live-" + Uuid.string_random();
            expected.add(new ExpectedDisplayedItem(config.contact_jid,
                id_prefix + "-chat", config.account_jid));
            expected.add(new ExpectedDisplayedItem(config.room_jid,
                id_prefix + "-groupchat", config.room_jid));
            expected.add(new ExpectedDisplayedItem(
                config.room_jid.with_resource("peer"),
                id_prefix + "-muc-pm", config.account_jid));

            var observed = new DisplayedItemCollector();
            observed_handler_id = ((!) subscriber_mds).displayed_received
                .connect((stream, item) => {
                    if (stream == subscriber_stream) observed.add(item);
                });

            foreach (ExpectedDisplayedItem item in expected) {
                Xep.MessageDisplayedSynchronization.PublishResult result =
                    yield publisher_mds.publish_displayed(
                        (!) publisher_stream, item.chat, item.stanza_id,
                        item.by);
                if (!result.ok) {
                    string detail = result.unsupported
                        ? "publish-options unsupported"
                        : (result.error_condition ??
                            (result.ambiguous ? "ambiguous transport failure"
                                : "unspecified publish failure"));
                    throw new IOError.FAILED(
                        "regular PEP publish failed: " + detail);
                }
            }

            if (!(yield observed.wait_for_count(expected.size,
                    config.timeout_seconds))) {
                throw new IOError.TIMED_OUT(
                    "second DinoX resource did not receive all live PEP events");
            }
            foreach (ExpectedDisplayedItem item in expected) {
                assert_expected_item(observed.items, item, "live event");
            }

            Xep.MessageDisplayedSynchronization.FetchResult fetched = yield
                ((!) subscriber_mds).fetch_all((!) subscriber_stream);
            if (!fetched.ok) {
                throw new IOError.FAILED("fetch-all failed: " +
                    (fetched.error_condition ?? "unspecified error"));
            }
            var fetched_items = new HashMap<string,
                Xep.MessageDisplayedSynchronization.DisplayedItem>();
            foreach (Xep.MessageDisplayedSynchronization.DisplayedItem item
                    in fetched.items) {
                fetched_items[item.chat.to_string()] = item;
            }
            foreach (ExpectedDisplayedItem item in expected) {
                assert_expected_item(fetched_items, item,
                    "persisted fetch-all item");
            }

            GLib.Test.message(
                "Remote XEP-0490 regular-PEP smoke passed for two DinoX resources and three chat scopes");
        } catch (Error error) {
            pending_error = error;
        }

        if (subscriber_mds != null && observed_handler_id != 0 &&
                SignalHandler.is_connected((!) subscriber_mds,
                    observed_handler_id)) {
            SignalHandler.disconnect((!) subscriber_mds,
                observed_handler_id);
        }
        if (publisher_interactor != null && publisher_account != null) {
            yield ((!) publisher_interactor).connection_manager
                .disconnect_account((!) publisher_account);
        }
        if (subscriber_interactor != null && subscriber_account != null) {
            yield ((!) subscriber_interactor).connection_manager
                .disconnect_account((!) subscriber_account);
        }
        if (publisher_db != null) ((!) publisher_db).close();
        if (subscriber_db != null) ((!) subscriber_db).close();
        try {
            delete_file_tree(File.new_for_path(temp_dir));
        } catch (Error error) {
            cleanup_error = error;
        }

        if (pending_error != null && cleanup_error != null) {
            throw new IOError.FAILED("primary failure: " +
                ((!) pending_error).message + "; credential-bearing temp " +
                "cleanup failure: " + ((!) cleanup_error).message);
        }
        if (pending_error != null) throw (!) pending_error;
        if (cleanup_error != null) throw (!) cleanup_error;
    }

    private static void assert_expected_item(HashMap<string,
            Xep.MessageDisplayedSynchronization.DisplayedItem> items,
            ExpectedDisplayedItem expected, string source) throws Error {
        Xep.MessageDisplayedSynchronization.DisplayedItem? actual =
            items[expected.chat.to_string()];
        if (actual == null ||
                ((!) actual).stanza_id != expected.stanza_id ||
                !((!) actual).by.equals(expected.by)) {
            throw new IOError.FAILED(source +
                " did not preserve chat, stanza-id, and by authority");
        }
    }

    private async bool connect_and_wait_for_negotiation(
            StreamInteractor stream_interactor, Account account,
            uint timeout_seconds, out string failure_reason) {
        failure_reason = "";
        string local_failure_reason = "";
        bool completed = false;
        bool success = false;
        SourceFunc resume = connect_and_wait_for_negotiation.callback;
        uint timeout_id = 0;
        ulong negotiated_id = 0;
        ulong error_id = 0;

        negotiated_id = stream_interactor.stream_negotiated.connect(
                (seen_account, stream) => {
            if (completed || !Account.equals_func(seen_account, account)) {
                return;
            }
            completed = true;
            success = true;
            if (timeout_id != 0) Source.remove(timeout_id);
            if (error_id != 0) SignalHandler.disconnect(
                stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(
                stream_interactor, negotiated_id);
            resume();
        });
        error_id = stream_interactor.connection_manager.connection_error
            .connect((seen_account, error) => {
                if (completed || !Account.equals_func(seen_account,
                        account)) {
                    return;
                }
                completed = true;
                local_failure_reason = format_connection_error(error);
                if (timeout_id != 0) Source.remove(timeout_id);
                if (error_id != 0) SignalHandler.disconnect(
                    stream_interactor.connection_manager, error_id);
                if (negotiated_id != 0) SignalHandler.disconnect(
                    stream_interactor, negotiated_id);
                resume();
            });
        timeout_id = Timeout.add_seconds(timeout_seconds, () => {
            if (completed) return Source.REMOVE;
            completed = true;
            local_failure_reason =
                "timed out waiting for XMPP stream negotiation";
            if (error_id != 0) SignalHandler.disconnect(
                stream_interactor.connection_manager, error_id);
            if (negotiated_id != 0) SignalHandler.disconnect(
                stream_interactor, negotiated_id);
            resume();
            return Source.REMOVE;
        });

        stream_interactor.connect_account(account);
        yield;
        failure_reason = local_failure_reason;
        return success;
    }

    private static string format_connection_error(
            ConnectionManager.ConnectionError error) {
        string text = "XMPP connection error: " +
            error.source.to_string();
        if (error.identifier != null) text += "/" + (!) error.identifier;
        if (error.tls_flags != 0) {
            text += " TLS flags " + error.tls_flags.to_string();
        }
        return text;
    }

    private static void delete_file_tree(File file) throws Error {
        FileType type = file.query_file_type(
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
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

    private class DisplayedItemCollector : Object {
        public signal void changed();
        public HashMap<string,
            Xep.MessageDisplayedSynchronization.DisplayedItem> items =
                new HashMap<string,
                    Xep.MessageDisplayedSynchronization.DisplayedItem>();

        public void add(
                Xep.MessageDisplayedSynchronization.DisplayedItem item) {
            items[item.chat.to_string()] = item;
            changed();
        }

        public async bool wait_for_count(int expected_count,
                uint timeout_seconds) {
            if (items.size >= expected_count) return true;

            bool completed = false;
            bool success = false;
            SourceFunc resume = wait_for_count.callback;
            uint timeout_id = 0;
            ulong changed_id = 0;
            changed_id = changed.connect(() => {
                if (completed || items.size < expected_count) return;
                completed = true;
                success = true;
                if (timeout_id != 0) Source.remove(timeout_id);
                if (changed_id != 0) SignalHandler.disconnect(this,
                    changed_id);
                resume();
            });
            timeout_id = Timeout.add_seconds(timeout_seconds, () => {
                if (completed) return Source.REMOVE;
                completed = true;
                if (changed_id != 0) SignalHandler.disconnect(this,
                    changed_id);
                resume();
                return Source.REMOVE;
            });

            yield;
            return success;
        }
    }

    private class ExpectedDisplayedItem : Object {
        public Jid chat;
        public string stanza_id;
        public Jid by;

        public ExpectedDisplayedItem(Jid chat, string stanza_id, Jid by) {
            this.chat = chat;
            this.stanza_id = stanza_id;
            this.by = by;
        }
    }

    /** Minimal entity-caps wiring without starting unrelated app services. */
    private class RemoteXep0490CapsInstaller : Object,
            StreamInteractionModule {
        private static ModuleIdentity<RemoteXep0490CapsInstaller> IDENTITY =
            new ModuleIdentity<RemoteXep0490CapsInstaller>(
                "remote_xep0490_caps_installer");
        public string id { get { return IDENTITY.id; } }

        private StreamInteractor stream_interactor;
        private EntityCapabilitiesStorage storage;

        public static void start(StreamInteractor stream_interactor,
                Database db) {
            stream_interactor.add_module(new RemoteXep0490CapsInstaller(
                stream_interactor, db));
        }

        private RemoteXep0490CapsInstaller(
                StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.storage = new EntityCapabilitiesStorage(db);
            stream_interactor.account_added.connect(on_account_added);
            stream_interactor.module_manager.initialize_account_modules
                .connect(initialize_modules);
        }

        private void on_account_added(Account account) {
            Xep.ServiceDiscovery.Module discovery = stream_interactor
                .module_manager.get_module<Xep.ServiceDiscovery.Module>(
                    account, Xep.ServiceDiscovery.Module.IDENTITY);
            discovery.cache = new RemoteXep0490CapsCache(
                stream_interactor, account);
        }

        private void initialize_modules(Account _account,
                ArrayList<XmppStreamModule> modules) {
            modules.add(new Xep.EntityCapabilities.Module(storage));
        }
    }

    /** Live disco cache used only by the opt-in remote test. */
    private class RemoteXep0490CapsCache : Object,
            Xep.ServiceDiscovery.CapsCache {
        private StreamInteractor stream_interactor;
        private Account account;

        public RemoteXep0490CapsCache(StreamInteractor stream_interactor,
                Account account) {
            this.stream_interactor = stream_interactor;
            this.account = account;
        }

        public async bool has_entity_feature(Jid jid, string feature) {
            Xep.ServiceDiscovery.InfoResult? info = yield request_info(jid);
            return info != null && ((!) info).features.contains(feature);
        }

        public async Gee.Set<Xep.ServiceDiscovery.Identity>
                get_entity_identities(Jid jid) {
            Xep.ServiceDiscovery.InfoResult? info = yield request_info(jid);
            if (info != null) return ((!) info).identities;
            return new HashSet<Xep.ServiceDiscovery.Identity>();
        }

        private async Xep.ServiceDiscovery.InfoResult? request_info(Jid jid) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return null;
            return yield ((!) stream).get_module<
                Xep.ServiceDiscovery.Module>(
                    Xep.ServiceDiscovery.Module.IDENTITY)
                .request_info_fresh((!) stream, jid);
        }
    }

    private class RemoteXep0490Config : Object {
        public Jid account_jid;
        public string password;
        public Jid contact_jid;
        public Jid room_jid;
        public string? custom_host;
        public int custom_port;
        public uint timeout_seconds = DEFAULT_TIMEOUT_SECONDS;
        public ExpectedDisplayedItem? expected_existing;

        public Account make_account() {
            var account = new Account(account_jid, password);
            account.enabled = true;
            account.custom_host = custom_host;
            account.custom_port = custom_port;
            return account;
        }

        public static RemoteXep0490Config? from_env() {
            if (Environment.get_variable("DINOX_REMOTE_XEP0490_SMOKE") !=
                    "1") {
                GLib.Test.skip(
                    "Set DINOX_REMOTE_XEP0490_SMOKE=1 with JID, password, contact, and room variables to run the live test");
                return null;
            }

            string? account = require_env("DINOX_REMOTE_XEP0490_JID");
            string? password = require_env(
                "DINOX_REMOTE_XEP0490_PASSWORD");
            string? contact = require_env(
                "DINOX_REMOTE_XEP0490_CONTACT");
            string? room = require_env("DINOX_REMOTE_XEP0490_ROOM");
            if (account == null || password == null || contact == null ||
                    room == null) {
                return null;
            }

            try {
                var config = new RemoteXep0490Config();
                config.account_jid = new Jid((!) account).bare_jid;
                config.password = (!) password;
                config.contact_jid = new Jid((!) contact).bare_jid;
                config.room_jid = new Jid((!) room).bare_jid;
                config.custom_host = empty_to_null(Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_HOST"));

                string? port = Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_PORT");
                if (port != null && ((!) port).strip() != "") {
                    int parsed_port;
                    if (!int.try_parse((!) port, out parsed_port) ||
                            parsed_port < 1 || parsed_port > 65535) {
                        fail_if(true,
                            "DINOX_REMOTE_XEP0490_PORT must be between 1 and 65535");
                        return null;
                    }
                    config.custom_port = parsed_port;
                }

                string? timeout = Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS");
                if (timeout != null && ((!) timeout).strip() != "") {
                    uint parsed_timeout;
                    if (!uint.try_parse((!) timeout, out parsed_timeout) ||
                            parsed_timeout < 5 || parsed_timeout > 600) {
                        fail_if(true,
                            "DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS must be between 5 and 600");
                        return null;
                    }
                    config.timeout_seconds = parsed_timeout;
                }

                string? expected_chat = Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_EXPECTED_CHAT");
                string? expected_id = Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_EXPECTED_ID");
                string? expected_by = Environment.get_variable(
                    "DINOX_REMOTE_XEP0490_EXPECTED_BY");
                int expected_parts = (expected_chat != null ? 1 : 0) +
                    (expected_id != null ? 1 : 0) +
                    (expected_by != null ? 1 : 0);
                if (expected_parts != 0 && expected_parts != 3) {
                    fail_if(true,
                        "EXPECTED_CHAT, EXPECTED_ID, and EXPECTED_BY must be set together");
                    return null;
                }
                if (expected_parts == 3) {
                    string id = ((!) expected_id).strip();
                    Jid by = new Jid((!) expected_by);
                    if (id == "" || !by.is_bare()) {
                        fail_if(true,
                            "EXPECTED_ID must be non-empty and EXPECTED_BY must be bare");
                        return null;
                    }
                    config.expected_existing = new ExpectedDisplayedItem(
                        new Jid((!) expected_chat), id, by);
                }
                return config;
            } catch (InvalidJidError error) {
                fail_if(true, "Remote XEP-0490 JID configuration is invalid: " +
                    error.message);
                return null;
            }
        }

        private static string? require_env(string name) {
            string? value = Environment.get_variable(name);
            if (value == null || ((!) value).strip() == "") {
                fail_if(true, name +
                    " must be set when DINOX_REMOTE_XEP0490_SMOKE=1");
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
