using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private const uint WAIT_TIMEOUT_MS = 5000;
private const int64 AUDIO_SAMPLE_TIMEOUT_US = 10000 * 1000;

private class WireCancellation : Object {
    public Jid peer;
    public string sid;

    public WireCancellation(Jid peer, string sid) {
        this.peer = peer;
        this.sid = sid;
    }
}

// Exercise the production IQ module and Google XMPP transport, including the
// asynchronous security-filter boundary. Only the network write is captured.
private class FilteredWireStream : XmppStream {
    public ArrayList<StanzaNode> written = new ArrayList<StanzaNode>();
    private Jid local_full_jid;

    public FilteredWireStream(Jid local_full_jid) throws InvalidJidError {
        base(new Jid("example.test"));
        this.local_full_jid = local_full_jid;
        var iq = new Iq.Module();
        add_module(iq);
        iq.attach(this);
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("No network reader in the IQ ordering test");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        written.add(node);
    }

    public void reply(int index, bool error = false) throws Error {
        if (index < 0 || index >= written.size) {
            throw new IOError.FAILED("No actual IQ write at index %d (written=%d)".printf(index, written.size));
        }
        var request = new Iq.Stanza.from_stanza(written[index], null);
        request.from = local_full_jid;
        Iq.Stanza response = error
            ? new Iq.Stanza.error(request, new ErrorStanza.not_acceptable("Setup rejected"))
            : new Iq.Stanza.result(request);
        response.from = request.to;
        response.to = local_full_jid;
        received_iq_stanza(this, response.stanza);
        iterate_default_context();
    }
}

private class HeldSetupFilter : Object, Iq.OutgoingRequestFilter {
    public string sid;
    public string? recipient;
    public bool reject = false;
    public int calls = 0;
    private SourceFunc? continuation;

    public HeldSetupFilter(string sid, string? recipient = null) {
        this.sid = sid;
        this.recipient = recipient;
    }

    public async void prepare_send(XmppStream stream, Iq.Stanza iq,
            Cancellable cancellable) throws Error {
        StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
        if (jingle == null || ((!) jingle).get_attribute("sid") != sid) return;
        if (recipient != null && (iq.to == null || iq.to.to_string() != recipient)) return;
        string? action = ((!) jingle).get_attribute("action");
        if (action != "session-initiate" && action != "session-accept") return;
        calls++;
        continuation = prepare_send.callback;
        yield;
        // Deliberately permit a late release: production IQ cancellation and
        // the transport lifetime must prevent stale work from reaching wire.
        if (reject) throw new IOError.PERMISSION_DENIED("Held setup rejected");
    }

    public void release() {
        SourceFunc? callback = (owned) continuation;
        if (callback != null) ((!) callback)();
        iterate_default_context();
    }
}

private class RecordingWireTransport : Object, EngineJingleWireTransport,
        EngineCancellableJingleWireTransport {
    public Jid local_full_jid { get; private set; }
    public ArrayList<Iq.Stanza> jingle_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> result_iqs = new ArrayList<Iq.Stanza>();
    public ArrayList<Iq.Stanza> error_iqs = new ArrayList<Iq.Stanza>();
    private ArrayList<WireCancellation> cancellations = new ArrayList<WireCancellation>();
    public bool termination_after_cancellation = false;

    public signal void jingle_iq_sent(Iq.Stanza iq);

    public RecordingWireTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_jingle_iq(Jid to, StanzaNode jingle) {
        string? sid = jingle.get_attribute("sid");
        if (jingle.get_attribute("action") == "session-terminate" && sid != null) {
            termination_after_cancellation = cancellation_count(to, (!) sid) > 0;
        }
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

    public void deliver_jingle_iq_error(
            Iq.Stanza request_iq, ErrorStanza error,
            bool locally_failed = false, IOError? local_error = null,
            Iq.LocalFailurePhase phase = Iq.LocalFailurePhase.UNKNOWN) throws Error {
        if (request_iq.to == null) {
            throw new IOError.INVALID_ARGUMENT(
                "recorded Jingle IQ has no recipient");
        }
        StanzaNode? jingle = request_iq.stanza.get_subnode(
            "jingle", Jingle.NS_URI);
        if (jingle == null) {
            throw new IOError.INVALID_ARGUMENT(
                "recorded IQ has no Jingle payload");
        }
        Iq.Stanza response = locally_failed
            ? Iq.Module.local_failure(request_iq, local_error, phase)
            : new Iq.Stanza.error(request_iq, error);
        response.from = request_iq.to;
        response.to = request_iq.from;
        jingle_iq_error((!) request_iq.to, (!) jingle, response);
    }

    public void cancel_pending_iqs(Jid peer_full_jid, string sid) {
        cancellations.add(new WireCancellation(peer_full_jid, sid));
    }

    public int cancellation_count(Jid peer_full_jid, string sid) {
        int count = 0;
        foreach (WireCancellation cancellation in cancellations) {
            if (cancellation.peer.equals(peer_full_jid) && cancellation.sid == sid) count++;
        }
        return count;
    }
}

private class JmiRecord : Object {
    public string name { get; private set; }
    public Jid to { get; private set; }
    public string sid { get; private set; }
    public ArrayList<StanzaNode> descriptions = new ArrayList<StanzaNode>();

    public JmiRecord(string name, Jid to, string sid, Gee.List<StanzaNode>? descriptions = null) {
        this.name = name;
        this.to = to;
        this.sid = sid;
        if (descriptions != null) {
            this.descriptions.add_all((!) descriptions);
        }
    }
}

private class RecordingJmiTransport : Object, EngineJmiTransport {
    public Jid local_full_jid { get; private set; }
    public ArrayList<JmiRecord> records = new ArrayList<JmiRecord>();

    public RecordingJmiTransport(Jid local_full_jid) {
        this.local_full_jid = local_full_jid;
    }

    public void send_propose(Jid to, string sid, Gee.List<StanzaNode> descriptions) {
        records.add(new JmiRecord("propose", to, sid, descriptions));
    }

    public void send_accept_to_self(string sid) {
        records.add(new JmiRecord("accept-self", local_full_jid.bare_jid, sid));
    }

    public void send_proceed(Jid to, string sid) {
        records.add(new JmiRecord("proceed", to, sid));
    }

    public void send_reject(Jid to, string sid) {
        records.add(new JmiRecord("reject", to, sid));
    }

    public void send_reject_to_self(string sid) {
        records.add(new JmiRecord("reject-self", local_full_jid.bare_jid, sid));
    }

    public void send_retract(Jid to, string sid) {
        records.add(new JmiRecord("retract", to, sid));
    }
}

private class StaticMujiCodecProvider : Object, Muji.CodecProvider {
    public async Gee.List<JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        var payloads = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        if (media == "audio") {
            var opus = new JingleRtp.PayloadType();
            opus.id = 111;
            opus.name = "opus";
            opus.clockrate = 48000;
            opus.channels = 2;
            payloads.add(opus);
        } else if (media == "video") {
            var vp8 = new JingleRtp.PayloadType();
            vp8.id = 96;
            vp8.name = "VP8";
            vp8.clockrate = 90000;
            payloads.add(vp8);
        }
        return payloads;
    }

    public async bool is_payload_supported(
            string media, JingleRtp.PayloadType payload_type) throws Error {
        if (payload_type.name == null) return false;
        return (media == "audio" && ((!) payload_type.name).down() == "opus" &&
                payload_type.clockrate == 48000) ||
            (media == "video" && ((!) payload_type.name).down() == "vp8" &&
                payload_type.clockrate == 90000);
    }
}

private enum FakeMujiCodecProbeBehavior {
    FAIL,
    NEVER_COMPLETE
}

private class FakeMujiCodecProbe : Object, EngineMujiCodecProbeSource {
    private FakeMujiCodecProbeBehavior behavior;
    public int start_count { get; private set; default = 0; }
    public int close_count { get; private set; default = 0; }

    public FakeMujiCodecProbe(FakeMujiCodecProbeBehavior behavior) {
        this.behavior = behavior;
    }

    public void start() throws Error {
        start_count++;
        if (behavior == FakeMujiCodecProbeBehavior.FAIL) {
            failed("injected codec probe failure");
        }
    }

    public void close() {
        close_count++;
    }
}

