using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

public errordomain JmiError {
    BAD_STATE,
    BAD_STANZA
}

public enum JmiState {
    NEW,
    PROPOSED,
    PROCEED_SENT,
    PROCEED_RECEIVED,
    REJECTED,
    RETRACTED,
    ENDED
}

public interface EngineJmiTransport : Object {
    public abstract void send_propose(Jid to, string sid, Gee.List<StanzaNode> descriptions);
    public abstract void send_accept_to_self(string sid);
    public abstract void send_proceed(Jid to, string sid);
    public abstract void send_reject(Jid to, string sid);
    public abstract void send_reject_to_self(string sid);
    public abstract void send_retract(Jid to, string sid);
}

/**
 * Real XMPP Jingle Message Initiation transport for the libwebrtc call engine.
 * It deliberately reuses DinoX's existing XEP-0353 module instead of inventing
 * a second stanza format.
 */
public class XmppEngineJmiTransport : Object, EngineJmiTransport {
    private XmppStream stream;

    public XmppEngineJmiTransport(XmppStream stream) {
        this.stream = stream;
    }

    public void send_propose(Jid to, string sid, Gee.List<StanzaNode> descriptions) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_propose_to_peer(stream, to, sid, descriptions);
    }

    public void send_accept_to_self(string sid) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_accept_to_self(stream, sid);
    }

    public void send_proceed(Jid to, string sid) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_proceed_to_peer(stream, to, sid);
    }

    public void send_reject(Jid to, string sid) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_reject_to_peer(stream, to, sid);
    }

    public void send_reject_to_self(string sid) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_reject_to_self(stream, sid);
    }

    public void send_retract(Jid to, string sid) {
        stream.get_module<JingleMessageInitiation.Module>(JingleMessageInitiation.Module.IDENTITY)
            .send_session_retract_to_peer(stream, to, sid);
    }
}

/**
 * XEP-0353 gate in front of EngineJingleWireSession.
 *
 * Outgoing calls send a JMI propose first and create/start the libwebrtc Jingle
 * IQ session only after the peer replies with proceed from a concrete full JID.
 * Incoming calls validate a received proposal, send accept/proceed, and create
 * the incoming IQ wire session only when the following session-initiate IQ
 * arrives. This mirrors DinoX's current call_resource boundary while keeping
 * without routing the owned call through the retired RTP/GStreamer engine.
 */
public class EngineJmiSession : Dino.Plugins.JmiCallEngineSession {
    private const string CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";
    private const uint OUTGOING_OFFER_AFTER_PROCEED_DELAY_MS = 1500;

    public EngineContext context { get; private set; }
    public EngineJingleWireTransport wire_transport { get; private set; }
    public EngineJmiTransport jmi_transport { get; private set; }
    public string sid { get; private set; }
    public uint64 logical_call_id { get; private set; }
    public Jid local_full_jid { get; private set; }
    public Jid peer_jid { get; private set; }
    public Jid? muji_room_jid { get; private set; default = null; }
    public bool is_muji { get { return muji_room_jid != null; } }
    public bool audio_requested { get; private set; default = true; }
    public bool video_requested { get; private set; default = false; }
    public JmiState jmi_state { get; private set; default = JmiState.NEW; }
    public EngineJingleWireSession? wire_session { get; private set; default = null; }
    public bool local_audio_enabled { get; private set; default = true; }
    public bool local_video_enabled { get; private set; default = true; }
    public EngineVideoEffectPipelineOwner? video_effect_pipeline { get; private set; default = null; }
    public Gee.List<EngineIceServer> ice_servers { get; private set; }
    private EngineVideoDeviceInfo? selected_video_device = null;
    private Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC;
    private bool bundle_grouping_enabled = false;
    private HashMap<string, string>? muji_content_names_by_media = null;
    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>?
        muji_payload_types_by_media = null;

    private ulong wire_active_handler_id = 0;
    private ulong wire_failed_handler_id = 0;
    private ulong wire_remote_terminated_handler_id = 0;
    private ulong wire_remote_video_frame_handler_id = 0;
    private ulong wire_local_video_frame_handler_id = 0;
    private ulong video_effect_pipeline_state_handler_id = 0;
    private uint outgoing_offer_delay_timeout_id = 0;
    private bool video_effects_blocked_for_group_call = false;
    private weak EngineMujiGroupSession? muji_group_owner = null;
#if GOOGLE_WEBRTC_EFFECT_TEST
    private bool fail_next_group_video_state_apply_for_test = false;
    private bool local_capture_start_suppressed_for_test = false;
#endif
    // Sticky even while the owner is releasing this leg, so a queued frame
    // from an old preview publisher can never fall back to direct preview.
    private bool muji_group_video_managed = false;
    private Gee.ArrayList<EngineVideoEffectPipelineOwner> closing_video_effect_pipelines =
        new Gee.ArrayList<EngineVideoEffectPipelineOwner>();
    private Dino.Plugins.JmiVideoEffectCapabilities video_effect_capabilities =
        Dino.Plugins.JmiVideoEffectCapabilities.unavailable(
            Dino.Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
    private Dino.Plugins.JmiVideoEffectStatus video_effect_status =
        new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
            Dino.Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
            0,
            0,
            Dino.Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);

    public signal void wire_session_started(EngineJingleWireSession session);
    public signal void rejected();
    public signal void retracted();
    public signal void ended();

    private static bool call_debug_enabled() {
        string? enabled = Environment.get_variable(CALL_DEBUG_ENV);
        return enabled == "1" || enabled == "true" || enabled == "yes";
    }

    public EngineJmiSession.outgoing(
            EngineContext context,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            string sid,
            uint64 logical_call_id,
            Jid local_full_jid,
            Jid peer_jid,
            bool audio_requested = true,
            bool video_requested = false,
            Gee.List<EngineIceServer>? ice_servers = null,
            Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC) throws JmiError {
        validate_sid(sid);
        if (logical_call_id == 0) {
            throw new JmiError.BAD_STATE("Google/libwebrtc call requires a stable logical call id");
        }
        if (!audio_requested && !video_requested) {
            throw new JmiError.BAD_STANZA("JMI proposal must contain at least one media description");
        }
        this.context = context;
        this.wire_transport = wire_transport;
        this.jmi_transport = jmi_transport;
        this.sid = sid;
        this.logical_call_id = logical_call_id;
        this.local_full_jid = local_full_jid;
        this.peer_jid = peer_jid;
        this.audio_requested = audio_requested;
        this.video_requested = video_requested;
        this.network_policy = network_policy;
        this.ice_servers = copy_ice_servers(ice_servers);
    }

    public EngineJmiSession.incoming(
            EngineContext context,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            string sid,
            uint64 logical_call_id,
            Jid local_full_jid,
            Jid peer_full_jid,
            Gee.List<StanzaNode> descriptions,
            Gee.List<EngineIceServer>? ice_servers = null,
            Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC) throws JmiError {
        validate_sid(sid);
        if (logical_call_id == 0) {
            throw new JmiError.BAD_STATE("Google/libwebrtc call requires a stable logical call id");
        }
        this.context = context;
        this.wire_transport = wire_transport;
        this.jmi_transport = jmi_transport;
        this.sid = sid;
        this.logical_call_id = logical_call_id;
        this.local_full_jid = local_full_jid;
        this.peer_jid = peer_full_jid;
        bool audio;
        bool video;
        parse_descriptions(descriptions, out audio, out video);
        this.audio_requested = audio;
        this.video_requested = video;
        this.network_policy = video ? Native.NetworkPolicy.AUTOMATIC : network_policy;
        this.jmi_state = JmiState.PROPOSED;
        this.ice_servers = copy_ice_servers(ice_servers);
    }

