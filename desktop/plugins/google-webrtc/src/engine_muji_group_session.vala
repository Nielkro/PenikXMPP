using Gee;
using Xmpp;

namespace Dino.Plugins.GoogleWebrtc {

public delegate bool EnginePeerBundleCapability(Jid peer_full_jid);

public interface EnginePeerBundleCapabilityResolver : Object {
    public abstract async bool supports_bundle_grouping(Jid peer_full_jid)
        throws Error;
}

private class EngineMujiPeerSignalHandlers : Object {
    public ulong failed = 0;
    public ulong rejected = 0;
    public ulong retracted = 0;
    public ulong ended = 0;
    public ulong remote_terminated = 0;
}

private class EngineMujiIncomingPeerFailure : Object {
    public Jid peer_full_jid { get; private set; }
    public string sid { get; private set; }
    public string message { get; private set; }

    public EngineMujiIncomingPeerFailure(
            Jid peer_full_jid, string sid, string message) {
        this.peer_full_jid = peer_full_jid;
        this.sid = sid;
        this.message = message;
    }
}

/**
 * Direct-Jingle peer-session owner for one already accepted MUJI room.
 *
 * Expectations are exact full-JID entries learned from ready MUJI presence.
 * The router may claim a previously unknown SID only through this owner.
 */
public class EngineMujiGroupSession : Dino.Plugins.MujiCallEngineGroupSession {
    private const string CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";
    private const uint32 MIN_GROUP_VIDEO_SUBSCRIBERS = 4;

    public Jid local_full_jid { get; private set; }
    public override Jid room_jid { get { return selected_room_jid; } }
    public uint64 logical_call_id { get; private set; }
    public bool video_requested { get; private set; }
    public override Xep.Muji.CodecProvider codec_provider {
        get { return selected_codec_provider; }
    }

    private EngineContext context;
    private Jid selected_room_jid;
    private Xep.Muji.CodecProvider selected_codec_provider;
    private EngineJmiSessionRouter router;
    private EngineJingleWireTransport wire_transport;
    private EngineJmiTransport jmi_transport;
    private Gee.List<EngineIceServer> ice_servers;
    private Native.NetworkPolicy network_policy;
    private EnginePeerBundleCapability? peer_bundle_capability = null;
    private EnginePeerBundleCapabilityResolver?
        peer_bundle_capability_resolver = null;
    private HashMap<string, bool> expected_peer_video =
        new HashMap<string, bool>();
    private HashMap<string, string> content_names_by_media =
        new HashMap<string, string>();
    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
        payload_types_by_media =
            new HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>();
    private bool conference_media_configured = false;
    private EngineJmiSession? prepared_adoption_session = null;
    private string? prepared_adoption_peer_key = null;
    private HashMap<string, string> preferred_content_names_by_media =
        new HashMap<string, string>();
    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
        preferred_payload_types_by_media =
            new HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>();
    private HashMap<string, EngineJmiSession> peer_sessions_by_sid =
        new HashMap<string, EngineJmiSession>();
    private HashMap<string, string> peer_sids = new HashMap<string, string>();
    private ArrayList<EngineJmiSession> peer_session_order =
        new ArrayList<EngineJmiSession>();
    private ArrayList<EngineJmiSession> deferred_incoming_peer_sessions =
        new ArrayList<EngineJmiSession>();
    private ArrayList<EngineMujiIncomingPeerFailure>
        deferred_incoming_peer_failures =
            new ArrayList<EngineMujiIncomingPeerFailure>();
    private bool incoming_peer_delivery_deferred = false;
    private HashMap<string, EngineMujiPeerSignalHandlers> peer_signal_handlers_by_sid =
        new HashMap<string, EngineMujiPeerSignalHandlers>();
    private HashMap<string, EngineSessionOwner> video_attachments_by_sid =
        new HashMap<string, EngineSessionOwner>();
    private EngineVideoEffectPipelineOwner? shared_video_pipeline = null;
    private ulong shared_video_effect_state_handler_id = 0;
    private Dino.Plugins.JmiVideoEffectCapabilities video_effect_capabilities =
        Dino.Plugins.JmiVideoEffectCapabilities.unavailable(Dino.Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY);
    private Dino.Plugins.JmiVideoEffectStatus video_effect_status =
        unavailable_video_effect_status(Dino.Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY);
    private EngineJmiSession? preview_publisher = null;
    private EngineVideoDeviceInfo? selected_video_device = null;
    private bool local_video_enabled = true;
    private bool video_disabled_by_codec_downgrade = false;
#if GOOGLE_WEBRTC_EFFECT_TEST
    private uint capture_start_attempt_count = 0;
    private bool capture_start_suppressed_for_test = false;
#endif
    private bool closed = false;

    internal signal void peer_session_created(EngineJmiSession session);
    internal signal void group_closed(EngineMujiGroupSession group);

    public EngineMujiGroupSession(
            EngineContext context,
            EngineJmiSessionRouter router,
            EngineJingleWireTransport wire_transport,
            EngineJmiTransport jmi_transport,
            Jid local_full_jid,
            Jid room_jid,
            uint64 logical_call_id,
            bool video_requested,
            Xep.Muji.CodecProvider codec_provider,
            Gee.List<EngineIceServer>? ice_servers = null,
            Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC) throws JmiError {
        if (local_full_jid.resourcepart == null) {
            throw new JmiError.BAD_STANZA("MUJI local address must be a full JID");
        }
        if (room_jid.resourcepart != null) {
            throw new JmiError.BAD_STANZA("MUJI room must be a bare JID");
        }
        if (logical_call_id == 0) {
            throw new JmiError.BAD_STATE("MUJI group requires a stable logical call id");
        }
        this.context = context;
        this.router = router;
        this.wire_transport = wire_transport;
        this.jmi_transport = jmi_transport;
        this.local_full_jid = local_full_jid;
        this.selected_room_jid = room_jid;
        this.logical_call_id = logical_call_id;
        this.video_requested = video_requested;
        this.selected_codec_provider = codec_provider;
        this.ice_servers = copy_ice_servers(ice_servers);
        this.network_policy = network_policy;

        if (video_requested) {
            try {
                Native.VideoEffectCapabilities capabilities =
                    context.get_video_effect_capabilities();
                if (capabilities.shared_pipeline_supported == 0 ||
                        capabilities.preview_publisher_supported == 0 ||
                        capabilities.max_subscribers < MIN_GROUP_VIDEO_SUBSCRIBERS) {
                    throw new JmiError.BAD_STATE(
                        "Google/libwebrtc does not support shared MUJI video fan-out");
                }
                shared_video_pipeline =
                    context.create_video_effect_pipeline(logical_call_id);
                EngineVideoEffectPipelineOwner pipeline = (!) shared_video_pipeline;
                Native.VideoEffectCapabilities effect_capabilities = pipeline.get_capabilities();
                video_effect_capabilities = VideoEffectConfigMapper.capabilities(effect_capabilities);
                shared_video_effect_state_handler_id = pipeline.state_changed.connect(() => {
                    if (closed || !effective_video_requested() || shared_video_pipeline != pipeline) return;
                    Native.VideoPipelineState state = {};
                    if (pipeline.get_cached_state(out state)) publish_video_effect_state(state);
                });
                video_effect_status = new Dino.Plugins.JmiVideoEffectStatus(
                    new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
                    Dino.Plugins.JmiVideoEffectApplyState.IDLE, 0, 0);
                Native.VideoPipelineState state = {};
                if (pipeline.get_cached_state(out state)) publish_video_effect_state(state);
            } catch (JmiError e) {
                throw e;
            } catch (Error e) {
                throw new JmiError.BAD_STATE(
                    "Cannot create shared Google/libwebrtc MUJI video pipeline: %s".printf(
                        e.message));
            }
        }
    }

