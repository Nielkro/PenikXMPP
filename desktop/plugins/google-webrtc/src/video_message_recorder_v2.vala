namespace Dino.Plugins.GoogleWebrtc {

/**
 * Video-message recorder layer above the native media-recorder ABI.
 *
 * The Linux path captures camera frames through libwebrtc, optionally captures
 * microphone PCM through the same native recorder, and writes interoperable
 * MP4/H.264 + AAC-LC files without a GStreamer recorder fallback.
 */
public class VideoMessageRecorderV2 : Object {
    public const string MIME_TYPE = "video/mp4";
    public const string VIDEO_CODEC = "h264";
    public const string AUDIO_CODEC_NONE = "none";
    public const string AUDIO_CODEC_AAC_LC = "aac-lc";
    public const string AUDIO_CODEC = AUDIO_CODEC_NONE;
    public const int EXPECTED_AUDIO_SAMPLE_RATE = 48000;
    public const int EXPECTED_AUDIO_CHANNELS = 1;
    public const int EXPECTED_AUDIO_BYTES_PER_SAMPLE = 2;
    public const int DEFAULT_WIDTH = 640;
    public const int DEFAULT_HEIGHT = 480;
    public const int DEFAULT_MAX_FPS = 24;
    private const uint64 START_PREROLL_MAX_FRAMES = 8;
    private const int START_PREWARM_MS = 700;

    private MediaMessageRecorderNative recorder;
    private VideoMessageWriter? writer = null;
    private EngineContextActivityLease? activity_lease = null;
    private bool closed = false;
    private bool live_video_capture = false;
    private uint64 raw_video_frame_count = 0;
    private int64 video_writer_start_us = 0;
    private uint64 video_writer_frame_count = 0;
    private Bytes? last_writer_video_frame = null;
    private int last_writer_video_width = 0;
    private int last_writer_video_height = 0;
    private int last_writer_video_stride = 0;
    private uint64 last_writer_video_frame_id = 0;
    private int64 live_prewarm_start_us = 0;
    private uint64 audio_writer_pcm_frame_count = 0;
    private double wallclock_duration_seconds = 0.0;

    public string output_path { get; private set; }
    public int configured_width { get; private set; }
    public int configured_height { get; private set; }
    public int configured_max_fps { get; private set; }
    public bool include_audio_track { get; private set; }
    public bool file_writer_enabled {
        get { return writer != null; }
    }
    public VideoMessageWriterState file_writer_state {
        get { return writer != null ? ((!) writer).state : VideoMessageWriterState.IDLE; }
    }
    public Native.MediaRecorderState state {
        get {
            try {
                return recorder.get_state();
            } catch (Error e) {
                return Native.MediaRecorderState.FAILED;
            }
        }
    }
    public uint64 frame_callback_count { get; private set; default = 0; }
    public uint64 audio_frame_callback_count { get; private set; default = 0; }
    public uint64 audio_pcm_frame_count { get; private set; default = 0; }
    public uint64 last_frame_id { get; private set; default = 0; }
    public uint64 last_audio_frame_id { get; private set; default = 0; }
    public int width { get; private set; default = 0; }
    public int height { get; private set; default = 0; }
    public int stride { get; private set; default = 0; }
    public size_t last_frame_byte_count { get; private set; default = 0; }
    public Bytes? latest_preview_frame { get; private set; default = null; }
    public double duration_seconds {
        get {
            if (live_video_capture && video_writer_start_us != 0) {
                return wallclock_duration_seconds;
            }
            if (configured_max_fps <= 0) return 0.0;
            return (double) frame_callback_count / (double) configured_max_fps;
        }
    }

    public signal void started();
    public signal void stopped();
    public signal void duration_changed(double seconds);
    public signal void recording_error(string message);
    public signal void frame_received(Bytes bgra_data, int width, int height, int stride, uint64 frame_id);
    public signal void audio_frame_received(Bytes pcm_data, int sample_rate, int channels, int bytes_per_sample, uint64 frame_id);
    public signal void preview_frame_changed(Bytes bgra_data, int width, int height, int stride);

    public VideoMessageRecorderV2(
            Native.Context context,
            string output_path,
            int width = DEFAULT_WIDTH,
            int height = DEFAULT_HEIGHT,
            int max_fps = DEFAULT_MAX_FPS,
            string? video_device_unique_id = null,
            bool include_audio_track = false) throws EngineError {
        validate_geometry(width, height, max_fps);
        this.output_path = output_path;
        this.configured_width = width;
        this.configured_height = height;
        this.configured_max_fps = max_fps;
        this.include_audio_track = include_audio_track;
        this.live_video_capture = video_device_unique_id != null && (!) video_device_unique_id != "";
        recorder = new MediaMessageRecorderNative(
            context,
            Native.MediaRecorderKind.VIDEO,
            output_path,
            MIME_TYPE,
            width,
            height,
            max_fps,
            video_device_unique_id,
            include_audio_track);
        recorder.started.connect(() => {
            started();
        });
        recorder.stopped.connect(() => {
            stopped();
        });
        recorder.native_error.connect((status, message) => {
            recording_error(@"$(status.to_log_string()): $(message)");
        });
        recorder.video_frame.connect(on_video_frame);
        recorder.audio_frame.connect(on_audio_frame);
    }

    public VideoMessageRecorderV2.with_writer(
            Native.Context context,
            string output_path,
            VideoMessageWriter writer,
            int width = DEFAULT_WIDTH,
            int height = DEFAULT_HEIGHT,
            int max_fps = DEFAULT_MAX_FPS,
            string? video_device_unique_id = null,
            bool include_audio_track = false) throws EngineError {
        this(context, output_path, width, height, max_fps, video_device_unique_id, include_audio_track);
        this.writer = writer;
    }

    public void start() throws EngineError {
        reset_counters();
        Native.Status status = recorder.start();
        if (status != Native.Status.OK) {
            if (writer != null) {
                ((!) writer).cancel();
            }
            throw_if_native_error(status, "starting video-message recorder v2");
        }
    }

    public void stop(bool defer_activity_release = false) throws EngineError {
        int64 stop_time_us = GLib.get_monotonic_time();
        throw_if_native_error(recorder.stop(), "stopping video-message recorder v2");
        closed = true;
        if (!defer_activity_release) {
            release_activity_lease();
        }
        try {
            if (writer != null && ((!) writer).state == VideoMessageWriterState.STARTED) {
                pad_video_writer_to_time(stop_time_us);
                ((!) writer).finish();
            } else if (writer != null && frame_callback_count == 0) {
                throw new VideoMessageWriterError.FINALIZE_FAILED("No video frames were recorded");
            }
        } catch (VideoMessageWriterError e) {
            throw new EngineError.NATIVE("Could not finalize video-message writer: %s".printf(e.message));
        }
    }

    public void cancel() throws EngineError {
        if (closed) {
            release_activity_lease();
            return;
        }
        throw_if_native_error(recorder.cancel(), "cancelling video-message recorder v2");
        if (writer != null) {
            ((!) writer).cancel();
        }
        closed = true;
        release_activity_lease();
    }

    public void push_synthetic_frame() throws EngineError {
        throw_if_native_error(recorder.push_synthetic_frame(), "pushing video-message recorder v2 synthetic frame");
    }

    internal void take_activity_lease(owned EngineContextActivityLease lease) {
        activity_lease = (owned) lease;
    }

    internal void release_completed_activity() {
        if (closed) {
            release_activity_lease();
        }
    }

    ~VideoMessageRecorderV2() {
        if (!closed) {
            recorder.cancel();
            closed = true;
        }
        release_activity_lease();
    }

    private void release_activity_lease() {
        if (activity_lease == null) return;
        ((!) activity_lease).release();
        activity_lease = null;
    }

    private void reset_counters() {
        frame_callback_count = 0;
        audio_frame_callback_count = 0;
        audio_pcm_frame_count = 0;
        raw_video_frame_count = 0;
        last_frame_id = 0;
        last_audio_frame_id = 0;
        width = 0;
        height = 0;
        stride = 0;
        last_frame_byte_count = 0;
        latest_preview_frame = null;
        video_writer_start_us = 0;
        video_writer_frame_count = 0;
        last_writer_video_frame = null;
        last_writer_video_width = 0;
        last_writer_video_height = 0;
        last_writer_video_stride = 0;
        last_writer_video_frame_id = 0;
        live_prewarm_start_us = 0;
        audio_writer_pcm_frame_count = 0;
        wallclock_duration_seconds = 0.0;
    }

    private void on_video_frame(Bytes bgra_data, int frame_width, int frame_height, int frame_stride, uint64 frame_id) {
        if (frame_width <= 0 || frame_height <= 0 || frame_stride < frame_width * 4) {
            recording_error("Invalid BGRA frame metadata");
            return;
        }

        size_t byte_count = bgra_data.get_size();
        size_t expected_minimum = (size_t) frame_stride * (size_t) frame_height;
        if (byte_count < expected_minimum || byte_count == 0) {
            recording_error("Invalid BGRA frame size");
            return;
        }

        raw_video_frame_count++;
        if (live_video_capture &&
                raw_video_frame_count <= START_PREROLL_MAX_FRAMES &&
                is_probably_start_preroll_frame(bgra_data, frame_width, frame_height, frame_stride)) {
            return;
        }
        int64 frame_time_us = GLib.get_monotonic_time();
        if (live_video_capture) {
            if (live_prewarm_start_us == 0) {
                live_prewarm_start_us = frame_time_us;
                return;
            }
            if (frame_time_us - live_prewarm_start_us < START_PREWARM_MS * 1000) {
                return;
            }
        }

        try {
            if (writer != null) {
                if (((!) writer).state == VideoMessageWriterState.IDLE ||
                        ((!) writer).state == VideoMessageWriterState.CANCELLED) {
                    ((!) writer).start(new VideoMessageWriterConfig(
                        output_path,
                        MIME_TYPE,
                        VIDEO_CODEC,
                        include_audio_track ? AUDIO_CODEC_AAC_LC : AUDIO_CODEC_NONE,
                        frame_width,
                        frame_height,
                        configured_max_fps));
                }
                write_video_frame_with_timing(
                    (!) writer,
                    bgra_data,
                    frame_width,
                    frame_height,
                    frame_stride,
                    frame_id,
                    frame_time_us);
            }
        } catch (VideoMessageWriterError e) {
            recording_error("Could not write BGRA frame: %s".printf(e.message));
            return;
        }

        frame_callback_count++;
        last_frame_id = frame_id;
        width = frame_width;
        height = frame_height;
        stride = frame_stride;
        last_frame_byte_count = byte_count;
        latest_preview_frame = bgra_data;

        frame_received(bgra_data, frame_width, frame_height, frame_stride, frame_id);
        preview_frame_changed(bgra_data, frame_width, frame_height, frame_stride);
        duration_changed(duration_seconds);
    }

    private void on_audio_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) {
        if (!include_audio_track) {
            return;
        }
        if (sample_rate <= 0 || channels <= 0 || bytes_per_sample <= 0) {
            recording_error("Invalid video-message PCM frame metadata");
            return;
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = channels * bytes_per_sample;
        if (byte_count == 0 || bytes_per_pcm_frame <= 0 || byte_count % bytes_per_pcm_frame != 0) {
            recording_error("Invalid video-message PCM frame size");
            return;
        }

        try {
            if (writer != null && ((!) writer).state == VideoMessageWriterState.STARTED) {
                Bytes writer_frame = MediaMessagePcmUtil.apply_start_fade_in(
                    pcm_data,
                    sample_rate,
                    channels,
                    bytes_per_sample,
                    audio_writer_pcm_frame_count);
                ((!) writer).write_pcm_frame(
                    writer_frame,
                    sample_rate,
                    channels,
                    bytes_per_sample,
                    frame_id);
                audio_writer_pcm_frame_count += (uint64) (byte_count / bytes_per_pcm_frame);
            }
        } catch (VideoMessageWriterError e) {
            recording_error("Could not write video-message PCM frame: %s".printf(e.message));
            return;
        }

        audio_frame_callback_count++;
        last_audio_frame_id = frame_id;
        audio_pcm_frame_count += (uint64) (byte_count / bytes_per_pcm_frame);
        audio_frame_received(pcm_data, sample_rate, channels, bytes_per_sample, frame_id);
    }

    private void write_video_frame_with_timing(
            VideoMessageWriter active_writer,
            Bytes bgra_data,
            int frame_width,
            int frame_height,
            int frame_stride,
            uint64 frame_id,
            int64 now_us) throws VideoMessageWriterError {
        if (!live_video_capture) {
            active_writer.write_bgra_frame(bgra_data, frame_width, frame_height, frame_stride, frame_id);
            remember_writer_frame(bgra_data, frame_width, frame_height, frame_stride, frame_id);
            video_writer_frame_count++;
            return;
        }

        if (video_writer_start_us == 0) {
            video_writer_start_us = now_us;
        }
        int64 elapsed_now_us = now_us > video_writer_start_us ? now_us - video_writer_start_us : 0;
        wallclock_duration_seconds = (double) elapsed_now_us / 1000000.0;

        uint64 target_frame_count = wallclock_target_frame_count(now_us);
        if (target_frame_count <= video_writer_frame_count) {
            remember_writer_frame(bgra_data, frame_width, frame_height, frame_stride, frame_id);
            return;
        }

        if (last_writer_video_frame != null && target_frame_count > video_writer_frame_count + 1) {
            while (video_writer_frame_count + 1 < target_frame_count) {
                active_writer.write_bgra_frame(
                    (!) last_writer_video_frame,
                    last_writer_video_width,
                    last_writer_video_height,
                    last_writer_video_stride,
                    last_writer_video_frame_id);
                video_writer_frame_count++;
            }
        }

        active_writer.write_bgra_frame(bgra_data, frame_width, frame_height, frame_stride, frame_id);
        video_writer_frame_count++;
        remember_writer_frame(bgra_data, frame_width, frame_height, frame_stride, frame_id);
    }

    private void remember_writer_frame(Bytes bgra_data, int frame_width, int frame_height, int frame_stride, uint64 frame_id) {
        last_writer_video_frame = bgra_data;
        last_writer_video_width = frame_width;
        last_writer_video_height = frame_height;
        last_writer_video_stride = frame_stride;
        last_writer_video_frame_id = frame_id;
    }

    private uint64 wallclock_target_frame_count(int64 now_us) {
        if (configured_max_fps <= 0 || video_writer_start_us == 0) {
            return video_writer_frame_count;
        }
        int64 elapsed_us = now_us > video_writer_start_us ? now_us - video_writer_start_us : 0;
        uint64 target = (uint64) ((((uint64) elapsed_us * (uint64) configured_max_fps) + 999999) / 1000000);
        return target > 0 ? target : 1;
    }

    private void pad_video_writer_to_time(int64 stop_time_us) throws VideoMessageWriterError {
        if (!live_video_capture ||
                writer == null ||
                last_writer_video_frame == null ||
                video_writer_start_us == 0 ||
                ((!) writer).state != VideoMessageWriterState.STARTED) {
            return;
        }
        int64 elapsed_stop_us = stop_time_us > video_writer_start_us ? stop_time_us - video_writer_start_us : 0;
        wallclock_duration_seconds = (double) elapsed_stop_us / 1000000.0;
        uint64 target_frame_count = wallclock_target_frame_count(stop_time_us);
        while (video_writer_frame_count < target_frame_count) {
            ((!) writer).write_bgra_frame(
                (!) last_writer_video_frame,
                last_writer_video_width,
                last_writer_video_height,
                last_writer_video_stride,
                last_writer_video_frame_id);
            video_writer_frame_count++;
        }
    }

    private static bool is_probably_start_preroll_frame(Bytes bgra_data, int frame_width, int frame_height, int frame_stride) {
        unowned uint8[]? raw_maybe = bgra_data.get_data();
        if (raw_maybe == null || frame_width <= 0 || frame_height <= 0 || frame_stride < frame_width * 4) {
            return false;
        }
        unowned uint8[] raw = (!) raw_maybe;
        int step_x = frame_width / 12;
        if (step_x < 1) step_x = 1;
        int step_y = frame_height / 12;
        if (step_y < 1) step_y = 1;
        uint64 sample_count = 0;
        uint64 sum_b = 0;
        uint64 sum_g = 0;
        uint64 sum_r = 0;
        uint64 sum_luma = 0;
        uint64 sum_luma_delta = 0;
        int previous_luma = -1;

        for (int y = 0; y < frame_height; y += step_y) {
            size_t row_offset = (size_t) y * (size_t) frame_stride;
            for (int x = 0; x < frame_width; x += step_x) {
                size_t offset = row_offset + (size_t) x * 4;
                int b = raw[offset];
                int g = raw[offset + 1];
                int r = raw[offset + 2];
                int luma = (r * 30 + g * 59 + b * 11) / 100;
                if (previous_luma >= 0) {
                    int delta = luma - previous_luma;
                    if (delta < 0) delta = -delta;
                    sum_luma_delta += (uint64) delta;
                }
                previous_luma = luma;
                sum_luma += (uint64) luma;
                sum_b += (uint64) b;
                sum_g += (uint64) g;
                sum_r += (uint64) r;
                sample_count++;
            }
        }

        if (sample_count == 0) {
            return false;
        }
        uint64 avg_b = sum_b / sample_count;
        uint64 avg_g = sum_g / sample_count;
        uint64 avg_r = sum_r / sample_count;
        uint64 avg_luma = sum_luma / sample_count;
        uint64 avg_luma_delta = sample_count > 1 ? sum_luma_delta / (sample_count - 1) : 0;

        bool dark_blank_preroll = avg_luma < 12 && avg_luma_delta < 8;
        bool blue_blank_preroll = avg_b > 160 &&
            avg_b > avg_g + 80 &&
            avg_b > avg_r + 80 &&
            avg_luma_delta < 8;
        return dark_blank_preroll || blue_blank_preroll;
    }

    private static void validate_geometry(int width, int height, int max_fps) throws EngineError {
        if (width <= 0 || height <= 0 || max_fps <= 0 ||
                width > 7680 || height > 4320 || max_fps > 120) {
            throw new EngineError.NATIVE("Unsupported video-message recorder geometry");
        }
    }
}

}