    /** Direct full-JID peer leg inside an already accepted MUJI room. */
    public EngineJmiSession.muji_outgoing(
            EngineContext context,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            string sid,
            uint64 logical_call_id,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid room_jid,
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                payload_types_by_media,
            bool video_requested = false,
            Gee.List<EngineIceServer>? ice_servers = null,
            Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC) throws JmiError {
        this.muji_outgoing_with_bundle(
            context, wire_transport, jmi_transport, sid, logical_call_id,
            local_full_jid, peer_full_jid, room_jid,
            content_names_by_media, payload_types_by_media,
            video_requested, ice_servers, network_policy, false);
    }

    internal EngineJmiSession.muji_outgoing_with_bundle(
            EngineContext context,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            string sid,
            uint64 logical_call_id,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid room_jid,
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                payload_types_by_media,
            bool video_requested,
            Gee.List<EngineIceServer>? ice_servers,
            Native.NetworkPolicy network_policy,
            bool bundle_grouping_enabled) throws JmiError {
        validate_muji_addresses(local_full_jid, peer_full_jid, room_jid);
        validate_sid(sid);
        if (logical_call_id == 0) {
            throw new JmiError.BAD_STATE("Google/libwebrtc MUJI call requires a stable logical call id");
        }
        this.context = context;
        this.wire_transport = wire_transport;
        this.jmi_transport = jmi_transport;
        this.sid = sid;
        this.logical_call_id = logical_call_id;
        this.local_full_jid = local_full_jid;
        this.peer_jid = peer_full_jid;
        this.muji_room_jid = room_jid;
        this.muji_content_names_by_media = copy_string_map(
            content_names_by_media);
        this.muji_payload_types_by_media = copy_payload_map(
            payload_types_by_media);
        this.audio_requested = true;
        this.video_requested = video_requested;
        this.video_effects_blocked_for_group_call = true;
        this.network_policy = video_requested ? Native.NetworkPolicy.AUTOMATIC : network_policy;
        this.bundle_grouping_enabled = bundle_grouping_enabled;
        this.ice_servers = copy_ice_servers(ice_servers);
    }

    /** Expected incoming full-JID peer leg claimed from a MUJI session-initiate. */
    public EngineJmiSession.muji_incoming(
            EngineContext context,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            string sid,
            uint64 logical_call_id,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid room_jid,
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                payload_types_by_media,
            bool video_requested = false,
            Gee.List<EngineIceServer>? ice_servers = null,
            Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC) throws JmiError {
        validate_muji_addresses(local_full_jid, peer_full_jid, room_jid);
        validate_sid(sid);
        if (logical_call_id == 0) {
            throw new JmiError.BAD_STATE("Google/libwebrtc MUJI call requires a stable logical call id");
        }
        this.context = context;
        this.wire_transport = wire_transport;
        this.jmi_transport = jmi_transport;
        this.sid = sid;
        this.logical_call_id = logical_call_id;
        this.local_full_jid = local_full_jid;
        this.peer_jid = peer_full_jid;
        this.muji_room_jid = room_jid;
        this.muji_content_names_by_media = copy_string_map(
            content_names_by_media);
        this.muji_payload_types_by_media = copy_payload_map(
            payload_types_by_media);
        this.audio_requested = true;
        this.video_requested = video_requested;
        this.video_effects_blocked_for_group_call = true;
        this.network_policy = video_requested ? Native.NetworkPolicy.AUTOMATIC : network_policy;
        this.jmi_state = JmiState.PROCEED_SENT;
        this.ice_servers = copy_ice_servers(ice_servers);
    }

    public EngineJingleWireSession start_muji_outgoing() throws Error {
        if (!is_muji) {
            throw new JmiError.BAD_STATE("Only a MUJI peer session can start direct Jingle");
        }
        require_state(JmiState.NEW, "starting direct MUJI Jingle");
        EngineJingleWireSession started = create_outgoing_wire_session(peer_jid);
        jmi_state = JmiState.PROCEED_RECEIVED;
        try {
            started.start_outgoing_offer();
        } catch (Error e) {
            disconnect_wire_session();
            started.close();
            wire_session = null;
            throw e;
        }
        return started;
    }

    internal void set_muji_bundle_grouping_enabled(bool enabled)
            throws JmiError {
        if (!is_muji || jmi_state != JmiState.NEW || wire_session != null) {
            throw new JmiError.BAD_STATE(
                "MUJI BUNDLE capability must be resolved before Jingle starts");
        }
        bundle_grouping_enabled = enabled;
    }

    internal void report_start_failure(string message) {
        if (jmi_state == JmiState.ENDED) return;
        failed(message);
    }

    public void propose() throws JmiError {
        require_state(JmiState.NEW, "sending JMI propose");
        jmi_transport.send_propose(peer_jid, sid, build_descriptions(audio_requested, video_requested));
        jmi_state = JmiState.PROPOSED;
    }

    public EngineJingleWireSession handle_proceed(
            Jid from,
            Jid to,
            string incoming_sid) throws Error {
        require_state(JmiState.PROPOSED, "handling JMI proceed");
        validate_jmi_reply(from, to, incoming_sid, "JMI proceed");
        if (from.resourcepart == null) {
            throw new JmiError.BAD_STANZA("JMI proceed must come from a full JID before Jingle IQ can start");
        }

        // The proposal targets a bare JID, while the accepted Jingle leg is
        // bound to the exact resource that sent <proceed/>. Keep that binding
        // on the session so a later MUJI conversion can safely adopt it.
        peer_jid = from;
        EngineJingleWireSession started = create_outgoing_wire_session(from);
        jmi_state = JmiState.PROCEED_RECEIVED;
        schedule_outgoing_offer_after_proceed(started);
        return started;
    }

    public void handle_reject(Jid from, Jid to, string incoming_sid) throws JmiError {
        require_state(JmiState.PROPOSED, "handling JMI reject");
        validate_jmi_reply(from, to, incoming_sid, "JMI reject");
        jmi_state = JmiState.REJECTED;
        rejected();
    }

    public void retract() throws JmiError {
        require_state(JmiState.PROPOSED, "retracting JMI proposal");
        jmi_transport.send_retract(peer_jid, sid);
        jmi_state = JmiState.RETRACTED;
        retracted();
    }

    public override void accept_proposal() throws Error {
        if (is_muji) {
            require_state(JmiState.PROCEED_SENT, "accepting direct MUJI session");
            if (wire_session == null) {
                throw new JmiError.BAD_STATE("Cannot accept MUJI peer before session-initiate was handled");
            }
            return;
        }
        require_state(JmiState.PROPOSED, "accepting JMI proposal");
        if (peer_jid.resourcepart == null) {
            throw new JmiError.BAD_STANZA("incoming JMI proposal must come from a full JID");
        }
        jmi_transport.send_accept_to_self(sid);
        jmi_transport.send_proceed(peer_jid, sid);
        jmi_state = JmiState.PROCEED_SENT;
    }

