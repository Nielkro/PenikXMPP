using Dino.Entities;
using Gee;
using Xmpp;

public class Dino.PeerState : Object {
    private const string GOOGLE_WEBRTC_CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";

    public signal void stream_created(string media);
    public signal void counterpart_sends_video_updated(bool mute);
    public signal void info_received(Xep.JingleRtp.CallSessionInfo session_info);

    public signal void connection_ready();
    public signal void session_terminated(bool we_terminated, string? reason_name, string? reason_text);
    public signal void encryption_updated(Xep.Jingle.ContentEncryption? audio_encryption, Xep.Jingle.ContentEncryption? video_encryption);
    public signal void google_webrtc_jmi_remote_video_frame(Plugins.JmiCallVideoFrame frame);
    public signal void google_webrtc_jmi_local_video_frame(Plugins.JmiCallVideoFrame frame);
    public signal void google_webrtc_jmi_video_effect_status_changed(Plugins.JmiVideoEffectStatus status);

    public StreamInteractor stream_interactor;
    public CallState call_state;
    public Calls calls;
    public Call call;
    public Jid jid;
    public Xep.Jingle.Session session;
    public string sid;
    public string internal_id = Xmpp.random_uuid();

    public Xep.JingleRtp.Parameters? audio_content_parameter = null;
    public Xep.JingleRtp.Parameters? video_content_parameter = null;
    public Xep.Jingle.Content? audio_content = null;
    public Xep.Jingle.Content? video_content = null;
    public Xep.Jingle.ContentEncryption? video_encryption = null;
    public Xep.Jingle.ContentEncryption? audio_encryption = null;
    public bool encryption_keys_same = false;
    public HashMap<string, Xep.Jingle.ContentEncryption>? video_encryptions = null;
    public HashMap<string, Xep.Jingle.ContentEncryption>? audio_encryptions = null;

    public bool first_peer = false;
    public bool waiting_for_inbound_muji_connection = false;
    public Xep.Muji.GroupCall? group_call { get; set; }

    // Signal handler IDs for singleton session_info_type (must be disconnected to prevent leak)
    private ulong session_info_mute_handler_id = 0;
    private ulong session_info_info_handler_id = 0;
    private Xep.JingleRtp.SessionInfoType? connected_session_info_type = null;

    // Signal handler IDs for session signals (set_session)
    private ulong session_terminated_handler_id = 0;
    private ulong session_content_add_handler_id = 0;

    // Signal handler IDs for content/RTP signals (connect_content_signals)
    private ulong audio_stream_created_handler_id = 0;
    private ulong audio_connection_ready_handler_id = 0;
    private ulong audio_senders_modify_handler_id = 0;
    private ulong video_stream_created_handler_id = 0;
    private ulong video_connection_ready_handler_id = 0;
    private ulong video_senders_modify_handler_id = 0;
    // Extra handler from on_stream_created()
    private ulong video_connection_ready_extra_handler_id = 0;
    private Plugins.JmiCallEngineSession? google_webrtc_jmi_call_engine_session = null;
    private ulong google_webrtc_jmi_active_handler_id = 0;
    private ulong google_webrtc_jmi_media_ready_handler_id = 0;
    private ulong google_webrtc_jmi_failed_handler_id = 0;
    private ulong google_webrtc_jmi_remote_terminated_handler_id = 0;
    private ulong google_webrtc_jmi_remote_video_frame_handler_id = 0;
    private ulong google_webrtc_jmi_local_video_frame_handler_id = 0;
    private ulong google_webrtc_jmi_video_effect_status_handler_id = 0;
    private uint64 google_webrtc_jmi_session_generation = 0;
    private bool google_webrtc_jmi_connection_ready_emitted = false;

    public bool counterpart_sends_video = false;
    public bool we_should_send_audio { get; set; default=false; }
    public bool we_should_send_video { get; set; default=false; }

    private static bool google_webrtc_call_debug_enabled() {
        string? enabled = Environment.get_variable(GOOGLE_WEBRTC_CALL_DEBUG_ENV);
        return enabled == "1" || enabled == "true" || enabled == "yes";
    }

    public PeerState(Jid jid, Call call, CallState call_state, StreamInteractor stream_interactor) {
        this.jid = jid;
        this.call = call;
        this.call_state = call_state;
        this.stream_interactor = stream_interactor;
        this.calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);

        Xep.JingleRtp.Module jinglertp_module = stream_interactor.module_manager.get_module<Xep.JingleRtp.Module>(call.account, Xep.JingleRtp.Module.IDENTITY);
        if (jinglertp_module == null) return;

