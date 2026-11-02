using Gee;
using Xmpp;

using Dino.Entities;

namespace Dino.Test {

class ConnectionManagerAudit : Gee.TestCase {

    public ConnectionManagerAudit() {
        base("ConnectionManagerAudit");
        add_test("sasl_policy_survives_restart_and_is_account_scoped", test_sasl_policy);
        add_test("sasl_schema58_migration_preserves_existing_accounts", test_sasl_migration);
        add_test("dns_security_settings_keep_accounts_separate", test_dns_security_settings_keep_accounts_separate);
        add_test("suspend_wake_serializes_and_fences_multiple_accounts",
            test_suspend_wake_serializes_and_fences_multiple_accounts);
        add_test("suspend_wake_fences_inflight_establish_and_retries_once",
            test_suspend_wake_fences_inflight_establish_and_retries_once);
        add_test("readiness_blocks_initial_connect_and_resumes_once",
            test_readiness_blocks_initial_connect_and_resumes_once);
        add_test("readiness_terminalizes_live_stream_and_discards_sm",
            test_readiness_terminalizes_live_stream_and_discards_sm);
        add_test("readiness_fences_inflight_establish_and_retries_once",
            test_readiness_fences_inflight_establish_and_retries_once);
        add_test("readiness_defers_reconnect_until_wake",
            test_readiness_defers_reconnect_until_wake);
    }

    private void test_sasl_migration() {
        string directory = Path.build_filename(Environment.get_tmp_dir(), "dinox-sasl-migration-" + Uuid.string_random());
        string path = Path.build_filename(directory, "test.db");
        Database? database = null;
        try {
            DirUtils.create_with_parents(directory, 0700);
            database = new Database(path, "sasl-fixture");
            var account = new Account(new Jid("existing@example.test"), "пароль-Über");
            account.require_channel_binding = true;
            account.persist(database);
            // Recreate precisely the previous account schema/version.
            rebuild_account_fixture_at_version(database, 58);
            database.exec("UPDATE _meta SET int_val=58 WHERE name='version'");
            account = null;
            database = null;
            database = new Database(path, "sasl-fixture");
            var accounts = database.get_accounts();
            assert_cmpint(accounts.size, CompareOperator.EQ, 1);
            assert_cmpstr(accounts[0].password, CompareOperator.EQ, "пароль-Über");
            assert_true(accounts[0].require_channel_binding);
            assert_false(accounts[0].allow_plain || accounts[0].scram_seen);
            database.exec("CREATE TRIGGER reject_pin BEFORE UPDATE OF scram_seen ON account BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Could not persist SCRAM login protection*");
            assert_false(accounts[0].remember_scram());
            GLib.Test.assert_expected_messages();
            assert_false(accounts[0].scram_seen || database.get_accounts()[0].scram_seen);
            database.exec("DROP TRIGGER reject_pin");
            assert_true(accounts[0].remember_scram());
            assert_true(database.get_accounts()[0].scram_seen);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            database = null;
            FileUtils.remove(path); FileUtils.remove(path + "-wal"); FileUtils.remove(path + "-shm");
            DirUtils.remove(directory);
        }
    }

