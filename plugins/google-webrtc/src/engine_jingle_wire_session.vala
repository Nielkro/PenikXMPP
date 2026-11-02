using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

public errordomain WireError {
    BAD_STATE,
    BAD_STANZA
}

public interface EngineJingleWireTransport : Object {
    public signal void jingle_iq_error(
        Jid to, StanzaNode request_jingle, Iq.Stanza response_iq);

    public abstract void send_jingle_iq(Jid to, StanzaNode jingle);
    public abstract void send_result_iq(Iq.Stanza request_iq);
    public abstract void send_error_iq(Iq.Stanza request_iq, ErrorStanza error);
}

/** Optional lifetime boundary for transports which prepare IQs asynchronously. */
public interface EngineCancellableJingleWireTransport : Object {
    public abstract void cancel_pending_iqs(Jid peer_full_jid, string sid);
}

/**
 * XMPP IQ transport for production Google/libwebrtc Jingle sessions.
 * The shared IQ pipeline prepares security data before the request is written.
 */
public class XmppEngineJingleWireTransport : Object, EngineJingleWireTransport,
        EngineCancellableJingleWireTransport {
    internal const int MAX_QUEUED_TRANSPORT_INFOS = 128;

    private class PendingSession : Object {
        public Cancellable cancellable = new Cancellable();
        public string? setup_iq_id = null;
        public bool setup_acknowledged = false;
        public Gee.ArrayList<StanzaNode> transport_infos =
            new Gee.ArrayList<StanzaNode>();
    }

    private XmppStream stream;
    private Gee.HashMap<string, Gee.HashMap<string, PendingSession>> pending_sessions =
        new Gee.HashMap<string, Gee.HashMap<string, PendingSession>>();

    public XmppEngineJingleWireTransport(XmppStream stream) {
        this.stream = stream;
    }

    public void send_jingle_iq(Jid to, StanzaNode jingle) {
        string? sid = jingle.get_attribute("sid");
        // The final termination must remain sendable after the pending offer,
        // answer and ICE preparation belonging to this session is cancelled.
        PendingSession? pending = sid != null &&
                jingle.get_attribute("action") != "session-terminate"
            ? get_pending_session(to, (!) sid) : null;
        if (pending != null && jingle.get_attribute("action") == "transport-info" &&
                !((!) pending).setup_acknowledged) {
            if (((!) pending).cancellable.is_cancelled()) return;
            if (((!) pending).transport_infos.size >= MAX_QUEUED_TRANSPORT_INFOS) {
                var request = new Iq.Stanza.set(jingle) { to=to };
                cancel_pending_iqs(to, (!) sid);
                jingle_iq_error(to, jingle, Iq.Module.local_failure(request));
                return;
            }
            ((!) pending).transport_infos.add(jingle);
            return;
        }
        send_prepared_iq(to, jingle, pending);
    }

    private void send_prepared_iq(Jid to, StanzaNode jingle, PendingSession? pending) {
        Iq.Stanza iq = new Iq.Stanza.set(jingle) { to=to };
        string? sid = jingle.get_attribute("sid");
        string? action = jingle.get_attribute("action");
        bool setup = action == "session-initiate" || action == "session-accept";
        if (pending != null && setup) {
            ((!) pending).setup_iq_id = iq.id;
            ((!) pending).setup_acknowledged = false;
        }
        Cancellable? cancellable = pending != null && sid != null
            ? get_session_cancellable(to, (!) sid) : null;
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, iq, (stream, response_iq) => {
            // Both success and failure belong to this exact session lifetime.
            // A late reply must not drain or retire a replacement with the
            // same SID, nor another account or resource's call.
            if (pending != null && (sid == null ||
                    !is_current_session(to, (!) sid, (!) pending))) return;
            if (response_iq.is_error()) {
                // Closing a leg deliberately cancels its queued IQs. Their
                // callbacks must not report a new call failure after hangup.
                if (response_iq.locally_failed && cancellable != null && cancellable.is_cancelled()) return;
                if (setup && sid != null) cancel_pending_iqs(to, (!) sid);
                if (EngineJingleWireSession.is_transport_info_response_timeout(jingle, response_iq)) {
                    // A missing IQ acknowledgement is not an ICE failure;
                    // native ICE reports actual connection failures separately.
                    debug("Google/libwebrtc ICE candidate IQ was sent but no matching response arrived before timeout: sid=%s to=%s iq_id=%s; native ICE determines call connectivity",
                        sid ?? "(missing)", to.to_string(), iq.id);
                } else {
                    warning(
                        "Google/libwebrtc Jingle IQ got error: action=%s sid=%s to=%s local=%s phase=%s code=%d response=%s",
                        jingle.get_attribute("action") ?? "(missing)",
                        jingle.get_attribute("sid") ?? "(missing)",
                        to.to_string(),
                        response_iq.locally_failed.to_string(),
                        response_iq.local_failure_phase.to_string(),
                        response_iq.local_failure_code,
                        response_iq.stanza.to_string());
                }
                jingle_iq_error(to, jingle, response_iq);
            } else if (pending != null && setup &&
                    ((!) pending).setup_iq_id == iq.id) {
                // send_iq starts asynchronous security preparation. Emitting
                // the offer is not proof it was written: fingerprint setup may
                // await an OMEMO bundle while fingerprintless ICE is ready.
                // A real setup ACK is a conservative dispatch/ownership gate.
                ((!) pending).setup_acknowledged = true;
                while (is_current_session(to, (!) sid, (!) pending) &&
                        !((!) pending).transport_infos.is_empty) {
                    StanzaNode next = ((!) pending).transport_infos.remove_at(0);
                    send_prepared_iq(to, next, pending);
                }
            }
        }, Priority.DEFAULT, cancellable);
    }

    internal Cancellable get_session_cancellable(Jid peer_full_jid, string sid) {
        return get_pending_session(peer_full_jid, sid).cancellable;
    }

    private PendingSession get_pending_session(Jid peer_full_jid, string sid) {
        string peer_key = peer_full_jid.to_string();
        Gee.HashMap<string, PendingSession>? peer_sessions = pending_sessions[peer_key];
        if (peer_sessions == null) {
            peer_sessions = new Gee.HashMap<string, PendingSession>();
            pending_sessions[peer_key] = (!) peer_sessions;
        }
        PendingSession? pending = ((!) peer_sessions)[sid];
        if (pending == null) {
            pending = new PendingSession();
            ((!) peer_sessions)[sid] = (!) pending;
        }
        return (!) pending;
    }

    private bool is_current_session(Jid peer_full_jid, string sid, PendingSession pending) {
        Gee.HashMap<string, PendingSession>? peer_sessions =
            pending_sessions[peer_full_jid.to_string()];
        return peer_sessions != null && ((!) peer_sessions)[sid] == pending &&
            !pending.cancellable.is_cancelled();
    }

    public void cancel_pending_iqs(Jid peer_full_jid, string sid) {
        string peer_key = peer_full_jid.to_string();
        Gee.HashMap<string, PendingSession>? peer_sessions = pending_sessions[peer_key];
        if (peer_sessions == null) return;
        PendingSession? pending = ((!) peer_sessions)[sid];
        ((!) peer_sessions).unset(sid);
        if (((!) peer_sessions).is_empty) {
            pending_sessions.unset(peer_key);
        }
        // Remove before emitting cancellation: error delivery may close its
        // owner synchronously, without invalidating another peer's token.
        if (pending != null) {
            ((!) pending).transport_infos.clear();
            ((!) pending).cancellable.cancel();
        }
    }

    public void send_result_iq(Iq.Stanza request_iq) {
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, new Iq.Stanza.result(request_iq));
    }

    public void send_error_iq(Iq.Stanza request_iq, ErrorStanza error) {
        stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(
            stream,
            new Iq.Stanza.error(request_iq, error) { to=request_iq.from });
    }
}

