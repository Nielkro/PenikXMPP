using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

public errordomain EngineError {
    NATIVE,
    CLOSED,
    PROTOCOL
}

public class EngineSessionConfig : Object {
    public bool audio_enabled { get; set; default = true; }
    public bool video_enabled { get; set; default = true; }
    public JingleRtp.SdpMediaDirection audio_direction { get; set; default = JingleRtp.SdpMediaDirection.SEND_RECV; }
    public JingleRtp.SdpMediaDirection video_direction { get; set; default = JingleRtp.SdpMediaDirection.SEND_RECV; }
    public bool defer_audio_transceiver_until_answer { get; set; default = false; }
    public bool defer_video_transceiver_until_answer { get; set; default = false; }
    public int ice_candidate_pool_size { get; set; default = 0; }
    public bool max_bundle { get; set; default = true; }
    public Native.NetworkPolicy network_policy { get; set; default = Native.NetworkPolicy.AUTOMATIC; }
    public Gee.List<EngineIceServer> ice_servers { get; private set; }

    public EngineSessionConfig() {
        ice_servers = new ArrayList<EngineIceServer>();
    }

    public void add_ice_server(EngineIceServer ice_server) {
        ice_servers.add(ice_server);
    }

    internal Native.SessionConfig to_native() {
        Native.SessionConfig native = Native.session_config_default();
        native.abi_version = Native.ABI_VERSION;
        native.audio_enabled = audio_enabled ? 1 : 0;
        native.video_enabled = video_enabled ? 1 : 0;
        native.audio_direction = Native.media_direction_to_native(audio_direction);
        native.video_direction = Native.media_direction_to_native(video_direction);
        native.defer_audio_transceiver_until_answer = defer_audio_transceiver_until_answer ? 1 : 0;
        native.defer_video_transceiver_until_answer = defer_video_transceiver_until_answer ? 1 : 0;
        native.ice_candidate_pool_size = ice_candidate_pool_size;
        native.max_bundle = max_bundle ? 1 : 0;
        native.network_policy = network_policy;
        return native;
    }
}

public enum EngineAudioDeviceMode {
    SYNTHETIC,
    PLATFORM_DEFAULT;

    internal Native.AudioDeviceMode to_native() {
        switch (this) {
            case SYNTHETIC:
                return Native.AudioDeviceMode.SYNTHETIC;
            case PLATFORM_DEFAULT:
                return Native.AudioDeviceMode.PLATFORM_DEFAULT;
            default:
                assert_not_reached();
        }
    }
}

public class EngineAudioDeviceInfo : Object {
    public bool incoming { get; private set; }
    public int index { get; private set; }
    public string display_name { get; private set; }
    public string guid { get; private set; }

    public string id {
        owned get {
            return "%s:%d:%s".printf(incoming ? "playout" : "recording", index, guid);
        }
    }

    public EngineAudioDeviceInfo(bool incoming, int index, string display_name, string guid) {
        this.incoming = incoming;
        this.index = index;
        this.display_name = display_name;
        this.guid = guid;
    }
}

public class EngineVideoDeviceInfo : Object {
    public int index { get; private set; }
    public string display_name { get; private set; }
    public string unique_id { get; private set; }
    public string product_id { get; private set; }

    public string id {
        owned get {
            return "video:%d:%s".printf(index, unique_id);
        }
    }

    public EngineVideoDeviceInfo(int index, string display_name, string unique_id, string product_id) {
        this.index = index;
        this.display_name = display_name;
        this.unique_id = unique_id;
        this.product_id = product_id;
    }
}

internal class EngineContextActivityLease : Object {
    private EngineContext? owner;

    public string purpose { get; private set; }
    public bool released { get { return owner == null; } }

    internal EngineContextActivityLease(EngineContext owner, string purpose) {
        this.owner = owner;
        this.purpose = purpose;
    }

    public void release() {
        if (owner == null) return;
        EngineContext current_owner = (!) owner;
        owner = null;
        current_owner.release_activity(purpose);
    }

    ~EngineContextActivityLease() {
        release();
    }
}

public class EngineContext : Object {
    private Native.Context? native_context;
    private Mutex state_mutex = Mutex();
    private bool closed = false;
    private bool close_requested = false;
    private uint activity_count = 0;
    private uint call_activity_count = 0;
    private uint non_call_activity_count = 0;

    /** Emitted after the final activity lease is released, outside the lock. */
    internal signal void became_idle();

    public bool is_closed {
        get {
            state_mutex.lock();
            bool value = closed;
            state_mutex.unlock();
            return value;
        }
    }
    public bool close_pending {
        get {
            state_mutex.lock();
            bool value = close_requested && !closed;
            state_mutex.unlock();
            return value;
        }
    }
    public uint active_activity_count {
        get {
            state_mutex.lock();
            uint value = activity_count;
            state_mutex.unlock();
            return value;
        }
    }
    public uint active_call_activity_count {
        get {
            state_mutex.lock();
            uint value = call_activity_count;
            state_mutex.unlock();
            return value;
        }
    }
    public uint active_non_call_activity_count {
        get {
            state_mutex.lock();
            uint value = non_call_activity_count;
            state_mutex.unlock();
            return value;
        }
    }