    internal void set_peer_bundle_capability_resolver(
            EnginePeerBundleCapabilityResolver resolver) throws JmiError {
        require_open();
        if (!peer_session_order.is_empty) {
            throw new JmiError.BAD_STATE(
                "MUJI peer capability resolver must be set before peer sessions start");
        }
        peer_bundle_capability_resolver = resolver;
    }

    internal void set_peer_bundle_capability(
            owned EnginePeerBundleCapability capability) throws JmiError {
        require_open();
        if (!peer_session_order.is_empty) {
            throw new JmiError.BAD_STATE(
                "MUJI peer capability must be set before peer sessions start");
        }
        peer_bundle_capability = (owned) capability;
    }

    public override Dino.Plugins.JmiCallEngineSession start_outgoing_peer_session(
            Jid peer_full_jid, string sid,
            bool peer_video_requested) throws Error {
        require_open();
        require_conference_media_configured();
        require_full_peer(peer_full_jid);
        require_peer_video_available(peer_video_requested);
        string peer_key = peer_full_jid.to_string();
        if (peer_sids.has_key(peer_key)) {
            throw new JmiError.BAD_STATE("A MUJI peer session already exists for this full JID");
        }

        bool cached_bundle_support =
            peer_supports_bundle_grouping(peer_full_jid);
        EngineJmiSession session = new EngineJmiSession.muji_outgoing_with_bundle(
            context,
            wire_transport,
            jmi_transport,
            sid,
            logical_call_id,
            local_full_jid,
            peer_full_jid,
            room_jid,
            effective_content_names_by_media(peer_video_requested),
            effective_payload_types_by_media(peer_video_requested),
            peer_video_requested,
            ice_servers,
            network_policy,
            cached_bundle_support);
        router.add(session);
        try {
            track_peer_session(session);
            peer_session_created(session);
            if (cached_bundle_support ||
                    peer_bundle_capability_resolver == null) {
                session.start_muji_outgoing();
            } else {
                start_outgoing_after_bundle_capability_check.begin(session);
            }
        } catch (Error e) {
            forget_peer_session(session);
            router.remove(session);
            session.discard();
            throw e;
        }
        return session;
    }

    private async void start_outgoing_after_bundle_capability_check(
            EngineJmiSession session) {
        bool supports_bundle = false;
        EnginePeerBundleCapabilityResolver? resolver =
            peer_bundle_capability_resolver;
        if (resolver != null) {
            try {
                supports_bundle = yield ((!) resolver)
                    .supports_bundle_grouping(session.peer_jid);
            } catch (Error e) {
                debug(
                    "Google/libwebrtc MUJI BUNDLE discovery failed for %s: %s",
                    session.peer_jid.to_string(), e.message);
            }
        }

        if (closed || peer_sessions_by_sid[session.sid] != session) return;
        try {
            session.set_muji_bundle_grouping_enabled(supports_bundle);
            session.start_muji_outgoing();
        } catch (Error e) {
            session.report_start_failure(
                "Could not start the MUJI peer session: %s".printf(e.message));
        }
    }

    public override void prepare_peer_adoption(
            Jid peer_full_jid,
            Dino.Plugins.JmiCallEngineSession peer_session) throws Error {
        require_open();
        if (conference_media_configured || !peer_session_order.is_empty ||
                !expected_peer_video.is_empty ||
                prepared_adoption_session != null) {
            throw new JmiError.BAD_STATE(
                "MUJI peer adoption must be prepared before conference media");
        }
        EngineJmiSession engine_session = require_adoptable_session(
            peer_full_jid, peer_session);
        HashMap<string, string> names;
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> payloads;
        if (!engine_session.copy_initial_offer_conference_media(
                out names, out payloads)) {
            throw new JmiError.BAD_STATE(
                "Adopted 1:1 leg has no stable initial Jingle offer mapping");
        }
        if (!validate_adoption_media_shape(names, payloads)) {
            throw new JmiError.BAD_STANZA(
                "Adopted 1:1 leg media does not match the requested MUJI group");
        }
        preferred_content_names_by_media = copy_string_map(names);
        preferred_payload_types_by_media = copy_payload_map(payloads);
        if (!effective_video_requested()) {
            preferred_content_names_by_media.unset("video");
            preferred_payload_types_by_media.unset("video");
        }
        prepared_adoption_session = engine_session;
        prepared_adoption_peer_key = peer_full_jid.to_string();
    }

    public override bool copy_preferred_conference_media(
            out Gee.Map<string, string> content_names_by_media,
            out Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                payload_types_by_media) {
        content_names_by_media = copy_string_map(
            preferred_content_names_by_media);
        payload_types_by_media = copy_payload_map(
            preferred_payload_types_by_media);
        return prepared_adoption_session != null;
    }