/**
 * Per-peer IQ wire owner around EngineJingleSession.
 *
 * It maps outgoing engine/signaling payloads to real IQ set stanzas and maps
 * incoming IQ set stanzas back into the engine. It intentionally does not
 * register with Xep.Jingle.Module, does not create Xep.Jingle.Session objects,
 * does not expose UI and owns only explicitly registered libwebrtc SIDs.
 */
public class EngineJingleWireSession : Object {
    public EngineJingleSession session { get; private set; }
    public EngineJingleWireTransport transport { get; private set; }
    public Jid local_full_jid { get { return session.signaling.local_full_jid; } }
    public Jid peer_full_jid { get { return session.signaling.peer_full_jid; } }
    public Jid? muji_room_jid { get { return session.signaling.muji_room_jid; } }
    public string sid { get { return session.signaling.sid; } }
    public SignalingState state { get { return session.state; } }

    private ulong outgoing_jingle_handler_id = 0;
    private ulong outgoing_transport_info_handler_id = 0;
    private ulong active_handler_id = 0;
    private ulong failed_handler_id = 0;
    private ulong transport_iq_error_handler_id = 0;
    private bool closed = false;

    public signal void active();
    public signal void failed(string message);
    public signal void remote_terminated(string? reason_name, string? reason_text);