private class FakeBundleCapabilityResolver : Object,
        EnginePeerBundleCapabilityResolver {
    public enum Behavior {
        SUPPORTED,
        UNSUPPORTED,
        FAIL
    }

    private Behavior behavior;
    public int request_count { get; private set; default = 0; }

    public FakeBundleCapabilityResolver(Behavior behavior) {
        this.behavior = behavior;
    }

    public async bool supports_bundle_grouping(Jid peer_full_jid)
            throws Error {
        request_count++;
        Idle.add(supports_bundle_grouping.callback);
        yield;
        if (behavior == Behavior.FAIL) {
            throw new IOError.FAILED("injected MUJI BUNDLE discovery failure");
        }
        return behavior == Behavior.SUPPORTED;
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
        RecordingWireTransport transport,
        EngineJmiSession session,
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

private void wait_for_active(EngineJmiSession session, string label) throws Error {
    if (session.wire_session != null && ((!) session.wire_session).state == SignalingState.ACTIVE) return;

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
    if (session.wire_session == null || ((!) session.wire_session).state != SignalingState.ACTIVE) {
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

private StanzaNode require_content_with_media(StanzaNode jingle, string media, string label) throws Error {
    foreach (StanzaNode content in jingle.get_subnodes("content", Jingle.NS_URI)) {
        StanzaNode? description = content.get_subnode("description", JingleRtp.NS_URI);
        if (description != null && ((!) description).get_attribute("media") == media) {
            return content;
        }
    }
    throw new IOError.FAILED(@"$(label) is missing $(media) content");
}

private void assert_content_has_transport(StanzaNode content, string label) throws Error {
    StanzaNode transport = get_single_transport(content, label);
    if (transport.get_attribute("ufrag") == null || transport.get_attribute("pwd") == null) {
        throw new IOError.FAILED(@"$(label) is missing ICE credentials");
    }
}

private void assert_audio_video_jingle(StanzaNode jingle, string expected_action, string expected_sid, string label) throws Error {
    assert_str_eq(jingle.get_attribute("action"), expected_action, @"$(label) action");
    assert_str_eq(jingle.get_attribute("sid"), expected_sid, @"$(label) SID");
    Gee.List<StanzaNode> contents = jingle.get_subnodes("content", Jingle.NS_URI);
    if (contents.size != 2) {
        throw new IOError.FAILED(@"$(label) must contain exactly audio and video contents, got $(contents.size)");
    }

    StanzaNode audio_content = require_content_with_media(jingle, "audio", label);
    StanzaNode audio_description = get_single_description(audio_content, label);
    if (!description_has_payload(audio_description, "opus", "48000")) {
        throw new IOError.FAILED(@"$(label) is missing Opus/48000 payload");
    }
    assert_content_has_transport(audio_content, @"$(label) audio");

    StanzaNode video_content = require_content_with_media(jingle, "video", label);
    StanzaNode video_description = get_single_description(video_content, label);
    if (!description_has_payload(video_description, "VP8", "90000")) {
        throw new IOError.FAILED(@"$(label) is missing VP8/90000 payload");
    }
    assert_content_has_transport(video_content, @"$(label) video");
}

private void assert_jmi_descriptions(Gee.List<StanzaNode> descriptions, bool expect_video, string label) throws Error {
    bool has_audio = false;
    bool has_video = false;
    foreach (StanzaNode description in descriptions) {
        if (description.ns_uri != JingleRtp.NS_URI) continue;
        string? media = description.get_attribute("media");
        if (media == "audio") has_audio = true;
        if (media == "video") has_video = true;
    }
    assert_int_eq(has_audio ? 1 : 0, 1, @"$(label) audio description");
    assert_int_eq(has_video ? 1 : 0, expect_video ? 1 : 0, @"$(label) video description");
}

private void assert_int_eq(int actual, int expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual) != $(expected)");
    }
}

private void assert_uint64_eq(uint64 actual, uint64 expected, string message) throws Error {
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

private void assert_jmi_record(
        JmiRecord record,
        string name,
        Jid to,
        string sid,
        string label) throws Error {
    assert_str_eq(record.name, name, @"$(label) name");
    assert_jid_eq(record.to, to, @"$(label) to");
    assert_str_eq(record.sid, sid, @"$(label) SID");
}

private EngineJingleWireSession require_wire_session(EngineJmiSession session, string label) throws Error {
    if (session.wire_session == null) {
        throw new IOError.FAILED(@"$(label) has no Jingle wire session");
    }
    return (!) session.wire_session;
}

private void assert_jmi_state(EngineJmiSession session, JmiState expected, string message) throws Error {
    if (session.jmi_state != expected) {
        throw new IOError.FAILED(message);
    }
}

private void assert_signaling_state(
        EngineJmiSession session,
        SignalingState expected,
        string message) throws Error {
    if (require_wire_session(session, message).state != expected) {
        throw new IOError.FAILED(message);
    }
}

private void assert_remote_audio_receiver_state(EngineJmiSession session, int expected_audio, string label) throws Error {
    Native.SessionState state = require_wire_session(session, label).session.engine.get_state();
    assert_int_eq(state.remote_audio_receiver_count, expected_audio, @"$(label) remote audio receiver count");
    assert_int_eq(state.remote_video_receiver_count, 0, @"$(label) remote video receiver count");
    assert_int_eq(state.remote_audio_sink_count, expected_audio, @"$(label) remote audio sink count");
}

private void assert_pending_jmi_diagnostics(EngineJmiSession session, int expected_local_audio_enabled, string label) throws Error {
    Dino.Plugins.JmiCallDiagnostics? diagnostics = session.get_diagnostics();
    if (diagnostics == null) {
        throw new IOError.FAILED(@"$(label) diagnostics missing");
    }
    Dino.Plugins.JmiCallDiagnostics info = (!) diagnostics;
    assert_int_eq(info.wire_started ? 1 : 0, 0, @"$(label) wire not started");
    assert_int_eq(info.audio_requested ? 1 : 0, 1, @"$(label) audio requested");
    assert_int_eq(info.video_requested ? 1 : 0, 0, @"$(label) video not requested");
    assert_int_eq(info.local_audio_track_enabled ? 1 : 0, expected_local_audio_enabled, @"$(label) local audio desired state");
    assert_int_eq(info.remote_audio_receiver_count, 0, @"$(label) remote audio receiver count");
    assert_int_eq(info.remote_audio_sink_count, 0, @"$(label) remote audio sink count");
    assert_str_eq(info.peer_connection_state, "not-started", @"$(label) peer connection state");
    assert_str_eq(info.ice_connection_state, "not-started", @"$(label) ICE state");
}

private void assert_jmi_diagnostics(EngineJmiSession session, int expected_local_audio_enabled, string label) throws Error {
    Dino.Plugins.JmiCallDiagnostics? diagnostics = session.get_diagnostics();
    if (diagnostics == null) {
        throw new IOError.FAILED(@"$(label) diagnostics missing");
    }
    Dino.Plugins.JmiCallDiagnostics info = (!) diagnostics;
    assert_int_eq(info.wire_started ? 1 : 0, 1, @"$(label) wire started");
    assert_int_eq(info.audio_requested ? 1 : 0, 1, @"$(label) audio requested");
    assert_int_eq(info.video_requested ? 1 : 0, 0, @"$(label) video not requested");
    assert_int_eq(info.local_audio_track_attached ? 1 : 0, 1, @"$(label) local audio track attached");
    assert_int_eq(info.local_audio_track_enabled ? 1 : 0, expected_local_audio_enabled, @"$(label) local audio enabled");
    assert_int_eq(info.audio_transceiver_count >= 1 ? 1 : 0, 1, @"$(label) audio transceiver count");
    assert_int_eq(info.video_transceiver_count, 0, @"$(label) video transceiver count");
    assert_int_eq(info.remote_audio_receiver_count, 1, @"$(label) remote audio receiver count");
    assert_int_eq(info.remote_video_receiver_count, 0, @"$(label) remote video receiver count");
    assert_int_eq(info.remote_audio_sink_count, 1, @"$(label) remote audio sink count");
    if (info.jmi_state == null || info.peer_connection_state == null || info.ice_connection_state == null) {
        throw new IOError.FAILED(@"$(label) diagnostics states missing");
    }
}

private void assert_remote_audio_sample_state(EngineJmiSession session, string label) throws Error {
    Native.SessionState state = require_wire_session(session, label).session.engine.get_state();
    if (state.remote_audio_sink_count < 1) {
        throw new IOError.FAILED(@"$(label) has no remote audio sink");
    }
    if (state.remote_audio_sink_sample_count == 0) {
        throw new IOError.FAILED(@"$(label) has no decoded remote audio samples");
    }
}

private void pump_transport_infos(
        RecordingWireTransport from_transport,
        EngineJmiIqInterceptor to_interceptor,
        Jid to_local_full_jid,
        ref int next_index,
        string expected_sid,
        string label) throws Error {
    while (next_index < from_transport.jingle_iqs.size) {
        Iq.Stanza iq = from_transport.jingle_iqs[next_index++];
        StanzaNode jingle = get_jingle(iq);
        string? action = jingle.get_attribute("action");
        if (action == "transport-info") {
            assert_transport_info_jingle(jingle, expected_sid, label);
            if (!to_interceptor.route_iq_set_for_local_jid(to_local_full_jid, iq)) {
                throw new IOError.FAILED(@"$(label) was not routed");
            }
        } else if (action != "session-initiate" && action != "session-accept") {
            throw new IOError.FAILED(@"unexpected $(label) action '$((action == null) ? "(null)" : (!) action)'");
        }
    }
}

private int count_transport_info_iqs(RecordingWireTransport transport) throws Error {
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
        EngineJmiSession initiator,
        EngineJmiSession responder,
        EngineJmiIqInterceptor initiator_interceptor,
        EngineJmiIqInterceptor responder_interceptor,
        RecordingWireTransport initiator_transport,
        RecordingWireTransport responder_transport,
        string sid) throws Error {
    int next_initiator_iq = 0;
    int next_responder_iq = 0;
    int64 deadline = get_monotonic_time() + AUDIO_SAMPLE_TIMEOUT_US;

    while (get_monotonic_time() < deadline) {
        iterate_default_context();
        pump_transport_infos(
            initiator_transport,
            responder_interceptor,
            responder.local_full_jid,
            ref next_initiator_iq,
            sid,
            "initiator transport-info");
        pump_transport_infos(
            responder_transport,
            initiator_interceptor,
            initiator.local_full_jid,
            ref next_responder_iq,
            sid,
            "responder transport-info");
        iterate_default_context();

        Native.SessionState initiator_state = require_wire_session(initiator, "initiator audio wait").session.engine.get_state();
        Native.SessionState responder_state = require_wire_session(responder, "responder audio wait").session.engine.get_state();
        if (initiator_state.remote_audio_sink_sample_count > 0 &&
                responder_state.remote_audio_sink_sample_count > 0) {
            return;
        }

        Thread.usleep(20 * 1000);
    }

    Native.SessionState initiator_state = require_wire_session(initiator, "initiator audio timeout").session.engine.get_state();
    Native.SessionState responder_state = require_wire_session(responder, "responder audio timeout").session.engine.get_state();
    throw new IOError.TIMED_OUT(
        @"timed out waiting for decoded audio samples: initiator=$(initiator_state.remote_audio_sink_sample_count), responder=$(responder_state.remote_audio_sink_sample_count)");
}

private void run_video_requested_offer_smoke(EngineContext context) throws Error {
    EngineJmiSession? session = null;
    try {
        uint64 logical_call_id = 4294968297;
        var initiator_jid = new Jid("alice-video@example.test/DinoX");
        var responder_jid = new Jid("bob-video@example.test/Phone");
        var wire = new RecordingWireTransport(initiator_jid);
        var jmi = new RecordingJmiTransport(initiator_jid);

        session = new EngineJmiSession.outgoing(
            context,
            wire,
            jmi,
            "jmi-video-offer-smoke",
            logical_call_id,
            initiator_jid,
            responder_jid.bare_jid,
            true,
            true);
        assert_uint64_eq(((!) session).logical_call_id, logical_call_id, "video logical call id");
        ((!) session).propose();
        assert_int_eq(jmi.records.size, 1, "video JMI record count");
        assert_jmi_record(jmi.records[0], "propose", responder_jid.bare_jid, "jmi-video-offer-smoke", "video propose");
        assert_jmi_descriptions(jmi.records[0].descriptions, true, "video propose");

        Dino.Plugins.JmiCallDiagnostics? pending = ((!) session).get_diagnostics();
        if (pending == null) {
            throw new IOError.FAILED("video pending diagnostics missing");
        }
        assert_int_eq(((!) pending).video_requested ? 1 : 0, 1, "video pending diagnostics requested");
        assert_int_eq(((!) pending).wire_started ? 1 : 0, 0, "video pending diagnostics not wired yet");
        ((!) session).set_local_video_enabled(false);

        ((!) session).handle_proceed(responder_jid, initiator_jid, "jmi-video-offer-smoke");
        Iq.Stanza initiate_iq = wait_for_jingle_iq(wire, (!) session, 0, "video session-initiate after JMI proceed");
        StanzaNode initiate = get_jingle(initiate_iq);
        assert_audio_video_jingle(initiate, "session-initiate", "jmi-video-offer-smoke", "video JMI initiate");
        assert_jid_eq(initiate_iq.to, responder_jid, "video initiate IQ to");

        Native.SessionState state = require_wire_session((!) session, "video wire state").session.engine.get_state();
        assert_uint64_eq(((!) session).logical_call_id, logical_call_id, "video wire logical call id");
        assert_int_eq(((!) session).video_effect_pipeline != null ? 1 : 0, 1,
            "video call owns an effect pipeline");
        Native.VideoPipelineState effect_state = ((!) ((!) session).video_effect_pipeline).get_state();
        assert_uint64_eq(effect_state.logical_call_id, logical_call_id, "video effect pipeline logical call id");
        assert_int_eq((int) effect_state.subscriber_count, 1, "video effect pipeline subscriber count");
        assert_int_eq(effect_state.effect_type == Native.VideoEffectType.NONE ? 1 : 0, 1,
            "video effects default to off");
        assert_int_eq(require_wire_session((!) session, "video wire state").session.engine.max_bundle_transport_policy ? 1 : 0,
            0,
            "video JMI wire session must stay unbundled without peer capability");
        assert_int_eq(
            initiate.get_subnodes("group", JINGLE_GROUPING_NS).size,
            0,
            "video JMI offer must omit BUNDLE without peer capability");
        assert_int_eq(state.video_transceiver_count >= 1 ? 1 : 0, 1, "video transceiver count");
        assert_int_eq(state.local_video_source_attached, 1, "local synthetic video source attached");
        assert_int_eq(state.local_video_track_attached, 1, "local synthetic video track attached");
        assert_int_eq(state.local_video_track_enabled, 0, "pending local video mute applied to native video track");
        ((!) session).set_local_video_enabled(true);
        Native.SessionState unmuted_state = require_wire_session((!) session, "video wire unmuted state").session.engine.get_state();
        assert_int_eq(unmuted_state.local_video_track_enabled, 1, "local video unmute applied to native video track");
        Native.VideoPipelineState effect_state_after_camera =
            ((!) ((!) session).video_effect_pipeline).get_state();
        assert_int_eq(
            effect_state_after_camera.effect_type == Native.VideoEffectType.NONE &&
            effect_state_after_camera.accepted_revision == 0 &&
            effect_state_after_camera.applied_revision == 0 ? 1 : 0,
            1,
            "starting or selecting a camera must not enable a video effect");

        Dino.Plugins.JmiVideoEffectCapabilities effect_capabilities =
            ((!) session).get_video_effect_capabilities();
        assert_int_eq(
            effect_capabilities.available &&
            effect_capabilities.grayscale_supported &&
            effect_capabilities.warm_tone_supported ? 1 : 0,
            1,
            "JMI video calls must expose grayscale and warm-tone worker capabilities");
        Dino.Plugins.JmiVideoEffectStatus initial_effect_status =
            ((!) session).get_video_effect_status();
        assert_int_eq(
            initial_effect_status.selection.kind == Dino.Plugins.JmiVideoEffectKind.OFF &&
            initial_effect_status.accepted_revision == 0 &&
            initial_effect_status.applied_revision == 0 ? 1 : 0,
            1,
            "JMI video effects must remain off until an explicit selection");

        bool warm_request_done = false;
        Error? warm_request_error = null;
        uint64 warm_revision = 0;
        ((!) session).select_video_effect.begin(
            new Dino.Plugins.JmiVideoEffectSelection(
                Dino.Plugins.JmiVideoEffectKind.WARM_TONE),
            (_, result) => {
                try {
                    warm_revision = ((!) session).select_video_effect.end(result);
                } catch (Error e) {
                    warm_request_error = e;
                }
                warm_request_done = true;
            });
        int64 warm_request_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!warm_request_done && get_monotonic_time() < warm_request_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        assert_int_eq(warm_request_done && warm_request_error == null && warm_revision > 0 ? 1 : 0,
            1,
            "an explicit JMI warm-tone request must be accepted and applied");
        Dino.Plugins.JmiVideoEffectStatus warm_status =
            ((!) session).get_video_effect_status();
        int64 warm_status_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while ((warm_status.selection.kind != Dino.Plugins.JmiVideoEffectKind.WARM_TONE ||
                warm_status.state != Dino.Plugins.JmiVideoEffectApplyState.APPLIED ||
                warm_status.applied_revision != warm_revision) &&
                get_monotonic_time() < warm_status_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
            warm_status = ((!) session).get_video_effect_status();
        }
        assert_int_eq(
            warm_status.selection.kind == Dino.Plugins.JmiVideoEffectKind.WARM_TONE &&
            warm_status.state == Dino.Plugins.JmiVideoEffectApplyState.APPLIED &&
            warm_status.accepted_revision == warm_revision &&
            warm_status.applied_revision == warm_revision ? 1 : 0,
            1,
            "native WARM_TONE state must map back to the explicit JMI warm-tone selection");
        Native.VideoPipelineState warm_native_state =
            ((!) ((!) session).video_effect_pipeline).get_state();
        assert_int_eq(
            warm_native_state.effect_type == Native.VideoEffectType.WARM_TONE &&
            warm_native_state.applied_revision == warm_revision ? 1 : 0,
            1,
            "JMI warm-tone selection must reach the native per-call pipeline");

        // MUJI promotion is a backend boundary: it must synchronously make
        // the session unavailable, detach ownership and reject even callers
        // that bypass CallState/the GTK button.
        ((!) session).disable_video_effects_for_group_call();
        Dino.Plugins.JmiVideoEffectCapabilities group_capabilities =
            ((!) session).get_video_effect_capabilities();
        assert_int_eq(group_capabilities.available ? 1 : 0, 0,
            "MUJI promotion must disable backend effect capabilities");
        assert_int_eq(
            group_capabilities.unavailable_reason ==
                Dino.Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL ? 1 : 0,
            1,
            "MUJI backend capability must report the group-call reason");
        assert_int_eq(((!) session).video_effect_pipeline == null ? 1 : 0, 1,
            "MUJI promotion must detach effect pipeline ownership immediately");

        bool direct_request_done = false;
        Error? direct_request_error = null;
        ((!) session).select_video_effect.begin(
            new Dino.Plugins.JmiVideoEffectSelection(
                Dino.Plugins.JmiVideoEffectKind.GRAYSCALE),
            (_, result) => {
                try {
                    ((!) session).select_video_effect.end(result);
                } catch (Error e) {
                    direct_request_error = e;
                }
                direct_request_done = true;
            });
        int64 direct_request_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!direct_request_done && get_monotonic_time() < direct_request_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        assert_int_eq(direct_request_done ? 1 : 0, 1,
            "MUJI direct effect request must complete without entering worker IPC");
        assert_int_eq(
            direct_request_error != null && ((!) direct_request_error).matches(
                IOError.quark(), IOError.NOT_SUPPORTED) ? 1 : 0,
            1,
            "MUJI direct effect request must be rejected as not supported");

        ((!) session).close();
        session = null;
    } finally {
        if (session != null) ((!) session).close();
    }
}

private void configure_muji_group_content_names(
        EngineMujiGroupSession group, bool video) throws Error {
    var names = new HashMap<string, string>();
    var payloads = new HashMap<string,
        Gee.List<JingleRtp.PayloadType>>();
    names["audio"] = "voice";
    var audio_payloads = new ArrayList<JingleRtp.PayloadType>(
        JingleRtp.PayloadType.equals_func);
    audio_payloads.add(new JingleRtp.PayloadType() {
        id = 111,
        name = "opus",
        clockrate = 48000,
        channels = 2
    });
    payloads["audio"] = audio_payloads;
    if (video) {
        names["video"] = "camera";
        var video_payloads = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        video_payloads.add(new JingleRtp.PayloadType() {
            id = 96,
            name = "VP8",
            clockrate = 90000
        });
        payloads["video"] = video_payloads;
    }
    group.configure_conference_media(names, payloads);
}

private void run_muji_native_content_name_validation_smoke(
        EngineContext context) throws Error {
    var local = new Jid("mid-validation@example.test/DinoX");
    var room = new Jid("mid-validation@conference.example.test");
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var group = new EngineMujiGroupSession(
        context, new EngineJmiSessionRouter(), wire, jmi, local, room,
        7101, false, new StaticMujiCodecProvider());
    try {
        var names = new HashMap<string, string>();
        var payloads = new HashMap<string, Gee.List<JingleRtp.PayloadType>>();
        var audio = new ArrayList<JingleRtp.PayloadType>(
            JingleRtp.PayloadType.equals_func);
        audio.add(new JingleRtp.PayloadType() {
            id = 111, name = "opus", clockrate = 48000, channels = 2
        });
        payloads["audio"] = audio;
        foreach (string invalid_name in new string[] {
                "", "voice stream", "voice\tstream", "0123456789abcdefg" }) {
            names["audio"] = invalid_name;
            bool rejected = false;
            try {
                group.configure_conference_media(names, payloads);
            } catch (JmiError e) {
                rejected = e is JmiError.BAD_STANZA;
            }
            assert_int_eq(rejected ? 1 : 0, 1,
                "unsupported native MID must be rejected before MUJI publication");
        }
        names["audio"] = "0123456789abcdef";
        audio[0].ptime = 60;
        audio[0].maxptime = 20;
        bool timing_rejected = false;
        try {
            group.configure_conference_media(names, payloads);
        } catch (JmiError e) {
            timing_rejected = e is JmiError.BAD_STANZA;
        }
        assert_int_eq(timing_rejected ? 1 : 0, 1,
            "conflicting native timing must be rejected before MUJI publication");
        audio[0].ptime = 20;
        audio[0].maxptime = 60;
        group.configure_conference_media(names, payloads);
        assert_int_eq(wire.jingle_iqs.size, 0,
            "configuration rejection must not start a peer leg or poison retry");
    } finally {
        group.close();
    }
}

private void prepare_and_configure_muji_adoption(
        EngineMujiGroupSession group,
        Jid peer,
        EngineJmiSession first_peer) throws Error {
    group.prepare_peer_adoption(peer, first_peer);
    Gee.Map<string, string> names;
    Gee.Map<string, Gee.List<JingleRtp.PayloadType>> payloads;
    if (!group.copy_preferred_conference_media(
            out names, out payloads)) {
        throw new IOError.FAILED(
            "prepared MUJI adoption did not expose conference media");
    }
    group.configure_conference_media(names, payloads);
}

private void run_muji_bundle_capability_discovery_case(
        EngineContext context,
        FakeBundleCapabilityResolver.Behavior behavior,
        string suffix,
        bool expect_bundle) throws Error {
    var local = new Jid(
        "alice-bundle-%s@example.test/DinoX".printf(suffix));
    var peer = new Jid(
        "bob-bundle-%s@example.test/Phone".printf(suffix));
    var room = new Jid(
        "bundle-%s@conference.example.test".printf(suffix));
    var wire = new RecordingWireTransport(local);
    var router = new EngineJmiSessionRouter();
    var group = new EngineMujiGroupSession(
        context,
        router,
        wire,
        new RecordingJmiTransport(local),
        local,
        room,
        5010,
        true,
        new StaticMujiCodecProvider());
    var resolver = new FakeBundleCapabilityResolver(behavior);
    EngineJmiSession? session = null;
    EngineJingleSession? engine_session = null;
    ulong wire_started_handler = 0;
    ulong ice_complete_handler = 0;
    bool ice_complete = false;
    try {
        group.set_peer_bundle_capability_resolver(resolver);
        group.suppress_capture_start_for_test();
        configure_muji_group_content_names(group, true);
        router.add_muji_group(group);
        session = (EngineJmiSession)
            group.start_outgoing_peer_session(
                peer, "muji-bundle-%s".printf(suffix), true);
        wire_started_handler = ((!) session).wire_session_started.connect(
            (wire_session) => {
                engine_session = wire_session.session;
                ice_complete_handler = wire_session.session
                    .ice_gathering_complete.connect(() => {
                        ice_complete = true;
                    });
            });
        Iq.Stanza initiate_iq = wait_for_jingle_iq(
            wire, (!) session, 0,
            "MUJI offer after BUNDLE capability discovery");
        assert_int_eq(resolver.request_count, 1,
            "unknown MUJI peer capability must trigger one disco lookup");
        Gee.List<StanzaNode> groups = get_jingle(initiate_iq)
            .get_subnodes("group", JINGLE_GROUPING_NS);
        assert_int_eq(groups.size, expect_bundle ? 1 : 0,
            expect_bundle
                ? "discovered XEP-0338 support must enable BUNDLE before the offer"
                : "unsupported or failed discovery must keep the MUJI offer unbundled");
        if (!expect_bundle) return;
        Gee.List<StanzaNode> bundled_contents = groups[0]
            .get_subnodes("content", JINGLE_GROUPING_NS);
        assert_int_eq(bundled_contents.size, 2,
            "MUJI BUNDLE must reference both conference contents");
        assert_str_eq(bundled_contents[0].get_attribute("name"), "voice",
            "MUJI BUNDLE audio content name");
        assert_str_eq(bundled_contents[1].get_attribute("name"), "camera",
            "MUJI BUNDLE video content name");
    } finally {
        int64 deadline = get_monotonic_time() + WAIT_TIMEOUT_MS * 1000;
        while (!ice_complete && engine_session != null &&
                get_monotonic_time() < deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        if (engine_session != null && ice_complete_handler != 0) {
            ((!) engine_session).disconnect(ice_complete_handler);
        }
        if (session != null && wire_started_handler != 0) {
            ((!) session).disconnect(wire_started_handler);
        }
        group.close();
    }
}

private void run_muji_bundle_capability_discovery_smoke(
        EngineContext context) throws Error {
    run_muji_bundle_capability_discovery_case(
        context,
        FakeBundleCapabilityResolver.Behavior.SUPPORTED,
        "supported",
        true);
    run_muji_bundle_capability_discovery_case(
        context,
        FakeBundleCapabilityResolver.Behavior.UNSUPPORTED,
        "unsupported",
        false);
    run_muji_bundle_capability_discovery_case(
        context,
        FakeBundleCapabilityResolver.Behavior.FAIL,
        "failure",
        false);
}

private void run_muji_router_wire_smoke(EngineContext context) throws Error {
    var alice = new Jid("alice-muji@example.test/DinoX");
    var bob = new Jid("bob-muji@example.test/Phone");
    var mallory = new Jid("mallory@example.test/Tablet");
    var room = new Jid("call-123@conference.example.test");
    var wrong_room = new Jid("call-other@conference.example.test");
    var alice_wire = new RecordingWireTransport(alice);
    var bob_wire = new RecordingWireTransport(bob);
    var alice_jmi = new RecordingJmiTransport(alice);
    var bob_jmi = new RecordingJmiTransport(bob);
    var alice_router = new EngineJmiSessionRouter();
    var bob_router = new EngineJmiSessionRouter();
    var bob_interceptor = new EngineJmiIqInterceptor(bob_router);
    var codecs = new StaticMujiCodecProvider();
    var alice_group = new EngineMujiGroupSession(
        context, alice_router, alice_wire, alice_jmi,
        alice, room, 5001, false, codecs);
    var bob_group = new EngineMujiGroupSession(
        context, bob_router, bob_wire, bob_jmi,
        bob, room, 5002, false, codecs);
    configure_muji_group_content_names(alice_group, false);
    configure_muji_group_content_names(bob_group, false);
    alice_router.add_muji_group(alice_group);
    bob_router.add_muji_group(bob_group);

    EngineJmiSession? incoming = null;
    int incoming_count = 0;
    bob_group.incoming_peer_session.connect((_peer, _sid, session) => {
        incoming = session as EngineJmiSession?;
        incoming_count++;
    });
    // Core installs the exact expectation before publishing Ready presence,
    // but does not expose the peer session until its PeerState owner exists.
    bob_group.defer_incoming_peer_session_delivery();
    bob_group.expect_incoming_peer_session(alice, false);

    EngineJmiSession outgoing = (EngineJmiSession)
        alice_group.start_outgoing_peer_session(
            bob, "muji-wire-smoke", false);
    Iq.Stanza initiate_iq = wait_for_jingle_iq(
        alice_wire, outgoing, 0, "direct MUJI session-initiate");
    StanzaNode initiate = get_jingle(initiate_iq);
    assert_str_eq(require_content_with_media(
            initiate, "audio", "direct MUJI session-initiate")
            .get_attribute("name"), "voice",
        "direct MUJI Jingle audio content must use the conference identity");
    Gee.List<StanzaNode> muji_nodes = initiate.get_subnodes("muji", Muji.NS_URI);
    assert_int_eq(muji_nodes.size, 1, "direct MUJI room marker count");
    assert_str_eq(muji_nodes[0].get_attribute("room"), room.to_string(),
        "direct MUJI room marker");

    initiate_iq.from = mallory;
    assert_int_eq(bob_interceptor.owns_iq_set(bob, initiate_iq) ? 1 : 0, 0,
        "unexpected MUJI sender must fall through");
    initiate_iq.from = alice;

    muji_nodes[0].set_attribute("room", wrong_room.to_string());
    assert_int_eq(bob_interceptor.owns_iq_set(bob, initiate_iq) ? 1 : 0, 0,
        "unexpected MUJI room must fall through");
    muji_nodes[0].set_attribute("room", room.to_string());

    bob_group.cancel_expected_incoming_peer_session(alice);
    initiate.set_attribute("sid", "unknown-muji-sid");
    assert_int_eq(bob_interceptor.owns_iq_set(bob, initiate_iq) ? 1 : 0, 0,
        "unknown MUJI SID without a matching expectation must fall through");
    initiate.set_attribute("sid", "muji-wire-smoke");
    bob_group.expect_incoming_peer_session(alice, false);

    assert_int_eq(bob_interceptor.owns_iq_set(bob, initiate_iq) ? 1 : 0, 1,
        "expected MUJI full-JID/room/SID must be owned");
    assert_int_eq(
        bob_interceptor.route_iq_set_for_local_jid(bob, initiate_iq) ? 1 : 0,
        1,
        "expected MUJI session-initiate must route");
    assert_int_eq(incoming_count, 0,
        "a Ready-presence race must hold the claimed peer until Core is ready");
    assert_int_eq(incoming != null ? 1 : 0, 0,
        "a deferred MUJI peer must not escape before its Core owner exists");
    bob_group.expect_incoming_peer_session(alice, false);
    bob_group.release_deferred_incoming_peer_sessions();
    assert_int_eq(incoming_count, 1, "expected MUJI peer must be emitted once");
    assert_int_eq(incoming != null ? 1 : 0, 1,
        "expected MUJI peer session must be created");
    assert_int_eq(((!) incoming).is_muji ? 1 : 0, 1,
        "claimed peer session must be marked MUJI");
    Iq.Stanza accept_iq = wait_for_jingle_iq(
        bob_wire, (!) incoming, 0, "direct MUJI session-accept");
    StanzaNode accept = get_jingle(accept_iq);
    assert_str_eq(require_content_with_media(
            accept, "audio", "direct MUJI session-accept")
            .get_attribute("name"), "voice",
        "direct MUJI Jingle answer must restore the conference identity");

    var carol = new Jid("carol@example.test/Laptop");
    bob_group.expect_incoming_peer_session(carol, false);
    initiate_iq.from = carol;
    bool duplicate_rejected = false;
    try {
        bob_interceptor.route_iq_set_for_local_jid(bob, initiate_iq);
    } catch (Error e) {
        duplicate_rejected = true;
    }
    assert_int_eq(duplicate_rejected ? 1 : 0, 1,
        "duplicate MUJI SID from another peer must be rejected");
    assert_int_eq(incoming_count, 1,
        "duplicate MUJI SID must not create a second peer session");

    initiate_iq.from = alice;
    alice_group.close();
    bob_group.close();
}

private ErrorStanza create_unknown_session_error() {
    return new ErrorStanza.item_not_found(
        new StanzaNode.build(
            "unknown-session", "urn:xmpp:jingle:errors:1")
            .add_self_xmlns());
}

private Iq.Stanza create_jingle_request(
        Jid from, Jid to, string sid, string action) {
    StanzaNode jingle = new StanzaNode.build("jingle", Jingle.NS_URI)
        .add_self_xmlns()
        .put_attribute("sid", sid)
        .put_attribute("action", action);
    return new Iq.Stanza.set(jingle) { from=from, to=to };
}

private void run_setup_iq_filter_ordering_smoke() throws Error {
    var local = new Jid("ordering@example.test/DinoX");
    var peer = new Jid("ordering-peer@example.test/Phone");
    foreach (string action in new string[] { "session-initiate", "session-accept" }) {
        var stream = new FilteredWireStream(local);
        var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
        var filter = new HeldSetupFilter("held-setup");
        iq.add_outgoing_request_filter(filter);
        var wire = new XmppEngineJingleWireTransport(stream);
        wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
            local, peer, "held-setup", action)));
        wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
            local, peer, "held-setup", "transport-info")));
        iterate_default_context();
        assert_int_eq(filter.calls, 1, "setup enters the real asynchronous IQ filter");
        assert_int_eq(stream.written.size, 0,
            "ICE must not overtake a setup waiting in an IQ security filter");
        filter.release();
        assert_int_eq(stream.written.size, 1, "only prepared setup may reach wire before its ACK");
        var setup = new Iq.Stanza.from_stanza(stream.written[0], null);
        assert_str_eq(get_jingle(setup).get_attribute("action"), action,
            "the first actual wire request is the setup");
        stream.reply(0);
        assert_int_eq(stream.written.size, 2, "setup ACK releases queued ICE exactly once");
        stream.reply(0);
        assert_int_eq(stream.written.size, 2, "duplicate ACK cannot resend ICE");
        stream.reply(1);
        wire.cancel_pending_iqs(peer, "held-setup");
        iq.detach(stream);
    }
}