    public override void adopt_peer_session(
            Jid peer_full_jid,
            Dino.Plugins.JmiCallEngineSession peer_session) throws Error {
        require_open();
        require_conference_media_configured();
        require_full_peer(peer_full_jid);
        EngineJmiSession engine_session = require_adoptable_session(
            peer_full_jid, peer_session);
        if (prepared_adoption_session != engine_session ||
                prepared_adoption_peer_key != peer_full_jid.to_string()) {
            throw new JmiError.BAD_STATE(
                "MUJI peer was not prepared before conference publication");
        }
        HashMap<string, string> current_names;
        HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>> current_payloads;
        if (!engine_session.copy_initial_offer_conference_media(
                out current_names, out current_payloads)) {
            throw new JmiError.BAD_STATE(
                "Adopted MUJI peer lost its Jingle offer mapping");
        }
        if (!effective_video_requested()) {
            current_names.unset("video");
            current_payloads.unset("video");
        }
        if (!conference_media_equals(current_names, current_payloads,
                content_names_by_media, payload_types_by_media)) {
            throw new JmiError.BAD_STANZA(
                "Adopted 1:1 leg does not match the frozen MUJI conference media");
        }

        string peer_key = peer_full_jid.to_string();
        if (peer_sids.has_key(peer_key) ||
                peer_sessions_by_sid.has_key(engine_session.sid)) {
            throw new JmiError.BAD_STATE("The MUJI group already owns this peer session");
        }
        bool was_expected = expected_peer_video.has_key(peer_key);
        bool expected_video = was_expected && expected_peer_video[peer_key];
        expected_peer_video.unset(peer_key);
        engine_session.disable_video_effects_for_group_call();
        try {
            track_peer_session(engine_session);
            peer_session_created(engine_session);
        } catch (Error e) {
            forget_peer_session(engine_session);
            if (was_expected) expected_peer_video[peer_key] = expected_video;
            throw e;
        }
        prepared_adoption_session = null;
        prepared_adoption_peer_key = null;
    }

    public override void expect_incoming_peer_session(
            Jid peer_full_jid, bool peer_video_requested) throws Error {
        require_open();
        require_conference_media_configured();
        require_full_peer(peer_full_jid);
        require_peer_video_available(peer_video_requested);
        string peer_key = peer_full_jid.to_string();
        if (peer_sids.has_key(peer_key)) {
            EngineJmiSession? existing =
                peer_sessions_by_sid[peer_sids[peer_key]];
            if (existing != null &&
                    deferred_incoming_peer_sessions.contains((!) existing)) {
                return;
            }
            throw new JmiError.BAD_STATE("A MUJI peer session already exists for this full JID");
        }
        expected_peer_video[peer_key] = peer_video_requested;
    }

    public override bool cancel_expected_incoming_peer_session(Jid peer_full_jid) {
        return expected_peer_video.unset(peer_full_jid.to_string());
    }

    public override void defer_incoming_peer_session_delivery() {
        if (!closed) incoming_peer_delivery_deferred = true;
    }

    public override void release_deferred_incoming_peer_sessions() {
        if (closed || !incoming_peer_delivery_deferred) return;
        incoming_peer_delivery_deferred = false;
        var pending = new ArrayList<EngineJmiSession>();
        pending.add_all(deferred_incoming_peer_sessions);
        deferred_incoming_peer_sessions.clear();
        foreach (EngineJmiSession session in pending) {
            if (peer_sessions_by_sid[session.sid] != session) continue;
            incoming_peer_session(session.peer_jid, session.sid, session);
        }
        var failures = new ArrayList<EngineMujiIncomingPeerFailure>();
        failures.add_all(deferred_incoming_peer_failures);
        deferred_incoming_peer_failures.clear();
        foreach (EngineMujiIncomingPeerFailure failure in failures) {
            incoming_peer_session_failed(
                failure.peer_full_jid, failure.sid, failure.message);
        }
    }

    public override void configure_conference_media(
            Gee.Map<string, string> selected_names,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
                selected_payloads) throws Error {
        require_open();
        if (conference_media_configured) {
            throw new JmiError.BAD_STATE(
                "MUJI conference media is already configured");
        }
        if (!peer_session_order.is_empty || !expected_peer_video.is_empty) {
            throw new JmiError.BAD_STATE(
                "MUJI conference media must be configured before peer legs");
        }

        bool expect_video = effective_video_requested();
        int expected_size = expect_video ? 2 : 1;
        if (selected_names.size != expected_size ||
                !selected_names.has_key("audio") ||
                (expect_video && !selected_names.has_key("video")) ||
                (!expect_video && selected_names.has_key("video"))) {
            throw new JmiError.BAD_STANZA(
                expect_video
                    ? "MUJI audio/video content identities are required"
                    : "MUJI audio content identity is required");
        }
        if (selected_payloads.size != expected_size ||
                !selected_payloads.has_key("audio") ||
                (expect_video && !selected_payloads.has_key("video")) ||
                (!expect_video && selected_payloads.has_key("video"))) {
            throw new JmiError.BAD_STANZA(
                expect_video
                    ? "MUJI audio/video payload maps are required"
                    : "MUJI audio payload map is required");
        }

        var unique_names = new HashSet<string>();
        foreach (var entry in selected_names.entries) {
            if ((entry.key != "audio" && entry.key != "video") ||
                    !is_content_name(entry.value) ||
                    !Xep.JingleRtp.LibwebrtcJingleAdapter
                        .is_supported_native_conference_mid(entry.value) ||
                    unique_names.contains(entry.value)) {
                throw new JmiError.BAD_STANZA(
                    "MUJI conference content identities must be unique SDP tokens within libwebrtc's 16-byte MID limit");
            }
            unique_names.add(entry.value);
        }

        var copied_payloads = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        foreach (var entry in selected_payloads.entries) {
            if ((entry.key != "audio" && entry.key != "video") ||
                    !selected_names.has_key(entry.key) ||
                    entry.value.is_empty) {
                throw new JmiError.BAD_STANZA(
                    "MUJI conference payload maps must cover configured media");
            }
            if (!Xep.JingleRtp.LibwebrtcJingleAdapter
                    .has_supported_conference_timing(entry.value)) {
                throw new JmiError.BAD_STANZA(
                    "MUJI conference packetization times must be consistent within each medium");
            }
            var media_payloads = new ArrayList<Xep.JingleRtp.PayloadType>(
                Xep.JingleRtp.PayloadType.equals_func);
            var media_payload_ids = new HashSet<int>();
            var media_rtx_payload_ids = new HashSet<int>();
            foreach (Xep.JingleRtp.PayloadType payload_type in entry.value) {
                if (!payload_type.id_valid || payload_type.id > 127 ||
                        payload_type.name == null ||
                        ((!) payload_type.name).strip() == "" ||
                        media_payload_ids.contains((int) payload_type.id)) {
                    throw new JmiError.BAD_STANZA(
                        "MUJI conference payload IDs must be unique per content");
                }
                media_payload_ids.add((int) payload_type.id);
                if (((!) payload_type.name).strip().ascii_down() == "rtx") {
                    media_rtx_payload_ids.add((int) payload_type.id);
                }
                media_payloads.add(payload_type.clone());
            }
            foreach (Xep.JingleRtp.PayloadType payload_type in media_payloads) {
                string? apt = payload_type.parameters["apt"];
                bool rtx = payload_type.name != null &&
                    ((!) payload_type.name).strip().ascii_down() == "rtx";
                if (!rtx) {
                    if (apt != null) {
                        throw new JmiError.BAD_STANZA(
                            "MUJI non-RTX payload must not carry apt");
                    }
                    continue;
                }
                int apt_id = -1;
                if (apt == null ||
                        !int.try_parse((!) apt, out apt_id, null, 10) ||
                        !media_payload_ids.contains(apt_id) ||
                        media_rtx_payload_ids.contains(apt_id) ||
                        apt_id == (int) payload_type.id) {
                    throw new JmiError.BAD_STANZA(
                        "MUJI conference RTX apt must target a payload in the same content");
                }
            }
            copied_payloads[entry.key] = media_payloads;
        }
        foreach (var entry in selected_names.entries) {
            content_names_by_media[entry.key] = entry.value;
        }
        foreach (var entry in copied_payloads.entries) {
            payload_types_by_media[entry.key] = entry.value;
        }
        if (prepared_adoption_session != null &&
                !conference_media_equals(
                    preferred_content_names_by_media,
                    preferred_payload_types_by_media,
                    content_names_by_media,
                    payload_types_by_media)) {
            content_names_by_media.clear();
            payload_types_by_media.clear();
            throw new JmiError.BAD_STANZA(
                "Selected MUJI media differs from the adopted 1:1 leg");
        }
        conference_media_configured = true;
    }