    public EngineJingleWireSession.outgoing(
            EngineSessionOwner engine,
            EngineJingleWireTransport transport,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        this.transport = transport;
        this.session = new EngineJingleSession.outgoing(
            engine, sid, local_full_jid, peer_full_jid);
        connect_session_signals();
    }

    internal EngineJingleWireSession.muji_outgoing(
            EngineSessionOwner engine,
            EngineJingleWireTransport transport,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.transport = transport;
        this.session = new EngineJingleSession.muji_outgoing(
            engine, sid, local_full_jid, peer_full_jid, muji_room_jid);
        connect_session_signals();
    }

    internal EngineJingleWireSession.outgoing_with_bundle(
            EngineSessionOwner engine,
            EngineJingleWireTransport transport,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.transport = transport;
        this.session = new EngineJingleSession.outgoing_with_bundle(
            engine,
            sid,
            local_full_jid,
            peer_full_jid,
            muji_room_jid);
        connect_session_signals();
    }

    public EngineJingleWireSession.incoming(
            EngineSessionOwner engine,
            EngineJingleWireTransport transport,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid) throws SignalingError {
        this.transport = transport;
        this.session = new EngineJingleSession.incoming(
            engine, sid, local_full_jid, peer_full_jid);
        connect_session_signals();
    }

    internal EngineJingleWireSession.muji_incoming(
            EngineSessionOwner engine,
            EngineJingleWireTransport transport,
            string sid,
            Jid local_full_jid,
            Jid peer_full_jid,
            Jid muji_room_jid) throws SignalingError {
        this.transport = transport;
        this.session = new EngineJingleSession.muji_incoming(
            engine, sid, local_full_jid, peer_full_jid, muji_room_jid);
        connect_session_signals();
    }

    public void start_outgoing_offer() throws EngineError, SignalingError, WireError {
        require_open();
        session.start_outgoing_offer();
    }

    public void handle_iq_set(Iq.Stanza iq) throws Error {
        require_open();
        try {
            StanzaNode jingle = get_jingle_node(iq);
            validate_peer(iq);
            validate_sid(jingle);

            string? action = jingle.get_attribute("action");
            require_token(action, "Jingle action");
            log_muji_setup_action("received", jingle);

            switch ((!) action) {
                case "session-initiate":
                    session.handle_session_initiate(jingle);
                    break;
                case "session-accept":
                    session.handle_session_accept(jingle);
                    break;
                case "transport-info":
                    session.handle_transport_info(jingle);
                    break;
                case "session-terminate": {
                    string? reason_name = null;
                    string? reason_text = null;
                    handle_session_terminate(jingle, out reason_name, out reason_text);
                    // ACK while this wire session and its transport still have
                    // a strong owner. The remote_terminated signal releases the
                    // plugin session synchronously and may otherwise destroy
                    // this object before the result IQ is sent.
                    transport.send_result_iq(iq);
                    remote_terminated(reason_name, reason_text);
                    return;
                }
                default:
                    throw new WireError.BAD_STANZA(@"unsupported Jingle action '$((!) action)' for the libwebrtc session");
            }

            transport.send_result_iq(iq);
        } catch (Error e) {
            send_error_if_addressable(iq, e);
            throw e;
        }
    }

    public void terminate(string? reason_name = null, string? reason_text = null) throws SignalingError {
        if (closed) return;
        SignalingState previous_state = state;
        StanzaNode terminate_jingle = session.terminate(reason_name, reason_text);
        log_muji_setup_action("sent", terminate_jingle, previous_state);
        close();
        transport.send_jingle_iq(peer_full_jid, terminate_jingle);
    }