private void run_setup_iq_failure_smoke() throws Error {
    var local = new Jid("failure@example.test/DinoX");
    var peer = new Jid("failure-peer@example.test/Phone");
    foreach (bool reject_filter in new bool[] { true, false }) {
        var stream = new FilteredWireStream(local);
        var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
        var filter = new HeldSetupFilter("failed-setup") { reject=reject_filter };
        iq.add_outgoing_request_filter(filter);
        var wire = new XmppEngineJingleWireTransport(stream);
        int failures = 0;
        wire.jingle_iq_error.connect(() => { failures++; });
        Cancellable lifetime = wire.get_session_cancellable(peer, "failed-setup");
        wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
            local, peer, "failed-setup", "session-initiate")));
        wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
            local, peer, "failed-setup", "transport-info")));
        filter.release();
        if (!reject_filter) stream.reply(0, true);
        assert_int_eq(failures, 1, "setup failure is delivered exactly once");
        assert_int_eq(lifetime.is_cancelled() ? 1 : 0, 1,
            "filter or remote setup failure cancels the session lifetime");
        assert_int_eq(stream.written.size, reject_filter ? 0 : 1,
            "failed setup must discard ICE rather than sending it");
        iq.detach(stream);
    }
}

private void run_setup_iq_cancellation_smoke() throws Error {
    var local = new Jid("cancel-filter@example.test/DinoX");
    var peer = new Jid("cancel-filter-peer@example.test/Phone");
    var stream = new FilteredWireStream(local);
    var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
    var filter = new HeldSetupFilter("cancel-setup");
    iq.add_outgoing_request_filter(filter);
    var wire = new XmppEngineJingleWireTransport(stream);
    int failures = 0;
    wire.jingle_iq_error.connect(() => { failures++; });
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "cancel-setup", "session-initiate")));
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "cancel-setup", "transport-info")));
    wire.cancel_pending_iqs(peer, "cancel-setup");
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "cancel-setup", "session-terminate")));
    filter.release();
    assert_int_eq(failures, 0, "late cancelled preparation is not a new call failure");
    assert_int_eq(stream.written.size, 1, "cancelled setup and ICE must not reach wire");
    var termination = new Iq.Stanza.from_stanza(stream.written[0], null);
    assert_str_eq(get_jingle(termination).get_attribute("action"), "session-terminate",
        "the final termination remains sendable after cancellation");
    stream.reply(0);
    iq.detach(stream);
}

private void run_setup_iq_late_ack_smoke() throws Error {
    var local = new Jid("late-ack@example.test/DinoX");
    var peer = new Jid("late-ack-peer@example.test/Phone");
    var stream = new FilteredWireStream(local);
    var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
    var wire = new XmppEngineJingleWireTransport(stream);
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "reused-sid", "session-initiate")));
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "reused-sid", "transport-info")));
    wire.cancel_pending_iqs(peer, "reused-sid");
    var filter = new HeldSetupFilter("reused-sid");
    iq.add_outgoing_request_filter(filter);
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(
        local, peer, "reused-sid", "session-initiate")));
    StanzaNode replacement_ice = get_jingle(create_jingle_request(
        local, peer, "reused-sid", "transport-info"));
    replacement_ice.put_attribute("test-generation", "replacement");
    wire.send_jingle_iq(peer, replacement_ice);
    stream.reply(0);
    assert_int_eq(stream.written.size, 1, "old ACK cannot release a replacement's ICE");
    filter.release();
    assert_int_eq(stream.written.size, 2, "replacement must wait for its own ACK");
    stream.reply(0);
    assert_int_eq(stream.written.size, 2, "repeated old ACK still cannot release ICE");
    stream.reply(1);
    assert_int_eq(stream.written.size, 3, "only replacement ICE is released");
    var actual_ice = new Iq.Stanza.from_stanza(stream.written[2], null);
    assert_str_eq(get_jingle(actual_ice).get_attribute("test-generation"), "replacement",
        "the retired lifetime's queued ICE was discarded");
    stream.reply(2);
    wire.cancel_pending_iqs(peer, "reused-sid");
    iq.detach(stream);
}

