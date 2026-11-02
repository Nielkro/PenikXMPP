namespace Xmpp.Test {

// Exercise the real startup modules without a network/account database.
class ReconnectStartupTest : Gee.TestCase {
    public ReconnectStartupTest() {
        base("ReconnectStartup");
        add_async_test("cancelled_startup_is_quiet_and_replacement_reloads",
            (cb) => { test_replacement.begin(cb); });
        add_async_test("real_startup_errors_remain_visible",
            (cb) => { test_real_errors.begin(cb); });
        add_async_test("cancelled_carbons_disable_completes",
            (cb) => { test_disable.begin(cb); });
    }

    private ReconnectStartupStream create_stream(Xep.MessageCarbons.Module carbons,
            Xep.BlockingCommand.Module blocking) throws Error {
        var stream = new ReconnectStartupStream(new Jid("example.test"));
        var bind = new Bind.Flag();
        bind.my_jid = new Jid("alice@example.test/dinox");
        bind.finished = true;
        stream.add_flag(bind);
        stream.negotiation_complete = true;
        stream.add_module(new Iq.Module());
        var disco = new Xep.ServiceDiscovery.Module.with_identity("client", "pc", "Test");
        disco.cache = new ReconnectStartupCapsCache();
        stream.add_module(disco);
        stream.add_module(new MessageModule());
        stream.add_module(carbons);
        stream.add_module(blocking);
        return stream;
    }

    // All fixture replies use idle callbacks; drain their async continuations.
    private async void settle() {
        for (int i = 0; i < 16; i++) {
            Idle.add(() => { settle.callback(); return Source.REMOVE; });
            yield;
        }
    }

    private async void test_replacement(Gee.TestFinishedCallback cb) {
        try {
            var carbons = new Xep.MessageCarbons.Module();
            var blocking = new Xep.BlockingCommand.Module();
            var old_stream = create_stream(carbons, blocking);
            old_stream.hold_responses = true;
            old_stream.stream_negotiated(old_stream);
            yield settle();
            fail_if(old_stream.writes.size != 2, "Both startup requests must be in flight");
            // Match the detach ordering: IQ waiters resume before the other
            // modules are detached. Unexpected warnings are fatal in g_test.
            old_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(old_stream);
            yield settle();
            carbons.detach(old_stream);
            blocking.detach(old_stream);

            var current = create_stream(carbons, blocking);
            current.stream_negotiated(current);
            yield settle();
            fail_if(current.writes.size != 2, "Replacement must repeat both startup requests");
            fail_if(!current.get_flag(Xep.BlockingCommand.Flag.IDENTITY)
                .blocklist.contains("spam@example.test"), "Replacement must load the server blocklist");
            foreach (var request in old_stream.writes) old_stream.reply(request);
            yield settle();
            fail_if(current.writes.size != 2, "Late old replies must not restart current requests");
            current.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(current);
            carbons.detach(current);
            blocking.detach(current);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }

    private async void test_real_errors(Gee.TestFinishedCallback cb) {
        try {
            var carbons = new Xep.MessageCarbons.Module();
            var blocking = new Xep.BlockingCommand.Module();
            var stream = create_stream(carbons, blocking);
            stream.fail_writes = true;
            // Start each operation separately so log ordering is deterministic.
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to enable carbons:*scripted transport failure*");
            yield carbons.enable(stream);
            GLib.Test.assert_expected_messages();
            carbons.detach(stream);
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to get blocklist:*scripted transport failure*");
            stream.stream_negotiated(stream);
            yield settle();
            GLib.Test.assert_expected_messages();
            blocking.detach(stream);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }

    private async void test_disable(Gee.TestFinishedCallback cb) {
        try {
            var carbons = new Xep.MessageCarbons.Module();
            var blocking = new Xep.BlockingCommand.Module();
            var stream = create_stream(carbons, blocking);
            stream.hold_responses = true;
            bool completed = false;
            carbons.disable.begin(stream, (_, res) => {
                carbons.disable.end(res);
                completed = true;
            });
            yield settle();
            fail_if(stream.writes.size != 1, "Disable must send one request");
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            yield settle();
            fail_if(!completed, "Cancelled disable must release its waiter");
            carbons.detach(stream);
            blocking.detach(stream);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }
}

private class ReconnectStartupCapsCache : Object, Xep.ServiceDiscovery.CapsCache {
    public async bool has_entity_feature(Jid jid, string feature) {
        return feature == "urn:xmpp:blocking";
    }
    public async Gee.Set<Xep.ServiceDiscovery.Identity> get_entity_identities(Jid jid) {
        return new Gee.HashSet<Xep.ServiceDiscovery.Identity>(
            Xep.ServiceDiscovery.Identity.hash_func, Xep.ServiceDiscovery.Identity.equals_func);
    }
}

private class ReconnectStartupStream : XmppStream {
    public Gee.ArrayList<StanzaNode> writes = new Gee.ArrayList<StanzaNode>();
    public bool hold_responses = false;
    public bool fail_writes = false;

    public ReconnectStartupStream(Jid remote) { base(remote); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("No network in reconnect test");
    }
    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        writes.add(node);
        if (fail_writes) throw new IOError.FAILED("scripted transport failure");
        if (!hold_responses) Idle.add(() => { reply(node); return Source.REMOVE; });
    }

    public void reply(StanzaNode request) {
        var result = new StanzaNode.build("iq")
            .put_attribute("type", "result").put_attribute("id", request.get_attribute("id"));
        if (request.get_subnode("blocklist", "urn:xmpp:blocking") != null) {
            result.put_node(new StanzaNode.build("blocklist", "urn:xmpp:blocking")
                .put_node(new StanzaNode.build("item", "urn:xmpp:blocking")
                    .put_attribute("jid", "spam@example.test")));
        }
        received_iq_stanza(this, result);
    }
}

}
