namespace Dino.Test {

class AccountRemovalAudit : Gee.TestCase {
    public AccountRemovalAudit() {
        base("AccountRemovalAudit");
        add_test("server_failure_stops_before_cleanup", test_server_failure_stops_before_cleanup);
        add_test("server_success_orders_all_steps", test_server_success_orders_all_steps);
        add_test("local_only_skips_server_step", test_local_only_skips_server_step);
        add_test("local_removal_preserves_other_accounts", test_local_removal_preserves_other_accounts);
    }

    private void test_server_failure_stops_before_cleanup() {
        var operation = new TestAccountRemovalOperation("not-allowed");
        string? error = run_operation(operation, true);

        fail_if_not_eq_str("not-allowed", error);
        fail_if(operation.events.size != 1, "server failure must stop before cleanup and local deletion");
        fail_if_not_eq_str("server", operation.events[0]);
    }

    private void test_server_success_orders_all_steps() {
        var operation = new TestAccountRemovalOperation(null);
        string? error = run_operation(operation, true);

        fail_if(error != null, "successful server removal must not return an error");
        assert_events(operation, { "server", "cleanup", "local" });
    }

    private void test_local_only_skips_server_step() {
        var operation = new TestAccountRemovalOperation("must-not-be-used");
        string? error = run_operation(operation, false);

        fail_if(error != null, "local-only removal must not return a server error");
        assert_events(operation, { "cleanup", "local" });
    }

    private void test_local_removal_preserves_other_accounts() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-account-removal-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "account-removal-test");

            var removed_account = new Entities.Account(new Xmpp.Jid("removed@example.test"), "secret");
            removed_account.enabled = false;
            removed_account.persist((!) db);

            var remaining_account = new Entities.Account(new Xmpp.Jid("remaining@example.test"), "secret");
            remaining_account.enabled = true;
            remaining_account.persist((!) db);

            removed_account.remove();

            var accounts = ((!) db).get_accounts();
            fail_if(accounts.size != 1, "local removal must delete exactly one account");
            if (accounts.size == 1) {
                fail_if_not_eq_str("remaining@example.test", accounts[0].bare_jid.to_string(),
                    "local removal must preserve unrelated accounts");
            }
        } catch (Error e) {
            fail_if_reached("Unexpected local account removal error: " + e.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private string? run_operation(TestAccountRemovalOperation operation, bool remove_from_server) {
        var loop = new MainLoop();
        string? result = "operation-did-not-complete";

        Plugins.AccountRemovalCoordinator.run.begin(operation, remove_from_server, (source, res) => {
            result = Plugins.AccountRemovalCoordinator.run.end(res);
            loop.quit();
        });
        loop.run();
        return result;
    }

    private void assert_events(TestAccountRemovalOperation operation, string[] expected) {
        fail_if(operation.events.size != expected.length,
            "unexpected account removal event count: %d".printf(operation.events.size));
        int count = int.min(operation.events.size, expected.length);
        for (int i = 0; i < count; i++) {
            fail_if_not_eq_str(expected[i], operation.events[i],
                "unexpected account removal step at index %d".printf(i));
        }
    }
}

private class TestAccountRemovalOperation : Object, Plugins.AccountRemovalOperation {
    public Gee.ArrayList<string> events = new Gee.ArrayList<string>();
    private string? server_error;

    public TestAccountRemovalOperation(string? server_error) {
        this.server_error = server_error;
    }

    public async string? remove_server_account() {
        events.add("server");
        return server_error;
    }

    public async void cleanup_related_data() {
        events.add("cleanup");
    }

    public async void remove_local_account() {
        events.add("local");
    }
}

}
