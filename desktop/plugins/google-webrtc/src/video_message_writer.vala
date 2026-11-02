namespace Dino.Plugins.GoogleWebrtc {

public errordomain VideoMessageWriterError {
    UNAVAILABLE,
    INVALID_FORMAT,
    INVALID_STATE,
    WRITE_FAILED,
    FINALIZE_FAILED
}

public enum VideoMessageWriterState {
    IDLE,
    STARTED,
    FINALIZED,
    CANCELLED,
    FAILED
}

public class VideoMessageWriterConfig : Object {
    public const int DEFAULT_VIDEO_BITRATE_BPS = 500000;

    public string output_path { get; private set; }
    public string mime_type { get; private set; }
    public string video_codec { get; private set; }
    public string audio_codec { get; private set; }
    public int width { get; private set; }
    public int height { get; private set; }
    public int max_fps { get; private set; }
    public int video_bitrate_bps { get; private set; }

    public VideoMessageWriterConfig(
            string output_path,
            string mime_type = VideoMessageRecorderV2.MIME_TYPE,
            string video_codec = "h264",
            string audio_codec = VideoMessageRecorderV2.AUDIO_CODEC,
            int width = VideoMessageRecorderV2.DEFAULT_WIDTH,
            int height = VideoMessageRecorderV2.DEFAULT_HEIGHT,
            int max_fps = VideoMessageRecorderV2.DEFAULT_MAX_FPS,
            int video_bitrate_bps = DEFAULT_VIDEO_BITRATE_BPS) {
        this.output_path = output_path;
        this.mime_type = mime_type;
        this.video_codec = video_codec;
        this.audio_codec = audio_codec;
        this.width = width;
        this.height = height;
        this.max_fps = max_fps;
        this.video_bitrate_bps = video_bitrate_bps;
    }
}

public interface VideoMessageWriter : Object {
    public abstract bool available { get; }
    public abstract string? unavailable_reason { owned get; }
    public abstract VideoMessageWriterState state { get; }

    public abstract void start(VideoMessageWriterConfig config) throws VideoMessageWriterError;
    public abstract void write_bgra_frame(
        Bytes bgra_data,
        int width,
        int height,
        int stride,
        uint64 frame_id) throws VideoMessageWriterError;
    public abstract void write_pcm_frame(
        Bytes pcm_data,
        int sample_rate,
        int channels,
        int bytes_per_sample,
        uint64 frame_id) throws VideoMessageWriterError;
    public abstract void finish() throws VideoMessageWriterError;
    public abstract void cancel();
}

public class UnavailableMp4H264VideoMessageWriter : Object, VideoMessageWriter {
    private string reason;
    private VideoMessageWriterState current_state = VideoMessageWriterState.IDLE;

    public bool available {
        get { return false; }
    }

    public string? unavailable_reason {
        owned get { return reason; }
    }

    public VideoMessageWriterState state {
        get { return current_state; }
    }

    public UnavailableMp4H264VideoMessageWriter(string? reason = null) {
        this.reason = reason ?? "MP4/H.264 video-message backend is not available in this build";
    }

    public void start(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        current_state = VideoMessageWriterState.FAILED;
        throw new VideoMessageWriterError.UNAVAILABLE(reason);
    }

    public void write_bgra_frame(
            Bytes bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id) throws VideoMessageWriterError {
        throw new VideoMessageWriterError.UNAVAILABLE(reason);
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws VideoMessageWriterError {
        throw new VideoMessageWriterError.UNAVAILABLE(reason);
    }

    public void finish() throws VideoMessageWriterError {
        throw new VideoMessageWriterError.UNAVAILABLE(reason);
    }

    public void cancel() {
        current_state = VideoMessageWriterState.CANCELLED;
    }
}

#if WINDOWS
[CCode (cname = "dinox_mf_writer_new_video", cheader_filename = "media_foundation_writer.h")]
private static extern MediaFoundationWriterHandle? mf_video_writer_new(
    string output_path,
    int width,
    int height,
    int max_fps,
    int video_bitrate_bps,
    int include_audio,
    int audio_sample_rate,
    int audio_channels,
    int audio_bytes_per_sample,
    int audio_bitrate_bps);

[CCode (cname = "dinox_mf_writer_is_ready", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_video_writer_is_ready(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_last_error", cheader_filename = "media_foundation_writer.h")]
private static extern unowned string mf_video_writer_last_error(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_write_bgra", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_video_writer_write_bgra(
    MediaFoundationWriterHandle writer,
    uint8* data,
    size_t byte_count,
    int width,
    int height,
    int stride);

[CCode (cname = "dinox_mf_writer_write_audio", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_video_writer_write_audio(
    MediaFoundationWriterHandle writer,
    uint8* data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample);

[CCode (cname = "dinox_mf_writer_finish", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_video_writer_finish(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_cancel", cheader_filename = "media_foundation_writer.h")]
private static extern void mf_video_writer_cancel(MediaFoundationWriterHandle writer);

public class WindowsMediaFoundationMp4H264VideoMessageWriter : Object, VideoMessageWriter {
    private VideoMessageWriterState current_state = VideoMessageWriterState.IDLE;
    private MediaFoundationWriterHandle? handle = null;
    private VideoMessageWriterConfig? active_config = null;

    public bool available { get { return true; } }
    public string? unavailable_reason { owned get { return null; } }
    public VideoMessageWriterState state { get { return current_state; } }

    public void start(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.IDLE && current_state != VideoMessageWriterState.CANCELLED) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer already started");
        }
        validate_config(config);
        bool include_audio = config.audio_codec == VideoMessageRecorderV2.AUDIO_CODEC_AAC_LC;
        handle = mf_video_writer_new(
            config.output_path,
            config.width,
            config.height,
            config.max_fps,
            config.video_bitrate_bps,
            include_audio ? 1 : 0,
            VideoMessageRecorderV2.EXPECTED_AUDIO_SAMPLE_RATE,
            VideoMessageRecorderV2.EXPECTED_AUDIO_CHANNELS,
            VideoMessageRecorderV2.EXPECTED_AUDIO_BYTES_PER_SAMPLE,
            64000);
        if (handle == null) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.UNAVAILABLE("Could not allocate Windows Media Foundation writer");
        }
        if (mf_video_writer_is_ready((!) handle) == 0) {
            string message = mf_video_writer_last_error((!) handle).dup();
            handle = null;
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.UNAVAILABLE(message);
        }
        active_config = config;
        current_state = VideoMessageWriterState.STARTED;
    }

    public void write_bgra_frame(
            Bytes bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || handle == null || active_config == null) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer is not started");
        }
        VideoMessageWriterConfig config = (!) active_config;
        if (width != config.width || height != config.height || stride < width * 4 ||
                bgra_data.get_size() < (size_t) stride * (size_t) height) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected BGRA frame format");
        }
        unowned uint8[]? raw = bgra_data.get_data();
        if (raw == null || mf_video_writer_write_bgra(
                (!) handle, (!) raw, bgra_data.get_size(), width, height, stride) == 0) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.WRITE_FAILED(mf_video_writer_last_error((!) handle).dup());
        }
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || handle == null || active_config == null) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer is not started");
        }
        VideoMessageWriterConfig config = (!) active_config;
        if (config.audio_codec == VideoMessageRecorderV2.AUDIO_CODEC_NONE) return;
        if (sample_rate != VideoMessageRecorderV2.EXPECTED_AUDIO_SAMPLE_RATE ||
                channels != VideoMessageRecorderV2.EXPECTED_AUDIO_CHANNELS ||
                bytes_per_sample != VideoMessageRecorderV2.EXPECTED_AUDIO_BYTES_PER_SAMPLE ||
                pcm_data.get_size() == 0) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }
        unowned uint8[]? raw = pcm_data.get_data();
        if (raw == null || mf_video_writer_write_audio(
                (!) handle, (!) raw, pcm_data.get_size(), sample_rate, channels, bytes_per_sample) == 0) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.WRITE_FAILED(mf_video_writer_last_error((!) handle).dup());
        }
    }

    public void finish() throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || handle == null) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer is not started");
        }
        if (mf_video_writer_finish((!) handle) == 0) {
            string message = mf_video_writer_last_error((!) handle).dup();
            handle = null;
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.FINALIZE_FAILED(message);
        }
        handle = null;
        current_state = VideoMessageWriterState.FINALIZED;
    }

    public void cancel() {
        if (handle != null) {
            mf_video_writer_cancel((!) handle);
            handle = null;
        }
        current_state = VideoMessageWriterState.CANCELLED;
    }

    private static void validate_config(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        if (config.output_path == "" || config.mime_type != VideoMessageRecorderV2.MIME_TYPE ||
                config.video_codec != VideoMessageRecorderV2.VIDEO_CODEC ||
                (config.audio_codec != VideoMessageRecorderV2.AUDIO_CODEC_NONE &&
                 config.audio_codec != VideoMessageRecorderV2.AUDIO_CODEC_AAC_LC) ||
                config.width <= 0 || config.height <= 0 || (config.width % 2) != 0 ||
                (config.height % 2) != 0 || config.max_fps <= 0 ||
                config.video_bitrate_bps < 100000 || config.video_bitrate_bps > 5000000) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unsupported MP4/H.264 writer config");
        }
    }
}
#endif

