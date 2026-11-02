namespace Dino.Plugins.GoogleWebrtc {

public errordomain AudioMessageWriterError {
    UNAVAILABLE,
    INVALID_FORMAT,
    INVALID_STATE,
    WRITE_FAILED,
    FINALIZE_FAILED
}

public enum AudioMessageWriterState {
    IDLE,
    STARTED,
    FINALIZED,
    CANCELLED,
    FAILED
}

public class AudioMessageWriterConfig : Object {
    public string output_path { get; private set; }
    public string mime_type { get; private set; }
    public string codec { get; private set; }
    public int sample_rate { get; private set; }
    public int channels { get; private set; }
    public int bytes_per_sample { get; private set; }
    public int bitrate_bps { get; private set; }

    public AudioMessageWriterConfig(
            string output_path,
            string mime_type = AudioMessageRecorderV2.MIME_TYPE,
            string codec = "aac-lc",
            int sample_rate = AudioMessageRecorderV2.EXPECTED_SAMPLE_RATE,
            int channels = AudioMessageRecorderV2.EXPECTED_CHANNELS,
            int bytes_per_sample = AudioMessageRecorderV2.EXPECTED_BYTES_PER_SAMPLE,
            int bitrate_bps = 64000) {
        this.output_path = output_path;
        this.mime_type = mime_type;
        this.codec = codec;
        this.sample_rate = sample_rate;
        this.channels = channels;
        this.bytes_per_sample = bytes_per_sample;
        this.bitrate_bps = bitrate_bps;
    }
}

public interface AudioMessageWriter : Object {
    public abstract bool available { get; }
    public abstract string? unavailable_reason { owned get; }
    public abstract AudioMessageWriterState state { get; }

    public abstract void start(AudioMessageWriterConfig config) throws AudioMessageWriterError;
    public abstract void write_pcm_frame(
        Bytes pcm_data,
        int sample_rate,
        int channels,
        int bytes_per_sample,
        uint64 frame_id) throws AudioMessageWriterError;
    public abstract void finish() throws AudioMessageWriterError;
    public abstract void cancel();
}

public class UnavailableAacM4aAudioMessageWriter : Object, AudioMessageWriter {
    private string reason;
    private AudioMessageWriterState current_state = AudioMessageWriterState.IDLE;

    public bool available {
        get { return false; }
    }

    public string? unavailable_reason {
        owned get { return reason; }
    }

    public AudioMessageWriterState state {
        get { return current_state; }
    }

    public UnavailableAacM4aAudioMessageWriter(string? reason = null) {
        this.reason = reason ?? "AAC/M4A recording backend is not available in this build";
    }

    public void start(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        current_state = AudioMessageWriterState.FAILED;
        throw new AudioMessageWriterError.UNAVAILABLE(reason);
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws AudioMessageWriterError {
        throw new AudioMessageWriterError.UNAVAILABLE(reason);
    }

    public void finish() throws AudioMessageWriterError {
        throw new AudioMessageWriterError.UNAVAILABLE(reason);
    }

    public void cancel() {
        current_state = AudioMessageWriterState.CANCELLED;
    }
}

#if WINDOWS
[CCode (cname = "dinox_mf_writer_new_audio", cheader_filename = "media_foundation_writer.h")]
private static extern MediaFoundationWriterHandle? mf_audio_writer_new(
    string output_path,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    int bitrate_bps);

[CCode (cname = "dinox_mf_writer_is_ready", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_audio_writer_is_ready(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_last_error", cheader_filename = "media_foundation_writer.h")]
private static extern unowned string mf_audio_writer_last_error(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_write_audio", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_audio_writer_write(
    MediaFoundationWriterHandle writer,
    uint8* data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample);

[CCode (cname = "dinox_mf_writer_finish", cheader_filename = "media_foundation_writer.h")]
private static extern int mf_audio_writer_finish(MediaFoundationWriterHandle writer);

[CCode (cname = "dinox_mf_writer_cancel", cheader_filename = "media_foundation_writer.h")]
private static extern void mf_audio_writer_cancel(MediaFoundationWriterHandle writer);

public class WindowsMediaFoundationAacM4aAudioMessageWriter : Object, AudioMessageWriter {
    private AudioMessageWriterState current_state = AudioMessageWriterState.IDLE;
    private MediaFoundationWriterHandle? handle = null;
    private AudioMessageWriterConfig? active_config = null;

    public bool available { get { return true; } }
    public string? unavailable_reason { owned get { return null; } }
    public AudioMessageWriterState state { get { return current_state; } }

    public void start(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.IDLE && current_state != AudioMessageWriterState.CANCELLED) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer already started");
        }
        validate_config(config);
        handle = mf_audio_writer_new(
            config.output_path,
            config.sample_rate,
            config.channels,
            config.bytes_per_sample,
            config.bitrate_bps);
        if (handle == null) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.UNAVAILABLE("Could not allocate Windows Media Foundation writer");
        }
        if (mf_audio_writer_is_ready((!) handle) == 0) {
            string message = mf_audio_writer_last_error((!) handle).dup();
            handle = null;
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.UNAVAILABLE(message);
        }
        active_config = config;
        current_state = AudioMessageWriterState.STARTED;
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED || handle == null || active_config == null) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer is not started");
        }
        AudioMessageWriterConfig config = (!) active_config;
        if (sample_rate != config.sample_rate || channels != config.channels ||
                bytes_per_sample != config.bytes_per_sample || pcm_data.get_size() == 0) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }
        unowned uint8[]? raw = pcm_data.get_data();
        if (raw == null || mf_audio_writer_write(
                (!) handle, (!) raw, pcm_data.get_size(), sample_rate, channels, bytes_per_sample) == 0) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.WRITE_FAILED(mf_audio_writer_last_error((!) handle).dup());
        }
    }

    public void finish() throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED || handle == null) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer is not started");
        }
        if (mf_audio_writer_finish((!) handle) == 0) {
            string message = mf_audio_writer_last_error((!) handle).dup();
            handle = null;
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.FINALIZE_FAILED(message);
        }
        handle = null;
        current_state = AudioMessageWriterState.FINALIZED;
    }

    public void cancel() {
        if (handle != null) {
            mf_audio_writer_cancel((!) handle);
            handle = null;
        }
        current_state = AudioMessageWriterState.CANCELLED;
    }

    private static void validate_config(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        if (config.output_path == "" || config.mime_type != AudioMessageRecorderV2.MIME_TYPE ||
                config.codec != "aac-lc" || config.sample_rate <= 0 || config.channels <= 0 ||
                config.bytes_per_sample != 2 || config.bitrate_bps <= 0) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unsupported AAC/M4A writer config");
        }
    }
}
#endif

