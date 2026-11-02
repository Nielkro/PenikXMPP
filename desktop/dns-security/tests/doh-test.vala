[CCode (cname = "g_tls_file_database_new", cheader_filename = "gio/gio.h")]
private extern TlsDatabase create_tls_database(string path) throws Error;

private async void rejected_endpoint(string endpoint) throws Error {
    var forwarder = new DinoDns.DohForwarder(endpoint, Environment.get_variable("DINOX_TEST_DOH_PROXY"));
    var resolver = new DinoDns.Native.Resolver({forwarder.forwarder_address},
                                                Environment.get_variable("DINOX_TEST_DNS_ANCHOR"), true);
    // resolve_async's error is consumed here; no exception can leave this
    // block. An extra try/finally emits an unused label with Vala/MinGW.
    bool rejected = false;
    try { yield resolver.resolve_async("good.dinox-test.", 1, 800); }
    catch (Error e) { rejected = true; }
    assert(rejected);
    resolver.close();
    forwarder.close();
}

private async void run(MainLoop loop) {
    DinoDns.DohForwarder? forwarder = null;
    DinoDns.Native.Resolver? resolver = null;
    try {
        var database = create_tls_database(Environment.get_variable("DINOX_TEST_DOH_CA"));
        TlsBackend.get_default().set_default_database(database);
        forwarder = new DinoDns.DohForwarder(Environment.get_variable("DINOX_TEST_DOH_URL"),
                                             Environment.get_variable("DINOX_TEST_DOH_PROXY"));
        resolver = new DinoDns.Native.Resolver({forwarder.forwarder_address},
                                                Environment.get_variable("DINOX_TEST_DNS_ANCHOR"), true);
        var answer = yield resolver.resolve_async("good.dinox-test.", 1, 5000);
        assert(answer.validation == DinoDns.Native.Validation.SECURE);
        assert(answer.records.length == 1);
        // The DNSKEY query needed for this answer must have used the proxy too.
        var tlsa = yield resolver.resolve_async("_5222._tcp.good.dinox-test.", 52, 5000);
        assert(tlsa.validation == DinoDns.Native.Validation.SECURE);
        assert(tlsa.records.length == 1);
        string base_url = Environment.get_variable("DINOX_TEST_DOH_URL");
        yield rejected_endpoint(base_url.replace("/dns-query", "/redirect"));
        yield rejected_endpoint(base_url.replace("/dns-query", "/oversize"));
        yield rejected_endpoint(base_url.replace("/dns-query", "/wrong-id"));
        yield rejected_endpoint(base_url.replace("resolver.invalid", "wrong.invalid"));
        resolver.close();
        resolver = new DinoDns.Native.Resolver({forwarder.forwarder_address},
                                                Environment.get_variable("DINOX_TEST_DNS_ANCHOR"), true);
        forwarder.close();
        bool failed = false;
        try {
            yield resolver.resolve_async("good.dinox-test.", 1, 200);
        } catch (Error e) { failed = true; }
        assert(failed);
        stdout.printf("DNSSEC over HTTPS/SOCKS5: signed A/DNSKEY/TLSA; redirects, oversized/invalid answers, invalid HTTPS identity and closed route rejected\n");
    } catch (Error e) {
        error("DNS-over-HTTPS fixture failed: %s", e.message);
    } finally {
        if (resolver != null) resolver.close();
        if (forwarder != null) forwarder.close();
        loop.quit();
    }
}

public int main(string[] args) {
    var loop = new MainLoop();
    run.begin(loop);
    loop.run();
    return 0;
}
