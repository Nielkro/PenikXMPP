using Gee;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

private class PluginSessionSignalHandlers : Object {
    public ulong wire_session_started = 0;
    public ulong active = 0;
    public ulong failed = 0;
    public ulong rejected = 0;
    public ulong retracted = 0;
    public ulong ended = 0;
    public ulong remote_terminated = 0;
}

private class XmppEnginePeerBundleCapabilityResolver : Object,
        EnginePeerBundleCapabilityResolver {
    private Account account;
    private Dino.EntityInfo entity_info;

    public XmppEnginePeerBundleCapabilityResolver(
            Account account, Dino.EntityInfo entity_info) {
        this.account = account;
        this.entity_info = entity_info;
    }

    public async bool supports_bundle_grouping(Jid peer_full_jid)
            throws Error {
        if (yield entity_info.has_feature(
                account,
                peer_full_jid,
                MUJI_BUNDLE_DISCO_FEATURE)) {
            return true;
        }
        return yield entity_info.has_feature(
            account, peer_full_jid, JINGLE_GROUPING_DISCO_FEATURE);
    }
}

public class Plugin : RootInterface, JmiCallEnginePlugin, MujiCallEnginePlugin,
        Xep.Muji.CodecProvider, Object {
    private const string CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";
    private const string AUDIO_DEVICE_ENV = "DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE";
    private const uint ACTIVE_DIAGNOSTICS_DELAY_MS = 3000;
    private const uint LATE_DIAGNOSTICS_DELAY_MS = 10000;
    private const uint STARTUP_STABLE_DIAGNOSTICS_DELAY_MS = 15000;

    public string engine_id { get { return "google-libwebrtc"; } }
    public string group_engine_id { get { return "google-libwebrtc"; } }
    public Dino.Application? app { get; private set; }

    private EngineJmiSessionRouter router = new EngineJmiSessionRouter();
    private EngineJmiIqInterceptor? iq_interceptor = null;
    private ArrayList<XmppStream> interceptor_streams = new ArrayList<XmppStream>();
    private ArrayList<EngineJmiSession> sessions = new ArrayList<EngineJmiSession>();
    private HashMap<EngineJmiSession, PluginSessionSignalHandlers> session_signal_handlers =
        new HashMap<EngineJmiSession, PluginSessionSignalHandlers>();
    private ArrayList<EngineMujiGroupSession> muji_groups =
        new ArrayList<EngineMujiGroupSession>();
    private HashMap<string, Gee.List<JingleRtp.PayloadType>> muji_payload_cache =
        new HashMap<string, Gee.List<JingleRtp.PayloadType>>();
    private EngineContext? context = null;
    private ulong context_idle_handler_id = 0;
    private Mutex context_mutex = Mutex();
    private bool group_video_capability_known = false;
    private bool group_video_capability_available = false;
#if GOOGLE_WEBRTC_EFFECT_TEST
    private uint context_creation_count = 0;
#endif
    private bool shutting_down = false;
    private bool context_restart_required = false;
    // Logical call owners cover the signaling-only interval before a JMI
    // proposal owns its first native PeerConnection lease. Registrations cover
    // the narrow construction interval before the session/group is tracked.
    // Both counters are protected by context_mutex and prevent deferred worker
    // retirement from racing a newly created 1:1 or MUJI call.
    private uint tracked_call_context_owners = 0;
    private uint pending_call_context_registrations = 0;
    private Dino.Plugins.MediaMessageRecorderProvider? media_message_recorder_provider = null;
    private GoogleWebrtcMediaMessagePlaybackProvider? media_message_playback_provider = null;
    private ulong media_message_playback_failed_handler_id = 0;
    private ulong stream_attached_handler_id = 0;
    private ulong stream_negotiated_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    private HashMap<Account, Gee.List<EngineIceServer>> ice_servers_by_account = new HashMap<Account, Gee.List<EngineIceServer>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, uint> ice_server_refresh_timeouts = new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashMap<Account, int64?> extdisco_warning_timestamps = new HashMap<Account, int64?>(Account.hash_func, Account.equals_func);
    private uint microphone_volume_diagnostics_timeout_id = 0;
    private uint speaker_volume_diagnostics_timeout_id = 0;
    private double pending_microphone_volume = 1.0;
    private double pending_speaker_volume = 1.0;
    private EngineContextActivityLease? audio_test_playback_lease = null;
    private EngineContext? audio_test_playback_context = null;

    public Plugin() {
    }

    public void registered(Dino.Application app) {
        context_mutex.lock();
        shutting_down = false;
        context_restart_required = false;
        tracked_call_context_owners = 0;
        pending_call_context_registrations = 0;
        group_video_capability_known = false;
        group_video_capability_available = false;
        context_mutex.unlock();
        this.app = app;
        media_message_recorder_provider = new GoogleWebrtcMediaMessageRecorderProvider(
            () => {
                return ensure_context();
            },
            () => {
                return app.settings.msg_audio_input_device;
            },
            () => {
                return app.settings.msg_video_device;
            });
        app.plugin_registry.register_media_message_recorder_provider((!) media_message_recorder_provider);
        media_message_playback_provider = new GoogleWebrtcMediaMessagePlaybackProvider(
            () => {
                return create_isolated_media_context();
            },
            () => {
                return app.settings.msg_audio_output_device;
            }, true);
        media_message_playback_failed_handler_id =
            ((!) media_message_playback_provider).playback_failed.connect((message) => {
                // Playback owns a separate worker. Its failure must not retire
                // the worker that owns an unrelated 1:1 or MUJI call.
                debug("Google/libwebrtc isolated media playback failed: %s", message);
            });
        app.plugin_registry.register_media_message_playback_provider((!) media_message_playback_provider);
        app.plugin_registry.jmi_call_engine_plugin = this;
        app.plugin_registry.muji_call_engine_plugin = this;
        stream_attached_handler_id = app.stream_interactor.stream_attached_modules.connect(on_stream_attached_modules);
        stream_negotiated_handler_id = app.stream_interactor.stream_negotiated.connect(refresh_ice_servers);
        account_removed_handler_id = app.stream_interactor.account_removed.connect(on_account_removed);
        debug("Google/libwebrtc process-isolated media engine loaded");
        EngineAudioDeviceMode mode = runtime_audio_device_mode();
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call engine registered audio-device=%s ownership=registered-sid-only",
                audio_device_mode_to_string(mode));
        }
        foreach (Account account in app.stream_interactor.get_accounts()) {
            XmppStream? stream = app.stream_interactor.get_stream(account);
            if (stream != null) {
                on_stream_attached_modules(account, (!) stream);
                refresh_ice_servers.begin(account, (!) stream);
            }
        }
    }

    public void shutdown() {
        context_mutex.lock();
        shutting_down = true;
        context_mutex.unlock();
        if (app != null && stream_attached_handler_id != 0) {
            ((!) app).stream_interactor.disconnect(stream_attached_handler_id);
            stream_attached_handler_id = 0;
        }
        if (app != null && stream_negotiated_handler_id != 0) {
            ((!) app).stream_interactor.disconnect(stream_negotiated_handler_id);
            stream_negotiated_handler_id = 0;
        }
        if (app != null && account_removed_handler_id != 0) {
            ((!) app).stream_interactor.disconnect(account_removed_handler_id);
            account_removed_handler_id = 0;
        }
        if (app != null && ((!) app).plugin_registry.jmi_call_engine_plugin == this) {
            ((!) app).plugin_registry.jmi_call_engine_plugin = null;
        }
        if (app != null && ((!) app).plugin_registry.muji_call_engine_plugin == this) {
            ((!) app).plugin_registry.muji_call_engine_plugin = null;
        }
        if (app != null &&
                media_message_recorder_provider != null &&
                ((!) app).plugin_registry.media_message_recorder_provider == media_message_recorder_provider) {
            ((!) app).plugin_registry.media_message_recorder_provider = null;
        }
        media_message_recorder_provider = null;
        if (media_message_playback_provider != null) {
            ((!) media_message_playback_provider).stop_current_session();
            if (media_message_playback_failed_handler_id != 0 &&
                    SignalHandler.is_connected(
                        (!) media_message_playback_provider,
                        media_message_playback_failed_handler_id)) {
                SignalHandler.disconnect(
                    (!) media_message_playback_provider,
                    media_message_playback_failed_handler_id);
            }
        }
        media_message_playback_failed_handler_id = 0;
        if (app != null &&
                media_message_playback_provider != null &&
                ((!) app).plugin_registry.media_message_playback_provider == media_message_playback_provider) {
            ((!) app).plugin_registry.media_message_playback_provider = null;
        }
        media_message_playback_provider = null;

        foreach (XmppStream stream in interceptor_streams) {
            Iq.Module? iq_module = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
            if (iq_module != null && iq_interceptor != null) {
                ((!) iq_module).unregister_interceptor_from_namespace(Jingle.NS_URI, (!) iq_interceptor);
            }
            Xep.Muji.Module? muji_module = stream.get_module<Xep.Muji.Module>(
                Xep.Muji.Module.IDENTITY);
            if (muji_module != null) {
                ((!) muji_module).unregister_codec_provider(stream, this);
            }
            remove_call_disco_features(stream);
        }
        interceptor_streams.clear();

        var muji_groups_snapshot = new ArrayList<EngineMujiGroupSession>();
        muji_groups_snapshot.add_all(muji_groups);
        foreach (EngineMujiGroupSession group in muji_groups_snapshot) {
            group.close();
        }
        muji_groups.clear();

        ArrayList<EngineJmiSession> sessions_snapshot = new ArrayList<EngineJmiSession>();
        sessions_snapshot.add_all(sessions);
        foreach (EngineJmiSession session in sessions_snapshot) {
            release_session(session);
        }
        sessions.clear();
        session_signal_handlers.clear();
        cancel_audio_volume_diagnostics();
        try {
            stop_audio_test_playout();
        } catch (Error e) {
            debug("Could not stop Google/libwebrtc device-test playback during shutdown: %s", e.message);
        }
        clear_all_ice_server_refresh_timeouts();
        ice_servers_by_account.clear();
        extdisco_warning_timestamps.clear();
        muji_payload_cache.clear();

        EngineContext? context_to_close = null;
        context_mutex.lock();
        if (context != null) {
            context_to_close = (!) context;
            disconnect_context_idle_handler_locked((!) context);
            context = null;
        }
        context_restart_required = false;
        tracked_call_context_owners = 0;
        pending_call_context_registrations = 0;
        group_video_capability_known = false;
        group_video_capability_available = false;
        context_mutex.unlock();
        if (context_to_close != null) {
            ((!) context_to_close).close();
        }
    }

    public void rekey_database(string new_key) throws Error {
        // No own database.
    }

    public void checkpoint_database() {
        // No own database.
    }

    public bool runtime_enabled() {
        return true;
    }

    bool MujiCallEnginePlugin.runtime_enabled() {
        return runtime_enabled();
    }

    public static bool call_debug_enabled() {
        string? enabled = Environment.get_variable(CALL_DEBUG_ENV);
        return enabled == "1" || enabled == "true" || enabled == "yes";
    }

    public bool can_start_audio_only(Dino.Entities.Account account) {
        return runtime_enabled();
    }

    public bool can_start_video(Dino.Entities.Account account) {
        return runtime_enabled() && !low_bandwidth_mode_enabled();
    }

    public bool can_start_group_audio(Dino.Entities.Account account) {
        return runtime_enabled();
    }

    public bool can_start_group_video(Dino.Entities.Account account) {
        return runtime_enabled() && !low_bandwidth_mode_enabled() &&
            shared_group_video_runtime_available();
    }

    public MujiCallEngineGroupSession create_group_session(
            XmppStream stream,
            Jid local_full_jid,
            Jid room_jid,
            uint64 logical_call_id,
            bool video_requested) throws Error {
        if (!runtime_enabled()) {
            throw new EngineError.CLOSED("Google/libwebrtc MUJI engine is disabled");
        }
        begin_call_context_registration();
        try {
            EngineContext group_context = ensure_context();
            if (video_requested && (low_bandwidth_mode_enabled() ||
                    !validate_shared_group_video_capability(group_context))) {
                throw new IOError.NOT_SUPPORTED(
                    "Google/libwebrtc MUJI video requires native shared camera fan-out");
            }

            Gee.List<EngineIceServer> ice_servers = get_cached_ice_servers_for_stream(stream);
            EngineMujiGroupSession group = new EngineMujiGroupSession(
                group_context,
                router,
                new XmppEngineJingleWireTransport(stream),
                new XmppEngineJmiTransport(stream),
                local_full_jid,
                room_jid,
                logical_call_id,
                video_requested,
                this,
                ice_servers,
                network_policy_for_new_call(video_requested));
            group.set_peer_bundle_capability((peer_full_jid) => {
                    return peer_supports_feature_for_stream(
                        stream,
                        peer_full_jid,
                        MUJI_BUNDLE_DISCO_FEATURE) ||
                        peer_supports_feature_for_stream(
                            stream,
                            peer_full_jid,
                            JINGLE_GROUPING_DISCO_FEATURE);
                });
            if (app != null) {
                Account? account = get_account_for_stream(stream);
                if (account != null) {
                    Dino.EntityInfo entity_info = ((!) app).stream_interactor
                        .get_module<Dino.EntityInfo>(Dino.EntityInfo.IDENTITY);
                    group.set_peer_bundle_capability_resolver(
                        new XmppEnginePeerBundleCapabilityResolver(
                            (!) account, entity_info));
                }
            }
            router.add_muji_group(group);
            track_muji_group(group);
            return group;
        } finally {
            end_call_context_registration();
        }
    }

    public async Gee.List<JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        if (media != "audio" && media != "video") {
            return new ArrayList<JingleRtp.PayloadType>(JingleRtp.PayloadType.equals_func);
        }
        if (muji_payload_cache.has_key(media)) {
            return clone_payload_types(muji_payload_cache[media]);
        }

        EngineSessionConfig config = new EngineSessionConfig();
        config.audio_enabled = media == "audio";
        config.video_enabled = media == "video";
        config.max_bundle = true;
        EngineSessionOwner session = ensure_context().create_session(config);
        var probe = new EngineSessionMujiCodecProbe(session);
        Gee.List<JingleRtp.PayloadType> payloads = yield EngineMujiCodecProbeRunner.run(
            probe, media);
        muji_payload_cache[media] = clone_payload_types(payloads);
        return clone_payload_types(payloads);
    }

    public async bool is_payload_supported(
            string media, JingleRtp.PayloadType payload_type) throws Error {
        Gee.List<JingleRtp.PayloadType> supported = yield get_supported_payloads(media);
        foreach (JingleRtp.PayloadType candidate in supported) {
            if (payload_codec_matches(candidate, payload_type)) return true;
        }
        return false;
    }

    public Gee.List<Dino.Plugins.MediaDevice> get_audio_devices(bool incoming) {
        var devices = new ArrayList<Dino.Plugins.MediaDevice>();

        try {
            Gee.List<EngineAudioDeviceInfo> engine_devices = ensure_context().get_audio_devices(incoming);
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: audio devices direction=%s count=%d",
                    incoming ? "speaker" : "microphone",
                    engine_devices.size);
            }
            foreach (EngineAudioDeviceInfo info in engine_devices) {
                devices.add(new EngineMediaDevice(info));
            }
        } catch (Error e) {
            warning(
                "Google/libwebrtc call: cannot enumerate %s devices: %s",
                incoming ? "speaker" : "microphone",
                e.message);
        }

        devices.sort((left, right) => strcmp(left.id, right.id));
        return devices;
    }

    public Dino.Plugins.MediaDevice? get_preferred_audio_device(bool incoming) {
        Gee.List<Dino.Plugins.MediaDevice> devices = get_audio_devices(incoming);
        if (devices.is_empty) return null;
        return devices.first();
    }

    public void set_audio_device(Dino.Plugins.MediaDevice device) throws Error {
        EngineMediaDevice? engine_device = device as EngineMediaDevice?;
        if (engine_device == null) {
            throw new EngineError.PROTOCOL("Media device does not belong to the Google/libwebrtc engine");
        }
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: selecting %s device index=%d name=%s",
                engine_device.info.incoming ? "speaker" : "microphone",
                engine_device.info.index,
                    engine_device.info.display_name);
        }
        ensure_context().set_audio_device(engine_device.info);
    }

    public double get_audio_device_volume(Dino.Plugins.MediaDevice? device) {
        EngineMediaDevice? engine_device = device as EngineMediaDevice?;
        if (engine_device == null) {
            return 1.0;
        }

        // Do not read back the platform WebRTC/PulseAudio mixer volume here.
        // On Linux the libwebrtc PulseAudio ADM can abort the whole process
        // from pa_operation_get_state(NULL) while reading the current speaker
        // sink-input volume. Keep the UI state in DinoX and only push explicit
        // user changes to libwebrtc.
        double volume = engine_device.info.incoming ? pending_speaker_volume : pending_microphone_volume;
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: cached %s volume value=%.2f",
                engine_device.info.incoming ? "speaker" : "microphone",
                volume);
        }
        return volume;
    }

    public void set_audio_device_volume(Dino.Plugins.MediaDevice? device, double volume) throws Error {
        EngineMediaDevice? engine_device = device as EngineMediaDevice?;
        if (engine_device == null) {
            throw new EngineError.PROTOCOL("Media device does not belong to the Google/libwebrtc engine");
        }
        double normalized_volume = clamp_audio_volume(volume);
        ensure_context().set_audio_device_volume(engine_device.info.incoming, normalized_volume);
        if (engine_device.info.incoming) {
            pending_speaker_volume = normalized_volume;
        } else {
            pending_microphone_volume = normalized_volume;
        }
        schedule_audio_volume_diagnostics(engine_device.info.incoming, normalized_volume);
    }

    public void play_test_tone(Dino.Plugins.MediaDevice? device, char digit = '5', uint duration_ms = 360) throws Error {
        stop_audio_test_playout();
        EngineContext playback_context = create_isolated_media_context();
        EngineContextActivityLease? playback_lease = null;
        try {
            playback_lease = playback_context.acquire_activity("audio-device-test-playback");
            select_audio_test_speaker(playback_context, device);

            playback_context.play_test_tone(digit, duration_ms);
            audio_test_playback_context = playback_context;
            audio_test_playback_lease = (owned) playback_lease;
        } catch (Error e) {
            if (playback_lease != null) ((!) playback_lease).release();
            playback_context.close();
            throw e;
        }
    }

    public uint play_audio_test_clip(
            Dino.Plugins.MediaDevice? device,
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample) throws Error {
        stop_audio_test_playout();
        EngineContext playback_context = create_isolated_media_context();
        EngineContextActivityLease? playback_lease = null;
        try {
            playback_lease = playback_context.acquire_activity("audio-device-test-playback");
            select_audio_test_speaker(playback_context, device);

            uint duration_ms = playback_context.play_audio_test_clip(
                pcm_data,
                sample_rate,
                channels,
                bytes_per_sample);
            audio_test_playback_context = playback_context;
            audio_test_playback_lease = (owned) playback_lease;
            return duration_ms;
        } catch (Error e) {
            if (playback_lease != null) ((!) playback_lease).release();
            playback_context.close();
            throw e;
        }
    }

    public void stop_audio_test_playout() throws Error {
        EngineContext? playback_context = audio_test_playback_context;
        EngineContextActivityLease? playback_lease = audio_test_playback_lease;
        audio_test_playback_context = null;
        audio_test_playback_lease = null;
        try {
            if (playback_context != null) {
                ((!) playback_context).stop_audio_test_playout();
            }
        } finally {
            if (playback_lease != null) {
                ((!) playback_lease).release();
            }
            if (playback_context != null) ((!) playback_context).close();
        }
    }

    private EngineContext create_isolated_media_context() throws EngineError {
        context_mutex.lock();
        try {
            if (shutting_down) throw new EngineError.CLOSED("Google/libwebrtc plugin is shutting down");
            return new EngineContext(runtime_audio_device_mode());
        } finally {
            context_mutex.unlock();
        }
    }

    private static void select_audio_test_speaker(EngineContext playback_context,
            Dino.Plugins.MediaDevice? selected) throws Error {
        // A fresh context uses the platform default, including Core Audio's
        // default-device selection on Windows. Do not substitute device zero.
        if (selected == null) return;
        if (selected is Dino.Plugins.SystemDefaultMediaDevice) {
            if (selected.media != "audio" || !selected.incoming) {
                throw new EngineError.PROTOCOL("Media device is not a speaker");
            }
            return;
        }
        var devices = new ArrayList<Dino.Plugins.MediaDevice>();
        foreach (EngineAudioDeviceInfo info in playback_context.get_audio_devices(true)) {
            devices.add(new EngineMediaDevice(info));
        }
        var device = Dino.Plugins.MediaDeviceSelection.find_selected(devices, selected) as EngineMediaDevice;
        if (device == null || !device.info.incoming) {
            throw new EngineError.PROTOCOL("Selected Google/libwebrtc speaker is no longer available");
        }
        playback_context.set_audio_device(device.info);
    }

    public Gee.List<Dino.Plugins.MediaDevice> get_video_devices() {
        var devices = new ArrayList<Dino.Plugins.MediaDevice>();

        try {
            Gee.List<EngineVideoDeviceInfo> engine_devices = ensure_context().get_video_devices();
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: video devices count=%d",
                    engine_devices.size);
            }
            foreach (EngineVideoDeviceInfo info in engine_devices) {
                devices.add(new EngineVideoMediaDevice(info));
            }
        } catch (Error e) {
            warning("Google/libwebrtc call: cannot enumerate camera devices: %s", e.message);
        }

        devices.sort((left, right) => strcmp(left.id, right.id));
        return devices;
    }

    public Dino.Plugins.MediaDevice? get_preferred_video_device() {
        Gee.List<Dino.Plugins.MediaDevice> devices = get_video_devices();
        if (devices.is_empty) return null;
        return devices.first();
    }

    /** Sends an XEP-0353 proposal and registers its SID with the worker-backed call engine. */
    public JmiCallEngineSession start_outgoing_audio_session(
            XmppStream stream,
            Jid local_full_jid,
            Jid peer_bare_jid,
            string sid,
            uint64 logical_call_id) throws Error {
        return start_outgoing_session(stream, local_full_jid, peer_bare_jid, sid, logical_call_id, false);
    }

    public JmiCallEngineSession start_outgoing_session(
            XmppStream stream,
            Jid local_full_jid,
            Jid peer_bare_jid,
            string sid,
            uint64 logical_call_id,
            bool video_requested) throws Error {
        if (video_requested && low_bandwidth_mode_enabled()) {
            throw new EngineError.PROTOCOL(
                "Video calls are disabled while low-bandwidth (2G) mode is active");
        }
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: outgoing %s session sid=%s local=%s peer=%s path=libwebrtc-jmi rtp-gstreamer=not-started",
                media_label(video_requested),
                sid,
                local_full_jid.to_string(),
                peer_bare_jid.to_string());
        }
        begin_call_context_registration();
        try {
            Gee.List<EngineIceServer> ice_servers = get_cached_ice_servers_for_stream(stream);
            log_ice_servers_for_session("outgoing", sid, local_full_jid, peer_bare_jid, ice_servers);
            EngineJmiSession session = new EngineJmiSession.outgoing(
                ensure_context(),
                new XmppEngineJingleWireTransport(stream),
                new XmppEngineJmiTransport(stream),
                sid,
                logical_call_id,
                local_full_jid,
                peer_bare_jid,
                true,
                video_requested,
                ice_servers,
                network_policy_for_new_call(video_requested));
            try {
                router.add(session);
                track_session(session);
                session.propose();
            } catch (Error e) {
                release_session(session);
                throw e;
            }
            return session;
        } finally {
            end_call_context_registration();
        }
    }

    public bool handle_proceed(Jid from, Jid to, string sid) throws Error {
        if (!runtime_enabled()) return false;

        EngineJingleWireSession? wire_session = null;
        bool routed = router.route_proceed(
            from, to, sid, out wire_session);
        if (routed && call_debug_enabled()) {
            message(
                "Google/libwebrtc call: JMI proceed routed sid=%s from=%s to=%s next=session-initiate path=libwebrtc-jingle rtp-gstreamer=skipped",
                sid,
                from.to_string(),
                to.to_string());
        }
        return routed;
    }

    /** Creates the worker-backed state for an incoming XEP-0353 proposal. */
    public JmiCallEngineSession create_incoming_session(
            XmppStream stream,
            Jid local_full_jid,
            Jid peer_full_jid,
            string sid,
            uint64 logical_call_id,
            Gee.List<StanzaNode> descriptions) throws Error {
        bool video_requested = descriptions_request_video(descriptions);
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: incoming %s proposal sid=%s local=%s peer=%s path=libwebrtc-jmi rtp-gstreamer=not-started",
                media_label(video_requested),
                sid,
                local_full_jid.to_string(),
                peer_full_jid.to_string());
        }
        begin_call_context_registration();
        try {
            Gee.List<EngineIceServer> ice_servers = get_cached_ice_servers_for_stream(stream);
            log_ice_servers_for_session("incoming", sid, local_full_jid, peer_full_jid, ice_servers);
            EngineJmiSession session = new EngineJmiSession.incoming(
                ensure_context(),
                new XmppEngineJingleWireTransport(stream),
                new XmppEngineJmiTransport(stream),
                sid,
                logical_call_id,
                local_full_jid,
                peer_full_jid,
                descriptions,
                ice_servers,
                network_policy_for_new_call(video_requested));
            try {
                router.add(session);
                track_session(session);
            } catch (Error e) {
                session.close();
                throw e;
            }
            return session;
        } finally {
            end_call_context_registration();
        }
    }

    private static bool descriptions_request_video(Gee.List<StanzaNode> descriptions) {
        foreach (StanzaNode description in descriptions) {
            if (description.ns_uri == JingleRtp.NS_URI &&
                    description.get_attribute("media") == "video") {
                return true;
            }
        }
        return false;
    }

    private static Gee.List<JingleRtp.PayloadType> clone_payload_types(
            Gee.List<JingleRtp.PayloadType> payloads) {
        var ret = new ArrayList<JingleRtp.PayloadType>(JingleRtp.PayloadType.equals_func);
        foreach (JingleRtp.PayloadType payload in payloads) {
            ret.add(payload.clone());
        }
        return ret;
    }

    private static bool payload_codec_matches(
            JingleRtp.PayloadType left, JingleRtp.PayloadType right) {
        string left_name = left.name == null ? "" : ((!) left.name).strip().ascii_down();
        string right_name = right.name == null ? "" : ((!) right.name).strip().ascii_down();
        return left_name != "" && left_name == right_name &&
            left.clockrate == right.clockrate && left.channels == right.channels;
    }

    private static string media_label(bool video_requested) {
        return video_requested ? "audio-video" : "audio";
    }

    private void on_stream_attached_modules(Dino.Entities.Account account, XmppStream stream) {
        if (!runtime_enabled()) return;

        Iq.Module? iq_module = stream.get_module<Iq.Module>(Iq.Module.IDENTITY);
        if (iq_module == null) return;
        if (interceptor_streams.contains(stream)) return;

        ((!) iq_module).register_interceptor_for_namespace(Jingle.NS_URI, ensure_iq_interceptor());
        Xep.Muji.Module? muji_module = stream.get_module<Xep.Muji.Module>(
            Xep.Muji.Module.IDENTITY);
        if (muji_module != null) {
            ((!) muji_module).register_codec_provider(stream, this);
        }
        add_call_disco_features(stream, muji_module != null);
        interceptor_streams.add(stream);
        debug("Google/libwebrtc Jingle IQ interceptor attached for account %s", account.bare_jid.to_string());
        if (runtime_enabled() && call_debug_enabled()) {
            message(
                "Google/libwebrtc call: Jingle IQ interceptor attached account=%s ownership=registered-sid-only fallback=existing-jingle-handler",
                account.bare_jid.to_string());
        }
    }

    internal static bool should_advertise_muji_bundle_feature(
            bool muji_module_available) {
        return muji_module_available;
    }

    private static void add_call_disco_features(
            XmppStream stream, bool muji_module_available) {
        Xep.ServiceDiscovery.Module? disco = stream.get_module<Xep.ServiceDiscovery.Module>(
            Xep.ServiceDiscovery.Module.IDENTITY);
        if (disco == null) return;

        ((!) disco).add_feature(stream, JingleRtp.NS_URI);
        ((!) disco).add_feature(stream, JingleRtp.NS_URI_AUDIO);
        ((!) disco).add_feature(stream, JingleRtp.NS_URI_VIDEO);
        ((!) disco).add_feature(stream, JingleRtp.HeaderExtension.NS_URI);
        if (should_advertise_muji_bundle_feature(muji_module_available)) {
            ((!) disco).add_feature(stream, MUJI_BUNDLE_DISCO_FEATURE);
        }
    }

    private static void remove_call_disco_features(XmppStream stream) {
        Xep.ServiceDiscovery.Module? disco = stream.get_module<Xep.ServiceDiscovery.Module>(
            Xep.ServiceDiscovery.Module.IDENTITY);
        if (disco == null) return;

        ((!) disco).remove_feature(stream, MUJI_BUNDLE_DISCO_FEATURE);

        // A concurrently loaded legacy RTP module owns the remaining shared
        // capabilities. Do not remove those when only this plugin stops.
        if (stream.get_module<JingleRtp.Module>(JingleRtp.Module.IDENTITY) != null) return;

        ((!) disco).remove_feature(stream, JingleRtp.HeaderExtension.NS_URI);
        ((!) disco).remove_feature(stream, JingleRtp.NS_URI_VIDEO);
        ((!) disco).remove_feature(stream, JingleRtp.NS_URI_AUDIO);
        ((!) disco).remove_feature(stream, JingleRtp.NS_URI);
    }

    private EngineJmiIqInterceptor ensure_iq_interceptor() {
        if (iq_interceptor == null) {
            iq_interceptor = new EngineJmiIqInterceptor(router);
        }
        return (!) iq_interceptor;
    }

    private async void refresh_ice_servers(Account account, XmppStream stream) {
        clear_ice_server_refresh_timeout(account);
        if (!runtime_enabled()) return;
        if (app == null || ((!) app).stream_interactor.get_stream(account) != stream) return;

        Gee.List<Xep.ExternalServiceDiscovery.Service> services;
        try {
            services = yield Xep.ExternalServiceDiscovery.request_services_checked(stream);
        } catch (IOError e) {
            log_external_service_discovery_failure(account, "Could not request XEP-0215 services for Google/libwebrtc", e);
            return;
        }
        if (app == null || ((!) app).stream_interactor.get_stream(account) != stream) return;

        Gee.List<EngineIceServer> ice_servers = EngineIceServer.from_external_services(services);
        if (ice_servers.is_empty) {
            ice_servers_by_account.unset(account);
        } else {
            ice_servers_by_account[account] = ice_servers;
        }
        update_pending_sessions_ice_servers(account, ice_servers);

        int stun_count;
        int turn_count;
        count_ice_server_types(ice_servers, out stun_count, out turn_count);
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: XEP-0215 ICE services account=%s count=%d stun=%d turn=%d source=server",
                account.bare_jid.to_string(),
                ice_servers.size,
                stun_count,
                turn_count);
        }

        uint? refresh_delay = calculate_ice_server_refresh_delay(ice_servers, new DateTime.now_utc());
        if (refresh_delay != null) {
            uint delay = (!) refresh_delay;
            ice_server_refresh_timeouts[account] = Timeout.add_seconds(delay, () => {
                ice_server_refresh_timeouts.unset(account);
                if (app != null && ((!) app).stream_interactor.get_stream(account) == stream) {
                    refresh_ice_servers.begin(account, stream);
                }
                return Source.REMOVE;
            });
        }
    }

    private Gee.List<EngineIceServer> get_cached_ice_servers_for_stream(XmppStream stream) {
        var ret = new ArrayList<EngineIceServer>();
        Account? account = get_account_for_stream(stream);
        if (account == null) return ret;

        Account current_account = (!) account;
        if (ice_servers_by_account.has_key(current_account)) {
            Gee.List<EngineIceServer> cached = ice_servers_by_account[current_account];
            Gee.List<EngineIceServer> fresh = filter_unexpired_ice_servers(cached, new DateTime.now_utc());
            if (fresh.size != cached.size) {
                if (fresh.is_empty) {
                    ice_servers_by_account.unset(current_account);
                } else {
                    ice_servers_by_account[current_account] = fresh;
                }
                refresh_ice_servers.begin(current_account, stream);
            }
            ret.add_all(fresh);
        } else {
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: no cached XEP-0215 ICE services account=%s; refreshing in background",
                    current_account.bare_jid.to_string());
            }
            refresh_ice_servers.begin(current_account, stream);
        }
        return ret;
    }

    private static Gee.List<EngineIceServer> filter_unexpired_ice_servers(
            Gee.List<EngineIceServer> ice_servers,
            DateTime now) {
        var ret = new ArrayList<EngineIceServer>();
        int64 now_unix = now.to_unix();
        foreach (EngineIceServer ice_server in ice_servers) {
            if (ice_server.expires != null && ((!) ice_server.expires).to_unix() <= now_unix) continue;
            ret.add(ice_server);
        }
        return ret;
    }

    private void update_pending_sessions_ice_servers(Account account, Gee.List<EngineIceServer> ice_servers) {
        foreach (EngineJmiSession session in sessions) {
            if (session.wire_session != null) continue;
            if (!session.local_full_jid.equals_bare(account.bare_jid)) continue;
            session.update_ice_servers(ice_servers);
        }
    }

    private Account? get_account_for_stream(XmppStream stream) {
        if (app == null) return null;
        foreach (Account account in ((!) app).stream_interactor.get_accounts()) {
            if (((!) app).stream_interactor.get_stream(account) == stream) {
                return account;
            }
        }
        return null;
    }

    private bool peer_supports_feature_for_stream(
            XmppStream stream,
            Jid peer_full_jid,
            string feature) {
        if (app == null) return false;
        Account? account = get_account_for_stream(stream);
        if (account == null) return false;
        return ((!) app).stream_interactor
            .get_module<Dino.EntityInfo>(Dino.EntityInfo.IDENTITY)
            .has_feature_offline((!) account, peer_full_jid, feature);
    }

    private void log_ice_servers_for_session(
            string direction,
            string sid,
            Jid local_full_jid,
            Jid peer_jid,
            Gee.List<EngineIceServer> ice_servers) {
        if (!call_debug_enabled()) return;

        int stun_count;
        int turn_count;
        count_ice_server_types(ice_servers, out stun_count, out turn_count);
        message(
            "Google/libwebrtc call: ICE servers session=%s sid=%s local=%s peer=%s count=%d stun=%d turn=%d passwords=hidden",
            direction,
            sid,
            local_full_jid.to_string(),
            peer_jid.to_string(),
            ice_servers.size,
            stun_count,
            turn_count);
    }

    private static void count_ice_server_types(
            Gee.List<EngineIceServer> ice_servers,
            out int stun_count,
            out int turn_count) {
        stun_count = 0;
        turn_count = 0;
        foreach (EngineIceServer ice_server in ice_servers) {
            if (ice_server.is_stun) stun_count++;
            if (ice_server.is_turn) turn_count++;
        }
    }

    private void log_external_service_discovery_failure(Account account, string message, IOError error) {
        if (error is IOError.CANCELLED) {
            debug("%s: %s", message, error.message);
            return;
        }

        if (error is IOError.TIMED_OUT) {
            int64 now_unix = new DateTime.now_utc().to_unix();
            int64? stored_last_warning_unix = extdisco_warning_timestamps[account];
            int64 last_warning_unix = stored_last_warning_unix ?? 0;
            if (last_warning_unix == 0 || now_unix - last_warning_unix >= 3600) {
                warning("%s: %s", message, error.message);
                extdisco_warning_timestamps[account] = now_unix;
            } else {
                debug("%s: %s", message, error.message);
            }
            return;
        }

        warning("%s: %s", message, error.message);
    }

    private void on_account_removed(Account account) {
        clear_ice_server_refresh_timeout(account);
        ice_servers_by_account.unset(account);
        extdisco_warning_timestamps.unset(account);
    }

    private void clear_ice_server_refresh_timeout(Account account) {
        if (!ice_server_refresh_timeouts.has_key(account)) return;

        uint timeout_id = ice_server_refresh_timeouts[account];
        ice_server_refresh_timeouts.unset(account);
        if (timeout_id != 0) Source.remove(timeout_id);
    }

    private void clear_all_ice_server_refresh_timeouts() {
        foreach (uint timeout_id in ice_server_refresh_timeouts.values) {
            if (timeout_id != 0) Source.remove(timeout_id);
        }
        ice_server_refresh_timeouts.clear();
    }

    private EngineContext ensure_context() throws EngineError {
        context_mutex.lock();
        try {
            if (shutting_down) {
                throw new EngineError.CLOSED("Google/libwebrtc plugin is shutting down");
            }
            retire_call_context_if_safe_locked("before next use");
            if (context == null) {
                EngineAudioDeviceMode mode = runtime_audio_device_mode();
                if (call_debug_enabled()) {
                    message(
                        "Google/libwebrtc call: creating libwebrtc context audio-device=%s rtp-gstreamer=not-used-for-owned-sids",
                        audio_device_mode_to_string(mode));
                }
                EngineContext created = new EngineContext(mode);
                try {
                    // A replacement worker starts at unity gain. Restore the
                    // values shown by the controls before any caller can use it.
                    created.set_audio_device_volume(false, pending_microphone_volume);
                    created.set_audio_device_volume(true, pending_speaker_volume);
                } catch (EngineError e) {
                    created.close();
                    throw e;
                }
                context = created;
                context_idle_handler_id = created.became_idle.connect(() => {
                    bool should_retry = false;
                    context_mutex.lock();
                    should_retry = context == created &&
                        context_restart_required;
                    context_mutex.unlock();
                    if (should_retry) retire_idle_call_context();
                });
#if GOOGLE_WEBRTC_EFFECT_TEST
                context_creation_count++;
#endif
                group_video_capability_known = false;
                group_video_capability_available = false;
            }
            return (!) context;
        } finally {
            context_mutex.unlock();
        }
    }

    /** Reserve the construction-to-tracking interval against idle retirement. */
    private void begin_call_context_registration() throws EngineError {
        context_mutex.lock();
        try {
            if (shutting_down) {
                throw new EngineError.CLOSED("Google/libwebrtc plugin is shutting down");
            }
            // If the old worker is already completely idle, retire it before
            // reserving the new logical call. Otherwise the new call shares
            // that still-live worker until all outstanding activity is done.
            retire_call_context_if_safe_locked("before call registration");
            pending_call_context_registrations++;
        } finally {
            context_mutex.unlock();
        }
    }

    private void end_call_context_registration() {
        context_mutex.lock();
        if (pending_call_context_registrations == 0) {
            critical("Google/libwebrtc pending call registration underflow");
        } else {
            pending_call_context_registrations--;
        }
        context_mutex.unlock();
        retire_idle_call_context();
    }

    private void retain_tracked_call_context_owner() {
        context_mutex.lock();
        tracked_call_context_owners++;
        context_mutex.unlock();
    }

    private void release_tracked_call_context_owner() {
        context_mutex.lock();
        if (tracked_call_context_owners == 0) {
            critical("Google/libwebrtc tracked call owner underflow");
        } else {
            tracked_call_context_owners--;
        }
        context_mutex.unlock();
    }

    private bool low_bandwidth_mode_enabled() {
        return app != null && ((!) app).settings.call_network_mode == "low-bandwidth-2g";
    }

    private bool shared_group_video_runtime_available() {
        context_mutex.lock();
        bool known = group_video_capability_known;
        bool available = group_video_capability_available;
        context_mutex.unlock();
        if (known) return available;

        // This getter is called synchronously from the GTK titlebar. Only use
        // the loaded wrapper's immutable build contract here; never create a
        // context, spawn the worker or perform IPC. create_group_session()
        // revalidates the actual shared/preview flags fail-closed.
        unowned Native.BuildInfo? build_info = Native.get_build_info();
        return build_info != null &&
            ((!) build_info).abi_version == Native.ABI_VERSION &&
            Native.ABI_VERSION >= 38 && ((!) build_info).runtime_enabled != 0;
    }

    private bool validate_shared_group_video_capability(EngineContext current_context) {
        bool available = false;
        try {
            Native.VideoEffectCapabilities capabilities =
                current_context.get_video_effect_capabilities();
            available = capabilities.shared_pipeline_supported != 0 &&
                capabilities.preview_publisher_supported != 0 &&
                capabilities.max_subscribers >= 4;
        } catch (Error e) {
            if (call_debug_enabled()) {
                debug(
                    "Google/libwebrtc MUJI video capability unavailable: %s",
                    e.message);
            }
        }
        context_mutex.lock();
        if (context == current_context) {
            group_video_capability_known = true;
            group_video_capability_available = available;
        }
        context_mutex.unlock();
        return available;
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    internal bool can_start_group_video_without_account_for_test() {
        return runtime_enabled() && !low_bandwidth_mode_enabled() &&
            shared_group_video_runtime_available();
    }

    internal uint context_creation_count_for_test() {
        context_mutex.lock();
        uint count = context_creation_count;
        context_mutex.unlock();
        return count;
    }

    internal void track_muji_group_for_test(EngineMujiGroupSession group) {
        track_muji_group(group);
    }

    internal void track_session_for_test(EngineJmiSession session) {
        track_session(session);
    }

    internal void begin_call_context_registration_for_test()
            throws EngineError {
        begin_call_context_registration();
    }

    internal void end_call_context_registration_for_test() {
        end_call_context_registration();
    }

    internal int muji_group_count_for_test() {
        return muji_groups.size;
    }

    internal int session_count_for_test() {
        return sessions.size;
    }

    internal EngineContext context_for_retirement_test() throws EngineError {
        return ensure_context();
    }

    internal void request_context_retirement_for_test() {
        context_mutex.lock();
        context_restart_required = true;
        context_mutex.unlock();
        retire_idle_call_context();
    }

    internal bool has_context_for_test() {
        context_mutex.lock();
        bool present = context != null;
        context_mutex.unlock();
        return present;
    }
#endif

    private Native.NetworkPolicy network_policy_for_new_call(bool video_requested) {
        return !video_requested && low_bandwidth_mode_enabled()
            ? Native.NetworkPolicy.LOW_BANDWIDTH_2G
            : Native.NetworkPolicy.AUTOMATIC;
    }

    private EngineAudioDeviceMode runtime_audio_device_mode() {
        string? mode = Environment.get_variable(AUDIO_DEVICE_ENV);
        if (mode == "synthetic" || mode == "test") {
            debug("Google/libwebrtc engine using synthetic audio device module");
            return EngineAudioDeviceMode.SYNTHETIC;
        }

        if (mode != null && mode != "" && mode != "platform" && mode != "platform-default" && mode != "real") {
            warning("Unknown %s value '%s'; using platform default audio device module", AUDIO_DEVICE_ENV, (!) mode);
        }

        debug("Google/libwebrtc engine using platform default audio device module");
        return EngineAudioDeviceMode.PLATFORM_DEFAULT;
    }

    private void track_muji_group(EngineMujiGroupSession group) {
        if (muji_groups.contains(group)) return;

        retain_tracked_call_context_owner();

        ulong peer_session_created_handler_id =
            group.peer_session_created.connect((session) => {
                track_session(session);
            });
        ulong group_closed_handler_id = 0;
        group_closed_handler_id = group.group_closed.connect((closed_group) => {
            if (peer_session_created_handler_id != 0 &&
                    SignalHandler.is_connected(
                        closed_group, peer_session_created_handler_id)) {
                SignalHandler.disconnect(
                    closed_group, peer_session_created_handler_id);
            }
            if (group_closed_handler_id != 0 &&
                    SignalHandler.is_connected(closed_group, group_closed_handler_id)) {
                SignalHandler.disconnect(closed_group, group_closed_handler_id);
                group_closed_handler_id = 0;
            }
            release_muji_group(closed_group);
        });
        muji_groups.add(group);
    }

    private void track_session(EngineJmiSession session) {
        if (sessions.contains(session)) return;
        retain_tracked_call_context_owner();
        sessions.add(session);
        var handlers = new PluginSessionSignalHandlers();
        handlers.wire_session_started = session.wire_session_started.connect((wire_session) => {
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: wire session started sid=%s local=%s peer=%s jingle-iq=owned",
                    wire_session.sid,
                    wire_session.local_full_jid.to_string(),
                    wire_session.peer_full_jid.to_string());
            }
        });
        handlers.active = session.active.connect(() => {
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: active sid=%s peer=%s media=%s engine=libwebrtc",
                    session.sid,
                    session.peer_jid.to_string(),
                    media_label(session.video_requested));
            }
            log_session_diagnostics(session, "active");
            Timeout.add(ACTIVE_DIAGNOSTICS_DELAY_MS, () => {
                if (sessions.contains(session)) {
                    log_session_diagnostics(session, "active+3s");
                }
                return Source.REMOVE;
            });
            Timeout.add(LATE_DIAGNOSTICS_DELAY_MS, () => {
                if (sessions.contains(session)) {
                    log_session_diagnostics(session, "active+10s");
                }
                return Source.REMOVE;
            });
            Timeout.add(STARTUP_STABLE_DIAGNOSTICS_DELAY_MS, () => {
                if (sessions.contains(session)) {
                    log_session_diagnostics(session, "active+15s");
                }
                return Source.REMOVE;
            });
        });
        handlers.failed = session.failed.connect((message) => {
            warning(
                "Google/libwebrtc call: failed sid=%s peer=%s error=%s",
                session.sid,
                session.peer_jid.to_string(),
                message);
            log_session_diagnostics(session, "failed");
            release_session(session);
        });
        handlers.rejected = session.rejected.connect(() => {
            if (call_debug_enabled()) {
                message("Google/libwebrtc call: rejected sid=%s peer=%s", session.sid, session.peer_jid.to_string());
            }
            release_session(session);
        });
        handlers.retracted = session.retracted.connect(() => {
            if (call_debug_enabled()) {
                message("Google/libwebrtc call: retracted sid=%s peer=%s", session.sid, session.peer_jid.to_string());
            }
            release_session(session);
        });
        handlers.ended = session.ended.connect(() => {
            if (call_debug_enabled()) {
                message("Google/libwebrtc call: ended sid=%s peer=%s", session.sid, session.peer_jid.to_string());
            }
            log_session_diagnostics(session, "ended");
            release_session(session);
        });
        handlers.remote_terminated = session.remote_terminated.connect((reason_name, reason_text) => {
            if (call_debug_enabled()) {
                message(
                    "Google/libwebrtc call: remote terminated sid=%s peer=%s reason=%s text=%s",
                    session.sid,
                    session.peer_jid.to_string(),
                    reason_name ?? "(none)",
                    reason_text ?? "(none)");
            }
            log_session_diagnostics(session, "remote-terminated");
            release_session(session);
        });
        session_signal_handlers[session] = handlers;
    }

    private void disconnect_session_signals(EngineJmiSession session) {
        PluginSessionSignalHandlers? handlers = session_signal_handlers[session];
        if (handlers == null) return;

        // Remove the strong map key before disconnecting the current handler.
        // Signal disconnect is safe during emission and may release the last
        // closure reference to this session immediately.
        session_signal_handlers.unset(session);
        disconnect_session_signal(session, ((!) handlers).wire_session_started);
        disconnect_session_signal(session, ((!) handlers).active);
        disconnect_session_signal(session, ((!) handlers).failed);
        disconnect_session_signal(session, ((!) handlers).rejected);
        disconnect_session_signal(session, ((!) handlers).retracted);
        disconnect_session_signal(session, ((!) handlers).ended);
        disconnect_session_signal(session, ((!) handlers).remote_terminated);
    }

    private static void disconnect_session_signal(
            EngineJmiSession session, ulong handler_id) {
        if (handler_id != 0 && SignalHandler.is_connected(session, handler_id)) {
            SignalHandler.disconnect(session, handler_id);
        }
    }

    private static string audio_device_mode_to_string(EngineAudioDeviceMode mode) {
        switch (mode) {
            case EngineAudioDeviceMode.SYNTHETIC:
                return "synthetic";
            case EngineAudioDeviceMode.PLATFORM_DEFAULT:
                return "platform";
            default:
                assert_not_reached();
        }
    }

    private void log_session_diagnostics(EngineJmiSession session, string phase) {
        if (!call_debug_enabled()) return;

        try {
            Dino.Plugins.JmiCallDiagnostics? diagnostics = session.get_diagnostics();
            if (diagnostics == null) {
                message(
                    "Google/libwebrtc call: diagnostics phase=%s sid=%s peer=%s unavailable",
                    phase,
                    session.sid,
                    session.peer_jid.to_string());
                return;
            }

            Dino.Plugins.JmiCallDiagnostics info = (!) diagnostics;
            message(
                "Google/libwebrtc call: diagnostics phase=%s sid=%s peer=%s jmi=%s wire=%s pc=%s ice=%s ice-srv:%d local=%s/%s/%s video-local=%s/%s/%s transceivers=a:%d/v:%d remote=a:%d/v:%d remote-sink=%d/%llu/%llu/%.4f video-sink=%d/%llu/%dx%d rtp-audio=in:%llu/%lluB/%llusamples out:%llu/%lluB/%.0fbps rtp-video=in:%llu/%lluB frames:%llu decoded:%llu %dx%d out:%llu/%lluB frames:%llu encoded:%llu %.0fbps %dx%d level:in:%.4f src:%.4f src-energy:%.6f/%.3fs reports:%llu adm=init:%s play:%s/%s rec:%s/%s cap:%llu probe:%llu/%llu/%.4f out:%llu micvol:%s/%.2f spkvol:%s/%.2f dtmf=local:%llu/%llu/%llu unsupported:%llu fmt:%u/%u/%u peak:%.4f active:%s",
                phase,
                session.sid,
                session.peer_jid.to_string(),
                info.jmi_state ?? "unknown",
                info.wire_started ? "started" : "pending",
                info.peer_connection_state ?? "unknown",
                info.ice_connection_state ?? "unknown",
                info.ice_server_count,
                info.local_audio_source_attached ? "source" : "no-source",
                info.local_audio_track_attached ? "track" : "no-track",
                info.local_audio_track_enabled ? "enabled" : "muted",
                info.local_video_source_attached ? "source" : "no-source",
                info.local_video_track_attached ? "track" : "no-track",
                info.local_video_track_enabled ? "enabled" : "disabled",
                info.audio_transceiver_count,
                info.video_transceiver_count,
                info.remote_audio_receiver_count,
                info.remote_video_receiver_count,
                info.remote_audio_sink_count,
                info.remote_audio_sink_frame_count,
                info.remote_audio_sink_sample_count,
                info.remote_audio_sink_peak_level,
                info.remote_video_sink_count,
                info.remote_video_sink_frame_count,
                info.remote_video_sink_last_width,
                info.remote_video_sink_last_height,
                info.inbound_audio_packets_received,
                info.inbound_audio_bytes_received,
                info.inbound_audio_total_samples_received,
                info.outbound_audio_packets_sent,
                info.outbound_audio_bytes_sent,
                info.outbound_audio_target_bitrate,
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
                info.inbound_audio_level,
                info.source_audio_level,
                info.source_audio_total_energy,
                info.source_audio_total_duration,
                info.stats_report_count,
                info.audio_device_initialized ? "yes" : "no",
                info.audio_device_playout_initialized ? "init" : "no-init",
                info.audio_device_playing ? "playing" : "stopped",
                info.audio_device_recording_initialized ? "init" : "no-init",
                info.audio_device_recording ? "recording" : "stopped",
                info.audio_device_capture_sample_count,
                info.audio_device_capture_probe_frame_count,
                info.audio_device_capture_probe_sample_count,
                info.audio_device_capture_probe_peak_level,
                info.audio_device_playout_sample_count,
                info.audio_device_microphone_volume_available ? "yes" : "no",
                info.audio_device_microphone_volume,
                info.audio_device_speaker_volume_available ? "yes" : "no",
                info.audio_device_speaker_volume,
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
            if (e is EngineError.CLOSED) {
                message(
                    "Google/libwebrtc call: diagnostics phase=%s sid=%s peer=%s unavailable: %s",
                    phase,
                    session.sid,
                    session.peer_jid.to_string(),
                    e.message);
                return;
            }
            warning(
                "Google/libwebrtc call: diagnostics phase=%s sid=%s peer=%s failed: %s",
                phase,
                session.sid,
                session.peer_jid.to_string(),
                e.message);
        }
    }

    private void release_session(EngineJmiSession session) {
        disconnect_session_signals(session);
        router.remove(session);
        bool was_tracked = sessions.remove(session);
        // close() is idempotent.  Run it even after remote termination so the
        // JMI owner cannot retain a closed wire session or its context lease.
        session.close();

        // A terminal session must never keep the shared call-worker alive.
        // Prune any duplicate/stale terminal entries before deciding whether
        // another real call still owns the worker.
        var stale_sessions = new ArrayList<EngineJmiSession>();
        foreach (EngineJmiSession candidate in sessions) {
            if (candidate.jmi_state == JmiState.REJECTED ||
                    candidate.jmi_state == JmiState.RETRACTED ||
                    candidate.jmi_state == JmiState.ENDED) {
                stale_sessions.add(candidate);
            }
        }
        foreach (EngineJmiSession stale in stale_sessions) {
            disconnect_session_signals(stale);
            router.remove(stale);
            stale.close();
            if (sessions.remove(stale)) {
                release_tracked_call_context_owner();
            }
        }
        if (was_tracked) release_tracked_call_context_owner();
        if (sessions.is_empty && muji_groups.is_empty) {
            cancel_audio_volume_diagnostics();
            context_mutex.lock();
            context_restart_required = true;
            context_mutex.unlock();
            retire_idle_call_context();
        }
    }

    private void release_muji_group(EngineMujiGroupSession group) {
        router.remove_muji_group(group);
        bool was_tracked = muji_groups.remove(group);
        if (was_tracked) release_tracked_call_context_owner();
        if (!sessions.is_empty || !muji_groups.is_empty) return;

        cancel_audio_volume_diagnostics();
        context_mutex.lock();
        context_restart_required = true;
        context_mutex.unlock();
        retire_idle_call_context();
    }

    private void retire_idle_call_context() {
        context_mutex.lock();
        try {
            retire_call_context_if_safe_locked("after final call");
        } finally {
            context_mutex.unlock();
        }
    }

    /** Must be called with context_mutex held. */
    private void retire_call_context_if_safe_locked(string phase) {
        if (!context_restart_required) return;
        if (context == null) {
            context_restart_required = false;
            return;
        }

        EngineContext candidate = (!) context;
        // A signaling-only proposal is a real logical call owner even before
        // <proceed/> creates its first PeerConnection. A closing group-video
        // pipeline is likewise a real call lease until native cleanup has
        // released its strong worker reference. Never force-close either one.
        if (pending_call_context_registrations != 0 ||
                tracked_call_context_owners != 0) {
            return;
        }
        // This is one atomic state-mutex operation inside EngineContext. A
        // lease either wins before retirement (and keeps this context alive),
        // or retirement wins and every later acquire fails closed. Never
        // inspect counters and force-close in two separate lock intervals.
        if (!candidate.try_retire_if_idle()) {
            return;
        }

        disconnect_context_idle_handler_locked(candidate);
        context = null;
        context_restart_required = false;
        if (call_debug_enabled()) {
            message(
                "Google/libwebrtc call: retired idle media worker %s",
                phase);
        }
    }

    /** Must be called with context_mutex held. */
    private void disconnect_context_idle_handler_locked(
            EngineContext owned_context) {
        if (context_idle_handler_id != 0 &&
                SignalHandler.is_connected(
                    owned_context, context_idle_handler_id)) {
            SignalHandler.disconnect(
                owned_context, context_idle_handler_id);
        }
        context_idle_handler_id = 0;
    }

    private void schedule_audio_volume_diagnostics(bool incoming, double volume) {
        volume = clamp_audio_volume(volume);
        if (incoming) {
            pending_speaker_volume = volume;
            if (!call_debug_enabled()) return;

            if (speaker_volume_diagnostics_timeout_id != 0) {
                Source.remove(speaker_volume_diagnostics_timeout_id);
                speaker_volume_diagnostics_timeout_id = 0;
            }
            speaker_volume_diagnostics_timeout_id = Timeout.add(1000, () => {
                speaker_volume_diagnostics_timeout_id = 0;
                if (sessions.is_empty) return Source.REMOVE;
                message(
                    "Google/libwebrtc call: speaker volume applied value=%.2f sessions=%d",
                    pending_speaker_volume,
                    sessions.size);
                foreach (EngineJmiSession session in sessions) {
                    log_session_diagnostics(session, "speaker-volume+1s");
                }
                return Source.REMOVE;
            });
        } else {
            pending_microphone_volume = volume;
            if (!call_debug_enabled()) return;

            if (microphone_volume_diagnostics_timeout_id != 0) {
                Source.remove(microphone_volume_diagnostics_timeout_id);
                microphone_volume_diagnostics_timeout_id = 0;
            }
            microphone_volume_diagnostics_timeout_id = Timeout.add(1000, () => {
                microphone_volume_diagnostics_timeout_id = 0;
                if (sessions.is_empty) return Source.REMOVE;
                message(
                    "Google/libwebrtc call: microphone volume applied value=%.2f sessions=%d",
                    pending_microphone_volume,
                    sessions.size);
                foreach (EngineJmiSession session in sessions) {
                    log_session_diagnostics(session, "microphone-volume+1s");
                }
                return Source.REMOVE;
            });
        }
    }

    private static double clamp_audio_volume(double volume) {
        if (volume < 0.0) return 0.0;
        if (volume > 1.0) return 1.0;
        return volume;
    }

    private void cancel_audio_volume_diagnostics() {
        if (microphone_volume_diagnostics_timeout_id != 0) {
            Source.remove(microphone_volume_diagnostics_timeout_id);
            microphone_volume_diagnostics_timeout_id = 0;
        }
        if (speaker_volume_diagnostics_timeout_id != 0) {
            Source.remove(speaker_volume_diagnostics_timeout_id);
            speaker_volume_diagnostics_timeout_id = 0;
        }
    }
}

}