#if !WINDOWS
public class SystemFfmpegMp4H264VideoMessageWriter : Object, VideoMessageWriter {
    private static bool probe_done = false;
    private static string? cached_ffmpeg_path = null;
    private static string? cached_encoder = null;
    private static string? cached_unavailable = null;

    private VideoMessageWriterState current_state = VideoMessageWriterState.IDLE;
    private Subprocess? process = null;
    private OutputStream? stdin_pipe = null;
    private AudioMessageWriter? audio_writer = null;
    private string? final_output_path = null;
    private string? video_temp_path = null;
    private string? audio_temp_path = null;
    private VideoMessageWriterConfig? active_config = null;

    public bool available {
        get {
            ensure_probe();
            return cached_unavailable == null;
        }
    }

    public string? unavailable_reason {
        owned get {
            ensure_probe();
            return cached_unavailable;
        }
    }

    public VideoMessageWriterState state {
        get { return current_state; }
    }

    public SystemFfmpegMp4H264VideoMessageWriter() {
        // Keep construction cheap. The full ffmpeg encoder/muxer probe may
        // spawn subprocesses and must not run on GTK recorder setup paths.
        // It is performed lazily by available/unavailable_reason/start().
    }

    public void start(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        ensure_probe();
        if (!available || cached_ffmpeg_path == null || cached_encoder == null) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.UNAVAILABLE(cached_unavailable ?? "System ffmpeg is unavailable");
        }
        if (current_state != VideoMessageWriterState.IDLE && current_state != VideoMessageWriterState.CANCELLED) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer already started");
        }
        validate_config(config);

        string size = "%dx%d".printf(config.width, config.height);
        final_output_path = config.output_path;
        string video_output_path = config.output_path;
        if (config.audio_codec == VideoMessageRecorderV2.AUDIO_CODEC_AAC_LC) {
            video_temp_path = make_temp_path(".video.mp4");
            audio_temp_path = make_temp_path(".audio.m4a");
            video_output_path = (!) video_temp_path;

            AudioMessageWriter created_audio_writer = AudioMessageWriterFactory.create_default_aac_m4a_writer();
            if (!created_audio_writer.available) {
                cleanup_temp_files();
                current_state = VideoMessageWriterState.FAILED;
                throw new VideoMessageWriterError.UNAVAILABLE(
                    "Audio writer unavailable: %s".printf(created_audio_writer.unavailable_reason ?? "unknown reason"));
            }

            try {
                created_audio_writer.start(new AudioMessageWriterConfig((!) audio_temp_path));
            } catch (Error e) {
                created_audio_writer.cancel();
                cleanup_temp_files();
                current_state = VideoMessageWriterState.FAILED;
                throw new VideoMessageWriterError.UNAVAILABLE("Could not start audio writer: %s".printf(e.message));
            }
            audio_writer = created_audio_writer;
        }
        string[] argv = build_ffmpeg_argv((!) cached_ffmpeg_path, (!) cached_encoder, config, size, video_output_path);

        try {
            process = new Subprocess.newv(
                argv,
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            stdin_pipe = ((!) process).get_stdin_pipe();
            if (stdin_pipe == null) {
                throw new IOError.FAILED("system ffmpeg stdin pipe was not created");
            }
        } catch (Error e) {
            cancel_audio_writer();
            cleanup_temp_files();
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.UNAVAILABLE("Could not start system ffmpeg: %s".printf(e.message));
        }

        active_config = config;
        current_state = VideoMessageWriterState.STARTED;
    }

    public void write_bgra_frame(
            Bytes bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || stdin_pipe == null || active_config == null) {
            throw new VideoMessageWriterError.INVALID_STATE(
                "video writer is not started (state=%d stdin=%s config=%s)".printf(
                    (int) current_state,
                    stdin_pipe != null ? "yes" : "no",
                    active_config != null ? "yes" : "no"));
        }
        VideoMessageWriterConfig config = (!) active_config;
        if (width != config.width ||
                height != config.height ||
                stride != width * 4) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected BGRA frame format");
        }

        size_t byte_count = bgra_data.get_size();
        size_t expected_size = (size_t) stride * (size_t) height;
        if (byte_count != expected_size || byte_count > int.MAX) {
            throw new VideoMessageWriterError.INVALID_FORMAT("invalid BGRA frame size");
        }

        unowned uint8[]? raw_maybe = bgra_data.get_data();
        if (raw_maybe == null) {
            throw new VideoMessageWriterError.WRITE_FAILED("BGRA frame has no readable data");
        }
        unowned uint8[] raw = (!) raw_maybe;
        try {
            size_t written = 0;
            ((!) stdin_pipe).write_all(raw[0:(int) byte_count], out written);
            if (written != byte_count) {
                throw new VideoMessageWriterError.WRITE_FAILED("short write to system ffmpeg");
            }
        } catch (Error e) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.WRITE_FAILED("Could not write BGRA frame to system ffmpeg: %s".printf(e.message));
        }
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || active_config == null) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer is not started");
        }
        VideoMessageWriterConfig config = (!) active_config;
        if (config.audio_codec == VideoMessageRecorderV2.AUDIO_CODEC_NONE) {
            return;
        }
        if (audio_writer == null) {
            throw new VideoMessageWriterError.INVALID_STATE("audio writer is not open");
        }
        if (sample_rate != VideoMessageRecorderV2.EXPECTED_AUDIO_SAMPLE_RATE ||
                channels != VideoMessageRecorderV2.EXPECTED_AUDIO_CHANNELS ||
                bytes_per_sample != VideoMessageRecorderV2.EXPECTED_AUDIO_BYTES_PER_SAMPLE) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = channels * bytes_per_sample;
        if (byte_count == 0 || bytes_per_pcm_frame <= 0 || byte_count % bytes_per_pcm_frame != 0 || byte_count > int.MAX) {
            throw new VideoMessageWriterError.INVALID_FORMAT("invalid PCM frame size");
        }

        try {
            ((!) audio_writer).write_pcm_frame(pcm_data, sample_rate, channels, bytes_per_sample, frame_id);
        } catch (Error e) {
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.WRITE_FAILED("Could not write PCM frame to audio writer: %s".printf(e.message));
        }
    }

    public void finish() throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED || process == null || stdin_pipe == null) {
            throw new VideoMessageWriterError.INVALID_STATE("video writer is not started");
        }

        try {
            ((!) stdin_pipe).close();
            stdin_pipe = null;
            ((!) process).wait();
        } catch (Error e) {
            cancel_audio_writer();
            cleanup_temp_files();
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.FINALIZE_FAILED("Could not finalize system ffmpeg writer: %s".printf(e.message));
        }

        if (!((!) process).get_successful()) {
            cancel_audio_writer();
            cleanup_temp_files();
            current_state = VideoMessageWriterState.FAILED;
            throw new VideoMessageWriterError.FINALIZE_FAILED("System ffmpeg failed to finalize the MP4/H.264 file");
        }

        process = null;

        if (audio_writer != null) {
            try {
                ((!) audio_writer).finish();
            } catch (Error e) {
                cleanup_temp_files();
                current_state = VideoMessageWriterState.FAILED;
                throw new VideoMessageWriterError.FINALIZE_FAILED("Could not finalize audio writer: %s".printf(e.message));
            }
            audio_writer = null;

            if (video_temp_path == null || audio_temp_path == null || final_output_path == null) {
                cleanup_temp_files();
                current_state = VideoMessageWriterState.FAILED;
                throw new VideoMessageWriterError.FINALIZE_FAILED("Temporary audio/video paths are missing");
            }

            try {
                mux_audio_video((!) video_temp_path, (!) audio_temp_path, (!) final_output_path);
            } catch (Error e) {
                cleanup_temp_files();
                current_state = VideoMessageWriterState.FAILED;
                throw new VideoMessageWriterError.FINALIZE_FAILED("Could not mux audio/video MP4: %s".printf(e.message));
            }
        }

        cleanup_temp_files();
        current_state = VideoMessageWriterState.FINALIZED;
    }

    public void cancel() {
        if (stdin_pipe != null) {
            try {
                ((!) stdin_pipe).close();
            } catch (Error e) {
                // Best-effort cleanup only.
            }
            stdin_pipe = null;
        }
        cancel_audio_writer();
        if (process != null) {
            ((!) process).force_exit();
            try {
                ((!) process).wait();
            } catch (Error e) {
                // Best-effort cleanup only.
            }
            process = null;
        }
        cleanup_temp_files();
        current_state = VideoMessageWriterState.CANCELLED;
    }

    private static void ensure_probe() {
        if (probe_done) return;
        cached_ffmpeg_path = Environment.find_program_in_path("ffmpeg");
        if (cached_ffmpeg_path == null) {
            cached_unavailable = "System ffmpeg was not found";
            probe_done = true;
            return;
        }

        cached_encoder = choose_h264_encoder((!) cached_ffmpeg_path);
        if (cached_encoder == null) {
            cached_unavailable = "System ffmpeg does not provide a supported software H.264 encoder";
            probe_done = true;
            return;
        }

        if (!ffmpeg_supports_mp4_muxer((!) cached_ffmpeg_path)) {
            cached_unavailable = "System ffmpeg does not provide an MP4 muxer";
            probe_done = true;
            return;
        }

        cached_unavailable = null;
        probe_done = true;
    }

    private static string? choose_h264_encoder(string ffmpeg) {
        string output = run_ffmpeg_probe({ ffmpeg, "-hide_banner", "-encoders", null });
        bool has_libx264 = false;
        bool has_libopenh264 = false;
        foreach (string line in output.split("\n")) {
            if (line.contains(" libx264 ") || line.has_suffix(" libx264")) {
                has_libx264 = true;
            }
            if (line.contains(" libopenh264 ") || line.has_suffix(" libopenh264")) {
                has_libopenh264 = true;
            }
        }
        if (has_libx264) return "libx264";
        if (has_libopenh264) return "libopenh264";
        return null;
    }

    private static bool ffmpeg_supports_mp4_muxer(string ffmpeg) {
        string output = run_ffmpeg_probe({ ffmpeg, "-hide_banner", "-muxers", null });
        foreach (string line in output.split("\n")) {
            if (line.contains(" mp4 ") || line.has_suffix(" mp4")) {
                return true;
            }
        }
        return false;
    }

    private static string run_ffmpeg_probe(string[] argv) {
        try {
            Subprocess probe = new Subprocess.newv(
                argv,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? probe_stdout = null;
            probe.communicate_utf8(null, null, out probe_stdout, null);
            if (!probe.get_successful()) {
                return "";
            }
            return probe_stdout ?? "";
        } catch (Error e) {
            return "";
        }
    }

    private static string[] build_ffmpeg_argv(
            string ffmpeg,
            string encoder,
            VideoMessageWriterConfig config,
            string size,
            string output_path) {
        string video_bitrate = config.video_bitrate_bps.to_string();
        string video_maxrate = config.video_bitrate_bps.to_string();
        string video_bufsize = (config.video_bitrate_bps * 2).to_string();
        if (encoder == "libx264") {
            return {
                ffmpeg,
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-f", "rawvideo",
                "-pix_fmt", "bgra",
                "-s:v", size,
                "-r", config.max_fps.to_string(),
                "-i", "pipe:0",
                "-an",
                "-c:v", encoder,
                "-preset", "veryfast",
                "-tune", "zerolatency",
                "-profile:v", "baseline",
                "-b:v", video_bitrate,
                "-maxrate", video_maxrate,
                "-bufsize", video_bufsize,
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                "-f", "mp4",
                output_path,
                null
            };
        }

        return {
            ffmpeg,
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "bgra",
            "-s:v", size,
            "-r", config.max_fps.to_string(),
            "-i", "pipe:0",
            "-an",
            "-c:v", encoder,
            "-b:v", video_bitrate,
            "-maxrate", video_maxrate,
            "-bufsize", video_bufsize,
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            "-f", "mp4",
            output_path,
            null
        };
    }

    private static void validate_config(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        if (config.output_path == "" ||
                config.mime_type != VideoMessageRecorderV2.MIME_TYPE ||
                config.video_codec != VideoMessageRecorderV2.VIDEO_CODEC ||
                (config.audio_codec != VideoMessageRecorderV2.AUDIO_CODEC_NONE &&
                 config.audio_codec != VideoMessageRecorderV2.AUDIO_CODEC_AAC_LC) ||
                config.width <= 0 ||
                config.height <= 0 ||
                config.max_fps <= 0 ||
                config.video_bitrate_bps < 100000 ||
                config.width > 7680 ||
                config.height > 4320 ||
                config.max_fps > 120 ||
                config.video_bitrate_bps > 5000000) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unsupported MP4/H.264 writer config");
        }
    }

    private static string make_temp_path(string suffix) {
        return Path.build_filename(
            Environment.get_tmp_dir(),
            "dinox-google-webrtc-video-message-" + Uuid.string_random() + suffix);
    }

    private void cancel_audio_writer() {
        if (audio_writer != null) {
            ((!) audio_writer).cancel();
            audio_writer = null;
        }
    }

    private void cleanup_temp_files() {
        if (video_temp_path != null) {
            FileUtils.remove((!) video_temp_path);
            video_temp_path = null;
        }
        if (audio_temp_path != null) {
            FileUtils.remove((!) audio_temp_path);
            audio_temp_path = null;
        }
        final_output_path = null;
    }

    private static void mux_audio_video(
            string video_path,
            string audio_path,
            string output_path) throws Error {
        string? ffmpeg = cached_ffmpeg_path;
        if (ffmpeg == null) {
            throw new IOError.FAILED("System ffmpeg is unavailable");
        }

        string[] argv = {
            (!) ffmpeg,
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", video_path,
            "-i", audio_path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c", "copy",
            "-shortest",
            "-movflags", "+faststart",
            output_path,
            null
        };

        Subprocess muxer = new Subprocess.newv(
            argv,
            SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        muxer.wait();
        if (!muxer.get_successful()) {
            throw new IOError.FAILED("system ffmpeg failed while muxing audio/video MP4");
        }
    }
}
#endif

