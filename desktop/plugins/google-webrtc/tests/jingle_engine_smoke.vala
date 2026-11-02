using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private const uint WAIT_TIMEOUT_MS = 5000;

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

private StanzaNode wait_for_outgoing_jingle(EngineJingleSession session, string label) throws Error {
    var waiter = new SignalWaiter();
    StanzaNode? node = null;

    ulong jingle_handler = session.outgoing_jingle.connect((jingle) => {
        node = jingle;
        waiter.finish();
    });
    ulong failed_handler = session.failed.connect((message) => {
        waiter.error_message = message;
        waiter.finish();
    });

    waiter.run_until_signal();
    session.disconnect(jingle_handler);
    session.disconnect(failed_handler);

    if (waiter.timed_out) {
        throw new IOError.TIMED_OUT(@"timed out waiting for $(label)");
    }
    if (waiter.error_message != null) {
        throw new IOError.FAILED(@"session failed while waiting for $(label): $((!) waiter.error_message)");
    }
    if (node == null) {
        throw new IOError.FAILED(@"missing $(label)");
    }
    return (!) node;
}

private void wait_for_active(EngineJingleSession session, string label) throws Error {
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

private void assert_true(bool condition, string message) throws Error {
    if (!condition) {
        throw new IOError.FAILED(message);
    }
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

private StanzaNode make_early_transport_info(StanzaNode description) throws Error {
    Gee.List<StanzaNode> contents = description.get_subnodes("content", Jingle.NS_URI);
    if (contents.is_empty) {
        throw new IOError.FAILED("session description has no content for early ICE");
    }
    StanzaNode content = contents[0];
    StanzaNode? source_transport = content.get_subnode("transport", JingleIceUdp.NS_URI);
    string? content_name = content.get_attribute("name");
    string? sid = description.get_attribute("sid");
    string? ufrag = source_transport != null ? ((!) source_transport).get_attribute("ufrag") : null;
    string? pwd = source_transport != null ? ((!) source_transport).get_attribute("pwd") : null;
    if (content_name == null || sid == null || ufrag == null || pwd == null) {
        throw new IOError.FAILED("session description has incomplete ICE credentials");
    }
    JingleIceUdp.Candidate candidate = JingleRtp.SdpBridge.candidate_from_sdp(
        "a=candidate:early 1 udp 2130706431 192.0.2.10 5000 typ host generation 0");
    return new StanzaNode.build("jingle", Jingle.NS_URI)
        .add_self_xmlns()
        .put_attribute("action", "transport-info")
        .put_attribute("sid", (!) sid)
        .put_node(new StanzaNode.build("content", Jingle.NS_URI)
            .put_attribute("creator", Jingle.Role.INITIATOR.to_string())
            .put_attribute("name", (!) content_name)
            .put_node(new StanzaNode.build("transport", JingleIceUdp.NS_URI)
                .add_self_xmlns()
                .put_attribute("ufrag", (!) ufrag)
                .put_attribute("pwd", (!) pwd)
                .put_node(candidate.to_xml())));
}

private int run_smoke() {
    EngineContext? context = null;
    EngineJingleSession? initiator = null;
    EngineJingleSession? responder = null;
    EngineJingleSession? unbundled_muji_initiator = null;
    EngineJingleSession? unbundled_muji_responder = null;
    EngineJingleSession? bundled_initiator = null;
    EngineJingleSession? bundled_responder = null;

    try {
        context = new EngineContext();
        var initiator_jid = new Jid("alice@example.test/DinoX");
        var responder_jid = new Jid("bob@example.test/Phone");
        var bundle_room_jid = new Jid(
            "bundle@conference.example.test");

        var unbundled_initiator_config = new EngineSessionConfig() {
            max_bundle = false
        };
        var unbundled_responder_config = new EngineSessionConfig() {
            max_bundle = false
        };
        initiator = new EngineJingleSession.outgoing(
            ((!) context).create_session(unbundled_initiator_config),
            "engine-jingle-smoke",
            initiator_jid,
            responder_jid);
        responder = new EngineJingleSession.incoming(
            ((!) context).create_session(unbundled_responder_config),
            "engine-jingle-smoke",
            responder_jid,
            initiator_jid);

        ((!) initiator).start_outgoing_offer();
        StanzaNode initiate = wait_for_outgoing_jingle((!) initiator, "session-initiate");
        assert_str_eq(initiate.get_attribute("action"), "session-initiate", "initiate action");
        assert_str_eq(initiate.get_attribute("initiator"), initiator_jid.to_string(), "initiator JID");
        assert_int_eq(initiate.get_subnodes("content", Jingle.NS_URI).size, 2, "initiate content count");
        assert_true(initiate.to_string().contains("urn:xmpp:jingle:transports:ice-udp:1"), "initiate must contain ICE-UDP transport");

        ((!) responder).handle_session_initiate(initiate);
        ((!) responder).handle_transport_info(make_early_transport_info(initiate));
        StanzaNode accept = wait_for_outgoing_jingle((!) responder, "session-accept");
        assert_str_eq(accept.get_attribute("action"), "session-accept", "accept action");
        assert_str_eq(accept.get_attribute("responder"), responder_jid.to_string(), "responder JID");
        assert_int_eq(accept.get_subnodes("content", Jingle.NS_URI).size, 2, "accept content count");
        wait_for_active((!) responder, "responder active");

        ((!) initiator).handle_session_accept(accept);
        ((!) initiator).handle_transport_info(make_early_transport_info(accept));
        wait_for_active((!) initiator, "initiator active");

        unbundled_muji_initiator = new EngineJingleSession.muji_outgoing(
            ((!) context).create_session(unbundled_initiator_config),
            "engine-jingle-muji-unbundled-smoke",
            initiator_jid,
            responder_jid,
            bundle_room_jid);
        unbundled_muji_responder = new EngineJingleSession.muji_incoming(
            ((!) context).create_session(unbundled_responder_config),
            "engine-jingle-muji-unbundled-smoke",
            responder_jid,
            initiator_jid,
            bundle_room_jid);
        ((!) unbundled_muji_initiator).start_outgoing_offer();
        StanzaNode unbundled_muji_initiate = wait_for_outgoing_jingle(
            (!) unbundled_muji_initiator,
            "unbundled MUJI session-initiate");
        assert_int_eq(
            unbundled_muji_initiate.get_subnodes(
                "group", JINGLE_GROUPING_NS).size,
            0,
            "unbundled MUJI offer must not advertise BUNDLE");
        ((!) unbundled_muji_responder).handle_session_initiate(
            unbundled_muji_initiate);
        StanzaNode unbundled_muji_accept = wait_for_outgoing_jingle(
            (!) unbundled_muji_responder,
            "unbundled MUJI session-accept");
        assert_int_eq(
            unbundled_muji_accept.get_subnodes(
                "group", JINGLE_GROUPING_NS).size,
            0,
            "unbundled MUJI answer must not add BUNDLE");
        ((!) unbundled_muji_initiator).handle_session_accept(
            unbundled_muji_accept);
        wait_for_active(
            (!) unbundled_muji_initiator,
            "unbundled MUJI initiator active");

        var bundled_initiator_config = new EngineSessionConfig() {
            max_bundle = false
        };
        var bundled_responder_config = new EngineSessionConfig() {
            max_bundle = false
        };
        bundled_initiator = new EngineJingleSession.outgoing_with_bundle(
            ((!) context).create_session(bundled_initiator_config),
            "engine-jingle-bundle-answer-smoke",
            initiator_jid,
            responder_jid,
            bundle_room_jid);
        bundled_responder = new EngineJingleSession.muji_incoming(
            ((!) context).create_session(bundled_responder_config),
            "engine-jingle-bundle-answer-smoke",
            responder_jid,
            initiator_jid,
            bundle_room_jid);
        ((!) bundled_initiator).start_outgoing_offer();
        StanzaNode bundled_initiate = wait_for_outgoing_jingle(
            (!) bundled_initiator, "bundled session-initiate");
        assert_int_eq(
            bundled_initiate.get_subnodes("group", JINGLE_GROUPING_NS).size,
            1,
            "bundled initiate group count");
        ((!) bundled_responder).handle_session_initiate(bundled_initiate);
        StanzaNode bundled_accept = wait_for_outgoing_jingle(
            (!) bundled_responder, "bundled session-accept");
        StanzaNode? accepted_group = bundled_accept.get_subnode(
            "group", JINGLE_GROUPING_NS);
        assert_true(accepted_group != null, "bundled answer must confirm BUNDLE");
        bundled_accept.sub_nodes.remove((!) accepted_group);
        ((!) bundled_initiator).handle_session_accept(bundled_accept);
        wait_for_active(
            (!) bundled_initiator,
            "initiator active after a valid answer without BUNDLE");

        ((!) bundled_responder).close();
        ((!) bundled_initiator).close();
        ((!) unbundled_muji_responder).close();
        ((!) unbundled_muji_initiator).close();
        ((!) responder).close();
        ((!) initiator).close();
        ((!) context).close();
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-jingle-engine-smoke failed: %s\n", e.message);
        if (bundled_responder != null) ((!) bundled_responder).close();
        if (bundled_initiator != null) ((!) bundled_initiator).close();
        if (unbundled_muji_responder != null) {
            ((!) unbundled_muji_responder).close();
        }
        if (unbundled_muji_initiator != null) {
            ((!) unbundled_muji_initiator).close();
        }
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