    public EngineContext(EngineAudioDeviceMode audio_device_mode = EngineAudioDeviceMode.SYNTHETIC) throws EngineError {
        Native.Context? created = null;
        throw_if_native_error(
            Native.context_new_with_audio_device_mode(audio_device_mode.to_native(), out created),
            "creating Google/libwebrtc context");
        native_context = (owned) created;
    }

    public unowned Native.BuildInfo? get_build_info() {
        return Native.get_build_info();
    }

    public Gee.List<EngineAudioDeviceInfo> get_audio_devices(bool incoming) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("audio-device-enumeration");
        try {
            int count = 0;
            throw_if_native_error(
                Native.context_get_audio_device_count(native_context, incoming ? 1 : 0, out count),
                incoming ? "enumerating Google/libwebrtc speaker devices" : "enumerating Google/libwebrtc microphone devices");

            var devices = new ArrayList<EngineAudioDeviceInfo>();
            for (int index = 0; index < count; index++) {
                uint8[] name_buf = new uint8[256];
                uint8[] guid_buf = new uint8[256];
                throw_if_native_error(
                    Native.context_get_audio_device_name(
                        native_context,
                        incoming ? 1 : 0,
                        index,
                        (char*) name_buf,
                        name_buf.length,
                        (char*) guid_buf,
                        guid_buf.length),
                    incoming ? "reading Google/libwebrtc speaker device" : "reading Google/libwebrtc microphone device");
                string display_name = ((string) name_buf).dup();
                string guid = ((string) guid_buf).dup();
                devices.add(new EngineAudioDeviceInfo(incoming, index, display_name, guid));
            }
            return devices;
        } finally {
            lease.release();
        }
    }

    public void set_audio_device(EngineAudioDeviceInfo device) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("audio-device-selection");
        try {
            throw_if_native_error(
                Native.context_set_audio_device(native_context, device.incoming ? 1 : 0, device.index),
                device.incoming ? "selecting Google/libwebrtc speaker device" : "selecting Google/libwebrtc microphone device");
        } finally {
            lease.release();
        }
    }

    public double get_audio_device_volume(bool incoming, out bool available) throws EngineError {
        available = false;
        EngineContextActivityLease lease = acquire_activity("audio-device-volume-read");
        try {
            double volume = 1.0;
            int native_available = 0;
            throw_if_native_error(
                Native.context_get_audio_device_volume(native_context, incoming ? 1 : 0, out volume, out native_available),
                incoming ? "reading Google/libwebrtc speaker volume" : "reading Google/libwebrtc microphone volume");
            available = native_available != 0;
            return volume;
        } finally {
            lease.release();
        }
    }

    public void set_audio_device_volume(bool incoming, double volume) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("audio-device-volume-write");
        try {
            throw_if_native_error(
                Native.context_set_audio_device_volume(native_context, incoming ? 1 : 0, volume),
                incoming ? "setting Google/libwebrtc speaker volume" : "setting Google/libwebrtc microphone volume");
        } finally {
            lease.release();
        }
    }

    public void play_test_tone(char digit = '5', uint duration_ms = 360) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("speaker-test-tone");
        try {
            throw_if_native_error(
                Native.context_play_test_tone(native_context, digit, duration_ms),
                "playing Google/libwebrtc speaker test tone");
        } finally {
            lease.release();
        }
    }

    public uint play_audio_test_clip(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("audio-test-clip");
        try {
            unowned uint8[]? raw_data = pcm_data.get_data();
            if (raw_data == null || pcm_data.get_size() == 0) {
                throw new EngineError.PROTOCOL("Google/libwebrtc audio test clip is empty");
            }
            uint duration_ms = 0;
            throw_if_native_error(
                Native.context_play_audio_test_clip(
                    native_context,
                    (uint8*) (!) raw_data,
                    pcm_data.get_size(),
                    sample_rate,
                    channels,
                    bytes_per_sample,
                    out duration_ms),
                "playing Google/libwebrtc microphone test recording");
            return duration_ms;
        } finally {
            lease.release();
        }
    }

    public void stop_audio_test_playout() throws EngineError {
        EngineContextActivityLease lease;
        try {
            lease = acquire_activity("audio-test-stop");
        } catch (EngineError e) {
            if (e is EngineError.CLOSED) return;
            throw e;
        }
        try {
            throw_if_native_error(
                Native.context_stop_audio_test_playout(native_context),
                "stopping Google/libwebrtc audio device test");
        } finally {
            lease.release();
        }
    }

    public void start_media_audio_playout(
            int sample_rate,
            int channels,
            int bytes_per_sample) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("media-audio-playout-start");
        try {
            throw_if_native_error(
                Native.context_media_audio_playout_start(
                    native_context, sample_rate, channels, bytes_per_sample),
                "starting Google/libwebrtc media audio playout");
        } finally {
            lease.release();
        }
    }

    public uint push_media_audio_playout(Bytes pcm_data) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("media-audio-playout-push");
        try {
            unowned uint8[]? raw_data = pcm_data.get_data();
            if (raw_data == null || pcm_data.get_size() == 0) {
                throw new EngineError.PROTOCOL("Google/libwebrtc media PCM buffer is empty");
            }
            uint queued_duration_ms = 0;
            throw_if_native_error(
                Native.context_media_audio_playout_push(
                    native_context,
                    (uint8*) (!) raw_data,
                    pcm_data.get_size(),
                    out queued_duration_ms),
                "queueing Google/libwebrtc media PCM");
            return queued_duration_ms;
        } finally {
            lease.release();
        }
    }

    public void set_media_audio_playout_paused(bool paused) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("media-audio-playout-pause");
        try {
            throw_if_native_error(
                Native.context_media_audio_playout_set_paused(native_context, paused ? 1 : 0),
                paused ? "pausing Google/libwebrtc media audio playout" :
                    "resuming Google/libwebrtc media audio playout");
        } finally {
            lease.release();
        }
    }

    public void flush_media_audio_playout() throws EngineError {
        EngineContextActivityLease lease = acquire_activity("media-audio-playout-flush");
        try {
            throw_if_native_error(
                Native.context_media_audio_playout_flush(native_context),
                "flushing Google/libwebrtc media audio playout");
        } finally {
            lease.release();
        }
    }

    public uint finish_media_audio_playout() throws EngineError {
        EngineContextActivityLease lease = acquire_activity("media-audio-playout-finish");
        try {
            uint queued_duration_ms = 0;
            throw_if_native_error(
                Native.context_media_audio_playout_finish(
                    native_context, out queued_duration_ms),
                "finishing Google/libwebrtc media audio playout");
            return queued_duration_ms;
        } finally {
            lease.release();
        }
    }

    public void stop_media_audio_playout() throws EngineError {
        EngineContextActivityLease lease;
        try {
            lease = acquire_activity("media-audio-playout-stop");
        } catch (EngineError e) {
            if (e is EngineError.CLOSED) return;
            throw e;
        }
        try {
            throw_if_native_error(
                Native.context_media_audio_playout_stop(native_context),
                "stopping Google/libwebrtc media audio playout");
        } finally {
            lease.release();
        }
    }

    public Gee.List<EngineVideoDeviceInfo> get_video_devices() throws EngineError {
        EngineContextActivityLease lease = acquire_activity("video-device-enumeration");
        try {
            int count = 0;
            throw_if_native_error(
                Native.context_get_video_device_count(native_context, out count),
                "enumerating Google/libwebrtc camera devices");

            var devices = new ArrayList<EngineVideoDeviceInfo>();
            for (int index = 0; index < count; index++) {
                uint8[] name_buf = new uint8[256];
                uint8[] unique_id_buf = new uint8[1024];
                uint8[] product_id_buf = new uint8[128];
                throw_if_native_error(
                    Native.context_get_video_device_name(
                        native_context,
                        index,
                        (char*) name_buf,
                        name_buf.length,
                        (char*) unique_id_buf,
                        unique_id_buf.length,
                        (char*) product_id_buf,
                        product_id_buf.length),
                    "reading Google/libwebrtc camera device");
                string display_name = ((string) name_buf).dup();
                string unique_id = ((string) unique_id_buf).dup();
                string product_id = ((string) product_id_buf).dup();
                devices.add(new EngineVideoDeviceInfo(index, display_name, unique_id, product_id));
            }
            return devices;
        } finally {
            lease.release();
        }
    }

    public EngineSessionOwner create_session(EngineSessionConfig? config = null) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("call-session");
        try {
            EngineSessionOwner session = new EngineSessionOwner(
                (!) native_context,
                config ?? new EngineSessionConfig());
            session.take_activity_lease((owned) lease);
            return session;
        } catch (EngineError e) {
            lease.release();
            throw e;
        }
    }

    public Native.VideoEffectCapabilities get_video_effect_capabilities() throws EngineError {
        EngineContextActivityLease lease = acquire_activity("video-effect-capabilities");
        try {
            Native.VideoEffectCapabilities capabilities = {};
            throw_if_native_error(
                Native.context_get_video_effect_capabilities(native_context, out capabilities),
                "reading Google/libwebrtc video-effect capabilities");
            if (capabilities.abi_version != Native.ABI_VERSION) {
                throw new EngineError.NATIVE("Google/libwebrtc video-effect capability ABI mismatch");
            }
            return capabilities;
        } finally {
            lease.release();
        }
    }

    public EngineVideoEffectPipelineOwner create_video_effect_pipeline(uint64 logical_call_id) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("call-video-pipeline");
        try {
            EngineVideoEffectPipelineOwner pipeline = new EngineVideoEffectPipelineOwner(
                (!) native_context,
                logical_call_id);
            pipeline.take_activity_lease((owned) lease);
            return pipeline;
        } catch (EngineError e) {
            lease.release();
            throw e;
        }
    }

    public AudioMessageRecorderV2 create_audio_message_recorder(
            string output_path,
            AudioMessageWriter? writer = null) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("audio-message-recorder");
        try {
            AudioMessageRecorderV2 recorder;
            if (writer != null) {
                recorder = new AudioMessageRecorderV2.with_writer((!) native_context, output_path, (!) writer);
            } else {
                recorder = new AudioMessageRecorderV2((!) native_context, output_path);
            }
            recorder.take_activity_lease((owned) lease);
            return recorder;
        } catch (EngineError e) {
            lease.release();
            throw e;
        }
    }

    public VideoMessageRecorderV2 create_video_message_recorder(
            string output_path,
            VideoMessageWriter? writer = null,
            EngineVideoDeviceInfo? device = null,
            int width = VideoMessageRecorderV2.DEFAULT_WIDTH,
            int height = VideoMessageRecorderV2.DEFAULT_HEIGHT,
            int max_fps = VideoMessageRecorderV2.DEFAULT_MAX_FPS,
            bool include_audio_track = false) throws EngineError {
        EngineContextActivityLease lease = acquire_activity("video-message-recorder");
        string? unique_id = device != null ? ((!) device).unique_id : null;
        try {
            VideoMessageRecorderV2 recorder;
            if (writer != null) {
                recorder = new VideoMessageRecorderV2.with_writer(
                    (!) native_context,
                    output_path,
                    (!) writer,
                    width,
                    height,
                    max_fps,
                    unique_id,
                    include_audio_track);
            } else {
                recorder = new VideoMessageRecorderV2(
                    (!) native_context,
                    output_path,
                    width,
                    height,
                    max_fps,
                    unique_id,
                    include_audio_track);
            }
            recorder.take_activity_lease((owned) lease);
            return recorder;
        } catch (EngineError e) {
            lease.release();
            throw e;
        }
    }

    public void close() {
        state_mutex.lock();
        if (!closed && !close_requested) {
            close_requested = true;
            close_native_if_idle_locked();
        }
        state_mutex.unlock();
    }

    internal EngineContextActivityLease acquire_activity(string purpose) throws EngineError {
        state_mutex.lock();
        try {
            if (closed || close_requested || native_context == null) {
                throw new EngineError.CLOSED("Google/libwebrtc context is closed");
            }
            activity_count++;
            if (is_call_activity(purpose)) {
                call_activity_count++;
            } else {
                non_call_activity_count++;
            }
        } finally {
            state_mutex.unlock();
        }
        return new EngineContextActivityLease(this, purpose);
    }

    internal void release_activity(string purpose) {
        bool notify_idle = false;
        state_mutex.lock();
        if (activity_count == 0) {
            critical("Google/libwebrtc context activity lease underflow");
            state_mutex.unlock();
            return;
        }
        activity_count--;
        if (is_call_activity(purpose)) {
            if (call_activity_count == 0) {
                critical("Google/libwebrtc call activity lease underflow");
            } else {
                call_activity_count--;
            }
        } else {
            if (non_call_activity_count == 0) {
                critical("Google/libwebrtc non-call activity lease underflow");
            } else {
                non_call_activity_count--;
            }
        }
        close_native_if_idle_locked();
        notify_idle = activity_count == 0;
        state_mutex.unlock();
        if (notify_idle) became_idle();
    }

    public void force_close() {
        state_mutex.lock();
        if (!closed) {
            close_requested = true;
            closed = true;
            native_context = null;
        }
        state_mutex.unlock();
    }

    /**
     * Atomically retires an idle context. The idle check and transition to a
     * permanently closed state share state_mutex with acquire_activity(), so
     * no device, recorder, call-session or video-pipeline lease can enter
     * between the check and native worker teardown.
     */
    internal bool try_retire_if_idle() {
        state_mutex.lock();
        try {
            if (closed) return true;
            if (activity_count != 0) return false;
            close_requested = true;
            closed = true;
            native_context = null;
            return true;
        } finally {
            state_mutex.unlock();
        }
    }

    private void close_native_if_idle_locked() {
        if (closed || !close_requested || activity_count != 0) return;
        closed = true;
        if (native_context != null) {
            native_context = null;
        }
    }

    private static bool is_call_activity(string purpose) {
        return purpose == "call-session" || purpose == "call-video-pipeline";
    }

    ~EngineContext() {
        close();
    }
}