    public override void set_local_video_enabled(bool enabled) throws Error {
        require_open();
        if (!video_requested) {
            local_video_enabled = false;
            if (enabled) {
                throw new IOError.NOT_SUPPORTED(
                    "This MUJI group was created as audio-only");
            }
            return;
        }
        if (video_disabled_by_codec_downgrade && enabled) {
            throw new IOError.NOT_SUPPORTED(
                "MUJI video was permanently disabled after codec negotiation");
        }

        local_video_enabled = enabled && !video_disabled_by_codec_downgrade;
        apply_video_track_state_to_all(local_video_enabled);
        if (local_video_enabled) {
            ensure_shared_capture_started();
        } else {
            stop_shared_capture();
        }
    }

    public override void set_video_device(Dino.Plugins.MediaDevice device) throws Error {
        require_open();
        EngineVideoMediaDevice? engine_device = device as EngineVideoMediaDevice?;
        if (engine_device == null) {
            throw new EngineError.PROTOCOL(
                "Media device does not belong to the Google/libwebrtc engine");
        }
        selected_video_device = engine_device.info;
        if (effective_video_requested() && local_video_enabled &&
                preview_publisher != null) {
            // start_video_capture atomically replaces the pipeline-owned
            // capture, so a device change still opens at most one camera.
            start_shared_capture((!) engine_device.info);
        }
    }

    public override void disable_video_for_codec_downgrade() {
        if (video_disabled_by_codec_downgrade) return;
        video_disabled_by_codec_downgrade = true;
        local_video_enabled = false;

        apply_video_track_state_to_all(false);
        stop_shared_capture();
        close_shared_video_pipeline();
    }

    public override Dino.Plugins.JmiVideoEffectCapabilities get_video_effect_capabilities() {
        if (closed) return Dino.Plugins.JmiVideoEffectCapabilities.unavailable(
            Dino.Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED);
        if (!effective_video_requested()) return Dino.Plugins.JmiVideoEffectCapabilities.unavailable(
            Dino.Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY);
        return video_effect_capabilities;
    }

    public override Dino.Plugins.JmiVideoEffectStatus get_video_effect_status() {
        return video_effect_status;
    }

    public override async void release_video_background(uint asset_id) throws Error {
        EngineVideoEffectPipelineOwner? pipeline = shared_video_pipeline;
        if (pipeline != null) yield ((!) pipeline).release_background(asset_id);
    }

    public override async uint stage_video_background(uint builtin_choice,
            Dino.Plugins.JmiVideoBackgroundImage? image = null) throws Error {
        if (closed || !effective_video_requested() || shared_video_pipeline == null)
            throw new IOError.NOT_SUPPORTED("No live video pipeline is available");
        EngineVideoEffectPipelineOwner pipeline = (!) shared_video_pipeline;
        uint asset = yield pipeline.stage_background(builtin_choice, image);
        if (closed || !effective_video_requested() || shared_video_pipeline != pipeline) {
            try { yield pipeline.release_background(asset); } catch (Error ignored) { }
            throw new IOError.CANCELLED("The background image call owner changed");
        }
        return asset;
    }

    public override async uint64 select_video_effect(Dino.Plugins.JmiVideoEffectSelection selection) throws Error {
        require_open();
        require_conference_media_configured();
        if (!effective_video_requested() || shared_video_pipeline == null) {
            throw new IOError.NOT_SUPPORTED("Shared video effects require a live group video source");
        }
        Native.VideoEffectConfig config = VideoEffectConfigMapper.to_native(
            selection, video_effect_capabilities);
        EngineVideoEffectPipelineOwner pipeline = (!) shared_video_pipeline;
        uint64 revision = yield pipeline.select_config(config);
        if (closed || !effective_video_requested() || shared_video_pipeline != pipeline) {
            throw new IOError.CANCELLED("The shared group video pipeline changed");
        }
        Native.VideoPipelineState state = {};
        if (revision < video_effect_status.accepted_revision) return revision;
        if (pipeline.get_cached_state(out state) && state.applied_revision >= revision) {
            publish_video_effect_state(state);
        } else {
            video_effect_status = new Dino.Plugins.JmiVideoEffectStatus(selection,
                Dino.Plugins.JmiVideoEffectApplyState.ACCEPTED, revision, state.applied_revision);
            video_effect_status_changed(video_effect_status);
        }
        return revision;
    }

    private static Dino.Plugins.JmiVideoEffectStatus unavailable_video_effect_status(
            Dino.Plugins.JmiVideoEffectUnavailableReason reason) {
        return new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
            Dino.Plugins.JmiVideoEffectApplyState.UNAVAILABLE, 0, 0, reason);
    }

