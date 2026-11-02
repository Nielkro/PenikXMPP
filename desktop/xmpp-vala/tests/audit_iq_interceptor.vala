namespace Xmpp.Test {

class IqInterceptorAudit : Gee.TestCase {
    private const string TEST_NS = "urn:dinox:test:iq-interceptor";
    private const string STANZAS_NS = "urn:ietf:params:xml:ns:xmpp-stanzas";

    public IqInterceptorAudit() {
        base("IqInterceptorAudit");

        add_async_test("interceptor_consumes_before_namespace_handler", (cb) => {
            test_interceptor_consumes_before_namespace_handler.begin(cb);
        });
        add_async_test("interceptor_can_fall_back_to_namespace_handler", (cb) => {
            test_interceptor_can_fall_back_to_namespace_handler.begin(cb);
        });
        add_async_test("interceptor_decline_without_handler_returns_service_unavailable", (cb) => {
            test_interceptor_decline_without_handler_returns_service_unavailable.begin(cb);
        });
    }

    private async void test_interceptor_consumes_before_namespace_handler(Gee.TestFinishedCallback cb) {
        IqInterceptorAuditStream stream = make_stream();
        Iq.Module iq_module = attach_iq_module(stream);
        CountingInterceptor interceptor = new CountingInterceptor(true);
        CountingHandler handler = new CountingHandler();
        int preprocess_count = 0;

        iq_module.preprocess_incoming_iq_set_get.connect(() => {
            preprocess_count++;
        });
        iq_module.register_interceptor_for_namespace(TEST_NS, interceptor);
        iq_module.register_for_namespace(TEST_NS, handler);

        stream.emit_iq(build_set_iq("consume-1"));

        finish_after_dispatch(() => {
            fail_if_not_eq_int(preprocess_count, 1, "IQ preprocess should run once before interceptor handling");
            fail_if_not_eq_int(interceptor.set_calls, 1, "Interceptor should see the IQ set");
            fail_if_not_eq_int(handler.set_calls, 0, "Consumed IQ must not continue into the namespace handler");
            fail_if_not_eq_int(stream.written_nodes.size, 0, "Consumed IQ should not get an automatic fallback error");
        }, cb);
    }

    private async void test_interceptor_can_fall_back_to_namespace_handler(Gee.TestFinishedCallback cb) {
        IqInterceptorAuditStream stream = make_stream();
        Iq.Module iq_module = attach_iq_module(stream);
        CountingInterceptor interceptor = new CountingInterceptor(false);
        CountingHandler handler = new CountingHandler();
        int preprocess_count = 0;

        iq_module.preprocess_incoming_iq_set_get.connect(() => {
            preprocess_count++;
        });
        iq_module.register_interceptor_for_namespace(TEST_NS, interceptor);
        iq_module.register_for_namespace(TEST_NS, handler);

        stream.emit_iq(build_set_iq("fallback-1"));

        finish_after_dispatch(() => {
            fail_if_not_eq_int(preprocess_count, 1, "IQ preprocess should run once before fallback handling");
            fail_if_not_eq_int(interceptor.set_calls, 1, "Interceptor should be allowed to inspect the IQ set");
            fail_if_not_eq_int(handler.set_calls, 1, "Declined IQ must continue into the existing namespace handler");
            fail_if_not_eq_int(stream.written_nodes.size, 0, "Existing handler path should not get an automatic fallback error");
        }, cb);
    }

    private async void test_interceptor_decline_without_handler_returns_service_unavailable(Gee.TestFinishedCallback cb) {
        IqInterceptorAuditStream stream = make_stream();
        Iq.Module iq_module = attach_iq_module(stream);
        CountingInterceptor interceptor = new CountingInterceptor(false);
        int preprocess_count = 0;

        iq_module.preprocess_incoming_iq_set_get.connect(() => {
            preprocess_count++;
        });
        iq_module.register_interceptor_for_namespace(TEST_NS, interceptor);

        stream.emit_iq(build_set_iq("fallback-error-1"));

        finish_after_dispatch(() => {
            fail_if_not_eq_int(preprocess_count, 1, "IQ preprocess should run for interceptor-owned namespaces");
            fail_if_not_eq_int(interceptor.set_calls, 1, "Interceptor should inspect the IQ before declining");
            fail_if_not_eq_int(stream.written_nodes.size, 1, "Declined interceptor-only IQ should return service-unavailable");
            StanzaNode error_iq = stream.written_nodes[0];
            fail_if_not_eq_str(error_iq.get_attribute("type"), Xmpp.Stanza.TYPE_ERROR, "Fallback response should be an IQ error");
            fail_if_not_eq_str(error_iq.get_attribute("id"), "fallback-error-1", "Fallback error should preserve the request id");
            StanzaNode? error_node = error_iq.get_subnode("error");
            fail_if(error_node == null, "Fallback error should contain an <error/> node");
            if (error_node != null) {
                fail_if(error_node.get_subnode(ErrorStanza.CONDITION_SERVICE_UNAVAILABLE, STANZAS_NS) == null,
                    "Fallback error should be service-unavailable");
            }
        }, cb);
    }

    private static IqInterceptorAuditStream make_stream() {
        try {
            return new IqInterceptorAuditStream(new Jid("server.example.test"));
        } catch (InvalidJidError e) {
            fail_if_reached(@"Could not create test stream JID: $(e.message)");
        }
        assert_not_reached();
    }

    private static Iq.Module attach_iq_module(IqInterceptorAuditStream stream) {
        Iq.Module iq_module = new Iq.Module();
        stream.add_module(iq_module);
        iq_module.attach(stream);
        return iq_module;
    }

    private static StanzaNode build_set_iq(string id) {
        return new StanzaNode.build("iq")
            .put_attribute("type", Iq.Stanza.TYPE_SET)
            .put_attribute("id", id)
            .put_attribute("from", "romeo@example.test/mobile")
            .put_node(new StanzaNode.build("payload", TEST_NS).add_self_xmlns());
    }

    private delegate void DeferredAssertion();

    private static void finish_after_dispatch(owned DeferredAssertion assertions, Gee.TestFinishedCallback cb) {
        Timeout.add(50, () => {
            assertions();
            cb();
            return Source.REMOVE;
        });
    }
}

private class CountingInterceptor : Object, Iq.Interceptor {
    public int set_calls { get; private set; default = 0; }
    private bool consume;

    public CountingInterceptor(bool consume) {
        this.consume = consume;
    }

    public async bool try_handle_iq_set(XmppStream stream, Iq.Stanza iq) {
        set_calls++;
        return consume;
    }
}

private class CountingHandler : Object, Iq.Handler {
    public int set_calls { get; private set; default = 0; }

    public async void on_iq_set(XmppStream stream, Iq.Stanza iq) {
        set_calls++;
    }
}

private class IqInterceptorAuditStream : XmppStream {
    public Gee.ArrayList<StanzaNode> written_nodes = new Gee.ArrayList<StanzaNode>();

    public IqInterceptorAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public void emit_iq(StanzaNode node) {
        received_iq_stanza(this, node);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        written_nodes.add(node);
    }

    public override async void setup() throws IOError {
    }
}

}
