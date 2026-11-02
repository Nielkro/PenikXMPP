using GLib;
using Dino;
using Dino.Entities;
using Dino.Plugins.TorManager;

private class FakeTorController : TorController {
    public int starts;
    public int stops;
    public bool fail_next_start;
    public bool defer_canceled_start;
    private SourceFunc? canceled_start;
    private uint generation;
    private SourceFunc? pending_start;

    public FakeTorController() { base.for_tests(); }

    public override async void start() {
        if (is_running || is_starting) return;
        starts++;
        uint expected = ++generation;
        is_starting = true;
        socks_ready = false;
        bootstrap_percent = 0;
        pending_start = start.callback;
        yield;
        if (expected != generation) return;
        is_starting = false;
        is_running = !fail_next_start;
        socks_ready = is_running;
        fail_next_start = false;
    }

    public void show_bootstrap_before_listener(int port) {
        socks_port = port;
        is_running = true;
        bootstrap_percent = 100;
        bootstrap_status(100, "Fake bootstrap before listener confirmation");
    }

    public void complete_start(int port) {
        assert(pending_start != null);
        socks_port = port;
        SourceFunc callback = (owned) pending_start;
        pending_start = null;
        callback();
    }

    public void bootstrap() {
        bootstrap_percent = 100;
        bootstrap_status(100, "Offline fixture ready");
    }

    public override void stop() {
        stops++;
        generation++;
        is_running = false;
        is_starting = false;
        socks_ready = false;
        bootstrap_percent = 0;
        bootstrap_summary = "Offline fixture stopped";
        bootstrap_status(0, bootstrap_summary);
        if (pending_start != null) {
            if (defer_canceled_start) {
                canceled_start = (owned) pending_start;
                pending_start = null;
            } else {
                SourceFunc callback = (owned) pending_start;
                pending_start = null;
                callback();
            }
        }
    }

    public void release_canceled_start() {
        assert(canceled_start != null);
        SourceFunc callback = (owned) canceled_start;
        canceled_start = null;
        callback();
    }

    public override async void stop_and_wait() { stop(); }
    public override void clean_state() { }

    public void crash() {
        is_running = false;
        socks_ready = false;
        bootstrap_percent = 0;
        process_exited(1);
    }
}

private class Fixture {
    public string directory;
    public Database db;
    public StreamInteractor interactor;
    public FakeTorController controller;
    public TorManager manager;

    public Fixture(bool enabled = true, int timeout_seconds = 180) throws Error {
        directory = DirUtils.make_tmp("dinox-tor-startup-XXXXXX");
        db = new Database(Path.build_filename(directory, "dino.db"), "offline-tor-test");
        db.settings.upsert().value(db.settings.key, "tor_manager_enabled", true)
            .value(db.settings.value, enabled ? "true" : "false").perform();
        interactor = new StreamInteractor.for_tests(db);
        interactor.connection_manager.intercept_connect_stream_for_tests();
        controller = new FakeTorController();
        manager = new TorManager.for_tests(interactor, db, controller, timeout_seconds);
    }

    public Account account(string name, string proxy = "none", int port = 0) throws Error {
        var account = new Account(new Xmpp.Jid(name + "@example.test"), "fixture-password") {
            enabled = true, proxy_type = proxy, proxy_host = "127.0.0.1", proxy_port = port
        };
        account.persist(db);
        interactor.connect_account(account);
        return account;
    }

    public int attempts(Account account) {
        return interactor.connection_manager.get_intercepted_connect_count_for_tests(account);
    }

    public bool desired_state() {
        foreach (var row in db.settings.select().with(db.settings.key, "=", "tor_manager_enabled")) {
            return row[db.settings.value] == "true";
        }
        return false;
    }

    public void close() {
        manager.prepare_shutdown();
        bool finished = false;
        manager.stop_tor.begin(false, (obj, res) => {
            manager.stop_tor.end(res); finished = true;
        });
        wait_until(() => finished);
        db.close();
        foreach (string suffix in new string[] { "", "-wal", "-shm" }) {
            FileUtils.remove(Path.build_filename(directory, "dino.db" + suffix));
        }
        assert(DirUtils.remove(directory) == 0);
    }
}

private void wait_until(owned SourceFunc condition) {
    bool expired = false;
    var deadline = new TimeoutSource(4000);
    deadline.set_callback(() => { expired = true; return Source.REMOVE; });
    deadline.attach(null);
    while (!condition() && !expired) MainContext.default().iteration(true);
    deadline.destroy();
    assert(!expired);
}