internal class PendingLocalIceCandidate : Object {
    public string? mid;
    public int mline_index;
    public string candidate;
    public PendingLocalIceCandidate(string? mid, int mline_index, string candidate) {
        this.mid = mid;
        this.mline_index = mline_index;
        this.candidate = candidate;
    }
}

public class EngineSessionOwner : Object {
    private Native.Session? native_session;
    private EngineContextActivityLease? activity_lease;
    private JingleRtp.LibwebrtcJingleAdapter adapter = new JingleRtp.LibwebrtcJingleAdapter();
    private bool conference_media_configured = false;
    private bool conference_local_description_pending = false;
    private bool pending_ice_gathering_complete = false;
    private ArrayList<PendingLocalIceCandidate> pending_local_ice_candidates =
        new ArrayList<PendingLocalIceCandidate>();
    private MainContext callback_context;
    private bool closed = false;
    private Native.NetworkPolicy network_policy = Native.NetworkPolicy.AUTOMATIC;
    private Mutex pending_video_mutex;
    private Dino.Plugins.JmiCallVideoFrame? pending_remote_video_frame = null;
    private Dino.Plugins.JmiCallVideoFrame? pending_local_video_frame = null;
    private bool video_dispatch_scheduled = false;

    public bool max_bundle_transport_policy { get; private set; default = true; }

