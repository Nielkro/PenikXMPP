using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private const uint WAIT_TIMEOUT_MS = 5000;

private class RecordingTransport : Object, EngineJingleWireTransport {
    public Jid local_full_jid { get; private set; }
    public ArrayList<Iq.Stanza> jingle_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> result_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> error_iqs = new ArrayList<Iq.Stanza>();

    public signal void jingle_iq_sent(Iq.Stanza iq);
    public signal void result_iq_sent(Iq.Stanza iq);
    public signal void error_iq_sent(Iq.Stanza iq);

    public RecordingTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_jingle_iq(Jid to, StanzaNode jingle) {
        Iq.Stanza iq = new Iq.Stanza.set(jingle) { from=local_full_jid, to=to };
        jingle_iqs.add(iq);
        jingle_iq_sent(iq);
    }

    public void send_result_iq(Iq.Stanza request_iq) {
        Iq.Stanza result = new Iq.Stanza.result(request_iq) { from=local_full_jid, to=request_iq.from };
        result_iqs.add(result);
        result_iq_sent(result);
    }

    public void send_error_iq(Iq.Stanza request_iq, ErrorStanza error) {
        Iq.Stanza error_iq = new Iq.Stanza.error(request_iq, error) { from=local_full_jid, to=request_iq.from };
        error_iqs.add(error_iq);
        error_iq_sent(error_iq);
    }
}

private class SignalWaiter : Object {
    private MainLoop loop = new MainLoop();
    private uint timeout_id = 0;
    public bool timed_out { get; private set; default = false; }
    public string? error_message { get; set; default = null; }

    public void run_until_signal() {
        timeout_id = Timeout.add(WAIT_TIMEOUT_MS, () => {
            timed_out = true;
            timeout_id = 0;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
    }

    public void finish() {
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
        loop.quit();
    }
}

private Iq.Stanza wait_for_jingle_iq(
        RecordingTransport transport,
        EngineJingleWireSession session,
        int index,
        string label) throws Error {
    if (transport.jingle_iqs.size > index) return transport.jingle_iqs[index];

    var waiter = new SignalWaiter();
    ulong sent_handler = transport.jingle_iq_sent.connect((iq) => {
        if (transport.jingle_iqs.size > index) waiter.finish();
    });
    ulong failed_handler = session.failed.connect((message) => {
        waiter.error_message = message;
        waiter.finish();
    });

    waiter.run_until_signal();
    transport.disconnect(sent_handler);
    session.disconnect(failed_handler);

    if (waiter.timed_out) {
        throw new IOError.TIMED_OUT(@"timed out waiting for $(label)");
    }
    if (waiter.error_message != null) {
        throw new IOError.FAILED(@"session failed while waiting for $(label): $((!) waiter.error_message)");
    }
    if (transport.jingle_iqs.size <= index) {
        throw new IOError.FAILED(@"missing $(label)");
    }
    return transport.jingle_iqs[index];
}

private void wait_for_active(EngineJingleWireSession session, string label) throws Error {
    if (session.state == SignalingState.ACTIVE) return;

    var waiter = new SignalWaiter();
    ulong active_handler = session.active.connect(() => {
        waiter.finish();
    });
    ulong failed_handler = session.failed.connect((message) => {
        waiter.error_message = message;
        waiter.finish();
    });

    waiter.run_until_signal();
    session.disconnect(active_handler);
    session.disconnect(failed_handler);

    if (waiter.timed_out) {
        throw new IOError.TIMED_OUT(@"timed out waiting for $(label)");
    }
    if (waiter.error_message != null) {
        throw new IOError.FAILED(@"session failed while waiting for $(label): $((!) waiter.error_message)");
    }
    if (session.state != SignalingState.ACTIVE) {
        throw new IOError.FAILED(@"missing $(label)");
    }
}

private StanzaNode get_jingle(Iq.Stanza iq) throws Error {
    StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
    if (jingle == null) {
        throw new IOError.FAILED("IQ is missing Jingle payload");
    }
    return (!) jingle;
}

private Iq.Stanza build_empty_jingle_iq(Jid from, Jid to, string sid, string action) {
    StanzaNode jingle = new StanzaNode.build("jingle", Jingle.NS_URI)
        .add_self_xmlns()
        .put_attribute("sid", sid)
        .put_attribute("action", action);
    return new Iq.Stanza.set(jingle) { from=from, to=to };
}

private void assert_handle_fails_with_error_iq(
        EngineJingleWireSession session,
        RecordingTransport transport,
        Iq.Stanza iq,
        int expected_error_count,
        string expected_condition,
        string label) throws Error {
    bool threw = false;
    try {
        session.handle_iq_set(iq);
    } catch (Error e) {
        threw = true;
    }
    if (!threw) {
        throw new IOError.FAILED(@"$(label) should have failed");
    }
    assert_int_eq(transport.error_iqs.size, expected_error_count, @"$(label) error IQ count");
    Iq.Stanza response = transport.error_iqs[expected_error_count - 1];
    assert_str_eq(response.id, iq.id, @"$(label) error IQ id");
    ErrorStanza? error = ErrorStanza.from_stanza(response.stanza);
    if (error == null) throw new IOError.FAILED(@"$(label) is missing an error element");
    assert_str_eq(((!) error).condition, expected_condition, @"$(label) error condition");
    bool has_out_of_order = ((!) error).error_node.get_subnode(
        "out-of-order", "urn:xmpp:jingle:errors:1") != null;
    assert_int_eq(has_out_of_order ? 1 : 0,
        expected_condition == ErrorStanza.CONDITION_UNEXPECTED_REQUEST ? 1 : 0,
        @"$(label) Jingle application condition");
}

private void assert_int_eq(int actual, int expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual) != $(expected)");
    }
}