    public override void reject_proposal() throws Error {
        if (is_muji) {
            if (wire_session != null) {
                terminate(Xep.Jingle.ReasonElement.DECLINE, "MUJI peer session rejected");
            } else {
                close();
                ended();
            }
            return;
        }
        require_state(JmiState.PROPOSED, "rejecting JMI proposal");
        jmi_transport.send_reject(peer_jid, sid);
        jmi_transport.send_reject_to_self(sid);
        jmi_state = JmiState.REJECTED;
        rejected();
    }

    public override void set_local_audio_enabled(bool enabled) throws Error {
        local_audio_enabled = enabled;
        if (wire_session != null) {
            apply_local_audio_enabled((!) wire_session);
        }
    }

    public override void set_local_video_enabled(bool enabled) throws Error {
        if (muji_group_owner != null) {
            ((!) muji_group_owner).set_local_video_enabled(enabled);
            return;
        }
        local_video_enabled = enabled;
        if (wire_session != null) {
            apply_local_video_enabled((!) wire_session);
        }
    }

    public override void set_video_device(Dino.Plugins.MediaDevice device) throws Error {
        if (muji_group_owner != null) {
            ((!) muji_group_owner).set_video_device(device);
            return;
        }
        EngineVideoMediaDevice? engine_device = device as EngineVideoMediaDevice?;
        if (engine_device == null) {
            throw new EngineError.PROTOCOL("Media device does not belong to the Google/libwebrtc engine");
        }
        selected_video_device = engine_device.info;
        if (wire_session != null && video_requested && local_video_enabled) {
            ((!) wire_session).session.engine.start_video_capture(engine_device.info, 640, 480, 30);
        }
    }