private void run_setup_iq_scope_smoke() throws Error {
    var local = new Jid("scope@example.test/DinoX");
    var peer = new Jid("scope-peer@example.test/Phone");
    var other_resource = new Jid("scope-peer@example.test/Desktop");
    var stream = new FilteredWireStream(local);
    var other_stream = new FilteredWireStream(new Jid("other-account@example.test/DinoX"));
    var iq = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
    var filter = new HeldSetupFilter("scope-sid", peer.to_string());
    iq.add_outgoing_request_filter(filter);
    var wire = new XmppEngineJingleWireTransport(stream);
    var other_account_wire = new XmppEngineJingleWireTransport(other_stream);
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "scope-sid", "session-initiate")));
    wire.send_jingle_iq(other_resource, get_jingle(create_jingle_request(local, other_resource, "scope-sid", "session-initiate")));
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "other-sid", "session-initiate")));
    other_account_wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "scope-sid", "session-initiate")));
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "scope-sid", "transport-info")));
    wire.send_jingle_iq(other_resource, get_jingle(create_jingle_request(local, other_resource, "scope-sid", "transport-info")));
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "other-sid", "transport-info")));
    other_account_wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "scope-sid", "transport-info")));
    // Even a nonmatching asynchronous filter may resume on the main context.
    // Reply only after the two unheld setups actually reached write_async.
    iterate_default_context();
    assert_int_eq(stream.written.size, 2, "unheld setups reach wire while the selected resource waits");
    stream.reply(0);
    assert_int_eq(stream.written.size, 3, "another resource ACK releases only its own ICE");
    stream.reply(1);
    assert_int_eq(stream.written.size, 4, "another SID ACK releases only its own ICE");
    other_stream.reply(0);
    assert_int_eq(other_stream.written.size, 2, "another transport/account owns a separate barrier");
    assert_int_eq(stream.written.size, 4, "another account cannot release held local ICE");
    filter.release();
    assert_int_eq(stream.written.size, 5, "held resource still waits for its own setup ACK");
    stream.reply(4);
    assert_int_eq(stream.written.size, 6, "held resource ACK releases its final ICE");
    stream.reply(2);
    stream.reply(3);
    stream.reply(5);
    other_stream.reply(1);
    wire.cancel_pending_iqs(peer, "scope-sid");
    wire.cancel_pending_iqs(other_resource, "scope-sid");
    wire.cancel_pending_iqs(peer, "other-sid");
    other_account_wire.cancel_pending_iqs(peer, "scope-sid");
    iq.detach(stream);
    other_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(other_stream);
}

private void run_setup_iq_queue_limit_smoke() throws Error {
    var local = new Jid("limit@example.test/DinoX");
    var peer = new Jid("limit-peer@example.test/Phone");
    var stream = new FilteredWireStream(local);
    var wire = new XmppEngineJingleWireTransport(stream);
    int failures = 0;
    wire.jingle_iq_error.connect(() => { failures++; });
    Cancellable lifetime = wire.get_session_cancellable(peer, "queue-limit");
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "queue-limit", "session-initiate")));
    for (int i = 0; i < XmppEngineJingleWireTransport.MAX_QUEUED_TRANSPORT_INFOS; i++) {
        wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "queue-limit", "transport-info")));
    }
    assert_int_eq(failures, 0, "the bounded queue accepts its documented capacity");
    assert_int_eq(stream.written.size, 1, "queued ICE stays behind the unacknowledged setup");
    wire.send_jingle_iq(peer, get_jingle(create_jingle_request(local, peer, "queue-limit", "transport-info")));
    assert_int_eq(failures, 1, "queue overflow fails the affected leg once");
    assert_int_eq(lifetime.is_cancelled() ? 1 : 0, 1, "overflow cancels and discards the queue");
    stream.reply(0);
    assert_int_eq(stream.written.size, 1, "late setup ACK cannot release an overflowed queue");
    stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
}

private void run_setup_iq_ordering_tests() throws Error {
    run_setup_iq_filter_ordering_smoke();
    run_setup_iq_failure_smoke();
    run_setup_iq_cancellation_smoke();
    run_setup_iq_late_ack_smoke();
    run_setup_iq_scope_smoke();
    run_setup_iq_queue_limit_smoke();
    stdout.printf("Google wire setup ordering: 6 regression groups passed (real IQ/filter/write pipeline)\n");
}

private void assert_rejected_jmi_request(
        EngineJmiSession session,
        RecordingWireTransport transport,
        Iq.Stanza request,
        int expected_error_count,
        string expected_condition,
        string label,
        EngineJmiIqInterceptor? interceptor = null) throws Error {
    int result_count = transport.result_iqs.size;
    bool rejected = false;
    try {
        if (interceptor != null) {
            ((!) interceptor).route_iq_set_for_local_jid(
                session.local_full_jid, request);
        } else {
            session.handle_jingle_iq_set(request);
        }
    } catch (Error e) {
        rejected = true;
    }
    assert_int_eq(rejected ? 1 : 0, 1, @"$(label) must reject the request");
    assert_int_eq(transport.result_iqs.size, result_count,
        @"$(label) must not ACK the request");
    assert_int_eq(transport.error_iqs.size, expected_error_count,
        @"$(label) sends exactly one error IQ");
    Iq.Stanza response = transport.error_iqs[expected_error_count - 1];
    assert_str_eq(response.type_, Xmpp.Stanza.TYPE_ERROR, @"$(label) error IQ type");
    assert_str_eq(response.id, request.id, @"$(label) error IQ id");
    assert_jid_eq(response.to, (!) request.from, @"$(label) error IQ recipient");
    ErrorStanza? error = ErrorStanza.from_stanza(response.stanza);
    if (error == null) throw new IOError.FAILED(@"$(label) is missing an error element");
    assert_str_eq(((!) error).type_, ErrorStanza.TYPE_MODIFY, @"$(label) error type");
    assert_str_eq(((!) error).condition, expected_condition, @"$(label) error condition");
    bool has_out_of_order = ((!) error).error_node.get_subnode(
        "out-of-order", "urn:xmpp:jingle:errors:1") != null;
    assert_int_eq(has_out_of_order ? 1 : 0,
        expected_condition == ErrorStanza.CONDITION_UNEXPECTED_REQUEST ? 1 : 0,
        @"$(label) Jingle application condition");
}