private void assert_str_eq(string? actual, string expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): '$(actual ?? "(null)")' != '$(expected)'");
    }
}

private void assert_jid_eq(Jid? actual, Jid expected, string message) throws Error {
    if (actual == null || !((!) actual).equals(expected)) {
        throw new IOError.FAILED(@"$(message): '$((actual == null) ? "(null)" : ((!) actual).to_string())' != '$(expected.to_string())'");
    }
}

private int run_smoke() {
    EngineContext? context = null;
    EngineJingleWireSession? initiator = null;
    EngineJingleWireSession? responder = null;

    try {
        context = new EngineContext();
        var initiator_jid = new Jid("alice@example.test/DinoX");
        var responder_jid = new Jid("bob@example.test/Phone");
        var initiator_transport = new RecordingTransport(initiator_jid);
        var responder_transport = new RecordingTransport(responder_jid);

        initiator = new EngineJingleWireSession.outgoing(
            ((!) context).create_session(),
            initiator_transport,
            "wire-smoke",
            initiator_jid,
            responder_jid);
        responder = new EngineJingleWireSession.incoming(
            ((!) context).create_session(),
            responder_transport,
            "wire-smoke",
            responder_jid,
            initiator_jid);

        var mallory_jid = new Jid("mallory@example.test/Evil");
        assert_handle_fails_with_error_iq(
            (!) responder,
            responder_transport,
            build_empty_jingle_iq(mallory_jid, responder_jid, "wire-smoke", "transport-info"),
            1,
            ErrorStanza.CONDITION_BAD_REQUEST,
            "unexpected peer guard");
        assert_handle_fails_with_error_iq(
            (!) responder,
            responder_transport,
            build_empty_jingle_iq(initiator_jid, responder_jid, "wrong-sid", "transport-info"),
            2,
            ErrorStanza.CONDITION_BAD_REQUEST,
            "unexpected SID guard");

        assert_handle_fails_with_error_iq(
            (!) responder,
            responder_transport,
            build_empty_jingle_iq(initiator_jid, responder_jid, "wire-smoke", "transport-info"),
            3,
            ErrorStanza.CONDITION_UNEXPECTED_REQUEST,
            "transport-info before session-initiate");
        assert_int_eq(responder_transport.result_iqs.size, 0,
            "early transport-info must not be acknowledged");
        assert_int_eq(((!) responder).state == SignalingState.NEW ? 1 : 0, 1,
            "early transport-info preserves the incoming signaling state");

        ((!) initiator).start_outgoing_offer();
        Iq.Stanza initiate_iq = wait_for_jingle_iq(initiator_transport, (!) initiator, 0, "session-initiate IQ");
        StanzaNode initiate = get_jingle(initiate_iq);
        assert_str_eq(initiate_iq.type_, Iq.Stanza.TYPE_SET, "initiate IQ type");
        assert_jid_eq(initiate_iq.from, initiator_jid, "initiate IQ from");
        assert_jid_eq(initiate_iq.to, responder_jid, "initiate IQ to");
        assert_str_eq(initiate.get_attribute("action"), "session-initiate", "initiate action");
        assert_str_eq(initiate.get_attribute("sid"), "wire-smoke", "initiate SID");
        assert_int_eq(initiate.get_subnodes("content", Jingle.NS_URI).size, 2, "initiate content count");

        ((!) responder).handle_iq_set(initiate_iq);
        assert_int_eq(responder_transport.result_iqs.size, 1, "responder ACK count");
        assert_str_eq(responder_transport.result_iqs[0].id, initiate_iq.id, "responder ACK id");
        assert_jid_eq(responder_transport.result_iqs[0].to, initiator_jid, "responder ACK to");

        Iq.Stanza accept_iq = wait_for_jingle_iq(responder_transport, (!) responder, 0, "session-accept IQ");
        StanzaNode accept = get_jingle(accept_iq);
        assert_str_eq(accept_iq.type_, Iq.Stanza.TYPE_SET, "accept IQ type");
        assert_jid_eq(accept_iq.from, responder_jid, "accept IQ from");
        assert_jid_eq(accept_iq.to, initiator_jid, "accept IQ to");
        assert_str_eq(accept.get_attribute("action"), "session-accept", "accept action");
        assert_str_eq(accept.get_attribute("sid"), "wire-smoke", "accept SID");
        assert_int_eq(accept.get_subnodes("content", Jingle.NS_URI).size, 2, "accept content count");
        wait_for_active((!) responder, "responder active");

        ((!) initiator).handle_iq_set(accept_iq);
        assert_int_eq(initiator_transport.result_iqs.size, 1, "initiator ACK count");
        assert_str_eq(initiator_transport.result_iqs[0].id, accept_iq.id, "initiator ACK id");
        assert_jid_eq(initiator_transport.result_iqs[0].to, responder_jid, "initiator ACK to");
        wait_for_active((!) initiator, "initiator active");

        assert_int_eq(initiator_transport.error_iqs.size, 0, "initiator error count");
        assert_int_eq(responder_transport.error_iqs.size, 3, "responder error count");

        ((!) responder).close();
        ((!) initiator).close();
        ((!) context).close();
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-jingle-wire-smoke failed: %s\n", e.message);
        if (responder != null) ((!) responder).close();
        if (initiator != null) ((!) initiator).close();
        if (context != null) ((!) context).close();
        return 1;
    }
}

}

public int main(string[] args) {
    return Dino.Plugins.GoogleWebrtc.Test.run_smoke();
}