    private void publish_video_effect_state(Native.VideoPipelineState state) {
        if (closed || !effective_video_requested() || state.logical_call_id != logical_call_id ||
                state.accepted_revision < video_effect_status.accepted_revision ||
                state.applied_revision < video_effect_status.applied_revision) return;
        Dino.Plugins.JmiVideoEffectSelection selection;
        try {
            selection = VideoEffectConfigMapper.from_native(state);
        } catch (EngineError e) {
            warning("Invalid Google/libwebrtc group effect state: %s", e.message);
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

    internal void attach_peer_wire_session(
            EngineJmiSession session,
            EngineJingleWireSession wire_session) throws Error {
        require_open();
        if (peer_sessions_by_sid[session.sid] != session &&
                !peer_session_order.contains(session)) {
            // During adoption bind_muji_group_owner() runs immediately before
            // the peer is inserted in the maps. No unrelated session may use
            // this path, though.
            if (!session.local_full_jid.equals(local_full_jid) ||
                    !session.peer_jid.equals(wire_session.peer_full_jid)) {
                throw new JmiError.BAD_STATE(
                    "MUJI video attachment does not belong to this group");
            }
        }

        if (!effective_video_requested() || !session.video_requested) {
            session.apply_group_local_video_enabled(false);
            return;
        }
        EngineVideoEffectPipelineOwner? pipeline = shared_video_pipeline;
        if (pipeline == null) {
            throw new JmiError.BAD_STATE("Shared MUJI video pipeline is unavailable");
        }

        EngineSessionOwner engine = wire_session.session.engine;
        EngineSessionOwner? existing = video_attachments_by_sid[session.sid];
        if (existing != null) {
            if (existing != engine) {
                throw new JmiError.BAD_STATE(
                    "MUJI peer already has a different video attachment");
            }
            session.apply_group_local_video_enabled(local_video_enabled);
            return;
        }

        bool publish_preview = preview_publisher == null;
        ((!) pipeline).attach(engine, publish_preview);
        video_attachments_by_sid[session.sid] = engine;
        if (publish_preview) preview_publisher = session;

        try {
            session.apply_group_local_video_enabled(local_video_enabled);
            if (publish_preview && local_video_enabled) {
                // A promoted 1:1 call may already own a live camera. Native
                // attach transfers it into the pipeline; this state check is
                // what prevents a second open during adoption.
                ensure_shared_capture_started();
            }
        } catch (Error e) {
            detach_peer_wire_session(session, wire_session);
            throw e;
        }
    }

    internal void detach_peer_wire_session(
            EngineJmiSession session,
            EngineJingleWireSession wire_session) {
        EngineSessionOwner? attached = video_attachments_by_sid[session.sid];
        if (attached == null || attached != wire_session.session.engine) return;
        detach_video_attachment(session, (!) attached);
    }

    internal bool should_publish_local_preview(
            EngineJmiSession session,
            EngineSessionOwner engine) {
        return !closed && effective_video_requested() && local_video_enabled &&
            preview_publisher == session &&
            video_attachments_by_sid[session.sid] == engine;
    }

    internal void reapply_peer_video_state(EngineJmiSession session) {
        if (!peer_session_order.contains(session)) return;
        try {
            session.apply_group_local_video_enabled(
                effective_video_requested() && local_video_enabled);
        } catch (Error e) {
            warning(
                "Google/libwebrtc MUJI: cannot reapply local video track sid=%s: %s",
                session.sid, e.message);
        }
    }

    internal bool expects_incoming(
            Jid candidate_local_full_jid,
            Jid peer_full_jid,
            Jid candidate_room_jid,
            string sid) {
        if (closed || sid.strip() == "") return false;
        if (!candidate_local_full_jid.equals(local_full_jid) ||
                !candidate_room_jid.equals(room_jid)) return false;
        if (peer_full_jid.resourcepart == null) return false;
        string peer_key = peer_full_jid.to_string();
        return expected_peer_video.has_key(peer_key) &&
            !peer_sids.has_key(peer_key) &&
            !peer_sessions_by_sid.has_key(sid) &&
            !router.contains(local_full_jid, sid);
    }

    internal EngineJmiSession claim_incoming(Iq.Stanza iq, string sid) throws Error {
        require_open();
        require_conference_media_configured();
        if (iq.from == null) {
            throw new JmiError.BAD_STANZA("MUJI session-initiate has no sender");
        }
        Jid peer_full_jid = (!) iq.from;
        if (!expects_incoming(local_full_jid, peer_full_jid, room_jid, sid)) {
            throw new JmiError.BAD_STANZA("MUJI session-initiate was not expected for this peer");
        }

        bool peer_video_requested = expected_peer_video[peer_full_jid.to_string()];
        EngineJmiSession session = new EngineJmiSession.muji_incoming(
            context,
            wire_transport,
            jmi_transport,
            sid,
            logical_call_id,
            local_full_jid,
            peer_full_jid,
            room_jid,
            effective_content_names_by_media(peer_video_requested),
            effective_payload_types_by_media(peer_video_requested),
            peer_video_requested,
            ice_servers,
            network_policy);
        router.add(session);
        try {
            track_peer_session(session);
            peer_session_created(session);
        } catch (Error e) {
            forget_peer_session(session);
            router.remove(session);
            session.discard();
            throw e;
        }
        return session;
    }

    internal void complete_incoming_claim(EngineJmiSession session) {
        expected_peer_video.unset(session.peer_jid.to_string());
        if (incoming_peer_delivery_deferred) {
            deferred_incoming_peer_sessions.add(session);
        } else {
            incoming_peer_session(session.peer_jid, session.sid, session);
        }
    }

    internal void abort_incoming_claim(
            EngineJmiSession session, string message) {
        Jid peer_full_jid = session.peer_jid;
        string failed_sid = session.sid;
        expected_peer_video.unset(peer_full_jid.to_string());
        forget_peer_session(session);
        router.remove(session);
        session.discard();
        var failure = new EngineMujiIncomingPeerFailure(
            peer_full_jid, failed_sid, message);
        if (incoming_peer_delivery_deferred) {
            deferred_incoming_peer_failures.add(failure);
        } else {
            incoming_peer_session_failed(
                peer_full_jid, failed_sid, message);
        }
    }

    internal bool reject_expected_incoming(Jid peer_full_jid,
            string sid, string message) {
        if (!expects_incoming(local_full_jid, peer_full_jid, room_jid, sid)) return false;
        expected_peer_video.unset(peer_full_jid.to_string());
        var failure = new EngineMujiIncomingPeerFailure(peer_full_jid, sid, message);
        if (incoming_peer_delivery_deferred) {
            deferred_incoming_peer_failures.add(failure);
        } else {
            incoming_peer_session_failed(peer_full_jid, sid, message);
        }
        return true;
    }

    public override void close() {
        if (closed) return;
        closed = true;
        router.remove_muji_group(this);
        expected_peer_video.clear();

        var snapshot = new ArrayList<EngineJmiSession>();
        snapshot.add_all(peer_sessions_by_sid.values);

        // Ownership order is deliberate: stop capture and all video tracks,
        // then close the shared pipeline, and only then tear down peer legs.
        apply_video_track_state_to_all(false);
        stop_shared_capture();
        close_shared_video_pipeline();
        foreach (EngineJmiSession session in snapshot) {
            disconnect_peer_session_signals(session);
            session.unbind_muji_group_owner(this);
        }
        peer_sessions_by_sid.clear();
        peer_sids.clear();
        peer_session_order.clear();
        deferred_incoming_peer_sessions.clear();
        deferred_incoming_peer_failures.clear();
        incoming_peer_delivery_deferred = false;
        peer_signal_handlers_by_sid.clear();
        prepared_adoption_session = null;
        peer_bundle_capability_resolver = null;
        prepared_adoption_peer_key = null;
        preferred_content_names_by_media.clear();
        preferred_payload_types_by_media.clear();
        peer_bundle_capability = null;
        foreach (EngineJmiSession session in snapshot) {
            router.remove(session);
            try {
                session.end(Xep.Jingle.ReasonElement.CANCEL, "MUJI group ended");
            } catch (Error e) {
                session.discard();
            }
        }
        group_closed(this);
    }

    ~EngineMujiGroupSession() {
        close();
    }

    private void track_peer_session(EngineJmiSession session) throws Error {
        session.bind_muji_group_owner(this);
        peer_sessions_by_sid[session.sid] = session;
        peer_sids[session.peer_jid.to_string()] = session.sid;
        peer_session_order.add(session);
        var handlers = new EngineMujiPeerSignalHandlers();
        handlers.failed = session.failed.connect((message) => {
            retire_failed_peer_session(session, message);
        });
        handlers.rejected = session.rejected.connect(() => {
            retire_terminal_peer_session(session,
                "Incoming MUJI peer session was rejected before publication");
        });
        handlers.retracted = session.retracted.connect(() => {
            retire_terminal_peer_session(session,
                "Incoming MUJI peer session was retracted before publication");
        });
        handlers.ended = session.ended.connect(() => {
            retire_terminal_peer_session(session,
                "Incoming MUJI peer session ended before publication");
        });
        handlers.remote_terminated = session.remote_terminated.connect(
                (reason_name, reason_text) => {
            string message = reason_text ?? reason_name ??
                "Incoming MUJI peer session was terminated before publication";
            retire_terminal_peer_session(session, message);
        });
        peer_signal_handlers_by_sid[session.sid] = handlers;
    }

    private void retire_failed_peer_session(
            EngineJmiSession session, string message) {
        publish_undelivered_peer_failure(session, message);
        forget_peer_session(session);
        router.remove(session);
        session.discard();
    }

    private void retire_terminal_peer_session(
            EngineJmiSession session, string message) {
        bool was_undelivered =
            publish_undelivered_peer_failure(session, message);
        forget_peer_session(session);
        if (was_undelivered) {
            router.remove(session);
            session.close();
        }
    }

    private bool publish_undelivered_peer_failure(
            EngineJmiSession session, string message) {
        if (!deferred_incoming_peer_sessions.contains(session)) return false;
        var failure = new EngineMujiIncomingPeerFailure(
            session.peer_jid, session.sid, message);
        if (incoming_peer_delivery_deferred) {
            deferred_incoming_peer_failures.add(failure);
        } else {
            incoming_peer_session_failed(
                failure.peer_full_jid, failure.sid, failure.message);
        }
        return true;
    }

    private void forget_peer_session(EngineJmiSession session) {
        disconnect_peer_session_signals(session);
        detach_peer_session(session);
        deferred_incoming_peer_sessions.remove(session);
        peer_sessions_by_sid.unset(session.sid);
        peer_session_order.remove(session);
        string peer_key = session.peer_jid.to_string();
        if (peer_sids[peer_key] == session.sid) {
            peer_sids.unset(peer_key);
        }
        session.unbind_muji_group_owner(this);
    }

    private void disconnect_peer_session_signals(EngineJmiSession session) {
        EngineMujiPeerSignalHandlers? handlers =
            peer_signal_handlers_by_sid[session.sid];
        if (handlers == null) return;
        peer_signal_handlers_by_sid.unset(session.sid);
        disconnect_peer_signal(session, ((!) handlers).failed);
        disconnect_peer_signal(session, ((!) handlers).rejected);
        disconnect_peer_signal(session, ((!) handlers).retracted);
        disconnect_peer_signal(session, ((!) handlers).ended);
        disconnect_peer_signal(session, ((!) handlers).remote_terminated);
    }

    private static void disconnect_peer_signal(
            EngineJmiSession session, ulong handler_id) {
        if (handler_id != 0 && SignalHandler.is_connected(session, handler_id)) {
            SignalHandler.disconnect(session, handler_id);
        }
    }

    private bool effective_video_requested() {
        return video_requested && !video_disabled_by_codec_downgrade;
    }

    private EngineJmiSession require_adoptable_session(
            Jid peer_full_jid,
            Dino.Plugins.JmiCallEngineSession peer_session)
            throws JmiError {
        require_full_peer(peer_full_jid);
        EngineJmiSession? session = peer_session as EngineJmiSession?;
        if (session == null) {
            throw new JmiError.BAD_STATE(
                "Cannot mix a non-Google media session into a Google/libwebrtc MUJI group");
        }
        EngineJmiSession engine_session = (!) session;
        if (engine_session.context != context) {
            throw new JmiError.BAD_STATE(
                "Adopted MUJI peer must use the group's Google/libwebrtc context");
        }
        if (!engine_session.local_full_jid.equals(local_full_jid) ||
                !engine_session.peer_jid.equals(peer_full_jid)) {
            throw new JmiError.BAD_STANZA(
                "Adopted MUJI peer does not match group JIDs " +
                "(session=%s->%s group=%s->%s)".printf(
                    engine_session.local_full_jid.to_string(),
                    engine_session.peer_jid.to_string(),
                    local_full_jid.to_string(),
                    peer_full_jid.to_string()));
        }
        if (engine_session.wire_session == null ||
                engine_session.jmi_state == JmiState.ENDED ||
                engine_session.jmi_state == JmiState.REJECTED ||
                engine_session.jmi_state == JmiState.RETRACTED) {
            throw new JmiError.BAD_STATE(
                "Only a live Google/libwebrtc peer leg can be adopted by MUJI");
        }
        return engine_session;
    }

    private bool validate_adoption_media_shape(
            Gee.Map<string, string> names,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> payloads) {
        if (!names.has_key("audio") || !payloads.has_key("audio") ||
                payloads["audio"].is_empty || names.size != payloads.size) {
            return false;
        }
        bool has_video_name = names.has_key("video");
        bool has_video_payload = payloads.has_key("video") &&
            !payloads["video"].is_empty;
        if (has_video_name != has_video_payload ||
                has_video_name != effective_video_requested()) {
            return false;
        }
        foreach (string media in names.keys) {
            if ((media != "audio" && media != "video") ||
                    !payloads.has_key(media) || payloads[media].is_empty) {
                return false;
            }
        }
        return true;
    }

    private static bool conference_media_equals(
            Gee.Map<string, string> left_names,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> left_payloads,
            Gee.Map<string, string> right_names,
            Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> right_payloads) {
        if (left_names.size != right_names.size ||
                left_payloads.size != right_payloads.size ||
                left_names.size != left_payloads.size) return false;
        foreach (var entry in left_names.entries) {
            if (!right_names.has_key(entry.key) ||
                    right_names[entry.key] != entry.value ||
                    !left_payloads.has_key(entry.key) ||
                    !right_payloads.has_key(entry.key)) return false;
            Gee.List<Xep.JingleRtp.PayloadType> left =
                left_payloads[entry.key];
            Gee.List<Xep.JingleRtp.PayloadType> right =
                right_payloads[entry.key];
            if (left.size != right.size ||
                    !left.contains_all(right) ||
                    !right.contains_all(left)) return false;
        }
        return true;
    }

    private void require_conference_media_configured() throws JmiError {
        if (!conference_media_configured) {
            throw new JmiError.BAD_STATE(
                "MUJI conference media is not configured");
        }
    }

    private void require_peer_video_available(bool peer_video_requested)
            throws JmiError {
        if (peer_video_requested && !effective_video_requested()) {
            throw new JmiError.BAD_STATE(
                "MUJI peer video is unavailable for this group");
        }
    }

    private static bool is_content_name(string? value) {
        return value != null && ((!) value).length > 0;
    }

    private HashMap<string, string> effective_content_names_by_media(
            bool peer_video_requested) {
        var selected = new HashMap<string, string>();
        selected["audio"] = content_names_by_media["audio"];
        if (peer_video_requested) {
            selected["video"] = content_names_by_media["video"];
        }
        return selected;
    }

    private HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
            effective_payload_types_by_media(bool peer_video_requested) {
        var selected = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        selected["audio"] = clone_payload_types(
            payload_types_by_media["audio"]);
        if (peer_video_requested) {
            selected["video"] = clone_payload_types(
                payload_types_by_media["video"]);
        }
        return selected;
    }

    private static Gee.List<Xep.JingleRtp.PayloadType> clone_payload_types(
            Gee.List<Xep.JingleRtp.PayloadType> source) {
        var copy = new ArrayList<Xep.JingleRtp.PayloadType>(
            Xep.JingleRtp.PayloadType.equals_func);
        foreach (Xep.JingleRtp.PayloadType payload_type in source) {
            copy.add(payload_type.clone());
        }
        return copy;
    }

    private static HashMap<string, string> copy_string_map(
            Gee.Map<string, string> source) {
        var copy = new HashMap<string, string>();
        foreach (var entry in source.entries) {
            copy[entry.key] = entry.value;
        }
        return copy;
    }

    private static HashMap<string, Gee.List<Xep.JingleRtp.PayloadType>>
            copy_payload_map(
                Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>> source) {
        var copy = new HashMap<string,
            Gee.List<Xep.JingleRtp.PayloadType>>();
        foreach (var entry in source.entries) {
            copy[entry.key] = clone_payload_types(entry.value);
        }
        return copy;
    }

    private void apply_video_track_state_to_all(bool enabled) {
        foreach (EngineJmiSession session in peer_session_order) {
            try {
                session.apply_group_local_video_enabled(enabled);
            } catch (Error e) {
                warning(
                    "Google/libwebrtc MUJI: cannot set local video track sid=%s enabled=%s: %s",
                    session.sid, enabled.to_string(), e.message);
            }
        }
    }

    private void ensure_shared_capture_started() {
        if (!effective_video_requested() || !local_video_enabled ||
                preview_publisher == null) return;
        EngineJmiSession publisher = (!) preview_publisher;
        try {
            if (publisher.group_video_capture_running()) return;
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc MUJI: cannot read shared capture state sid=%s: %s",
                    publisher.sid, e.message);
            }
        }

        EngineVideoDeviceInfo? camera = selected_video_device;
        if (camera == null) {
            try {
                Gee.List<EngineVideoDeviceInfo> cameras = context.get_video_devices();
                if (!cameras.is_empty) camera = cameras[0];
            } catch (Error e) {
                if (call_debug_enabled()) {
                    warning(
                        "Google/libwebrtc MUJI: cannot enumerate cameras: %s",
                        e.message);
                }
            }
        }
        if (camera != null) start_shared_capture((!) camera);
    }