    private void test_sasl_policy() {
        string directory = Path.build_filename(Environment.get_tmp_dir(), "dinox-sasl-" + Uuid.string_random());
        string path = Path.build_filename(directory, "Аккаунты test.db");
        Database? database = null;
        try {
            DirUtils.create_with_parents(directory, 0700);
            database = new Database(path, "sasl-fixture");
            var first = new Account(new Jid("first@example.test"), "fixture");
            var second = new Account(new Jid("second@example.test"), "fixture");
            first.persist(database);
            second.persist(database);
            assert_false(first.allow_plain || first.scram_seen || second.allow_plain || second.scram_seen);
            first.allow_plain = true;
            var manager = new ModuleManager();
            manager.get_modules(first);
            manager.get_modules(second);
            var first_sasl = manager.get_module<Sasl.Module>(first, Sasl.Module.IDENTITY);
            var second_sasl = manager.get_module<Sasl.Module>(second, Sasl.Module.IDENTITY);
            assert_true(first_sasl.allow_plain);
            assert_false(second_sasl.allow_plain);
            // Protocol tests prove that this callback requires the server proof;
            // this test verifies the application's persistence wiring.
            assert_true(first_sasl.persist_scram());
            assert_true(first.scram_seen);
            assert_false(second.scram_seen);
            first.require_channel_binding = true;
            first.password = "changed";
            first.enabled = false;
            manager = null;
            first_sasl = null;
            second_sasl = null;
            first = null;
            second = null;
            database = null;
            database = new Database(path, "sasl-fixture");
            var accounts = database.get_accounts();
            assert_cmpint(accounts.size, CompareOperator.EQ, 2);
            foreach (Account account in accounts) {
                bool pinned = account.localpart == "first";
                assert_true(account.scram_seen == pinned);
                assert_true(account.allow_plain == pinned);
                var restored = new ModuleManager();
                restored.get_modules(account);
                var sasl = restored.get_module<Sasl.Module>(account, Sasl.Module.IDENTITY);
                assert_true(sasl.scram_seen == pinned);
                // Disabling the stricter PLUS requirement does not clear the pin.
                account.require_channel_binding = false;
                account.allow_plain = true;
                restored.get_modules(account);
                assert_true(sasl.scram_seen == pinned);
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            database = null;
            FileUtils.remove(path); FileUtils.remove(path + "-wal"); FileUtils.remove(path + "-shm");
            DirUtils.remove(directory);
        }
    }

    private void test_dns_security_settings_keep_accounts_separate() {
        if (!DnsSecurity.Configuration.supported()) {
            GLib.Test.skip("DNSSEC component is disabled in this build");
            return;
        }
        string directory = Path.build_filename(Environment.get_tmp_dir(), "dinox-dns-settings-" + Uuid.string_random());
        string path = Path.build_filename(directory, "test.db");
        Database? database = null;
        try {
            DirUtils.create_with_parents(directory, 0700);
            database = new Database(path, "dns-settings-fixture");
            var first = new Account(new Jid("first@example.test"), "fixture");
            var second = new Account(new Jid("second@example.test"), "fixture");
            first.persist(database);
            second.persist(database);
            first.enabled = second.enabled = true;
            var manager = new ConnectionManager.for_tests(new ModuleManager(), database);
            manager.intercept_connect_stream_for_tests();
            var first_stream = new LateEstablishAuditStream(new Jid("example.test"));
            var second_stream = new LateEstablishAuditStream(new Jid("example.test"));
            manager.set_connected_stream_for_tests(first, first_stream);
            manager.set_connected_stream_for_tests(second, second_stream);
            fail_if(manager.get_dns_security_mode(first) != DnsSecurity.Mode.OFF ||
                manager.get_dns_security_mode(second) != DnsSecurity.Mode.OFF, "Existing accounts must default to off");
            manager.apply_dns_security(first, DnsSecurity.Mode.REQUIRED, "https://resolver.example/dns-query");
            fail_if(manager.get_dns_security_mode(first) != DnsSecurity.Mode.REQUIRED, "Required mode was not saved");
            fail_if(manager.get_dns_security_mode(second) != DnsSecurity.Mode.OFF ||
                manager.get_dns_security_resolver(second) != "", "Policy crossed the account boundary");
            fail_if(first_stream.disconnect_count != 1 || second_stream.disconnect_count != 0,
                "Only the changed account may disconnect");
            bool rejected = false;
            try { manager.apply_dns_security(first, DnsSecurity.Mode.WHEN_AVAILABLE, "http://invalid.example/dns-query"); }
            catch (Error error) { rejected = true; }
            fail_if(!rejected || manager.get_dns_security_mode(first) != DnsSecurity.Mode.REQUIRED ||
                manager.get_dns_security_resolver(first) != "https://resolver.example/dns-query", "Invalid updates must leave the saved pair intact");
            second.proxy_type = "socks5";
            rejected = false;
            try { manager.apply_dns_security(second, DnsSecurity.Mode.WHEN_AVAILABLE, ""); }
            catch (Error error) { rejected = true; }
            fail_if(!rejected || manager.get_dns_security_mode(second) != DnsSecurity.Mode.OFF,
                "A proxied account must not silently select direct system DNS");
            manager = null;
            database.close();
            database = new Database(path, "dns-settings-fixture");
            manager = new ConnectionManager.for_tests(new ModuleManager(), database);
            fail_if(manager.get_dns_security_mode(first) != DnsSecurity.Mode.REQUIRED ||
                manager.get_dns_security_mode(second) != DnsSecurity.Mode.OFF,
                "Account-specific policy did not survive database reopen");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (database != null) database.close();
            FileUtils.remove(path);
            FileUtils.remove(path + "-wal");
            FileUtils.remove(path + "-shm");
            DirUtils.remove(directory);
        }
    }

    private void test_suspend_wake_serializes_and_fences_multiple_accounts() {
        MainLoop loop = new MainLoop();
        string? failure = null;
        bool timeout_fired = false;
        run_suspend_wake_audit.begin((_, res) => {
            try {
                run_suspend_wake_audit.end(res);
            } catch (Error error) {
                failure = error.message;
            }
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(5, () => {
            timeout_fired = true;
            failure = "timed out waiting for suspend/wake serialization audit";
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timeout_fired) Source.remove(timeout_id);
        if (failure != null) fail_if_reached((!) failure);
    }

    private async void run_suspend_wake_audit() throws Error {
        var manager = new ConnectionManager.for_tests(new ModuleManager());
        manager.intercept_connect_stream_for_tests();

        var reconnect_account = new Account(
            new Jid("reconnect@example.test"), "secret");
        var replaced_stream_account = new Account(
            new Jid("stream-replaced@example.test"), "secret");
        var replaced_connection_account = new Account(
            new Jid("connection-replaced@example.test"), "secret");
        var removed_account = new Account(
            new Jid("removed@example.test"), "secret");
        var preterminal_account = new Account(
            new Jid("preterminal@example.test"), "secret");

        var reconnect_stream = new SuspendWakeAuditStream(
            new Jid("reconnect.example.test"));
        var replaced_stream = new SuspendWakeAuditStream(
            new Jid("stream-replaced.example.test"));
        var replaced_connection_stream = new SuspendWakeAuditStream(
            new Jid("connection-replaced.example.test"));
        var removed_stream = new SuspendWakeAuditStream(
            new Jid("removed.example.test"));
        var preterminal_stream = new SuspendWakeAuditStream(
            new Jid("preterminal.example.test"));

        manager.set_connected_stream_for_tests(reconnect_account,
            reconnect_stream);
        manager.set_connected_stream_for_tests(replaced_stream_account,
            replaced_stream);
        manager.set_connected_stream_for_tests(replaced_connection_account,
            replaced_connection_stream);
        manager.set_connected_stream_for_tests(removed_account,
            removed_stream);
        manager.set_connected_stream_for_tests(preterminal_account,
            preterminal_stream);

        // Model a TLS/SASL/user terminal that existed before Login1 suspend.
        manager.set_connection_state_for_tests(preterminal_account,
            ConnectionManager.ConnectionState.DISCONNECTED);

        manager.prepare_for_sleep_for_tests(true);
        int ticks = 0;
        while (!any_disconnect_in_progress(reconnect_stream, replaced_stream,
                    replaced_connection_stream, removed_stream) &&
                ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (!any_disconnect_in_progress(reconnect_stream, replaced_stream,
                replaced_connection_stream, removed_stream)) {
            throw new IOError.FAILED(
                "suspend must reach one held stream disconnect");
        }

        uint cycle_generation = manager
            .get_suspend_cycle_generation_for_tests();
        if (cycle_generation == 0 ||
                !manager.is_suspend_reconnect_owned_for_tests(
                    reconnect_account) ||
                !manager.is_suspend_reconnect_owned_for_tests(
                    replaced_stream_account) ||
                !manager.is_suspend_reconnect_owned_for_tests(
                    replaced_connection_account) ||
                !manager.is_suspend_reconnect_owned_for_tests(
                    removed_account)) {
            throw new IOError.FAILED(
                "all eligible accounts must be snapshotted and terminalized before the first suspend yield");
        }
        if (manager.is_suspend_reconnect_owned_for_tests(preterminal_account)) {
            throw new IOError.FAILED(
                "a pre-existing terminal must never become suspend-owned");
        }

        // disconnect() cancels the real stream.loop(). Its terminal catch must
        // consume the already-owned close instead of starting a second close
        // coroutine on the same stream.
        Account disconnecting_account;
        SuspendWakeAuditStream disconnecting_stream;
        if (reconnect_stream.disconnect_in_progress) {
            disconnecting_account = reconnect_account;
            disconnecting_stream = reconnect_stream;
        } else if (replaced_stream.disconnect_in_progress) {
            disconnecting_account = replaced_stream_account;
            disconnecting_stream = replaced_stream;
        } else if (replaced_connection_stream.disconnect_in_progress) {
            disconnecting_account = replaced_connection_account;
            disconnecting_stream = replaced_connection_stream;
        } else {
            disconnecting_account = removed_account;
            disconnecting_stream = removed_stream;
        }
        if (!manager.finish_terminal_stream_loop_for_tests(
                    disconnecting_account, disconnecting_stream) ||
                disconnecting_stream.disconnect_count != 1) {
            throw new IOError.FAILED(
                "terminal stream-loop exit must not overlap the suspend-owned disconnect");
        }

        // Login1 wake arrives while the first disconnect is still held. It
        // must queue behind the complete suspend cycle instead of reconnecting
        // the first HashMap entry immediately.
        manager.prepare_for_sleep_for_tests(false);
        yield wait_suspend_wake_tick();
        if (manager.get_intercepted_connect_count_for_tests(
                    reconnect_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    replaced_stream_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    replaced_connection_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    removed_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    preterminal_account) != 0) {
            throw new IOError.FAILED(
                "wake must not run in parallel with suspend disconnects");
        }

        // Fence a stream replacement on the same Connection object, a full
        // Connection replacement, and an account removed during the yield.
        var replacement_stream = new SuspendWakeAuditStream(
            new Jid("replacement-stream.example.test"), false);
        manager.set_connected_stream_for_tests(replaced_stream_account,
            replacement_stream);

        manager.remove_managed_account_for_tests(replaced_connection_account);
        var replacement_connection_stream = new SuspendWakeAuditStream(
            new Jid("replacement-connection.example.test"), false);
        manager.set_connected_stream_for_tests(replaced_connection_account,
            replacement_connection_stream);

        manager.remove_managed_account_for_tests(removed_account);

        reconnect_stream.release_disconnect();
        replaced_stream.release_disconnect();
        replaced_connection_stream.release_disconnect();
        removed_stream.release_disconnect();

        ticks = 0;
        while (!manager.is_prepare_for_sleep_idle_for_tests() && ticks++ < 200) {
            yield wait_suspend_wake_tick();
        }
        if (!manager.is_prepare_for_sleep_idle_for_tests()) {
            throw new IOError.FAILED(
                "serialized suspend/wake queue did not drain");
        }

        if (manager.get_intercepted_connect_count_for_tests(
                reconnect_account) != 1) {
            throw new IOError.FAILED(
                "wake must reconnect exactly the unchanged suspend-owned account");
        }
        if (reconnect_stream.disconnect_count != 1) {
            throw new IOError.FAILED(
                "wake must not start a second disconnect beside reconnect");
        }
        if (manager.get_intercepted_connect_count_for_tests(
                    replaced_stream_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    replaced_connection_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    removed_account) != 0 ||
                manager.get_intercepted_connect_count_for_tests(
                    preterminal_account) != 0) {
            throw new IOError.FAILED(
                "wake must fence replaced, removed and pre-existing terminal accounts");
        }
        if (manager.get_stream(replaced_stream_account) != replacement_stream ||
                manager.get_stream(replaced_connection_account) !=
                    replacement_connection_stream) {
            throw new IOError.FAILED(
                "wake must not disturb replacement stream or connection identities");
        }
        if (!manager.is_terminal_disconnect_requested(preterminal_account)) {
            throw new IOError.FAILED(
                "wake must preserve a pre-existing terminal decision");
        }
        if (manager.get_managed_accounts().contains(removed_account)) {
            throw new IOError.FAILED(
                "wake must not recreate an account removed during suspend");
        }
        if (any_disconnect_in_progress(reconnect_stream, replaced_stream,
                replaced_connection_stream, removed_stream)) {
            throw new IOError.FAILED(
                "no suspend disconnect may overlap the wake reconnect");
        }
    }

    private void test_suspend_wake_fences_inflight_establish_and_retries_once() {
        MainLoop loop = new MainLoop();
        string? failure = null;
        bool timeout_fired = false;
        run_inflight_establish_audit.begin((_, res) => {
            try {
                run_inflight_establish_audit.end(res);
            } catch (Error error) {
                failure = error.message;
            }
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(5, () => {
            timeout_fired = true;
            failure = "timed out waiting for in-flight establish audit";
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timeout_fired) Source.remove(timeout_id);
        if (failure != null) fail_if_reached((!) failure);
    }

    private async void run_inflight_establish_audit() throws Error {
        var manager = new HeldEstablishConnectionManager(
            new ModuleManager());
        var account = new Account(new Jid("inflight@example.test"),
            "secret");

        manager.connect_account(account);
        if (manager.attempt_count != 1 || manager.active_attempts != 1) {
            throw new IOError.FAILED(
                "the first establish attempt must be held in flight");
        }

        // Suspend terminalizes the owner while establish_stream() is still
        // awaiting its result. Wake rotates the connection UUID, but must only
        // coalesce a successor request until that old callback has completed.
        manager.prepare_for_sleep_for_tests(true);
        manager.prepare_for_sleep_for_tests(false);
        int ticks = 0;
        while (!manager.is_prepare_for_sleep_idle_for_tests() && ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (!manager.is_prepare_for_sleep_idle_for_tests()) {
            throw new IOError.FAILED(
                "suspend/wake queue did not drain around held establish");
        }
        if (manager.attempt_count != 1 || manager.active_attempts != 1 ||
                manager.max_active_attempts != 1) {
            throw new IOError.FAILED(
                "wake must not overlap the held establish attempt");
        }

        var stale_stream = new LateEstablishAuditStream(
            new Jid("inflight.example.test"));
        manager.release_attempt(1, new XmppStreamResult() {
            stream = stale_stream
        });
        ticks = 0;
        while (manager.attempt_count < 2 && ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (manager.attempt_count != 2 || manager.active_attempts != 1) {
            throw new IOError.FAILED(
                "the stale callback must start exactly one successor attempt");
        }
        if (manager.max_active_attempts != 1) {
            throw new IOError.FAILED(
                "old and successor establish attempts must never overlap");
        }
        if (manager.get_assigned_stream_for_tests(account) != null) {
            throw new IOError.FAILED(
                "a late stream from the superseded generation must not be assigned");
        }
        if (stale_stream.disconnect_count != 1) {
            throw new IOError.FAILED(
                "a late stream from the superseded generation must be closed");
        }

        // End the successor deterministically with a terminal TLS result so
        // the audit never starts the normal ten-second reconnect timer.
        manager.release_attempt(2, new XmppStreamResult() {
            tls_errors = TlsCertificateFlags.UNKNOWN_CA
        });
        ticks = 0;
        while ((manager.active_attempts != 0 ||
                manager.is_connection_ongoing_for_tests(account)) &&
                ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (manager.active_attempts != 0 ||
                manager.is_connection_ongoing_for_tests(account) ||
                manager.attempt_count != 2) {
            throw new IOError.FAILED(
                "the successor attempt must settle exactly once");
        }
    }

    private void test_readiness_blocks_initial_connect_and_resumes_once() {
        var manager = new ConnectionManager.for_tests(new ModuleManager());
        manager.intercept_connect_stream_for_tests();
        var gate = new AuditAccountReadinessGate();
        manager.add_readiness_gate(gate);
        Jid account_jid;
        Jid terminal_jid;
        try {
            account_jid = new Jid("initial-gate@example.test");
            terminal_jid = new Jid("terminal-gate@example.test");
        } catch (InvalidJidError error) {
            fail_if_reached(error.message);
            return;
        }
        var account = new Account(account_jid, "secret");

        manager.connect_account(account);
        if (!manager.is_readiness_blocked_for_tests(account) ||
                !manager.is_terminal_disconnect_requested(account) ||
                manager.get_intercepted_connect_count_for_tests(account) != 0) {
            fail_if_reached(
                "an unavailable gate must terminally block the initial connect");
        }

        gate.set_ready(account, true);
        gate.set_ready(account, true);
        if (manager.is_readiness_blocked_for_tests(account) ||
                manager.is_terminal_disconnect_requested(account) ||
                manager.get_intercepted_connect_count_for_tests(account) != 1) {
            fail_if_reached(
                "readiness recovery must start exactly one initial connect");
        }

        var terminal_account = new Account(terminal_jid, "secret");
        gate.set_ready(terminal_account, false);
        manager.connect_account(terminal_account);
        // Model an explicit remove/shutdown/TLS terminal while its dependency
        // is still unavailable. Readiness recovery must not take ownership of
        // that pre-existing terminal decision.
        manager.set_connection_state_for_tests(terminal_account,
            ConnectionManager.ConnectionState.DISCONNECTED);
        gate.set_ready(terminal_account, true);
        if (manager.get_intercepted_connect_count_for_tests(
                    terminal_account) != 0 ||
                !manager.is_terminal_disconnect_requested(
                    terminal_account)) {
            fail_if_reached(
                "readiness recovery must preserve an explicit terminal decision");
        }

        manager.connect_account(terminal_account);
        if (manager.get_intercepted_connect_count_for_tests(
                    terminal_account) != 1) {
            fail_if_reached(
                "a later explicit reconnect must still authorize one connect");
        }
    }

    private void test_readiness_terminalizes_live_stream_and_discards_sm() {
        MainLoop loop = new MainLoop();
        string? failure = null;
        bool timeout_fired = false;
        run_readiness_live_stream_audit.begin((_, res) => {
            try {
                run_readiness_live_stream_audit.end(res);
            } catch (Error error) {
                failure = error.message;
            }
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(5, () => {
            timeout_fired = true;
            failure = "timed out waiting for live-stream readiness audit";
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timeout_fired) Source.remove(timeout_id);
        if (failure != null) fail_if_reached((!) failure);
    }

    private async void run_readiness_live_stream_audit() throws Error {
        var module_manager = new ModuleManager();
        var account = new Account(new Jid("live-gate@example.test"),
            "secret");
        module_manager.initialize(account);
        var stream_management = module_manager.get_module<
            Xep.StreamManagement.Module>(account,
                Xep.StreamManagement.Module.IDENTITY);
        if (stream_management == null) {
            throw new IOError.FAILED(
                "stream-management module must exist for readiness audit");
        }
        ((!) stream_management).session_id = "resume-me";
        ((!) stream_management).h_inbound = 7;

        var manager = new ConnectionManager.for_tests(module_manager);
        manager.intercept_connect_stream_for_tests();
        var gate = new AuditAccountReadinessGate();
        gate.set_ready(account, true);
        manager.add_readiness_gate(gate);
        var stream = new SuspendWakeAuditStream(
            new Jid("live-gate.example.test"), false);
        manager.set_connected_stream_for_tests(account, stream);

        gate.set_ready(account, false);
        int ticks = 0;
        while (stream.disconnect_count == 0 && ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (!manager.is_readiness_blocked_for_tests(account) ||
                !manager.is_terminal_disconnect_requested(account) ||
                manager.get_state(account) !=
                    ConnectionManager.ConnectionState.DISCONNECTED ||
                manager.get_assigned_stream_for_tests(account) != null ||
                stream.disconnect_count != 1 ||
                ((!) stream_management).session_id != null ||
                ((!) stream_management).h_inbound != 0) {
            throw new IOError.FAILED(
                "readiness loss must close the stream and discard its SM session");
        }

        gate.set_ready(account, true);
        gate.set_ready(account, true);
        ticks = 0;
        while (manager.get_intercepted_connect_count_for_tests(account) == 0 &&
                ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (manager.get_intercepted_connect_count_for_tests(account) != 1 ||
                manager.is_readiness_blocked_for_tests(account) ||
                manager.is_terminal_disconnect_requested(account)) {
            throw new IOError.FAILED(
                "a live-stream readiness recovery must reconnect exactly once");
        }
    }

    private void test_readiness_fences_inflight_establish_and_retries_once() {
        MainLoop loop = new MainLoop();
        string? failure = null;
        bool timeout_fired = false;
        run_readiness_inflight_audit.begin((_, res) => {
            try {
                run_readiness_inflight_audit.end(res);
            } catch (Error error) {
                failure = error.message;
            }
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(5, () => {
            timeout_fired = true;
            failure = "timed out waiting for in-flight readiness audit";
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timeout_fired) Source.remove(timeout_id);
        if (failure != null) fail_if_reached((!) failure);
    }

    private async void run_readiness_inflight_audit() throws Error {
        var manager = new HeldEstablishConnectionManager(
            new ModuleManager());
        var gate = new AuditAccountReadinessGate();
        var account = new Account(new Jid("inflight-gate@example.test"),
            "secret");
        gate.set_ready(account, true);
        manager.add_readiness_gate(gate);

        manager.connect_account(account);
        if (manager.attempt_count != 1 || manager.active_attempts != 1) {
            throw new IOError.FAILED(
                "the readiness audit must hold one establish attempt");
        }

        gate.set_ready(account, false);
        gate.set_ready(account, true);
        gate.set_ready(account, true);
        if (manager.attempt_count != 1 || manager.active_attempts != 1 ||
                manager.max_active_attempts != 1) {
            throw new IOError.FAILED(
                "readiness recovery must not overlap the superseded attempt");
        }

        var stale_stream = new LateEstablishAuditStream(
            new Jid("inflight-gate.example.test"));
        manager.release_attempt(1, new XmppStreamResult() {
            stream = stale_stream
        });
        int ticks = 0;
        while (manager.attempt_count < 2 && ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (manager.attempt_count != 2 || manager.active_attempts != 1 ||
                manager.max_active_attempts != 1 ||
                stale_stream.disconnect_count != 1 ||
                manager.get_assigned_stream_for_tests(account) != null) {
            throw new IOError.FAILED(
                "the stale attempt must close and start one fenced successor");
        }

        manager.release_attempt(2, new XmppStreamResult() {
            tls_errors = TlsCertificateFlags.UNKNOWN_CA
        });
        ticks = 0;
        while ((manager.active_attempts != 0 ||
                manager.is_connection_ongoing_for_tests(account)) &&
                ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (manager.attempt_count != 2 || manager.active_attempts != 0 ||
                manager.is_connection_ongoing_for_tests(account)) {
            throw new IOError.FAILED(
                "the readiness successor must settle exactly once");
        }
    }

    private void test_readiness_defers_reconnect_until_wake() {
        MainLoop loop = new MainLoop();
        string? failure = null;
        bool timeout_fired = false;
        run_readiness_suspend_audit.begin((_, res) => {
            try {
                run_readiness_suspend_audit.end(res);
            } catch (Error error) {
                failure = error.message;
            }
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(5, () => {
            timeout_fired = true;
            failure = "timed out waiting for suspended readiness audit";
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timeout_fired) Source.remove(timeout_id);
        if (failure != null) fail_if_reached((!) failure);
    }

    private async void run_readiness_suspend_audit() throws Error {
        var manager = new ConnectionManager.for_tests(new ModuleManager());
        manager.intercept_connect_stream_for_tests();
        var gate = new AuditAccountReadinessGate();
        var account = new Account(new Jid("suspended-gate@example.test"),
            "secret");
        gate.set_ready(account, true);
        manager.add_readiness_gate(gate);
        var stream = new SuspendWakeAuditStream(
            new Jid("suspended-gate.example.test"));
        manager.set_connected_stream_for_tests(account, stream);

        manager.prepare_for_sleep_for_tests(true);
        int ticks = 0;
        while (!stream.disconnect_in_progress && ticks++ < 100) {
            yield wait_suspend_wake_tick();
        }
        if (!stream.disconnect_in_progress) {
            throw new IOError.FAILED(
                "suspend must hold the readiness audit stream close");
        }

        gate.set_ready(account, false);
        gate.set_ready(account, true);
        gate.set_ready(account, true);
        manager.prepare_for_sleep_for_tests(false);
        yield wait_suspend_wake_tick();
        if (manager.get_intercepted_connect_count_for_tests(account) != 0) {
            throw new IOError.FAILED(
                "readiness recovery must wait for the suspended close");
        }

        stream.release_disconnect();
        ticks = 0;
        while (!manager.is_prepare_for_sleep_idle_for_tests() && ticks++ < 200) {
            yield wait_suspend_wake_tick();
        }
        if (!manager.is_prepare_for_sleep_idle_for_tests() ||
                manager.get_intercepted_connect_count_for_tests(account) != 1 ||
                stream.disconnect_count != 1) {
            throw new IOError.FAILED(
                "wake must resume one readiness-owned connect without a second close");
        }
    }

    private static bool any_disconnect_in_progress(
            SuspendWakeAuditStream first, SuspendWakeAuditStream second,
            SuspendWakeAuditStream third, SuspendWakeAuditStream fourth) {
        return first.disconnect_in_progress || second.disconnect_in_progress ||
            third.disconnect_in_progress || fourth.disconnect_in_progress;
    }

    private static async void wait_suspend_wake_tick() {
        Idle.add(wait_suspend_wake_tick.callback);
        yield;
    }
}

private class AuditAccountReadinessGate : AccountReadinessGate {
    private HashMap<Account, bool> ready = new HashMap<Account, bool>(
        Account.hash_func, Account.equals_func);

    public override bool is_ready(Account account) {
        return ready.has_key(account) && ready[account];
    }

    public void set_ready(Account account, bool value) {
        ready[account] = value;
        readiness_changed(account);
    }
}

private class HeldEstablishConnectionManager : ConnectionManager {
    public int attempt_count { get; private set; default = 0; }
    public int active_attempts { get; private set; default = 0; }
    public int max_active_attempts { get; private set; default = 0; }

    private SourceFunc? first_resume = null;
    private SourceFunc? second_resume = null;
    private XmppStreamResult? first_result = null;
    private XmppStreamResult? second_result = null;

    public HeldEstablishConnectionManager(ModuleManager module_manager) {
        base.for_tests(module_manager);
    }

    internal override async XmppStreamResult establish_account_stream(
            Account account) {
        attempt_count++;
        active_attempts++;
        max_active_attempts = int.max(max_active_attempts, active_attempts);
        int attempt = attempt_count;
        if (attempt == 1) {
            first_resume = establish_account_stream.callback;
            yield;
            active_attempts--;
            return (!) first_result;
        }
        if (attempt == 2) {
            second_resume = establish_account_stream.callback;
            yield;
            active_attempts--;
            return (!) second_result;
        }

        active_attempts--;
        return new XmppStreamResult() {
            tls_errors = TlsCertificateFlags.UNKNOWN_CA
        };
    }

    public void release_attempt(int attempt, XmppStreamResult result) {
        SourceFunc? callback;
        if (attempt == 1) {
            first_result = result;
            callback = (owned) first_resume;
        } else {
            second_result = result;
            callback = (owned) second_resume;
        }
        if (callback == null) return;
        Idle.add(() => {
            ((!) callback)();
            return Source.REMOVE;
        });
    }
}

private class LateEstablishAuditStream : TlsXmppStream {
    public int disconnect_count { get; private set; default = 0; }

    public LateEstablishAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
        disconnect_count++;
    }
}

private class SuspendWakeAuditStream : XmppStream {
    public int disconnect_count { get; private set; default = 0; }
    public bool disconnect_in_progress { get; private set; default = false; }

    private bool disconnect_released;
    private SourceFunc? disconnect_resume = null;

    public SuspendWakeAuditStream(Jid remote_name,
            bool hold_disconnect = true) {
        base(remote_name);
        disconnect_released = !hold_disconnect;
        negotiation_complete = true;
        add_module(new Presence.Module());
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
        disconnect_count++;
        disconnect_in_progress = true;
        if (!disconnect_released) {
            disconnect_resume = disconnect.callback;
            yield;
        }
        disconnect_in_progress = false;
    }

    public void release_disconnect() {
        disconnect_released = true;
        SourceFunc? callback = (owned) disconnect_resume;
        if (callback == null) return;
        Idle.add(() => {
            ((!) callback)();
            return Source.REMOVE;
        });
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("suspend audit stream has no reader");
    }

    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
    }

    public override async void setup() throws IOError {
    }
}

}
