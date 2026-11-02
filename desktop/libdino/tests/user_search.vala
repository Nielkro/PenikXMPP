using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Test {

class UserSearchTest : Gee.TestCase {
    public UserSearchTest() {
        base("UserSearch");
        add_test("failed_component_check_is_not_directory_absence", () => { run_discovery_case(0); });
        add_test("failed_component_does_not_hide_working_directory", () => { run_discovery_case(1); });
        add_test("completed_checks_without_search_return_no_directory", () => { run_discovery_case(2); });
    }

    private void run_discovery_case(int scenario) {
        string? directory = null;
        Database? db = null;
        UserSearchDiscoveryStream? stream = null;
        try {
            directory = DirUtils.make_tmp("dinox-user-search-XXXXXX");
            db = new Database(Path.build_filename((!) directory, "dino.db"), "user-search-test");
            var interactor = new StreamInteractor.for_tests((!) db);
            var account = new Account(new Jid("user@example.test"), "secret") { enabled = true };
            stream = new UserSearchDiscoveryStream(new Jid("example.test"), scenario);
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid.with_resource("desktop");
            bind.finished = true;
            ((!) stream).add_flag(bind);
            ((!) stream).negotiation_complete = true;
            interactor.connection_manager.set_connected_stream_for_tests(account, (!) stream);
            var service = new UserSearch(interactor);
            bool done = false;
            bool expired = false;
            Jid? result = null;
            Error? failure = null;
            var timeout = new TimeoutSource(2000);
            timeout.set_callback(() => {
                expired = true;
                return Source.REMOVE;
            });
            timeout.attach(null);
            service.find_search_component.begin(account, null, (obj, res) => {
                try {
                    result = service.find_search_component.end(res);
                } catch (Error e) {
                    failure = e.copy();
                }
                done = true;
            });
            while (!done && !expired) MainContext.default().iteration(true);
            timeout.destroy();
            fail_if(expired, "Directory discovery did not complete in the fake stream");
            if (scenario == 0) {
                fail_if(failure == null, "A failed component check must not prove directory absence");
                if (failure != null) {
                    fail_if(!(failure is IOError.FAILED), "The real discovery failure must be preserved");
                    fail_if(!failure.message.contains("service-unavailable"), "The IQ error condition must survive discovery");
                }
                fail_if(result != null, "Failed discovery must not select an unadvertised target");
            } else if (scenario == 1) {
                fail_if(failure != null, failure != null ? failure.message : null);
                fail_if_not_eq_str(result != null ? result.to_string() : null, "vjud.example.test");
                fail_if(((!) stream).failed_checks != 1 || ((!) stream).directory_checks != 1,
                        "Discovery must continue from the failed component to the advertised directory");
            } else {
                fail_if(failure != null, failure != null ? failure.message : null);
                fail_if(result != null, "A complete discovery with no search feature must return no directory");
            }
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (stream != null) {
                ((!) stream).get_module<Iq.Module>(Iq.Module.IDENTITY).detach((!) stream);
            }
            if (db != null) ((!) db).close();
            if (directory != null) {
                string path = Path.build_filename((!) directory, "dino.db");
                FileUtils.remove(path);
                FileUtils.remove(path + "-shm");
                FileUtils.remove(path + "-wal");
                DirUtils.remove((!) directory);
            }
        }
    }
}

private class UserSearchDiscoveryStream : XmppStream {
    private int scenario;
    public int failed_checks = 0;
    public int directory_checks = 0;

    public UserSearchDiscoveryStream(Jid remote_name, int scenario) {
        base(remote_name);
        this.scenario = scenario;
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
        add_module(new ServiceDiscovery.Module.with_identity("client", "pc", "Directory test"));
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("Test stream has no reader");
    }

    public override async void write_async(StanzaNode request,
            int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) ((!) cancellable).set_error_if_cancelled();
        request.to_xml();
        var response = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("type", "result")
                .put_attribute("id", request.get_attribute("id"))
                .put_attribute("from", request.get_attribute("to"));
        StanzaNode? items = request.get_subnode("query", ServiceDiscovery.NS_URI_ITEMS);
        if (items != null) {
            var query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns();
            query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                    .put_attribute("jid", scenario == 2 ? "ordinary.example.test" : "offline.example.test"));
            if (scenario == 1) {
                query.put_node(new StanzaNode.build("item", ServiceDiscovery.NS_URI_ITEMS)
                        .put_attribute("jid", "vjud.example.test"));
            }
            response.put_node(query);
        } else if (request.get_attribute("to") == "offline.example.test") {
            failed_checks++;
            response.set_attribute("type", "error");
            response.put_node(new StanzaNode.build("error", "jabber:client")
                    .put_attribute("type", "cancel")
                    .put_node(new StanzaNode.build("service-unavailable",
                    "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
        } else {
            bool directory = request.get_attribute("to") == "vjud.example.test";
            if (directory) directory_checks++;
            var query = new StanzaNode.build("query", ServiceDiscovery.NS_URI_INFO).add_self_xmlns();
            query.put_node(new StanzaNode.build("identity", ServiceDiscovery.NS_URI_INFO)
                    .put_attribute("category", directory ? "directory" : "server")
                    .put_attribute("type", directory ? "user" : "im"));
            query.put_node(new StanzaNode.build("feature", ServiceDiscovery.NS_URI_INFO)
                    .put_attribute("var", directory ? Search.NS_URI : ServiceDiscovery.NS_URI_INFO));
            response.put_node(query);
        }
        Idle.add(() => {
            received_iq_stanza(this, response);
            return Source.REMOVE;
        });
    }
}

}
