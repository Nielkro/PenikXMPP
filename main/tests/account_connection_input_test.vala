using Dino.Entities;
using Dino.Ui.ManageAccounts;
using Xmpp;

namespace Dino.Ui.Test {

class AccountConnectionInputTest : Gee.TestCase {

    public AccountConnectionInputTest() {
        base("AccountConnectionInput");

        add_test("direct_connection_keeps_proxy_disabled", test_direct_connection);
        add_test("custom_I2P_target_and_SOCKS5_are_applied_together", test_i2p_socks5_connection);
        add_test("optional_proxy_credentials_are_normalized", test_proxy_credentials);
        add_test("invalid_proxy_endpoint_is_transactional", test_invalid_proxy_endpoint);
        add_test("invalid_custom_server_is_transactional", test_invalid_custom_server);
        add_test("proxy_password_requires_username", test_proxy_password_requires_username);
        add_test("port_boundaries_are_enforced", test_port_boundaries);
        add_test("raw_IPv6_is_accepted", test_raw_ipv6);
        add_test("address_fields_reject_endpoint_syntax", test_invalid_host_syntax);
        add_test("ready_global_Tor_is_applied", test_ready_runtime_tor);
        add_test("unready_global_Tor_fails_closed", test_unready_runtime_tor);
        add_test("SOCKS5_preferences_survive_disable", test_socks5_preferences_survive_disable);
    }

    private Account new_account() {
        try {
            return new Account(new Jid("alice@example.test"), "xmpp-password");
        } catch (InvalidJidError error) {
            GLib.error("Invalid test JID: %s", error.message);
        }
    }

    private AccountConnectionInput input(string custom_host = "",
                                         string custom_port = "",
                                         bool proxy_enabled = false,
                                         string proxy_host = "",
                                         string proxy_port = "",
                                         string proxy_user = "",
                                         string proxy_pass = "") {
        return new AccountConnectionInput(custom_host, custom_port,
                proxy_enabled, proxy_host, proxy_port, proxy_user, proxy_pass);
    }

    private void test_direct_connection() {
        Account account = new_account();

        assert_true(input().apply_to(account) == AccountConnectionInputIssue.NONE);
        assert_true(account.custom_host == null);
        fail_if_not_eq_int(0, account.custom_port);
        fail_if_not_eq_str("none", account.proxy_type);
        assert_true(account.proxy_host == null);
        fail_if_not_eq_int(0, account.proxy_port);
        assert_true(account.proxy_user == null);
        assert_true(account.proxy_pass == null);
    }