private enum QueuedVideoMessageWriterJobKind {
    VIDEO,
    AUDIO,
    FINISH,
    CANCEL
}

private class QueuedVideoMessageWriterJob : Object {
    public QueuedVideoMessageWriterJobKind kind { get; private set; }
    public Bytes? data { get; private set; default = null; }
    public int width { get; private set; default = 0; }
    public int height { get; private set; default = 0; }
    public int stride { get; private set; default = 0; }
    public int sample_rate { get; private set; default = 0; }
    public int channels { get; private set; default = 0; }
    public int bytes_per_sample { get; private set; default = 0; }
    public uint64 frame_id { get; private set; default = 0; }

    private QueuedVideoMessageWriterJob(QueuedVideoMessageWriterJobKind kind) {
        this.kind = kind;
    }

    public static QueuedVideoMessageWriterJob video(Bytes data, int width, int height, int stride, uint64 frame_id) {
        var job = new QueuedVideoMessageWriterJob(QueuedVideoMessageWriterJobKind.VIDEO);
        job.data = data;
        job.width = width;
        job.height = height;
        job.stride = stride;
        job.frame_id = frame_id;
        return job;
    }

    public static QueuedVideoMessageWriterJob audio(
            Bytes data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) {
        var job = new QueuedVideoMessageWriterJob(QueuedVideoMessageWriterJobKind.AUDIO);
        job.data = data;
        job.sample_rate = sample_rate;
        job.channels = channels;
        job.bytes_per_sample = bytes_per_sample;
        job.frame_id = frame_id;
        return job;
    }

