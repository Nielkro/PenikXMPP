using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class PasswordChangeTest : Gee.TestCase {
    public PasswordChangeTest() {
        base("PasswordChange");
        add_test("offline_account_is_not_success", () => { run_case("offline"); });
        add_test("unmanaged_equal_jid_account_is_rejected", () => { run_case("stale-account"); });
        add_test("unbound_account_is_rejected", () => { run_case("unbound"); });
        add_test("server_ack_is_the_only_success", () => { run_case("success"); });
        add_test("legal_home_server_senderless_ack_is_success", () => { run_case("senderless"); });
        add_test("server_rejection_is_not_success", () => { run_case("reject"); });
        add_test("write_error_is_not_success", () => { run_case("write-error"); });
        add_test("timeout_is_not_success", () => { run_case("timeout"); });
        add_test("foreign_ack_is_not_success", () => { run_case("foreign-sender"); });
        add_test("malformed_error_is_not_success", () => { run_case("malformed-error"); });
        add_test("confirmed_change_survives_disconnection", () => { run_case("disconnect-before-ack"); });
        add_test("confirmed_change_survives_stream_replacement", () => { run_case("replace-before-ack"); });
    }

    private void run_case(string mode) {
        PasswordChangeFixture? fixture = null;
        try {
            fixture = new PasswordChangeFixture(mode);
            var current = (!) fixture;
            Account target = current.account;
            if (mode == "stale-account") {
                target = new Account(new Jid("user@example.test"), "old-test-password") { enabled = true };
            }
            bool done = false;
            bool expired = false;
            string? result = "unfinished";
            var timeout = new TimeoutSource(2000);
            timeout.set_callback(() => { expired = true; return Source.REMOVE; });
            timeout.attach(null);
            current.registration.change_password.begin(target, "new-test-password", (obj, res) => {
                result = current.registration.change_password.end(res);
                done = true;
            });
            while (!done && !expired) MainContext.default().iteration(true);
            timeout.destroy();
            fail_if(expired, "Password-change fake request did not complete");
            if (mode == "offline" || mode == "stale-account" || mode == "unbound") {
                fail_if_not_eq_str(Register.ERROR_CONNECTION_FAILED, result);
                fail_if(current.stream.writes.size != 0, "Invalid account must not transmit a password");
            } else if (mode == "reject") {
                fail_if_not_eq_str(ErrorStanza.CONDITION_NOT_ALLOWED, result);
            } else if (mode == "success" || mode == "senderless" ||
                    mode == "disconnect-before-ack" || mode == "replace-before-ack") {
                fail_if(result != null, "A valid server acknowledgement must be success");
                fail_if(current.stream.writes.size != 1, "Password change must send exactly one request");
                var request = current.stream.writes[0];
                fail_if(request.get_attribute("to") != "example.test", "Password change must target its home server");
                var query = request.get_subnode("query", InBandRegistration.NS_URI);
                fail_if(query == null, "Password change must use XEP-0077");
                if (query != null) {
                    fail_if(query.get_deep_string_content("username") != "user", "Password change must use the initiating username");
                    fail_if(query.get_deep_string_content("password") != "new-test-password", "The request must contain the chosen credential");
                }
            } else {
                fail_if_not_eq_str(Register.ERROR_NO_RESPONSE, result);
            }
            // Persistence belongs to the view model after confirmed success.
            fail_if(current.account.password != "old-test-password", "The service must not persist an unconfirmed credential");
        } catch (Error e) {
            fail_if_reached("Password-change fixture setup failed");
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }
}

internal class PasswordChangeFixture : Object {
    public string directory;
    public Database db;
    public StreamInteractor interactor;
    public Register registration;
    public Account account;
    public PasswordChangeAuditStream stream;
    public PasswordChangeAuditStream? replacement;

    public PasswordChangeFixture(string mode) throws Error {
        directory = DirUtils.make_tmp("dinox-password-change-XXXXXX");
        db = new Database(Path.build_filename(directory, "dino.db"), "password-change-test");
        interactor = new StreamInteractor.for_tests(db);
        Register.start(interactor, db);
        registration = interactor.get_module<Register>(Register.IDENTITY);
        account = new Account(new Jid("user@example.test"), "old-test-password") { enabled = true };
        account.persist(db);
        stream = new PasswordChangeAuditStream(new Jid("example.test"), mode);
        if (mode != "unbound") attach_binding(stream, account);
        stream.negotiation_complete = true;
        if (mode != "offline") interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        if (mode == "disconnect-before-ack") {
            stream.before_response = () => {
                interactor.connection_manager.set_provisional_disconnected_for_tests(account);
            };
        } else if (mode == "replace-before-ack") {
            replacement = new PasswordChangeAuditStream(new Jid("example.test"), "success");
            attach_binding((!) replacement, account);
            ((!) replacement).negotiation_complete = true;
            stream.before_response = () => {
                interactor.connection_manager.set_connected_stream_for_tests(account, (!) replacement);
            };
        }
    }

    private static void attach_binding(XmppStream stream, Account account) throws Error {
        var bind = new Bind.Flag();
        bind.my_jid = account.bare_jid.with_resource("desktop");
        bind.finished = true;
        stream.add_flag(bind);
    }

    public void close() {
        stream.before_response = null;
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
        if (replacement != null) ((!) replacement).get_module<Iq.Module>(Iq.Module.IDENTITY).detach((!) replacement);
        db.close();
        string path = Path.build_filename(directory, "dino.db");
        FileUtils.remove(path);
        FileUtils.remove(path + "-shm");
        FileUtils.remove(path + "-wal");
        DirUtils.remove(directory);
    }
}

internal class PasswordChangeAuditStream : XmppStream {
    public delegate void BeforeResponse();
    public BeforeResponse? before_response;
    public ArrayList<StanzaNode> writes = new ArrayList<StanzaNode>();
    private string mode;

    public PasswordChangeAuditStream(Jid remote_name, string mode) {
        base(remote_name);
        this.mode = mode;
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new InBandRegistration.Module());
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Fixture has no reader");
    }

    public override async void write_async(StanzaNode request,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        request.to_xml();
        writes.add(request);
        if (mode == "write-error") throw new IOError.NOT_CONNECTED("Fixture write failure");
        if (mode == "timeout") throw new IOError.TIMED_OUT("Fixture response timeout");
        respond(request);
    }

    private void respond(StanzaNode request) {
        Idle.add(() => {
            if (before_response != null) ((!) before_response)();
            var response = new StanzaNode.build("iq", "jabber:client")
                    .put_attribute("type", "result")
                    .put_attribute("id", request.get_attribute("id"));
            if (mode != "senderless") {
                response.put_attribute("from", mode == "foreign-sender" ? "foreign.example.test" : "example.test");
            }
            if (mode == "reject" || mode == "malformed-error") {
                response.set_attribute("type", "error");
                if (mode == "reject") {
                    response.put_node(new StanzaNode.build("error", "jabber:client")
                            .put_attribute("type", "cancel")
                            .put_node(new StanzaNode.build("not-allowed",
                            "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
                }
            }
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }
}

}