    public override void send_dtmf(char digit, uint duration_ms = 250) throws Error {
        if (wire_session == null) {
            throw new JmiError.BAD_STATE("Cannot send DTMF before the Google/libwebrtc wire session has started");
        }
        try {
            uint feedback_duration_ms = duration_ms;
            if (feedback_duration_ms < 120) feedback_duration_ms = 120;
            if (feedback_duration_ms > 300) feedback_duration_ms = 300;
            ((!) wire_session).session.engine.play_local_dtmf_feedback(digit, feedback_duration_ms);
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug("Google/libwebrtc call: local DTMF feedback skipped: %s", e.message);
            }
        }
        ((!) wire_session).session.engine.send_dtmf(digit, duration_ms);
    }

    public void update_ice_servers(Gee.List<EngineIceServer>? updated_ice_servers) {
        if (wire_session != null) return;
        ice_servers = copy_ice_servers(updated_ice_servers);
    }

    public override Dino.Plugins.JmiCallDiagnostics? get_diagnostics() throws Error {
        var diagnostics = new Dino.Plugins.JmiCallDiagnostics();
        diagnostics.audio_requested = audio_requested;
        diagnostics.video_requested = video_requested;
        diagnostics.local_audio_track_enabled = local_audio_enabled;
        diagnostics.ice_server_count = ice_servers.size;
        diagnostics.jmi_state = jmi_state_to_debug_string(jmi_state);

        if (wire_session == null) {
            diagnostics.wire_started = false;
            diagnostics.peer_connection_state = "not-started";
            diagnostics.ice_connection_state = "not-started";
            return diagnostics;
        }

        Native.SessionState state = ((!) wire_session).session.engine.get_state();
        diagnostics.wire_started = true;
        diagnostics.audio_transceiver_count = state.audio_transceiver_count;
        diagnostics.video_transceiver_count = state.video_transceiver_count;
        diagnostics.local_audio_source_attached = state.local_audio_source_attached != 0;
        diagnostics.local_audio_track_attached = state.local_audio_track_attached != 0;
        diagnostics.local_audio_track_enabled = state.local_audio_track_enabled != 0;
        diagnostics.local_video_source_attached = state.local_video_source_attached != 0;
        diagnostics.local_video_track_attached = state.local_video_track_attached != 0;
        diagnostics.local_video_track_enabled = state.local_video_track_enabled != 0;
        diagnostics.local_video_capture_running = state.local_video_capture_running != 0;
        diagnostics.local_video_capture_frame_count = state.local_video_capture_frame_count;
        diagnostics.local_video_capture_last_width = state.local_video_capture_last_width;
        diagnostics.local_video_capture_last_height = state.local_video_capture_last_height;
        diagnostics.remote_audio_receiver_count = state.remote_audio_receiver_count;
        diagnostics.remote_video_receiver_count = state.remote_video_receiver_count;
        diagnostics.remote_audio_sink_count = state.remote_audio_sink_count;
        diagnostics.remote_audio_sink_frame_count = state.remote_audio_sink_frame_count;
        diagnostics.remote_audio_sink_sample_count = state.remote_audio_sink_sample_count;
        diagnostics.remote_audio_sink_peak_level = state.remote_audio_sink_peak_level;
        diagnostics.remote_video_sink_count = state.remote_video_sink_count;
        diagnostics.remote_video_sink_frame_count = state.remote_video_sink_frame_count;
        diagnostics.remote_video_sink_last_width = state.remote_video_sink_last_width;
        diagnostics.remote_video_sink_last_height = state.remote_video_sink_last_height;
        diagnostics.inbound_audio_packets_received = state.inbound_audio_packets_received;
        diagnostics.inbound_audio_bytes_received = state.inbound_audio_bytes_received;
        diagnostics.inbound_audio_total_samples_received = state.inbound_audio_total_samples_received;
        diagnostics.inbound_video_packets_received = state.inbound_video_packets_received;
        diagnostics.inbound_video_bytes_received = state.inbound_video_bytes_received;
        diagnostics.inbound_video_frames_received = state.inbound_video_frames_received;
        diagnostics.inbound_video_frames_decoded = state.inbound_video_frames_decoded;
        diagnostics.inbound_video_frame_width = state.inbound_video_frame_width;
        diagnostics.inbound_video_frame_height = state.inbound_video_frame_height;
        diagnostics.outbound_audio_packets_sent = state.outbound_audio_packets_sent;
        diagnostics.outbound_audio_bytes_sent = state.outbound_audio_bytes_sent;
        diagnostics.outbound_audio_target_bitrate = state.outbound_audio_target_bitrate;
        diagnostics.call_network_policy = state.network_policy == Native.NetworkPolicy.LOW_BANDWIDTH_2G
            ? "low-bandwidth-2g"
            : "automatic";
        diagnostics.audio_sender_bitrate_cap_bps = state.audio_sender_bitrate_cap_bps;
        diagnostics.audio_sender_adaptive_ptime = state.audio_sender_adaptive_ptime != 0;
        diagnostics.audio_sender_policy_applied = state.audio_sender_policy_applied != 0;
        diagnostics.outbound_video_packets_sent = state.outbound_video_packets_sent;
        diagnostics.outbound_video_bytes_sent = state.outbound_video_bytes_sent;
        diagnostics.outbound_video_frames_sent = state.outbound_video_frames_sent;
        diagnostics.outbound_video_frames_encoded = state.outbound_video_frames_encoded;
        diagnostics.outbound_video_target_bitrate = state.outbound_video_target_bitrate;
        diagnostics.outbound_video_frame_width = state.outbound_video_frame_width;
        diagnostics.outbound_video_frame_height = state.outbound_video_frame_height;
        diagnostics.inbound_audio_level = state.inbound_audio_level;
        diagnostics.source_audio_level = state.source_audio_level;
        diagnostics.source_audio_total_energy = state.source_audio_total_energy;
        diagnostics.source_audio_total_duration = state.source_audio_total_duration;
        diagnostics.stats_report_count = state.stats_report_count;
        diagnostics.audio_device_initialized = state.audio_device_initialized != 0;
        diagnostics.audio_device_playout_initialized = state.audio_device_playout_initialized != 0;
        diagnostics.audio_device_recording_initialized = state.audio_device_recording_initialized != 0;
        diagnostics.audio_device_playing = state.audio_device_playing != 0;
        diagnostics.audio_device_recording = state.audio_device_recording != 0;
        diagnostics.audio_device_capture_sample_count = state.audio_device_capture_sample_count;
        diagnostics.audio_device_capture_probe_frame_count = state.audio_device_capture_probe_frame_count;
        diagnostics.audio_device_capture_probe_sample_count = state.audio_device_capture_probe_sample_count;
        diagnostics.audio_device_capture_probe_peak_level = state.audio_device_capture_probe_peak_level;
        diagnostics.audio_device_playout_sample_count = state.audio_device_playout_sample_count;
        diagnostics.audio_device_microphone_volume_available = state.audio_device_microphone_volume_available != 0;
        diagnostics.audio_device_microphone_volume = state.audio_device_microphone_volume;
        diagnostics.audio_device_speaker_volume_available = state.audio_device_speaker_volume_available != 0;
        diagnostics.audio_device_speaker_volume = state.audio_device_speaker_volume;
        diagnostics.local_dtmf_feedback_start_count = state.local_dtmf_feedback_start_count;
        diagnostics.local_dtmf_feedback_mix_call_count = state.local_dtmf_feedback_mix_call_count;
        diagnostics.local_dtmf_feedback_mixed_frame_count = state.local_dtmf_feedback_mixed_frame_count;
        diagnostics.local_dtmf_feedback_unsupported_format_count = state.local_dtmf_feedback_unsupported_format_count;
        diagnostics.local_dtmf_feedback_last_sample_rate = state.local_dtmf_feedback_last_sample_rate;
        diagnostics.local_dtmf_feedback_last_channels = state.local_dtmf_feedback_last_channels;
        diagnostics.local_dtmf_feedback_last_bytes_per_sample = state.local_dtmf_feedback_last_bytes_per_sample;
        diagnostics.local_dtmf_feedback_peak_level = state.local_dtmf_feedback_peak_level;
        diagnostics.local_dtmf_feedback_active = state.local_dtmf_feedback_active != 0;
        diagnostics.ice_server_count = state.ice_server_count;
        diagnostics.peer_connection_state = peer_connection_state_to_debug_string(state.peer_connection_state);
        diagnostics.ice_connection_state = ice_connection_state_to_debug_string(state.ice_connection_state);
        return diagnostics;
    }

    public EngineJingleWireSession handle_session_initiate_iq(Iq.Stanza iq) throws Error {
        // A JMI proposal owns the SID before a Jingle session exists. Validate
        // the first IQ before allocating a native session: early transport-info
        // must not repeatedly create and immediately destroy media owners.
        try {
            if (iq.type_ != Iq.Stanza.TYPE_SET) {
                throw new JmiError.BAD_STANZA("expected IQ set for Jingle session-initiate");
            }
            if (iq.from == null || !((!) iq.from).equals(peer_jid)) {
                throw new JmiError.BAD_STANZA("Jingle session-initiate came from an unexpected peer");
            }
            if (!EngineJmiIqInterceptor.recipient_matches_local(local_full_jid, iq.to)) {
                throw new JmiError.BAD_STANZA("Jingle session-initiate has an unexpected recipient");
            }
            StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
            if (jingle == null || ((!) jingle).get_attribute("sid") != sid) {
                throw new JmiError.BAD_STANZA("Jingle session-initiate has an unexpected SID");
            }
            string? action = ((!) jingle).get_attribute("action");
            if (action == null || ((!) action).strip() == "") {
                throw new JmiError.BAD_STANZA("Jingle action is missing");
            }
            if (action != "session-initiate" || jmi_state != JmiState.PROCEED_SENT) {
                throw new Jingle.IqError.OUT_OF_ORDER(
                    "Jingle session-initiate is required after JMI proceed before other actions");
            }
        } catch (Error e) {
            if (iq.from != null && iq.type_ == Iq.Stanza.TYPE_SET) {
                wire_transport.send_error_iq(iq,
                    EngineJingleWireSession.build_error_stanza(e));
            }
            throw e;
        }

        bool created = wire_session == null;
        EngineJingleWireSession started = ensure_incoming_wire_session((!) iq.from);
        try {
            started.handle_iq_set(iq);
        } catch (Error e) {
            if (created) {
                disconnect_wire_session();
                started.close();
                wire_session = null;
            }
            throw e;
        }
        return started;
    }

    public EngineJingleWireSession handle_jingle_iq_set(Iq.Stanza iq) throws Error {
        if (wire_session == null) {
            return handle_session_initiate_iq(iq);
        }
        ((!) wire_session).handle_iq_set(iq);
        return (!) wire_session;
    }

    public void terminate(string? reason_name = null, string? reason_text = null) throws Error {
        if (jmi_state == JmiState.ENDED) return;
        if (wire_session == null) {
            throw new JmiError.BAD_STATE("Cannot terminate before the Jingle wire session has started");
        }
        ((!) wire_session).terminate(reason_name, reason_text);
        jmi_state = JmiState.ENDED;
        ended();
    }

    public override void end(string? reason_name, string? reason_text) throws Error {
        if (jmi_state == JmiState.ENDED) return;
        if (jmi_state == JmiState.PROPOSED) {
            retract();
            return;
        }
        if (wire_session != null) {
            terminate(reason_name, reason_text);
            return;
        }
        close();
        ended();
    }

    public override void discard() {
        if (jmi_state == JmiState.ENDED) return;
        close();
        ended();
    }

    public override void close() {
        clear_outgoing_offer_delay();
        // Suppress effect UI callbacks immediately and enqueue native pipeline
        // destruction before closing the wire owner. The C pipeline destructor
        // removes its attachments without dereferencing the later-closed Vala
        // session object.
        close_video_effect_pipeline(
            Dino.Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED);
        disconnect_wire_session();
        if (wire_session != null) {
            ((!) wire_session).close();
            wire_session = null;
        }
        if (jmi_state != JmiState.REJECTED && jmi_state != JmiState.RETRACTED) {
            jmi_state = JmiState.ENDED;
        }
    }

    public override Dino.Plugins.JmiVideoEffectCapabilities get_video_effect_capabilities() {
        return video_effect_capabilities;
    }

    public override Dino.Plugins.JmiVideoEffectStatus get_video_effect_status() {
        return video_effect_status;
    }

    public override async void release_video_background(uint asset_id) throws Error {
        EngineVideoEffectPipelineOwner? pipeline = video_effect_pipeline;
        if (pipeline != null) yield ((!) pipeline).release_background(asset_id);
    }

    public override async uint stage_video_background(uint builtin_choice,
            Dino.Plugins.JmiVideoBackgroundImage? image = null) throws Error {
        if (video_effects_blocked_for_group_call || !video_requested || jmi_state == JmiState.ENDED || video_effect_pipeline == null)
            throw new IOError.NOT_SUPPORTED("No live video pipeline is available");
        EngineVideoEffectPipelineOwner pipeline = (!) video_effect_pipeline;
        uint asset = yield pipeline.stage_background(builtin_choice, image);
        if (video_effects_blocked_for_group_call || !video_requested || jmi_state == JmiState.ENDED || video_effect_pipeline != pipeline) {
            try { yield pipeline.release_background(asset); } catch (Error ignored) { }
            throw new IOError.CANCELLED("The background image call owner changed");
        }
        return asset;
    }

    public override async uint64 select_video_effect(
            Dino.Plugins.JmiVideoEffectSelection selection) throws Error {
        if (video_effects_blocked_for_group_call) {
            throw new IOError.NOT_SUPPORTED("Video effects are disabled for MUJI group calls");
        }
        if (!video_requested) {
            throw new IOError.NOT_SUPPORTED("Video effects require an outgoing video track");
        }
        EngineVideoEffectPipelineOwner? pipeline = video_effect_pipeline;
        if (pipeline == null || !video_effect_capabilities.available) {
            throw new IOError.NOT_SUPPORTED("Video effects are unavailable for this call");
        }
        Native.VideoEffectConfig config = VideoEffectConfigMapper.to_native(
            selection, video_effect_capabilities);
        uint64 revision = yield ((!) pipeline).select_config(config);
        if (video_effects_blocked_for_group_call ||
                video_effect_pipeline != pipeline || jmi_state == JmiState.ENDED) {
            throw new IOError.CANCELLED("The video-effect pipeline changed");
        }

        Native.VideoPipelineState native_state = {};
        if (revision < video_effect_status.accepted_revision) return revision;
        if (((!) pipeline).get_cached_state(out native_state) &&
                native_state.applied_revision >= revision) {
            publish_video_effect_state(native_state);
        } else {
            video_effect_status = new Dino.Plugins.JmiVideoEffectStatus(
                selection,
                Dino.Plugins.JmiVideoEffectApplyState.ACCEPTED,
                revision,
                native_state.applied_revision);
            video_effect_status_changed(video_effect_status);
        }
        return revision;
    }

    public override void disable_video_effects_for_group_call() {
        if (video_effects_blocked_for_group_call) return;
        video_effects_blocked_for_group_call = true;
        close_video_effect_pipeline(
            Dino.Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL,
            true);
    }

    public override async void fence_video_effects_for_group_call() {
        disable_video_effects_for_group_call();
        // A wire disconnect or offer failure may already have removed the
        // visible pipeline immediately before MUJI promotion while its native
        // cleanup is still queued behind an in-flight set_config request. Do
        // not fence just the currently visible pipeline: wait for every
        // closing pipeline owned by this JMI session. The loop also covers a
        // close registered while an earlier cleanup callback is dispatched.
        while (!closing_video_effect_pipelines.is_empty) {
            var pending = new Gee.ArrayList<EngineVideoEffectPipelineOwner>();
            pending.add_all(closing_video_effect_pipelines);
            foreach (EngineVideoEffectPipelineOwner pipeline in pending) {
                yield pipeline.close_and_wait_for_cleanup();
                closing_video_effect_pipelines.remove(pipeline);
            }
        }
    }

    ~EngineJmiSession() {
        close();
    }

    private EngineJingleWireSession create_outgoing_wire_session(Jid peer_full_jid) throws Error {
        disconnect_wire_session();
        EngineJingleWireSession started;
        if (muji_room_jid != null && bundle_grouping_enabled) {
            started = new EngineJingleWireSession.outgoing_with_bundle(
                create_engine_session(false),
                wire_transport,
                sid,
                local_full_jid,
                peer_full_jid,
                (!) muji_room_jid);
        } else if (muji_room_jid != null) {
            started = new EngineJingleWireSession.muji_outgoing(
                create_engine_session(false),
                wire_transport,
                sid,
                local_full_jid,
                peer_full_jid,
                (!) muji_room_jid);
        } else {
            started = new EngineJingleWireSession.outgoing(
                create_engine_session(false),
                wire_transport,
                sid,
                local_full_jid,
                peer_full_jid);
        }
        wire_session = started;
        try {
            attach_video_effect_pipeline(started);
            connect_wire_session(started);
            apply_local_audio_enabled(started);
            if (muji_group_owner != null) {
                ((!) muji_group_owner).attach_peer_wire_session(this, started);
            } else {
                apply_local_video_enabled(started);
            }
            wire_session_started(started);
        } catch (Error e) {
            disconnect_wire_session();
            started.close();
            wire_session = null;
            close_video_effect_pipeline();
            throw e;
        }
        return started;
    }

    private void schedule_outgoing_offer_after_proceed(EngineJingleWireSession started) {
        clear_outgoing_offer_delay();
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: delaying session-initiate sid=%s peer=%s wait=%ums reason=omemo-call-device-session",
                sid,
                peer_jid.to_string(),
                OUTGOING_OFFER_AFTER_PROCEED_DELAY_MS);
        }
        outgoing_offer_delay_timeout_id = Timeout.add(OUTGOING_OFFER_AFTER_PROCEED_DELAY_MS, () => {
            outgoing_offer_delay_timeout_id = 0;
            if (jmi_state != JmiState.PROCEED_RECEIVED || wire_session != started) return Source.REMOVE;
            try {
                started.start_outgoing_offer();
            } catch (Error e) {
                disconnect_wire_session();
                started.close();
                if (wire_session == started) wire_session = null;
                failed(e.message);
            }
            return Source.REMOVE;
        });
    }

    private void clear_outgoing_offer_delay() {
        if (outgoing_offer_delay_timeout_id == 0) return;
        Source.remove(outgoing_offer_delay_timeout_id);
        outgoing_offer_delay_timeout_id = 0;
    }

    private EngineJingleWireSession ensure_incoming_wire_session(Jid peer_full_jid) throws Error {
        if (wire_session != null) return (!) wire_session;

        EngineJingleWireSession started;
        if (muji_room_jid != null) {
            started = new EngineJingleWireSession.muji_incoming(
                create_engine_session(true),
                wire_transport,
                sid,
                local_full_jid,
                peer_full_jid,
                (!) muji_room_jid);
        } else {
            started = new EngineJingleWireSession.incoming(
                create_engine_session(true),
                wire_transport,
                sid,
                local_full_jid,
                peer_full_jid);
        }
        wire_session = started;
        try {
            attach_video_effect_pipeline(started);
            connect_wire_session(started);
            apply_local_audio_enabled(started);
            if (muji_group_owner != null) {
                ((!) muji_group_owner).attach_peer_wire_session(this, started);
            } else {
                apply_local_video_enabled(started);
            }
            wire_session_started(started);
        } catch (Error e) {
            disconnect_wire_session();
            started.close();
            wire_session = null;
            close_video_effect_pipeline();
            throw e;
        }
        return started;
    }

    private EngineSessionOwner create_engine_session(bool incoming) throws Error {
        EngineSessionOwner engine = context.create_session(
            build_engine_config(incoming));
        try {
            if (muji_content_names_by_media != null &&
                    muji_payload_types_by_media != null) {
                engine.configure_conference_media(
                    (!) muji_content_names_by_media,
                    (!) muji_payload_types_by_media);
            }
        } catch (Error e) {
            engine.close();
            throw e;
        }
        return engine;
    }

    private void attach_video_effect_pipeline(EngineJingleWireSession session) {
        if (!video_requested || video_effects_blocked_for_group_call) return;
        try {
            ensure_video_effect_pipeline().attach(session.session.engine, true);
        } catch (Error e) {
            // Effects are optional. Their failure must not turn an otherwise
            // usable audio/video call into a failed call.
            warning(
                "Google/libwebrtc video effects unavailable for this call; continuing without effects: %s",
                e.message);
            close_video_effect_pipeline();
        }
    }

    private EngineVideoEffectPipelineOwner ensure_video_effect_pipeline() throws Error {
        if (video_effects_blocked_for_group_call) {
            throw new IOError.NOT_SUPPORTED("Video effects are disabled for MUJI group calls");
        }
        if (video_effect_pipeline != null) return (!) video_effect_pipeline;

        EngineVideoEffectPipelineOwner pipeline =
            context.create_video_effect_pipeline(logical_call_id);
        video_effect_pipeline = pipeline;
        video_effect_pipeline_state_handler_id = pipeline.state_changed.connect(() => {
            Native.VideoPipelineState state = {};
            if (video_effect_pipeline == pipeline && pipeline.get_cached_state(out state)) {
                publish_video_effect_state(state);
            }
        });
        Native.VideoEffectCapabilities native_capabilities = pipeline.get_capabilities();
        video_effect_capabilities = VideoEffectConfigMapper.capabilities(native_capabilities);
        Native.VideoPipelineState initial_state = {};
        if (pipeline.get_cached_state(out initial_state)) {
            publish_video_effect_state(initial_state);
        }
        return pipeline;
    }

    private EngineVideoEffectPipelineOwner? close_video_effect_pipeline(
            Dino.Plugins.JmiVideoEffectUnavailableReason reason =
                Dino.Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED,
            bool emit_status = false) {
        EngineVideoEffectPipelineOwner? pipeline = video_effect_pipeline;
        if (pipeline != null && video_effect_pipeline_state_handler_id != 0 &&
                SignalHandler.is_connected((!) pipeline, video_effect_pipeline_state_handler_id)) {
            ((!) pipeline).disconnect(video_effect_pipeline_state_handler_id);
        }
        video_effect_pipeline_state_handler_id = 0;
        video_effect_pipeline = null;
        video_effect_capabilities = Dino.Plugins.JmiVideoEffectCapabilities.unavailable(
            reason);
        video_effect_status = new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
            Dino.Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
            0,
            0,
            reason);
        if (pipeline != null) track_video_effect_pipeline_cleanup((!) pipeline);
        if (emit_status) video_effect_status_changed(video_effect_status);
        return pipeline;
    }

    private void track_video_effect_pipeline_cleanup(
            EngineVideoEffectPipelineOwner pipeline) {
        // close() is deliberately synchronous only at the Vala ownership
        // boundary; native detach/destruction stays on the control worker.
        // Keep the pipeline in the session fence set until that worker has
        // completed the VIDEO_PIPELINE_DESTROY ordering barrier.
        pipeline.close();
        closing_video_effect_pipelines.add(pipeline);
        pipeline.close_and_wait_for_cleanup.begin((_, result) => {
            pipeline.close_and_wait_for_cleanup.end(result);
            closing_video_effect_pipelines.remove(pipeline);
        });
    }

    private void publish_video_effect_state(Native.VideoPipelineState state) {
        if (jmi_state == JmiState.ENDED || video_effects_blocked_for_group_call ||
                state.logical_call_id != logical_call_id ||
                state.accepted_revision < video_effect_status.accepted_revision ||
                state.applied_revision < video_effect_status.applied_revision) return;
        Dino.Plugins.JmiVideoEffectSelection selection;
        try {
            selection = VideoEffectConfigMapper.from_native(state);
        } catch (EngineError e) {
            warning("Invalid Google/libwebrtc effect state: %s", e.message);
            return;
        }
        Dino.Plugins.JmiVideoEffectApplyState apply_state;
        Dino.Plugins.JmiVideoEffectUnavailableReason reason =
            Dino.Plugins.JmiVideoEffectUnavailableReason.NONE;
        switch (state.application_state) {
            case Native.VideoEffectApplicationState.IDLE:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.IDLE;
                break;
            case Native.VideoEffectApplicationState.ACCEPTED:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.ACCEPTED;
                break;
            case Native.VideoEffectApplicationState.APPLIED:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.APPLIED;
                break;
            case Native.VideoEffectApplicationState.DEGRADED:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.DEGRADED;
                reason = Dino.Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE;
                break;
            case Native.VideoEffectApplicationState.UNAVAILABLE:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.UNAVAILABLE;
                reason = Dino.Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE;
                break;
            case Native.VideoEffectApplicationState.FAILED:
            default:
                apply_state = Dino.Plugins.JmiVideoEffectApplyState.FAILED;
                reason = Dino.Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE;
                break;
        }
        video_effect_status = new Dino.Plugins.JmiVideoEffectStatus(
            selection,
            apply_state,
            state.accepted_revision,
            state.applied_revision,
            reason);
        video_effect_status_changed(video_effect_status);
    }

    private void apply_local_audio_enabled(EngineJingleWireSession session) throws Error {
        if (!audio_requested) return;
        session.session.engine.set_local_audio_enabled(local_audio_enabled);
    }

    private void apply_local_video_enabled(EngineJingleWireSession session) throws Error {
        if (!video_requested) return;
        // A MUJI leg never owns a camera. Its group owner binds the shared
        // pipeline, changes all local tracks and selects the sole publisher.
        if (is_muji || muji_group_video_managed) return;
        try {
            session.session.engine.set_local_video_enabled(local_video_enabled);
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug("Google/libwebrtc call: local video track state not applied yet: %s", e.message);
            }
        }
        if (local_video_enabled) {
            start_local_video_capture_if_available(session);
        } else {
            session.session.engine.stop_video_capture();
        }
    }

    private void start_local_video_capture_if_available(EngineJingleWireSession session) {
        if (!video_requested) return;
#if GOOGLE_WEBRTC_EFFECT_TEST
        if (local_capture_start_suppressed_for_test) return;
#endif

        try {
            EngineVideoDeviceInfo? camera = selected_video_device;
            if (camera == null) {
                Gee.List<EngineVideoDeviceInfo> cameras = context.get_video_devices();
                if (cameras.is_empty) {
                    if (call_debug_enabled()) {
                        debug("Google/libwebrtc call: no camera available for local preview/capture");
                    }
                    return;
                }
                camera = cameras[0];
            }
            if (camera == null) {
                if (call_debug_enabled()) {
                    debug("Google/libwebrtc call: no camera available for local preview/capture");
                }
                return;
            }
            session.session.engine.start_video_capture((!) camera, 640, 480, 30);
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc call: started local camera capture sid=%s device=%s",
                    sid,
                    ((!) camera).display_name);
            }
        } catch (Error e) {
            if (call_debug_enabled()) {
                warning("Google/libwebrtc call: local camera capture unavailable: %s", e.message);
            }
        }
    }

    private EngineSessionConfig build_engine_config(bool incoming_responder) {
        var config = new EngineSessionConfig();
        config.audio_enabled = audio_requested;
        config.video_enabled = video_requested;
        config.max_bundle = should_use_max_bundle_transport_policy();
        config.network_policy = network_policy;
        // The incoming Jingle responder already gets the remote audio m-line
        // from Monal's offer. Creating an eager local transceiver before that
        // produces a second audio/video transceiver and breaks incoming media.
        config.defer_audio_transceiver_until_answer = incoming_responder;
        config.defer_video_transceiver_until_answer = incoming_responder;
        foreach (EngineIceServer ice_server in ice_servers) {
            config.add_ice_server(ice_server);
        }
        return config;
    }

    private bool should_use_max_bundle_transport_policy() {
        if (!is_muji) {
            // Preserve the established direct-call transport policy: 1:1
            // audio uses max-bundle, while audio+video uses separate
            // transports.
            return !(audio_requested && video_requested);
        }
        // MUJI uses libwebrtc's balanced policy even when it offers BUNDLE.
        // That keeps a standards-compliant unbundled answer usable instead of
        // forcing all media onto a single transport before the peer agrees.
        return false;
    }

    private static Gee.List<EngineIceServer> copy_ice_servers(Gee.List<EngineIceServer>? source) {
        var ret = new ArrayList<EngineIceServer>();
        if (source != null) ret.add_all((!) source);
        return ret;
    }

    private static HashMap<string, string> copy_string_map(
            Gee.Map<string, string> source) {
        var ret = new HashMap<string, string>();
        foreach (var entry in source.entries) {
            ret[entry.key] = entry.value;
        }
        return ret;
    }

    private static HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
            copy_payload_map(
                Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> source) {
        var ret = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        foreach (var entry in source.entries) {
            var payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            foreach (Xep.JingleRtp.PayloadType payload_type in entry.value) {
                payloads.add(payload_type.clone());
            }
            ret[entry.key] = payloads;
        }
        return ret;
    }

    private void connect_wire_session(EngineJingleWireSession session) {
        wire_active_handler_id = session.active.connect(() => {
            if (muji_group_owner != null) {
                ((!) muji_group_owner).reapply_peer_video_state(this);
            }
            if (audio_requested) media_ready("audio");
            if (video_requested) media_ready("video");
            active();
        });
        wire_failed_handler_id = session.failed.connect((message) => {
            failed(message);
        });
        wire_remote_terminated_handler_id = session.remote_terminated.connect((reason_name, reason_text) => {
            jmi_state = JmiState.ENDED;
            remote_terminated(reason_name, reason_text);
        });
        wire_remote_video_frame_handler_id = session.session.engine.remote_video_frame.connect((frame) => {
            remote_video_frame(frame);
        });
        wire_local_video_frame_handler_id = session.session.engine.local_video_frame.connect((frame) => {
            EngineMujiGroupSession? group = muji_group_owner;
            if (!muji_group_video_managed ||
                    (group != null && ((!) group).should_publish_local_preview(
                        this, session.session.engine))) {
                local_video_frame(frame);
            }
        });
    }

    private void disconnect_wire_session() {
        // Never synchronously detach the effect pipeline here. Detach crosses
        // the worker IPC boundary and can wait for its timeout while this
        // method runs on the GTK/main thread (including offer-error paths).
        // Closing is immediate at the Vala boundary; native destruction owns
        // the eventual detach on the existing control worker. A replacement
        // wire session receives a fresh pipeline in attach_video_effect_pipeline().
        if (video_effect_pipeline != null) close_video_effect_pipeline();
        if (wire_session == null) return;
        EngineJingleWireSession session = (!) wire_session;
        if (muji_group_owner != null) {
            ((!) muji_group_owner).detach_peer_wire_session(this, session);
        }
        if (wire_active_handler_id != 0) {
            session.disconnect(wire_active_handler_id);
            wire_active_handler_id = 0;
        }
        if (wire_failed_handler_id != 0) {
            session.disconnect(wire_failed_handler_id);
            wire_failed_handler_id = 0;
        }
        if (wire_remote_terminated_handler_id != 0) {
            session.disconnect(wire_remote_terminated_handler_id);
            wire_remote_terminated_handler_id = 0;
        }
        if (wire_remote_video_frame_handler_id != 0) {
            session.session.engine.disconnect(wire_remote_video_frame_handler_id);
            wire_remote_video_frame_handler_id = 0;
        }
        if (wire_local_video_frame_handler_id != 0) {
            session.session.engine.disconnect(wire_local_video_frame_handler_id);
            wire_local_video_frame_handler_id = 0;
        }
    }

    internal void bind_muji_group_owner(EngineMujiGroupSession owner) throws Error {
        if (muji_group_owner != null && muji_group_owner != owner) {
            throw new JmiError.BAD_STATE("MUJI peer leg already belongs to another group");
        }
        if (muji_group_owner == owner) return;

        EngineMujiGroupSession? previous_owner = muji_group_owner;
        Jid? previous_room = muji_room_jid;
        bool previous_group_video_managed = muji_group_video_managed;
        bool previous_local_video_enabled = local_video_enabled;
        muji_group_owner = owner;
        muji_group_video_managed = true;
        muji_room_jid = owner.room_jid;
        video_effects_blocked_for_group_call = true;
        try {
            if (wire_session != null) {
                owner.attach_peer_wire_session(this, (!) wire_session);
            }
        } catch (Error e) {
            muji_group_owner = previous_owner;
            muji_room_jid = previous_room;
            muji_group_video_managed = previous_group_video_managed;
            local_video_enabled = previous_local_video_enabled;
            if (wire_session != null) {
                try {
                    apply_local_video_enabled((!) wire_session);
                } catch (Error rollback_error) {
                    warning(
                        "Google/libwebrtc MUJI: cannot restore direct video state " +
                        "after failed adoption sid=%s: %s (adoption failed: %s)",
                        sid, rollback_error.message, e.message);
                }
            }
            throw e;
        }
    }

    internal bool copy_initial_offer_conference_media(
            out HashMap<string, string> content_names_by_media,
            out HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
                payload_types_by_media) {
        content_names_by_media = new HashMap<string, string>();
        payload_types_by_media = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        if (wire_session == null) return false;
        return ((!) wire_session).session.engine
            .copy_initial_offer_conference_media(
                out content_names_by_media,
                out payload_types_by_media);
    }

    public override bool try_get_initial_offer_media(out bool audio, out bool video) {
        HashMap<string, string> names;
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> payloads;
        bool known = copy_initial_offer_conference_media(out names, out payloads);
        audio = known && names.has_key("audio") && payloads.has_key("audio") && !payloads["audio"].is_empty;
        video = known && names.has_key("video") && payloads.has_key("video") && !payloads["video"].is_empty;
        return known;
    }

    internal void unbind_muji_group_owner(EngineMujiGroupSession owner) {
        if (muji_group_owner == owner) muji_group_owner = null;
    }

    internal void apply_group_local_video_enabled(bool enabled) throws Error {
        local_video_enabled = enabled;
#if GOOGLE_WEBRTC_EFFECT_TEST
        if (fail_next_group_video_state_apply_for_test) {
            fail_next_group_video_state_apply_for_test = false;
            throw new EngineError.NATIVE(
                "injected MUJI adoption video-state failure");
        }
#endif
        if (wire_session == null || !video_requested) return;
        try {
            ((!) wire_session).session.engine.set_local_video_enabled(enabled);
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc MUJI: local video track state not applied yet sid=%s: %s",
                    sid, e.message);
            }
            throw e;
        }
    }

    internal void start_group_video_capture(EngineVideoDeviceInfo device) throws Error {
        if (wire_session == null || !video_requested) {
            throw new JmiError.BAD_STATE("MUJI preview publisher has no video wire session");
        }
        ((!) wire_session).session.engine.start_video_capture(device, 640, 480, 30);
    }

    internal void stop_group_video_capture() throws Error {
        if (wire_session == null || !video_requested) return;
        ((!) wire_session).session.engine.stop_video_capture();
    }

    internal bool group_video_capture_running() throws Error {
        if (wire_session == null || !video_requested) return false;
        return ((!) wire_session).session.engine.get_state().local_video_capture_running != 0;
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    internal void inject_group_video_state_apply_failure_for_test() {
        fail_next_group_video_state_apply_for_test = true;
    }

    internal void suppress_local_capture_start_for_test() {
        local_capture_start_suppressed_for_test = true;
    }

    internal void push_group_synthetic_video_frame(int width, int height) throws Error {
        if (wire_session == null || !video_requested) {
            throw new JmiError.BAD_STATE("MUJI preview publisher has no video wire session");
        }
        ((!) wire_session).session.engine.push_synthetic_video_frame(width, height);
    }

    internal EngineJingleWireSession start_muji_wire_without_offer_for_test() throws Error {
        if (!is_muji) {
            throw new JmiError.BAD_STATE("Only a MUJI peer session can start direct Jingle");
        }
        require_state(JmiState.NEW, "starting test-only MUJI wire");
        EngineJingleWireSession started = create_outgoing_wire_session(peer_jid);
        jmi_state = JmiState.PROCEED_RECEIVED;
        return started;
    }

    internal EngineVideoEffectPipelineOwner ensure_video_effect_pipeline_for_test() throws Error {
        if (!video_requested) {
            throw new IOError.NOT_SUPPORTED("Video effects require a video call");
        }
        return ensure_video_effect_pipeline();
    }

    internal void disconnect_wire_session_for_test() {
        disconnect_wire_session();
    }
#endif

    private void validate_jmi_reply(Jid from, Jid to, string incoming_sid, string label) throws JmiError {
        if (incoming_sid != sid) {
            throw new JmiError.BAD_STANZA(@"$(label) has an unexpected SID");
        }
        if (!from.equals_bare(peer_jid)) {
            throw new JmiError.BAD_STANZA(@"$(label) came from an unexpected peer");
        }
        if (!to.equals(local_full_jid)) {
            throw new JmiError.BAD_STANZA(@"$(label) was not addressed to this full JID");
        }
    }

    private void require_state(JmiState expected, string action) throws JmiError {
        if (jmi_state != expected) {
            throw new JmiError.BAD_STATE(@"Cannot perform $(action) while JMI state is $(jmi_state.to_string())");
        }
    }

    private static Gee.List<StanzaNode> build_descriptions(bool audio, bool video) throws JmiError {
        if (!audio && !video) {
            throw new JmiError.BAD_STANZA("JMI proposal must contain at least one media description");
        }
        var descriptions = new ArrayList<StanzaNode>();
        if (audio) {
            descriptions.add(new StanzaNode.build("description", JingleRtp.NS_URI)
                .add_self_xmlns()
                .put_attribute("media", "audio"));
        }
        if (video) {
            descriptions.add(new StanzaNode.build("description", JingleRtp.NS_URI)
                .add_self_xmlns()
                .put_attribute("media", "video"));
        }
        return descriptions;
    }

    private static void parse_descriptions(
            Gee.List<StanzaNode> descriptions,
            out bool audio,
            out bool video) throws JmiError {
        audio = false;
        video = false;
        foreach (StanzaNode description in descriptions) {
            if (description.name != "description" || description.ns_uri != JingleRtp.NS_URI) continue;
            string? media = description.get_attribute("media");
            if (media == "audio") {
                audio = true;
            } else if (media == "video") {
                video = true;
            }
        }
        if (!audio && !video) {
            throw new JmiError.BAD_STANZA("JMI proposal did not contain audio or video RTP descriptions");
        }
    }

    private static void validate_sid(string sid) throws JmiError {
        if (sid.strip() == "") {
            throw new JmiError.BAD_STANZA("JMI SID is missing");
        }
    }

    private static void validate_muji_addresses(
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid room_jid) throws JmiError {
        if (local_full_jid.resourcepart == null) {
            throw new JmiError.BAD_STANZA("MUJI local address must be a full JID");
        }
        if (peer_full_jid.resourcepart == null) {
            throw new JmiError.BAD_STANZA("MUJI peer address must be a full JID");
        }
        if (room_jid.resourcepart != null) {
            throw new JmiError.BAD_STANZA("MUJI room must be a bare JID");
        }
    }

    private static string jmi_state_to_debug_string(JmiState state) {
        switch (state) {
            case JmiState.NEW:
                return "new";
            case JmiState.PROPOSED:
                return "proposed";
            case JmiState.PROCEED_SENT:
                return "proceed-sent";
            case JmiState.PROCEED_RECEIVED:
                return "proceed-received";
            case JmiState.REJECTED:
                return "rejected";
            case JmiState.RETRACTED:
                return "retracted";
            case JmiState.ENDED:
                return "ended";
            default:
                assert_not_reached();
        }
    }

    private static string peer_connection_state_to_debug_string(Native.PeerConnectionState state) {
        switch (state) {
            case Native.PeerConnectionState.NEW:
                return "new";
            case Native.PeerConnectionState.CONNECTING:
                return "connecting";
            case Native.PeerConnectionState.CONNECTED:
                return "connected";
            case Native.PeerConnectionState.DISCONNECTED:
                return "disconnected";
            case Native.PeerConnectionState.FAILED:
                return "failed";
            case Native.PeerConnectionState.CLOSED:
                return "closed";
            default:
                assert_not_reached();
        }
    }

    private static string ice_connection_state_to_debug_string(Native.IceConnectionState state) {
        switch (state) {
            case Native.IceConnectionState.NEW:
                return "new";
            case Native.IceConnectionState.CHECKING:
                return "checking";
            case Native.IceConnectionState.CONNECTED:
                return "connected";
            case Native.IceConnectionState.COMPLETED:
                return "completed";
            case Native.IceConnectionState.FAILED:
                return "failed";
            case Native.IceConnectionState.DISCONNECTED:
                return "disconnected";
            case Native.IceConnectionState.CLOSED:
                return "closed";
            default:
                assert_not_reached();
        }
    }
}

}