private void run_wire_cancellable_scope_smoke() throws Error {
    var local = new Jid("cancel-owner@example.test/DinoX");
    var first_peer = new Jid("cancel-peer@example.test/Phone");
    var second_peer = new Jid("cancel-peer@example.test/Desktop");
    var stream = new StartTlsXmppStream(local.bare_jid,
        "example.test", 5222,
        new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
    var wire = new XmppEngineJingleWireTransport(stream);
    Cancellable first = wire.get_session_cancellable(first_peer, "shared-sid");
    Cancellable first_again = wire.get_session_cancellable(first_peer, "shared-sid");
    Cancellable another_sid = wire.get_session_cancellable(first_peer, "another-sid");
    Cancellable another_resource = wire.get_session_cancellable(second_peer, "shared-sid");
    assert_int_eq(first == first_again ? 1 : 0, 1,
        "one exact full-JID/SID must share its IQ preparation lifetime");
    wire.cancel_pending_iqs(first_peer, "shared-sid");
    assert_int_eq(first.is_cancelled() ? 1 : 0, 1,
        "closing one peer leg must cancel its waiting IQ preparation");
    assert_int_eq(another_sid.is_cancelled() ? 1 : 0, 0,
        "another SID on the same peer resource must remain sendable");
    assert_int_eq(another_resource.is_cancelled() ? 1 : 0, 0,
        "another resource with the same SID must remain sendable");
    Cancellable replacement = wire.get_session_cancellable(first_peer, "shared-sid");
    assert_int_eq(replacement != first && !replacement.is_cancelled() ? 1 : 0, 1,
        "a later session lifetime must not reuse a cancelled token");
    wire.cancel_pending_iqs(first_peer, "shared-sid");
    wire.cancel_pending_iqs(first_peer, "another-sid");
    wire.cancel_pending_iqs(second_peer, "shared-sid");
}

private void run_wire_close_cancellation_smoke(EngineContext context) throws Error {
    var local = new Jid("wire-close@example.test/DinoX");
    var first_peer = new Jid("wire-peer@example.test/Phone");
    var second_peer = new Jid("wire-peer@example.test/Desktop");
    var wire = new RecordingWireTransport(local);
    var first = new EngineJingleWireSession.outgoing(
        context.create_session(), wire, "same-sid", local, first_peer);
    var second = new EngineJingleWireSession.outgoing(
        context.create_session(), wire, "same-sid", local, second_peer);
    var third = new EngineJingleWireSession.outgoing(
        context.create_session(), wire, "other-sid", local, first_peer);
    try {
        first.close();
        first.close();
        assert_int_eq(wire.cancellation_count(first_peer, "same-sid"), 1,
            "wire close must cancel its preparation exactly once");
        assert_int_eq(wire.cancellation_count(second_peer, "same-sid"), 0,
            "wire close must preserve another resource on the shared transport");
        assert_int_eq(wire.cancellation_count(first_peer, "other-sid"), 0,
            "wire close must preserve another SID on the shared transport");
        second.terminate("cancel", "call ended during key lookup");
        assert_int_eq(wire.cancellation_count(second_peer, "same-sid"), 1,
            "wire termination must cancel its waiting preparation");
        assert_int_eq(wire.termination_after_cancellation ? 1 : 0, 1,
            "termination must be sent after pending session IQs are cancelled");
        assert_int_eq(wire.jingle_iqs.size, 1,
            "cancellation must preserve the final termination IQ");
        assert_str_eq(get_jingle(wire.jingle_iqs[0]).get_attribute("action"),
            "session-terminate", "only the final termination may be sent");
        assert_int_eq(wire.cancellation_count(first_peer, "other-sid"), 0,
            "terminating one peer must preserve the remaining MUJI leg");
    } finally {
        first.close();
        second.close();
        third.close();
    }
    assert_int_eq(wire.cancellation_count(first_peer, "other-sid"), 1,
        "the last peer owns its own final cancellation");
}

private void run_direct_local_iq_failure_smoke(EngineContext context) throws Error {
    var local = new Jid("local-failure@example.test/DinoX");
    var peer = new Jid("local-failure-peer@example.test/Phone");
    var other_resource = new Jid("local-failure-peer@example.test/Desktop");
    var wire = new RecordingWireTransport(local);
    var session = new EngineJingleWireSession.outgoing(
        context.create_session(), wire, "local-failure-sid", local, peer);
    int failed_count = 0;
    session.failed.connect((_message) => { failed_count++; });
    try {
        Iq.Stanza request = create_jingle_request(
            local, peer, "local-failure-sid", "session-initiate");
        wire.deliver_jingle_iq_error(create_jingle_request(
                local, peer, "local-failure-sid", "transport-info"),
            new ErrorStanza.bad_request("candidate rejected"));
        assert_int_eq(failed_count, 0,
            "a nonterminal remote ICE error must preserve the direct call");
        wire.deliver_jingle_iq_error(create_jingle_request(
                local, other_resource, "local-failure-sid", "session-initiate"),
            create_unknown_session_error(), true);
        wire.deliver_jingle_iq_error(create_jingle_request(
                local, peer, "another-sid", "session-initiate"),
            create_unknown_session_error(), true);
        assert_int_eq(failed_count, 0,
            "local preparation failure must match the exact peer resource and SID");
        wire.deliver_jingle_iq_error(request, create_unknown_session_error(), true);
        assert_int_eq(failed_count, 1,
            "a locally refused authenticated offer must fail a direct call once");
        assert_int_eq(wire.cancellation_count(peer, "local-failure-sid"), 1,
            "local preparation failure must cancel the failed session's pending IQs");
        wire.deliver_jingle_iq_error(request, create_unknown_session_error(), true);
        assert_int_eq(failed_count, 1,
            "later errors must not fail the already closed direct wire twice");
        bool rejected = false;
        try {
            session.start_outgoing_offer();
        } catch (WireError e) {
            rejected = e is WireError.BAD_STATE;
        }
        assert_int_eq(rejected ? 1 : 0, 1,
            "local preparation failure must close the direct native wire");
    } finally {
        session.close();
    }
}

private void run_transport_info_timeout_smoke(EngineContext context) throws Error {
    var local = new Jid("ice-timeout@example.test/DinoX");
    var peer = new Jid("ice-timeout-peer@example.test/Phone");
    foreach (Iq.LocalFailurePhase phase in new Iq.LocalFailurePhase[] {
            Iq.LocalFailurePhase.UNKNOWN, Iq.LocalFailurePhase.PREPARE,
            Iq.LocalFailurePhase.WRITE, Iq.LocalFailurePhase.AWAIT_RESPONSE }) {
        string sid = "ice-timeout-" + phase.to_string();
        var wire = new RecordingWireTransport(local);
        var engine = context.create_session();
        var session = new EngineJingleWireSession.outgoing(
            engine, wire, sid, local, peer);
        int failed_count = 0;
        session.failed.connect((_message) => { failed_count++; });
        try {
            wire.deliver_jingle_iq_error(
                create_jingle_request(local, peer, sid, "transport-info"),
                new ErrorStanza.not_acceptable(), true,
                new IOError.TIMED_OUT("synthetic ICE IQ timeout"), phase);
            if (phase == Iq.LocalFailurePhase.AWAIT_RESPONSE) {
                assert_int_eq(failed_count, 0,
                    "a missing result for a written ICE candidate must preserve the call");
                assert_int_eq(wire.cancellation_count(peer, sid), 0,
                    "an ICE IQ response timeout must not cancel the session");
                engine.native_error(Native.Status.INTERNAL_ERROR, "synthetic ICE failure");
                assert_int_eq(failed_count, 1,
                    "native connection failure must still reach the call owner after an IQ timeout");
            } else {
                assert_int_eq(failed_count, 1,
                    "unwritten or unclassified ICE timeouts must still fail closed");
                assert_int_eq(wire.cancellation_count(peer, sid), 1,
                    "an unwritten ICE timeout must retire only its own session");
            }
        } finally {
            session.close();
        }
    }

    foreach (string action in new string[] { "session-initiate", "session-accept", "transport-info" }) {
        string sid = "terminal-timeout-" + action;
        var wire = new RecordingWireTransport(local);
        var session = new EngineJingleWireSession.outgoing(
            context.create_session(), wire, sid, local, peer);
        int failed_count = 0;
        session.failed.connect((_message) => { failed_count++; });
        try {
            IOError error;
            if (action == "transport-info") {
                error = new IOError.PERMISSION_DENIED("synthetic security rejection");
            } else {
                error = new IOError.TIMED_OUT("synthetic setup response timeout");
            }
            wire.deliver_jingle_iq_error(create_jingle_request(local, peer, sid, action),
                new ErrorStanza.not_acceptable(), true, error,
                Iq.LocalFailurePhase.AWAIT_RESPONSE);
            assert_int_eq(failed_count, 1,
                "setup timeouts and non-timeout local errors must remain terminal");
        } finally {
            session.close();
        }
    }
}

private void run_direct_remote_iq_failure_smoke(EngineContext context) throws Error {
    var local = new Jid("remote-failure@example.test/DinoX");
    var peer = new Jid("remote-failure-peer@example.test/Phone");
    foreach (string action in new string[] {
            "session-initiate", "session-accept", "transport-info" }) {
        string sid = "remote-failure-" + action;
        var wire = new RecordingWireTransport(local);
        var session = new EngineJingleWireSession.outgoing(
            context.create_session(), wire, sid, local, peer);
        int failed_count = 0;
        session.failed.connect((_message) => { failed_count++; });
        try {
            Iq.Stanza request = create_jingle_request(local, peer, sid, action);
            ErrorStanza error = action == "transport-info"
                ? create_unknown_session_error()
                : new ErrorStanza.not_acceptable("fingerprint authentication refused");
            wire.deliver_jingle_iq_error(request, error);
            assert_int_eq(failed_count, 1,
                "remote setup rejection or unknown session must fail the direct call");
            assert_int_eq(wire.cancellation_count(peer, sid), 1,
                "remote terminal failure must cancel the direct session's pending IQs");
            wire.deliver_jingle_iq_error(request, error);
            assert_int_eq(failed_count, 1,
                "repeated remote errors must not fail the closed direct wire twice");
            bool rejected = false;
            try {
                session.start_outgoing_offer();
            } catch (WireError e) {
                rejected = e is WireError.BAD_STATE;
            }
            assert_int_eq(rejected ? 1 : 0, 1,
                "remote terminal failure must close the direct native wire");
        } finally {
            session.close();
        }
    }
}

private void run_incoming_security_rejection_smoke(EngineContext context) throws Error {
    var local = new Jid("incoming-security@example.test/DinoX");
    var peer = new Jid("incoming-security-peer@example.test/Phone");
    var other_resource = new Jid("incoming-security-peer@example.test/Desktop");
    var stream = new StartTlsXmppStream(local.bare_jid, "example.test", 5222,
        new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
    stream.add_flag(new Bind.Flag() { my_jid=local, finished=true });
    var other_local = new Jid("another-incoming@example.test/DinoX");
    var other_stream = new StartTlsXmppStream(other_local.bare_jid, "example.test", 5222,
        new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
    other_stream.add_flag(new Bind.Flag() { my_jid=other_local, finished=true });
    var wire = new RecordingWireTransport(local);
    var router = new EngineJmiSessionRouter();
    var interceptor = new EngineJmiIqInterceptor(router);
    var descriptions = new ArrayList<StanzaNode>();
    descriptions.add(new StanzaNode.build("description", JingleRtp.NS_URI)
        .put_attribute("media", "audio"));
    var direct = new EngineJmiSession.incoming(context, wire,
        new RecordingJmiTransport(local), "rejected-direct", 5110,
        local, peer, descriptions);
    router.add(direct);
    direct.accept_proposal();
    int direct_failures = 0;
    direct.failed.connect((_message) => { direct_failures++; });
    uint before_reject = context.active_call_activity_count;
    try {
        Iq.Stanza rejected = create_jingle_request(peer, local,
            "rejected-direct", "session-initiate");
        interceptor.on_iq_request_rejected(other_stream, rejected);
        interceptor.on_iq_request_rejected(stream, create_jingle_request(
            other_resource, local, "rejected-direct", "session-initiate"));
        interceptor.on_iq_request_rejected(stream, create_jingle_request(
            peer, local, "unknown-sid", "session-initiate"));
        assert_int_eq(direct_failures, 0,
            "rejected IQ from another account, resource or SID must preserve the direct call");
        interceptor.on_iq_request_rejected(stream, rejected);
        interceptor.on_iq_request_rejected(stream, rejected);
        assert_int_eq(direct_failures, 1,
            "locally rejected incoming direct setup must fail its owner exactly once");
        assert_int_eq(router.contains(local, "rejected-direct") ? 1 : 0, 0,
            "locally rejected incoming direct setup must remove the registered SID");
        assert_int_eq(direct.jmi_state == JmiState.ENDED && direct.wire_session == null ? 1 : 0, 1,
            "incoming security rejection must close the logical direct leg without native media");
        assert_int_eq((int) context.active_call_activity_count, (int) before_reject,
            "incoming security rejection must not allocate a native media session");
    } finally {
        direct.close();
    }

    foreach (bool deferred in new bool[] { false, true }) {
        var room = new Jid("incoming-security@conference.example.test");
        var other_room = new Jid("unrelated-security@conference.example.test");
        var group = new EngineMujiGroupSession(context, router, wire,
            new RecordingJmiTransport(local), local, room, 5111, false,
            new StaticMujiCodecProvider());
        var unrelated = new EngineMujiGroupSession(context, router, wire,
            new RecordingJmiTransport(local), local, other_room, 5112, false,
            new StaticMujiCodecProvider());
        configure_muji_group_content_names(group, false);
        configure_muji_group_content_names(unrelated, false);
        router.add_muji_group(group);
        router.add_muji_group(unrelated);
        group.expect_incoming_peer_session(peer, false);
        unrelated.expect_incoming_peer_session(peer, false);
        if (deferred) group.defer_incoming_peer_session_delivery();
        int failed_count = 0;
        int created_count = 0;
        string? failed_sid = null;
        group.incoming_peer_session_failed.connect((_peer, sid, _message) => {
            failed_count++;
            failed_sid = sid;
        });
        group.peer_session_created.connect((_session) => { created_count++; });
        try {
            Iq.Stanza rejected = create_jingle_request(peer, local,
                "rejected-muji", "session-initiate");
            get_jingle(rejected).put_node(new StanzaNode.build("muji", Muji.NS_URI)
                .put_attribute("room", room.to_string()));
            interceptor.on_iq_request_rejected(other_stream, rejected);
            rejected.from = other_resource;
            interceptor.on_iq_request_rejected(stream, rejected);
            rejected.from = peer;
            assert_int_eq(interceptor.owns_iq_set(local, rejected) ? 1 : 0, 1,
                "foreign security rejection must preserve the exact expected MUJI peer");
            before_reject = context.active_call_activity_count;
            interceptor.on_iq_request_rejected(stream, rejected);
            assert_int_eq(interceptor.owns_iq_set(local, rejected) ? 1 : 0, 0,
                "rejected MUJI setup must consume its waiting participant immediately");
            assert_int_eq(failed_count, deferred ? 0 : 1,
                "rejected MUJI setup must respect the room-publication failure barrier");
            group.release_deferred_incoming_peer_sessions();
            assert_int_eq(failed_count, 1,
                "the published room must receive exactly one waiting-peer failure");
            assert_str_eq(failed_sid, "rejected-muji", "waiting-peer failure must retain its exact rejected SID");
            interceptor.on_iq_request_rejected(stream, rejected);
            assert_int_eq(failed_count, 1,
                "a repeated rejected IQ must not fail the removed waiting peer twice");
            assert_int_eq(unrelated.expects_incoming(local, peer, other_room, "rejected-muji") ? 1 : 0, 1,
                "security rejection must preserve the same peer in another room");
            assert_int_eq(created_count, 0,
                "rejected MUJI setup must not claim a logical peer session");
            assert_int_eq((int) context.active_call_activity_count, (int) before_reject,
                "rejected MUJI setup must not allocate native media");
            assert_int_eq(router.contains(local, "rejected-muji") ? 1 : 0, 0,
                "rejected MUJI setup must not register a ghost SID");
        } finally {
            group.close();
            unrelated.close();
        }
    }
    assert_int_eq(wire.jingle_iqs.size + wire.result_iqs.size + wire.error_iqs.size, 0,
        "rejection notification must not allocate media, ACK or send a second IQ error");
}

private void run_bound_account_routing_smoke() throws Error {
    var first = new Jid("first-account@example.test/DinoX");
    var second = new Jid("second-account@example.test/DinoX");
    var peer = new Jid("peer@example.test/Phone");
    // Real stream and Bind.Flag objects, without connecting to any server.
    var first_stream = new StartTlsXmppStream(first.bare_jid,
        "example.test", 5222,
        new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
    var second_stream = new StartTlsXmppStream(second.bare_jid,
        "example.test", 5222,
        new TlsXmppStream.OnInvalidCertWrapper((_certificate, _errors) => false));
    first_stream.add_flag(new Bind.Flag() { my_jid=first, finished=true });
    second_stream.add_flag(new Bind.Flag() { my_jid=second, finished=true });
    Iq.Stanza iq = create_jingle_request(peer, first,
        "same-sid-on-two-accounts", "transport-info");
    assert_jid_eq(EngineJmiIqInterceptor.resolve_local_full_jid(first_stream, iq),
        first, "matching full recipient belongs to the bound first account");
    assert_int_eq(EngineJmiIqInterceptor.resolve_local_full_jid(second_stream, iq) == null ? 1 : 0,
        1, "explicit full recipient cannot select another account on this stream");
    iq.to = first.bare_jid;
    assert_jid_eq(EngineJmiIqInterceptor.resolve_local_full_jid(first_stream, iq),
        first, "matching bare recipient resolves to the stream's bound resource");
    assert_int_eq(EngineJmiIqInterceptor.resolve_local_full_jid(second_stream, iq) == null ? 1 : 0,
        1, "explicit bare recipient cannot select another account on this stream");
    iq.to = new Jid("first-account@example.test/OtherDevice");
    assert_int_eq(EngineJmiIqInterceptor.resolve_local_full_jid(first_stream, iq) == null ? 1 : 0,
        1, "another resource of the same account is not owned by this stream");
    // JID setters serialize an address and cannot remove an XML attribute.
    // Construct a fresh IQ whose recipient attribute is absent on the wire.
    iq = new Iq.Stanza.set(get_jingle(iq)) { from=peer };
    assert_jid_eq(EngineJmiIqInterceptor.resolve_local_full_jid(first_stream, iq),
        first, "missing recipient uses the first stream's bound account");
    assert_jid_eq(EngineJmiIqInterceptor.resolve_local_full_jid(second_stream, iq),
        second, "missing recipient uses the second stream's bound account");
}

private void run_muji_iq_error_lifecycle_smoke(
        EngineContext context) throws Error {
    var local = new Jid("alice-muji-error@example.test/DinoX");
    var peer = new Jid("bob-muji-error@example.test/Phone");
    var room = new Jid("call-error@conference.example.test");
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();
    var group = new EngineMujiGroupSession(
        context, router, wire, jmi, local, room, 5101, false, codecs);
    configure_muji_group_content_names(group, false);
    router.add_muji_group(group);

    EngineJmiSession outgoing = (EngineJmiSession)
        group.start_outgoing_peer_session(
            peer, "muji-iq-error", false);
    int failed_count = 0;
    outgoing.failed.connect((_message) => {
        failed_count++;
    });
    Iq.Stanza initiate_iq = wait_for_jingle_iq(
        wire, outgoing, 0, "MUJI error session-initiate");
    wire.deliver_jingle_iq_error(
        initiate_iq, create_unknown_session_error());
    assert_int_eq(failed_count, 1,
        "MUJI unknown-session must fail its peer leg once");
    assert_int_eq(router.contains(local, "muji-iq-error") ? 1 : 0, 0,
        "failed MUJI peer SID must leave the router");
    for (int i = 0; i < 4; i++) {
        Iq.Stanza candidate_iq = create_jingle_request(
            local, peer, "muji-iq-error", "transport-info");
        wire.deliver_jingle_iq_error(
            candidate_iq, create_unknown_session_error());
    }
    assert_int_eq(failed_count, 1,
        "candidate error cascades must not fail a MUJI leg twice");
    group.close();

    var initiator = new Jid("carol-muji-error@example.test/DinoX");
    var responder = new Jid("dave-muji-error@example.test/Phone");
    var initiator_wire = new RecordingWireTransport(initiator);
    var responder_wire = new RecordingWireTransport(responder);
    var initiator_router = new EngineJmiSessionRouter();
    var responder_router = new EngineJmiSessionRouter();
    var initiator_group = new EngineMujiGroupSession(
        context, initiator_router, initiator_wire,
        new RecordingJmiTransport(initiator),
        initiator, room, 5102, false, codecs);
    var responder_group = new EngineMujiGroupSession(
        context, responder_router, responder_wire,
        new RecordingJmiTransport(responder),
        responder, room, 5103, false, codecs);
    configure_muji_group_content_names(initiator_group, false);
    configure_muji_group_content_names(responder_group, false);
    initiator_router.add_muji_group(initiator_group);
    responder_router.add_muji_group(responder_group);
    responder_group.defer_incoming_peer_session_delivery();
    responder_group.expect_incoming_peer_session(initiator, false);

    int incoming_count = 0;
    int incoming_failed_count = 0;
    string? failed_sid = null;
    responder_group.incoming_peer_session.connect(
        (_peer, _sid, _session) => {
            incoming_count++;
        });
    responder_group.incoming_peer_session_failed.connect(
        (_peer, sid, _message) => {
            incoming_failed_count++;
            failed_sid = sid;
        });

    EngineJmiSession invalid_outgoing = (EngineJmiSession)
        initiator_group.start_outgoing_peer_session(
            responder, "muji-invalid-map", false);
    int invalid_outgoing_failed_count = 0;
    invalid_outgoing.failed.connect((_message) => {
        invalid_outgoing_failed_count++;
    });
    Iq.Stanza invalid_iq = wait_for_jingle_iq(
        initiator_wire, invalid_outgoing, 0,
        "invalid MUJI session-initiate");
    StanzaNode invalid_jingle = get_jingle(invalid_iq);
    StanzaNode audio_content = require_content_with_media(
        invalid_jingle, "audio", "invalid MUJI session-initiate");
    StanzaNode? description = audio_content.get_subnode(
        "description", JingleRtp.NS_URI);
    StanzaNode? payload = description != null
        ? ((!) description).get_subnode("payload-type", JingleRtp.NS_URI)
        : null;
    if (payload == null) {
        throw new IOError.FAILED(
            "invalid MUJI fixture has no audio payload");
    }
    ((!) payload).set_attribute("name", "PCMU");
    invalid_iq.from = initiator;
    invalid_iq.to = responder;

    var responder_interceptor = new EngineJmiIqInterceptor(
        responder_router);
    bool rejected = false;
    try {
        responder_interceptor.route_iq_set_for_local_jid(
            responder, invalid_iq);
    } catch (Error e) {
        rejected = true;
    }
    assert_int_eq(rejected ? 1 : 0, 1,
        "conflicting MUJI conference payload must be rejected");
    initiator_wire.deliver_jingle_iq_error(
        invalid_iq,
        new ErrorStanza.bad_request("conference payload map changed"));
    assert_int_eq(invalid_outgoing_failed_count, 1,
        "rejected MUJI mapping must fail the outgoing peer leg once");
    assert_int_eq(
        initiator_router.contains(initiator, "muji-invalid-map") ? 1 : 0,
        0,
        "mapping rejection must remove the outgoing MUJI SID");
    for (int i = 0; i < 4; i++) {
        initiator_wire.deliver_jingle_iq_error(
            create_jingle_request(
                initiator, responder, "muji-invalid-map", "transport-info"),
            create_unknown_session_error());
    }
    assert_int_eq(invalid_outgoing_failed_count, 1,
        "late ICE unknown-session errors must not fail the leg twice");
    assert_int_eq(incoming_count, 0,
        "rejected incoming MUJI session must not reach Core");
    assert_int_eq(incoming_failed_count, 0,
        "join publication must defer an early incoming failure");
    responder_group.release_deferred_incoming_peer_sessions();
    assert_int_eq(incoming_failed_count, 1,
        "deferred incoming MUJI failure must reach Core once");
    assert_str_eq(failed_sid, "muji-invalid-map",
        "incoming MUJI failure SID");
    responder_group.release_deferred_incoming_peer_sessions();
    assert_int_eq(incoming_failed_count, 1,
        "incoming MUJI failure must not be delivered twice");
    assert_int_eq(
        responder_router.contains(responder, "muji-invalid-map") ? 1 : 0,
        0,
        "rejected incoming MUJI SID must leave the router");
    assert_int_eq(
        responder_interceptor.owns_iq_set(responder, invalid_iq) ? 1 : 0,
        0,
        "rejected incoming MUJI expectation must be consumed");

    initiator_group.close();
    responder_group.close();
}

private void run_muji_deferred_claim_failure_smoke(
        EngineContext context) throws Error {
    var initiator = new Jid("eve-muji-deferred@example.test/DinoX");
    var responder = new Jid("frank-muji-deferred@example.test/Phone");
    var room = new Jid("call-deferred@conference.example.test");
    var initiator_wire = new RecordingWireTransport(initiator);
    var responder_wire = new RecordingWireTransport(responder);
    var initiator_router = new EngineJmiSessionRouter();
    var responder_router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();
    var initiator_group = new EngineMujiGroupSession(
        context, initiator_router, initiator_wire,
        new RecordingJmiTransport(initiator),
        initiator, room, 5201, false, codecs);
    var responder_group = new EngineMujiGroupSession(
        context, responder_router, responder_wire,
        new RecordingJmiTransport(responder),
        responder, room, 5202, false, codecs);
    configure_muji_group_content_names(initiator_group, false);
    configure_muji_group_content_names(responder_group, false);
    initiator_router.add_muji_group(initiator_group);
    responder_router.add_muji_group(responder_group);
    responder_group.defer_incoming_peer_session_delivery();
    responder_group.expect_incoming_peer_session(initiator, false);

    int incoming_count = 0;
    int failed_count = 0;
    responder_group.incoming_peer_session.connect(
        (_peer, _sid, _session) => {
            incoming_count++;
        });
    responder_group.incoming_peer_session_failed.connect(
        (_peer, _sid, _message) => {
            failed_count++;
        });

    EngineJmiSession outgoing = (EngineJmiSession)
        initiator_group.start_outgoing_peer_session(
            responder, "muji-deferred-failure", false);
    Iq.Stanza initiate_iq = wait_for_jingle_iq(
        initiator_wire, outgoing, 0,
        "deferred MUJI session-initiate");
    initiate_iq.from = initiator;
    initiate_iq.to = responder;
    var responder_interceptor = new EngineJmiIqInterceptor(
        responder_router);
    assert_int_eq(
        responder_interceptor.route_iq_set_for_local_jid(
            responder, initiate_iq) ? 1 : 0,
        1,
        "valid incoming MUJI claim must route before publication");
    assert_int_eq(incoming_count, 0,
        "successful claim must remain deferred until Core publication");
    assert_int_eq(failed_count, 0,
        "successful claim must not fail before its engine leg fails");

    EngineJmiSession? claimed = responder_router.lookup(
        responder, "muji-deferred-failure");
    if (claimed == null) {
        throw new IOError.FAILED(
            "deferred incoming MUJI claim did not retain its engine session");
    }
    ((!) claimed).failed("deferred incoming peer failed");
    assert_int_eq(
        responder_router.contains(
            responder, "muji-deferred-failure") ? 1 : 0,
        0,
        "failed deferred incoming MUJI SID must leave the router");
    assert_int_eq(failed_count, 0,
        "deferred incoming failure must wait for Core publication");

    responder_group.release_deferred_incoming_peer_sessions();
    assert_int_eq(incoming_count, 0,
        "failed deferred claim must never publish as a live session");
    assert_int_eq(failed_count, 1,
        "failed deferred claim must publish one terminal event");
    responder_group.release_deferred_incoming_peer_sessions();
    assert_int_eq(failed_count, 1,
        "failed deferred claim must not publish twice");

    initiator_group.close();
    responder_group.close();
}

private void run_muji_shared_video_group_smoke() throws Error {
    var context = new EngineContext();
    var local = new Jid("alice-video-group@example.test/DinoX");
    var room = new Jid("video-group@conference.example.test");
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();
    var group = new EngineMujiGroupSession(
        context, router, wire, jmi, local, room, 8100, true, codecs);
    configure_muji_group_content_names(group, true);
    router.add_muji_group(group);

    EngineJmiSession? first = null;
    EngineJmiSession? second = null;
    EngineJmiSession? third = null;
    EngineJmiSession? future_audio_only = null;
    try {
        group.suppress_capture_start_for_test();
        var missing_camera = new EngineVideoDeviceInfo(
            777, "DinoX missing MUJI camera", "dinox-missing-muji-camera", "");
        group.set_video_device(new EngineVideoMediaDevice(missing_camera));
        group.set_local_video_enabled(false);
        assert_int_eq((int) group.capture_start_attempt_count_for_test(), 0,
            "zero-peer video state must not open a camera");

        first = group.start_peer_without_offer_for_test(
            new Jid("bob-video-group@example.test/Phone"), "muji-video-first");
        second = group.start_peer_without_offer_for_test(
            new Jid("carol-video-group@example.test/Laptop"), "muji-video-second");
        third = group.start_peer_without_offer_for_test(
            new Jid("dave-video-group@example.test/Tablet"), "muji-video-third");

        assert_int_eq(group.video_attachment_count_for_test(), 3,
            "three MUJI peer legs must share one pipeline");
        assert_str_eq((!) group.preview_publisher_sid_for_test(), "muji-video-first",
            "first attached leg must be the sole preview publisher");
        assert_int_eq((int) group.capture_start_attempt_count_for_test(), 0,
            "disabled zero-peer state must suppress every per-leg camera start");
        var video_peers = new ArrayList<EngineJmiSession>();
        video_peers.add((!) first);
        video_peers.add((!) second);
        video_peers.add((!) third);
        foreach (EngineJmiSession peer in video_peers) {
            Native.SessionState state = ((!) peer.wire_session).session.engine.get_state();
            assert_int_eq(state.video_transceiver_count, 1,
                "video MUJI peer must have one video transceiver");
            assert_int_eq(state.local_video_track_enabled, 0,
                "zero-peer disabled state must apply to the first and later legs");
            assert_int_eq(state.local_video_capture_running, 0,
                "MUJI peer leg must not own an independent camera");
        }

        int first_preview_count = 0;
        int second_preview_count = 0;
        int third_preview_count = 0;
        int raw_first_preview_count = 0;
        ((!) first).local_video_frame.connect((_frame) => { first_preview_count++; });
        ((!) second).local_video_frame.connect((_frame) => { second_preview_count++; });
        ((!) third).local_video_frame.connect((_frame) => { third_preview_count++; });
        ((!) ((!) first).wire_session).session.engine.local_video_frame.connect(
            (_frame) => { raw_first_preview_count++; });

        group.set_local_video_enabled(true);
        assert_int_eq((int) group.capture_start_attempt_count_for_test(), 1,
            "enabling three legs must issue one call-scoped camera start");
        assert_int_eq((group.should_publish_local_preview(
                (!) first, ((!) ((!) first).wire_session).session.engine) ? 1 : 0), 1,
            "first leg must pass the group preview gate before frame publication");
        group.push_preview_synthetic_frame_for_test(176, 144);
        int64 preview_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (first_preview_count == 0 && get_monotonic_time() < preview_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        assert_int_eq(raw_first_preview_count, 1,
            "native shared group pipeline must emit one publisher preview");
        assert_int_eq(group.video_attachment_count_for_test(), 3,
            "group attachments must remain live through preview publication");
        assert_str_eq((!) group.preview_publisher_sid_for_test(), "muji-video-first",
            "preview publisher identity must remain stable through publication");
        assert_int_eq(group.local_video_enabled_for_test() ? 1 : 0, 1,
            "group video state must remain enabled through publication");
        assert_int_eq(group.video_disabled_by_codec_for_test() ? 1 : 0, 0,
            "group must not downgrade video during ordinary publication");
        assert_int_eq((group.should_publish_local_preview(
                (!) first, ((!) ((!) first).wire_session).session.engine) ? 1 : 0), 1,
            "first leg must remain the group preview publisher after publication");
        assert_int_eq(first_preview_count, 1,
            "shared group must emit one preview from its publisher");
        assert_int_eq(second_preview_count + third_preview_count, 0,
            "subscriber legs must not emit duplicate local previews");
        assert_int_eq(
            ((!) ((!) first).wire_session).session.engine.get_state()
                    .local_video_source_frame_count == 1 &&
            ((!) ((!) second).wire_session).session.engine.get_state()
                    .local_video_source_frame_count == 1 &&
            ((!) ((!) third).wire_session).session.engine.get_state()
                    .local_video_source_frame_count == 1 ? 1 : 0,
            1,
            "one MUJI preview frame must fan out to all three peer tracks");

        // Queue one old-publisher callback, then leave before the main context
        // delivers it. The sticky group filter must discard that old frame.
        group.push_preview_synthetic_frame_for_test(176, 144);
        EngineVideoEffectPipelineOwner pipeline =
            (!) group.shared_video_pipeline_for_test();
        ((!) ((!) first).wire_session).session.engine.close();
        assert_int_eq((int) pipeline.get_state().subscriber_count, 2,
            "native publisher close must detach its MUJI leg before group retirement");
        assert_int_eq(pipeline.attachment_count_for_test(), 3,
            "closed MUJI publisher must remain in Vala until group retirement");
        ((!) first).discard();
        assert_int_eq(group.video_attachment_count_for_test(), 2,
            "publisher leave must detach exactly one peer leg");
        assert_int_eq(pipeline.attachment_count_for_test(), 2,
            "publisher retirement must release the closed Vala pipeline attachment");
        assert_str_eq((!) group.preview_publisher_sid_for_test(), "muji-video-second",
            "publisher leave must promote exactly one existing subscriber");
        assert_int_eq((int) group.capture_start_attempt_count_for_test(), 2,
            "publisher handover must restart shared capture exactly once");
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        assert_int_eq(first_preview_count, 1,
            "queued frame from the departed publisher must be discarded");

        group.push_preview_synthetic_frame_for_test(176, 144);
        preview_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (second_preview_count == 0 && get_monotonic_time() < preview_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        assert_int_eq(second_preview_count, 1,
            "promoted subscriber must become the only new preview publisher");
        assert_int_eq(third_preview_count, 0,
            "handover must leave remaining subscribers preview-silent");

        group.disable_video_for_codec_downgrade();
        assert_int_eq(group.video_disabled_by_codec_for_test() ? 1 : 0, 1,
            "codec downgrade must be sticky");
        assert_int_eq(group.shared_video_pipeline_open_for_test() ? 1 : 0, 0,
            "codec downgrade must close the shared video pipeline");
        assert_int_eq(group.video_attachment_count_for_test(), 0,
            "codec downgrade must release all video attachments");
        var remaining_video_peers = new ArrayList<EngineJmiSession>();
        remaining_video_peers.add((!) second);
        remaining_video_peers.add((!) third);
        foreach (EngineJmiSession peer in remaining_video_peers) {
            Native.SessionState state = ((!) peer.wire_session).session.engine.get_state();
            assert_int_eq(state.local_video_track_enabled, 0,
                "codec downgrade must disable every existing local video track");
            assert_int_eq(state.audio_transceiver_count, 1,
                "codec downgrade must leave peer audio alive");
            assert_int_eq(peer.jmi_state == JmiState.ENDED ? 1 : 0, 0,
                "codec downgrade must not end an existing audio leg");
        }

        bool reenable_rejected = false;
        try {
            group.set_local_video_enabled(true);
        } catch (Error e) {
            reenable_rejected = e.matches(IOError.quark(), IOError.NOT_SUPPORTED);
        }
        assert_int_eq(reenable_rejected ? 1 : 0, 1,
            "sticky codec downgrade must reject later video re-enable");

        future_audio_only = group.start_peer_without_offer_for_test(
            new Jid("erin-video-group@example.test/Desktop"), "muji-after-downgrade");
        Native.SessionState future_state =
            ((!) ((!) future_audio_only).wire_session).session.engine.get_state();
        assert_int_eq(((!) future_audio_only).video_requested ? 1 : 0, 0,
            "future peer after codec downgrade must be born audio-only");
        assert_int_eq(future_state.video_transceiver_count, 0,
            "future peer after codec downgrade must have no video transceiver");
        assert_int_eq(future_state.audio_transceiver_count, 1,
            "future peer after codec downgrade must retain audio");

        group.close();
        assert_int_eq(((!) second).jmi_state == JmiState.ENDED ? 1 : 0, 1,
            "group close must tear down peers after pipeline close");
        assert_int_eq(((!) third).jmi_state == JmiState.ENDED ? 1 : 0, 1,
            "group close must tear down every video peer");
        assert_int_eq(((!) future_audio_only).jmi_state == JmiState.ENDED ? 1 : 0, 1,
            "group close must tear down the future audio-only peer");
    } finally {
        group.close();
        context.close();
    }
}

private void run_muji_first_peer_adoption_case(bool video_requested) throws Error {
    var context = new EngineContext();
    var local = new Jid(video_requested
        ? "alice-adopt-video@example.test/DinoX"
        : "alice-adopt-audio@example.test/DinoX");
    var peer = new Jid(video_requested
        ? "bob-adopt-video@example.test/Phone"
        : "bob-adopt-audio@example.test/Phone");
    var room = new Jid(video_requested
        ? "adopt-video@conference.example.test"
        : "adopt-audio@conference.example.test");
    string sid = video_requested ? "adopt-video-sid" : "adopt-audio-sid";
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();

    var first_peer = new EngineJmiSession.outgoing(
        context, wire, jmi, sid, video_requested ? 6002 : 6001,
        local, peer.bare_jid, true, video_requested);
    router.add(first_peer);
    first_peer.propose();
    first_peer.handle_proceed(peer, local, sid);
    wait_for_jingle_iq(
        wire, first_peer, 0, "first peer offer before MUJI adoption");

    if (video_requested) {
        bool fence_done = false;
        first_peer.fence_video_effects_for_group_call.begin((_, result) => {
            first_peer.fence_video_effects_for_group_call.end(result);
            fence_done = true;
        });
        int64 fence_deadline = get_monotonic_time() + 5 * 1000 * 1000;
        while (!fence_done && get_monotonic_time() < fence_deadline) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
        assert_int_eq(fence_done ? 1 : 0, 1,
            "video adoption must await the old direct pipeline fence");

        var audio_only_group = new EngineMujiGroupSession(
            context, router, wire, jmi, local, room,
            6999, false, codecs);
        bool hidden_video_rejected = false;
        try {
            audio_only_group.prepare_peer_adoption(peer, first_peer);
        } catch (Error e) {
            hidden_video_rejected = true;
        }
        assert_int_eq(hidden_video_rejected ? 1 : 0, 1,
            "video direct leg must not be adopted into audio-only MUJI presence");
        audio_only_group.close();
    }

    var group = new EngineMujiGroupSession(
        context, router, wire, jmi, local, room,
        video_requested ? 7002 : 7001, video_requested, codecs);
    prepare_and_configure_muji_adoption(
        group, peer, first_peer);
    if (video_requested) {
        group.suppress_capture_start_for_test();
        group.set_video_device(new EngineVideoMediaDevice(
            new EngineVideoDeviceInfo(
                778, "DinoX missing adoption camera",
                "dinox-missing-adoption-camera", "")));
    }
    router.add_muji_group(group);
    int owned_count = 0;
    group.peer_session_created.connect((session) => {
        if (session == first_peer) owned_count++;
    });
    group.adopt_peer_session(peer, first_peer);
    assert_int_eq(wire.cancellation_count(peer, sid), 0,
        "adopting the existing direct SID must preserve its IQ preparation lifetime");
    assert_int_eq(owned_count, 1,
        "converted first peer must be adopted exactly once");
    if (video_requested) {
        assert_int_eq(group.video_attachment_count_for_test(), 1,
            "converted video peer must attach to the shared pipeline exactly once");
        assert_str_eq((!) group.preview_publisher_sid_for_test(), sid,
            "adopted video peer must become the single preview publisher");
        assert_int_eq(group.capture_start_attempt_count_for_test() <= 1 ? 1 : 0, 1,
            "video adoption must never start a second call-scoped camera");
    }

    bool duplicate_peer_rejected = false;
    try {
        group.start_outgoing_peer_session(
            peer, "duplicate-first-peer", video_requested);
    } catch (Error e) {
        duplicate_peer_rejected = true;
    }
    assert_int_eq(duplicate_peer_rejected ? 1 : 0, 1,
        "adopted first peer must not be negotiated a second time");

    group.close();
    assert_int_eq(wire.cancellation_count(peer, sid), 1,
        "closing the group must cancel the adopted direct SID exactly once");
    assert_int_eq(first_peer.jmi_state == JmiState.ENDED ? 1 : 0, 1,
        "closing MUJI group must tear down the adopted first peer");
    assert_int_eq(router.contains(local, sid) ? 1 : 0, 0,
        "closing MUJI group must unregister the adopted first peer SID");
    context.close();
}

private void run_muji_failed_adoption_rollback_case() throws Error {
    var context = new EngineContext();
    var local = new Jid("alice-adopt-rollback@example.test/DinoX");
    var peer = new Jid("bob-adopt-rollback@example.test/Phone");
    var room = new Jid("adopt-rollback@conference.example.test");
    const string sid = "adopt-rollback-sid";
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();
    var first_peer = new EngineJmiSession.outgoing(
        context, wire, jmi, sid, 8201, local, peer.bare_jid, true, true);
    EngineMujiGroupSession? group = null;

    router.add(first_peer);
    try {
        // Keep direct video enabled while preventing a platform camera from
        // injecting unrelated frames into this deterministic rollback test.
        first_peer.suppress_local_capture_start_for_test();
        first_peer.propose();
        first_peer.handle_proceed(peer, local, sid);
        wait_for_jingle_iq(
            wire, first_peer, 0,
            "failed-adoption direct offer before MUJI adoption");
        assert_int_eq(first_peer.wire_session != null ? 1 : 0, 1,
            "failed-adoption fixture must own a live direct wire session");

        bool fence_done = false;
        first_peer.fence_video_effects_for_group_call.begin((_, result) => {
            first_peer.fence_video_effects_for_group_call.end(result);
            fence_done = true;
        });
        int64 fence_deadline = get_monotonic_time() + 5 * 1000 * 1000;
        while (!fence_done && get_monotonic_time() < fence_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_int_eq(fence_done ? 1 : 0, 1,
            "failed video adoption must first fence the direct effects pipeline");

        group = new EngineMujiGroupSession(
            context, router, wire, jmi, local, room, 8202, true, codecs);
        prepare_and_configure_muji_adoption(
            (!) group, peer, first_peer);
        ((!) group).suppress_capture_start_for_test();
        ((!) group).set_local_video_enabled(false);
        ((!) group).expect_incoming_peer_session(peer, true);
        router.add_muji_group((!) group);

        assert_int_eq(first_peer.local_video_enabled ? 1 : 0, 1,
            "direct video state must differ from disabled group state before adoption");
        assert_int_eq(((!) group).local_video_enabled_for_test() ? 1 : 0, 0,
            "rollback fixture must keep group video disabled");

        first_peer.inject_group_video_state_apply_failure_for_test();
        Error? adoption_error = null;
        try {
            ((!) group).adopt_peer_session(peer, first_peer);
        } catch (Error e) {
            adoption_error = e;
        }
        assert_int_eq(
            adoption_error != null && ((!) adoption_error).message ==
                "injected MUJI adoption video-state failure" ? 1 : 0,
            1,
            "failed adoption must preserve the original attach error");
        assert_int_eq(((!) group).video_attachment_count_for_test(), 0,
            "failed adoption must detach its partial shared-pipeline attachment");
        assert_int_eq(((!) group).expects_incoming(
                local, peer, room, "replacement-adoption-sid") ? 1 : 0,
            1,
            "failed adoption must restore the consumed incoming expectation");
        assert_int_eq(first_peer.is_muji ? 1 : 0, 0,
            "failed adoption must restore the direct-session room ownership");
        assert_int_eq(first_peer.local_video_enabled ? 1 : 0, 1,
            "failed adoption must restore the direct local-video preference");

        Native.SessionState restored_state =
            ((!) first_peer.wire_session).session.engine.get_state();
        assert_int_eq(restored_state.local_video_track_enabled, 1,
            "failed adoption must reapply enabled direct video to the wire track");
        first_peer.set_local_video_enabled(false);
        assert_int_eq(
            ((!) first_peer.wire_session).session.engine.get_state()
                .local_video_track_enabled,
            0,
            "failed adoption must not leave the direct mute control group-managed");
        first_peer.set_local_video_enabled(true);
        Native.SessionState before_frame =
            ((!) first_peer.wire_session).session.engine.get_state();
        assert_int_eq(before_frame.local_video_track_enabled, 1,
            "failed adoption must restore direct unmute control");

        int preview_count = 0;
        ulong preview_handler_id = first_peer.local_video_frame.connect((_frame) => {
            preview_count++;
        });
        first_peer.push_group_synthetic_video_frame(176, 144);
        int64 preview_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (preview_count == 0 && get_monotonic_time() < preview_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        Native.SessionState after_frame =
            ((!) first_peer.wire_session).session.engine.get_state();
        assert_int_eq(preview_count, 1,
            "restored direct session must publish exactly one local preview");
        assert_int_eq(
            after_frame.local_video_source_frame_count ==
                before_frame.local_video_source_frame_count + 1 ? 1 : 0,
            1,
            "restored direct source must accept exactly one synthetic frame");
        SignalHandler.disconnect(first_peer, preview_handler_id);

        bool effect_done = false;
        Error? effect_error = null;
        first_peer.select_video_effect.begin(
            new Dino.Plugins.JmiVideoEffectSelection(
                Dino.Plugins.JmiVideoEffectKind.GRAYSCALE),
            (_, result) => {
                try {
                    first_peer.select_video_effect.end(result);
                } catch (Error e) {
                    effect_error = e;
                }
                effect_done = true;
            });
        int64 effect_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!effect_done && get_monotonic_time() < effect_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_int_eq(
            effect_done && effect_error != null && ((!) effect_error).matches(
                IOError.quark(), IOError.NOT_SUPPORTED) ? 1 : 0,
            1,
            "failed adoption must keep the group-call effects fence sticky");
    } finally {
        if (group != null) ((!) group).close();
        router.remove(first_peer);
        first_peer.close();
        context.close();
    }
}

private void close_muji_peer_ownership_fixture(
        ref WeakRef group_ref, ref WeakRef peer_ref) throws Error {
    var context = new EngineContext();
    var local = new Jid("alice-muji-ownership@example.test/DinoX");
    var peer_jid = new Jid("bob-muji-ownership@example.test/Phone");
    var room = new Jid("ownership@conference.example.test");
    var wire = new RecordingWireTransport(local);
    var jmi = new RecordingJmiTransport(local);
    var router = new EngineJmiSessionRouter();
    var codecs = new StaticMujiCodecProvider();
    EngineMujiGroupSession? group = new EngineMujiGroupSession(
        context, router, wire, jmi, local, room, 8301, false, codecs);
    configure_muji_group_content_names((!) group, false);
    router.add_muji_group((!) group);
    EngineJmiSession? peer = ((!) group).start_peer_without_offer_for_test(
        peer_jid, "muji-ownership-sid");

    group_ref.set((!) group);
    peer_ref.set((!) peer);

    ((!) peer).discard();
    router.remove((!) peer);
    ((!) group).close();

    peer = null;
    group = null;
    context.close();
}

private void run_muji_signal_ownership_smoke() throws Error {
    WeakRef group_ref = WeakRef(null);
    WeakRef peer_ref = WeakRef(null);
    close_muji_peer_ownership_fixture(ref group_ref, ref peer_ref);
    for (int i = 0; i < 8; i++) {
        iterate_default_context();
        Thread.usleep(1000);
    }
    assert_int_eq(peer_ref.get() == null ? 1 : 0, 1,
        "forgotten MUJI peer must not be retained by its signal closures");
    assert_int_eq(group_ref.get() == null ? 1 : 0, 1,
        "closed MUJI group must not retain itself through group_closed");
}

private void run_muji_codec_probe_failure_smoke() throws Error {
    var failed_probe = new FakeMujiCodecProbe(FakeMujiCodecProbeBehavior.FAIL);
    bool failed_done = false;
    bool failed_with_error = false;
    EngineMujiCodecProbeRunner.run.begin(failed_probe, "audio", 1000, (_, result) => {
        try {
            EngineMujiCodecProbeRunner.run.end(result);
        } catch (Error e) {
            failed_with_error = true;
        }
        failed_done = true;
    });
    int64 failure_deadline = get_monotonic_time() + 1000 * 1000;
    while (!failed_done && get_monotonic_time() < failure_deadline) {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        Thread.usleep(1000);
    }
    assert_int_eq(failed_done ? 1 : 0, 1,
        "injected MUJI codec probe failure must complete");
    assert_int_eq(failed_with_error ? 1 : 0, 1,
        "injected MUJI codec probe failure must propagate");
    assert_int_eq(failed_probe.start_count, 1,
        "failed MUJI codec probe must start exactly once");
    assert_int_eq(failed_probe.close_count, 1,
        "failed MUJI codec probe must close exactly once");

    var timeout_probe = new FakeMujiCodecProbe(
        FakeMujiCodecProbeBehavior.NEVER_COMPLETE);
    bool timeout_done = false;
    bool timeout_error = false;
    EngineMujiCodecProbeRunner.run.begin(timeout_probe, "audio", 5, (_, result) => {
        try {
            EngineMujiCodecProbeRunner.run.end(result);
        } catch (Error e) {
            timeout_error = true;
        }
        timeout_done = true;
    });
    int64 timeout_deadline = get_monotonic_time() + 1000 * 1000;
    while (!timeout_done && get_monotonic_time() < timeout_deadline) {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        Thread.usleep(1000);
    }
    assert_int_eq(timeout_done ? 1 : 0, 1,
        "non-responsive MUJI codec probe must complete by timeout");
    assert_int_eq(timeout_error ? 1 : 0, 1,
        "non-responsive MUJI codec probe must report TIMED_OUT");
    assert_int_eq(timeout_probe.start_count, 1,
        "timed-out MUJI codec probe must start exactly once");
    assert_int_eq(timeout_probe.close_count, 1,
        "timed-out MUJI codec probe must close exactly once without removing an expired source");
}

private void run_muji_codec_probe_smoke(EngineContext context, string media) throws Error {
    var config = new EngineSessionConfig() {
        audio_enabled = media == "audio",
        video_enabled = media == "video",
        max_bundle = true
    };
    var probe = new EngineSessionMujiCodecProbe(context.create_session(config));
    JingleRtp.SdpMediaSection? native_section = null;
    var native_payload_snapshot = new ArrayList<JingleRtp.PayloadType>();
    ulong description_handler = probe.description_ready.connect((description) => {
        foreach (JingleRtp.SdpMediaSection section in description.session.media_sections) {
            if (section.media != media) continue;
            native_section = section;
            foreach (JingleRtp.PayloadType payload in section.payload_types) {
                native_payload_snapshot.add(payload.clone());
            }
        }
    });
    bool done = false;
    Error? probe_error = null;
    Gee.List<JingleRtp.PayloadType>? payloads = null;
    EngineMujiCodecProbeRunner.run.begin(probe, media, 5000, (_, result) => {
        try {
            payloads = EngineMujiCodecProbeRunner.run.end(result);
        } catch (Error e) {
            probe_error = e;
        }
        done = true;
    });
    int64 deadline = get_monotonic_time() + 6 * 1000 * 1000;
    while (!done && get_monotonic_time() < deadline) {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        Thread.usleep(1000);
    }
    probe.disconnect(description_handler);
    assert_int_eq(done ? 1 : 0, 1,
        "native MUJI codec probe must complete");
    if (probe_error != null) throw (!) probe_error;
    assert_int_eq(payloads != null && !((!) payloads).is_empty ? 1 : 0, 1,
        "native MUJI codec probe must return payloads");
    assert_int_eq(native_section != null ? 1 : 0, 1,
        "MUJI probe must preserve its source media section");
    assert_int_eq(((!) payloads).size, native_payload_snapshot.size,
        "MUJI export must preserve every codec and repair payload");
    bool has_required_codec = false;
    int native_rrtr_count = 0;
    for (int i = 0; i < ((!) payloads).size; i++) {
        JingleRtp.PayloadType payload = ((!) payloads)[i];
        JingleRtp.PayloadType original = native_payload_snapshot[i];
        assert_int_eq(JingleRtp.PayloadType.equals_func(
                ((!) native_section).payload_types[i], original) ? 1 : 0, 1,
            "MUJI RRTR policy must not change the native/direct-call offer");
        int retained_feedback_count = 0;
        foreach (JingleRtp.RtcpFeedback feedback in original.rtcp_fbs) {
            if (feedback.type_ == "rrtr") {
                native_rrtr_count++;
                continue;
            }
            retained_feedback_count++;
            assert_int_eq(payload.rtcp_fbs.any_match((candidate) =>
                    candidate.type_ == feedback.type_ &&
                    candidate.subtype == feedback.subtype) ? 1 : 0, 1,
                "MUJI must preserve other native RTCP feedback");
        }
        assert_int_eq(payload.rtcp_fbs.size, retained_feedback_count,
            "new MUJI capabilities must omit only RRTR");
        // Compare all codec parameters independently of optional feedback.
        JingleRtp.PayloadType codec_copy = payload.clone();
        codec_copy.rtcp_fbs.clear();
        original.rtcp_fbs.clear();
        assert_int_eq(JingleRtp.PayloadType.equals_func(codec_copy, original) ? 1 : 0, 1,
            "MUJI RRTR policy must preserve payload IDs, format parameters and timing");
        if (payload.name != null && ((!) payload.name).down() ==
                (media == "audio" ? "opus" : "vp8")) has_required_codec = true;
    }
    assert_int_eq(has_required_codec ? 1 : 0, 1,
        "native MUJI codec probe must expose Opus audio or VP8 video");
    stdout.printf("MUJI %s codec probe: native RRTR=%d, exported RRTR=0\n",
        media, native_rrtr_count);
}

private int run_smoke() {
    EngineContext? context = null;
    EngineJmiSession? initiator = null;
    EngineJmiSession? responder = null;

    try {
        context = new EngineContext();
        uint64 initiator_logical_call_id = 4294968298;
        uint64 responder_logical_call_id = 4294969298;
        var initiator_jid = new Jid("alice@example.test/DinoX");
        var responder_jid = new Jid("bob@example.test/Phone");
        var responder_bare = responder_jid.bare_jid;

        var initiator_wire = new RecordingWireTransport(initiator_jid);
        var responder_wire = new RecordingWireTransport(responder_jid);
        var initiator_jmi = new RecordingJmiTransport(initiator_jid);
        var responder_jmi = new RecordingJmiTransport(responder_jid);
        var initiator_router = new EngineJmiSessionRouter();
        var responder_router = new EngineJmiSessionRouter();
        var initiator_interceptor = new EngineJmiIqInterceptor(initiator_router);
        var responder_interceptor = new EngineJmiIqInterceptor(responder_router);

        run_bound_account_routing_smoke();
        run_setup_iq_ordering_tests();
        run_wire_cancellable_scope_smoke();
        run_wire_close_cancellation_smoke((!) context);
        run_direct_local_iq_failure_smoke((!) context);
        run_transport_info_timeout_smoke((!) context);
        run_direct_remote_iq_failure_smoke((!) context);
        run_incoming_security_rejection_smoke((!) context);

        run_muji_native_content_name_validation_smoke((!) context);
        run_muji_router_wire_smoke((!) context);
        // Production runs each libwebrtc session in the worker process. Keep
        // the rapid capability/offer/close matrix on that lifecycle path; the
        // in-process suite already covers the wire mapping independently.
        if (Environment.get_variable("DINOX_WEBRTC_WORKER_PATH") != null) {
            run_muji_bundle_capability_discovery_smoke((!) context);
        }
        run_muji_iq_error_lifecycle_smoke((!) context);
        run_muji_deferred_claim_failure_smoke((!) context);
        run_muji_shared_video_group_smoke();
        run_muji_first_peer_adoption_case(false);
        run_muji_first_peer_adoption_case(true);
        run_muji_failed_adoption_rollback_case();
        run_muji_signal_ownership_smoke();
        run_muji_codec_probe_failure_smoke();
        run_muji_codec_probe_smoke((!) context, "audio");
        run_muji_codec_probe_smoke((!) context, "video");

        run_video_requested_offer_smoke((!) context);

        initiator = new EngineJmiSession.outgoing(
            ((!) context),
            initiator_wire,
            initiator_jmi,
            "jmi-wire-smoke",
            initiator_logical_call_id,
            initiator_jid,
            responder_bare,
            true,
            false);
        int direct_iq_failed_count = 0;
        ulong direct_iq_failed_handler = ((!) initiator).failed.connect(
            (_message) => {
                direct_iq_failed_count++;
            });
        assert_uint64_eq(((!) initiator).logical_call_id, initiator_logical_call_id, "initiator logical call id");
        initiator_router.add((!) initiator);
        assert_int_eq(((!) initiator).audio_requested ? 1 : 0, 1, "initiator audio requested");
        assert_int_eq(((!) initiator).video_requested ? 1 : 0, 0, "initiator video not requested");
        assert_int_eq(((!) initiator).video_effect_pipeline == null ? 1 : 0, 1,
            "audio-only call has no effect pipeline");
        assert_int_eq(initiator_router.contains(initiator_jid, "jmi-wire-smoke") ? 1 : 0, 1, "initiator router contains session");
        assert_int_eq(initiator_router.contains(initiator_jid, "unknown-sid") ? 1 : 0, 0, "initiator router ignores unknown SID");

        ((!) initiator).propose();
        assert_int_eq(initiator_jmi.records.size, 1, "initiator JMI record count");
        assert_jmi_record(initiator_jmi.records[0], "propose", responder_bare, "jmi-wire-smoke", "propose");
        assert_int_eq(initiator_jmi.records[0].descriptions.size, 1, "propose description count");
        assert_jmi_descriptions(initiator_jmi.records[0].descriptions, false, "propose");
        assert_int_eq(initiator_wire.jingle_iqs.size, 0, "no Jingle IQ before proceed");

        responder = new EngineJmiSession.incoming(
            ((!) context),
            responder_wire,
            responder_jmi,
            "jmi-wire-smoke",
            responder_logical_call_id,
            responder_jid,
            initiator_jid,
            initiator_jmi.records[0].descriptions);
        assert_uint64_eq(((!) responder).logical_call_id, responder_logical_call_id, "responder logical call id");
        responder_router.add((!) responder);
        assert_int_eq(responder_router.contains(responder_jid, "jmi-wire-smoke") ? 1 : 0, 1, "responder router contains session");

        assert_int_eq(((!) responder).audio_requested ? 1 : 0, 1, "responder audio requested");
        assert_int_eq(((!) responder).video_requested ? 1 : 0, 0, "responder video not requested");

        bool initiator_audio_ready = false;
        bool responder_audio_ready = false;
        bool unexpected_video_ready = false;
        ulong initiator_media_handler = ((!) initiator).media_ready.connect((media) => {
            if (media == "audio") initiator_audio_ready = true;
            if (media == "video") unexpected_video_ready = true;
        });
        ulong responder_media_handler = ((!) responder).media_ready.connect((media) => {
            if (media == "audio") responder_audio_ready = true;
            if (media == "video") unexpected_video_ready = true;
        });
        ((!) initiator).set_local_audio_enabled(false);
        assert_pending_jmi_diagnostics((!) initiator, 0, "initiator pending muted diagnostics");

        ((!) responder).accept_proposal();
        assert_int_eq(responder_jmi.records.size, 2, "responder JMI record count");
        assert_jmi_record(responder_jmi.records[0], "accept-self", responder_jid.bare_jid, "jmi-wire-smoke", "accept self");
        assert_jmi_record(responder_jmi.records[1], "proceed", initiator_jid, "jmi-wire-smoke", "proceed");

        int responder_wire_started_count = 0;
        ulong responder_wire_started_handler = ((!) responder).wire_session_started.connect((_wire) => {
            responder_wire_started_count++;
        });
        // A JMI proceed is not a Jingle session-initiate. Repeated early ICE
        // must produce one protocol error each without allocating native media.
        for (int index = 0; index < 8; index++) {
            assert_rejected_jmi_request((!) responder, responder_wire,
                create_jingle_request(initiator_jid, responder_jid,
                    "jmi-wire-smoke", "transport-info"),
                index + 1, ErrorStanza.CONDITION_UNEXPECTED_REQUEST,
                @"incoming early transport-info $(index)", responder_interceptor);
            assert_int_eq(((!) responder).wire_session == null ? 1 : 0, 1,
                "early ICE must leave the incoming wire unallocated");
            assert_int_eq(responder_wire_started_count, 0,
                "early ICE must not start any incoming media owner");
            assert_jmi_state((!) responder, JmiState.PROCEED_SENT,
                "early ICE preserves the accepted JMI proposal");
        }
        assert_rejected_jmi_request((!) responder, responder_wire,
            create_jingle_request(new Jid("mallory@example.test/Evil"),
                responder_jid, "jmi-wire-smoke", "transport-info"),
            9, ErrorStanza.CONDITION_BAD_REQUEST,
            "incoming wrong-peer guard", responder_interceptor);
        assert_rejected_jmi_request((!) responder, responder_wire,
            create_jingle_request(initiator_jid, responder_jid,
                "wrong-sid", "transport-info"),
            10, ErrorStanza.CONDITION_BAD_REQUEST, "incoming wrong-SID guard");
        Iq.Stanza wrong_recipient = create_jingle_request(initiator_jid,
            initiator_jid, "jmi-wire-smoke", "transport-info");
        assert_int_eq(responder_interceptor.route_iq_set_for_local_jid(
                responder_jid, wrong_recipient) ? 1 : 0, 0,
            "interceptor must not own another account's recipient");
        assert_int_eq(responder_wire.error_iqs.size, 10,
            "an unowned recipient must not receive an error from this account");
        assert_rejected_jmi_request((!) responder, responder_wire,
            wrong_recipient, 11, ErrorStanza.CONDITION_BAD_REQUEST,
            "direct incoming wrong-recipient guard");
        assert_int_eq(((!) responder).wire_session == null ? 1 : 0, 1,
            "invalid peer, SID and recipient leave the incoming wire unallocated");
        assert_int_eq(responder_wire_started_count, 0,
            "invalid peer, SID and recipient must not start a media owner");

        EngineJingleWireSession? routed_initiator_wire_session = null;
        if (!initiator_router.route_proceed(responder_jid, initiator_jid, "jmi-wire-smoke", out routed_initiator_wire_session)) {
            throw new IOError.FAILED("JMI proceed was not routed");
        }
        EngineJingleWireSession initiator_wire_session = (!) routed_initiator_wire_session;
        assert_uint64_eq(((!) initiator).logical_call_id, initiator_logical_call_id, "initiator wire logical call id");
        assert_int_eq(((!) initiator).jmi_state == JmiState.PROCEED_RECEIVED ? 1 : 0, 1, "initiator JMI state");
        assert_int_eq(initiator_wire_session.state == SignalingState.NEW ? 1 : 0, 1, "initiator wire starts before async offer");

        assert_rejected_jmi_request((!) initiator, initiator_wire,
            create_jingle_request(responder_jid, initiator_jid,
                "jmi-wire-smoke", "transport-info"),
            1, ErrorStanza.CONDITION_UNEXPECTED_REQUEST,
            "outgoing early ICE during offer delay", initiator_interceptor);
        assert_int_eq(((!) initiator).wire_session == initiator_wire_session ? 1 : 0,
            1, "outgoing early ICE preserves the existing media owner");
        assert_int_eq(initiator_wire_session.state == SignalingState.NEW ? 1 : 0,
            1, "outgoing early ICE preserves the offer delay state");

        Iq.Stanza initiate_iq = wait_for_jingle_iq(initiator_wire, (!) initiator, 0, "session-initiate after JMI proceed");
        StanzaNode initiate = get_jingle(initiate_iq);
        assert_audio_only_jingle(initiate, "session-initiate", "jmi-wire-smoke", "JMI initiate");
        assert_int_eq(
            initiate.get_subnodes("group", JINGLE_GROUPING_NS).size,
            0,
            "direct audio JMI must preserve the established implicit BUNDLE wire path");
        assert_jid_eq(initiate_iq.to, responder_jid, "initiate IQ to");
        initiator_wire.deliver_jingle_iq_error(
            create_jingle_request(initiator_jid, responder_jid,
                "jmi-wire-smoke", "transport-info"),
            new ErrorStanza.bad_request("candidate rejected"));
        assert_int_eq(direct_iq_failed_count, 0,
            "a nonterminal remote ICE error must preserve the direct JMI lifecycle");
        assert_int_eq(
            initiator_router.contains(initiator_jid, "jmi-wire-smoke") ? 1 : 0,
            1,
            "direct JMI SID must remain owned after a nonterminal ICE error");

        assert_int_eq(
            responder_interceptor.owns_iq_set(initiator_jid, initiate_iq) ? 1 : 0,
            0,
            "interceptor ownership ignores wrong local JID");
        assert_int_eq(
            responder_interceptor.owns_iq_set(responder_jid, initiate_iq) ? 1 : 0,
            1,
            "interceptor ownership accepts registered local JID and SID");
        assert_int_eq(
            responder_interceptor.route_iq_set_for_local_jid(initiator_jid, initiate_iq) ? 1 : 0,
            0,
            "interceptor must ignore known SID for the wrong local JID");
        assert_int_eq(responder_wire.result_iqs.size, 0, "wrong-local route must not ACK");

        if (!responder_interceptor.route_iq_set_for_local_jid(responder_jid, initiate_iq)) {
            throw new IOError.FAILED("JMI session-initiate was not routed");
        }
        EngineJingleWireSession responder_wire_session = require_wire_session((!) responder, "responder wire after routed initiate");
        assert_int_eq(responder_wire_started_count, 1,
            "the later valid session-initiate starts exactly one media owner");
        ((!) responder).disconnect(responder_wire_started_handler);
        assert_uint64_eq(((!) responder).logical_call_id, responder_logical_call_id, "responder wire logical call id");
        assert_int_eq(responder_wire.result_iqs.size, 1, "responder ACK count");
        assert_str_eq(responder_wire.result_iqs[0].id, initiate_iq.id, "responder ACK id");
        assert_int_eq(responder_wire_session.state == SignalingState.REMOTE_OFFER_RECEIVED ||
            responder_wire_session.state == SignalingState.REMOTE_OFFER_SET ||
            responder_wire_session.state == SignalingState.ACTIVE ? 1 : 0,
            1,
            "responder wire received initiate");

        Iq.Stanza accept_iq = wait_for_jingle_iq(responder_wire, (!) responder, 0, "session-accept after JMI proceed");
        StanzaNode accept = get_jingle(accept_iq);
        assert_audio_only_jingle(accept, "session-accept", "jmi-wire-smoke", "JMI accept");
        assert_jid_eq(accept_iq.to, initiator_jid, "accept IQ to");

        if (!initiator_interceptor.route_iq_set_for_local_jid(initiator_jid, accept_iq)) {
            throw new IOError.FAILED("JMI session-accept was not routed");
        }
        assert_int_eq(initiator_wire.result_iqs.size, 1, "initiator ACK count");
        assert_str_eq(initiator_wire.result_iqs[0].id, accept_iq.id, "initiator ACK id");

        wait_for_active((!) initiator, "initiator active");
        wait_for_active((!) responder, "responder active");
        ((!) initiator).disconnect(initiator_media_handler);
        ((!) responder).disconnect(responder_media_handler);
        assert_int_eq(initiator_audio_ready ? 1 : 0, 1, "initiator audio media-ready");
        assert_int_eq(responder_audio_ready ? 1 : 0, 1, "responder audio media-ready");
        assert_int_eq(unexpected_video_ready ? 1 : 0, 0, "audio-only call must not emit video media-ready");
        assert_int_eq(require_wire_session((!) initiator, "initiator audio wire state").session.engine.max_bundle_transport_policy ? 1 : 0,
            1,
            "direct audio JMI must preserve the established max-bundle transport policy");
        Native.SessionState initiator_muted_state =
            require_wire_session((!) initiator, "initiator muted state").session.engine.get_state();
        assert_int_eq(initiator_muted_state.local_audio_track_enabled, 0, "initiator pending mute applied to native audio track");
        assert_jmi_diagnostics((!) initiator, 0, "initiator muted diagnostics");
        ((!) initiator).set_local_audio_enabled(true);
        Native.SessionState initiator_unmuted_state =
            require_wire_session((!) initiator, "initiator unmuted state").session.engine.get_state();
        assert_int_eq(initiator_unmuted_state.local_audio_track_enabled, 1, "initiator unmute applied to native audio track");
        assert_jmi_diagnostics((!) initiator, 1, "initiator unmuted diagnostics");
        assert_jmi_diagnostics((!) responder, 1, "responder diagnostics");
        assert_remote_audio_receiver_state((!) initiator, 1, "initiator active state");
        assert_remote_audio_receiver_state((!) responder, 1, "responder active state");

        wait_for_audio_samples(
            (!) initiator,
            (!) responder,
            initiator_interceptor,
            responder_interceptor,
            initiator_wire,
            responder_wire,
            "jmi-wire-smoke");
        assert_remote_audio_sample_state((!) initiator, "initiator JMI active audio");
        assert_remote_audio_sample_state((!) responder, "responder JMI active audio");
        ((!) initiator).send_dtmf('5');
        ((!) responder).send_dtmf('#');
        if (count_transport_info_iqs(initiator_wire) == 0 ||
                count_transport_info_iqs(responder_wire) == 0) {
            throw new IOError.FAILED("JMI wire smoke did not exchange bidirectional transport-info candidates");
        }

        bool initiator_remote_terminated = false;
        string? initiator_remote_terminate_reason = null;
        string? initiator_remote_terminate_text = null;
        ulong terminated_handler = ((!) initiator).remote_terminated.connect((reason_name, reason_text) => {
            initiator_remote_terminated = true;
            initiator_remote_terminate_reason = reason_name;
            initiator_remote_terminate_text = reason_text;
        });
        int responder_jingle_count_before_terminate = responder_wire.jingle_iqs.size;
        int initiator_ack_count_before_terminate = initiator_wire.result_iqs.size;

        if (!responder_router.terminate(responder_jid, "jmi-wire-smoke", "success", "jmi wire smoke done")) {
            throw new IOError.FAILED("JMI local terminate was not routed");
        }
        assert_jmi_state((!) responder, JmiState.ENDED, "responder JMI state after local terminate");
        assert_signaling_state((!) responder, SignalingState.ENDED, "responder wire state after local terminate");
        assert_int_eq(responder_router.contains(responder_jid, "jmi-wire-smoke") ? 1 : 0, 0, "responder router removed local ended session");
        assert_int_eq(
            responder_wire.jingle_iqs.size,
            responder_jingle_count_before_terminate + 1,
            "responder terminate IQ count");

        Iq.Stanza terminate_iq = responder_wire.jingle_iqs[responder_jingle_count_before_terminate];
        StanzaNode terminate = get_jingle(terminate_iq);
        assert_str_eq(terminate_iq.type_, Iq.Stanza.TYPE_SET, "terminate IQ type");
        assert_jid_eq(terminate_iq.from, responder_jid, "terminate IQ from");
        assert_jid_eq(terminate_iq.to, initiator_jid, "terminate IQ to");
        assert_session_terminate_jingle(
            terminate,
            "jmi-wire-smoke",
            "success",
            "jmi wire smoke done",
            "JMI terminate");

        if (!initiator_interceptor.route_iq_set_for_local_jid(initiator_jid, terminate_iq)) {
            throw new IOError.FAILED("JMI session-terminate was not routed");
        }
        ((!) initiator).disconnect(terminated_handler);
        assert_jmi_state((!) initiator, JmiState.ENDED, "initiator JMI state after remote terminate");
        assert_signaling_state((!) initiator, SignalingState.ENDED, "initiator wire state after remote terminate");
        assert_int_eq(initiator_router.contains(initiator_jid, "jmi-wire-smoke") ? 1 : 0, 0, "initiator router removed remote ended session");
        if (!initiator_remote_terminated) {
            throw new IOError.FAILED("initiator JMI session did not emit remote_terminated");
        }
        assert_str_eq(initiator_remote_terminate_reason, "success", "initiator remote terminate reason");
        assert_str_eq(initiator_remote_terminate_text, "jmi wire smoke done", "initiator remote terminate text");
        assert_int_eq(
            initiator_wire.result_iqs.size,
            initiator_ack_count_before_terminate + 1,
            "initiator terminate ACK count");
        Iq.Stanza terminate_ack = initiator_wire.result_iqs[initiator_ack_count_before_terminate];
        assert_jid_eq(terminate_ack.from, initiator_jid, "terminate ACK from");
        assert_jid_eq(terminate_ack.to, responder_jid, "terminate ACK to");

        assert_int_eq(initiator_wire.error_iqs.size, 1, "initiator error count");
        assert_int_eq(responder_wire.error_iqs.size, 11, "responder error count");

        ((!) initiator).disconnect(direct_iq_failed_handler);
        ((!) responder).close();
        ((!) initiator).close();
        ((!) context).close();
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-jmi-wire-smoke failed: %s\n", e.message);
        if (responder != null) ((!) responder).close();
        if (initiator != null) ((!) initiator).close();
        if (context != null) ((!) context).close();
        return 1;
    }
}

}

public int main(string[] args) {
    if (args.length == 2 && args[1] == "--iq-ordering-only") {
        try {
            Dino.Plugins.GoogleWebrtc.Test.run_setup_iq_ordering_tests();
            return 0;
        } catch (Error error) {
            printerr("Google wire setup ordering failed: %s\n", error.message);
            return 1;
        }
    }
    return Dino.Plugins.GoogleWebrtc.Test.run_smoke();
}
