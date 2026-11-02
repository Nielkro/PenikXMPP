using Dino;
using Dino.Entities;
using Dino.Plugins.BotFeatures;
using Xmpp;

private const string PROFILE_KEY = "isolated-plugin-lifecycle-key";

class LifecycleApplication : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public string? db_key { get; set; }
    public Dino.Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }

    public LifecycleApplication() throws Error {
        Object(application_id: "im.dinox.bot-plugin-lifecycle-test", flags: ApplicationFlags.NON_UNIQUE);
        db = new Dino.Database(":memory:", PROFILE_KEY);
        db_key = PROFILE_KEY;
        file_encryption = new Dino.Security.FileEncryption(PROFILE_KEY);
        settings = new Dino.Entities.Settings.from_db(db);
        stream_interactor = new StreamInteractor.for_tests(db);
        MessageProcessor.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        RosterManager.start(stream_interactor, db);
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) {}
}

class LifecyclePipeline : MessageListenerHolder {
    public int count { get { return listeners.size; } }
}

class LifecycleTlsStream : TlsXmppStream {
    public int disconnects = 0;
    public int setups = 0;
    public LifecycleTlsStream() throws Error { base(new Jid("example.test")); }
    public override async void connect() throws IOError {}
    public override async void disconnect() throws IOError { disconnects++; }
    public override async void setup() throws IOError { setups++; }
    public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("No network in fixture"); }
    public override async void write_async(StanzaNode node, int priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {}
}

class LifecyclePool : SessionPool {
    public int attempts = 0;
    public bool hold_connect = false;
    public LifecycleTlsStream? held_stream;
    private SourceFunc? continuation;

    public LifecyclePool(Dino.Application app) { base(app); }

    protected override async XmppStreamResult establish_dedicated_stream(
            Jid jid, Gee.List<XmppStreamModule> modules) {
        attempts++;
        if (hold_connect) {
            continuation = establish_dedicated_stream.callback;
            yield;
            return new XmppStreamResult() { stream = held_stream };
        }
        // Register this expected diagnostic immediately before returning the
        // fake transport failure. Earlier startup progress messages must not
        // be mistaken for a missing warning by GLib's ordered expectation queue.
        Test.expect_message("bot-features", LogLevelFlags.LEVEL_WARNING,
            "*Failed to connect bot*Isolated connection boundary*");
        return new XmppStreamResult() { io_error = new IOError.NOT_CONNECTED("Isolated connection boundary") };
    }

    public void complete_held_connect() {
        assert(continuation != null);
        SourceFunc resume = (owned) continuation;
        resume();
    }
}

class LifecyclePlugin : Plugin {
    public Gee.ArrayList<LifecyclePool> pools = new Gee.ArrayList<LifecyclePool>();
    protected override SessionPool create_session_pool() {
        var pool = new LifecyclePool(app);
        pools.add(pool);
        return pool;
    }
}

void wait_milliseconds(uint milliseconds) {
    bool finished = false;
    Timeout.add(milliseconds, () => { finished = true; return Source.REMOVE; });
    while (!finished) MainContext.default().iteration(true);
}

Soup.Server reserve_loopback_port() throws Error {
    var server = new Soup.Server("server-header", "DinoX-lifecycle-test", null);
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    return server;
}

uint16 port_of(Soup.Server server) { return (uint16) server.get_uris().data.get_port(); }

uint16 unused_port() throws Error {
    var reservation = reserve_loopback_port();
    uint16 port = port_of(reservation);
    reservation.disconnect();
    return port;
}

bool api_healthy(uint16 port) {
    var session = new Soup.Session() { timeout = 1 };
    session.proxy_resolver = new SimpleProxyResolver(null, null);
    var request = new Soup.Message("GET", "http://127.0.0.1:%u/health".printf(port));
    bool done = false;
    bool healthy = false;
    session.send_and_read_async.begin(request, Priority.DEFAULT, null, (obj, result) => {
        try {
            Bytes body = session.send_and_read_async.end(result);
            var parser = new Json.Parser();
            parser.load_from_data((string) body.get_data(), (ssize_t) body.get_size());
            Json.Object response = parser.get_root().get_object();
            healthy = request.status_code == 200 && response.has_member("status") &&
                response.get_string_member("status") == "ok";
        } catch (Error e) { healthy = false; }
        done = true;
    });
    while (!done) MainContext.default().iteration(true);
    return healthy;
}

