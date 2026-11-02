// Real direct-TLS/STARTTLS streams, using only the fixture's loopback servers.
using Xmpp;

[CCode (cname = "g_tls_file_database_new", cheader_filename = "gio/gio.h")]
private extern TlsDatabase file_database_new(string anchors) throws Error;

private async void run_case(bool starttls, string scenario) throws Error {
    var attempt = new DnsSecurity.Attempt(DnsSecurity.Mode.REQUIRED);
    var records = new GenericArray<Bytes>();
    var certificate = new TlsCertificate.from_file(Environment.get_variable("DINOX_TEST_XMPP_CA"));
    ByteArray der = certificate.certificate;
    uint8[] record = new uint8[3 + der.len];
    record[0] = scenario.has_prefix("pkix") ? (uint8) 1 : (uint8) 3;
    record[1] = 0;
    record[2] = 0;
    for (uint i = 0; i < der.len; i++) record[i + 3] = der.data[i];
    if (scenario == "mismatch") record[record.length - 1] ^= 1;
    records.add(new Bytes(record));
    int64 expires = get_monotonic_time() + (scenario == "expired" ? -1 : 30 * 1000000);
    if (scenario == "expires-during-handshake") expires = get_monotonic_time() + 50000;
    string identity = scenario == "pkix-wrong-name" ? "wrong.invalid" : "xmpp.invalid";
    var guard = new DnsSecurity.HandshakeGuard(attempt, expires,
        new string[] { identity }, records, !scenario.has_prefix("normal-"));
    if (scenario == "cancelled") attempt.cancel();
    uint cancel_timer = 0;
    if (scenario == "cancel-during-handshake") {
        cancel_timer = Timeout.add(50, () => { attempt.cancel(); return Source.CONTINUE; });
    }
    uint16 port = (uint16) int.parse(Environment.get_variable(starttls ? "DINOX_TEST_STARTTLS_PORT" : "DINOX_TEST_TLS_PORT"));
    int pin_calls = 0;
    var pin = new TlsXmppStream.OnInvalidCertWrapper(() => { pin_calls++; return scenario != "normal-untrusted-reject"; });
    var jid = new Jid(identity);
    TlsXmppStream stream = starttls ?
        (TlsXmppStream) new StartTlsXmppStream(jid, "127.0.0.1", port, pin) :
        (TlsXmppStream) new DirectTlsXmppStream(jid, "127.0.0.1", port, pin);
    if (scenario != "off") stream.dns_security = guard;
    stream.log = new XmppLog("fixture", null);
    var sasl = new Sasl.Module("fixture", "FIXTURE-CREDENTIAL") { allow_plain = true };
    stream.add_module(sasl);
    bool expected = scenario == "match" || scenario == "pkix" || scenario == "untrusted-match" || scenario == "off" ||
        scenario == "normal-tls" || scenario == "normal-untrusted-pin";
    bool connected = false;
    uint timer = Timeout.add_seconds(4, () => { stream.cancel(); return Source.CONTINUE; });
    try {
        yield stream.connect();
        connected = true;
        assert_true(expected);
        assert_true(guard.verified == (scenario != "off" && !scenario.has_prefix("normal-")));
        // Let the real SASL module respond to the fixture's offered mechanism.
        // The server records the auth and closes without authenticating anyone.
        try { yield stream.loop(); } catch (IOError error) {}
    } catch (IOError error) {
        if (expected) throw error;
        if (scenario == "normal-untrusted-reject") {
            assert_true(stream.dns_security_error == null && stream.errors != null);
        } else {
            assert_true(stream.dns_security_error != null);
        }
    } finally {
        Source.remove(timer);
        if (cancel_timer != 0) Source.remove(cancel_timer);
        stream.cancel();
        stream.detach_modules();
    }
    assert_true(connected == expected);
    assert_cmpint(pin_calls, CompareOperator.EQ, scenario.has_prefix("normal-untrusted") ? 1 : 0);
    stdout.printf("PASS %s %s: pin overrides=%d, authenticated gate=%s\n",
        starttls ? "STARTTLS" : "direct TLS", scenario, pin_calls, guard.verified.to_string());
}

private async void run() throws Error {
    var system_database = TlsBackend.get_default().get_default_database();
    var database = file_database_new(Environment.get_variable("DINOX_TEST_XMPP_CA"));
    TlsBackend.get_default().set_default_database(database);
    foreach (bool starttls in new bool[] { false, true }) {
        foreach (string scenario in new string[] { "match", "mismatch", "pkix", "expired", "cancelled", "untrusted-match", "pkix-wrong-name", "expires-during-handshake", "off", "normal-tls", "normal-untrusted-pin", "normal-untrusted-reject", "cancel-during-handshake" }) {
            TlsBackend.get_default().set_default_database(scenario == "untrusted-match" || scenario.has_prefix("normal-untrusted") ? system_database : database);
            yield run_case(starttls, scenario);
        }
    }
}

int main(string[] args) {
    // Do not use g_test_init: expected connection failures produce warnings.
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