    public static QueuedVideoMessageWriterJob finish() {
        return new QueuedVideoMessageWriterJob(QueuedVideoMessageWriterJobKind.FINISH);
    }

    public static QueuedVideoMessageWriterJob cancel() {
        return new QueuedVideoMessageWriterJob(QueuedVideoMessageWriterJobKind.CANCEL);
    }
}

public class QueuedVideoMessageWriter : Object, VideoMessageWriter {
    private VideoMessageWriter inner;
    private VideoMessageWriterState current_state = VideoMessageWriterState.IDLE;
    private AsyncQueue<QueuedVideoMessageWriterJob>? queue = null;
    private Thread<void*>? worker_thread = null;
    private Mutex state_mutex = Mutex();
    private string? worker_error = null;

    public bool available {
        get { return inner.available; }
    }

    public string? unavailable_reason {
        owned get { return inner.unavailable_reason; }
    }

    public VideoMessageWriterState state {
        get {
            state_mutex.lock();
            try {
                return current_state;
            } finally {
                state_mutex.unlock();
            }
        }
    }

    public QueuedVideoMessageWriter(VideoMessageWriter inner) {
        this.inner = inner;
    }

    public void start(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        state_mutex.lock();
        try {
            if (current_state != VideoMessageWriterState.IDLE && current_state != VideoMessageWriterState.CANCELLED) {
                throw new VideoMessageWriterError.INVALID_STATE("queued video writer already started");
            }
            current_state = VideoMessageWriterState.STARTED;
            worker_error = null;
            queue = new AsyncQueue<QueuedVideoMessageWriterJob>();
        } finally {
            state_mutex.unlock();
        }

        worker_thread = new Thread<void*>("dinox-video-message-writer", () => {
            worker_loop(config);
            return null;
        });
    }