private void startup_waits_for_tuple_and_all_dependencies() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var first = current.account("tor", "tor", 9999);
        var second = current.account("formerly-direct");
        var standalone = current.account("standalone", "socks5", 23456);
        assert(current.attempts(first) == 0 && current.attempts(second) == 0);
        assert(current.attempts(standalone) == 1 && standalone.proxy_port == 23456);
        assert(!current.manager.proxy_ready);
        current.controller.show_bootstrap_before_listener(9156);
        assert(current.attempts(first) == 0 && !current.manager.proxy_ready);
        current.controller.complete_start(9156);
        wait_until(() => current.manager.proxy_ready);
        assert(current.manager.proxy_ready && current.manager.is_ready(first));
        assert(first.proxy_port == 9156 && second.proxy_port == 9156);
        assert(current.attempts(first) == 1 && current.attempts(second) == 1);
        current.controller.bootstrap();
        assert(current.attempts(first) == 1 && current.attempts(second) == 1);
        var later = current.account("later");
        assert(current.attempts(later) == 1 && later.proxy_port == 9156);
    } catch (Error error) { GLib.error("Startup fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void start_failure_keeps_desired_tor_until_explicit_off() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var account = current.account("failed-start");
        current.controller.fail_next_start = true;
        Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
            "*Tor start failed; keeping Tor enabled and accounts blocked.*");
        current.controller.complete_start(9156);
        wait_until(() => !current.manager.transition_in_progress_for_tests());
        Test.assert_expected_messages();
        assert(current.manager.is_enabled && current.desired_state());
        assert(!current.manager.proxy_ready && current.attempts(account) == 0);
        bool finished = false;
        current.manager.set_enabled.begin(false, (obj, res) => {
            current.manager.set_enabled.end(res); finished = true;
        });
        wait_until(() => finished);
        assert(!current.manager.is_enabled && !current.desired_state());
        assert(account.proxy_type == "none" && current.attempts(account) == 1);
        current.controller.bootstrap();
        assert(current.attempts(account) == 1 && !current.manager.proxy_ready);
    } catch (Error error) { GLib.error("Failure fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void bootstrap_timeout_keeps_tor_blocked() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture(true, 1);
        var current = (!) fixture;
        var account = current.account("timeout");
        Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
            "*Tor bootstrap timed out after 1s. Stopping Tor.*");
        Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
            "*Tor start failed; keeping Tor enabled and accounts blocked.*");
        current.controller.complete_start(9156);
        wait_until(() => !current.manager.transition_in_progress_for_tests());
        Test.assert_expected_messages();
        assert(current.manager.is_enabled && current.desired_state());
        assert(current.attempts(account) == 0 && !current.manager.proxy_ready);
    } catch (Error error) { GLib.error("Timeout fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void restarts_apply_new_port_before_resuming() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var account = current.account("restart");
        current.controller.complete_start(9155); current.controller.bootstrap();
        wait_until(() => current.manager.proxy_ready);
        assert(current.attempts(account) == 1);
        bool finished = false;
        current.manager.update_use_bridges.begin(false, (obj, res) => {
            current.manager.update_use_bridges.end(res); finished = true;
        });
        assert(!current.manager.is_ready(account));
        wait_until(() => current.controller.starts == 2);
        current.controller.show_bootstrap_before_listener(9157);
        assert(current.attempts(account) == 1);
        current.controller.complete_start(9157);
        wait_until(() => finished);
        assert(account.proxy_port == 9157 && current.attempts(account) == 2);
    } catch (Error error) { GLib.error("Restart fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void disabled_account_and_shutdown_never_resume() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var removed = current.account("disabled");
        bool disconnected = false;
        current.interactor.disconnect_account.begin(removed, (obj, res) => {
            current.interactor.disconnect_account.end(res); disconnected = true;
        });
        wait_until(() => disconnected);
        var account = current.account("shutdown");
        current.manager.prepare_shutdown();
        assert(current.controller.stops > 0 && !current.manager.is_ready(account));
        current.controller.bootstrap();
        assert(current.attempts(account) == 0 && current.attempts(removed) == 0);
        bool enabled_done = false;
        current.manager.set_enabled.begin(true, (obj, res) => {
            current.manager.set_enabled.end(res); enabled_done = true;
        });
        wait_until(() => enabled_done);
        assert(current.controller.starts == 1 && current.desired_state());
    } catch (Error error) { GLib.error("Shutdown fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private class OtherDependencyGate : AccountReadinessGate {
    public bool ready;
    public override bool is_ready(Account account) { return ready; }
    public void release(Account account) { ready = true; readiness_changed(account); }
}

private void other_gate_still_controls_tor_recovery() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var dependency = new OtherDependencyGate();
        current.interactor.connection_manager.add_readiness_gate(dependency);
        var account = current.account("combined-gate");
        current.controller.complete_start(9156); current.controller.bootstrap();
        wait_until(() => current.manager.proxy_ready);
        assert(current.manager.is_ready(account) && current.attempts(account) == 0);
        dependency.release(account); dependency.release(account);
        assert(current.attempts(account) == 1);
    } catch (Error error) { GLib.error("Combined gate fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void automatic_retry_budget_is_not_reset_by_restart() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var account = current.account("retries");
        for (int attempt = 0; attempt < 3; attempt++) {
            current.controller.complete_start(9155 + attempt);
            if (attempt < 2) {
                Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
                    "*Tor exited unexpectedly with status 1*Attempt*Cleaning state*");
                current.controller.crash();
                int next_start = attempt + 2;
                wait_until(() => current.controller.starts == next_start);
            } else {
                Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
                    "*Retries exhausted; accounts remain blocked*");
                Test.expect_message("tor-manager", LogLevelFlags.LEVEL_WARNING,
                    "*Tor start failed; keeping Tor enabled and accounts blocked*");
                current.controller.crash();
                wait_until(() => !current.manager.transition_in_progress_for_tests());
            }
            Test.assert_expected_messages();
        }
        assert(current.controller.starts == 3 && current.manager.is_enabled);
        assert(current.desired_state() && current.attempts(account) == 0);
        assert(!current.manager.proxy_ready);
    } catch (Error error) { GLib.error("Retry fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void rapid_off_on_does_not_release_old_start() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        var current = (!) fixture;
        var account = current.account("rapid-toggle");
        current.controller.defer_canceled_start = true;
        current.manager.set_enabled.begin(false);
        assert(account.proxy_type == "none" && current.attempts(account) == 1);
        current.manager.set_enabled.begin(true);
        assert(current.controller.starts == 1 && !current.manager.proxy_ready);
        current.controller.release_canceled_start();
        current.controller.defer_canceled_start = false;
        wait_until(() => current.controller.starts == 2);
        assert(current.attempts(account) == 1);
        current.controller.show_bootstrap_before_listener(9160);
        assert(current.attempts(account) == 1);
        current.controller.complete_start(9160);
        wait_until(() => current.manager.proxy_ready);
        assert(current.attempts(account) == 2 && account.proxy_port == 9160);
    } catch (Error error) { GLib.error("Rapid toggle fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private void restored_off_clears_a_preloaded_managed_tuple() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture(false);
        var current = (!) fixture;
        var account = current.account("cached-tor", "tor", 9999);
        var standalone = current.account("cached-socks", "socks5", 23456);
        assert(account.proxy_type == "none" && account.proxy_port == 0);
        assert(current.attempts(account) == 1 && current.controller.starts == 0);
        assert(standalone.proxy_type == "socks5" && standalone.proxy_port == 23456);
    } catch (Error error) { GLib.error("Restored off fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
}

private class OfflineStream : Xmpp.XmppStream {
    public int disconnects;
    public OfflineStream() throws Error { base(new Xmpp.Jid("example.test")); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { disconnects++; }
    public override async void setup() throws IOError { }
    public override async Xmpp.StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Offline fixture has no reader");
    }
    public override async void write_async(Xmpp.StanzaNode node,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError { }
}

private void enable_fences_existing_direct_stream_until_tor_is_ready() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture(false);
        var current = (!) fixture;
        var account = current.account("already-connected");
        var stream = new OfflineStream();
        current.interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        bool finished = false;
        current.manager.set_enabled.begin(true, (obj, res) => {
            current.manager.set_enabled.end(res); finished = true;
        });
        assert(current.interactor.connection_manager.is_readiness_blocked_for_tests(account));
        assert(current.interactor.connection_manager.get_assigned_stream_for_tests(account) == null);
        assert(stream.disconnects == 1 && current.attempts(account) == 1);
        current.controller.show_bootstrap_before_listener(9156);
        assert(current.attempts(account) == 1);
        current.controller.complete_start(9156);
        wait_until(() => finished && current.attempts(account) == 2);
        assert(account.proxy_type == "tor" && account.proxy_port == 9156);
        assert(stream.disconnects == 1);
    } catch (Error error) { GLib.error("Existing stream fixture: %s", error.message); }
    finally { if (fixture != null) fixture.close(); }
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
    Test.add_func("/TorStartup/listener-bootstrap-tuple-and-overrides", startup_waits_for_tuple_and_all_dependencies);
    Test.add_func("/TorStartup/failure-keeps-desired-state-until-explicit-off", start_failure_keeps_desired_tor_until_explicit_off);
    Test.add_func("/TorStartup/bootstrap-timeout-remains-blocked", bootstrap_timeout_keeps_tor_blocked);
    Test.add_func("/TorStartup/restart-port-before-resume", restarts_apply_new_port_before_resuming);
    Test.add_func("/TorStartup/disabled-and-shutdown-stay-terminal", disabled_account_and_shutdown_never_resume);
    Test.add_func("/TorStartup/other-readiness-gate-still-blocks", other_gate_still_controls_tor_recovery);
    Test.add_func("/TorStartup/automatic-retries-stay-bounded", automatic_retry_budget_is_not_reset_by_restart);
    Test.add_func("/TorStartup/rapid-off-on-fences-old-start", rapid_off_on_does_not_release_old_start);
    Test.add_func("/TorStartup/restored-off-clears-preloaded-tor-tuple", restored_off_clears_a_preloaded_managed_tuple);
    Test.add_func("/TorStartup/enable-fences-existing-direct-stream", enable_fences_existing_direct_stream_until_tor_is_ready);
    return Test.run();
}
