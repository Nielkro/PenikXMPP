using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

/**
 * Development-only bridge between the native libwebrtc session owner and the
 * XEP-0166 signaling shell.
 *
 * It proves the next boundary without registering a VideoCallPlugin, opening an
 * XmppStream or touching the production GStreamer RTP call path.
 */
public class EngineJingleSession : Object {
    private const string CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";
    private const int MAX_QUEUED_REMOTE_ICE_CANDIDATES = 128;

    public EngineSessionOwner engine { get; private set; }
    public JingleSignalingSession signaling { get; private set; }
    public SignalingState state { get { return signaling.state; } }
    public Jingle.Role local_role { get { return signaling.local_role; } }

    private ulong local_description_handler_id = 0;
    private ulong remote_description_handler_id = 0;
    private ulong local_ice_handler_id = 0;
    private ulong ice_complete_handler_id = 0;
    private ulong native_error_handler_id = 0;
    private ArrayList<JingleRtp.LibwebrtcJingleIceCandidate> queued_remote_ice =
        new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
    private bool remote_description_ready = false;
    private bool bundle_grouping_enabled = false;
    private bool closed = false;

    public signal void outgoing_jingle(StanzaNode jingle);
    public signal void outgoing_transport_info(StanzaNode jingle);
    public signal void active();
    public signal void ice_gathering_complete();
    public signal void failed(string message);

    private static bool call_debug_enabled() {
        string? enabled = Environment.get_variable(CALL_DEBUG_ENV);
        return enabled == "1" || enabled == "true" || enabled == "yes";
    }

    public EngineJingleSession.outgoing(
            EngineSessionOwner engine,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        this.engine = engine;
        this.signaling = JingleSignalingSession.outgoing(
            sid, local_full_jid, peer_full_jid);
        connect_engine_signals();
    }

    internal EngineJingleSession.muji_outgoing(
            EngineSessionOwner engine,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.engine = engine;
        this.signaling = JingleSignalingSession.muji_outgoing(
            sid, local_full_jid, peer_full_jid, muji_room_jid);
        connect_engine_signals();
    }

    internal EngineJingleSession.outgoing_with_bundle(
            EngineSessionOwner engine,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.engine = engine;
        this.bundle_grouping_enabled = true;
        this.signaling = JingleSignalingSession.muji_outgoing(
            sid, local_full_jid, peer_full_jid, muji_room_jid);
        connect_engine_signals();
    }

    public EngineJingleSession.incoming(
            EngineSessionOwner engine,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        this.engine = engine;
        this.signaling = JingleSignalingSession.incoming(
            sid, local_full_jid, peer_full_jid);
        connect_engine_signals();
    }

    internal EngineJingleSession.muji_incoming(
            EngineSessionOwner engine,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.engine = engine;
        this.signaling = JingleSignalingSession.muji_incoming(
            sid, local_full_jid, peer_full_jid, muji_room_jid);
        connect_engine_signals();
    }

    public void start_outgoing_offer() throws EngineError, SignalingError {
        require_open();
        if (local_role != Jingle.Role.INITIATOR || signaling.state != SignalingState.NEW) {
            throw new SignalingError.BAD_STATE("outgoing offer can only start from a new initiator session");
        }
        engine.create_offer();
    }

    public void handle_session_initiate(StanzaNode jingle) throws SignalingError, EngineError, Jingle.IqError {
        require_open();
        if (local_role != Jingle.Role.RESPONDER) {
            throw new SignalingError.BAD_STATE("only responder sessions can handle session-initiate");
        }
        if (signaling.muji_room_jid == null) {
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
                signaling.read_session_initiate(jingle);
            log_jingle_contents("remote-offer", contents);
            log_remote_description_bundle_policy("remote-offer");
            JingleRtp.LibwebrtcJingleDescription description =
                engine.set_remote_description_from_jingle(
                    JingleRtp.LibwebrtcSdpType.OFFER,
                    contents,
                    Jingle.Role.RESPONDER,
                    remote_description_bundle_policy());
            log_jingle_description("mapped-remote-offer", description);
            return;
        }
        JingleSignalingDescription incoming =
            signaling.read_session_initiate_with_bundle(jingle);
        bundle_grouping_enabled =
            incoming.bundle_content_names != null;
        log_jingle_contents("remote-offer", incoming.contents);
        log_muji_remote_description_bundle_policy(
            "remote-offer", incoming.bundle_content_names);
        JingleRtp.LibwebrtcJingleDescription description =
            engine.set_remote_description_from_jingle_with_bundle(
                JingleRtp.LibwebrtcSdpType.OFFER,
                incoming.contents,
                Jingle.Role.RESPONDER,
                JingleRtp.SdpBundlePolicy.NONE,
                incoming.bundle_content_names);
        log_jingle_description("mapped-remote-offer", description);
    }

