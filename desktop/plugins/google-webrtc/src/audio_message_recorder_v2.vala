namespace Dino.Plugins.GoogleWebrtc {

internal class MediaMessagePcmUtil {
    public const int START_MUTED_MS = 250;
    public const int START_FADE_MS = 50;

    public static Bytes apply_start_fade_in(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 processed_pcm_frames) {
        if (sample_rate <= 0 || channels <= 0 || bytes_per_sample != 2) {
            return pcm_data;
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = channels * bytes_per_sample;
        if (bytes_per_pcm_frame <= 0 || byte_count == 0 || byte_count % bytes_per_pcm_frame != 0 || byte_count > int.MAX) {
            return pcm_data;
        }

        uint64 frame_count = (uint64) (byte_count / bytes_per_pcm_frame);
        uint64 muted_frames = ((uint64) sample_rate * START_MUTED_MS) / 1000;
        uint64 fade_frames = ((uint64) sample_rate * START_FADE_MS) / 1000;
        uint64 fade_end_frame = muted_frames + fade_frames;
        if (fade_end_frame == 0) {
            return pcm_data;
        }
        if (processed_pcm_frames >= fade_end_frame) {
            return pcm_data;
        }

        unowned uint8[]? raw_maybe = pcm_data.get_data();
        if (raw_maybe == null) {
            return pcm_data;
        }
        unowned uint8[] raw = (!) raw_maybe;
        uint8[] processed = new uint8[(int) byte_count];

        for (uint64 frame = 0; frame < frame_count; frame++) {
            uint64 absolute_frame = processed_pcm_frames + frame;
            double gain = 1.0;
            if (absolute_frame < muted_frames) {
                gain = 0.0;
            } else if (absolute_frame < fade_end_frame && fade_frames > 0) {
                gain = (double) (absolute_frame - muted_frames) / (double) fade_frames;
            }

            for (int channel = 0; channel < channels; channel++) {
                size_t offset = (size_t) frame * (size_t) bytes_per_pcm_frame + (size_t) channel * 2;
                int sample = (int) raw[offset] | ((int) raw[offset + 1] << 8);
                if ((sample & 0x8000) != 0) {
                    sample -= 0x10000;
                }
                double scaled_double = (double) sample * gain;
                int scaled = (int) (scaled_double >= 0.0 ? scaled_double + 0.5 : scaled_double - 0.5);
                if (scaled > 32767) scaled = 32767;
                if (scaled < -32768) scaled = -32768;
                uint16 out_sample = (uint16) (scaled & 0xffff);
                processed[(int) offset] = (uint8) (out_sample & 0xff);
                processed[(int) offset + 1] = (uint8) ((out_sample >> 8) & 0xff);
            }
        }

        return new Bytes(processed);
    }
}

/**
 * Audio-message recorder layer above the native media-recorder ABI.
 *
 * Captured PCM drives message duration/level state and an optional file writer.
 * The chat provider supplies an AAC/M4A writer; device tests consume PCM without
 * encoding. File-writer PCM receives the startup mute/fade envelope before
 * encoding, while raw PCM remains available to the UI and device-test consumers.
 */
public class AudioMessageRecorderV2 : Object {
    public const string MIME_TYPE = "audio/mp4";
    public const int EXPECTED_SAMPLE_RATE = 48000;
    public const int EXPECTED_CHANNELS = 1;
    public const int EXPECTED_BYTES_PER_SAMPLE = 2;
    public const int MAX_DURATION_SECONDS = 300;

    private MediaMessageRecorderNative recorder;
    private AudioMessageWriter? writer = null;
    private EngineContextActivityLease? activity_lease = null;
    private bool closed = false;

    public string output_path { get; private set; }
    public bool file_writer_enabled {
        get { return writer != null; }
    }
    public AudioMessageWriterState file_writer_state {
        get { return writer != null ? ((!) writer).state : AudioMessageWriterState.IDLE; }
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
    public uint64 pcm_frame_count { get; private set; default = 0; }
    public uint64 pcm_sample_count { get; private set; default = 0; }
    public uint64 last_frame_id { get; private set; default = 0; }
    public int sample_rate { get; private set; default = 0; }
    public int channels { get; private set; default = 0; }
    public int bytes_per_sample { get; private set; default = 0; }
    public double peak_level { get; private set; default = 0.0; }
    public double duration_seconds {
        get {
            if (sample_rate <= 0) return 0.0;
            return (double) pcm_frame_count / (double) sample_rate;
        }
    }

    public signal void started();
    public signal void stopped();
    public signal void duration_changed(double seconds);
    public signal void level_changed(double peak);
    public signal void recording_error(string message);
    public signal void frame_received(Bytes pcm_data, uint64 frame_id);

    public AudioMessageRecorderV2(Native.Context context, string output_path) throws EngineError {
        this.output_path = output_path;
        recorder = new MediaMessageRecorderNative(
            context,
            Native.MediaRecorderKind.AUDIO,
            output_path,
            MIME_TYPE);
        recorder.started.connect(() => {
            started();
        });
        recorder.stopped.connect(() => {
            stopped();
        });
        recorder.native_error.connect((status, message) => {
            recording_error(@"$(status.to_log_string()): $(message)");
        });
        recorder.audio_frame.connect(on_audio_frame);
    }

    public AudioMessageRecorderV2.with_writer(
            Native.Context context,
            string output_path,
            AudioMessageWriter writer) throws EngineError {
        this(context, output_path);
        this.writer = writer;
    }

    public void start() throws EngineError {
        reset_counters();
        try {
            if (writer != null) {
                ((!) writer).start(new AudioMessageWriterConfig(output_path));
            }
        } catch (AudioMessageWriterError e) {
            throw new EngineError.NATIVE("Could not start audio-message writer: %s".printf(e.message));
        }

        Native.Status status = recorder.start();
        if (status != Native.Status.OK) {
            if (writer != null) {
                ((!) writer).cancel();
            }
            throw_if_native_error(status, "starting audio-message recorder v2");
        }
    }

    public void stop(bool defer_activity_release = false) throws EngineError {
        throw_if_native_error(recorder.stop(), "stopping audio-message recorder v2");
        closed = true;
        if (!defer_activity_release) {
            release_activity_lease();
        }
        try {
            if (writer != null) {
                ((!) writer).finish();
            }
        } catch (AudioMessageWriterError e) {
            throw new EngineError.NATIVE("Could not finalize audio-message writer: %s".printf(e.message));
        }
    }

    public void cancel() throws EngineError {
        if (closed) {
            release_activity_lease();
            return;
        }
        throw_if_native_error(recorder.cancel(), "cancelling audio-message recorder v2");
        if (writer != null) {
            ((!) writer).cancel();
        }
        closed = true;
        release_activity_lease();
    }

    public void push_synthetic_frame() throws EngineError {
        throw_if_native_error(recorder.push_synthetic_frame(), "pushing audio-message recorder v2 synthetic frame");
    }

    internal void take_activity_lease(owned EngineContextActivityLease lease) {
        activity_lease = (owned) lease;
    }

    internal void release_completed_activity() {
        if (closed) {
            release_activity_lease();
        }
    }

    ~AudioMessageRecorderV2() {
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
        pcm_frame_count = 0;
        pcm_sample_count = 0;
        last_frame_id = 0;
        sample_rate = 0;
        channels = 0;
        bytes_per_sample = 0;
        peak_level = 0.0;
    }

    private void on_audio_frame(
            Bytes pcm_data,
            int frame_sample_rate,
            int frame_channels,
            int frame_bytes_per_sample,
            uint64 frame_id) {
        if (frame_sample_rate <= 0 || frame_channels <= 0 || frame_bytes_per_sample <= 0) {
            recording_error("Invalid PCM frame metadata");
            return;
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = frame_channels * frame_bytes_per_sample;
        if (bytes_per_pcm_frame <= 0 || byte_count == 0 || byte_count % bytes_per_pcm_frame != 0) {
            recording_error("Invalid PCM frame size");
            return;
        }

        Bytes? output_pcm_data = null;
        try {
            if (writer != null) {
                output_pcm_data = MediaMessagePcmUtil.apply_start_fade_in(
                    pcm_data,
                    frame_sample_rate,
                    frame_channels,
                    frame_bytes_per_sample,
                    pcm_frame_count);
                ((!) writer).write_pcm_frame(
                    (!) output_pcm_data,
                    frame_sample_rate,
                    frame_channels,
                    frame_bytes_per_sample,
                    frame_id);
            }
        } catch (AudioMessageWriterError e) {
            recording_error("Could not write PCM frame: %s".printf(e.message));
            return;
        }

        frame_callback_count++;
        last_frame_id = frame_id;
        sample_rate = frame_sample_rate;
        channels = frame_channels;
        bytes_per_sample = frame_bytes_per_sample;
        uint64 frame_count = (uint64) (byte_count / bytes_per_pcm_frame);
        pcm_frame_count += frame_count;
        pcm_sample_count += frame_count * (uint64) frame_channels;

        Bytes level_pcm_data = output_pcm_data ?? pcm_data;
        double frame_peak = calculate_peak_level(level_pcm_data, frame_channels, frame_bytes_per_sample);
        if (frame_peak > peak_level) {
            peak_level = frame_peak;
        }

        frame_received(pcm_data, frame_id);
        level_changed(calculate_visual_level(frame_peak));
        duration_changed(duration_seconds);
    }

    private static double calculate_visual_level(double peak) {
        if (peak <= 0.0) {
            return 0.0;
        }
        if (peak > 1.0) {
            peak = 1.0;
        }
        // The recorder UI expects a perceptual 0..1 value. Raw PCM peak is
        // usually too small for normal speech and makes the waveform look dead.
        return sqrt_approx(peak);
    }

    private static double sqrt_approx(double value) {
        if (value <= 0.0) {
            return 0.0;
        }
        double guess = value >= 1.0 ? value : 1.0;
        for (int i = 0; i < 6; i++) {
            guess = 0.5 * (guess + value / guess);
        }
        return guess;
    }

    private static double calculate_peak_level(Bytes pcm_data, int frame_channels, int frame_bytes_per_sample) {
        if (frame_bytes_per_sample != 2 || frame_channels <= 0) {
            return 0.0;
        }

        unowned uint8[]? raw_maybe = pcm_data.get_data();
        if (raw_maybe == null) {
            return 0.0;
        }
        unowned uint8[] raw = (!) raw_maybe;
        size_t byte_count = pcm_data.get_size();
        if (byte_count < 2) {
            return 0.0;
        }

        int peak = 0;
        for (size_t i = 0; i + 1 < byte_count; i += 2) {
            int sample = (int) raw[i] | ((int) raw[i + 1] << 8);
            if ((sample & 0x8000) != 0) {
                sample -= 0x10000;
            }
            if (sample < 0) {
                sample = -sample;
            }
            if (sample > peak) {
                peak = sample;
            }
        }

        return (double) peak / 32768.0;
    }
}

}