    internal bool is_closed {
        get { return closed; }
    }

    public signal void local_description_ready(JingleRtp.LibwebrtcJingleDescription description);
    public signal void remote_description_set(JingleRtp.LibwebrtcSdpType type);
    public signal void local_ice_candidate(JingleRtp.LibwebrtcJingleIceCandidate candidate);
    public signal void ice_gathering_complete();
    public signal void remote_video_frame(Dino.Plugins.JmiCallVideoFrame frame);
    public signal void local_video_frame(Dino.Plugins.JmiCallVideoFrame frame);
    public signal void native_error(Native.Status status, string message);

    internal EngineSessionOwner(Native.Context context, EngineSessionConfig config) throws EngineError {
        callback_context = MainContext.ref_thread_default();

        Native.SessionConfig native_config = config.to_native();
        network_policy = config.network_policy;
        max_bundle_transport_policy = config.max_bundle;
        Native.Callbacks callbacks = Native.callbacks_default();
        callbacks.abi_version = Native.ABI_VERSION;
        callbacks.on_local_description = on_local_description;
        callbacks.on_local_description_prepared = on_local_description_prepared;
        callbacks.on_remote_description_set = on_remote_description_set;
        callbacks.on_ice_candidate = on_ice_candidate;
        callbacks.on_ice_gathering_complete = on_ice_gathering_complete;
        callbacks.on_error = on_error;
        callbacks.on_video_frame = on_video_frame;
        callbacks.on_local_video_frame = on_local_video_frame;

        Native.Session? created = null;
        throw_if_native_error(
            Native.session_new(context, ref native_config, ref callbacks, this, out created),
            "creating Google/libwebrtc session");
        native_session = (owned) created;

        foreach (EngineIceServer ice_server in config.ice_servers) {
            Native.Status status = Native.session_add_ice_server(
                native_session,
                ice_server.url,
                ice_server.username,
                ice_server.credential);
            if (status != Native.Status.OK) {
                close();
                throw_if_native_error(status, @"adding Google/libwebrtc ICE server $(ice_server.url)");
            }
        }
    }