    public void handle_session_accept(StanzaNode jingle) throws SignalingError, EngineError, Jingle.IqError {
        require_open();
        if (local_role != Jingle.Role.INITIATOR) {
            throw new SignalingError.BAD_STATE("only initiator sessions can handle session-accept");
        }
        if (signaling.muji_room_jid == null) {
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents =
                signaling.read_session_accept(jingle);
            log_jingle_contents("remote-answer", contents);
            log_remote_description_bundle_policy("remote-answer");
            JingleRtp.LibwebrtcJingleDescription description =
                engine.set_remote_description_from_jingle(
                    JingleRtp.LibwebrtcSdpType.ANSWER,
                    contents,
                    Jingle.Role.INITIATOR,
                    remote_description_bundle_policy());
            log_jingle_description("mapped-remote-answer", description);
            return;
        }
        JingleSignalingDescription incoming =
            signaling.read_session_accept_with_bundle(jingle);
        bundle_grouping_enabled =
            incoming.bundle_content_names != null;
        log_jingle_contents("remote-answer", incoming.contents);
        log_muji_remote_description_bundle_policy(
            "remote-answer", incoming.bundle_content_names);
        JingleRtp.LibwebrtcJingleDescription description =
            engine.set_remote_description_from_jingle_with_bundle(
                JingleRtp.LibwebrtcSdpType.ANSWER,
                incoming.contents,
                Jingle.Role.INITIATOR,
                JingleRtp.SdpBundlePolicy.NONE,
                incoming.bundle_content_names);
        log_jingle_description("mapped-remote-answer", description);
    }

