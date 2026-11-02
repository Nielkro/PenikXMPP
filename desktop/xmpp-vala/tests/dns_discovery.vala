using Xmpp.DnsSecurity;

private async void run() throws Error {
    foreach (string scenario in new string[] { "good", "absent", "bogus", "denied", "no-tlsa", "forged-tlsa", "srv-alias", "address-alias" }) {
        var attempt = new Attempt(Mode.REQUIRED);
        var resolver = new DinoDns.Native.Resolver(
            new string[] { Environment.get_variable("DINOX_TEST_DNS_FORWARDER") },
            Environment.get_variable("DINOX_TEST_DNS_ANCHOR"), true);
        var discovery = new Discovery.for_resolver(new Configuration(attempt), resolver);
        bool accepted = false;
        bool expected = scenario == "good" || scenario == "srv-alias" || scenario == "address-alias" || scenario == "absent";
        try {
            var targets = yield discovery.targets(scenario + ".dinox-test", null, 0);
            if (scenario == "denied") {
                assert_cmpint(targets.size, CompareOperator.EQ, 0);
            } else {
                assert_true(targets.size > 0);
                uint previous = 0;
                foreach (var target in targets) {
                    assert_true(target.priority >= previous);
                    previous = target.priority;
                    var endpoints = yield discovery.addresses(scenario + ".dinox-test", target);
                    assert_true(endpoints.size > 0);
                    foreach (var endpoint in endpoints) {
                        assert_cmpstr(endpoint.host, CompareOperator.EQ, "127.0.0.1");
                        assert_true(endpoint.guard.requires_tlsa);
                        endpoint.guard.check_current();
                    }
                }
                accepted = true;
            }
        } catch (SecurityError error) {
            if (expected) throw error;
        } finally {
            discovery.close();
        }
        assert_true(accepted == expected);
        stdout.printf("PASS discovery %s\n", scenario);
    }
    assert_cmpstr(Discovery.normalize_host("ПРИМЕР.РФ."), CompareOperator.EQ, "xn--e1afmkfd.xn--p1ai");
    foreach (string name in new string[] { "host.onion", "printer.local", "127.0.0.1", "::1", "localhost", "router.home.arpa" }) {
        assert_true(Discovery.is_special(name));
    }
    foreach (string name in new string[] { "foo..example", "foo/example", "-bad.example", "bad_.example" }) {
        bool rejected = false;
        try { Discovery.normalize_host(name); } catch (SecurityError error) { rejected = true; }
        assert_true(rejected);
    }
    stdout.printf("PASS IDNA and special-use address boundaries\n");
}

int main(string[] args) {
    var loop = new MainLoop();
    int status = 0;
    run.begin((obj, result) => {
        try { run.end(result); }
        catch (Error error) { stderr.printf("FAIL: %s\n", error.message); status = 1; }
        loop.quit();
    });
    loop.run();
    return status;
}
