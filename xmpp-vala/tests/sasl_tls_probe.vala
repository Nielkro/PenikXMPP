// Connect only to the Python fixture's loopback TLS server. No real accounts.
using Xmpp;

[CCode (cname = "g_tls_file_database_new", cheader_filename = "gio/gio.h")]
private extern TlsDatabase file_database_new(string anchors) throws Error;

private async void run_case(string[] args) throws Error {
    TlsBackend.get_default().set_default_database(file_database_new(args[2]));
    var pin = new TlsXmppStream.OnInvalidCertWrapper(() => false);
    var jid = new Jid("example.test");
    uint16 port = (uint16) int.parse(args[1]);
    TlsXmppStream stream = args[3] == "starttls" ?
        (TlsXmppStream) new StartTlsXmppStream(jid, "127.0.0.1", port, pin) :
        (TlsXmppStream) new DirectTlsXmppStream(jid, "127.0.0.1", port, pin);
    stream.log = new XmppLog("fixture", null);
    var sasl = new Sasl.Module("тест@example.test", "пароль-Über") {
        allow_plain = args[4] == "allow",
        scram_seen = args[5] == "seen",
        require_channel_binding = args[6] == "strict"
    };
    sasl.persist_scram = () => args[8] != "storage-fail";
    stream.add_module(sasl);
    int confirmed = 0;
    sasl.scram_authenticated.connect(() => confirmed++);
    uint timer = Timeout.add_seconds(6, () => { stream.cancel(); return Source.CONTINUE; });
    try {
        yield stream.connect();
        try { yield stream.loop(); } catch (IOError error) {}
        var flag = stream.get_flag(Sasl.Flag.IDENTITY);
        if (flag == null) throw new IOError.FAILED("No authentication result");
        if (args.length > 9 && flag.server_offers_channel_binding != (args[9] == "offers-plus")) {
            throw new IOError.FAILED("Server offer snapshot does not match the TLS fixture");
        }
        string result = flag.finished ? "ok" : flag.failure_reason ?? "server-failure";
        stdout.printf("RESULT %s %d %s\n", result, confirmed, stream.get_tls_version_hex() ?? "unknown");
        if (result != args[7]) throw new IOError.FAILED("Unexpected authentication result: %s", result);
        if (flag.finished && flag.mechanism != "PLAIN" && confirmed != 1) throw new IOError.FAILED("SCRAM pin not signalled");
        if ((!flag.finished || flag.mechanism == "PLAIN") && confirmed != 0) throw new IOError.FAILED("Unverified SCRAM pin");
    } finally {
        Source.remove(timer);
        stream.cancel();
        stream.detach_modules();
    }
}

int main(string[] crt_args) {
#if WINDOWS
    string[] args = GLib.Win32.get_command_line();
#else
    string[] args = crt_args;
#endif
    var loop = new MainLoop();
    int status = 0;
    run_case.begin(args, (obj, res) => {
        try { run_case.end(res); }
        catch (Error error) { stderr.printf("FAIL: %s\n", error.message); status = 1; }
        loop.quit();
    });
    loop.run();
    return status;
}
