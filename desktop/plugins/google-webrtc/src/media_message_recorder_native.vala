namespace Dino.Plugins.GoogleWebrtc {

/**
 * Thin Vala owner for the native media-message-recorder ABI.
 *
 * Recorder ownership and capture live in the external Google/libwebrtc worker.
 * Copied audio/video callbacks feed the message writers in the DinoX process;
 * synthetic frames are exposed only for deterministic regression tests.
 */
public class MediaMessageRecorderNative : Object {
    private Native.MediaRecorder? recorder;
    private MainContext callback_context;
    private bool closed = false;
    private int accepting_media_frames = 0;

    public Native.MediaRecorderKind kind { get; private set; }
    public string output_path { get; private set; }
    public string mime_type { get; private set; }

    public signal void started();
    public signal void stopped();
    public signal void native_error(Native.Status status, string message);
    public signal void audio_frame(Bytes pcm_data, int sample_rate, int channels, int bytes_per_sample, uint64 frame_id);
    public signal void video_frame(Bytes bgra_data, int width, int height, int stride, uint64 frame_id);

    public MediaMessageRecorderNative(
        Native.Context context,
        Native.MediaRecorderKind kind,
        string output_path,
        string mime_type,
        int width = 640,
        int height = 480,
        int max_fps = 24,
        string? video_device_unique_id = null,
        bool include_audio_track = false) throws EngineError {
        this.kind = kind;
        this.output_path = output_path;
        this.mime_type = mime_type;
        // Recorder sessions can be constructed from a background start thread.
        // UI-facing callbacks must still be marshalled to the GTK/default main
        // context, not to the worker's thread-default context.
        this.callback_context = MainContext.default();

        Native.MediaRecorderConfig config = Native.media_recorder_config_default();
        config.kind = kind;
        config.output_path = output_path;
        config.mime_type = mime_type;
        config.width = width;
        config.height = height;
        config.max_fps = max_fps;
        config.video_device_unique_id = video_device_unique_id;
        config.include_audio_track = include_audio_track ? 1 : 0;

        Native.MediaRecorderCallbacks callbacks = Native.media_recorder_callbacks_default();
        callbacks.on_started = on_started;
        callbacks.on_stopped = on_stopped;
        callbacks.on_error = on_error;
        callbacks.on_audio_frame = on_audio_frame;
        callbacks.on_video_frame = on_video_frame;
        Native.MediaRecorder? native_recorder = null;
        Native.Status status = Native.media_recorder_new(
            context,
            ref config,
            ref callbacks,
            this,
            out native_recorder);
        if (status != Native.Status.OK || native_recorder == null) {
            throw new EngineError.NATIVE("Could not create native media recorder: %s".printf(status.to_log_string()));
        }
        this.recorder = (owned) native_recorder;
    }

    public Native.MediaRecorderState get_state() throws EngineError {
        Native.MediaRecorderState state;
        Native.Status status = Native.media_recorder_get_state(recorder, out state);
        if (status != Native.Status.OK) {
            throw new EngineError.NATIVE("Could not query native media recorder state: %s".printf(status.to_log_string()));
        }
        return state;
    }

    public Native.Status start() {
        AtomicInt.set(ref accepting_media_frames, 1);
        Native.Status status = Native.media_recorder_start(recorder);
        if (status != Native.Status.OK) {
            AtomicInt.set(ref accepting_media_frames, 0);
        }
        return status;
    }

    public Native.Status stop() {
        // The PCM/BGRA callback is copied to the GTK main context. Frames that
        // were already queued there must not reach a writer after stop() has
        // finalized its output file.
        AtomicInt.set(ref accepting_media_frames, 0);
        return Native.media_recorder_stop(recorder);
    }

    public Native.Status cancel() {
        AtomicInt.set(ref accepting_media_frames, 0);
        Native.Status status = Native.media_recorder_cancel(recorder);
        if (status == Native.Status.OK) {
            closed = true;
        }
        return status;
    }

    public Native.Status push_synthetic_frame() {
        return Native.media_recorder_push_synthetic_frame(recorder);
    }

    ~MediaMessageRecorderNative() {
        AtomicInt.set(ref accepting_media_frames, 0);
        if (recorder != null && !closed) {
            Native.media_recorder_cancel(recorder);
            closed = true;
        }
    }

    private void dispatch_to_context(owned SourceFunc callback) {
        var source = new IdleSource();
        source.set_callback((owned) callback);
        source.attach(callback_context);
    }

    private void dispatch_started() {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            started();
            return Source.REMOVE;
        });
    }

    private void dispatch_stopped() {
        dispatch_to_context(() => {
            if (closed) return Source.REMOVE;
            stopped();
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

    private void dispatch_audio_frame(
            uint8* pcm_data,
            size_t byte_count,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) {
        if (AtomicInt.get(ref accepting_media_frames) == 0 ||
                pcm_data == null || byte_count == 0 || byte_count > int.MAX ||
                sample_rate <= 0 || channels <= 0 || bytes_per_sample <= 0) {
            return;
        }

        uint8[] copy = new uint8[(int) byte_count];
        Memory.copy(copy, pcm_data, byte_count);
        Bytes frame_data = new Bytes(copy);

        dispatch_to_context(() => {
            if (closed || AtomicInt.get(ref accepting_media_frames) == 0) return Source.REMOVE;
            audio_frame(frame_data, sample_rate, channels, bytes_per_sample, frame_id);
            return Source.REMOVE;
        });
    }

    private void dispatch_video_frame(uint8* bgra_data, int width, int height, int stride, uint64 frame_id) {
        if (AtomicInt.get(ref accepting_media_frames) == 0 ||
                bgra_data == null || width <= 0 || height <= 0 || stride < width * 4) {
            return;
        }

        size_t byte_count = (size_t) stride * (size_t) height;
        if (byte_count == 0 || byte_count > int.MAX) {
            return;
        }

        uint8[] copy = new uint8[(int) byte_count];
        Memory.copy(copy, bgra_data, byte_count);
        Bytes frame_data = new Bytes(copy);

        dispatch_to_context(() => {
            if (closed || AtomicInt.get(ref accepting_media_frames) == 0) return Source.REMOVE;
            video_frame(frame_data, width, height, stride, frame_id);
            return Source.REMOVE;
        });
    }

    private static void on_started(Native.MediaRecorder? recorder, void* user_data) {
        unowned MediaMessageRecorderNative self = (MediaMessageRecorderNative) user_data;
        self.dispatch_started();
    }

    private static void on_stopped(Native.MediaRecorder? recorder, void* user_data) {
        unowned MediaMessageRecorderNative self = (MediaMessageRecorderNative) user_data;
        self.dispatch_stopped();
    }

    private static void on_error(Native.MediaRecorder? recorder, Native.Status status, string? message, void* user_data) {
        unowned MediaMessageRecorderNative self = (MediaMessageRecorderNative) user_data;
        self.dispatch_native_error(status, (message ?? Native.status_to_string(status)).dup());
    }

    private static void on_audio_frame(
            Native.MediaRecorder? recorder,
            uint8* pcm_data,
            size_t byte_count,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id,
            void* user_data) {
        unowned MediaMessageRecorderNative self = (MediaMessageRecorderNative) user_data;
        self.dispatch_audio_frame(pcm_data, byte_count, sample_rate, channels, bytes_per_sample, frame_id);
    }

    private static void on_video_frame(
            Native.MediaRecorder? recorder,
            uint8* bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id,
            void* user_data) {
        unowned MediaMessageRecorderNative self = (MediaMessageRecorderNative) user_data;
        self.dispatch_video_frame(bgra_data, width, height, stride, frame_id);
    }
}

}