    public void close() {
        if (closed) return;
        closed = true;
        disconnect_session_signals();
        EngineCancellableJingleWireTransport? cancellable_transport =
            transport as EngineCancellableJingleWireTransport;
        if (cancellable_transport != null) {
            ((!) cancellable_transport).cancel_pending_iqs(peer_full_jid, sid);
        }
        session.close();
    }

    ~EngineJingleWireSession() {
        close();
    }

    private void connect_session_signals() {
        transport_iq_error_handler_id = transport.jingle_iq_error.connect(
            (to, request_jingle, response_iq) => {
                handle_outgoing_iq_error(to, request_jingle, response_iq);
            });
        outgoing_jingle_handler_id = session.outgoing_jingle.connect((jingle) => {
            log_muji_setup_action("sent", jingle);
            transport.send_jingle_iq(peer_full_jid, jingle);
        });
        outgoing_transport_info_handler_id = session.outgoing_transport_info.connect((jingle) => {
            transport.send_jingle_iq(peer_full_jid, jingle);
        });
        active_handler_id = session.active.connect(() => {
            active();
        });
        failed_handler_id = session.failed.connect((message) => {
            failed(message);
        });
    }

    private void disconnect_session_signals() {
        if (transport_iq_error_handler_id != 0 &&
                SignalHandler.is_connected(
                    transport, transport_iq_error_handler_id)) {
            transport.disconnect(transport_iq_error_handler_id);
            transport_iq_error_handler_id = 0;
        }
        if (outgoing_jingle_handler_id != 0) {
            session.disconnect(outgoing_jingle_handler_id);
            outgoing_jingle_handler_id = 0;
        }
        if (outgoing_transport_info_handler_id != 0) {
            session.disconnect(outgoing_transport_info_handler_id);
            outgoing_transport_info_handler_id = 0;
        }
        if (active_handler_id != 0) {
            session.disconnect(active_handler_id);
            active_handler_id = 0;
        }
        if (failed_handler_id != 0) {
            session.disconnect(failed_handler_id);
            failed_handler_id = 0;
        }
    }