    private void test_i2p_socks5_connection() {
        Account account = new_account();
        AccountConnectionInput connection = input(
                "exampledestination.b32.i2p",
                "5222", true, "127.0.0.1", "4447");

        assert_true(connection.apply_to(account) == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_str("exampledestination.b32.i2p", (!) account.custom_host);
        fail_if_not_eq_int(5222, account.custom_port);
        fail_if_not_eq_str("socks5", account.proxy_type);
        fail_if_not_eq_str("127.0.0.1", (!) account.proxy_host);
        fail_if_not_eq_int(4447, account.proxy_port);
        assert_true(account.proxy_user == null);
        assert_true(account.proxy_pass == null);
    }

    private void test_proxy_credentials() {
        Account account = new_account();
        AccountConnectionInput connection = input("", "", true,
                "proxy.example.test", "1080", " proxy-user ", " pass with spaces ");

        assert_true(connection.apply_to(account) == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_str("proxy-user", (!) account.proxy_user);
        fail_if_not_eq_str(" pass with spaces ", (!) account.proxy_pass);
    }

    private void test_invalid_proxy_endpoint() {
        Account account = seeded_account();
        AccountConnectionInput connection = input("new.example.test", "5223", true,
                "socks5://127.0.0.1", "not-a-port");

        assert_true(connection.apply_to(account) == AccountConnectionInputIssue.PROXY_ENDPOINT);
        assert_seed_unchanged(account);
    }

    private void test_invalid_custom_server() {
        Account account = seeded_account();
        AccountConnectionInput connection = input("new.example.test", "", true,
                "127.0.0.1", "4447");

        assert_true(connection.apply_to(account) == AccountConnectionInputIssue.CUSTOM_SERVER);
        assert_seed_unchanged(account);
    }

    private void test_proxy_password_requires_username() {
        Account account = seeded_account();
        AccountConnectionInput connection = input("", "", true,
                "127.0.0.1", "4447", "", "proxy-password");

        assert_true(connection.apply_to(account) == AccountConnectionInputIssue.PROXY_CREDENTIALS);
        assert_seed_unchanged(account);
    }

    private void test_port_boundaries() {
        Account low = new_account();
        assert_true(input("target.example", "1", true, "127.0.0.1", "1").apply_to(low)
                == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_int(1, low.custom_port);
        fail_if_not_eq_int(1, low.proxy_port);

        Account high = new_account();
        assert_true(input("target.example", "65535", true, "127.0.0.1", "65535").apply_to(high)
                == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_int(65535, high.custom_port);
        fail_if_not_eq_int(65535, high.proxy_port);

        assert_true(input("target.example", "0").validate() == AccountConnectionInputIssue.CUSTOM_SERVER);
        assert_true(input("target.example", "65536").validate() == AccountConnectionInputIssue.CUSTOM_SERVER);
        assert_true(input("", "", true, "127.0.0.1", "0").validate()
                == AccountConnectionInputIssue.PROXY_ENDPOINT);
        assert_true(input("", "", true, "127.0.0.1", "65536").validate()
                == AccountConnectionInputIssue.PROXY_ENDPOINT);
    }

    private void test_raw_ipv6() {
        Account account = new_account();
        assert_true(input("::1", "5222", true, "2001:db8::1", "4447").apply_to(account)
                == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_str("::1", (!) account.custom_host);
        fail_if_not_eq_str("2001:db8::1", (!) account.proxy_host);
    }

    private void test_invalid_host_syntax() {
        string[] invalid_hosts = {
            "socks5://127.0.0.1",
            "127.0.0.1:4447",
            "[::1]",
            "proxy.example.test/path",
            "proxy.example.test?query",
            "proxy.example.test#fragment"
        };
        foreach (string invalid_host in invalid_hosts) {
            assert_true(input("", "", true, invalid_host, "4447").validate()
                    == AccountConnectionInputIssue.PROXY_ENDPOINT);
        }
    }

    private void test_ready_runtime_tor() {
        Account account = new_account();
        assert_true(AccountConnectionInput.apply_runtime_proxy_to(account,
                true, true, "tor", "127.0.0.1", 19050)
                == AccountConnectionInputIssue.NONE);
        fail_if_not_eq_str("tor", account.proxy_type);
        fail_if_not_eq_str("127.0.0.1", (!) account.proxy_host);
        fail_if_not_eq_int(19050, account.proxy_port);
    }

    private void test_unready_runtime_tor() {
        Account account = seeded_account();
        assert_true(AccountConnectionInput.apply_runtime_proxy_to(account,
                true, false, "tor", "127.0.0.1", 19050)
                == AccountConnectionInputIssue.RUNTIME_PROXY_UNAVAILABLE);
        assert_seed_unchanged(account);
    }

    private void test_socks5_preferences_survive_disable() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
                "dinox-account-connection-input-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "account-connection-input-test");
            Account account = new_account();
            AccountConnectionInput connection = input(
                    "exampledestination.b32.i2p", "5222", true,
                    "127.0.0.1", "4447", " proxy-user ", "proxy-password");

            assert_true(connection.apply_to(account) == AccountConnectionInputIssue.NONE);
            account.persist((!) db);
            connection.persist_socks5_preferences((!) db, account);

            // Disabling the proxy clears the active endpoint, but must not
            // discard the values shown when it is enabled again later.
            account.proxy_type = "none";
            account.proxy_host = null;
            account.proxy_port = 0;
            account.proxy_user = null;
            account.proxy_pass = null;

            fail_if_not_eq_str("127.0.0.1", (!) ((!) db).account_settings.get_value(account.id, "socks5_host"));
            fail_if_not_eq_str("4447", (!) ((!) db).account_settings.get_value(account.id, "socks5_port"));
            fail_if_not_eq_str("proxy-user", (!) ((!) db).account_settings.get_value(account.id, "socks5_user"));
            fail_if_not_eq_str("proxy-password", (!) ((!) db).account_settings.get_value(account.id, "socks5_pass"));
        } catch (Error error) {
            GLib.Test.message("Unexpected SOCKS5 preference persistence error: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private Account seeded_account() {
        Account account = new_account();
        account.custom_host = "old.example.test";
        account.custom_port = 5222;
        account.proxy_type = "socks5";
        account.proxy_host = "old-proxy.example.test";
        account.proxy_port = 1080;
        account.proxy_user = "old-user";
        account.proxy_pass = "old-pass";
        return account;
    }

    private void assert_seed_unchanged(Account account) {
        fail_if_not_eq_str("old.example.test", (!) account.custom_host);
        fail_if_not_eq_int(5222, account.custom_port);
        fail_if_not_eq_str("socks5", account.proxy_type);
        fail_if_not_eq_str("old-proxy.example.test", (!) account.proxy_host);
        fail_if_not_eq_int(1080, account.proxy_port);
        fail_if_not_eq_str("old-user", (!) account.proxy_user);
        fail_if_not_eq_str("old-pass", (!) account.proxy_pass);
    }
}

}