string bot_database_path() {
    return Path.build_filename(Dino.Application.get_storage_dir(), "bot_registry.db");
}

int seed_dedicated_bot() throws Error {
    var registry = new BotRegistry(bot_database_path(), PROFILE_KEY);
    new TokenManager(registry);
    int id = registry.create_bot("Isolated dedicated", "owner@example.test", "isolated-token-hash",
        "dedicated", "bot@example.test");
    registry.update_bot_password(id, "disposable-fixture-password");
    registry.close();
    return id;
}

long omemo_identity_count() throws Error {
    var registry = Qlite.Database.open_existing(bot_database_path(), PROFILE_KEY);
    try {
        return long.parse(registry.query_column_checked(
            "SELECT count(*) FROM settings WHERE key LIKE 'omemo_ik_pub:%'")[0]);
    } finally { registry.close(); }
}

LifecyclePipeline set_counted_pipeline(LifecycleApplication app) {
    var pipeline = new LifecyclePipeline();
    app.stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline = pipeline;
    return pipeline;
}

// A real plugin intentionally retains its registry and setting watchers for
// later activation. Run each case in a child; the parent removes its private
// profile only after all native database handles in that child are closed.
bool run_in_child() {
    if (Test.subprocess()) return true;
    Test.trap_subprocess(null, 15 * TimeSpan.SECOND, (TestSubprocessFlags) 0);
    Test.trap_assert_passed();
    try {
        Dino.Security.ProfileDeletion.delete_tree(File.new_for_path(Dino.Application.get_storage_dir()));
        assert(DirUtils.create_with_parents(Dino.Application.get_storage_dir(), 0700) == 0);
    } catch (Error e) { Test.message("Isolated cleanup failed: %s", e.message); Test.fail(); }
    return false;
}

void test_disable_before_delayed_connect() {
    if (!run_in_child()) return;
    try {
        seed_dedicated_bot();
        var app = new LifecycleApplication();
        var pipeline = set_counted_pipeline(app);
        app.settings.api_port = unused_port();
        app.settings.bot_features_enabled = true;
        var plugin = new LifecyclePlugin();
        plugin.registered(app);
        assert(pipeline.count == 1 && plugin.pools.size == 1);
        app.settings.bot_features_enabled = false;
        assert(pipeline.count == 0);
        wait_milliseconds(5200);
        assert(plugin.pools[0].attempts == 0);
        assert(omemo_identity_count() == 0);
        assert(!api_healthy((uint16) app.settings.api_port));
        plugin.shutdown();
        app.db.close();
    } catch (Error e) { Test.message("Unexpected fixture failure: %s", e.message); Test.fail(); }
}

void test_rapid_activation_uses_only_current_runtime() {
    if (!run_in_child()) return;
    try {
        seed_dedicated_bot();
        var app = new LifecycleApplication();
        var pipeline = set_counted_pipeline(app);
        app.settings.api_port = unused_port();
        var plugin = new LifecyclePlugin();
        plugin.registered(app);
        assert(plugin.pools.size == 0 && pipeline.count == 0);
        app.settings.bot_features_enabled = true;
        app.settings.bot_features_enabled = false;
        app.settings.bot_features_enabled = true;
        assert(plugin.pools.size == 2 && pipeline.count == 1);
        wait_milliseconds(5200);
        Test.assert_expected_messages();
        assert(plugin.pools[0].attempts == 0);
        assert(plugin.pools[1].attempts == 1);
        assert(omemo_identity_count() == 1);
        plugin.pools[0].connect_all_dedicated();
        assert(plugin.pools[0].attempts == 0);
        assert(api_healthy((uint16) app.settings.api_port));
        app.settings.bot_features_enabled = false;
        assert(pipeline.count == 0);
        app.db.close();
    } catch (Error e) { Test.message("Unexpected fixture failure: %s", e.message); Test.fail(); }
}