    private void log_muji_setup_action(string direction, StanzaNode jingle,
            SignalingState? previous_state = null) {
        if (muji_room_jid == null) return;
        string? enabled = Environment.get_variable("DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
        if (enabled != "1" && enabled != "true" && enabled != "yes") return;
        string? action = jingle.get_attribute("action");
        if (action != "session-initiate" && action != "session-accept" &&
                action != "session-terminate") return;

        // Include the original payload and termination reason while the wire
        // owner is still alive. A later error for our termination IQ alone
        // cannot explain a peer's earlier setup rejection.
        message(
            "Google/libwebrtc MUJI signaling: direction=%s action=%s sid=%s local=%s peer=%s room=%s state=%s stanza=%s",
            direction, (!) action, sid, local_full_jid.to_string(),
            peer_full_jid.to_string(), ((!) muji_room_jid).to_string(),
            previous_state != null ? ((!) previous_state).to_string() : state.to_string(),
            jingle.to_string());
    }

    internal static bool is_transport_info_response_timeout(
            StanzaNode request_jingle, Iq.Stanza response_iq) {
        return response_iq.locally_failed &&
            request_jingle.get_attribute("action") == "transport-info" &&
            response_iq.local_failure_phase == Iq.LocalFailurePhase.AWAIT_RESPONSE &&
            response_iq.local_failure_code == (int) IOError.TIMED_OUT;
    }

    private void handle_outgoing_iq_error(
            Jid to, StanzaNode request_jingle, Iq.Stanza response_iq) {
        if (closed || !to.equals(peer_full_jid)) return;
        string? request_sid = request_jingle.get_attribute("sid");
        string? action = request_jingle.get_attribute("action");
        if (request_sid == null || request_sid != sid || action == null) {
            return;
        }

        // A written ICE candidate can work even if its IQ result is lost.
        // Let native ICE determine connectivity; preparation/write failures
        // and setup timeouts still fail closed below.
        if (is_transport_info_response_timeout(request_jingle, response_iq)) {
            debug("Google/libwebrtc ICE candidate IQ was written but not acknowledged: sid=%s peer=%s",
                sid, peer_full_jid.to_string());
            return;
        }

        bool setup_action = action == "session-initiate" ||
            action == "session-accept";
        StanzaNode? error_node = response_iq.stanza.get_subnode("error");
        bool unknown_session = error_node != null &&
            ((!) error_node).get_subnode(
                "unknown-session", "urn:xmpp:jingle:errors:1") != null;
        if (!response_iq.locally_failed && !setup_action && !unknown_session) return;

        ErrorStanza? stanza_error = ErrorStanza.from_stanza(
            response_iq.stanza);
        string condition = stanza_error != null
            ? ((!) stanza_error).condition
            : "undefined-condition";
        bool security_failure = response_iq.locally_failed &&
            response_iq.local_failure_phase == Iq.LocalFailurePhase.PREPARE &&
            response_iq.local_failure_code == (int) IOError.PERMISSION_DENIED;
        string message = response_iq.locally_failed
            ? GLib.dgettext("dino", security_failure
                ? "Could not establish a secure connection" : "Connection failed")
            : @"Jingle $(action) failed: $(condition)";
        close();
        failed(message);
    }

    private StanzaNode get_jingle_node(Iq.Stanza iq) throws WireError {
        if (iq.type_ != Iq.Stanza.TYPE_SET) {
            throw new WireError.BAD_STANZA("expected IQ set for Jingle action");
        }
        StanzaNode? jingle = iq.stanza.get_subnode("jingle", Jingle.NS_URI);
        if (jingle == null) {
            throw new WireError.BAD_STANZA("missing Jingle node");
        }
        return (!) jingle;
    }

    private void validate_peer(Iq.Stanza iq) throws WireError {
        Jid? from = iq.from;
        if (from == null || !((!) from).equals(peer_full_jid)) {
            throw new WireError.BAD_STANZA("Jingle IQ came from an unexpected peer");
        }
    }

    private void validate_sid(StanzaNode jingle) throws WireError {
        string? incoming_sid = jingle.get_attribute("sid");
        if (incoming_sid == null || incoming_sid != sid) {
            throw new WireError.BAD_STANZA("Jingle IQ has an unexpected SID");
        }
    }

    private void handle_session_terminate(
            StanzaNode jingle,
            out string? reason_name,
            out string? reason_text) throws SignalingError {
        reason_name = null;
        reason_text = null;
        StanzaNode? reason = jingle.get_subnode("reason", Jingle.NS_URI);
        if (reason != null) {
            foreach (StanzaNode node in ((!) reason).sub_nodes) {
                if (node.name == "text" && node.ns_uri == Jingle.NS_URI) {
                    reason_text = node.get_string_content();
                } else if (node.ns_uri == Jingle.NS_URI) {
                    reason_name = node.name;
                }
            }
        }
        session.handle_session_terminate(jingle);
        close();
    }

    internal static ErrorStanza build_error_stanza(Error error) {
        if (error is Jingle.IqError.OUT_OF_ORDER ||
                error is SignalingError.BAD_STATE) {
            StanzaNode out_of_order = new StanzaNode.build(
                "out-of-order", "urn:xmpp:jingle:errors:1").add_self_xmlns();
            return new ErrorStanza.build(ErrorStanza.TYPE_MODIFY,
                ErrorStanza.CONDITION_UNEXPECTED_REQUEST,
                error.message, out_of_order);
        }
        return new ErrorStanza.bad_request(error.message);
    }

    private void send_error_if_addressable(Iq.Stanza iq, Error error) {
        if (iq.from == null) {
            warning("Cannot send Google/libwebrtc Jingle error IQ without a sender address: %s", error.message);
            return;
        }
        transport.send_error_iq(iq, build_error_stanza(error));
    }

    private void require_open() throws WireError {
        if (closed || state == SignalingState.ENDED) {
            throw new WireError.BAD_STATE("engine Jingle wire session has ended");
        }
    }

    private static void require_token(string? token, string label) throws WireError {
        if (token == null || ((!) token).strip() == "") {
            throw new WireError.BAD_STANZA(@"$(label) is missing");
        }
    }
}

}