    private void start_shared_capture(EngineVideoDeviceInfo camera) {
        if (!effective_video_requested() || !local_video_enabled ||
                preview_publisher == null) return;
        EngineJmiSession publisher = (!) preview_publisher;
#if GOOGLE_WEBRTC_EFFECT_TEST
        capture_start_attempt_count++;
        if (capture_start_suppressed_for_test) return;
#endif
        try {
            publisher.start_group_video_capture(camera);
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc MUJI: started shared camera sid=%s device=%s",
                    publisher.sid, camera.display_name);
            }
        } catch (Error e) {
            if (call_debug_enabled()) {
                warning(
                    "Google/libwebrtc MUJI: shared camera unavailable sid=%s: %s",
                    publisher.sid, e.message);
            }
        }
    }

    private void stop_shared_capture() {
        if (preview_publisher == null) return;
        EngineJmiSession publisher = (!) preview_publisher;
        EngineSessionOwner? engine = video_attachments_by_sid[publisher.sid];
        if (engine != null && ((!) engine).is_closed) return;
        try {
            publisher.stop_group_video_capture();
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc MUJI: shared capture already stopped sid=%s: %s",
                    publisher.sid, e.message);
            }
        }
    }

    private void detach_peer_session(EngineJmiSession session) {
        EngineSessionOwner? engine = video_attachments_by_sid[session.sid];
        if (engine != null) detach_video_attachment(session, (!) engine);
    }

    private void detach_video_attachment(
            EngineJmiSession session,
            EngineSessionOwner engine) {
        bool was_publisher = preview_publisher == session;
        if (was_publisher) stop_shared_capture();

        EngineVideoEffectPipelineOwner? pipeline = shared_video_pipeline;
        if (pipeline != null) {
            try {
                ((!) pipeline).detach_session(engine);
            } catch (Error e) {
                if (call_debug_enabled()) {
                    warning(
                        "Google/libwebrtc MUJI: cannot detach video leg sid=%s: %s",
                        session.sid, e.message);
                }
            }
        }
        video_attachments_by_sid.unset(session.sid);
        if (!was_publisher) return;

        preview_publisher = null;
        if (closed || !effective_video_requested() || pipeline == null) return;
        foreach (EngineJmiSession candidate in peer_session_order) {
            if (candidate == session) continue;
            EngineSessionOwner? candidate_engine =
                video_attachments_by_sid[candidate.sid];
            if (candidate_engine == null) continue;
            try {
                ((!) pipeline).attach((!) candidate_engine, true);
                preview_publisher = candidate;
                if (local_video_enabled) ensure_shared_capture_started();
                break;
            } catch (Error e) {
                warning(
                    "Google/libwebrtc MUJI: cannot promote preview publisher sid=%s: %s",
                    candidate.sid, e.message);
            }
        }
    }

    private void close_shared_video_pipeline() {
        EngineVideoEffectPipelineOwner? pipeline = shared_video_pipeline;
        shared_video_pipeline = null;
        if (pipeline != null && shared_video_effect_state_handler_id != 0 &&
                SignalHandler.is_connected(pipeline, shared_video_effect_state_handler_id)) {
            pipeline.disconnect(shared_video_effect_state_handler_id);
        }
        shared_video_effect_state_handler_id = 0;
        Dino.Plugins.JmiVideoEffectUnavailableReason reason = closed
            ? Dino.Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED
            : Dino.Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY;
        video_effect_capabilities = Dino.Plugins.JmiVideoEffectCapabilities.unavailable(reason);
        video_effect_status = unavailable_video_effect_status(reason);
        video_effect_status_changed(video_effect_status);
        preview_publisher = null;
        video_attachments_by_sid.clear();
        // Pipeline close retains its own strong session references until
        // native destruction and the preview fence finish on the control
        // worker. Never synchronously detach peers through worker IPC here.
        if (pipeline != null) ((!) pipeline).close();
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    internal EngineJmiSession start_peer_without_offer_for_test(
            Jid peer_full_jid, string sid) throws Error {
        require_open();
        require_conference_media_configured();
        require_full_peer(peer_full_jid);
        string peer_key = peer_full_jid.to_string();
        if (peer_sids.has_key(peer_key)) {
            throw new JmiError.BAD_STATE(
                "A MUJI peer session already exists for this full JID");
        }
        EngineJmiSession session = new EngineJmiSession.muji_outgoing_with_bundle(
            context,
            wire_transport,
            jmi_transport,
            sid,
            logical_call_id,
            local_full_jid,
            peer_full_jid,
            room_jid,
            effective_content_names_by_media(effective_video_requested()),
            effective_payload_types_by_media(effective_video_requested()),
            effective_video_requested(),
            ice_servers,
            network_policy,
            peer_supports_bundle_grouping(peer_full_jid));
        router.add(session);
        try {
            track_peer_session(session);
            peer_session_created(session);
            session.start_muji_wire_without_offer_for_test();
        } catch (Error e) {
            forget_peer_session(session);
            router.remove(session);
            session.discard();
            throw e;
        }
        return session;
    }

    internal int video_attachment_count_for_test() {
        return video_attachments_by_sid.size;
    }

    internal string? preview_publisher_sid_for_test() {
        return preview_publisher != null ? ((!) preview_publisher).sid : null;
    }

    internal uint capture_start_attempt_count_for_test() {
        return capture_start_attempt_count;
    }

    internal bool shared_video_pipeline_open_for_test() {
        return shared_video_pipeline != null;
    }

    internal EngineVideoEffectPipelineOwner? shared_video_pipeline_for_test() {
        return shared_video_pipeline;
    }

    internal bool video_disabled_by_codec_for_test() {
        return video_disabled_by_codec_downgrade;
    }

    internal bool local_video_enabled_for_test() {
        return local_video_enabled;
    }

    internal void suppress_capture_start_for_test() {
        capture_start_suppressed_for_test = true;
    }

    internal void push_preview_synthetic_frame_for_test(int width, int height) throws Error {
        if (preview_publisher == null) {
            throw new JmiError.BAD_STATE("MUJI group has no preview publisher");
        }
        ((!) preview_publisher).push_group_synthetic_video_frame(width, height);
    }
#endif

    private void require_open() throws JmiError {
        if (closed) {
            throw new JmiError.BAD_STATE("MUJI group session is closed");
        }
    }

    private bool peer_supports_bundle_grouping(Jid peer_full_jid) {
        return peer_bundle_capability != null &&
            ((!) peer_bundle_capability)(peer_full_jid);
    }

    private static void require_full_peer(Jid peer_full_jid) throws JmiError {
        if (peer_full_jid.resourcepart == null) {
            throw new JmiError.BAD_STANZA("MUJI peer address must be a full JID");
        }
    }

    private static Gee.List<EngineIceServer> copy_ice_servers(
            Gee.List<EngineIceServer>? source) {
        var ret = new ArrayList<EngineIceServer>();
        if (source != null) ret.add_all((!) source);
        return ret;
    }

    private static bool call_debug_enabled() {
        string? enabled = Environment.get_variable(CALL_DEBUG_ENV);
        return enabled == "1" || enabled == "true" || enabled == "yes";
    }
}

}