void test_corrected_api_port_recovers_without_reinitialization() {
    if (!run_in_child()) return;
    try {
        var reservation = reserve_loopback_port();
        // Prepare normal registry startup before expecting the deliberate bind
        // failure, so its HMAC progress message is outside that expectation.
        var seed = new BotRegistry(bot_database_path(), PROFILE_KEY);
        new TokenManager(seed);
        seed.close();
        var app = new LifecycleApplication();
        var pipeline = set_counted_pipeline(app);
        app.settings.api_port = port_of(reservation);
        app.settings.bot_features_enabled = true;
        var plugin = new LifecyclePlugin();
        Test.expect_message("bot-features", LogLevelFlags.LEVEL_WARNING, "*Failed to start HTTP server*");
        plugin.registered(app);
        Test.assert_expected_messages();
        assert(plugin.pools.size == 1 && pipeline.count == 1);
        uint16 retry_port = unused_port();
        app.settings.api_port = retry_port;
        wait_milliseconds(650);
        assert(api_healthy(retry_port));
        assert(plugin.pools.size == 1 && pipeline.count == 1);
        var skipped = reserve_loopback_port();
        uint16 skipped_port = port_of(skipped);
        uint16 final_port = unused_port();
        app.settings.api_port = skipped_port;
        app.settings.api_port = final_port;
        wait_milliseconds(650);
        assert(api_healthy(final_port));
        assert(!api_healthy(retry_port));
        assert(plugin.pools.size == 1 && pipeline.count == 1);
        app.settings.bot_features_enabled = false;
        app.settings.api_port = retry_port;
        wait_milliseconds(650);
        assert(!api_healthy(final_port) && !api_healthy(retry_port));
        assert(pipeline.count == 0 && plugin.pools.size == 1);
        skipped.disconnect();
        reservation.disconnect();
        app.db.close();
    } catch (Error e) { Test.message("Unexpected fixture failure: %s", e.message); Test.fail(); }
}

void test_disabled_plugin_backup_includes_existing_wal_database() {
    if (!run_in_child()) return;
    try {
        var app = new LifecycleApplication();
        var pipeline = set_counted_pipeline(app);
        var plugin = new LifecyclePlugin();
        plugin.registered(app);
        string root = Environment.get_variable("DINOX_BOT_PLUGIN_TEST_ROOT");
        string stage = Path.build_filename(root, "stage");
        assert(DirUtils.create(stage, 0700) == 0);
        plugin.backup_database(stage);
        assert(!FileUtils.test(Path.build_filename(stage, "bot_registry.db"), FileTest.EXISTS));
        var registry = new BotRegistry(bot_database_path(), PROFILE_KEY);
        try {
            registry.exec("PRAGMA wal_autocheckpoint = 0");
            registry.set_setting("disabled-backup-proof", "committed through WAL");
            assert(FileUtils.test(bot_database_path() + "-wal", FileTest.EXISTS));
            uint8[] original_main, original_wal;
            FileUtils.get_data(bot_database_path(), out original_main);
            FileUtils.get_data(bot_database_path() + "-wal", out original_wal);
            plugin.backup_database(stage);
            Dino.Security.ProfileSnapshot.copy_files(Dino.Application.get_storage_dir(), stage);
            var snapshot = Qlite.Database.open_existing(Path.build_filename(stage, "bot_registry.db"), PROFILE_KEY);
            try {
                assert(snapshot.query_column_checked(
                    "SELECT value FROM settings WHERE key='disabled-backup-proof'")[0] == "committed through WAL");
            } finally { snapshot.close(); }
            uint8[] current_main, current_wal;
            FileUtils.get_data(bot_database_path(), out current_main);
            FileUtils.get_data(bot_database_path() + "-wal", out current_wal);
            assert(new Bytes(original_main).compare(new Bytes(current_main)) == 0);
            assert(new Bytes(original_wal).compare(new Bytes(current_wal)) == 0);
            assert(!FileUtils.test(Path.build_filename(stage, "bot_registry.db-wal"), FileTest.EXISTS));
            assert(!FileUtils.test(Path.build_filename(stage, "bot_registry.db-shm"), FileTest.EXISTS));
            assert(plugin.pools.size == 0 && pipeline.count == 0 && !app.settings.bot_features_enabled);
        } finally { registry.close(); }
        string closed_stage = Path.build_filename(root, "closed-stage");
        assert(DirUtils.create(closed_stage, 0700) == 0);
        plugin.backup_database(closed_stage);
        Dino.Security.ProfileSnapshot.copy_files(Dino.Application.get_storage_dir(), closed_stage);
        assert(FileUtils.test(Path.build_filename(closed_stage, "bot_registry.db"), FileTest.IS_REGULAR));
        app.db.close();
    } catch (Error e) { Test.message("Unexpected fixture failure: %s", e.message); Test.fail(); }
}