    public void write_bgra_frame(
            Bytes bgra_data,
            int width,
            int height,
            int stride,
            uint64 frame_id) throws VideoMessageWriterError {
        ensure_started();
        ((!) queue).push(QueuedVideoMessageWriterJob.video(bgra_data, width, height, stride, frame_id));
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws VideoMessageWriterError {
        ensure_started();
        ((!) queue).push(QueuedVideoMessageWriterJob.audio(
            pcm_data,
            sample_rate,
            channels,
            bytes_per_sample,
            frame_id));
    }

    public void finish() throws VideoMessageWriterError {
        ensure_started();
        ((!) queue).push(QueuedVideoMessageWriterJob.finish());
        join_worker();
        string? error = get_worker_error();
        if (error != null) {
            set_state(VideoMessageWriterState.FAILED);
            throw new VideoMessageWriterError.FINALIZE_FAILED((!) error);
        }
        set_state(VideoMessageWriterState.FINALIZED);
    }

    public void cancel() {
        if (state != VideoMessageWriterState.STARTED || queue == null) {
            inner.cancel();
            set_state(VideoMessageWriterState.CANCELLED);
            return;
        }
        ((!) queue).push(QueuedVideoMessageWriterJob.cancel());
        join_worker();
        set_state(VideoMessageWriterState.CANCELLED);
    }

    private void ensure_started() throws VideoMessageWriterError {
        state_mutex.lock();
        try {
            if (current_state != VideoMessageWriterState.STARTED || queue == null) {
                throw new VideoMessageWriterError.INVALID_STATE("queued video writer is not started");
            }
            if (worker_error != null) {
                throw new VideoMessageWriterError.WRITE_FAILED((!) worker_error);
            }
        } finally {
            state_mutex.unlock();
        }
    }

    private void worker_loop(VideoMessageWriterConfig config) {
        try {
            inner.start(config);
            while (true) {
                QueuedVideoMessageWriterJob job = ((!) queue).pop();
                switch (job.kind) {
                    case QueuedVideoMessageWriterJobKind.VIDEO:
                        inner.write_bgra_frame(
                            (!) job.data,
                            job.width,
                            job.height,
                            job.stride,
                            job.frame_id);
                        break;
                    case QueuedVideoMessageWriterJobKind.AUDIO:
                        inner.write_pcm_frame(
                            (!) job.data,
                            job.sample_rate,
                            job.channels,
                            job.bytes_per_sample,
                            job.frame_id);
                        break;
                    case QueuedVideoMessageWriterJobKind.FINISH:
                        inner.finish();
                        return;
                    case QueuedVideoMessageWriterJobKind.CANCEL:
                        inner.cancel();
                        return;
                }
            }
        } catch (VideoMessageWriterError e) {
            set_worker_error(e.message);
            inner.cancel();
        }
    }

    private void join_worker() {
        Thread<void*>? thread = worker_thread;
        worker_thread = null;
        if (thread != null) {
            ((!) thread).join();
        }
    }

    private void set_state(VideoMessageWriterState state) {
        state_mutex.lock();
        current_state = state;
        state_mutex.unlock();
    }

    private void set_worker_error(string message) {
        state_mutex.lock();
        worker_error = message;
        current_state = VideoMessageWriterState.FAILED;
        state_mutex.unlock();
    }

    private string? get_worker_error() {
        state_mutex.lock();
        try {
            return worker_error;
        } finally {
            state_mutex.unlock();
        }
    }
}

public class VideoMessageWriterFactory : Object {
    public static VideoMessageWriter create_default_mp4_h264_writer() {
#if WINDOWS
        return new QueuedVideoMessageWriter(new WindowsMediaFoundationMp4H264VideoMessageWriter());
#else
        return new QueuedVideoMessageWriter(new SystemFfmpegMp4H264VideoMessageWriter());
#endif
    }
}

}