    public bool has_local_content_map {
        get { return adapter.has_local_content_map; }
    }

    public bool has_remote_content_map {
        get { return adapter.has_remote_content_map; }
    }

    public bool copy_initial_offer_conference_media(
            out HashMap<string, string> content_names_by_media,
            out HashMap<string, Gee.List<JingleRtp.PayloadType>>
                payload_types_by_media) {
        return adapter.copy_initial_offer_conference_media(
            out content_names_by_media, out payload_types_by_media);
    }

    public void configure_conference_media(
            Gee.Map<string, string> content_names_by_media,
            Gee.Map<string, Gee.List<JingleRtp.PayloadType>>
                payload_types_by_media)
            throws EngineError, Jingle.IqError {
        require_open();
        adapter.configure_conference_media(
            content_names_by_media, payload_types_by_media);
        conference_media_configured = true;
    }

    public Native.SessionState get_state() throws EngineError {
        require_open();
        Native.SessionState state = {};
        throw_if_native_error(
            Native.session_get_state(native_session, out state),
            "reading Google/libwebrtc session state");
        if (state.abi_version != Native.ABI_VERSION) {
            throw new EngineError.NATIVE("Google/libwebrtc session state ABI mismatch");
        }
        return state;
    }

    public void set_local_audio_enabled(bool enabled) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_set_local_audio_enabled(native_session, enabled ? 1 : 0),
            enabled ? "enabling Google/libwebrtc local audio track" : "disabling Google/libwebrtc local audio track");
    }

    public void set_local_video_enabled(bool enabled) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_set_local_video_enabled(native_session, enabled ? 1 : 0),
            enabled ? "enabling Google/libwebrtc local video track" : "disabling Google/libwebrtc local video track");
    }

    public void send_dtmf(char digit, uint duration_ms = 250) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_send_dtmf(native_session, digit, duration_ms),
            "sending Google/libwebrtc DTMF digit");
    }

    public void play_local_dtmf_feedback(char digit, uint duration_ms = 120) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_play_local_dtmf_feedback(native_session, digit, duration_ms),
            "playing local Google/libwebrtc DTMF feedback");
    }

    public void push_synthetic_video_frame(int width, int height) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_push_synthetic_video_frame(native_session, width, height),
            "pushing synthetic Google/libwebrtc video frame");
    }

    public void start_video_capture(EngineVideoDeviceInfo device, int width = 640, int height = 480, int max_fps = 30) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_start_video_capture(native_session, device.unique_id, width, height, max_fps),
            "starting Google/libwebrtc camera capture");
    }

    public void stop_video_capture() throws EngineError {
        require_open();
        throw_if_native_error(
            Native.session_stop_video_capture(native_session),
            "stopping Google/libwebrtc camera capture");
    }

    internal void attach_video_effect_pipeline(
            Native.VideoPipeline pipeline,
            bool preview_publisher) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.video_pipeline_attach_session(
                pipeline,
                native_session,
                preview_publisher ? 1 : 0),
            "attaching Google/libwebrtc video-effect pipeline");
    }

    internal void detach_video_effect_pipeline(Native.VideoPipeline pipeline) throws EngineError {
        require_open();
        throw_if_native_error(
            Native.video_pipeline_detach_session(pipeline, native_session),
            "detaching Google/libwebrtc video-effect pipeline");
    }

    public void create_offer() throws EngineError {
        require_open();
        if (conference_media_configured) {
            prepare_local_conference_description(Native.SdpType.OFFER);
            return;
        }
        throw_if_native_error(
            Native.session_create_offer(native_session),
            "creating Google/libwebrtc offer");
    }

    public void create_answer() throws EngineError {
        require_open();
        if (conference_media_configured) {
            prepare_local_conference_description(Native.SdpType.ANSWER);
            return;
        }
        throw_if_native_error(
            Native.session_create_answer(native_session),
            "creating Google/libwebrtc answer");
    }

    private void prepare_local_conference_description(Native.SdpType type) throws EngineError {
        if (conference_local_description_pending) {
            throw new EngineError.PROTOCOL("A conference local description is already pending");
        }
        conference_local_description_pending = true;
        try {
            throw_if_native_error(Native.session_prepare_local_description(native_session, type),
                "preparing native conference SDP");
        } catch (EngineError e) {
            conference_local_description_pending = false;
            throw e;
        }
    }

    public JingleRtp.LibwebrtcJingleDescription set_remote_description_from_jingle(
            JingleRtp.LibwebrtcSdpType type,
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents,
            Jingle.Role local_role,
            JingleRtp.SdpBundlePolicy bundle_policy = JingleRtp.SdpBundlePolicy.NONE) throws EngineError, Jingle.IqError {
        require_open();
        JingleRtp.LibwebrtcJingleDescription description =
            adapter.remote_description_from_jingle_contents(
                type, contents, local_role, bundle_policy);
        throw_if_native_error(
            Native.session_set_remote_description(native_session, Native.sdp_type_to_native(type), description.sdp),
            "setting Google/libwebrtc remote description");
        return description;
    }

    internal JingleRtp.LibwebrtcJingleDescription set_remote_description_from_jingle_with_bundle(
            JingleRtp.LibwebrtcSdpType type,
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents,
            Jingle.Role local_role,
            JingleRtp.SdpBundlePolicy bundle_policy,
            Gee.List<string>? bundle_content_names = null) throws EngineError, Jingle.IqError {
        require_open();
        JingleRtp.LibwebrtcJingleDescription description =
            adapter.remote_description_from_jingle_contents(
                type, contents, local_role, bundle_policy);
        if (bundle_content_names != null) {
            apply_muji_bundle_content_names(
                description.session,
                description.contents,
                (!) bundle_content_names);
            string bundled_sdp = adapter.session_to_native_sdp(description.session);
            JingleRtp.SdpSession bundled_session =
                JingleRtp.SdpBridge.session_from_sdp(bundled_sdp);
            description = new JingleRtp.LibwebrtcJingleDescription(
                type,
                bundled_sdp,
                bundled_session,
                description.contents);
        }
        throw_if_native_error(
            Native.session_set_remote_description(native_session, Native.sdp_type_to_native(type), description.sdp),
            "setting Google/libwebrtc remote description");
        return description;
    }

    private static void apply_muji_bundle_content_names(
            JingleRtp.SdpSession session,
            Gee.List<JingleRtp.LibwebrtcJingleContent> contents,
            Gee.List<string> bundle_content_names) throws Jingle.IqError {
        session.bundle_mids.clear();
        if (bundle_content_names.is_empty) return;
        if (session.media_sections.size != contents.size) {
            throw new Jingle.IqError.BAD_REQUEST(
                "Jingle content count mismatch while applying MUJI BUNDLE");
        }

        var internal_mid_by_content_name = new HashMap<string, string>();
        for (int i = 0; i < contents.size; i++) {
            string content_name = contents[i].content_name;
            string? internal_mid = session.media_sections[i].mid;
            require_muji_bundle_mid(internal_mid);
            if (internal_mid_by_content_name.has_key(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "duplicate Jingle content while applying MUJI BUNDLE");
            }
            internal_mid_by_content_name[content_name] = (!) internal_mid;
        }

        var seen_content_names = new HashSet<string>();
        foreach (string content_name in bundle_content_names) {
            if (seen_content_names.contains(content_name)) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "duplicate Jingle content in MUJI BUNDLE group");
            }
            seen_content_names.add(content_name);
            string? internal_mid =
                internal_mid_by_content_name[content_name];
            if (internal_mid == null) {
                throw new Jingle.IqError.BAD_REQUEST(
                    "MUJI BUNDLE group references an unknown Jingle content");
            }
            session.bundle_mids.add((!) internal_mid);
        }
    }

    private static void require_muji_bundle_mid(string? mid)
            throws Jingle.IqError {
        if (mid == null || ((!) mid) == "" ||
                ((!) mid).contains(" ") ||
                ((!) mid).contains("\r") ||
                ((!) mid).contains("\n")) {
            throw new Jingle.IqError.BAD_REQUEST(
                "invalid internal SDP MID while applying MUJI BUNDLE");
        }
    }

    public JingleRtp.LibwebrtcRemoteIceCandidate add_remote_jingle_candidate(
            string content_name,
            JingleIceUdp.Candidate candidate) throws EngineError, Jingle.IqError {
        require_open();
        JingleRtp.LibwebrtcRemoteIceCandidate mapped =
            adapter.remote_jingle_candidate_to_webrtc(content_name, candidate);
        throw_if_native_error(
            Native.session_add_remote_ice_candidate(
                native_session,
                mapped.sdp_mid,
                mapped.sdp_mline_index,
                mapped.candidate),
            "adding Google/libwebrtc remote ICE candidate");
        return mapped;
    }

    public void close() {
        if (closed) return;
        closed = true;
        pending_local_ice_candidates.clear();
        pending_ice_gathering_complete = false;
        conference_local_description_pending = false;
        if (native_session != null) {
            Native.session_close(native_session);
            native_session = null;
        }
        release_activity_lease();
    }

    internal void take_activity_lease(owned EngineContextActivityLease lease) {
        activity_lease = (owned) lease;
    }

    ~EngineSessionOwner() {
        close();
    }

    private void release_activity_lease() {
        if (activity_lease == null) return;
        ((!) activity_lease).release();
        activity_lease = null;
    }

    private void require_open() throws EngineError {
        if (closed || native_session == null) {
            throw new EngineError.CLOSED("Google/libwebrtc session is closed");
        }
    }

    private void dispatch_to_context(owned SourceFunc callback) {
        var source = new IdleSource();
        source.set_callback((owned) callback);
        source.attach(callback_context);
    }

    private void dispatch_local_description_prepared(Native.SdpType type, string sdp) {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            try {
                if (!conference_media_configured || !conference_local_description_pending) {
                    throw new EngineError.PROTOCOL("Unexpected prepared conference description");
                }
                string projected = adapter.prepare_conference_local_description(
                    Native.sdp_type_from_native(type), sdp);
                throw_if_native_error(Native.session_set_local_description(native_session, type, projected),
                    "committing projected conference SDP");
            } catch (Error e) {
                native_error(Native.Status.PARSE_ERROR, e.message);
            }
            return Source.REMOVE;
        });
    }

    private void dispatch_local_description(Native.SdpType type, string sdp) {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            try {
                JingleRtp.LibwebrtcJingleDescription description =
                    adapter.local_description_to_jingle(
                        Native.sdp_type_from_native(type),
                        sdp,
                        type == Native.SdpType.OFFER ? Jingle.Role.INITIATOR : Jingle.Role.RESPONDER,
                        network_policy == Native.NetworkPolicy.LOW_BANDWIDTH_2G);
                conference_local_description_pending = false;
                local_description_ready(description);
                if (closed) return Source.REMOVE;
                foreach (PendingLocalIceCandidate candidate in pending_local_ice_candidates) {
                    local_ice_candidate(adapter.local_ice_candidate_to_jingle(
                        candidate.mid, candidate.mline_index, candidate.candidate));
                    if (closed) return Source.REMOVE;
                }
                pending_local_ice_candidates.clear();
                if (pending_ice_gathering_complete) {
                    pending_ice_gathering_complete = false;
                    ice_gathering_complete();
                }
            } catch (Jingle.IqError e) {
                native_error(Native.Status.PARSE_ERROR, e.message);
            }
            return Source.REMOVE;
        });
    }

    private void dispatch_remote_description_set(Native.SdpType type) {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            remote_description_set(Native.sdp_type_from_native(type));
            return Source.REMOVE;
        });
    }

    private void dispatch_local_ice_candidate(string? sdp_mid, int sdp_mline_index, string candidate) {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            if (conference_local_description_pending) {
                if (pending_local_ice_candidates.size >= 256) {
                    native_error(Native.Status.PARSE_ERROR, "Too many ICE candidates before conference SDP commit");
                    return Source.REMOVE;
                }
                pending_local_ice_candidates.add(new PendingLocalIceCandidate(sdp_mid, sdp_mline_index, candidate));
                return Source.REMOVE;
            }
            try {
                local_ice_candidate(adapter.local_ice_candidate_to_jingle(
                    sdp_mid,
                    sdp_mline_index,
                    candidate));
            } catch (Jingle.IqError e) {
                native_error(Native.Status.PARSE_ERROR, e.message);
            }
            return Source.REMOVE;
        });
    }

    private void dispatch_ice_gathering_complete() {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            if (conference_local_description_pending) {
                pending_ice_gathering_complete = true;
            } else {
                ice_gathering_complete();
            }
            return Source.REMOVE;
        });
    }

    private void dispatch_video_frame(uint8* bgra_data, int width, int height, int stride, uint64 frame_id, bool local) {
        if (bgra_data == null || width <= 0 || height <= 0 || stride < width * 4) {
            return;
        }

        size_t byte_count = (size_t) stride * (size_t) height;
        if (byte_count == 0 || byte_count > int.MAX) {
            return;
        }

        // The native callback owns bgra_data only until it returns. Copy it
        // directly into one GBytes allocation so the queued UI frame remains
        // valid without a zero-filled intermediate array or another ownership
        // conversion copy.
        unowned uint8[] frame_view = (uint8[]) bgra_data;
        frame_view.length = (int) byte_count;
        Bytes frame_data = new Bytes(frame_view);

        Dino.Plugins.JmiCallVideoFrame frame =
            new Dino.Plugins.JmiCallVideoFrame(frame_data, width, height, stride, frame_id);
        bool schedule_dispatch = false;
        pending_video_mutex.lock();
        if (local) {
            pending_local_video_frame = frame;
        } else {
            pending_remote_video_frame = frame;
        }
        if (!video_dispatch_scheduled) {
            video_dispatch_scheduled = true;
            schedule_dispatch = true;
        }
        pending_video_mutex.unlock();
        if (!schedule_dispatch) return;

        dispatch_to_context(() => {
            Dino.Plugins.JmiCallVideoFrame? remote = null;
            Dino.Plugins.JmiCallVideoFrame? local_frame = null;
            pending_video_mutex.lock();
            remote = pending_remote_video_frame;
            local_frame = pending_local_video_frame;
            pending_remote_video_frame = null;
            pending_local_video_frame = null;
            video_dispatch_scheduled = false;
            pending_video_mutex.unlock();
            if (closed) return Source.REMOVE;
            if (remote != null) remote_video_frame((!) remote);
            if (local_frame != null) local_video_frame((!) local_frame);
            return Source.REMOVE;
        });
    }

    private void dispatch_native_error(Native.Status status, string message) {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            native_error(status, message);
            return Source.REMOVE;
        });
    }

    private static void on_local_description_prepared(
            Native.Session? session, Native.SdpType type, string? sdp, void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_local_description_prepared(type, (sdp ?? "").dup());
    }

    private static void on_local_description(Native.Session? session, Native.SdpType type, string? sdp, void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_local_description(type, (sdp ?? "").dup());
    }

    private static void on_remote_description_set(Native.Session? session, Native.SdpType type, void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_remote_description_set(type);
    }

    private static void on_ice_candidate(
            Native.Session? session,
            string? sdp_mid,
            int sdp_mline_index,
            string? candidate,
            void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_local_ice_candidate(
            sdp_mid == null ? null : ((!) sdp_mid).dup(),
            sdp_mline_index,
            (candidate ?? "").dup());
    }

    private static void on_ice_gathering_complete(Native.Session? session, void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_ice_gathering_complete();
    }

    private static void on_error(Native.Session? session, Native.Status status, string? message, void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_native_error(status, (message ?? Native.status_to_string(status)).dup());
    }

    private static void on_video_frame(
            Native.Session? session,
            uint8* bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id,
            void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_video_frame(bgra_data, width, height, stride, frame_id, false);
    }

    private static void on_local_video_frame(
            Native.Session? session,
            uint8* bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id,
            void* user_data) {
        unowned EngineSessionOwner self = (EngineSessionOwner) user_data;
        self.dispatch_video_frame(bgra_data, width, height, stride, frame_id, true);
    }
}

internal static void throw_if_native_error(Native.Status status, string action) throws EngineError {
    if (status == Native.Status.OK) return;
    throw new EngineError.NATIVE(@"Google/libwebrtc $(action) failed: $(Native.status_to_string(status))");
}

}