#if !WINDOWS
public class SystemFfmpegAacM4aAudioMessageWriter : Object, AudioMessageWriter {
    private string? ffmpeg_path;
    private string? unavailable;
    private AudioMessageWriterState current_state = AudioMessageWriterState.IDLE;
    private Subprocess? process = null;
    private OutputStream? stdin_pipe = null;
    private AudioMessageWriterConfig? active_config = null;

    public bool available {
        get { return unavailable == null; }
    }

    public string? unavailable_reason {
        owned get { return unavailable; }
    }

    public AudioMessageWriterState state {
        get { return current_state; }
    }

    public SystemFfmpegAacM4aAudioMessageWriter() {
        ffmpeg_path = Environment.find_program_in_path("ffmpeg");
        if (ffmpeg_path == null) {
            unavailable = "System ffmpeg was not found";
            return;
        }
        if (!ffmpeg_supports_aac_encoder((!) ffmpeg_path)) {
            unavailable = "System ffmpeg does not provide an AAC encoder";
            return;
        }
        if (!ffmpeg_supports_m4a_muxer((!) ffmpeg_path)) {
            unavailable = "System ffmpeg does not provide an MP4/M4A muxer";
            return;
        }
    }

    public void start(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        if (!available || ffmpeg_path == null) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.UNAVAILABLE(unavailable ?? "System ffmpeg is unavailable");
        }
        if (current_state != AudioMessageWriterState.IDLE && current_state != AudioMessageWriterState.CANCELLED) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer already started");
        }
        validate_config(config);

        string[] argv = {
            (!) ffmpeg_path,
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-f", "s16le",
            "-ar", config.sample_rate.to_string(),
            "-ac", config.channels.to_string(),
            "-i", "pipe:0",
            "-vn",
            "-c:a", "aac",
            "-b:a", config.bitrate_bps.to_string(),
            "-movflags", "+faststart",
            "-f", "ipod",
            config.output_path,
            null
        };

        try {
            process = new Subprocess.newv(
                argv,
                SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            stdin_pipe = ((!) process).get_stdin_pipe();
        } catch (Error e) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.UNAVAILABLE("Could not start system ffmpeg: %s".printf(e.message));
        }

        active_config = config;
        current_state = AudioMessageWriterState.STARTED;
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED || stdin_pipe == null || active_config == null) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer is not started");
        }
        AudioMessageWriterConfig config = (!) active_config;
        if (sample_rate != config.sample_rate ||
                channels != config.channels ||
                bytes_per_sample != config.bytes_per_sample) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = channels * bytes_per_sample;
        if (byte_count == 0 || bytes_per_pcm_frame <= 0 || byte_count % bytes_per_pcm_frame != 0) {
            throw new AudioMessageWriterError.INVALID_FORMAT("invalid PCM frame size");
        }
        if (byte_count > int.MAX) {
            throw new AudioMessageWriterError.INVALID_FORMAT("PCM frame is too large");
        }

        unowned uint8[]? raw_maybe = pcm_data.get_data();
        if (raw_maybe == null) {
            throw new AudioMessageWriterError.WRITE_FAILED("PCM frame has no readable data");
        }
        unowned uint8[] raw = (!) raw_maybe;
        try {
            size_t written = 0;
            ((!) stdin_pipe).write_all(raw[0:(int) byte_count], out written);
            if (written != byte_count) {
                throw new AudioMessageWriterError.WRITE_FAILED("short write to system ffmpeg");
            }
        } catch (Error e) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.WRITE_FAILED("Could not write PCM frame to system ffmpeg: %s".printf(e.message));
        }
    }

    public void finish() throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED || process == null || stdin_pipe == null) {
            throw new AudioMessageWriterError.INVALID_STATE("audio writer is not started");
        }

        try {
            ((!) stdin_pipe).close();
            stdin_pipe = null;
            ((!) process).wait();
        } catch (Error e) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.FINALIZE_FAILED("Could not finalize system ffmpeg writer: %s".printf(e.message));
        }

        if (!((!) process).get_successful()) {
            current_state = AudioMessageWriterState.FAILED;
            throw new AudioMessageWriterError.FINALIZE_FAILED("System ffmpeg failed to finalize the M4A file");
        }

        process = null;
        current_state = AudioMessageWriterState.FINALIZED;
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
        if (process != null) {
            ((!) process).force_exit();
            try {
                ((!) process).wait();
            } catch (Error e) {
                // Best-effort cleanup only.
            }
            process = null;
        }
        current_state = AudioMessageWriterState.CANCELLED;
    }

    private static void validate_config(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        if (config.output_path == "" ||
                config.mime_type != AudioMessageRecorderV2.MIME_TYPE ||
                config.codec != "aac-lc" ||
                config.sample_rate <= 0 ||
                config.channels <= 0 ||
                config.bytes_per_sample != 2 ||
                config.bitrate_bps <= 0) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unsupported AAC/M4A writer config");
        }
    }

    private static bool ffmpeg_supports_aac_encoder(string ffmpeg) {
        string output = run_ffmpeg_probe({ ffmpeg, "-hide_banner", "-encoders", null });
        foreach (string line in output.split("\n")) {
            if (line.contains(" aac ") || line.has_suffix(" aac")) {
                return true;
            }
        }
        return false;
    }

    private static bool ffmpeg_supports_m4a_muxer(string ffmpeg) {
        string output = run_ffmpeg_probe({ ffmpeg, "-hide_banner", "-muxers", null });
        foreach (string line in output.split("\n")) {
            if (line.contains(" ipod ") || line.contains(" mp4 ") ||
                    line.has_suffix(" ipod") || line.has_suffix(" mp4")) {
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
}
#endif

public class AudioMessageWriterFactory : Object {
    public static AudioMessageWriter create_default_aac_m4a_writer() {
#if WINDOWS
        return new WindowsMediaFoundationAacM4aAudioMessageWriter();
#else
        return new SystemFfmpegAacM4aAudioMessageWriter();
#endif
    }
}

}