    public void handle_transport_info(StanzaNode jingle) throws SignalingError, EngineError, Jingle.IqError {
        require_open();
        if (signaling.state == SignalingState.NEW) {
            throw new SignalingError.BAD_STATE(
                "transport-info cannot arrive before session-initiate");
        }
        Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> candidates = signaling.read_transport_info_candidates(jingle);
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: signaling phase=remote-transport-info sid=%s role=%s candidates=%d",
                signaling.sid,
                local_role.to_string(),
                candidates.size);
        }
        if (!remote_description_ready) {
            if (candidates.size >
                    MAX_QUEUED_REMOTE_ICE_CANDIDATES - queued_remote_ice.size) {
                throw new SignalingError.BAD_STANZA(
                    "too many ICE candidates arrived before the remote description was ready");
            }
            queued_remote_ice.add_all(candidates);
            if (call_debug_enabled() && candidates.size > 0) {
                message(
                    "Google/libwebrtc call: signaling phase=remote-candidate-queued sid=%s role=%s queued=%d",
                    signaling.sid,
                    local_role.to_string(),
                    queued_remote_ice.size);
            }
            return;
        }
        apply_remote_ice_candidates(candidates);
    }

    private void apply_remote_ice_candidates(
            Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> candidates)
            throws EngineError, Jingle.IqError {
        foreach (JingleRtp.LibwebrtcJingleIceCandidate candidate in candidates) {
            JingleRtp.LibwebrtcRemoteIceCandidate mapped =
                engine.add_remote_jingle_candidate(candidate.content_name, candidate.jingle_candidate);
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: signaling phase=remote-candidate sid=%s role=%s content=%s mid=%s mline=%d ice=%s",
                    signaling.sid,
                    local_role.to_string(),
                    candidate.content_name,
                    mapped.sdp_mid,
                    mapped.sdp_mline_index,
                    candidate_to_log(candidate.jingle_candidate));
            }
        }
    }

    public void handle_session_terminate(StanzaNode jingle) throws SignalingError {
        require_open();
        signaling.read_session_terminate(jingle);
        close();
    }

    public StanzaNode terminate(string? reason_name = null, string? reason_text = null) throws SignalingError {
        StanzaNode jingle = signaling.build_session_terminate(reason_name, reason_text);
        close();
        return jingle;
    }

    public void close() {
        if (closed) return;
        closed = true;
        queued_remote_ice.clear();
        disconnect_engine_signals();
        engine.close();
    }

    ~EngineJingleSession() {
        close();
    }

    private void connect_engine_signals() {
        local_description_handler_id = engine.local_description_ready.connect(on_local_description_ready);
        remote_description_handler_id = engine.remote_description_set.connect(on_remote_description_set);
        local_ice_handler_id = engine.local_ice_candidate.connect(on_local_ice_candidate);
        ice_complete_handler_id = engine.ice_gathering_complete.connect(() => {
            ice_gathering_complete();
        });
        native_error_handler_id = engine.native_error.connect((status, message) => {
            failed(@"$(status.to_log_string()): $(message)");
        });
    }

    private void disconnect_engine_signals() {
        if (local_description_handler_id != 0) {
            engine.disconnect(local_description_handler_id);
            local_description_handler_id = 0;
        }
        if (remote_description_handler_id != 0) {
            engine.disconnect(remote_description_handler_id);
            remote_description_handler_id = 0;
        }
        if (local_ice_handler_id != 0) {
            engine.disconnect(local_ice_handler_id);
            local_ice_handler_id = 0;
        }
        if (ice_complete_handler_id != 0) {
            engine.disconnect(ice_complete_handler_id);
            ice_complete_handler_id = 0;
        }
        if (native_error_handler_id != 0) {
            engine.disconnect(native_error_handler_id);
            native_error_handler_id = 0;
        }
    }

    private void on_local_description_ready(JingleRtp.LibwebrtcJingleDescription description) {
        if (closed) return;
        try {
            if (description.sdp_type == JingleRtp.LibwebrtcSdpType.OFFER) {
                if (local_role != Jingle.Role.INITIATOR) {
                    throw new SignalingError.BAD_STATE("responder produced an unexpected local offer");
                }
                log_jingle_description("local-offer", description);
                if (signaling.muji_room_jid == null ||
                        !bundle_grouping_enabled) {
                    outgoing_jingle(
                        signaling.build_session_initiate(description));
                } else {
                    outgoing_jingle(
                        signaling.build_session_initiate_with_bundle(
                            description));
                }
                drain_local_ice();
                return;
            }

            if (description.sdp_type == JingleRtp.LibwebrtcSdpType.ANSWER) {
                if (local_role != Jingle.Role.RESPONDER) {
                    throw new SignalingError.BAD_STATE("initiator produced an unexpected local answer");
                }
                log_jingle_description("local-answer", description);
                if (signaling.muji_room_jid == null) {
                    outgoing_jingle(
                        signaling.build_session_accept(description));
                } else {
                    outgoing_jingle(
                        signaling.build_session_accept_with_bundle(
                            description));
                }
                active();
                drain_local_ice();
                return;
            }

            throw new SignalingError.BAD_STANZA("unsupported local SDP type");
        } catch (Error e) {
            failed(e.message);
        }
    }

    private void on_remote_description_set(JingleRtp.LibwebrtcSdpType type) {
        if (closed) return;
        try {
            signaling.mark_remote_description_set(type);
            remote_description_ready = true;
            drain_remote_ice();
            if (type == JingleRtp.LibwebrtcSdpType.OFFER) {
                if (local_role != Jingle.Role.RESPONDER) {
                    throw new SignalingError.BAD_STATE("initiator received a remote offer in this proof path");
                }
                engine.create_answer();
                return;
            }

            if (type == JingleRtp.LibwebrtcSdpType.ANSWER) {
                active();
                drain_local_ice();
            }
        } catch (Error e) {
            failed(e.message);
        }
    }

    private void drain_remote_ice() throws EngineError, Jingle.IqError {
        if (queued_remote_ice.is_empty) return;
        var pending = new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
        pending.add_all(queued_remote_ice);
        queued_remote_ice.clear();
        apply_remote_ice_candidates(pending);
    }

    private void on_local_ice_candidate(JingleRtp.LibwebrtcJingleIceCandidate candidate) {
        if (closed) return;
        try {
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: signaling phase=local-candidate sid=%s role=%s content=%s mid=%s mline=%d ice=%s",
                    signaling.sid,
                    local_role.to_string(),
                    candidate.content_name,
                    candidate.sdp_mid,
                    candidate.sdp_mline_index,
                    candidate_to_log(candidate.jingle_candidate));
            }
            signaling.queue_local_ice_candidate(candidate);
            drain_local_ice();
        } catch (SignalingError e) {
            failed(e.message);
        }
    }

    private void drain_local_ice() throws SignalingError {
        foreach (StanzaNode transport_info in signaling.drain_local_ice_transport_info()) {
            outgoing_transport_info(transport_info);
        }
    }

    private JingleRtp.SdpBundlePolicy remote_description_bundle_policy() {
        return engine.max_bundle_transport_policy
            ? JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS
            : JingleRtp.SdpBundlePolicy.NONE;
    }

    private void log_remote_description_bundle_policy(string phase) {
        if (!call_debug_enabled()) return;
        message(
            "Google/libwebrtc call: signaling phase=%s sid=%s role=%s remote-sdp-bundle-policy=%s",
            phase,
            signaling.sid,
            local_role.to_string(),
            engine.max_bundle_transport_policy ? "all-media-sections" : "none");
    }

    private void log_muji_remote_description_bundle_policy(
            string phase,
            Gee.List<string>? bundle_content_names) {
        if (!call_debug_enabled()) return;
        message(
            "Google/libwebrtc call: signaling phase=%s sid=%s role=%s remote-sdp-bundle-policy=%s",
            phase,
            signaling.sid,
            local_role.to_string(),
            bundle_content_names != null
                ? "wire-bundle-group"
                : "none");
    }

    private void log_jingle_description(string phase, JingleRtp.LibwebrtcJingleDescription description) {
        if (!call_debug_enabled()) return;

        log_jingle_contents(phase, description.contents);
        for (int i = 0; i < description.session.media_sections.size; i++) {
            JingleRtp.SdpMediaSection section = description.session.media_sections[i];
            message(
                "Google/libwebrtc call: signaling phase=%s sid=%s role=%s mline=%d mid=%s media=%s direction=%s hdrext=%d[%s] extmap-mixed=%s",
                phase,
                signaling.sid,
                local_role.to_string(),
                i,
                section.mid ?? "(none)",
                section.media,
                section.direction != null ? ((!) section.direction).to_sdp() : "sendrecv-default",
                section.header_extensions.size,
                media_header_extensions_to_log(section),
                section.extmap_allow_mixed ? "yes" : "no");
            log_media_payload(phase, i, section);
        }
    }

    private static string media_header_extensions_to_log(JingleRtp.SdpMediaSection section) {
        var parts = new ArrayList<string>();
        foreach (JingleRtp.SdpHeaderExtension extension in section.header_extensions) {
            parts.add(
                "%u/%s:%s".printf(
                    extension.id,
                    extension.direction.to_sdp(),
                    extension.uri));
        }
        if (parts.is_empty) return "-";

        var builder = new StringBuilder();
        bool first = true;
        foreach (string part in parts) {
            if (!first) builder.append(",");
            first = false;
            builder.append(part);
        }
        return builder.str;
    }

    private void log_media_payload(string phase, int mline, JingleRtp.SdpMediaSection section) {
        if (section.payload_types.is_empty) return;

        // SDP preference order is not proof of the active RTP codec. Report
        // the actual first entry rather than searching for our preferred name.
        JingleRtp.PayloadType payload_type = section.payload_types[0];
        message(
            "Google/libwebrtc call: signaling phase=%s sid=%s role=%s mline=%d first-payload=%u codec=%s/%u/%u params=%s rtcpfb=%d payloads=%d[%s]",
            phase,
            signaling.sid,
            local_role.to_string(),
            mline,
            payload_type.id,
            payload_type.name ?? "(none)",
            payload_type.clockrate,
            payload_type.channels,
            payload_parameters_to_log(payload_type),
            payload_type.rtcp_fbs.size,
            section.payload_types.size,
            media_payloads_to_log(section));
    }

    private static string media_payloads_to_log(JingleRtp.SdpMediaSection section) {
        var parts = new ArrayList<string>();
        foreach (JingleRtp.PayloadType payload_type in section.payload_types) {
            parts.add(
                "%u:%s/%u/%u{%s}".printf(
                    payload_type.id,
                    payload_type.name ?? "(none)",
                    payload_type.clockrate,
                    payload_type.channels,
                    payload_parameters_to_log(payload_type)));
        }
        if (parts.is_empty) return "-";

        var builder = new StringBuilder();
        bool first = true;
        foreach (string part in parts) {
            if (!first) builder.append(",");
            first = false;
            builder.append(part);
        }
        return builder.str;
    }

    private static string payload_parameters_to_log(JingleRtp.PayloadType payload_type) {
        var parts = new ArrayList<string>();
        if (payload_type.ptime != 0) parts.add(@"ptime=$(payload_type.ptime)");
        if (payload_type.maxptime != 0) parts.add(@"maxptime=$(payload_type.maxptime)");
        foreach (string key in payload_type.parameters.keys) {
            parts.add(@"$(key)=$(payload_type.parameters[key])");
        }
        parts.sort((left, right) => strcmp(left, right));
        if (parts.is_empty) return "-";

        var builder = new StringBuilder();
        bool first = true;
        foreach (string part in parts) {
            if (!first) builder.append(";");
            first = false;
            builder.append(part);
        }
        return builder.str;
    }

    private static string candidate_to_log(JingleIceUdp.Candidate candidate) {
        return "%s/%s/%s:%s rel=%s:%s prio=%s".printf(
            candidate.type_.to_string(),
            candidate.protocol,
            candidate.ip,
            candidate.port.to_string(),
            candidate.rel_addr ?? "-",
            candidate.rel_port != 0 ? candidate.rel_port.to_string() : "-",
            candidate.priority.to_string());
    }

    private void log_jingle_contents(string phase, Gee.List<JingleRtp.LibwebrtcJingleContent> contents) {
        if (!call_debug_enabled()) return;

        for (int i = 0; i < contents.size; i++) {
            JingleRtp.LibwebrtcJingleContent content = contents[i];
            Gee.List<StanzaNode> header_extensions = content.description.get_subnodes(
                JingleRtp.HeaderExtension.NAME,
                JingleRtp.HeaderExtension.NS_URI);
            message(
                "Google/libwebrtc call: signaling phase=%s sid=%s role=%s content=%d name=%s media=%s senders=%s hdrext=%d[%s] extmap-mixed=%s",
                phase,
                signaling.sid,
                local_role.to_string(),
                i,
                content.content_name,
                content.description.get_attribute("media") ?? "(none)",
                content.senders.to_string(),
                header_extensions.size,
                jingle_header_extensions_to_log(header_extensions),
                content.description.get_subnode(
                    "extmap-allow-mixed", JingleRtp.HeaderExtension.NS_URI) != null ? "yes" : "no");
        }
    }

    private static string jingle_header_extensions_to_log(Gee.List<StanzaNode> extensions) {
        if (extensions.is_empty) return "-";

        var builder = new StringBuilder();
        bool first = true;
        foreach (StanzaNode extension in extensions) {
            if (!first) builder.append(",");
            first = false;
            builder.append_printf(
                "%s/%s:%s",
                extension.get_attribute("id") ?? "?",
                extension.get_attribute("senders") ?? "both",
                extension.get_attribute("uri") ?? "?");
        }
        return builder.str;
    }

    private void require_open() throws SignalingError {
        if (closed || signaling.state == SignalingState.ENDED) {
            throw new SignalingError.ENDED("engine Jingle session has ended");
        }
    }
}

}