void test_inflight_connect_is_discarded_after_shutdown() {
    if (!run_in_child()) return;
    try {
        int bot_id = seed_dedicated_bot();
        var registry = new BotRegistry(bot_database_path(), PROFILE_KEY);
        try {
            var app = new LifecycleApplication();
            app.settings.bot_features_enabled = true;
            var pool = new LifecyclePool(app);
            pool.set_registry(registry);
            pool.hold_connect = true;
            pool.held_stream = new LifecycleTlsStream();
            int ready = 0;
            pool.dedicated_bot_ready.connect(() => { ready++; });
            BotInfo bot = registry.get_bot_by_id(bot_id);
            bool done = false;
            bool connected = true;
            pool.connect_dedicated.begin(bot, (obj, result) => {
                connected = pool.connect_dedicated.end(result);
                done = true;
            });
            assert(pool.attempts == 1 && !done);
            pool.shutdown();
            pool.complete_held_connect();
            while (!done) MainContext.default().iteration(true);
            assert(!connected && ready == 0);
            assert(pool.held_stream.disconnects == 1 && pool.held_stream.setups == 0);
            assert(pool.get_stream(bot) == null);
            pool.connect_all_dedicated();
            assert(pool.attempts == 1);
            app.db.close();
        } finally { registry.close(); }
    } catch (Error e) { Test.message("Unexpected fixture failure: %s", e.message); Test.fail(); }
}

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    Test.init(ref args);
    bool owns_root = !Test.subprocess();
    try {
        string root;
        if (owns_root) {
            // Ignore any externally supplied profile path. Only this parent
            // owns the fresh directory that its children may subsequently use.
            root = DirUtils.make_tmp("dinox-bot-plugin-lifecycle-XXXXXX");
            string token = Uuid.string_random();
            FileUtils.set_contents(Path.build_filename(root, ".fixture-owner"), token);
            Environment.set_variable("DINOX_BOT_PLUGIN_TEST_ROOT", root, true);
            Environment.set_variable("DINOX_BOT_PLUGIN_TEST_OWNER", token, true);
        } else {
            string? inherited_root = Environment.get_variable("DINOX_BOT_PLUGIN_TEST_ROOT");
            string? token = Environment.get_variable("DINOX_BOT_PLUGIN_TEST_OWNER");
            if (inherited_root == null || token == null || !Uuid.string_is_valid(token) ||
                    !Path.is_absolute(inherited_root) ||
                    Filename.canonicalize(Path.get_dirname(inherited_root)) != Filename.canonicalize(Environment.get_tmp_dir()) ||
                    !Path.get_basename(inherited_root).has_prefix("dinox-bot-plugin-lifecycle-") ||
                    FileUtils.test(inherited_root, FileTest.IS_SYMLINK)) {
                throw new IOError.INVALID_ARGUMENT("Child fixture profile does not belong to its test parent");
            }
            string marker = Path.build_filename(inherited_root, ".fixture-owner");
            string contents = "";
            if (FileUtils.test(marker, FileTest.IS_SYMLINK) ||
                    !FileUtils.get_contents(marker, out contents) || contents != token) {
                throw new IOError.INVALID_ARGUMENT("Child fixture ownership marker is invalid");
            }
            root = inherited_root;
        }
        Environment.set_variable("XDG_DATA_HOME", root, true);
        assert(Dino.Application.get_storage_dir() == Path.build_filename(root, "dinox"));
        assert(DirUtils.create_with_parents(Dino.Application.get_storage_dir(), 0700) == 0);
        Test.add_func("/botmother/plugin/disable-before-delayed-dedicated-connect", test_disable_before_delayed_connect);
        Test.add_func("/botmother/plugin/rapid-activation-keeps-only-current-runtime", test_rapid_activation_uses_only_current_runtime);
        Test.add_func("/botmother/plugin/corrected-api-port-recovers-without-reinitialization", test_corrected_api_port_recovers_without_reinitialization);
        Test.add_func("/botmother/plugin/disabled-startup-backup-includes-existing-wal", test_disabled_plugin_backup_includes_existing_wal_database);
        Test.add_func("/botmother/plugin/inflight-connect-is-discarded-after-shutdown", test_inflight_connect_is_discarded_after_shutdown);
        int status = Test.run();
        if (owns_root) Dino.Security.ProfileDeletion.delete_tree(File.new_for_path(root));
        return status;
    } catch (Error e) { stderr.printf("Isolated lifecycle fixture failed: %s\n", e.message); return 1; }
}
