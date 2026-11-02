using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private const uint WAIT_TIMEOUT_MS = 5000;
private const int64 AUDIO_SAMPLE_TIMEOUT_US = 10000 * 1000;

private class RecordingTransport : Object, EngineJingleWireTransport {
    public Jid local_full_jid { get; private set; }
    public ArrayList<Iq.Stanza> jingle_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> result_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> error_iqs = new ArrayList<Iq.Stanza>();

    public signal void jingle_iq_sent(Iq.Stanza iq);

    public RecordingTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_jingle_iq(Jid to, StanzaNode jingle) {
        Iq.Stanza iq = new Iq.Stanza.set(jingle) { from=local_full_jid, to=to };
        jingle_iqs.add(iq);
        jingle_iq_sent(iq);
    }

    public void send_result_iq(Iq.Stanza request_iq) {
        result_iqs.add(new Iq.Stanza.result(request_iq) { from=local_full_jid, to=request_iq.from });
    }

    public void send_error_iq(Iq.Stanza request_iq, ErrorStanza error) {
        error_iqs.add(new Iq.Stanza.error(request_iq, error) { from=local_full_jid, to=request_iq.from });
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

private EngineSessionConfig audio_only_config() {
    var config = new EngineSessionConfig();
    config.audio_enabled = true;
    config.video_enabled = false;
    return config;
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

private StanzaNode get_single_content(StanzaNode jingle, string label) throws Error {
    Gee.List<StanzaNode> contents = jingle.get_subnodes("content", Jingle.NS_URI);
    if (contents.size != 1) {
        throw new IOError.FAILED(@"$(label) must contain exactly one Jingle content, got $(contents.size)");
    }
    return contents[0];
}

private StanzaNode get_single_description(StanzaNode content, string label) throws Error {
    StanzaNode? description = content.get_subnode("description", JingleRtp.NS_URI);
    if (description == null) {
        throw new IOError.FAILED(@"$(label) is missing RTP description");
    }
    return (!) description;
}

private StanzaNode get_single_transport(StanzaNode content, string label) throws Error {
    StanzaNode? transport = content.get_subnode("transport", JingleIceUdp.NS_URI);
    if (transport == null) {
        throw new IOError.FAILED(@"$(label) is missing ICE-UDP transport");
    }
    return (!) transport;
}

private void assert_transport_info_jingle(StanzaNode jingle, string expected_sid, string label) throws Error {
    assert_str_eq(jingle.get_attribute("action"), "transport-info", @"$(label) action");
    assert_str_eq(jingle.get_attribute("sid"), expected_sid, @"$(label) SID");
    StanzaNode content = get_single_content(jingle, label);
    StanzaNode transport = get_single_transport(content, label);
    Gee.List<StanzaNode> candidates = transport.get_subnodes("candidate", JingleIceUdp.NS_URI);
    if (candidates.size != 1) {
        throw new IOError.FAILED(@"$(label) must contain exactly one ICE candidate, got $(candidates.size)");
    }
    if (transport.get_attribute("ufrag") == null || transport.get_attribute("pwd") == null) {
        throw new IOError.FAILED(@"$(label) is missing ICE credentials");
    }
}

private void assert_session_terminate_jingle(
        StanzaNode jingle,
        string expected_sid,
        string expected_reason,
        string expected_text,
        string label) throws Error {
    assert_str_eq(jingle.get_attribute("action"), "session-terminate", @"$(label) action");
    assert_str_eq(jingle.get_attribute("sid"), expected_sid, @"$(label) SID");

    StanzaNode? reason = jingle.get_subnode("reason", Jingle.NS_URI);
    if (reason == null) {
        throw new IOError.FAILED(@"$(label) is missing terminate reason");
    }
    if (((!) reason).get_subnode(expected_reason, Jingle.NS_URI) == null) {
        throw new IOError.FAILED(@"$(label) is missing terminate reason $(expected_reason)");
    }
    StanzaNode? text = ((!) reason).get_subnode("text", Jingle.NS_URI);
    if (text == null) {
        throw new IOError.FAILED(@"$(label) is missing terminate reason text");
    }
    assert_str_eq(((!) text).get_string_content(), expected_text, @"$(label) terminate text");
}

private bool description_has_payload(StanzaNode description, string name, string clockrate) {
    foreach (StanzaNode payload in description.get_subnodes("payload-type", JingleRtp.NS_URI)) {
        if (payload.get_attribute("name") == name &&
                payload.get_attribute("clockrate") == clockrate) {
            return true;
        }
    }
    return false;
}

private void assert_audio_only_jingle(StanzaNode jingle, string expected_action, string expected_sid, string label) throws Error {
    assert_str_eq(jingle.get_attribute("action"), expected_action, @"$(label) action");
    assert_str_eq(jingle.get_attribute("sid"), expected_sid, @"$(label) SID");
    StanzaNode content = get_single_content(jingle, label);
    StanzaNode description = get_single_description(content, label);
    StanzaNode transport = get_single_transport(content, label);

    assert_str_eq(description.get_attribute("media"), "audio", @"$(label) media");
    if (!description_has_payload(description, "opus", "48000")) {
        throw new IOError.FAILED(@"$(label) is missing Opus/48000 payload");
    }
    if (transport.get_attribute("ufrag") == null || transport.get_attribute("pwd") == null) {
        throw new IOError.FAILED(@"$(label) is missing ICE credentials");
    }

    foreach (StanzaNode nested_content in jingle.get_subnodes("content", Jingle.NS_URI)) {
        StanzaNode? nested_description = nested_content.get_subnode("description", JingleRtp.NS_URI);
        if (nested_description != null && ((!) nested_description).get_attribute("media") == "video") {
            throw new IOError.FAILED(@"$(label) unexpectedly contains video content");
        }
    }
}

private void assert_local_audio_track_state(
        EngineJingleWireSession session,
        int expected_transceivers,
        string label) throws Error {
    Native.SessionState state = session.session.engine.get_state();
    assert_int_eq(state.audio_transceiver_count, expected_transceivers, @"$(label) audio transceiver count");
    assert_int_eq(state.video_transceiver_count, 0, @"$(label) video transceiver count");
    assert_int_eq(state.local_audio_source_attached, 1, @"$(label) local audio source attached");
    assert_int_eq(state.local_audio_track_attached, 1, @"$(label) local audio track attached");
    assert_int_eq(state.local_audio_track_enabled, 1, @"$(label) local audio track enabled");
}

private void assert_remote_audio_receiver_state(EngineJingleWireSession session, int expected_audio, string label) throws Error {
    Native.SessionState state = session.session.engine.get_state();
    assert_int_eq(state.remote_audio_receiver_count, expected_audio, @"$(label) remote audio receiver count");
    assert_int_eq(state.remote_video_receiver_count, 0, @"$(label) remote video receiver count");
    assert_int_eq(state.remote_audio_sink_count, expected_audio, @"$(label) remote audio sink count");
    if (expected_audio == 0) {
        assert_uint64_eq(state.remote_audio_sink_frame_count, 0, @"$(label) remote audio sink frame count");
        assert_uint64_eq(state.remote_audio_sink_sample_count, 0, @"$(label) remote audio sink sample count");
    }
}

private void assert_remote_audio_sample_state(EngineJingleWireSession session, string label) throws Error {
    Native.SessionState state = session.session.engine.get_state();
    if (state.remote_audio_sink_count < 1) {
        throw new IOError.FAILED(@"$(label) has no remote audio sink");
    }
    if (state.remote_audio_sink_sample_count == 0) {
        throw new IOError.FAILED(@"$(label) has no decoded remote audio samples");
    }
}

private void assert_signaling_state(
        EngineJingleWireSession session,
        SignalingState expected,
        string message) throws Error {
    if (session.state != expected) {
        throw new IOError.FAILED(message);
    }
}

private void pump_transport_infos(
        RecordingTransport from_transport,
        EngineJingleWireSession to_session,
        ref int next_index,
        string expected_sid,
        string label) throws Error {
    while (next_index < from_transport.jingle_iqs.size) {
        Iq.Stanza iq = from_transport.jingle_iqs[next_index++];
        StanzaNode jingle = get_jingle(iq);
        string? action = jingle.get_attribute("action");
        if (action == "transport-info") {
            assert_transport_info_jingle(jingle, expected_sid, label);
            to_session.handle_iq_set(iq);
        } else if (action != "session-initiate" && action != "session-accept") {
            throw new IOError.FAILED(@"unexpected $(label) action '$((action == null) ? "(null)" : (!) action)'");
        }
    }
}

private int count_transport_info_iqs(RecordingTransport transport) throws Error {
    int count = 0;
    foreach (Iq.Stanza iq in transport.jingle_iqs) {
        StanzaNode jingle = get_jingle(iq);
        if (jingle.get_attribute("action") == "transport-info") {
            count++;
        }
    }
    return count;
}

private void iterate_default_context() {
    MainContext context = MainContext.default();
    while (context.pending()) {
        context.iteration(false);
    }
}

private void wait_for_audio_samples(
        EngineJingleWireSession initiator,
        EngineJingleWireSession responder,
        RecordingTransport initiator_transport,
        RecordingTransport responder_transport,
        string sid) throws Error {
    int next_initiator_iq = 0;
    int next_responder_iq = 0;
    int64 deadline = get_monotonic_time() + AUDIO_SAMPLE_TIMEOUT_US;

    while (get_monotonic_time() < deadline) {
        iterate_default_context();
        pump_transport_infos(
            initiator_transport,
            responder,
            ref next_initiator_iq,
            sid,
            "initiator transport-info");
        pump_transport_infos(
            responder_transport,
            initiator,
            ref next_responder_iq,
            sid,
            "responder transport-info");
        iterate_default_context();

        Native.SessionState initiator_state = initiator.session.engine.get_state();
        Native.SessionState responder_state = responder.session.engine.get_state();
        if (initiator_state.remote_audio_sink_sample_count > 0 &&
                responder_state.remote_audio_sink_sample_count > 0) {
            return;
        }

        Thread.usleep(20 * 1000);
    }

    Native.SessionState initiator_state = initiator.session.engine.get_state();
    Native.SessionState responder_state = responder.session.engine.get_state();
    throw new IOError.TIMED_OUT(
        @"timed out waiting for decoded audio samples: initiator=$(initiator_state.remote_audio_sink_sample_count), responder=$(responder_state.remote_audio_sink_sample_count)");
}

private void assert_int_eq(int actual, int expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual) != $(expected)");
    }
}

private void assert_uint64_eq(uint64 actual, uint64 expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual.to_string()) != $(expected.to_string())");
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
            ((!) context).create_session(audio_only_config()),
            initiator_transport,
            "audio-only-smoke",
            initiator_jid,
            responder_jid);
        EngineSessionConfig responder_config = audio_only_config();
        // Production incoming JMI sessions create the local track first and
        // bind it only after applying the remote offer.  Keep the media smoke
        // on that exact path so an SDP-only success cannot hide a silent call.
        responder_config.defer_audio_transceiver_until_answer = true;
        responder = new EngineJingleWireSession.incoming(
            ((!) context).create_session(responder_config),
            responder_transport,
            "audio-only-smoke",
            responder_jid,
            initiator_jid);
        assert_local_audio_track_state((!) initiator, 1, "initiator initial state");
        assert_local_audio_track_state((!) responder, 0, "responder initial state");
        assert_remote_audio_receiver_state((!) initiator, 0, "initiator initial state");
        assert_remote_audio_receiver_state((!) responder, 0, "responder initial state");

        ((!) initiator).start_outgoing_offer();
        Iq.Stanza initiate_iq = wait_for_jingle_iq(initiator_transport, (!) initiator, 0, "audio-only session-initiate");
        StanzaNode initiate = get_jingle(initiate_iq);
        assert_str_eq(initiate_iq.type_, Iq.Stanza.TYPE_SET, "initiate IQ type");
        assert_jid_eq(initiate_iq.from, initiator_jid, "initiate IQ from");
        assert_jid_eq(initiate_iq.to, responder_jid, "initiate IQ to");
        assert_audio_only_jingle(initiate, "session-initiate", "audio-only-smoke", "audio-only initiate");

        ((!) responder).handle_iq_set(initiate_iq);
        assert_int_eq(responder_transport.result_iqs.size, 1, "responder ACK count");

        Iq.Stanza accept_iq = wait_for_jingle_iq(responder_transport, (!) responder, 0, "audio-only session-accept");
        StanzaNode accept = get_jingle(accept_iq);
        assert_str_eq(accept_iq.type_, Iq.Stanza.TYPE_SET, "accept IQ type");
        assert_jid_eq(accept_iq.from, responder_jid, "accept IQ from");
        assert_jid_eq(accept_iq.to, initiator_jid, "accept IQ to");
        assert_audio_only_jingle(accept, "session-accept", "audio-only-smoke", "audio-only accept");
        wait_for_active((!) responder, "responder active");
        assert_local_audio_track_state((!) responder, 1, "responder active local state");
        assert_remote_audio_receiver_state((!) responder, 1, "responder active state");

        ((!) initiator).handle_iq_set(accept_iq);
        assert_int_eq(initiator_transport.result_iqs.size, 1, "initiator ACK count");
        wait_for_active((!) initiator, "initiator active");
        assert_remote_audio_receiver_state((!) initiator, 1, "initiator active state");

        wait_for_audio_samples(
            (!) initiator,
            (!) responder,
            initiator_transport,
            responder_transport,
            "audio-only-smoke");
        assert_remote_audio_sample_state((!) initiator, "initiator active audio");
        assert_remote_audio_sample_state((!) responder, "responder active audio");

        assert_int_eq(initiator_transport.error_iqs.size, 0, "initiator error count");
        assert_int_eq(responder_transport.error_iqs.size, 0, "responder error count");
        if (count_transport_info_iqs(initiator_transport) == 0 ||
                count_transport_info_iqs(responder_transport) == 0) {
            throw new IOError.FAILED("audio-only smoke did not exchange bidirectional transport-info candidates");
        }

        bool initiator_remote_terminated = false;
        bool initiator_terminate_ack_preceded_signal = false;
        string? initiator_remote_terminate_reason = null;
        string? initiator_remote_terminate_text = null;
        int initiator_ack_count_before_terminate = initiator_transport.result_iqs.size;
        ulong terminated_handler = ((!) initiator).remote_terminated.connect((reason_name, reason_text) => {
            initiator_remote_terminated = true;
            initiator_terminate_ack_preceded_signal =
                initiator_transport.result_iqs.size == initiator_ack_count_before_terminate + 1;
            initiator_remote_terminate_reason = reason_name;
            initiator_remote_terminate_text = reason_text;
        });
        int responder_jingle_count_before_terminate = responder_transport.jingle_iqs.size;

        ((!) responder).terminate("success", "audio-only smoke done");
        assert_signaling_state((!) responder, SignalingState.ENDED, "responder did not enter ENDED after local terminate");
        assert_int_eq(
            responder_transport.jingle_iqs.size,
            responder_jingle_count_before_terminate + 1,
            "responder terminate IQ count");

        Iq.Stanza terminate_iq = responder_transport.jingle_iqs[responder_jingle_count_before_terminate];
        StanzaNode terminate = get_jingle(terminate_iq);
        assert_str_eq(terminate_iq.type_, Iq.Stanza.TYPE_SET, "terminate IQ type");
        assert_jid_eq(terminate_iq.from, responder_jid, "terminate IQ from");
        assert_jid_eq(terminate_iq.to, initiator_jid, "terminate IQ to");
        assert_session_terminate_jingle(
            terminate,
            "audio-only-smoke",
            "success",
            "audio-only smoke done",
            "audio-only terminate");

        ((!) initiator).handle_iq_set(terminate_iq);
        ((!) initiator).disconnect(terminated_handler);
        assert_signaling_state((!) initiator, SignalingState.ENDED, "initiator did not enter ENDED after remote terminate");
        if (!initiator_remote_terminated) {
            throw new IOError.FAILED("initiator did not emit remote_terminated");
        }
        if (!initiator_terminate_ack_preceded_signal) {
            throw new IOError.FAILED("session-terminate ACK must precede remote cleanup signal");
        }
        assert_str_eq(initiator_remote_terminate_reason, "success", "initiator remote terminate reason");
        assert_str_eq(initiator_remote_terminate_text, "audio-only smoke done", "initiator remote terminate text");
        assert_int_eq(
            initiator_transport.result_iqs.size,
            initiator_ack_count_before_terminate + 1,
            "initiator terminate ACK count");
        Iq.Stanza terminate_ack = initiator_transport.result_iqs[initiator_ack_count_before_terminate];
        assert_jid_eq(terminate_ack.from, initiator_jid, "terminate ACK from");
        assert_jid_eq(terminate_ack.to, responder_jid, "terminate ACK to");

        ((!) responder).close();
        ((!) initiator).close();
        assert_int_eq(
            (int) ((!) context).active_activity_count,
            0,
            "audio-only sessions must release every context activity lease");
        assert_int_eq(
            (int) ((!) context).active_call_activity_count,
            0,
            "audio-only sessions must release every call activity lease");
        assert_int_eq(
            (int) ((!) context).active_non_call_activity_count,
            0,
            "audio-only sessions must not leak non-call activity leases");
        ((!) context).close();

        // Retirement and activity acquisition use the same state mutex. A
        // live call lease must prevent retirement; after its release the idle
        // context retires exactly once and rejects every later acquire.
        var retirement_context = new EngineContext();
        EngineSessionOwner retirement_session =
            retirement_context.create_session(audio_only_config());
        assert_int_eq((int) retirement_context.active_call_activity_count, 1,
            "atomic-retirement call lease setup");
        if (retirement_context.try_retire_if_idle() ||
                retirement_context.is_closed) {
            throw new IOError.FAILED(
                "atomic retirement closed a context with a live call lease");
        }
        retirement_session.close();
        assert_int_eq((int) retirement_context.active_activity_count, 0,
            "atomic-retirement lease release");
        if (!retirement_context.try_retire_if_idle() ||
                !retirement_context.is_closed) {
            throw new IOError.FAILED("idle context did not retire atomically");
        }
        bool post_retirement_acquire_rejected = false;
        try {
            retirement_context.acquire_activity(
                "post-atomic-retirement-test");
        } catch (EngineError.CLOSED e) {
            post_retirement_acquire_rejected = true;
        }
        if (!post_retirement_acquire_rejected) {
            throw new IOError.FAILED(
                "retired context accepted a later activity lease");
        }
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-audio-only-smoke failed: %s\n", e.message);
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