        connected_session_info_type = jinglertp_module.session_info_type;
        session_info_mute_handler_id = connected_session_info_type.mute_update_received.connect((session,mute, name) => {
            if (this.sid != session.sid) return;

            foreach (Xep.Jingle.Content content in session.contents) {
                if (name == null || content.content_name == name) {
                    Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
                    if (rtp_content_parameter != null) {
                        on_counterpart_mute_update(mute, rtp_content_parameter.media);
                    }
                }
            }
        });
        session_info_info_handler_id = connected_session_info_type.info_received.connect((session, session_info) => {
            if (this.sid != session.sid) return;

            info_received(session_info);
        });
    }

    internal string ensure_sid() {
        if (sid == null || sid.strip() == "") sid = Xmpp.random_uuid();
        return sid;
    }

    private bool uses_direct_jmi_lifecycle() {
        return group_call == null && call_state.group_call == null;
    }

    public async void initiate_call(Jid counterpart) {
        XmppStream? expected_stream = stream_interactor.get_stream(
            call.account);
        if (expected_stream == null) {
            if (CallState.call_invite_retractable(call.state) ||
                    call.state == Call.State.IN_PROGRESS) {
                call_state.fail_local(
                    Xep.Jingle.ReasonElement.FAILED_TRANSPORT,
                    "No XMPP stream while initiating the call");
            }
            return;
        }
        PeerCallInitiationTransaction? maybe_transaction =
            call_state.begin_peer_call_initiation(expected_stream);
        if (maybe_transaction == null) return;
        PeerCallInitiationTransaction transaction = (!) maybe_transaction;

        Gee.List<Jid> call_resources = yield calls.get_call_resources(call.account, counterpart);
        if (!call_state.peer_call_initiation_is_current(transaction,
                stream_interactor.get_stream(call.account))) return;

        bool do_jmi = false;
        Jid? jid_for_direct = null;
        if (yield calls.contains_jmi_resources(call.account, call_resources)) {
            do_jmi = true;
        } else if (!call_resources.is_empty) {
            jid_for_direct = call_resources[0];
        } else if (calls.has_jmi_resources_for_account(call.account, jid)) {
            do_jmi = true;
        }
        if (!call_state.peer_call_initiation_is_current(transaction,
                stream_interactor.get_stream(call.account))) return;

        ensure_sid();

        debug("initiate_call: do_jmi=%s we_should_send_video=%s counterpart=%s",
              do_jmi.to_string(), we_should_send_video.to_string(), counterpart.to_string());

        if (do_jmi && !calls.claim_outgoing_jmi_session(this)) {
            call_state.fail_local(Xep.Jingle.ReasonElement.GENERAL_ERROR,
                "Could not claim the local JMI session ID");
            return;
        }

        bool google_webrtc_audio_engine_enabled =
            call_state.get_selected_jmi_call_engine() != null;

        if (google_webrtc_audio_engine_enabled && !do_jmi) {
            if (!call_state.peer_call_initiation_is_current(transaction,
                    stream_interactor.get_stream(call.account))) return;
            log_google_webrtc_jmi_not_selected(
                "no-jmi-resource", "none", jid_for_direct);
            call_state.fail_local(
                Xep.Jingle.ReasonElement.UNSUPPORTED_APPLICATIONS,
                "The contact does not advertise Jingle Message Initiation");
            return;
        }

        if (do_jmi) {
            XmppStream? stream = stream_interactor.get_stream(call.account);
            Plugins.JmiCallEnginePlugin? jmi_call_engine =
                call_state.get_selected_jmi_call_engine();
            if (jmi_call_engine != null) {
                if (stream == null) {
                    warning("Cannot start Google/libwebrtc JMI call without an XMPP stream");
                    call_state.fail_local(Xep.Jingle.ReasonElement.FAILED_TRANSPORT, "No XMPP stream for Google/libwebrtc call");
                    return;
                }
                if (!call_state.peer_call_initiation_is_current(transaction,
                        stream) ||
                        !transaction.try_claim_session_start(stream)) return;
                try {
                    set_google_webrtc_jmi_call_engine_session(((!) jmi_call_engine).start_outgoing_session(
                        (!) stream,
                        call.account.full_jid,
                        jid.bare_jid,
                        sid,
                        call.id > 0 ? (uint64) call.id : 0,
                        we_should_send_video));
                    debug(
                        "Started Google/libwebrtc JMI %s session sid=%s peer=%s",
                        we_should_send_video ? "audio-video" : "audio",
                        sid,
                        jid.bare_jid.to_string());
                    if (google_webrtc_call_debug_enabled()) {
                        message(
                            "Google/libwebrtc call: PeerState started outgoing %s sid=%s account=%s peer=%s bypass=call_resource/rtp-gstreamer",
                            we_should_send_video ? "audio-video" : "audio",
                            sid,
                            call.account.bare_jid.to_string(),
                            jid.bare_jid.to_string());
                    }
                    return;
                } catch (Error e) {
                    warning(
                        "Failed to start Google/libwebrtc JMI %s session: %s",
                        we_should_send_video ? "audio-video" : "audio",
                        e.message);
                    if (call_state.peer_call_initiation_is_current(
                            transaction, stream_interactor.get_stream(
                                call.account))) {
                        call_state.fail_local(
                            Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                            e.message);
                    }
                    return;
                }
            }
            if (google_webrtc_audio_engine_enabled) {
                log_google_webrtc_jmi_not_selected(
                    we_should_send_video ? "video-requested" : "engine-unavailable",
                    "existing-jmi/rtp-gstreamer",
                    null);
            }

            var descriptions = new ArrayList<StanzaNode>();
            descriptions.add(new StanzaNode.build("description", Xep.JingleRtp.NS_URI).add_self_xmlns().put_attribute("media", "audio"));
            if (we_should_send_video) {
                descriptions.add(new StanzaNode.build("description", Xep.JingleRtp.NS_URI).add_self_xmlns().put_attribute("media", "video"));
            }

            if (!call_state.peer_call_initiation_is_current(transaction,
                    stream) || !transaction.try_claim_proposal(stream)) return;
            stream.get_module<Xmpp.Xep.JingleMessageInitiation.Module>(Xmpp.Xep.JingleMessageInitiation.Module.IDENTITY).send_session_propose_to_peer(stream, jid, sid, descriptions);

//            Uncomment this use CIM instead of JMI
//            call_state.cim_call_id = sid;
//            stream.get_module<Xmpp.Xep.CallInvites.Module>(Xmpp.Xep.CallInvites.Module.IDENTITY).send_jingle_propose(stream, call_state.cim_call_id, jid, sid, we_should_send_video);
        } else if (jid_for_direct != null) {
            if (google_webrtc_audio_engine_enabled) {
                log_google_webrtc_jmi_not_selected("no-jmi-resource", "call_resource/rtp-gstreamer", jid_for_direct);
            }
            yield call_resource(jid_for_direct, transaction);
        } else if (google_webrtc_audio_engine_enabled) {
            log_google_webrtc_jmi_not_selected("no-jmi-resource-or-direct-resource", "none", null);
        }
    }

    public bool handle_google_webrtc_jmi_call_engine_proceed(Jid from, Jid to, string incoming_sid) {
        if (google_webrtc_jmi_call_engine_session == null) return false;
        if (incoming_sid != sid) return false;

        Plugins.JmiCallEnginePlugin? jmi_call_engine =
            call_state.get_selected_jmi_call_engine();
        if (jmi_call_engine == null) return false;

        /*
         * The OMEMO DTLS-SRTP verification plugin learns the peer OMEMO device
         * id from the same incoming XEP-0353 <proceed/> message. It is connected
         * to MessageModule.received_message independently from the call manager.
         *
         * Do not synchronously convert <proceed/> into a Jingle session-initiate
         * IQ from inside this signal emission. Give the other received-message
         * handlers one main-loop turn to process the same message first, otherwise
         * the outgoing IQ can be built before the call-fingerprint encryption map
         * has been populated. Monal then rejects the IQ with
         * "Could not decrypt call with OMEMO!".
         */
        Jid proceed_from = from;
        Jid proceed_to = to;
        string proceed_sid = incoming_sid;
        Idle.add(() => {
            route_google_webrtc_jmi_call_engine_proceed(proceed_from, proceed_to, proceed_sid);
            return false;
        });

        call.state = Call.State.ESTABLISHING;
        debug("Queued Google/libwebrtc JMI proceed sid=%s from=%s", incoming_sid, from.to_string());
        if (google_webrtc_call_debug_enabled()) {
            message(
                "Google/libwebrtc call: PeerState queued proceed sid=%s peer=%s wait=message-pipeline/omemo-device before=session-initiate",
                incoming_sid,
                from.to_string());
        }
        return true;
    }

    private void route_google_webrtc_jmi_call_engine_proceed(Jid from, Jid to, string incoming_sid) {
        if (google_webrtc_jmi_call_engine_session == null) return;
        if (incoming_sid != sid) return;

        Plugins.JmiCallEnginePlugin? jmi_call_engine =
            call_state.get_selected_jmi_call_engine();
        if (jmi_call_engine == null) {
            warning("Google/libwebrtc JMI proceed could not be routed: engine disappeared");
            call_state.fail_local(Xep.Jingle.ReasonElement.FAILED_APPLICATION, "Google/libwebrtc engine unavailable");
            return;
        }

        try {
            bool handled = ((!) jmi_call_engine).handle_proceed(from, to, incoming_sid);
            if (!handled) {
                warning("Google/libwebrtc JMI proceed was queued but no registered session owned sid=%s", incoming_sid);
                call_state.fail_local(Xep.Jingle.ReasonElement.FAILED_APPLICATION, "Google/libwebrtc session not found");
                return;
            }

            debug("Routed Google/libwebrtc JMI proceed sid=%s from=%s", incoming_sid, from.to_string());
            if (google_webrtc_call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: PeerState routed proceed sid=%s peer=%s bypass=call_resource/rtp-gstreamer",
                    incoming_sid,
                    from.to_string());
            }
        } catch (Error e) {
            warning("Failed to route Google/libwebrtc JMI proceed: %s", e.message);
            call_state.fail_local(Xep.Jingle.ReasonElement.FAILED_APPLICATION, e.message);
        }
    }

    internal void set_google_webrtc_jmi_call_engine_session(Plugins.JmiCallEngineSession engine_session) {
        disconnect_google_webrtc_jmi_call_engine_session();
        google_webrtc_jmi_session_generation++;
        google_webrtc_jmi_call_engine_session = engine_session;
        google_webrtc_jmi_connection_ready_emitted = false;

        google_webrtc_jmi_active_handler_id = engine_session.active.connect(() => {
            debug("Google/libwebrtc JMI session active sid=%s peer=%s", sid, jid.to_string());
            if (google_webrtc_call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: PeerState active sid=%s peer=%s engine=libwebrtc rtp-gstreamer=not-used",
                    sid,
                    jid.to_string());
            }
            mark_google_webrtc_jmi_connection_ready("active");
        });
        google_webrtc_jmi_media_ready_handler_id = engine_session.media_ready.connect((media) => {
            debug("Google/libwebrtc JMI media ready sid=%s peer=%s media=%s", sid, jid.to_string(), media);
            if (google_webrtc_call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: PeerState media-ready sid=%s peer=%s media=%s engine=libwebrtc rtp-gstreamer=not-used",
                    sid,
                    jid.to_string(),
                    media);
            }
            mark_google_webrtc_jmi_connection_ready(@"media:$(media)");
        });
        google_webrtc_jmi_failed_handler_id = engine_session.failed.connect((message) => {
            warning("Google/libwebrtc JMI session failed sid=%s peer=%s: %s", sid, jid.to_string(), message);
            session_terminated(true, Xep.Jingle.ReasonElement.FAILED_APPLICATION, message);
        });
        google_webrtc_jmi_remote_terminated_handler_id = engine_session.remote_terminated.connect((reason_name, reason_text) => {
            session_terminated(false, reason_name, reason_text);
        });
        google_webrtc_jmi_remote_video_frame_handler_id = engine_session.remote_video_frame.connect((frame) => {
            google_webrtc_jmi_remote_video_frame(frame);
        });
        google_webrtc_jmi_local_video_frame_handler_id = engine_session.local_video_frame.connect((frame) => {
            google_webrtc_jmi_local_video_frame(frame);
        });
        google_webrtc_jmi_video_effect_status_handler_id = engine_session.video_effect_status_changed.connect((status) => {
            google_webrtc_jmi_video_effect_status_changed(status);
        });
        if (call_state.video_effects_group_gate_active) {
            engine_session.disable_video_effects_for_group_call();
        }
    }

    internal void start_google_webrtc_muji_peer_session(
            Plugins.MujiCallEngineGroupSession group_session,
            Jid peer_full_jid,
            bool peer_video_requested) throws Error {
        if (peer_full_jid.resourcepart == null) {
            throw new IOError.INVALID_ARGUMENT(
                "MUJI peer session requires a full JID");
        }
        sid = Xmpp.random_uuid();
        set_google_webrtc_jmi_call_engine_session(
            group_session.start_outgoing_peer_session(
                peer_full_jid, sid, peer_video_requested));
        mute_own_audio(!we_should_send_audio);
        mute_own_video(!we_should_send_video);
    }

    internal void accept_google_webrtc_muji_peer_session(
            string incoming_sid,
            Plugins.JmiCallEngineSession engine_session) {
        sid = incoming_sid;
        waiting_for_inbound_muji_connection = false;
        set_google_webrtc_jmi_call_engine_session(engine_session);
        mute_own_audio(!we_should_send_audio);
        mute_own_video(!we_should_send_video);
        accept();
    }

    internal void fail_waiting_google_webrtc_muji_peer_session(
            string incoming_sid, string message) {
        if (!waiting_for_inbound_muji_connection) return;
        sid = incoming_sid;
        waiting_for_inbound_muji_connection = false;
        session_terminated(true,
            Xep.Jingle.ReasonElement.FAILED_APPLICATION, message);
    }

    private void mark_google_webrtc_jmi_connection_ready(string source) {
        if (google_webrtc_jmi_connection_ready_emitted) return;
        google_webrtc_jmi_connection_ready_emitted = true;
        debug("Google/libwebrtc JMI connection ready sid=%s peer=%s source=%s", sid, jid.to_string(), source);
        call.encryption = Encryption.DTLS_SRTP;
        audio_encryption = new Xep.Jingle.ContentEncryption(Xep.JingleIceUdp.DTLS_NS_URI, "DTLS-SRTP");
        video_encryption = we_should_send_video ?
            new Xep.Jingle.ContentEncryption(Xep.JingleIceUdp.DTLS_NS_URI, "DTLS-SRTP") :
            null;
        encryption_keys_same = true;
        encryption_updated(audio_encryption, video_encryption);
        call_state.cancel_establishing_timeout();
        connection_ready();
        if (call.state == Call.State.RINGING || call.state == Call.State.ESTABLISHING) {
            call.state = Call.State.IN_PROGRESS;
        }
    }

    public bool discard_google_webrtc_jmi_call_engine_session() {
        if (google_webrtc_jmi_call_engine_session == null) return false;
        ((!) google_webrtc_jmi_call_engine_session).discard();
        release_objects();
        return true;
    }

    public bool uses_google_webrtc_jmi_call_engine_session() {
        return google_webrtc_jmi_call_engine_session != null;
    }

    internal bool can_replace_active_direct_jmi_session() {
        return uses_direct_jmi_lifecycle() &&
            call_state.can_migrate_active_direct_jmi() && session == null &&
            google_webrtc_jmi_call_engine_session != null &&
            (call.state == Call.State.ESTABLISHING ||
                call.state == Call.State.IN_PROGRESS);
    }

    /**
     * Replace the native direct-call leg while retaining the logical CallState.
     *
     * The replacement session is signaling-only at this point. Closing the old
     * wire session therefore cannot overlap two native peer connections or
     * spawn another worker; the new wire owner appears only after proceed.
     */
    internal bool replace_active_direct_jmi_session(
            Plugins.JmiCallEngineSession replacement, Jid peer_full_jid,
            string replacement_sid, bool peer_offers_video) {
        if (!can_replace_active_direct_jmi_session() ||
                peer_full_jid.resourcepart == null ||
                !peer_full_jid.equals_bare(jid) ||
                replacement_sid.strip() == "") return false;

        Plugins.JmiCallEngineSession previous =
            (!) google_webrtc_jmi_call_engine_session;
        disconnect_google_webrtc_jmi_call_engine_session();
        google_webrtc_jmi_call_engine_session = null;
        try {
            previous.end(Xep.Jingle.ReasonElement.EXPIRED,
                "Session migrated to another resource");
        } catch (Error e) {
            warning("Failed to terminate superseded Google/libwebrtc JMI session: %s",
                e.message);
            previous.discard();
        }

        Jid previous_peer = jid;
        call_state.rename_peer(previous_peer, peer_full_jid);
        sid = replacement_sid;
        call.counterpart = peer_full_jid;
        we_should_send_video = we_should_send_video && peer_offers_video;
        call_state.we_should_send_video =
            call_state.we_should_send_video && peer_offers_video;
        set_google_webrtc_jmi_call_engine_session(replacement);
        mute_own_audio(!we_should_send_audio);
        mute_own_video(!we_should_send_video);
        call.state = Call.State.ESTABLISHING;
        return true;
    }

    internal bool accept_replacement_direct_jmi_session() {
        if (!uses_direct_jmi_lifecycle() ||
                google_webrtc_jmi_call_engine_session == null) return false;
        try {
            ((!) google_webrtc_jmi_call_engine_session).accept_proposal();
            return true;
        } catch (Error e) {
            warning("Failed to accept migrated Google/libwebrtc JMI session: %s",
                e.message);
            return false;
        }
    }

    internal Plugins.JmiCallEngineSession? get_google_webrtc_call_engine_session() {
        return google_webrtc_jmi_call_engine_session;
    }

    public Plugins.JmiVideoEffectCapabilities get_google_webrtc_jmi_video_effect_capabilities() {
        if (call_state.video_effects_group_gate_active) {
            return Plugins.JmiVideoEffectCapabilities.unavailable(
                Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        }
        if (google_webrtc_jmi_call_engine_session == null) {
            return Plugins.JmiVideoEffectCapabilities.unavailable(
                Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
        }
        return ((!) google_webrtc_jmi_call_engine_session).get_video_effect_capabilities();
    }

    public Plugins.JmiVideoEffectStatus get_google_webrtc_jmi_video_effect_status() {
        if (call_state.video_effects_group_gate_active) {
            return new Plugins.JmiVideoEffectStatus(
                new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF),
                Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
                0,
                0,
                Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        }
        if (google_webrtc_jmi_call_engine_session == null) {
            return new Plugins.JmiVideoEffectStatus(
                new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF),
                Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
                0,
                0,
                Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
        }
        return ((!) google_webrtc_jmi_call_engine_session).get_video_effect_status();
    }

    public async uint64 select_google_webrtc_jmi_video_effect(
            Plugins.JmiVideoEffectSelection selection) throws Error {
        if (call_state.video_effects_group_gate_active) {
            disable_google_webrtc_jmi_video_effects_for_group_call();
            throw new IOError.NOT_SUPPORTED("Video effects are disabled for MUJI group calls");
        }
        if (google_webrtc_jmi_call_engine_session == null) {
            throw new IOError.NOT_SUPPORTED("No Google/libwebrtc call session is active");
        }
        Plugins.JmiCallEngineSession engine_session = (!) google_webrtc_jmi_call_engine_session;
        uint64 generation = google_webrtc_jmi_session_generation;
        uint64 revision = yield engine_session.select_video_effect(selection);
        if (call_state.video_effects_group_gate_active ||
                google_webrtc_jmi_call_engine_session != engine_session ||
                google_webrtc_jmi_session_generation != generation) {
            throw new IOError.CANCELLED("The Google/libwebrtc call session changed");
        }
        return revision;
    }

    public async void release_google_webrtc_jmi_video_background(uint asset_id) throws Error {
        Plugins.JmiCallEngineSession? engine = google_webrtc_jmi_call_engine_session;
        if (engine != null) yield ((!) engine).release_video_background(asset_id);
    }

    public async uint stage_google_webrtc_jmi_video_background(uint builtin_choice,
            Plugins.JmiVideoBackgroundImage? image) throws Error {
        if (call_state.video_effects_group_gate_active || google_webrtc_jmi_call_engine_session == null)
            throw new IOError.NOT_SUPPORTED("No direct video pipeline is available");
        Plugins.JmiCallEngineSession engine = (!) google_webrtc_jmi_call_engine_session;
        uint64 generation = google_webrtc_jmi_session_generation;
        uint asset = yield engine.stage_video_background(builtin_choice, image);
        if (call_state.video_effects_group_gate_active || google_webrtc_jmi_call_engine_session != engine ||
                google_webrtc_jmi_session_generation != generation) {
            try { yield engine.release_video_background(asset); } catch (Error ignored) { }
            throw new IOError.CANCELLED("The video call owner changed");
        }
        return asset;
    }

    public void disable_google_webrtc_jmi_video_effects_for_group_call() {
        if (google_webrtc_jmi_call_engine_session == null) return;
        ((!) google_webrtc_jmi_call_engine_session).disable_video_effects_for_group_call();
    }

    public async void fence_google_webrtc_jmi_video_effects_for_group_call() {
        while (google_webrtc_jmi_call_engine_session != null) {
            Plugins.JmiCallEngineSession engine_session =
                (!) google_webrtc_jmi_call_engine_session;
            yield engine_session.fence_video_effects_for_group_call();
            if (google_webrtc_jmi_call_engine_session == engine_session) return;
        }
    }

    public bool send_google_webrtc_jmi_dtmf(char digit, uint duration_ms = 250) {
        if (google_webrtc_jmi_call_engine_session == null) return false;
        try {
            Plugins.JmiCallEngineSession engine_session = (!) google_webrtc_jmi_call_engine_session;
            engine_session.send_dtmf(digit, duration_ms);
            if (google_webrtc_call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: DTMF digit sent sid=%s peer=%s digit=%c",
                    sid,
                    jid.to_string(),
                    digit);
                Timeout.add(250, () => {
                    log_google_webrtc_jmi_dtmf_diagnostics(engine_session, digit, "dtmf+250ms");
                    return Source.REMOVE;
                });
            }
            return true;
        } catch (Error e) {
            warning(
                "Failed to send Google/libwebrtc DTMF digit sid=%s peer=%s: %s",
                sid,
                jid.to_string(),
                e.message);
            return false;
        }
    }

    private void log_google_webrtc_jmi_dtmf_diagnostics(
        Plugins.JmiCallEngineSession engine_session,
        char digit,
        string phase) {
        if (!google_webrtc_call_debug_enabled()) return;

        try {
            Plugins.JmiCallDiagnostics? diagnostics = engine_session.get_diagnostics();
            if (diagnostics == null) {
                message(
                    "Google/libwebrtc call: DTMF diagnostics phase=%s sid=%s peer=%s digit=%c unavailable",
                    phase,
                    sid,
                    jid.to_string(),
                    digit);
                return;
            }

            Plugins.JmiCallDiagnostics info = (!) diagnostics;
            message(
                "Google/libwebrtc call: DTMF diagnostics phase=%s sid=%s peer=%s digit=%c local:%llu/%llu/%llu unsupported:%llu fmt:%u/%u/%u peak:%.4f active:%s",
                phase,
                sid,
                jid.to_string(),
                digit,
                info.local_dtmf_feedback_start_count,
                info.local_dtmf_feedback_mix_call_count,
                info.local_dtmf_feedback_mixed_frame_count,
                info.local_dtmf_feedback_unsupported_format_count,
                info.local_dtmf_feedback_last_sample_rate,
                info.local_dtmf_feedback_last_channels,
                info.local_dtmf_feedback_last_bytes_per_sample,
                info.local_dtmf_feedback_peak_level,
                info.local_dtmf_feedback_active ? "yes" : "no");
        } catch (Error e) {
            message(
                "Google/libwebrtc call: DTMF diagnostics phase=%s sid=%s peer=%s digit=%c failed: %s",
                phase,
                sid,
                jid.to_string(),
                digit,
                e.message);
        }
    }

    private void log_google_webrtc_jmi_not_selected(string reason, string fallback, Jid? direct_resource) {
        if (!google_webrtc_call_debug_enabled()) return;

        if (direct_resource != null) {
            message(
                "Google/libwebrtc call: not selected sid=%s peer=%s reason=%s direct-resource=%s fallback=%s",
                sid,
                jid.to_string(),
                reason,
                ((!) direct_resource).to_string(),
                fallback);
            return;
        }

        message(
            "Google/libwebrtc call: not selected sid=%s peer=%s reason=%s fallback=%s",
            sid,
            jid.to_string(),
            reason,
            fallback);
    }

    internal async void call_resource(Jid full_jid,
            PeerCallInitiationTransaction? existing_transaction = null) {
        if (!call_state.accepted) {
            warning("Tried to call resource in an unaccepted call?!");
            return;
        }
        XmppStream? stream = stream_interactor.get_stream(call.account);
        if (stream == null) return;

        PeerCallInitiationTransaction? maybe_transaction =
            existing_transaction;
        if (maybe_transaction == null) {
            maybe_transaction = call_state.begin_peer_call_initiation(stream);
        }
        if (maybe_transaction == null) return;
        PeerCallInitiationTransaction transaction = (!) maybe_transaction;
        if (!call_state.peer_call_initiation_is_current(transaction, stream)) {
            return;
        }

        if (sid == null) sid = Xmpp.random_uuid();

        debug("call_resource: we_should_send_video=%s peer=%s", we_should_send_video.to_string(), full_jid.to_string());

        Xep.Jingle.Session session;
        if (!transaction.try_claim_session_start(stream)) return;
        try {
            session = yield stream.get_module<Xep.JingleRtp.Module>(Xep.JingleRtp.Module.IDENTITY).start_call(stream, full_jid, we_should_send_video, sid, group_call != null ? group_call.muc_jid : null);
        } catch (Xep.Jingle.Error e) {
            warning("Failed to start call: %s", e.message);
            return;
        }
        // Guard: call may have ended while we were yielding (async race).
        // If so, terminate the zombie session immediately.
        if (!call_state.peer_call_initiation_is_current(transaction,
                stream_interactor.get_stream(call.account))) {
            debug("call_resource: call already ended during async yield — terminating zombie session");
            session.terminate(Xep.Jingle.ReasonElement.CANCEL, null, "call already ended");
            return;
        }
        set_session(session);
    }

    public void accept() {
        if (!call_state.accepted) {
            critical("Tried to accept peer in unaccepted call?! Something's fishy. Abort.");
            return;
        }

        debug("accept: we_should_send_video=%s session=%s", we_should_send_video.to_string(), session != null ? "set" : "null");

        if (uses_direct_jmi_lifecycle() && session == null &&
                google_webrtc_jmi_call_engine_session == null &&
                call_state.media_backend == CallMediaBackend.GOOGLE_WEBRTC &&
                !calls.ensure_google_webrtc_jmi_incoming_session(this)) {
            session_terminated(true,
                Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                "Could not create the selected incoming media session");
            return;
        }

        if (session != null) {
            foreach (Xep.Jingle.Content content in session.contents) {
                Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
                if (rtp_content_parameter != null && rtp_content_parameter.media == "video") {
                    debug("accept: video content '%s' senders=%s we_initiated=%s",
                          content.content_name, content.senders.to_string(), session.we_initiated.to_string());
                    // We didn't accept video but our peer wants to negotiate that content
                    if (!we_should_send_video && session.senders_include_us(content.senders)) {
                        if (session.senders_include_counterpart(content.senders)) {
                            // If our peer wants to send, let them
                            content.modify(session.we_initiated ? Xep.Jingle.Senders.RESPONDER : Xep.Jingle.Senders.INITIATOR);
                        } else {
                            // If only we're supposed to send, reject
                            content.reject();
                            continue;
                        }
                    }
                }
                content.accept();
            }
        } else if (google_webrtc_jmi_call_engine_session != null) {
            try {
                bool proceed_reserved = !uses_direct_jmi_lifecycle() ||
                    calls.reserve_jmi_local_proceed(this, jid,
                        call.account.full_jid);
                if (!proceed_reserved) {
                    throw new IOError.FAILED(
                        "Could not bind JMI proceed to the peer resource");
                }
                if (google_webrtc_call_debug_enabled()) {
                    message(
                        "Google/libwebrtc call: accepting incoming proposal sid=%s peer=%s path=libwebrtc-jmi rtp-gstreamer=not-used",
                        sid,
                        jid.to_string());
                }
                ((!) google_webrtc_jmi_call_engine_session).accept_proposal();
                if (uses_direct_jmi_lifecycle() &&
                        !calls.commit_jmi_local_proceed(this, jid,
                            call.account.full_jid)) {
                    throw new IOError.FAILED(
                        "Could not commit JMI proceed ownership");
                }
            } catch (Error e) {
                if (uses_direct_jmi_lifecycle()) {
                    calls.rollback_jmi_local_proceed(this, jid,
                        call.account.full_jid);
                }
                warning("Failed to accept Google/libwebrtc JMI session: %s", e.message);
                session_terminated(true, Xep.Jingle.ReasonElement.FAILED_APPLICATION, e.message);
            }
        } else {
            // Only a JMI so far
            XmppStream stream = stream_interactor.get_stream(call.account);
            if (stream == null) return;

            if (uses_direct_jmi_lifecycle() &&
                    !calls.reserve_jmi_local_proceed(this, jid,
                        call.account.full_jid)) {
                session_terminated(true,
                    Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                    "Could not bind JMI proceed to the peer resource");
                return;
            }
            stream.get_module<Xep.JingleMessageInitiation.Module>(Xep.JingleMessageInitiation.Module.IDENTITY).send_session_accept_to_self(stream, sid);
            stream.get_module<Xep.JingleMessageInitiation.Module>(Xep.JingleMessageInitiation.Module.IDENTITY).send_session_proceed_to_peer(stream, jid, sid);
            if (uses_direct_jmi_lifecycle() &&
                    !calls.commit_jmi_local_proceed(this, jid,
                        call.account.full_jid)) {
                calls.rollback_jmi_local_proceed(this, jid,
                    call.account.full_jid);
                session_terminated(true,
                    Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                    "Could not commit JMI proceed ownership");
            }
        }
    }

    public void reject() {
        if (session != null) {
            foreach (Xep.Jingle.Content content in session.contents) {
                content.reject();
            }
        } else if (google_webrtc_jmi_call_engine_session != null) {
            try {
                if (google_webrtc_call_debug_enabled()) {
                    message(
                        "Google/libwebrtc call: rejecting proposal sid=%s peer=%s path=libwebrtc-jmi",
                        sid,
                        jid.to_string());
                }
                ((!) google_webrtc_jmi_call_engine_session).reject_proposal();
            } catch (Error e) {
                warning("Failed to reject Google/libwebrtc JMI session: %s", e.message);
            }
            release_objects();
        } else {
            // Only a JMI so far
            XmppStream stream = stream_interactor.get_stream(call.account);
            if (stream == null) return;

            stream.get_module<Xep.JingleMessageInitiation.Module>(Xep.JingleMessageInitiation.Module.IDENTITY).send_session_reject_to_peer(stream, jid, sid);
            stream.get_module<Xep.JingleMessageInitiation.Module>(Xep.JingleMessageInitiation.Module.IDENTITY).send_session_reject_to_self(stream, sid);
        }
    }

    public void end(string terminate_reason, string? reason_text = null) {
        // Disconnect all signal handlers to break reference cycles
        cleanup_signal_handlers();

        if (google_webrtc_jmi_call_engine_session != null) {
            try {
                if (google_webrtc_call_debug_enabled()) {
                    message(
                        "Google/libwebrtc call: ending sid=%s peer=%s reason=%s path=libwebrtc-jmi",
                        sid,
                        jid.to_string(),
                        terminate_reason);
                }
                ((!) google_webrtc_jmi_call_engine_session).end(terminate_reason, reason_text);
            } catch (Error e) {
                warning("Failed to end Google/libwebrtc JMI session: %s", e.message);
            }
            release_objects();
            return;
        }

        switch (terminate_reason) {
            case Xep.Jingle.ReasonElement.SUCCESS:
                if (session != null) {
                    session.terminate(terminate_reason, reason_text, "success");
                }
                break;
            case Xep.Jingle.ReasonElement.CANCEL:
                if (session != null) {
                    session.terminate(terminate_reason, reason_text, "cancel");
                } else if (group_call != null) {
                    // We don't have to do anything (?)
                } else {
                    // Only a JMI so far
                    XmppStream? stream = stream_interactor.get_stream(call.account);
                    if (stream != null) {
                        stream.get_module<Xep.JingleMessageInitiation.Module>(Xep.JingleMessageInitiation.Module.IDENTITY).send_session_retract_to_peer((!) stream, jid, sid);
                    }
                }
                break;
        }

        // Release heavyweight Jingle/GStreamer objects so they can be
        // collected even if something still holds a ref to this PeerState.
        release_objects();
    }

    /**
     * Null all heavyweight Jingle session, content, and encryption objects.
     * Called from end() (local hangup) and from CallState.handle_peer_left()
     * (remote hangup) to ensure GStreamer streams, ICE transports, and
     * RTP codec state can be collected promptly.
     */
    public void release_objects() {
        disconnect_google_webrtc_jmi_call_engine_session();
        session = null;
        google_webrtc_jmi_call_engine_session = null;
        audio_content_parameter = null;
        video_content_parameter = null;
        audio_content = null;
        video_content = null;
        audio_encryption = null;
        video_encryption = null;
        audio_encryptions = null;
        video_encryptions = null;
    }

    /**
     * Disconnect signal handlers from the long-lived session_info_type singleton.
     * Without this, the closures capture `this` (PeerState) and prevent GC,
     * keeping audio/video content parameters and GStreamer streams alive
     * (causing PipeWire connection leaks).
     */
    private void disconnect_session_info_handlers() {
        if (connected_session_info_type != null) {
            if (session_info_mute_handler_id != 0) {
                if (SignalHandler.is_connected(connected_session_info_type, session_info_mute_handler_id)) {
                    connected_session_info_type.disconnect(session_info_mute_handler_id);
                }
                session_info_mute_handler_id = 0;
            }
            if (session_info_info_handler_id != 0) {
                if (SignalHandler.is_connected(connected_session_info_type, session_info_info_handler_id)) {
                    connected_session_info_type.disconnect(session_info_info_handler_id);
                }
                session_info_info_handler_id = 0;
            }
            connected_session_info_type = null;
        }
    }

    private void disconnect_google_webrtc_jmi_call_engine_session() {
        if (google_webrtc_jmi_call_engine_session == null) {
            google_webrtc_jmi_active_handler_id = 0;
            google_webrtc_jmi_media_ready_handler_id = 0;
            google_webrtc_jmi_failed_handler_id = 0;
            google_webrtc_jmi_remote_terminated_handler_id = 0;
            google_webrtc_jmi_remote_video_frame_handler_id = 0;
            google_webrtc_jmi_local_video_frame_handler_id = 0;
            google_webrtc_jmi_video_effect_status_handler_id = 0;
            google_webrtc_jmi_connection_ready_emitted = false;
            return;
        }

        Plugins.JmiCallEngineSession engine_session = (!) google_webrtc_jmi_call_engine_session;
        if (google_webrtc_jmi_active_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_active_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_active_handler_id);
        }
        google_webrtc_jmi_active_handler_id = 0;
        if (google_webrtc_jmi_media_ready_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_media_ready_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_media_ready_handler_id);
        }
        google_webrtc_jmi_media_ready_handler_id = 0;
        if (google_webrtc_jmi_failed_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_failed_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_failed_handler_id);
        }
        google_webrtc_jmi_failed_handler_id = 0;
        if (google_webrtc_jmi_remote_terminated_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_remote_terminated_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_remote_terminated_handler_id);
        }
        google_webrtc_jmi_remote_terminated_handler_id = 0;
        if (google_webrtc_jmi_remote_video_frame_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_remote_video_frame_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_remote_video_frame_handler_id);
        }
        google_webrtc_jmi_remote_video_frame_handler_id = 0;
        if (google_webrtc_jmi_local_video_frame_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_local_video_frame_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_local_video_frame_handler_id);
        }
        google_webrtc_jmi_local_video_frame_handler_id = 0;
        if (google_webrtc_jmi_video_effect_status_handler_id != 0 && SignalHandler.is_connected(engine_session, google_webrtc_jmi_video_effect_status_handler_id)) {
            engine_session.disconnect(google_webrtc_jmi_video_effect_status_handler_id);
        }
        google_webrtc_jmi_video_effect_status_handler_id = 0;
        google_webrtc_jmi_session_generation++;
        google_webrtc_jmi_connection_ready_emitted = false;
    }

    /**
     * Disconnect all signal handlers that capture `this` (PeerState) in their
     * closures to break reference cycles. This allows PeerState, its content
     * parameters, and ultimately the GStreamer pipeline elements to be freed.
     */
    internal void cleanup_signal_handlers() {
        disconnect_session_info_handlers();
        disconnect_google_webrtc_jmi_call_engine_session();

        // Disconnect session signal handlers
        if (session != null) {
            if (session_terminated_handler_id != 0 && SignalHandler.is_connected(session, session_terminated_handler_id)) {
                session.disconnect(session_terminated_handler_id);
            }
            session_terminated_handler_id = 0;
            if (session_content_add_handler_id != 0 && SignalHandler.is_connected(session, session_content_add_handler_id)) {
                session.disconnect(session_content_add_handler_id);
            }
            session_content_add_handler_id = 0;
        }

        // Disconnect audio content signal handlers
        if (audio_content_parameter != null) {
            if (audio_stream_created_handler_id != 0 && SignalHandler.is_connected(audio_content_parameter, audio_stream_created_handler_id)) {
                audio_content_parameter.disconnect(audio_stream_created_handler_id);
            }
            audio_stream_created_handler_id = 0;
            if (audio_connection_ready_handler_id != 0 && SignalHandler.is_connected(audio_content_parameter, audio_connection_ready_handler_id)) {
                audio_content_parameter.disconnect(audio_connection_ready_handler_id);
            }
            audio_connection_ready_handler_id = 0;
        }
        if (audio_content != null) {
            if (audio_senders_modify_handler_id != 0 && SignalHandler.is_connected(audio_content, audio_senders_modify_handler_id)) {
                audio_content.disconnect(audio_senders_modify_handler_id);
            }
            audio_senders_modify_handler_id = 0;
        }

        // Disconnect video content signal handlers
        if (video_content_parameter != null) {
            if (video_stream_created_handler_id != 0 && SignalHandler.is_connected(video_content_parameter, video_stream_created_handler_id)) {
                video_content_parameter.disconnect(video_stream_created_handler_id);
            }
            video_stream_created_handler_id = 0;
            if (video_connection_ready_handler_id != 0 && SignalHandler.is_connected(video_content_parameter, video_connection_ready_handler_id)) {
                video_content_parameter.disconnect(video_connection_ready_handler_id);
            }
            video_connection_ready_handler_id = 0;
            if (video_connection_ready_extra_handler_id != 0 && SignalHandler.is_connected(video_content_parameter, video_connection_ready_extra_handler_id)) {
                video_content_parameter.disconnect(video_connection_ready_extra_handler_id);
            }
            video_connection_ready_extra_handler_id = 0;
        }
        if (video_content != null) {
            if (video_senders_modify_handler_id != 0 && SignalHandler.is_connected(video_content, video_senders_modify_handler_id)) {
                video_content.disconnect(video_senders_modify_handler_id);
            }
            video_senders_modify_handler_id = 0;
        }
    }

    internal void mute_own_audio(bool mute) {
        if (google_webrtc_jmi_call_engine_session != null) {
            try {
                ((!) google_webrtc_jmi_call_engine_session).set_local_audio_enabled(!mute);
            } catch (Error e) {
                warning("Failed to set Google/libwebrtc local audio enabled sid=%s peer=%s: %s", sid, jid.to_string(), e.message);
            }
            return;
        }

        // Call isn't fully established yet. Audio will be muted once the stream is created.
        if (session == null || audio_content_parameter == null || audio_content_parameter.stream == null) return;

        Xep.JingleRtp.Stream stream = audio_content_parameter.stream;

        // Inform our counterpart that we (un)muted our audio
        stream_interactor.module_manager.get_module<Xep.JingleRtp.Module>(call.account, Xep.JingleRtp.Module.IDENTITY).session_info_type.send_mute(session, mute, "audio");

        // Start/Stop sending audio data
        Plugins.VideoCallPlugin? call_plugin = Application.get_default().plugin_registry.video_call_plugin;
        if (call_plugin == null) {
            warning("Can't update legacy RTP audio mute state without a video call plugin");
            return;
        }
        ((!) call_plugin).set_pause(stream, mute);
    }

    internal void mute_own_video(bool mute) {
        if (google_webrtc_jmi_call_engine_session != null) {
            try {
                ((!) google_webrtc_jmi_call_engine_session).set_local_video_enabled(!mute);
            } catch (Error e) {
                warning("Failed to set Google/libwebrtc local video enabled sid=%s peer=%s: %s", sid, jid.to_string(), e.message);
            }
            return;
        }

        if (session == null) {
            // Call hasn't been established yet
            return;
        }

        Xep.JingleRtp.Module rtp_module = stream_interactor.module_manager.get_module<Xep.JingleRtp.Module>(call.account, Xep.JingleRtp.Module.IDENTITY);

        if (video_content_parameter != null &&
                video_content_parameter.stream != null &&
                session.senders_include_us(video_content.senders)) {
            // A video content already exists

            // Start/Stop sending video data
            Xep.JingleRtp.Stream stream = video_content_parameter.stream;
            if (stream != null) {
                Plugins.VideoCallPlugin? call_plugin = Application.get_default().plugin_registry.video_call_plugin;
                if (call_plugin == null) {
                    warning("Can't update legacy RTP video mute state without a video call plugin");
                    return;
                }
                ((!) call_plugin).set_pause(stream, mute);
            }

            // Inform our counterpart that we started/stopped our video
            rtp_module.session_info_type.send_mute(session, mute, "video");
        } else if (!mute) {
            // Add a new video content
            XmppStream stream = stream_interactor.get_stream(call.account);
            rtp_module.add_outgoing_video_content.begin(stream, session, group_call != null ? group_call.muc_jid : null, (_, res) => {
                if (video_content_parameter == null) {
                    Xep.Jingle.Content content;
                    try {
                        content = rtp_module.add_outgoing_video_content.end(res);
                    } catch (Xep.Jingle.Error e) {
                        warning("Failed to add outgoing video content: %s", e.message);
                        return;
                    }
                    Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
                    if (rtp_content_parameter != null) {
                        connect_content_signals(content, rtp_content_parameter);
                    }
                }
            });
        }
        // If video_content_parameter == null && !mute we're trying to mute a non-existant feed. It will be muted as soon as it is created.
    }

    internal void set_google_webrtc_jmi_video_device(Plugins.MediaDevice device) {
        if (google_webrtc_jmi_call_engine_session == null) return;
        try {
            ((!) google_webrtc_jmi_call_engine_session).set_video_device(device);
        } catch (Error e) {
            warning("Failed to set Google/libwebrtc video device sid=%s peer=%s device=%s: %s", sid, jid.to_string(), device.display_name, e.message);
        }
    }

    public Xep.JingleRtp.Stream? get_video_stream() {
        if (video_content_parameter != null) {
            return video_content_parameter.stream;
        }
        return null;
    }

    public Xep.JingleRtp.Stream? get_audio_stream() {
        if (audio_content_parameter != null) {
            return audio_content_parameter.stream;
        }
        return null;
    }

    internal void set_session(Xep.Jingle.Session session) {
        this.session = session;
        this.sid = session.sid;

        session_terminated_handler_id = session.terminated.connect((stream, we_terminated, reason_name, reason_text) =>
            session_terminated(we_terminated, reason_name, reason_text)
        );
        session_content_add_handler_id = session.additional_content_add_incoming.connect((stream, content) =>
            on_incoming_content_add(stream, content.session, content)
        );

        foreach (Xep.Jingle.Content content in session.contents) {
            Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
            if (rtp_content_parameter == null) continue;

            connect_content_signals(content, rtp_content_parameter);
        }
    }

    public PeerInfo get_info() {
        var ret = new PeerInfo();
        if (google_webrtc_jmi_call_engine_session != null) {
            return get_google_webrtc_jmi_info((!) google_webrtc_jmi_call_engine_session);
        }
        if (audio_content != null || audio_content_parameter != null) {
            ret.audio = get_content_info(audio_content, audio_content_parameter);
        }
        if (video_content != null || video_content_parameter != null) {
            ret.video = get_content_info(video_content, video_content_parameter);
        }
        return ret;
    }

    private PeerInfo get_google_webrtc_jmi_info(Plugins.JmiCallEngineSession engine_session) {
        PeerInfo ret = new PeerInfo();
        try {
            Plugins.JmiCallDiagnostics? diagnostics = engine_session.get_diagnostics();
            if (diagnostics == null) {
                ret.audio = get_google_webrtc_jmi_unavailable_info("Google/libwebrtc diagnostics unavailable");
                return ret;
            }

            Plugins.JmiCallDiagnostics info = (!) diagnostics;
            ret.audio = get_google_webrtc_jmi_audio_info(info);
            if (info.video_requested) {
                ret.video = get_google_webrtc_jmi_video_info(info);
            }
        } catch (Error e) {
            ret.audio = get_google_webrtc_jmi_unavailable_info("Google/libwebrtc diagnostics failed: %s".printf(e.message));
        }
        return ret;
    }

    private PeerContentInfo get_google_webrtc_jmi_unavailable_info(string message) {
        PeerContentInfo ret = new PeerContentInfo();
        ret.transport_title = "PeerConnection";
        ret.control_title = "ICE";
        ret.show_bitrate_rows = false;
        ret.transport_status = "unavailable";
        ret.control_status = "unavailable";
        ret.diagnostics = message;
        return ret;
    }

    private PeerContentInfo get_google_webrtc_jmi_audio_info(Plugins.JmiCallDiagnostics info) {
        PeerContentInfo ret = new PeerContentInfo();
        ret.transport_title = "PeerConnection";
        ret.control_title = "ICE";
        ret.transport_status = info.peer_connection_state ?? "unknown";
        ret.control_status = info.ice_connection_state ?? "unknown";
        ret.codec = "Opus";
        ret.clockrate = 48000;
        ret.show_bitrate_rows = info.wire_started;
        ret.bytes_received = (ulong) info.inbound_audio_bytes_received;
        ret.bytes_sent = (ulong) info.outbound_audio_bytes_sent;
        ret.diagnostics =
            "JMI %s · wire %s · network:%s cap:%dbps adaptive-ptime:%s applied:%s · local audio %s/%s/%s · packets in:%llu out:%llu · bytes in:%llu out:%llu · samples in:%llu sink:%llu/%llu · levels in:%.4f src:%.4f peak:%.4f · adm init:%s play:%s/%s rec:%s/%s cap:%llu out:%llu".printf(
                info.jmi_state ?? "unknown",
                info.wire_started ? "started" : "pending",
                info.call_network_policy,
                info.audio_sender_bitrate_cap_bps,
                info.audio_sender_adaptive_ptime ? "yes" : "no",
                info.audio_sender_policy_applied ? "yes" : "no",
                info.local_audio_source_attached ? "source" : "no-source",
                info.local_audio_track_attached ? "track" : "no-track",
                info.local_audio_track_enabled ? "enabled" : "muted",
                info.inbound_audio_packets_received,
                info.outbound_audio_packets_sent,
                info.inbound_audio_bytes_received,
                info.outbound_audio_bytes_sent,
                info.inbound_audio_total_samples_received,
                info.remote_audio_sink_frame_count,
                info.remote_audio_sink_sample_count,
                info.inbound_audio_level,
                info.source_audio_level,
                info.remote_audio_sink_peak_level,
                info.audio_device_initialized ? "yes" : "no",
                info.audio_device_playout_initialized ? "init" : "no-init",
                info.audio_device_playing ? "playing" : "stopped",
                info.audio_device_recording_initialized ? "init" : "no-init",
                info.audio_device_recording ? "recording" : "stopped",
                info.audio_device_capture_sample_count,
                info.audio_device_playout_sample_count);
        return ret;
    }

    private PeerContentInfo get_google_webrtc_jmi_video_info(Plugins.JmiCallDiagnostics info) {
        PeerContentInfo ret = new PeerContentInfo();
        ret.transport_title = "PeerConnection";
        ret.control_title = "ICE";
        ret.transport_status = info.peer_connection_state ?? "unknown";
        ret.control_status = info.ice_connection_state ?? "unknown";
        ret.codec = "VP8";
        ret.clockrate = 90000;
        ret.show_bitrate_rows = info.wire_started;
        ret.bytes_received = (ulong) info.inbound_video_bytes_received;
        ret.bytes_sent = (ulong) info.outbound_video_bytes_sent;
        ret.diagnostics =
            "JMI %s · wire %s · local video %s/%s/%s cap:%s frames:%llu %dx%d · rtp in:%llu/%lluB frames:%llu decoded:%llu %dx%d out:%llu/%lluB frames:%llu encoded:%llu target:%.0fbps %dx%d · remote video recv:%d sink:%d frames:%llu %dx%d · transceivers a:%d v:%d".printf(
                info.jmi_state ?? "unknown",
                info.wire_started ? "started" : "pending",
                info.local_video_source_attached ? "source" : "no-source",
                info.local_video_track_attached ? "track" : "no-track",
                info.local_video_track_enabled ? "enabled" : "muted",
                info.local_video_capture_running ? "running" : "stopped",
                info.local_video_capture_frame_count,
                info.local_video_capture_last_width,
                info.local_video_capture_last_height,
                info.inbound_video_packets_received,
                info.inbound_video_bytes_received,
                info.inbound_video_frames_received,
                info.inbound_video_frames_decoded,
                info.inbound_video_frame_width,
                info.inbound_video_frame_height,
                info.outbound_video_packets_sent,
                info.outbound_video_bytes_sent,
                info.outbound_video_frames_sent,
                info.outbound_video_frames_encoded,
                info.outbound_video_target_bitrate,
                info.outbound_video_frame_width,
                info.outbound_video_frame_height,
                info.remote_video_receiver_count,
                info.remote_video_sink_count,
                info.remote_video_sink_frame_count,
                info.remote_video_sink_last_width,
                info.remote_video_sink_last_height,
                info.audio_transceiver_count,
                info.video_transceiver_count);
        return ret;
    }

    private PeerContentInfo get_content_info(Xep.Jingle.Content? content, Xep.JingleRtp.Parameters? parameter) {
        PeerContentInfo ret = new PeerContentInfo();
        if (parameter != null) {
            ret.rtcp_ready = parameter.rtcp_ready;
            ret.rtp_ready = parameter.rtp_ready;

            if (parameter.agreed_payload_type != null) {
                ret.codec = parameter.agreed_payload_type.name;
                ret.clockrate = parameter.agreed_payload_type.clockrate;
            }
            if (parameter.stream != null && parameter.stream.remb_enabled) {
                ret.target_receive_bytes = parameter.stream.target_receive_bitrate;
                ret.target_send_bytes = parameter.stream.target_send_bitrate;
            }
        }

        if (content != null) {
            Xmpp.Xep.Jingle.ComponentConnection? component0 = content.get_transport_connection(1);
            if (component0 != null) {
                ret.bytes_received = component0.bytes_received;
                ret.bytes_sent = component0.bytes_sent;
            }
        }
        return ret;
    }



    private void connect_content_signals(Xep.Jingle.Content content, Xep.JingleRtp.Parameters rtp_content_parameter) {
        if (rtp_content_parameter.media == "audio") {
            audio_content = content;
            audio_content_parameter = rtp_content_parameter;
        } else if (rtp_content_parameter.media == "video") {
            video_content = content;
            video_content_parameter = rtp_content_parameter;
        }

        debug(@"[%s] %s connecting content signals %s", call.account.bare_jid.to_string(), jid.to_string(), rtp_content_parameter.media);
        ulong sc_id = rtp_content_parameter.stream_created.connect((stream) => on_stream_created(rtp_content_parameter.media, stream));
        ulong cr_id = rtp_content_parameter.connection_ready.connect((status) => {
            Idle.add(() => {
                on_connection_ready(content, rtp_content_parameter.media);
                return false;
            });
        });

        ulong sm_id = content.senders_modify_incoming.connect((content, proposed_senders) => {
            if (content.session.senders_include_us(content.senders) != content.session.senders_include_us(proposed_senders)) {
                warning("counterpart set us to (not)sending %s. ignoring", content.content_name);
                return;
            }

            if (!content.session.senders_include_counterpart(content.senders) && content.session.senders_include_counterpart(proposed_senders)) {
                // Counterpart wants to start sending. Ok.
                content.accept_content_modify(proposed_senders);
                on_counterpart_mute_update(false, "video");
            }
        });

        if (rtp_content_parameter.media == "audio") {
            audio_stream_created_handler_id = sc_id;
            audio_connection_ready_handler_id = cr_id;
            audio_senders_modify_handler_id = sm_id;
        } else if (rtp_content_parameter.media == "video") {
            video_stream_created_handler_id = sc_id;
            video_connection_ready_handler_id = cr_id;
            video_senders_modify_handler_id = sm_id;
        }
    }

    private void on_incoming_content_add(XmppStream stream, Xep.Jingle.Session session, Xep.Jingle.Content content) {
        Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;

        if (rtp_content_parameter == null) {
            content.reject();
            return;
        }

        // If this is a video content-add and we should be sending video, accept with both senders
        bool dominated_by_us = session.senders_include_us(content.senders);
        bool includes_peer = session.senders_include_counterpart(content.senders);
        if (dominated_by_us && !we_should_send_video) {
            if (includes_peer) {
                // Peer wants to send too — let them, but exclude us
                content.modify(session.we_initiated ? Xep.Jingle.Senders.RESPONDER : Xep.Jingle.Senders.INITIATOR);
            } else {
                // Only we're supposed to send but we don't want to — reject
                content.reject();
                return;
            }
        }
        // If we_should_send_video, keep senders as-is (both)

        connect_content_signals(content, rtp_content_parameter);
        content.accept();
    }

    private void on_stream_created(string media, Xep.JingleRtp.Stream stream) {
        debug("RECV-VIDEO-SIGNAL: on_stream_created media=%s sending=%s receiving=%s",
                media, stream.sending.to_string(), stream.receiving.to_string());
        if (media == "video" && stream.receiving) {
            counterpart_sends_video = true;
            // Guard against duplicate on_stream_created() calls (e.g. ICE restart)
            if (video_connection_ready_extra_handler_id != 0 && video_content_parameter != null &&
                    SignalHandler.is_connected(video_content_parameter, video_connection_ready_extra_handler_id)) {
                video_content_parameter.disconnect(video_connection_ready_extra_handler_id);
            }
            video_connection_ready_extra_handler_id = video_content_parameter.connection_ready.connect((status) => {
                debug("RECV-VIDEO-SIGNAL: video connection_ready fired, emitting counterpart_sends_video_updated(false)");
                Idle.add(() => {
                    counterpart_sends_video_updated(false);
                    return false;
                });
            });
        } else if (media == "video" && !stream.receiving) {
            debug("RECV-VIDEO-SIGNAL: video stream NOT receiving! counterpart won't send video");
        }

        // Outgoing audio/video might have been muted in the meanwhile.
        if (media == "video" && !we_should_send_video) {
            mute_own_video(true);
        } else if (media == "audio" && !we_should_send_audio) {
            mute_own_audio(true);
        }

        stream_created(media);
    }

    private void on_counterpart_mute_update(bool mute, string? media) {
        if (media == "video") {
            counterpart_sends_video = !mute;
            debug(@"[%s] %s video muted %s", call.account.bare_jid.to_string(), jid.to_string(), mute.to_string());
            counterpart_sends_video_updated(mute);
        }
    }

    private void on_connection_ready(Xep.Jingle.Content content, string media) {
        debug("[%s] %s on_connection_ready", call.account.bare_jid.to_string(), jid.to_string());
        call_state.cancel_establishing_timeout();
        connection_ready();

        if (call.state == Call.State.RINGING || call.state == Call.State.ESTABLISHING) {
            call.state = Call.State.IN_PROGRESS;
        }

        if (media == "audio") {
            audio_encryptions = content.encryptions;
        } else if (media == "video") {
            video_encryptions = content.encryptions;
        }

        if ((audio_encryptions != null && audio_encryptions.is_empty) || (video_encryptions != null && video_encryptions.is_empty)) {
            call.encryption = Encryption.NONE;
            encryption_updated(null, null);
            return;
        }

        HashMap<string, Xep.Jingle.ContentEncryption> encryptions = audio_encryptions ?? video_encryptions;

        Xep.Jingle.ContentEncryption? omemo_encryption = null, dtls_encryption = null, srtp_encryption = null;
        foreach (string encr_name in encryptions.keys) {
            if (video_encryptions != null && !video_encryptions.has_key(encr_name)) continue;

            var encryption = encryptions[encr_name];
            if (encryption.encryption_ns == "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification") {
                omemo_encryption = encryption;
            } else if (encryption.encryption_ns == Xep.JingleIceUdp.DTLS_NS_URI) {
                dtls_encryption = encryption;
            } else if (encryption.encryption_name == "SRTP") {
                srtp_encryption = encryption;
            }
        }

        if (omemo_encryption != null && dtls_encryption != null) {
            call.encryption = Encryption.OMEMO;
            omemo_encryption.peer_key = dtls_encryption.peer_key;
            omemo_encryption.our_key = dtls_encryption.our_key;
            audio_encryption = omemo_encryption;
            encryption_keys_same = true;
            video_encryption = video_encryptions != null ? video_encryptions["http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification"] : null;
        } else if (dtls_encryption != null) {
            call.encryption = Encryption.DTLS_SRTP;
            audio_encryption = dtls_encryption;
            video_encryption = video_encryptions != null ? video_encryptions[Xep.JingleIceUdp.DTLS_NS_URI] : null;
            encryption_keys_same = true;
            if (video_encryption != null && dtls_encryption.peer_key.length == video_encryption.peer_key.length) {
                for (int i = 0; i < dtls_encryption.peer_key.length; i++) {
                    if (dtls_encryption.peer_key[i] != video_encryption.peer_key[i]) {
                        encryption_keys_same = false;
                        break;
                    }
                }
            }
        } else if (srtp_encryption != null) {
            call.encryption = Encryption.SRTP;
            audio_encryption = srtp_encryption;
            video_encryption = video_encryptions != null ? video_encryptions["SRTP"] : null;
            encryption_keys_same = false;
        } else {
            call.encryption = Encryption.NONE;
            encryption_keys_same = true;
        }

        encryption_updated(audio_encryption, video_encryption);
    }
}

public class Dino.PeerContentInfo {
    public bool rtp_ready { get; set; }
    public bool rtcp_ready { get; set; }
    public ulong? bytes_sent { get; set; default=0; }
    public ulong? bytes_received { get; set; default=0; }
    public string? codec { get; set; }
    public uint32 clockrate { get; set; }
    public uint target_receive_bytes { get; set; default=-1; }
    public uint target_send_bytes { get; set; default=-1; }
    public bool show_bitrate_rows { get; set; default=true; }
    public string? transport_title { get; set; default=null; }
    public string? transport_status { get; set; default=null; }
    public string? control_title { get; set; default=null; }
    public string? control_status { get; set; default=null; }
    public string? diagnostics { get; set; default=null; }
}

public class Dino.PeerInfo {
    public PeerContentInfo? audio = null;
    public PeerContentInfo? video = null;
}
