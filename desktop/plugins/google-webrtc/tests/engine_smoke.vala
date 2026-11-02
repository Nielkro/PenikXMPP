using Gee;
using Xmpp;
using Xmpp.Xep;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private const uint WAIT_TIMEOUT_MS = 5000;
private const int64 VIDEO_FRAME_TIMEOUT_US = 10000 * 1000;
private delegate bool WaitCondition();

private class SignalWaiter : Object {
    private MainLoop loop = new MainLoop();
    private uint timeout_id = 0;
    public bool timed_out { get; private set; default = false; }
    public string? error_message { get; set; default = null; }

    public void run_until_signal() {
        timeout_id = Timeout.add(WAIT_TIMEOUT_MS, () => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
    }

    public void finish() {
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
        loop.quit();
    }
}

private class NoopEffectWireTransport : Object, EngineJingleWireTransport {
    public void send_jingle_iq(Jid to, StanzaNode jingle) {
    }

    public void send_result_iq(Iq.Stanza request_iq) {
    }

    public void send_error_iq(Iq.Stanza request_iq, ErrorStanza error) {
    }
}

private class NoopEffectJmiTransport : Object, EngineJmiTransport {
    public void send_propose(Jid to, string sid, Gee.List<StanzaNode> descriptions) {
    }

    public void send_accept_to_self(string sid) {
    }

    public void send_proceed(Jid to, string sid) {
    }

    public void send_reject(Jid to, string sid) {
    }

    public void send_reject_to_self(string sid) {
    }

    public void send_retract(Jid to, string sid) {
    }
}

private class NoopEffectMujiCodecProvider : Object, Muji.CodecProvider {
    public async Gee.List<JingleRtp.PayloadType> get_supported_payloads(
            string media) throws Error {
        return new ArrayList<JingleRtp.PayloadType>();
    }

    public async bool is_payload_supported(string media,
            JingleRtp.PayloadType payload_type) throws Error {
        return false;
    }
}

private class CountingAudioMessageWriter : Object, AudioMessageWriter {
    private AudioMessageWriterState current_state = AudioMessageWriterState.IDLE;

    public bool available {
        get { return true; }
    }

    public string? unavailable_reason {
        owned get { return null; }
    }

    public AudioMessageWriterState state {
        get { return current_state; }
    }
    public int start_count { get; private set; default = 0; }
    public int finish_count { get; private set; default = 0; }
    public int cancel_count { get; private set; default = 0; }
    public uint64 write_count { get; private set; default = 0; }
    public uint64 pcm_frame_count { get; private set; default = 0; }
    public uint64 pcm_sample_count { get; private set; default = 0; }
    public uint64 last_frame_id { get; private set; default = 0; }
    public string? output_path { get; private set; default = null; }
    public string? mime_type { get; private set; default = null; }
    public string? codec { get; private set; default = null; }
    public int bitrate_bps { get; private set; default = 0; }
    public bool capture_pcm { get; set; default = false; }
    public ArrayList<Bytes> captured_pcm = new ArrayList<Bytes>();

    public void start(AudioMessageWriterConfig config) throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.IDLE && current_state != AudioMessageWriterState.CANCELLED) {
            throw new AudioMessageWriterError.INVALID_STATE("writer already started");
        }
        if (config.mime_type != AudioMessageRecorderV2.MIME_TYPE ||
                config.codec != "aac-lc" ||
                config.sample_rate != AudioMessageRecorderV2.EXPECTED_SAMPLE_RATE ||
                config.channels != AudioMessageRecorderV2.EXPECTED_CHANNELS ||
                config.bytes_per_sample != AudioMessageRecorderV2.EXPECTED_BYTES_PER_SAMPLE) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unexpected audio writer config");
        }

        output_path = config.output_path;
        mime_type = config.mime_type;
        codec = config.codec;
        bitrate_bps = config.bitrate_bps;
        start_count++;
        current_state = AudioMessageWriterState.STARTED;
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED) {
            throw new AudioMessageWriterError.INVALID_STATE("writer is not started");
        }
        if (sample_rate != AudioMessageRecorderV2.EXPECTED_SAMPLE_RATE ||
                channels != AudioMessageRecorderV2.EXPECTED_CHANNELS ||
                bytes_per_sample != AudioMessageRecorderV2.EXPECTED_BYTES_PER_SAMPLE) {
            throw new AudioMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }

        size_t byte_count = pcm_data.get_size();
        if (byte_count == 0 || byte_count % (channels * bytes_per_sample) != 0) {
            throw new AudioMessageWriterError.INVALID_FORMAT("invalid PCM frame size");
        }

        uint64 frame_count = (uint64) (byte_count / (channels * bytes_per_sample));
        write_count++;
        pcm_frame_count += frame_count;
        pcm_sample_count += frame_count * (uint64) channels;
        last_frame_id = frame_id;
        if (capture_pcm) captured_pcm.add(pcm_data);
    }

    public void finish() throws AudioMessageWriterError {
        if (current_state != AudioMessageWriterState.STARTED) {
            throw new AudioMessageWriterError.INVALID_STATE("writer is not started");
        }
        finish_count++;
        current_state = AudioMessageWriterState.FINALIZED;
    }

    public void cancel() {
        cancel_count++;
        current_state = AudioMessageWriterState.CANCELLED;
    }
}

private class CountingVideoMessageWriter : Object, VideoMessageWriter {
    private VideoMessageWriterState current_state = VideoMessageWriterState.IDLE;

    public bool available {
        get { return true; }
    }

    public string? unavailable_reason {
        owned get { return null; }
    }

    public VideoMessageWriterState state {
        get { return current_state; }
    }
    public int start_count { get; private set; default = 0; }
    public int finish_count { get; private set; default = 0; }
    public int cancel_count { get; private set; default = 0; }
    public uint64 write_count { get; private set; default = 0; }
    public uint64 audio_write_count { get; private set; default = 0; }
    public uint64 audio_pcm_frame_count { get; private set; default = 0; }
    public uint64 last_frame_id { get; private set; default = 0; }
    public uint64 last_audio_frame_id { get; private set; default = 0; }
    public size_t last_byte_count { get; private set; default = 0; }
    public string? output_path { get; private set; default = null; }
    public string? mime_type { get; private set; default = null; }
    public string? video_codec { get; private set; default = null; }
    public string? audio_codec { get; private set; default = null; }
    public int width { get; private set; default = 0; }
    public int height { get; private set; default = 0; }
    public int max_fps { get; private set; default = 0; }
    public int video_bitrate_bps { get; private set; default = 0; }

    public void start(VideoMessageWriterConfig config) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.IDLE && current_state != VideoMessageWriterState.CANCELLED) {
            throw new VideoMessageWriterError.INVALID_STATE("writer already started");
        }
        if (config.mime_type != VideoMessageRecorderV2.MIME_TYPE ||
                config.video_codec != VideoMessageRecorderV2.VIDEO_CODEC ||
                config.audio_codec != VideoMessageRecorderV2.AUDIO_CODEC ||
                config.width <= 0 ||
                config.height <= 0 ||
                config.max_fps <= 0 ||
                config.video_bitrate_bps <= 0) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected video writer config");
        }

        output_path = config.output_path;
        mime_type = config.mime_type;
        video_codec = config.video_codec;
        audio_codec = config.audio_codec;
        width = config.width;
        height = config.height;
        max_fps = config.max_fps;
        video_bitrate_bps = config.video_bitrate_bps;
        start_count++;
        current_state = VideoMessageWriterState.STARTED;
    }

    public void write_bgra_frame(
            Bytes bgra_data,
            int frame_width,
            int frame_height,
            int frame_stride,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED) {
            throw new VideoMessageWriterError.INVALID_STATE("writer is not started");
        }
        if (frame_width != width ||
                frame_height != height ||
                frame_stride < frame_width * 4 ||
                bgra_data.get_size() < (size_t) frame_stride * (size_t) frame_height) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected BGRA frame format");
        }

        write_count++;
        last_frame_id = frame_id;
        last_byte_count = bgra_data.get_size();
    }

    public void write_pcm_frame(
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample,
            uint64 frame_id) throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED) {
            throw new VideoMessageWriterError.INVALID_STATE("writer is not started");
        }
        if (sample_rate != VideoMessageRecorderV2.EXPECTED_AUDIO_SAMPLE_RATE ||
                channels != VideoMessageRecorderV2.EXPECTED_AUDIO_CHANNELS ||
                bytes_per_sample != VideoMessageRecorderV2.EXPECTED_AUDIO_BYTES_PER_SAMPLE) {
            throw new VideoMessageWriterError.INVALID_FORMAT("unexpected PCM frame format");
        }

        size_t byte_count = pcm_data.get_size();
        int bytes_per_pcm_frame = channels * bytes_per_sample;
        if (byte_count == 0 || byte_count % bytes_per_pcm_frame != 0) {
            throw new VideoMessageWriterError.INVALID_FORMAT("invalid PCM frame size");
        }

        audio_write_count++;
        audio_pcm_frame_count += (uint64) (byte_count / bytes_per_pcm_frame);
        last_audio_frame_id = frame_id;
    }

    public void finish() throws VideoMessageWriterError {
        if (current_state != VideoMessageWriterState.STARTED) {
            throw new VideoMessageWriterError.INVALID_STATE("writer is not started");
        }
        finish_count++;
        current_state = VideoMessageWriterState.FINALIZED;
    }

    public void cancel() {
        cancel_count++;
        current_state = VideoMessageWriterState.CANCELLED;
    }
}

private JingleRtp.LibwebrtcJingleDescription wait_for_local_description(
        EngineSessionOwner session,
        string label) throws Error {
    var waiter = new SignalWaiter();
    JingleRtp.LibwebrtcJingleDescription? description = null;

    ulong ready_handler = session.local_description_ready.connect((mapped) => {
        description = mapped;
        waiter.finish();
    });
    ulong error_handler = session.native_error.connect((status, message) => {
        waiter.error_message = @"$(status.to_log_string()): $(message)";
        waiter.finish();
    });

    waiter.run_until_signal();
    session.disconnect(ready_handler);
    session.disconnect(error_handler);

    if (waiter.timed_out) {
        throw new IOError.TIMED_OUT(@"timed out waiting for $(label)");
    }
    if (waiter.error_message != null) {
        throw new IOError.FAILED(@"native error while waiting for $(label): $((!) waiter.error_message)");
    }
    if (description == null) {
        throw new IOError.FAILED(@"missing $(label)");
    }
    return (!) description;
}

private void wait_for_remote_description_set(
        EngineSessionOwner session,
        JingleRtp.LibwebrtcSdpType expected,
        string label) throws Error {
    var waiter = new SignalWaiter();
    bool received = false;

    ulong ready_handler = session.remote_description_set.connect((type) => {
        if (type == expected) {
            received = true;
            waiter.finish();
        }
    });
    ulong error_handler = session.native_error.connect((status, message) => {
        waiter.error_message = @"$(status.to_log_string()): $(message)";
        waiter.finish();
    });

    waiter.run_until_signal();
    session.disconnect(ready_handler);
    session.disconnect(error_handler);

    if (waiter.timed_out) {
        throw new IOError.TIMED_OUT(@"timed out waiting for $(label)");
    }
    if (waiter.error_message != null) {
        throw new IOError.FAILED(@"native error while waiting for $(label): $((!) waiter.error_message)");
    }
    if (!received) {
        throw new IOError.FAILED(@"missing $(label)");
    }
}

private void assert_true(bool condition, string message) throws Error {
    if (!condition) {
        throw new IOError.FAILED(message);
    }
}

private void assert_int_eq(int actual, int expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): $(actual) != $(expected)");
    }
}

private void assert_str_eq(string? actual, string expected, string message) throws Error {
    if (actual != expected) {
        throw new IOError.FAILED(@"$(message): '$(actual ?? "(null)")' != '$(expected)'");
    }
}

private int read_pcm_s16_le(Bytes pcm_data, int frame_index) throws Error {
    unowned uint8[]? raw_maybe = pcm_data.get_data();
    if (raw_maybe == null || frame_index < 0) {
        throw new IOError.FAILED("missing PCM test data");
    }
    unowned uint8[] raw = (!) raw_maybe;
    int offset = frame_index * 2;
    if (offset < 0 || offset + 1 >= raw.length) {
        throw new IOError.FAILED("PCM test frame is out of range");
    }
    int sample = (int) raw[offset] | ((int) raw[offset + 1] << 8);
    return (sample & 0x8000) != 0 ? sample - 0x10000 : sample;
}

private void verify_media_message_start_fade() throws Error {
    const int sample_rate = 48000;
    const int sample_value = 12000;
    const int frame_count = sample_rate * 310 / 1000;
    uint8[] raw_pcm = new uint8[frame_count * 2];
    for (int frame = 0; frame < frame_count; frame++) {
        raw_pcm[frame * 2] = (uint8) (sample_value & 0xff);
        raw_pcm[frame * 2 + 1] = (uint8) ((sample_value >> 8) & 0xff);
    }

    Bytes faded_pcm = MediaMessagePcmUtil.apply_start_fade_in(
        new Bytes(raw_pcm), sample_rate, 1, 2, 0);
    int muted_end_frame = sample_rate * MediaMessagePcmUtil.START_MUTED_MS / 1000;
    int fade_frame_count = sample_rate * MediaMessagePcmUtil.START_FADE_MS / 1000;
    int fade_end_frame = muted_end_frame + fade_frame_count;
    assert_true(muted_end_frame > 0 && fade_end_frame < frame_count,
        "media-message startup envelope should fit in the test data");
    assert_int_eq(read_pcm_s16_le(faded_pcm, 0), 0,
        "media-message startup mute first sample");
    assert_int_eq(read_pcm_s16_le(faded_pcm, muted_end_frame - 1), 0,
        "media-message startup mute should last 250 milliseconds");
    assert_int_eq(read_pcm_s16_le(faded_pcm, muted_end_frame), 0,
        "media-message startup fade should begin at silence");
    assert_int_eq(read_pcm_s16_le(faded_pcm, muted_end_frame + fade_frame_count / 2), sample_value / 2,
        "media-message startup fade should reach half gain after 25 milliseconds");
    assert_int_eq(read_pcm_s16_le(faded_pcm, fade_end_frame), sample_value,
        "media-message startup fade should reach unity after 50 milliseconds");

    uint8[] stereo_raw = new uint8[3 * 2 * 2];
    for (int sample = 0; sample < 6; sample++) {
        int value = sample % 2 == 0 ? sample_value : -sample_value;
        uint16 encoded = (uint16) (value & 0xffff);
        stereo_raw[sample * 2] = (uint8) (encoded & 0xff);
        stereo_raw[sample * 2 + 1] = (uint8) (encoded >> 8);
    }
    Bytes stereo_mute_edge = MediaMessagePcmUtil.apply_start_fade_in(
        new Bytes(stereo_raw), sample_rate, 2, 2, (uint64) muted_end_frame - 1);
    assert_int_eq(read_pcm_s16_le(stereo_mute_edge, 0), 0, "stereo mute boundary left");
    assert_int_eq(read_pcm_s16_le(stereo_mute_edge, 1), 0, "stereo mute boundary right");
    assert_int_eq(read_pcm_s16_le(stereo_mute_edge, 4), 5, "stereo fade counts frames, not samples");
    assert_int_eq(read_pcm_s16_le(stereo_mute_edge, 5), -5, "stereo channels use the same fade gain");
    Bytes stereo_fade_edge = MediaMessagePcmUtil.apply_start_fade_in(
        new Bytes(stereo_raw), sample_rate, 2, 2, (uint64) fade_end_frame - 1);
    assert_int_eq(read_pcm_s16_le(stereo_fade_edge, 0), sample_value - 5, "stereo final fade frame left");
    assert_int_eq(read_pcm_s16_le(stereo_fade_edge, 1), -sample_value + 5, "stereo final fade frame right");
    assert_int_eq(read_pcm_s16_le(stereo_fade_edge, 2), sample_value, "stereo post-fade left is unchanged");
    assert_int_eq(read_pcm_s16_le(stereo_fade_edge, 3), -sample_value, "stereo post-fade right is unchanged");
}

private void verify_audio_writer_startup_pcm_routing() throws Error {
    const int frames_per_chunk = 480;
    int chunk_count = 35;
    const int muted_frames = 12000; // 250 ms at 48 kHz.
    const int fade_frames = 2400; // 50 ms at 48 kHz.
    EngineContext? context = null;
    AudioMessageRecorderV2? recorder = null;
    ulong raw_handler = 0;
    try {
        // The real worker supplies deterministic 10 ms square-wave buffers.
        // Only the file writer is replaced; no microphone or AAC file is used.
        context = new EngineContext(EngineAudioDeviceMode.SYNTHETIC);
        var writer = new CountingAudioMessageWriter() { capture_pcm = true };
        recorder = ((!) context).create_audio_message_recorder(
            test_tmp_path("dinox-audio-startup-routing.m4a"), writer);
        var raw_frames = new ArrayList<Bytes>();
        raw_handler = ((!) recorder).frame_received.connect((pcm_data, frame_id) => {
            raw_frames.add(pcm_data);
        });
        ((!) recorder).start();
        for (int chunk = 1; chunk < chunk_count; chunk++) {
            ((!) recorder).push_synthetic_frame();
        }
        assert_true(wait_for_condition(() => writer.captured_pcm.size == chunk_count &&
                raw_frames.size == chunk_count),
            "native synthetic capture should reach both the raw callback and writer");
        ((!) recorder).stop();
        assert_int_eq(writer.finish_count, 1, "startup routing writer finalizes once");
        assert_true(writer.pcm_frame_count == frames_per_chunk * chunk_count,
            "startup processing preserves the recording's frame count");

        for (int chunk = 0; chunk < chunk_count; chunk++) {
            Bytes raw = raw_frames[chunk];
            Bytes output = writer.captured_pcm[chunk];
            assert_true(raw.get_size() == frames_per_chunk * 2 &&
                    output.get_size() == raw.get_size(),
                "startup processing preserves each native 10 ms buffer");
            for (int frame = 0; frame < frames_per_chunk; frame++) {
                int source_sample = ((frame / 24) % 2) == 0 ? 10000 : -10000;
                int absolute_frame = chunk * frames_per_chunk + frame;
                int expected = source_sample;
                if (absolute_frame < muted_frames) {
                    expected = 0;
                } else if (absolute_frame < muted_frames + fade_frames) {
                    int magnitude = (10000 * (absolute_frame - muted_frames) + fade_frames / 2) / fade_frames;
                    expected = source_sample < 0 ? -magnitude : magnitude;
                }
                int tolerance = absolute_frame >= muted_frames &&
                    absolute_frame < muted_frames + fade_frames ? 1 : 0;
                int actual = read_pcm_s16_le(output, frame);
                if (read_pcm_s16_le(raw, frame) != source_sample ||
                        actual < expected - tolerance || actual > expected + tolerance) {
                    throw new IOError.FAILED(
                        "startup PCM routing mismatch at chunk %d frame %d: actual=%d expected=%d".printf(
                            chunk, frame, actual, expected));
                }
            }
        }
        assert_true(((!) context).active_non_call_activity_count == 0,
            "finalized startup recorder releases its worker activity");
    } finally {
        if (recorder != null) {
            if (raw_handler != 0) ((!) recorder).disconnect(raw_handler);
            try { ((!) recorder).cancel(); }
            catch (EngineError error) { debug("Startup recorder cleanup failed: %s", error.message); }
        }
        if (context != null) ((!) context).close();
    }
}

private void iterate_default_context() {
    MainContext context = MainContext.default();
    int64 deadline = get_monotonic_time() + 250 * 1000;
    int64 quiet_since = get_monotonic_time();
    while (get_monotonic_time() < deadline) {
        bool dispatched = false;
        while (context.pending()) {
            context.iteration(false);
            dispatched = true;
        }
        if (dispatched) {
            quiet_since = get_monotonic_time();
        } else if (get_monotonic_time() - quiet_since >= 20 * 1000) {
            break;
        } else {
            Thread.usleep(1000);
        }
    }
}

private void run_default_context_for_ms(int milliseconds) {
    int64 deadline = get_monotonic_time() + ((int64) milliseconds * 1000);
    while (get_monotonic_time() < deadline) {
        iterate_default_context();
        Thread.usleep(20 * 1000);
    }
    iterate_default_context();
}

private string test_tmp_path(string filename) {
    // Meson may run repeated test instances in parallel. A unique pathname
    // keeps their ffmpeg writers and cleanup from racing each other.
    return Path.build_filename(
        Environment.get_tmp_dir(),
        "%s-%s".printf(Uuid.string_random(), filename));
}

private bool wait_for_condition(WaitCondition condition, uint timeout_ms = WAIT_TIMEOUT_MS) {
    int64 deadline = get_monotonic_time() + ((int64) timeout_ms * 1000);
    while (!condition() && get_monotonic_time() < deadline) {
        iterate_default_context();
        Thread.usleep(5 * 1000);
    }
    iterate_default_context();
    return condition();
}

private void run_platform_audio_recorder_iteration(
        EngineContext context,
        int iteration) throws Error {
    Gee.List<EngineAudioDeviceInfo> microphones = context.get_audio_devices(false);
    if (microphones.size == 0) {
        throw new IOError.FAILED("platform audio recorder smoke requires a microphone");
    }
    string? alternate_device_enabled = Environment.get_variable(
        "DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_ALTERNATE_DEVICE_SMOKE");
    bool alternate_device = alternate_device_enabled == "1" ||
        alternate_device_enabled == "true" || alternate_device_enabled == "yes";
    int microphone_index = alternate_device ? (iteration - 1) % microphones.size : 0;
    context.set_audio_device(microphones[microphone_index]);

    AudioMessageWriter writer = AudioMessageWriterFactory.create_default_aac_m4a_writer();
    if (!writer.available) {
        throw new IOError.FAILED(
            "platform audio recorder smoke requires an available AAC/M4A writer: %s".printf(
                writer.unavailable_reason ?? "unknown"));
    }

    string output_path = test_tmp_path(
        "dinox-google-webrtc-audio-message-platform-smoke-%d.m4a".printf(iteration));
    FileUtils.remove(output_path);

    AudioMessageRecorderV2 recorder = context.create_audio_message_recorder(output_path, writer);
    int started_count = 0;
    int stopped_count = 0;
    double last_duration = 0.0;
    string? recorder_error = null;
    recorder.started.connect(() => {
        started_count++;
    });
    recorder.stopped.connect(() => {
        stopped_count++;
    });
    recorder.duration_changed.connect((seconds) => {
        last_duration = seconds;
    });
    recorder.recording_error.connect((message) => {
        recorder_error = message;
    });

    recorder.start();
    run_default_context_for_ms(600);
    if (recorder_error != null) {
        throw new IOError.FAILED(
            "platform audio recorder iteration %d failed: %s".printf(
                iteration, (!) recorder_error));
    }
    assert_int_eq(started_count, 1, "platform audio recorder started callback count");
    assert_true(
        recorder.frame_callback_count > 5,
        "platform audio recorder iteration %d should receive live PCM frames".printf(iteration));
    assert_true(
        last_duration > 0.05,
        "platform audio recorder iteration %d duration should advance".printf(iteration));
    recorder.stop();
    iterate_default_context();
    assert_int_eq(stopped_count, 1, "platform audio recorder stopped callback count");
    assert_true(
        recorder.file_writer_state == AudioMessageWriterState.FINALIZED,
        "platform audio recorder writer should finalize");
    File output_file = File.new_for_path(output_path);
    FileInfo output_info = output_file.query_info(
        FileAttribute.STANDARD_SIZE,
        FileQueryInfoFlags.NONE);
    assert_true(output_info.get_size() > 0, "platform audio recorder should create a non-empty file");
    recorder.cancel();
    FileUtils.remove(output_path);
}

private void run_optional_platform_audio_recorder_smoke() throws Error {
    string? enabled = Environment.get_variable("DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_SMOKE");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

    string? fresh_context_enabled = Environment.get_variable(
        "DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_FRESH_CONTEXT_SMOKE");
    bool fresh_context = fresh_context_enabled == "1" ||
        fresh_context_enabled == "true" || fresh_context_enabled == "yes";
    if (fresh_context) {
        for (int iteration = 1; iteration <= 20; iteration++) {
            EngineContext? iteration_context = null;
            try {
                iteration_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
                run_platform_audio_recorder_iteration((!) iteration_context, iteration);
            } finally {
                if (iteration_context != null) {
                    ((!) iteration_context).close();
                }
            }
        }
        return;
    }

    EngineContext? platform_context = null;
    try {
        platform_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
        for (int iteration = 1; iteration <= 20; iteration++) {
            run_platform_audio_recorder_iteration((!) platform_context, iteration);
        }
    } finally {
        if (platform_context != null) {
            ((!) platform_context).close();
        }
    }
}

private void run_optional_platform_audio_provider_smoke() throws Error {
    string? enabled = Environment.get_variable(
        "DINOX_GOOGLE_WEBRTC_PLATFORM_AUDIO_PROVIDER_SMOKE");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

#if WINDOWS
    EngineContext? supplied_context = null;
    int supplier_call_count = 0;
    var provider = new GoogleWebrtcMediaMessageRecorderProvider(
        () => {
            supplier_call_count++;
            if (supplied_context == null) {
                supplied_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
            }
            return (!) supplied_context;
        });
    try {
        for (int iteration = 1; iteration <= 20; iteration++) {
            string output_path = test_tmp_path(
                "dinox-google-webrtc-audio-provider-platform-smoke-%d.m4a".printf(iteration));
            FileUtils.remove(output_path);
            Dino.Plugins.AudioMessageRecorderSession session =
                provider.create_audio_message_recorder(output_path);
            int started_count = 0;
            int stopped_count = 0;
            int pcm_count = 0;
            double last_duration = 0.0;
            string? recorder_error = null;
            session.started.connect(() => {
                started_count++;
            });
            session.pcm_frame.connect((pcm_data, sample_rate, channels, bytes_per_sample) => {
                pcm_count++;
            });
            session.duration_changed.connect((seconds) => {
                last_duration = seconds;
            });
            session.recording_error.connect((message) => {
                recorder_error = message;
            });
            session.recording_stopped.connect((output) => {
                stopped_count++;
            });

            session.start();
            run_default_context_for_ms(600);
            if (recorder_error != null) {
                throw new IOError.FAILED(
                    "platform provider audio iteration %d failed: %s".printf(
                        iteration, (!) recorder_error));
            }
            assert_int_eq(started_count, 1, "platform provider audio started callback count");
            assert_true(
                pcm_count > 5,
                "platform provider audio iteration %d should receive live PCM frames".printf(iteration));
            assert_true(
                last_duration > 0.05,
                "platform provider audio iteration %d duration should advance".printf(iteration));
            session.stop();
            iterate_default_context();
            assert_int_eq(stopped_count, 1, "platform provider audio stopped callback count");
            File output_file = File.new_for_path(output_path);
            FileInfo output_info = output_file.query_info(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            assert_true(
                output_info.get_size() > 0,
                "platform provider audio should create a non-empty file");
            session.cancel();
            FileUtils.remove(output_path);
        }
        assert_int_eq(
            supplier_call_count,
            0,
            "Windows message recording must not reuse the call/playback context");
    } finally {
        if (supplied_context != null) {
            ((!) supplied_context).close();
        }
    }
#endif
}

private void run_optional_platform_video_recorder_smoke() throws Error {
    string? enabled = Environment.get_variable("DINOX_GOOGLE_WEBRTC_PLATFORM_VIDEO_SMOKE");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

    VideoMessageWriter writer = VideoMessageWriterFactory.create_default_mp4_h264_writer();
    if (!writer.available) {
        throw new IOError.FAILED(
            "platform video recorder smoke requires an available MP4/H.264 writer: %s".printf(
                writer.unavailable_reason ?? "unknown"));
    }

    EngineContext? platform_context = null;
    try {
        platform_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
        // Reproduce the chat sequence on the same worker/context: a completed
        // voice message followed by a camera+microphone video message.
        run_platform_audio_recorder_iteration((!) platform_context, 1);
        Gee.List<EngineVideoDeviceInfo> cameras = ((!) platform_context).get_video_devices();
        if (cameras.is_empty) {
            throw new IOError.FAILED("platform video recorder smoke requires at least one camera");
        }

        string output_path = test_tmp_path("dinox-google-webrtc-video-message-platform-smoke.mp4");
        FileUtils.remove(output_path);

        VideoMessageRecorderV2 recorder =
            ((!) platform_context).create_video_message_recorder(
                output_path,
                writer,
                cameras[0],
                160,
                90,
                15,
                true);
        int started_count = 0;
        int stopped_count = 0;
        double last_duration = 0.0;
        string? recorder_error = null;
        recorder.started.connect(() => {
            started_count++;
        });
        recorder.stopped.connect(() => {
            stopped_count++;
        });
        recorder.duration_changed.connect((seconds) => {
            last_duration = seconds;
        });
        recorder.recording_error.connect((message) => {
            recorder_error = message;
        });

        recorder.start();
        run_default_context_for_ms(3500);
        if (recorder_error != null) {
            throw new IOError.FAILED("platform video recorder failed: %s".printf((!) recorder_error));
        }
        assert_int_eq(started_count, 1, "platform video recorder started callback count");
        assert_true(recorder.frame_callback_count > 0, "platform video recorder should receive live BGRA frames");
        assert_true(recorder.audio_frame_callback_count > 0, "platform video recorder should receive live PCM frames");
        assert_true(recorder.audio_pcm_frame_count > 0, "platform video recorder should count PCM frames");
        assert_true(recorder.latest_preview_frame != null, "platform video recorder should keep a preview frame");
        assert_true(last_duration > 0.5, "platform video recorder duration should advance after prewarm");
        recorder.stop();
        iterate_default_context();
        assert_int_eq(stopped_count, 1, "platform video recorder stopped callback count");
        assert_true(
            recorder.file_writer_state == VideoMessageWriterState.FINALIZED,
            "platform video recorder writer should finalize");
        File output_file = File.new_for_path(output_path);
        FileInfo output_info = output_file.query_info(
            FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NONE);
        assert_true(output_info.get_size() > 0, "platform video recorder should create a non-empty file");
        recorder.cancel();
    } finally {
        if (platform_context != null) {
            ((!) platform_context).close();
        }
    }
}

private void run_optional_platform_video_provider_smoke() throws Error {
    string? enabled = Environment.get_variable(
        "DINOX_GOOGLE_WEBRTC_PLATFORM_VIDEO_PROVIDER_SMOKE");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

#if WINDOWS
    EngineContext? supplied_context = null;
    int supplier_call_count = 0;
    int critical_count = 0;
    uint log_handler_id = GLib.Log.set_handler(
        "google-webrtc",
        GLib.LogLevelFlags.LEVEL_CRITICAL,
        (domain, level, message) => {
            critical_count++;
        });
    var provider = new GoogleWebrtcMediaMessageRecorderProvider(
        () => {
            supplier_call_count++;
            if (supplied_context == null) {
                supplied_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
            }
            return (!) supplied_context;
        });
    try {
        assert_true(provider.video_available, "Windows platform provider video writer should be available");
        for (int iteration = 1; iteration <= 5; iteration++) {
            string output_path = test_tmp_path(
                "dinox-google-webrtc-video-provider-platform-smoke-%d.mp4".printf(iteration));
            FileUtils.remove(output_path);
            Dino.Plugins.VideoMessageRecorderSession session =
                provider.create_video_message_recorder(output_path);
            int started_count = 0;
            int stopped_count = 0;
            int preview_count = 0;
            double last_duration = 0.0;
            string? recorder_error = null;
            session.started.connect(() => {
                started_count++;
            });
            session.preview_frame_changed.connect((frame) => {
                preview_count++;
            });
            session.duration_changed.connect((seconds) => {
                last_duration = seconds;
            });
            session.recording_error.connect((message) => {
                recorder_error = message;
            });
            session.recording_stopped.connect((output) => {
                stopped_count++;
            });

            session.start();
            run_default_context_for_ms(3000);
            if (recorder_error != null) {
                throw new IOError.FAILED(
                    "platform provider video iteration %d failed: %s".printf(
                        iteration, (!) recorder_error));
            }
            assert_int_eq(started_count, 1, "platform provider video started callback count");
            assert_true(
                preview_count > 0,
                "platform provider video iteration %d should receive camera frames".printf(iteration));
            assert_true(
                last_duration > 0.1,
                "platform provider video iteration %d duration should advance".printf(iteration));
            session.stop();
            iterate_default_context();
            assert_int_eq(stopped_count, 1, "platform provider video stopped callback count");
            File output_file = File.new_for_path(output_path);
            FileInfo output_info = output_file.query_info(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            assert_true(
                output_info.get_size() > 0,
                "platform provider video should create a non-empty file");
            session.cancel();
            FileUtils.remove(output_path);
        }
        assert_int_eq(
            supplier_call_count,
            0,
            "Windows video-message recording must not reuse the call/playback context");
    } finally {
        GLib.Log.remove_handler("google-webrtc", log_handler_id);
        if (supplied_context != null) {
            ((!) supplied_context).close();
        }
    }
    assert_int_eq(critical_count, 0, "platform provider video lifecycle critical count");
#endif
}

private void run_optional_platform_device_test_smoke() throws Error {
    string? enabled = Environment.get_variable("DINOX_GOOGLE_WEBRTC_PLATFORM_DEVICE_TEST_SMOKE");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

    EngineContext? platform_context = null;
    try {
        platform_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);

        Gee.List<EngineAudioDeviceInfo> speakers = ((!) platform_context).get_audio_devices(true);
        if (speakers.is_empty) {
            throw new IOError.FAILED("platform device-test smoke requires at least one speaker");
        }
        ((!) platform_context).set_audio_device(speakers[0]);
        ((!) platform_context).play_test_tone('5', 120);
        ((!) platform_context).set_audio_device(speakers[0]);
        run_default_context_for_ms(350);

        Gee.List<EngineVideoDeviceInfo> cameras = ((!) platform_context).get_video_devices();
        if (cameras.is_empty) {
            throw new IOError.FAILED("platform device-test smoke requires at least one camera");
        }
        var preview_recorder = ((!) platform_context).create_video_message_recorder(
            test_tmp_path("dinox-google-webrtc-device-test-preview"),
            null,
            cameras[0],
            VideoMessageRecorderV2.DEFAULT_WIDTH,
            VideoMessageRecorderV2.DEFAULT_HEIGHT,
            VideoMessageRecorderV2.DEFAULT_MAX_FPS,
            false);
        string? recorder_error = null;
        preview_recorder.recording_error.connect((message) => {
            recorder_error = message;
        });
        preview_recorder.start();
        run_default_context_for_ms(1800);
        if (recorder_error != null) {
            throw new IOError.FAILED("platform camera preview failed: %s".printf((!) recorder_error));
        }
        assert_true(
            preview_recorder.frame_callback_count > 0,
            "platform camera preview should receive live BGRA frames");
        assert_true(
            preview_recorder.audio_frame_callback_count == 0,
            "platform camera preview must not start microphone capture");
        preview_recorder.cancel();
    } finally {
        if (platform_context != null) {
            ((!) platform_context).close();
        }
    }
}

private void run_optional_platform_lifecycle_stress() throws Error {
    string? enabled = Environment.get_variable("DINOX_GOOGLE_WEBRTC_PLATFORM_LIFECYCLE_STRESS");
    if (enabled != "1" && enabled != "true" && enabled != "yes") {
        return;
    }

    for (int iteration = 0; iteration < 12; iteration++) {
        EngineContext? platform_context = null;
        try {
            platform_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
            // Exercise the same System Default route used by the preferences
            // page when no explicit endpoint has been chosen. Explicit
            // endpoint selection remains covered by the device-test smoke.
            ((!) platform_context).play_test_tone('5', 60);
            run_default_context_for_ms(100);
            ((!) platform_context).stop_audio_test_playout();
        } finally {
            if (platform_context != null) {
                ((!) platform_context).close();
            }
        }
        run_default_context_for_ms(25);
    }
}

private void pump_ice_candidates(
        Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> candidates,
        ref int next_index,
        EngineSessionOwner target) throws Error {
    while (next_index < candidates.size) {
        JingleRtp.LibwebrtcJingleIceCandidate candidate = candidates[next_index++];
        target.add_remote_jingle_candidate(candidate.content_name, candidate.jingle_candidate);
    }
}

private void wait_for_remote_video_frame(
        EngineSessionOwner sender,
        EngineSessionOwner receiver,
        Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> sender_candidates,
        Gee.List<JingleRtp.LibwebrtcJingleIceCandidate> receiver_candidates,
        ref int next_sender_candidate,
        ref int next_receiver_candidate,
        string label) throws Error {
    Dino.Plugins.JmiCallVideoFrame? received_frame = null;
    string? native_error_message = null;
    string? last_push_error = null;

    ulong frame_handler = receiver.remote_video_frame.connect((frame) => {
        if (received_frame == null) {
            received_frame = frame;
        }
    });
    ulong error_handler = receiver.native_error.connect((status, message) => {
        native_error_message = @"$(status.to_log_string()): $(message)";
    });

    int64 deadline = get_monotonic_time() + VIDEO_FRAME_TIMEOUT_US;
    while (get_monotonic_time() < deadline && received_frame == null && native_error_message == null) {
        iterate_default_context();
        pump_ice_candidates(sender_candidates, ref next_sender_candidate, receiver);
        pump_ice_candidates(receiver_candidates, ref next_receiver_candidate, sender);

        Native.SessionState sender_state = sender.get_state();
        receiver.get_state();
        if (sender_state.local_video_source_attached != 0 && sender_state.local_video_track_attached != 0) {
            try {
                sender.push_synthetic_video_frame(160, 120);
                last_push_error = null;
            } catch (Error e) {
                last_push_error = e.message;
            }
        }

        iterate_default_context();
        Thread.usleep(20 * 1000);
    }

    receiver.disconnect(frame_handler);
    receiver.disconnect(error_handler);

    if (native_error_message != null) {
        throw new IOError.FAILED(@"native error while waiting for $(label): $((!) native_error_message)");
    }
    if (received_frame == null) {
        Native.SessionState sender_state = sender.get_state();
        Native.SessionState receiver_state = receiver.get_state();
        throw new IOError.TIMED_OUT(
            @"timed out waiting for $(label); " +
            @"sender_video_track=$(sender_state.local_video_track_attached) " +
            @"sender_ice=$(sender_state.ice_connection_state) " +
            @"receiver_video_receivers=$(receiver_state.remote_video_receiver_count) " +
            @"receiver_video_sinks=$(receiver_state.remote_video_sink_count) " +
            @"receiver_video_frames=$(receiver_state.remote_video_sink_frame_count) " +
            @"last_push_error=$(last_push_error ?? "none")");
    }

    Dino.Plugins.JmiCallVideoFrame frame = (!) received_frame;
    assert_int_eq(frame.width, 160, @"$(label) width");
    assert_int_eq(frame.height, 120, @"$(label) height");
    assert_true(frame.stride >= 160 * 4, @"$(label) stride should contain BGRA pixels");
    assert_true(frame.data.get_size() >= 160 * 120 * 4, @"$(label) data should contain BGRA frame bytes");
}

private void wait_for_local_video_frame(
        EngineSessionOwner session,
        string label) throws Error {
    Dino.Plugins.JmiCallVideoFrame? received_frame = null;
    string? native_error_message = null;
    string? last_push_error = null;

    ulong frame_handler = session.local_video_frame.connect((frame) => {
        if (received_frame == null) {
            received_frame = frame;
        }
    });
    ulong error_handler = session.native_error.connect((status, message) => {
        native_error_message = @"$(status.to_log_string()): $(message)";
    });

    int64 deadline = get_monotonic_time() + VIDEO_FRAME_TIMEOUT_US;
    while (get_monotonic_time() < deadline && received_frame == null && native_error_message == null) {
        iterate_default_context();
        try {
            session.push_synthetic_video_frame(128, 96);
            last_push_error = null;
        } catch (Error e) {
            last_push_error = e.message;
        }
        iterate_default_context();
        Thread.usleep(20 * 1000);
    }

    session.disconnect(frame_handler);
    session.disconnect(error_handler);

    if (native_error_message != null) {
        throw new IOError.FAILED(@"native error while waiting for $(label): $((!) native_error_message)");
    }
    if (received_frame == null) {
        Native.SessionState state = session.get_state();
        throw new IOError.TIMED_OUT(
            @"timed out waiting for $(label); " +
            @"local_video_source=$(state.local_video_source_attached) " +
            @"local_video_track=$(state.local_video_track_attached) " +
            @"capture_running=$(state.local_video_capture_running) " +
            @"capture_frames=$(state.local_video_capture_frame_count) " +
            @"last_push_error=$(last_push_error ?? "none")");
    }

    Dino.Plugins.JmiCallVideoFrame frame = (!) received_frame;
    assert_int_eq(frame.width, 128, @"$(label) width");
    assert_int_eq(frame.height, 96, @"$(label) height");
    assert_true(frame.stride >= 128 * 4, @"$(label) stride should contain BGRA pixels");
    assert_true(frame.data.get_size() >= 128 * 96 * 4, @"$(label) data should contain BGRA frame bytes");
}

private ExternalServiceDiscovery.Service make_external_service(
        string type,
        string host,
        uint port,
        string transport,
        string? username = null,
        string? password = null) {
    var service = new ExternalServiceDiscovery.Service();
    service.ty = type;
    service.host = host;
    service.port = port;
    service.transport = transport;
    service.username = username;
    service.password = password;
    return service;
}

private void run_context_activity_lease_smoke() throws Error {
    var context = new EngineContext();
    var audio_only_config = new EngineSessionConfig() {
        video_enabled = false,
        video_direction = JingleRtp.SdpMediaDirection.INACTIVE
    };

    EngineSessionOwner session = context.create_session(audio_only_config);
    AudioMessageRecorderV2 recorder = context.create_audio_message_recorder(
        test_tmp_path("dinox-google-webrtc-context-lease-smoke.raw"));
    assert_int_eq((int) context.active_activity_count, 2, "call and recorder activity lease count");

    session.close();
    assert_int_eq((int) context.active_activity_count, 1, "recorder lease survives final call close");
    assert_true(!context.is_closed, "context must remain open while recorder owns a lease");

    context.close();
    assert_true(context.close_pending, "context close must wait for active recorder");
    assert_true(!context.is_closed, "pending close must not destroy native context");

    recorder.start();
    iterate_default_context();
    recorder.push_synthetic_frame();
    iterate_default_context();
    recorder.stop();
    iterate_default_context();
    assert_int_eq((int) context.active_activity_count, 0, "final recorder releases context lease");
    assert_true(context.is_closed, "pending context close completes after final lease");

    try {
        context.create_session(audio_only_config);
        throw new IOError.FAILED("closed context unexpectedly created a session");
    } catch (EngineError e) {
        assert_true(e is EngineError.CLOSED, "closed context must reject new sessions");
    }

    var stress_context = new EngineContext();
    for (int iteration = 0; iteration < 100; iteration++) {
        EngineSessionOwner stress_session = stress_context.create_session(audio_only_config);
        AudioMessageRecorderV2 stress_recorder = stress_context.create_audio_message_recorder(
            test_tmp_path("dinox-google-webrtc-context-lease-stress.raw"));
        assert_int_eq((int) stress_context.active_activity_count, 2, "stress activity lease count");
        stress_session.close();
        stress_recorder.start();
        iterate_default_context();
        stress_recorder.stop();
        iterate_default_context();
        assert_int_eq((int) stress_context.active_activity_count, 0, "stress activity leases released");
    }
    stress_context.close();
    assert_true(stress_context.is_closed, "idle stress context should close immediately");
}

private void run_concurrent_context_close_smoke() throws Error {
    var context = new EngineContext();
    Mutex result_mutex = Mutex();
    int closed_error_count = 0;
    int unexpected_error_count = 0;

    Thread<void*>[] workers = new Thread<void*>[4];
    for (int worker_index = 0; worker_index < workers.length; worker_index++) {
        workers[worker_index] = new Thread<void*>(@"webrtc-context-close-$(worker_index)", () => {
            for (int iteration = 0; iteration < 100; iteration++) {
                try {
                    context.get_audio_devices(false);
                    context.get_audio_devices(true);
                    context.get_video_devices();
                } catch (EngineError e) {
                    result_mutex.lock();
                    if (e is EngineError.CLOSED) {
                        closed_error_count++;
                    } else {
                        unexpected_error_count++;
                    }
                    result_mutex.unlock();
                    if (e is EngineError.CLOSED) break;
                }
                Thread.usleep(1000);
            }
            return null;
        });
    }

    Thread.usleep(2 * 1000);
    context.close();
    foreach (Thread<void*> worker in workers) {
        worker.join();
    }

    assert_int_eq(unexpected_error_count, 0, "concurrent context close must not expose native errors");
    assert_true(closed_error_count > 0, "device workers should observe the defined closed-context result");
    assert_int_eq((int) context.active_activity_count, 0, "concurrent device operations must release all leases");
    assert_true(context.is_closed, "context must close after concurrent device operations finish");
}

private void finish_audio_session_and_store_weak_ref(
        Native.Context context,
        ref WeakRef session_ref) throws Error {
    var session = new GoogleWebrtcAudioMessageRecorderSession(
        new AudioMessageRecorderV2(
            context,
            test_tmp_path("dinox-google-webrtc-audio-session-release.raw")));
    session_ref.set(session);
    session.start();
    iterate_default_context();
    session.stop();
    iterate_default_context();
}

private void run_recorder_session_reentrant_release_smoke(Native.Context context) throws Error {
    int critical_count = 0;
    uint log_handler_id = GLib.Log.set_handler(
        "google-webrtc",
        GLib.LogLevelFlags.LEVEL_CRITICAL,
        (domain, level, message) => {
            critical_count++;
        });
    try {
        Dino.Plugins.AudioMessageRecorderSession? audio_session =
            new GoogleWebrtcAudioMessageRecorderSession(new AudioMessageRecorderV2(
                context,
                test_tmp_path("dinox-google-webrtc-reentrant-audio-session.raw")));
        bool audio_stopped = false;
        ((!) audio_session).recording_stopped.connect((output) => {
            audio_stopped = true;
            audio_session = null;
        });
        ((!) audio_session).start();
        iterate_default_context();
        ((!) audio_session).stop();
        iterate_default_context();
        assert_true(audio_stopped, "audio session should emit recording_stopped");
        assert_true(audio_session == null, "audio session consumer should be able to release the session synchronously");

        WeakRef finished_audio_session_ref = WeakRef(null);
        finish_audio_session_and_store_weak_ref(
            context, ref finished_audio_session_ref);
        assert_true(
            finished_audio_session_ref.get() == null,
            "finished audio session must not be retained by its frame callback");

        Dino.Plugins.VideoMessageRecorderSession? video_session =
            new GoogleWebrtcVideoMessageRecorderSession(new VideoMessageRecorderV2(
                context,
                test_tmp_path("dinox-google-webrtc-reentrant-video-session.raw"),
                160,
                90,
                15));
        bool video_stopped = false;
        ((!) video_session).recording_stopped.connect((output) => {
            video_stopped = true;
            video_session = null;
        });
        ((!) video_session).start();
        iterate_default_context();
        ((!) video_session).stop();
        iterate_default_context();
        assert_true(video_stopped, "video session should emit recording_stopped");
        assert_true(video_session == null, "video session consumer should be able to release the session synchronously");
    } finally {
        GLib.Log.remove_handler("google-webrtc", log_handler_id);
    }
    assert_int_eq(critical_count, 0, "recorder session synchronous release critical count");
}

private uint64 select_video_effect_for_test(
        EngineVideoEffectPipelineOwner pipeline,
        Native.VideoEffectType effect_type) throws Error {
    Native.VideoEffectConfig config = Native.video_effect_config_default();
    config.effect_type = effect_type;
    return select_video_config_for_test(pipeline, config);
}

private uint64 select_video_config_for_test(
        EngineVideoEffectPipelineOwner pipeline,
        Native.VideoEffectConfig config) throws Error {
    bool done = false;
    uint64 revision = 0;
    Error? selection_error = null;
    pipeline.select_config.begin(config, (_, result) => {
        try {
            revision = pipeline.select_config.end(result);
        } catch (Error e) {
            selection_error = e;
        }
        done = true;
    });

    int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (!done && get_monotonic_time() < deadline) {
        iterate_default_context();
        Thread.usleep(1000);
    }
    if (!done) throw new IOError.TIMED_OUT("video-effect selection did not complete");
    if (selection_error != null) throw (!) selection_error;
    return revision;
}

private void wait_for_video_effect_revision(
        EngineVideoEffectPipelineOwner pipeline,
        uint64 revision,
        Native.VideoEffectType effect_type) throws Error {
    Native.VideoPipelineState state = {};
    int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (get_monotonic_time() < deadline) {
        iterate_default_context();
        if (pipeline.get_cached_state(out state) &&
                state.application_state == Native.VideoEffectApplicationState.APPLIED &&
                state.applied_revision == revision && state.effect_type == effect_type) {
            return;
        }
        Thread.usleep(1000);
    }
    throw new IOError.TIMED_OUT("video-effect revision was not applied");
}

private void run_shared_video_pipeline_fanout_smoke(EngineContext context) throws Error {
    var config = new EngineSessionConfig() {
        audio_enabled = false,
        video_enabled = true
    };
    EngineVideoEffectPipelineOwner pipeline =
        context.create_video_effect_pipeline(4294977397);
    EngineSessionOwner? first = context.create_session(config);
    EngineSessionOwner second = context.create_session(config);
    EngineSessionOwner third = context.create_session(config);
    EngineSessionOwner? fourth = context.create_session(config);
    WeakRef first_ref = WeakRef(first);
    WeakRef fourth_ref = WeakRef(fourth);
    int first_preview_count = 0;
    int second_preview_count = 0;
    int third_preview_count = 0;
    int fourth_preview_count = 0;
    ((!) first).local_video_frame.connect((_frame) => { first_preview_count++; });
    second.local_video_frame.connect((_frame) => { second_preview_count++; });
    third.local_video_frame.connect((_frame) => { third_preview_count++; });
    ((!) fourth).local_video_frame.connect((_frame) => { fourth_preview_count++; });

    try {
        pipeline.attach((!) first, true);
        pipeline.attach(second, false);
        pipeline.attach(third, false);
        pipeline.attach((!) fourth, false);
        Native.VideoPipelineState attached = pipeline.get_state();
        assert_int_eq((int) attached.subscriber_count, 4,
            "shared pipeline must keep four peer attachments");
        assert_int_eq(pipeline.attachment_count_for_test(), 4,
            "Vala owner must keep four strong peer attachments");
        assert_true(pipeline.is_preview_session_for_test((!) first),
            "shared pipeline must have exactly the selected preview publisher");
        assert_true(!pipeline.is_preview_session_for_test(second) &&
                !pipeline.is_preview_session_for_test(third) &&
                !pipeline.is_preview_session_for_test((!) fourth),
            "shared pipeline subscribers must not publish duplicate previews");

        ((!) first).push_synthetic_video_frame(176, 144);
        run_default_context_for_ms(100);
        assert_true(((!) first).get_state().local_video_source_frame_count == 1 &&
                second.get_state().local_video_source_frame_count == 1 &&
                third.get_state().local_video_source_frame_count == 1 &&
                ((!) fourth).get_state().local_video_source_frame_count == 1,
            "one publisher frame must reach every attached local video source");
        assert_int_eq(first_preview_count, 1,
            "publisher must emit one local preview callback");
        assert_int_eq(second_preview_count + third_preview_count + fourth_preview_count, 0,
            "subscribers must not emit local preview callbacks");

        ((!) first).close();
        Native.VideoPipelineState closed_publisher = pipeline.get_state();
        assert_int_eq((int) closed_publisher.subscriber_count, 3,
            "native session close must remove the preview publisher attachment");
        assert_true(closed_publisher.preview_subscriber_id == 0 &&
                closed_publisher.preview_subscriber_generation == 0,
            "native session close must release preview ownership");
        assert_int_eq(pipeline.attachment_count_for_test(), 4,
            "Vala must retain the closed peer until explicit detach");
        pipeline.detach_session((!) first);
        assert_int_eq(pipeline.attachment_count_for_test(), 3,
            "detaching a closed publisher must release its Vala attachment");
        assert_true(!pipeline.is_preview_session_for_test((!) first),
            "detaching a closed publisher must clear Vala preview ownership");
        first = null;
        iterate_default_context();
        assert_true(first_ref.get() == null,
            "detaching a closed publisher must release every Vala pipeline reference");
        pipeline.attach(second, true);
        assert_true(pipeline.is_preview_session_for_test(second),
            "preview ownership must hand over after publisher detach");
        second.push_synthetic_video_frame(176, 144);
        run_default_context_for_ms(100);
        assert_true(second.get_state().local_video_source_frame_count == 2 &&
                third.get_state().local_video_source_frame_count == 2 &&
                ((!) fourth).get_state().local_video_source_frame_count == 2,
            "promoted publisher frame must reach every remaining subscriber");
        assert_int_eq(second_preview_count, 1,
            "promoted publisher must become the sole local preview source");
        assert_int_eq(third_preview_count + fourth_preview_count, 0,
            "handover must not create another preview publisher");

        ((!) fourth).close();
        assert_int_eq((int) pipeline.get_state().subscriber_count, 2,
            "native session close must remove a non-preview subscriber");
        assert_int_eq(pipeline.attachment_count_for_test(), 3,
            "Vala must retain the closed subscriber until bulk detach");
        pipeline.detach();
        assert_int_eq((int) pipeline.get_state().subscriber_count, 0,
            "bulk detach must remove every remaining native subscriber");
        assert_int_eq(pipeline.attachment_count_for_test(), 0,
            "bulk detach must release open and closed Vala attachments");
        assert_true(!pipeline.is_preview_session_for_test(second),
            "bulk detach must clear preview ownership");
        fourth = null;
        iterate_default_context();
        assert_true(fourth_ref.get() == null,
            "bulk detach must release every Vala pipeline reference to a closed subscriber");
    } finally {
        try { pipeline.detach(); } catch (Error e) {}
        pipeline.close();
        if (first != null) ((!) first).close();
        second.close();
        third.close();
        if (fourth != null) ((!) fourth).close();
    }
}

private void run_video_effect_contract_smoke(EngineContext context) throws Error {
    Native.VideoEffectCapabilities capabilities = context.get_video_effect_capabilities();
    assert_int_eq((int) Native.ABI_VERSION, 40, "video-effect ABI 40 contract");
    assert_int_eq((int) capabilities.abi_version, (int) Native.ABI_VERSION, "video-effect capability ABI");
    assert_true((capabilities.supported_effect_mask & 1) != 0, "video-effect NONE capability");
    assert_true((capabilities.supported_effect_mask &
            ((uint64) 1 << (int) Native.VideoEffectType.GRAYSCALE)) != 0,
        "video-effect GRAYSCALE capability");
    assert_true((capabilities.supported_effect_mask &
            ((uint64) 1 << (int) Native.VideoEffectType.WARM_TONE)) != 0,
        "video-effect WARM_TONE capability");
    assert_true(capabilities.max_subscribers > 0, "video-effect subscriber capacity");
    assert_true(capabilities.shared_pipeline_supported != 0, "shared one-capture fanout capability");

    uint64 logical_call_id = 4294977297;
    EngineVideoEffectPipelineOwner pipeline = context.create_video_effect_pipeline(logical_call_id);
    var video_only_config = new EngineSessionConfig() {
        audio_enabled = false,
        video_enabled = true
    };
    EngineSessionOwner session = context.create_session(video_only_config);
    int state_change_count = 0;
    ulong state_handler = pipeline.state_changed.connect(() => {
        state_change_count++;
    });

    Native.VideoPipelineState initial = pipeline.get_state();
    assert_true(initial.logical_call_id == logical_call_id, "video-effect logical call id");
    assert_true(initial.effect_type == Native.VideoEffectType.NONE, "video effects default to off");
    assert_true(initial.application_state == Native.VideoEffectApplicationState.IDLE,
        "video effects start idle until an explicit per-call selection");
    assert_true(initial.accepted_revision == 0 && initial.applied_revision == 0,
        "video effects start without an implicit selection");
    assert_int_eq((int) initial.subscriber_count, 0, "initial video-effect subscriber count");

    pipeline.attach(session, true);
    Native.VideoPipelineState attached = pipeline.get_state();
    assert_int_eq((int) attached.subscriber_count, 1, "attached video-effect subscriber count");
    assert_true(attached.preview_subscriber_id != 0, "video-effect preview publisher id");
    assert_true(attached.preview_subscriber_generation != 0, "video-effect preview publisher generation");

    uint64 revision = pipeline.set_none();
    assert_true(revision == 1, "first video-effect revision");
    int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (state_change_count == 0 && get_monotonic_time() < deadline) {
        iterate_default_context();
        Thread.usleep(1000);
    }
    assert_true(state_change_count == 1, "video-effect applied event");

    Native.VideoPipelineState cached = {};
    assert_true(pipeline.get_cached_state(out cached), "cached video-effect state");
    assert_true(cached.accepted_revision == revision && cached.applied_revision == revision,
        "video-effect event revision");
    assert_true(cached.effect_type == Native.VideoEffectType.NONE, "video-effect event remains off");

    Native.VideoEffectDiagnostics diagnostics = pipeline.get_diagnostics();
    assert_true(diagnostics.configuration_request_count == 1, "video-effect configuration count");
    assert_true(diagnostics.enqueued == 0 && diagnostics.processed == 0 &&
        diagnostics.frame_copy_count == 0 && diagnostics.effect_thread_count == 0 &&
        diagnostics.loaded_model_bytes == 0 && diagnostics.effect_owned_allocated_bytes == 0,
        "NONE adds no effect work or resources");

    uint64 grayscale_revision = select_video_effect_for_test(
        pipeline, Native.VideoEffectType.GRAYSCALE);
    wait_for_video_effect_revision(
        pipeline, grayscale_revision, Native.VideoEffectType.GRAYSCALE);
    diagnostics = pipeline.get_diagnostics();
    assert_true(diagnostics.effect_thread_count == 1 &&
        diagnostics.effect_handle_count == 1,
        "explicit GRAYSCALE selection starts exactly one bounded effect executor");

    uint64 warm_tone_revision = select_video_effect_for_test(
        pipeline, Native.VideoEffectType.WARM_TONE);
    wait_for_video_effect_revision(
        pipeline, warm_tone_revision, Native.VideoEffectType.WARM_TONE);
    assert_true(warm_tone_revision == grayscale_revision + 1,
        "Gray-to-Warm switching must advance the per-call revision exactly once");
    diagnostics = pipeline.get_diagnostics();
    assert_true(diagnostics.effect_thread_count == 1 &&
        diagnostics.effect_handle_count == 1 &&
        diagnostics.loaded_model_bytes == 0,
        "explicit WARM_TONE selection must reuse the single bounded effect executor");

    var mapped_capabilities = VideoEffectConfigMapper.capabilities(capabilities);
    uint64 last_selected_revision = warm_tone_revision;
    foreach (Dino.Plugins.JmiVideoEffectKind kind in new Dino.Plugins.JmiVideoEffectKind[] {
            Dino.Plugins.JmiVideoEffectKind.LIGHT_LEAK, Dino.Plugins.JmiVideoEffectKind.DREAMY,
            Dino.Plugins.JmiVideoEffectKind.PRISM_LIGHT, Dino.Plugins.JmiVideoEffectKind.FISHEYE,
            Dino.Plugins.JmiVideoEffectKind.VINTAGE_TV, Dino.Plugins.JmiVideoEffectKind.FROSTED_GLASS,
            Dino.Plugins.JmiVideoEffectKind.DUO_TONE }) {
        var selection = new Dino.Plugins.JmiVideoEffectSelection(kind,
            Dino.Plugins.JmiVideoEffectQuality.AUTO, 0, 0, 12, -8, -20, 30);
        Native.VideoEffectConfig config = VideoEffectConfigMapper.to_native(selection, mapped_capabilities);
        uint64 next_revision = select_video_config_for_test(pipeline, config);
        wait_for_video_effect_revision(pipeline, next_revision, config.effect_type);
        assert_true(next_revision == last_selected_revision + 1,
            "every additional preset must advance the full selection revision once");
        assert_true(VideoEffectConfigMapper.from_native(pipeline.get_state()).matches(selection),
            "additional presets and all adjustments must roundtrip through the real worker");
        diagnostics = pipeline.get_diagnostics();
        assert_true(diagnostics.effect_thread_count == 1 && diagnostics.effect_handle_count == 1 &&
            diagnostics.loaded_model_bytes == 0,
            "additional presets must share the existing effect worker without loading models");
        last_selected_revision = next_revision;
    }

    uint64 off_revision = select_video_effect_for_test(
        pipeline, Native.VideoEffectType.NONE);
    wait_for_video_effect_revision(pipeline, off_revision, Native.VideoEffectType.NONE);
    assert_true(off_revision == last_selected_revision + 1,
        "returning to Off must advance the per-call revision exactly once");
    diagnostics = pipeline.get_diagnostics();
    assert_true(diagnostics.effect_thread_count == 0 &&
        diagnostics.effect_handle_count == 0 &&
        diagnostics.effect_owned_allocated_bytes == 0,
        "returning to NONE releases all effect resources");

    pipeline.detach();
    Native.VideoPipelineState detached = pipeline.get_state();
    assert_int_eq((int) detached.subscriber_count, 0, "detached video-effect subscriber count");
    assert_true(detached.preview_subscriber_id == 0 && detached.preview_subscriber_generation == 0,
        "detached video-effect preview publisher");

    pipeline.disconnect(state_handler);
    session.close();
    pipeline.close();

    // The future call popover can produce several quick selections. Keep
    // those worker notifications latest-only on the GTK main context instead
    // of emitting one UI update for every obsolete revision.
    EngineVideoEffectPipelineOwner burst_pipeline =
        context.create_video_effect_pipeline(logical_call_id + 1);
    int burst_state_change_count = 0;
    ulong burst_state_handler = burst_pipeline.state_changed.connect(() => {
        burst_state_change_count++;
    });
    uint64 burst_revision = 0;
    for (int i = 0; i < 16; i++) {
        burst_revision = burst_pipeline.set_none();
    }
    int64 burst_deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (!burst_pipeline.has_queued_state(burst_revision) &&
            get_monotonic_time() < burst_deadline) {
        Thread.usleep(1000);
    }
    assert_true(burst_pipeline.has_queued_state(burst_revision),
        "latest video-effect burst revision should be queued for the UI");
    while (burst_state_change_count == 0 && get_monotonic_time() < burst_deadline) {
        iterate_default_context();
        Thread.usleep(1000);
    }
    run_default_context_for_ms(100);
    assert_int_eq(burst_state_change_count, 1,
        "rapid video-effect revisions should coalesce to one UI update");
    Native.VideoPipelineState burst_cached = {};
    assert_true(burst_pipeline.get_cached_state(out burst_cached),
        "coalesced video-effect state should be cached");
    assert_true(burst_cached.accepted_revision == burst_revision &&
        burst_cached.applied_revision == burst_revision,
        "coalesced video-effect cache should contain only the latest revision");
    Native.VideoPipelineState invalid_callback = burst_cached;
    invalid_callback.brightness = 101;
    invalid_callback.accepted_revision++;
    invalid_callback.applied_revision++;
    burst_pipeline.inject_state_for_test(invalid_callback);
    run_default_context_for_ms(20);
    Native.VideoPipelineState after_invalid = {};
    assert_true(burst_pipeline.get_cached_state(out after_invalid) &&
        after_invalid.accepted_revision == burst_revision && after_invalid.brightness == 0,
        "invalid callbacks must leave the valid full-configuration cache unchanged");
    Native.VideoPipelineState newest_callback = burst_cached;
    newest_callback.accepted_revision++;
    newest_callback.applied_revision++;
    burst_pipeline.inject_state_for_test(newest_callback);
    burst_pipeline.inject_state_for_test(burst_cached);
    run_default_context_for_ms(20);
    Native.VideoPipelineState after_older = {};
    assert_true(burst_pipeline.get_cached_state(out after_older) &&
        after_older.accepted_revision == newest_callback.accepted_revision,
        "a later stale callback must not replace a newer pending state before delivery");
    burst_pipeline.disconnect(burst_state_handler);
    burst_pipeline.close();

    // Closing a call must cancel an already queued GTK delivery. Otherwise a
    // worker reply could update a destroyed effects popover or call window.
    EngineVideoEffectPipelineOwner closing_pipeline =
        context.create_video_effect_pipeline(logical_call_id + 2);
    int late_state_change_count = 0;
    closing_pipeline.state_changed.connect(() => {
        late_state_change_count++;
    });
    uint64 closing_revision = closing_pipeline.set_none();
    int64 closing_deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (!closing_pipeline.has_queued_state(closing_revision) &&
            get_monotonic_time() < closing_deadline) {
        Thread.usleep(1000);
    }
    assert_true(closing_pipeline.has_queued_state(closing_revision),
        "closing video-effect revision should have a pending UI source");
    closing_pipeline.close();
    run_default_context_for_ms(100);
    assert_int_eq(late_state_change_count, 0,
        "closed video-effect pipeline must not emit a late UI update");

    // A worker IPC can hold native_mutex until its timeout. Closing from the
    // GTK/call thread must still return immediately, cancel the replaceable
    // pending slot and guarantee prioritized cleanup after the in-flight job.
    EngineVideoEffectPipelineOwner blocked_pipeline =
        context.create_video_effect_pipeline(logical_call_id + 3);
    bool blocker_done = false;
    Error? blocker_error = null;
    blocked_pipeline.block_native_control_for_test.begin(500, (_, result) => {
        try {
            blocked_pipeline.block_native_control_for_test.end(result);
        } catch (Error e) {
            blocker_error = e;
        }
        blocker_done = true;
    });
    int64 blocker_deadline = get_monotonic_time() + 2 * 1000 * 1000;
    while (!blocked_pipeline.control_in_flight_for_test() &&
            get_monotonic_time() < blocker_deadline) {
        Thread.usleep(1000);
    }
    assert_true(blocked_pipeline.control_in_flight_for_test(),
        "deterministic native-control blocker must be in flight");

    int cancelled_selection_count = 0;
    int unexpected_selection_count = 0;
    blocked_pipeline.select_effect.begin(Native.VideoEffectType.GRAYSCALE, (_, result) => {
        try {
            blocked_pipeline.select_effect.end(result);
            unexpected_selection_count++;
        } catch (IOError.CANCELLED e) {
            cancelled_selection_count++;
        } catch (Error e) {
            unexpected_selection_count++;
        }
    });
    blocked_pipeline.select_effect.begin(Native.VideoEffectType.NONE, (_, result) => {
        try {
            blocked_pipeline.select_effect.end(result);
            unexpected_selection_count++;
        } catch (IOError.CANCELLED e) {
            cancelled_selection_count++;
        } catch (Error e) {
            unexpected_selection_count++;
        }
    });
    assert_int_eq((int) blocked_pipeline.control_pending_count_for_test(), 1,
        "one call may retain only the latest pending effect request");

    int64 close_started_us = get_monotonic_time();
    blocked_pipeline.close();
    int64 close_elapsed_us = get_monotonic_time() - close_started_us;
    assert_true(close_elapsed_us < 100 * 1000,
        "pipeline close must not wait for blocked native control work");
    assert_int_eq((int) blocked_pipeline.control_pending_count_for_test(), 0,
        "close must synchronously cancel the latest pending effect request");

    int64 cleanup_deadline = get_monotonic_time() + 3 * 1000 * 1000;
    while ((!blocked_pipeline.cleanup_finished_for_test() ||
            !blocker_done || cancelled_selection_count != 2) &&
            get_monotonic_time() < cleanup_deadline) {
        iterate_default_context();
        Thread.usleep(1000);
    }
    assert_true(blocked_pipeline.cleanup_finished_for_test(),
        "pipeline cleanup must run after the blocked control request");
    assert_true(blocker_done && blocker_error != null && ((!) blocker_error).matches(
            IOError.quark(), IOError.CANCELLED),
        "close must logically cancel even the in-flight control request immediately");
    assert_int_eq(cancelled_selection_count, 2,
        "superseded and close-cancelled effect requests must both resume with CANCELLED");
    assert_int_eq(unexpected_selection_count, 0,
        "no queued effect choice may run after close");
}

private uint stage_background_for_test(EngineVideoEffectPipelineOwner pipeline, uint choice) throws Error {
    bool done = false; uint asset = 0; Error? stage_error = null;
    pipeline.stage_background.begin(choice, null, (_, result) => {
        try { asset = pipeline.stage_background.end(result); } catch (Error e) { stage_error = e; }
        done = true;
    });
    int64 deadline = get_monotonic_time() + 3 * 1000 * 1000;
    while (!done && get_monotonic_time() < deadline) { iterate_default_context(); Thread.usleep(1000); }
    if (!done) throw new IOError.TIMED_OUT("background staging did not complete");
    if (stage_error != null) throw (!) stage_error;
    return asset;
}

private void run_active_builtin_stage_supersession_smoke(EngineContext context) throws Error {
    // Stage/select requires the real IMAGE capability gate. This fixture is
    // meaningful with Root's trusted fake/model paths; absence is explicit.
    if ((context.get_video_effect_capabilities().supported_background_mask & 8U) == 0) {
        stdout.printf("SKIP active builtin stage supersession: IMAGE capability unavailable\n");
        return;
    }
    var pipeline = context.create_video_effect_pipeline(4294977398);
    try {
        uint active_asset = stage_background_for_test(pipeline, 2); // Office
        Native.VideoEffectConfig config = Native.video_effect_config_default();
        config.background_mode = Native.VideoBackgroundMode.IMAGE; config.asset_id = active_asset;
        select_video_config_for_test(pipeline, config);
        assert_true(pipeline.get_state().asset_id == active_asset, "initial builtin must be accepted IMAGE");

        // Existing global blocker: the older pending stage must cancel before
        // any physical staging. This alone does not reach stale post-prepare cleanup.
        bool blocker_done = false; Error? blocker_error = null;
        pipeline.block_native_control_for_test.begin(500, (_, result) => {
            try { pipeline.block_native_control_for_test.end(result); } catch (Error e) { blocker_error = e; }
            blocker_done = true;
        });
        int64 deadline = get_monotonic_time() + 3 * 1000 * 1000;
        while (!pipeline.control_in_flight_for_test() && get_monotonic_time() < deadline) Thread.usleep(1000);
        assert_true(pipeline.control_in_flight_for_test(), "global blocker must own the control worker");
        int cancelled = 0; int unexpected = 0; bool latest_done = false; uint latest_asset = 0;
        pipeline.stage_background.begin(2, null, (_, result) => {
            try { pipeline.stage_background.end(result); unexpected++; }
            catch (IOError.CANCELLED e) { cancelled++; } catch (Error e) { unexpected++; }
        });
        pipeline.stage_background.begin(2, null, (_, result) => {
            try { latest_asset = pipeline.stage_background.end(result); } catch (Error e) { unexpected++; }
            latest_done = true;
        });
        while ((!blocker_done || !latest_done || cancelled != 1) && get_monotonic_time() < deadline) {
            iterate_default_context(); Thread.usleep(1000);
        }
        assert_true(blocker_done && blocker_error == null && latest_done, "blocked pending stages must complete");
        assert_true(cancelled == 1 && unexpected == 0 && latest_asset == active_asset,
            "pending supersession must preserve the active deduplicated builtin ID");
        select_video_config_for_test(pipeline, config); // native registry lookup, not only a cached ID echo

        // Deterministic physical in-flight case: pause after builtin+prepare,
        // advance UI generation, then allow obsolete cleanup to run.
        pipeline.arm_background_precommit_for_test();
        cancelled = 0; unexpected = 0; latest_done = false; latest_asset = 0;
        pipeline.stage_background.begin(2, null, (_, result) => {
            try { pipeline.stage_background.end(result); unexpected++; }
            catch (IOError.CANCELLED e) { cancelled++; } catch (Error e) { unexpected++; }
        });
        deadline = get_monotonic_time() + 3 * 1000 * 1000;
        while (!pipeline.background_precommit_reached_for_test() && get_monotonic_time() < deadline) {
            iterate_default_context(); Thread.usleep(1000);
        }
        assert_true(pipeline.background_precommit_reached_for_test(), "physical stage must reach precommit barrier");
        pipeline.stage_background.begin(2, null, (_, result) => {
            try { latest_asset = pipeline.stage_background.end(result); } catch (Error e) { unexpected++; }
            latest_done = true;
        });
        pipeline.release_background_precommit_for_test();
        while ((!latest_done || cancelled != 1) && get_monotonic_time() < deadline) {
            iterate_default_context(); Thread.usleep(1000);
        }
        assert_true(latest_done && cancelled == 1 && unexpected == 0,
            "obsolete physically completed stage must cancel while latest stage succeeds");
        assert_true(latest_asset == active_asset, "obsolete cleanup must not retire accepted IMAGE ID");
        assert_true(pipeline.get_state().background_mode == Native.VideoBackgroundMode.IMAGE &&
            pipeline.get_state().asset_id == active_asset, "accepted IMAGE selection must remain unchanged");
        select_video_config_for_test(pipeline, config); // must remain a registered native asset
    } finally {
        pipeline.release_background_precommit_for_test(); pipeline.close();
    }
}

private void run_video_effect_wire_disconnect_nonblocking_smoke(
        EngineContext context) throws Error {
    var local_jid = new Jid("alice-disconnect@example.test/DinoX");
    var peer_jid = new Jid("bob-disconnect@example.test/Phone");
    EngineJmiSession? session = new EngineJmiSession.outgoing(
        context,
        new NoopEffectWireTransport(),
        new NoopEffectJmiTransport(),
        "effect-wire-disconnect",
        4294977302,
        local_jid,
        peer_jid.bare_jid,
        true,
        true);
    try {
        EngineVideoEffectPipelineOwner pipeline =
            ((!) session).ensure_video_effect_pipeline_for_test();
        bool blocker_done = false;
        Error? blocker_error = null;
        pipeline.block_native_control_for_test.begin(500, (_, result) => {
            try {
                pipeline.block_native_control_for_test.end(result);
            } catch (Error e) {
                blocker_error = e;
            }
            blocker_done = true;
        });
        int64 blocker_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!pipeline.control_in_flight_for_test() &&
                get_monotonic_time() < blocker_deadline) {
            Thread.usleep(1000);
        }
        assert_true(pipeline.control_in_flight_for_test(),
            "wire-disconnect blocker must own the effect-control lane");

        int64 disconnect_started_us = get_monotonic_time();
        ((!) session).disconnect_wire_session_for_test();
        int64 disconnect_elapsed_us = get_monotonic_time() - disconnect_started_us;
        assert_true(disconnect_elapsed_us < 100 * 1000,
            "wire disconnect must not synchronously detach through blocked worker IPC");
        assert_true(((!) session).video_effect_pipeline == null,
            "wire disconnect must release Vala effect-pipeline ownership immediately");

        int64 cleanup_deadline = get_monotonic_time() + 3 * 1000 * 1000;
        while ((!pipeline.cleanup_finished_for_test() || !blocker_done) &&
                get_monotonic_time() < cleanup_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_true(pipeline.cleanup_finished_for_test(),
            "wire disconnect must guarantee deferred native pipeline cleanup");
        assert_true(blocker_done && blocker_error != null && ((!) blocker_error).matches(
                IOError.quark(), IOError.CANCELLED),
            "wire disconnect must immediately invalidate the blocked control result");
    } finally {
        if (session != null) ((!) session).close();
        session = null;
    }
}

private void run_muji_group_close_nonblocking_smoke(
        EngineContext context) throws Error {
    var router = new EngineJmiSessionRouter();
    var group = new EngineMujiGroupSession(
        context, router, new NoopEffectWireTransport(),
        new NoopEffectJmiTransport(), new Jid("muji-close@example.test/DinoX"),
        new Jid("close@conference.example.test"), 4294977303, true,
        new NoopEffectMujiCodecProvider());
    EngineJmiSession? first = null;
    EngineJmiSession? second = null;
    try {
        var names = new HashMap<string, string>();
        var payloads = new HashMap<string, Gee.List<JingleRtp.PayloadType>>();
        names["audio"] = "voice";
        names["video"] = "camera";
        var audio = new ArrayList<JingleRtp.PayloadType>(JingleRtp.PayloadType.equals_func);
        audio.add(new JingleRtp.PayloadType() {
            id = 111, name = "opus", clockrate = 48000, channels = 2
        });
        var video = new ArrayList<JingleRtp.PayloadType>(JingleRtp.PayloadType.equals_func);
        video.add(new JingleRtp.PayloadType() {
            id = 96, name = "VP8", clockrate = 90000
        });
        payloads["audio"] = audio;
        payloads["video"] = video;
        group.configure_conference_media(names, payloads);
        group.set_local_video_enabled(false);
        first = group.start_peer_without_offer_for_test(
            new Jid("first-close@example.test/Phone"), "muji-close-first");
        second = group.start_peer_without_offer_for_test(
            new Jid("second-close@example.test/Phone"), "muji-close-second");
        EngineVideoEffectPipelineOwner pipeline = (!) group.shared_video_pipeline_for_test();
        assert_int_eq(pipeline.attachment_count_for_test(), 2,
            "group close fixture must own two live video attachments");
        EngineSessionOwner? first_engine = ((!) ((!) first).wire_session).session.engine;
        WeakRef first_engine_ref = WeakRef(first_engine);
        first_engine = null;

        bool blocker_done = false;
        Error? blocker_error = null;
        pipeline.block_native_control_for_test.begin(750, (_, result) => {
            try {
                pipeline.block_native_control_for_test.end(result);
            } catch (Error e) {
                blocker_error = e;
            }
            blocker_done = true;
        });
        int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!pipeline.control_in_flight_for_test() && get_monotonic_time() < deadline) {
            Thread.usleep(1000);
        }
        assert_true(pipeline.control_in_flight_for_test(),
            "group close blocker must own the native-control lane");

        int64 close_started_us = get_monotonic_time();
        group.close();
        assert_true(get_monotonic_time() - close_started_us < 100 * 1000,
            "whole group close must not wait for blocked native detach or pipeline destruction");
        assert_true(!group.shared_video_pipeline_open_for_test() &&
                group.video_attachment_count_for_test() == 0 &&
                group.preview_publisher_sid_for_test() == null,
            "whole group close must release its video maps and preview immediately");
        assert_true(((!) first).jmi_state == JmiState.ENDED &&
                ((!) second).jmi_state == JmiState.ENDED,
            "whole group close must terminate both peer legs immediately");
        // This fixture has no plugin ended handler to release wire owners.
        // Drop those references so only the pipeline owns the closed engines.
        ((!) first).close();
        ((!) second).close();
        first = null;
        second = null;
        assert_true(!pipeline.cleanup_finished_for_test() && first_engine_ref.get() != null,
            "deferred pipeline cleanup must retain attached session owners until its barrier finishes");

        deadline = get_monotonic_time() + 3 * 1000 * 1000;
        while ((!pipeline.cleanup_finished_for_test() || !blocker_done) &&
                get_monotonic_time() < deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_true(pipeline.cleanup_finished_for_test(),
            "whole group close must finish deferred native pipeline destruction");
        assert_true(blocker_done && blocker_error != null &&
                ((!) blocker_error).matches(IOError.quark(), IOError.CANCELLED),
            "whole group close must invalidate the outstanding native-control result");
        assert_int_eq(pipeline.attachment_count_for_test(), 0,
            "deferred group cleanup must release every Vala attachment");
        iterate_default_context();
        assert_true(first_engine_ref.get() == null,
            "completed group cleanup must release its last Vala session reference");
    } finally {
        group.close();
        if (first != null) ((!) first).close();
        if (second != null) ((!) second).close();
    }
}

private void run_muji_video_effect_direct_gate_smoke(
        EngineContext context,
        string applied_marker_path) throws Error {
    var local_jid = new Jid("alice-muji@example.test/DinoX");
    var peer_jid = new Jid("bob-muji@example.test/Phone");
    EngineJmiSession? session = new EngineJmiSession.outgoing(
        context,
        new NoopEffectWireTransport(),
        new NoopEffectJmiTransport(),
        "muji-effect-direct-gate",
        4294977301,
        local_jid,
        peer_jid.bare_jid,
        true,
        true);
    try {
        EngineVideoEffectPipelineOwner pipeline =
            ((!) session).ensure_video_effect_pipeline_for_test();
        bool racing_request_done = false;
        Error? racing_request_error = null;
        ((!) session).select_video_effect.begin(
            new Dino.Plugins.JmiVideoEffectSelection(
                Dino.Plugins.JmiVideoEffectKind.GRAYSCALE),
            (_, result) => {
                try {
                    ((!) session).select_video_effect.end(result);
                } catch (Error e) {
                    racing_request_error = e;
                }
                racing_request_done = true;
            });
        int64 applied_deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while ((!pipeline.control_in_flight_for_test() ||
                !FileUtils.test(applied_marker_path, FileTest.EXISTS)) &&
                get_monotonic_time() < applied_deadline) {
            Thread.usleep(1000);
        }
        assert_true(pipeline.control_in_flight_for_test() &&
                FileUtils.test(applied_marker_path, FileTest.EXISTS),
            "MUJI race must observe native APPLIED while its IPC reply is outstanding");

        // Reproduce the narrow audit race: a wire teardown removes the
        // visible pipeline just before MUJI promotion, while native cleanup is
        // still queued behind the delayed post-apply IPC reply.
        int64 disconnect_started_us = get_monotonic_time();
        ((!) session).disconnect_wire_session_for_test();
        assert_true(get_monotonic_time() - disconnect_started_us < 100 * 1000,
            "pre-MUJI wire disconnect must stay nonblocking");
        assert_true(((!) session).video_effect_pipeline == null &&
                !pipeline.cleanup_finished_for_test(),
            "pre-MUJI disconnect must leave only an outstanding native cleanup");

        bool fence_done = false;
        int64 promotion_started_us = get_monotonic_time();
        ((!) session).fence_video_effects_for_group_call.begin((_, result) => {
            ((!) session).fence_video_effects_for_group_call.end(result);
            fence_done = true;
        });
        int64 promotion_elapsed_us = get_monotonic_time() - promotion_started_us;
        assert_true(promotion_elapsed_us < 100 * 1000,
            "starting the MUJI fence must not block on in-flight native IPC");
        Dino.Plugins.JmiVideoEffectCapabilities capabilities =
            ((!) session).get_video_effect_capabilities();
        assert_true(!capabilities.available &&
                capabilities.unavailable_reason ==
                    Dino.Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL,
            "MUJI backend gate must advertise group-call unavailability");
        assert_true(((!) session).video_effect_pipeline == null,
            "MUJI fence must not restore pre-fence effect-pipeline ownership");

        int64 cancellation_deadline = get_monotonic_time() + 200 * 1000;
        while (!racing_request_done && get_monotonic_time() < cancellation_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_true(racing_request_done && racing_request_error != null &&
                ((!) racing_request_error).matches(IOError.quark(), IOError.CANCELLED),
            "MUJI promotion must logically cancel an already in-flight effect request immediately");

        // The worker hook sleeps after native set_config has applied but
        // before replying. Promotion must remain pending until that reply and
        // the following VIDEO_PIPELINE_DESTROY ordering barrier.
        run_default_context_for_ms(100);
        assert_true(!fence_done,
            "MUJI must not become active before the in-flight IPC and destroy barrier finish");
        int64 cleanup_deadline = get_monotonic_time() + 4 * 1000 * 1000;
        while ((!pipeline.cleanup_finished_for_test() || !fence_done) &&
                get_monotonic_time() < cleanup_deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_true(fence_done && pipeline.cleanup_finished_for_test(),
            "MUJI fence must complete only after native IPC and pipeline destroy are ordered");

        bool done = false;
        Error? request_error = null;
        ((!) session).select_video_effect.begin(
            new Dino.Plugins.JmiVideoEffectSelection(
                Dino.Plugins.JmiVideoEffectKind.GRAYSCALE),
            (_, result) => {
                try {
                    ((!) session).select_video_effect.end(result);
                } catch (Error e) {
                    request_error = e;
                }
                done = true;
            });
        int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (!done && get_monotonic_time() < deadline) {
            iterate_default_context();
            Thread.usleep(1000);
        }
        assert_true(done, "MUJI direct backend request must complete immediately");
        assert_true(request_error != null && ((!) request_error).matches(
                IOError.quark(), IOError.NOT_SUPPORTED),
            "MUJI direct backend request must fail before control-worker IPC");
    } finally {
        if (session != null) ((!) session).close();
        session = null;
    }
}

private int run_smoke() {
    EngineContext? context = null;
    EngineSessionOwner? offer_session = null;
    EngineSessionOwner? answer_session = null;

    try {
        string? platform_only = Environment.get_variable(
            "DINOX_GOOGLE_WEBRTC_PLATFORM_ONLY_SMOKE");
        if (platform_only == "1" || platform_only == "true" || platform_only == "yes") {
            run_optional_platform_audio_recorder_smoke();
            run_optional_platform_audio_provider_smoke();
            run_optional_platform_video_recorder_smoke();
            run_optional_platform_video_provider_smoke();
            run_optional_platform_device_test_smoke();
            run_optional_platform_lifecycle_stress();
            return 0;
        }

        context = new EngineContext();
        run_media_message_provider_device_tests();
        unowned Native.BuildInfo? build_info = ((!) context).get_build_info();
        assert_true(build_info != null, "build info must be available");
        assert_int_eq((int) ((!) build_info).abi_version, (int) Native.ABI_VERSION, "ABI version should match");
        assert_int_eq((int) ((!) build_info).webrtc_milestone, 152, "engine must load the M152 runtime");
        assert_true(((!) build_info).runtime_enabled == 1, "wrapper runtime must be enabled");
        assert_str_eq(EngineMediaPolicy.PREFERRED_AUDIO_CODEC, "opus", "preferred audio codec");
        assert_str_eq(EngineMediaPolicy.PREFERRED_VIDEO_CODEC, "VP8", "preferred video codec");
        assert_true(EngineMediaPolicy.VIDEO_CODEC_FALLBACKS_ALLOWED, "negotiated video codec fallbacks must remain allowed");
        assert_true(EngineMediaPolicy.AUDIO_ONLY_FALLBACK_ALLOWED, "audio-only fallback must remain allowed");
        assert_true(EngineMediaPolicy.LIBWEBRTC_OWNS_RUNTIME_ADAPTATION, "libwebrtc must own runtime adaptation");
        assert_true(EngineMediaPolicy.is_preferred_video_codec("VP8"), "VP8 should be preferred");
        assert_true(EngineMediaPolicy.is_video_fallback_codec("H.264"), "H.264 must remain an interoperable codec alternative");
        assert_true(EngineMediaPolicy.is_video_fallback_codec("VP9"), "VP9 must remain an interoperable codec alternative");
        verify_media_message_start_fade();
        verify_audio_writer_startup_pcm_routing();
        assert_true(
            EngineMediaPolicy.video_codec_preference_rank("VP8") <
                EngineMediaPolicy.video_codec_preference_rank("VP9"),
            "VP8 should sort before fallback codecs");

        // Production retires the shared worker after the final call because
        // M150's ADM is not reusable after the last PeerConnection closes.
        // Keep the video-pipeline contract in its own call context so this
        // smoke does not bypass that plugin lifecycle and poison the later
        // standalone speaker/playback checks.
        string effect_applied_marker = test_tmp_path(
            "video-effect-set-config-applied.marker");
        FileUtils.unlink(effect_applied_marker);
        Environment.set_variable("DINOX_WEBRTC_ENABLE_TEST_FAULTS", "1", true);
        Environment.set_variable(
            "DINOX_WEBRTC_TEST_EFFECT_CONFIG_DELAY_LOGICAL_CALL_ID",
            "4294977301", true);
        Environment.set_variable(
            "DINOX_WEBRTC_TEST_EFFECT_CONFIG_APPLIED_MARKER",
            effect_applied_marker, true);
        Environment.set_variable(
            "DINOX_WEBRTC_TEST_EFFECT_CONFIG_POST_APPLY_DELAY_MS",
            "700", true);
        var video_effect_context = new EngineContext();
        try {
            run_shared_video_pipeline_fanout_smoke(video_effect_context);
            run_video_effect_contract_smoke(video_effect_context);
            run_active_builtin_stage_supersession_smoke(video_effect_context);
            run_video_effect_wire_disconnect_nonblocking_smoke(video_effect_context);
            run_muji_group_close_nonblocking_smoke(video_effect_context);
            run_muji_video_effect_direct_gate_smoke(
                video_effect_context, effect_applied_marker);
        } finally {
            video_effect_context.close();
            Environment.unset_variable("DINOX_WEBRTC_ENABLE_TEST_FAULTS");
            Environment.unset_variable(
                "DINOX_WEBRTC_TEST_EFFECT_CONFIG_DELAY_LOGICAL_CALL_ID");
            Environment.unset_variable(
                "DINOX_WEBRTC_TEST_EFFECT_CONFIG_APPLIED_MARKER");
            Environment.unset_variable(
                "DINOX_WEBRTC_TEST_EFFECT_CONFIG_POST_APPLY_DELAY_MS");
            FileUtils.unlink(effect_applied_marker);
        }

        run_context_activity_lease_smoke();
        run_concurrent_context_close_smoke();

        Native.Context? recorder_context = null;
        assert_true(
            Native.context_new(out recorder_context) == Native.Status.OK,
            "native recorder context should be created");
        assert_true(recorder_context != null, "native recorder context should not be null");
        run_recorder_session_reentrant_release_smoke((!) recorder_context);
        var media_recorder = new MediaMessageRecorderNative(
            (!) recorder_context,
            Native.MediaRecorderKind.AUDIO,
            test_tmp_path("dinox-google-webrtc-engine-smoke.m4a"),
            "audio/mp4");
        int recorder_started_count = 0;
        int recorder_stopped_count = 0;
        uint64 recorder_audio_frame_count = 0;
        size_t recorder_last_audio_size = 0;
        int recorder_last_audio_sample_rate = 0;
        int recorder_last_audio_channels = 0;
        int recorder_last_audio_bytes_per_sample = 0;
        uint64 recorder_last_audio_frame_id = 0;
        media_recorder.started.connect(() => {
            recorder_started_count++;
        });
        media_recorder.stopped.connect(() => {
            recorder_stopped_count++;
        });
        media_recorder.audio_frame.connect((pcm_data, sample_rate, channels, bytes_per_sample, frame_id) => {
            recorder_audio_frame_count++;
            recorder_last_audio_size = pcm_data.get_size();
            recorder_last_audio_sample_rate = sample_rate;
            recorder_last_audio_channels = channels;
            recorder_last_audio_bytes_per_sample = bytes_per_sample;
            recorder_last_audio_frame_id = frame_id;
        });
        assert_true(
            media_recorder.get_state() == Native.MediaRecorderState.IDLE,
            "media recorder should start idle");
        assert_true(
            media_recorder.push_synthetic_frame() == Native.Status.NOT_READY,
            "media recorder synthetic frame should require recording state");
        assert_true(
            media_recorder.start() == Native.Status.OK,
            "media recorder synthetic start should succeed");
        assert_true(
            wait_for_condition(() => recorder_started_count == 1 && recorder_audio_frame_count >= 1),
            "audio recorder start callbacks should arrive");
        assert_true(
            media_recorder.get_state() == Native.MediaRecorderState.RECORDING,
            "media recorder should enter recording state");
        assert_int_eq(recorder_started_count, 1, "audio recorder started callback count");
        assert_true(recorder_audio_frame_count == 1, "audio recorder should emit initial synthetic PCM frame");
        assert_true(recorder_last_audio_size == 480 * 2, "audio recorder PCM frame byte size");
        assert_int_eq(recorder_last_audio_sample_rate, 48000, "audio recorder sample rate");
        assert_int_eq(recorder_last_audio_channels, 1, "audio recorder channel count");
        assert_int_eq(recorder_last_audio_bytes_per_sample, 2, "audio recorder bytes per sample");
        assert_true(recorder_last_audio_frame_id == 1, "audio recorder first frame id");
        assert_true(
            media_recorder.push_synthetic_frame() == Native.Status.OK,
            "audio recorder explicit synthetic frame should succeed");
        assert_true(
            wait_for_condition(() => recorder_audio_frame_count >= 2),
            "audio recorder explicit frame callback should arrive");
        assert_true(recorder_audio_frame_count == 2, "audio recorder should emit second synthetic PCM frame");
        assert_true(recorder_last_audio_frame_id == 2, "audio recorder second frame id");
        assert_true(
            media_recorder.stop() == Native.Status.OK,
            "audio recorder stop should succeed");
        assert_true(
            wait_for_condition(() => recorder_stopped_count == 1),
            "audio recorder stop callback should arrive");
        assert_int_eq(recorder_stopped_count, 1, "audio recorder stopped callback count");
        assert_true(
            media_recorder.get_state() == Native.MediaRecorderState.IDLE,
            "media recorder should return idle after stop");
        assert_true(
            media_recorder.cancel() == Native.Status.OK,
            "media recorder cancel should succeed");

        var video_media_recorder = new MediaMessageRecorderNative(
            (!) recorder_context,
            Native.MediaRecorderKind.VIDEO,
            test_tmp_path("dinox-google-webrtc-engine-smoke.mp4"),
            "video/mp4",
            160,
            90,
            15);
        int video_recorder_started_count = 0;
        int video_recorder_stopped_count = 0;
        uint64 recorder_video_frame_count = 0;
        size_t recorder_last_video_size = 0;
        int recorder_last_video_width = 0;
        int recorder_last_video_height = 0;
        int recorder_last_video_stride = 0;
        uint64 recorder_last_video_frame_id = 0;
        video_media_recorder.started.connect(() => {
            video_recorder_started_count++;
        });
        video_media_recorder.stopped.connect(() => {
            video_recorder_stopped_count++;
        });
        video_media_recorder.video_frame.connect((bgra_data, width, height, stride, frame_id) => {
            recorder_video_frame_count++;
            recorder_last_video_size = bgra_data.get_size();
            recorder_last_video_width = width;
            recorder_last_video_height = height;
            recorder_last_video_stride = stride;
            recorder_last_video_frame_id = frame_id;
        });
        assert_true(
            video_media_recorder.start() == Native.Status.OK,
            "video recorder synthetic start should succeed");
        assert_true(
            wait_for_condition(() => video_recorder_started_count == 1 && recorder_video_frame_count >= 1),
            "video recorder start callbacks should arrive");
        assert_int_eq(video_recorder_started_count, 1, "video recorder started callback count");
        assert_true(recorder_video_frame_count == 1, "video recorder should emit initial synthetic BGRA frame");
        assert_int_eq(recorder_last_video_width, 160, "video recorder synthetic width");
        assert_int_eq(recorder_last_video_height, 90, "video recorder synthetic height");
        assert_int_eq(recorder_last_video_stride, 160 * 4, "video recorder synthetic stride");
        assert_true(recorder_last_video_size == 160 * 90 * 4, "video recorder synthetic byte size");
        assert_true(recorder_last_video_frame_id == 1, "video recorder first frame id");
        assert_true(
            video_media_recorder.push_synthetic_frame() == Native.Status.OK,
            "video recorder explicit synthetic frame should succeed");
        assert_true(
            wait_for_condition(() => recorder_video_frame_count >= 2),
            "video recorder explicit frame callback should arrive");
        assert_true(recorder_video_frame_count == 2, "video recorder should emit second synthetic BGRA frame");
        assert_true(recorder_last_video_frame_id == 2, "video recorder second frame id");
        assert_true(
            video_media_recorder.stop() == Native.Status.OK,
            "video recorder stop should succeed");
        assert_true(
            wait_for_condition(() => video_recorder_stopped_count == 1),
            "video recorder stop callback should arrive");
        assert_int_eq(video_recorder_stopped_count, 1, "video recorder stopped callback count");
        assert_true(
            video_media_recorder.cancel() == Native.Status.OK,
            "video recorder cancel should succeed");

        var video_message_recorder = new VideoMessageRecorderV2(
            (!) recorder_context,
            test_tmp_path("dinox-google-webrtc-video-message-v2-smoke.mp4"),
            160,
            90,
            15);
        int video_message_started_count = 0;
        int video_message_stopped_count = 0;
        uint64 video_message_frame_signal_count = 0;
        uint64 video_message_preview_signal_count = 0;
        uint64 video_message_last_frame_id = 0;
        double video_message_last_duration = 0.0;
        bool video_message_frame_size_valid = true;
        video_message_recorder.started.connect(() => {
            video_message_started_count++;
        });
        video_message_recorder.stopped.connect(() => {
            video_message_stopped_count++;
        });
        video_message_recorder.frame_received.connect((bgra_data, width, height, stride, frame_id) => {
            video_message_frame_signal_count++;
            video_message_last_frame_id = frame_id;
            if (width != 160 || height != 90 || stride != 160 * 4 ||
                    bgra_data.get_size() != 160 * 90 * 4) {
                video_message_frame_size_valid = false;
            }
        });
        video_message_recorder.preview_frame_changed.connect((bgra_data, width, height, stride) => {
            video_message_preview_signal_count++;
        });
        video_message_recorder.duration_changed.connect((seconds) => {
            video_message_last_duration = seconds;
        });
        video_message_recorder.start();
        iterate_default_context();
        assert_int_eq(video_message_started_count, 1, "video message v2 started callback count");
        assert_true(
            video_message_recorder.state == Native.MediaRecorderState.RECORDING,
            "video message v2 should enter recording state");
        assert_true(video_message_recorder.frame_callback_count == 1, "video message v2 first frame callback count");
        assert_true(video_message_frame_signal_count == 1, "video message v2 first frame signal count");
        assert_true(video_message_preview_signal_count == 1, "video message v2 first preview signal count");
        assert_true(video_message_frame_size_valid, "video message v2 frame size");
        assert_int_eq(video_message_recorder.width, 160, "video message v2 first width");
        assert_int_eq(video_message_recorder.height, 90, "video message v2 first height");
        assert_int_eq(video_message_recorder.stride, 160 * 4, "video message v2 first stride");
        assert_true(video_message_recorder.last_frame_byte_count == 160 * 90 * 4, "video message v2 first byte count");
        assert_true(video_message_recorder.latest_preview_frame != null, "video message v2 should keep latest preview frame");
        assert_true(video_message_recorder.last_frame_id == 1, "video message v2 first frame id property");
        assert_true(video_message_last_frame_id == 1, "video message v2 first frame id signal");
        assert_true(video_message_last_duration > 0.06 && video_message_last_duration < 0.07, "video message v2 first duration");
        video_message_recorder.push_synthetic_frame();
        iterate_default_context();
        assert_true(video_message_recorder.frame_callback_count == 2, "video message v2 second frame callback count");
        assert_true(video_message_frame_signal_count == 2, "video message v2 second frame signal count");
        assert_true(video_message_preview_signal_count == 2, "video message v2 second preview signal count");
        assert_true(video_message_recorder.last_frame_id == 2, "video message v2 second frame id property");
        assert_true(video_message_last_frame_id == 2, "video message v2 second frame id signal");
        assert_true(video_message_recorder.duration_seconds > 0.13 && video_message_recorder.duration_seconds < 0.14, "video message v2 second duration property");
        assert_true(video_message_last_duration > 0.13 && video_message_last_duration < 0.14, "video message v2 second duration signal");
        video_message_recorder.stop();
        iterate_default_context();
        assert_int_eq(video_message_stopped_count, 1, "video message v2 stopped callback count");
        assert_true(
            video_message_recorder.state == Native.MediaRecorderState.IDLE,
            "video message v2 should return idle after stop");
        video_message_recorder.cancel();

        var audio_message_recorder = new AudioMessageRecorderV2(
            (!) recorder_context,
            test_tmp_path("dinox-google-webrtc-audio-message-v2-smoke.m4a"));
        int audio_message_started_count = 0;
        int audio_message_stopped_count = 0;
        uint64 audio_message_frame_signal_count = 0;
        uint64 audio_message_last_frame_id = 0;
        double audio_message_last_duration = 0.0;
        double audio_message_last_level = 0.0;
        bool audio_message_frame_size_valid = true;
        audio_message_recorder.started.connect(() => {
            audio_message_started_count++;
        });
        audio_message_recorder.stopped.connect(() => {
            audio_message_stopped_count++;
        });
        audio_message_recorder.frame_received.connect((pcm_data, frame_id) => {
            audio_message_frame_signal_count++;
            audio_message_last_frame_id = frame_id;
            if (pcm_data.get_size() != 480 * 2) {
                audio_message_frame_size_valid = false;
            }
        });
        audio_message_recorder.duration_changed.connect((seconds) => {
            audio_message_last_duration = seconds;
        });
        audio_message_recorder.level_changed.connect((peak) => {
            audio_message_last_level = peak;
        });
        audio_message_recorder.start();
        iterate_default_context();
        assert_int_eq(audio_message_started_count, 1, "audio message v2 started callback count");
        assert_true(
            audio_message_recorder.state == Native.MediaRecorderState.RECORDING,
            "audio message v2 should enter recording state");
        assert_true(audio_message_recorder.frame_callback_count == 1, "audio message v2 first frame callback count");
        assert_true(audio_message_frame_signal_count == 1, "audio message v2 first frame signal count");
        assert_true(audio_message_frame_size_valid, "audio message v2 frame size");
        assert_true(audio_message_recorder.pcm_frame_count == 480, "audio message v2 first PCM frame count");
        assert_true(audio_message_recorder.pcm_sample_count == 480, "audio message v2 first PCM sample count");
        assert_true(audio_message_recorder.sample_rate == AudioMessageRecorderV2.EXPECTED_SAMPLE_RATE, "audio message v2 sample rate");
        assert_true(audio_message_recorder.channels == AudioMessageRecorderV2.EXPECTED_CHANNELS, "audio message v2 channel count");
        assert_true(audio_message_recorder.bytes_per_sample == AudioMessageRecorderV2.EXPECTED_BYTES_PER_SAMPLE, "audio message v2 bytes per sample");
        assert_true(audio_message_recorder.last_frame_id == 1, "audio message v2 first frame id property");
        assert_true(audio_message_last_frame_id == 1, "audio message v2 first frame id signal");
        assert_true(audio_message_last_duration > 0.009 && audio_message_last_duration < 0.011, "audio message v2 first duration");
        assert_true(audio_message_last_level > 0.55 && audio_message_last_level < 0.56, "audio message v2 first visual level");
        audio_message_recorder.push_synthetic_frame();
        iterate_default_context();
        assert_true(audio_message_recorder.frame_callback_count == 2, "audio message v2 second frame callback count");
        assert_true(audio_message_frame_signal_count == 2, "audio message v2 second frame signal count");
        assert_true(audio_message_recorder.pcm_frame_count == 960, "audio message v2 second PCM frame count");
        assert_true(audio_message_recorder.pcm_sample_count == 960, "audio message v2 second PCM sample count");
        assert_true(audio_message_recorder.last_frame_id == 2, "audio message v2 second frame id property");
        assert_true(audio_message_last_frame_id == 2, "audio message v2 second frame id signal");
        assert_true(audio_message_recorder.duration_seconds > 0.019 && audio_message_recorder.duration_seconds < 0.021, "audio message v2 second duration property");
        assert_true(audio_message_last_duration > 0.019 && audio_message_last_duration < 0.021, "audio message v2 second duration signal");
        audio_message_recorder.stop();
        iterate_default_context();
        assert_int_eq(audio_message_stopped_count, 1, "audio message v2 stopped callback count");
        assert_true(
            audio_message_recorder.state == Native.MediaRecorderState.IDLE,
            "audio message v2 should return idle after stop");
        audio_message_recorder.cancel();

        AudioMessageWriter default_writer = AudioMessageWriterFactory.create_default_aac_m4a_writer();
#if WINDOWS
        assert_true(
            default_writer.available,
            "Windows default AAC/M4A writer must use Media Foundation");
#endif
        if (default_writer.available) {
            string ffmpeg_writer_path = test_tmp_path("dinox-google-webrtc-audio-message-v2-ffmpeg-smoke.m4a");
            FileUtils.remove(ffmpeg_writer_path);
            var ffmpeg_backed_audio_recorder = new AudioMessageRecorderV2.with_writer(
                (!) recorder_context,
                ffmpeg_writer_path,
                default_writer);
            ffmpeg_backed_audio_recorder.start();
            iterate_default_context();
            assert_true(
                ffmpeg_backed_audio_recorder.file_writer_state == AudioMessageWriterState.STARTED,
                "default AAC/M4A writer should be started when available");
            ffmpeg_backed_audio_recorder.push_synthetic_frame();
            iterate_default_context();
            ffmpeg_backed_audio_recorder.stop();
            iterate_default_context();
            assert_true(
                ffmpeg_backed_audio_recorder.file_writer_state == AudioMessageWriterState.FINALIZED,
                "default AAC/M4A writer should finalize when available");
            File output_file = File.new_for_path(ffmpeg_writer_path);
            FileInfo output_info = output_file.query_info(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            assert_true(output_info.get_size() > 0, "default AAC/M4A writer should create a non-empty file");
            ffmpeg_backed_audio_recorder.cancel();
        } else {
            assert_true(
                default_writer.unavailable_reason != null && ((!) default_writer.unavailable_reason) != "",
                "default AAC/M4A writer should explain unavailability");
            try {
                default_writer.start(new AudioMessageWriterConfig(test_tmp_path("dinox-google-webrtc-unavailable.m4a")));
                throw new IOError.FAILED("unavailable writer unexpectedly started");
            } catch (AudioMessageWriterError e) {
                assert_true(e is AudioMessageWriterError.UNAVAILABLE, "default writer must fail as unavailable");
            }
        }

        var provider_context = new EngineContext();
        var recorder_provider = new GoogleWebrtcMediaMessageRecorderProvider.for_context(provider_context);
        assert_str_eq(recorder_provider.id, "google-libwebrtc", "media recorder provider id");
#if WINDOWS
        assert_true(
            recorder_provider.video_available,
            "Windows media recorder provider must expose the Media Foundation video writer");
        assert_true(
            recorder_provider.video_unavailable_reason == null,
            "Windows media recorder provider must not require system ffmpeg");
#endif
        if (recorder_provider.audio_available) {
            string provider_output_path = test_tmp_path("dinox-google-webrtc-audio-message-provider-smoke.m4a");
            FileUtils.remove(provider_output_path);
            Dino.Plugins.AudioMessageRecorderSession provider_session =
                recorder_provider.create_audio_message_recorder(provider_output_path);
            int provider_started_count = 0;
            int provider_stopped_count = 0;
            double provider_last_duration = 0.0;
            double provider_last_level = 0.0;
            Dino.Plugins.MediaMessageRecorderOutput? provider_output = null;
            bool provider_stop_kept_context_active = false;
            provider_session.started.connect(() => {
                provider_started_count++;
            });
            provider_session.duration_changed.connect((seconds) => {
                provider_last_duration = seconds;
            });
            provider_session.level_changed.connect((peak) => {
                provider_last_level = peak;
            });
            provider_session.recording_stopped.connect((output) => {
                provider_stopped_count++;
                provider_output = output;
                provider_stop_kept_context_active =
                    provider_context.active_non_call_activity_count > 0;
            });
            provider_session.start();
            iterate_default_context();
            assert_int_eq(provider_started_count, 1, "media recorder provider session started callback count");
            assert_true(
                provider_session.state == Dino.Plugins.MediaMessageRecorderState.RECORDING,
                "media recorder provider session should be recording");
            assert_true(provider_last_duration > 0.009, "media recorder provider session duration");
            assert_true(provider_last_level < 0.01,
                "media recorder provider session initial level should be muted during startup");
            provider_session.stop();
            iterate_default_context();
            assert_int_eq(provider_stopped_count, 1, "media recorder provider session stopped callback count");
            assert_true(
                provider_stop_kept_context_active,
                "media recorder provider must retain its context through recording_stopped consumers");
            assert_int_eq(
                (int) provider_context.active_non_call_activity_count,
                0,
                "media recorder provider should release its context after recording_stopped consumers");
            assert_true(provider_output != null, "media recorder provider output should be emitted");
            assert_true(((!) provider_output).kind == Dino.Plugins.MediaMessageKind.AUDIO, "media recorder provider output kind");
            assert_str_eq(((!) provider_output).path, provider_output_path, "media recorder provider output path");
            assert_str_eq(((!) provider_output).mime_type, AudioMessageRecorderV2.MIME_TYPE, "media recorder provider output MIME type");
            assert_str_eq(((!) provider_output).suggested_filename, Path.get_basename(provider_output_path), "media recorder provider output suggested filename");
            File provider_output_file = File.new_for_path(provider_output_path);
            FileInfo provider_output_info = provider_output_file.query_info(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            assert_true(provider_output_info.get_size() > 0, "media recorder provider should create a non-empty file");
            provider_session.cancel();
        } else {
            assert_true(
                recorder_provider.audio_unavailable_reason != null &&
                    ((!) recorder_provider.audio_unavailable_reason) != "",
                "media recorder provider should explain unavailable audio backend");
            try {
                recorder_provider.create_audio_message_recorder(test_tmp_path("dinox-google-webrtc-provider-unavailable.m4a"));
                throw new IOError.FAILED("unavailable media recorder provider unexpectedly created a session");
            } catch (Dino.Plugins.MediaMessageRecorderError e) {
                assert_true(
                    e is Dino.Plugins.MediaMessageRecorderError.ENCODER_UNAVAILABLE,
                    "media recorder provider should fail with encoder-unavailable");
            }
        }

        var playback_provider = new GoogleWebrtcMediaMessagePlaybackProvider(
            () => { return provider_context; },
            () => { return "DinoX synthetic speaker"; });
        int playback_provider_failure_count = 0;
        playback_provider.playback_failed.connect((message) => {
            playback_provider_failure_count++;
        });
        assert_str_eq(playback_provider.id, "google-libwebrtc", "media playback provider id");
        assert_true(playback_provider.available, "media playback provider should be available");
        Gee.List<Dino.Plugins.MediaDevice> playback_speakers =
            playback_provider.get_audio_output_devices();
        assert_int_eq(playback_speakers.size, 1, "media playback speaker count");
        assert_str_eq(
            playback_speakers[0].display_name,
            "DinoX synthetic speaker",
            "media playback speaker name");

        uint8[] provider_playback_pcm = new uint8[960 * 2];
        Dino.Plugins.MediaMessagePlaybackSession playback_session =
            playback_provider.create_audio_playback_session();
        assert_int_eq(
            (int) provider_context.active_non_call_activity_count,
            1,
            "media playback session should retain the engine context");
        playback_session.start(48000, 1, 2);
        assert_true(playback_session.active, "media playback session should be active");
        uint provider_queued_ms = playback_session.push_pcm(new Bytes(provider_playback_pcm));
        assert_true(
            provider_queued_ms > 0 && provider_queued_ms <= 20,
            "media playback provider queue duration");
        playback_session.set_paused(true);
        playback_session.flush();
        playback_session.set_paused(false);
        playback_session.push_pcm(new Bytes(provider_playback_pcm));
        assert_true(playback_session.finish() <= 20, "media playback provider finish duration");

        Dino.Plugins.MediaMessagePlaybackSession replacement_playback_session =
            playback_provider.create_audio_playback_session();
        assert_true(
            !playback_session.active,
            "a new media playback session should stop the previous session");
        try {
            playback_session.push_pcm(new Bytes(provider_playback_pcm));
            throw new IOError.FAILED("stale media playback session unexpectedly accepted PCM");
        } catch (EngineError e) {
            assert_true(e is EngineError.CLOSED, "stale media playback should fail as closed");
        } catch (Error e) {
            assert_true(false, "stale media playback failed with the wrong error");
        }
        assert_int_eq(
            playback_provider_failure_count,
            0,
            "stale session rejection must not mark a healthy worker as failed");
        replacement_playback_session.start(48000, 1, 2);
        replacement_playback_session.stop();
        replacement_playback_session.stop();
        assert_int_eq(
            (int) provider_context.active_non_call_activity_count,
            0,
            "media playback session should release the engine context once");

        string provider_test_path = test_tmp_path("dinox-google-webrtc-audio-device-test.raw");
        FileUtils.remove(provider_test_path);
        Dino.Plugins.AudioMessageRecorderSession provider_test_session =
            recorder_provider.create_audio_test_for_device(provider_test_path, null);
        int provider_test_pcm_count = 0;
        int provider_test_sample_rate = 0;
        bool provider_test_pcm_valid = true;
        provider_test_session.pcm_frame.connect((pcm_data, sample_rate, channels, bytes_per_sample) => {
            provider_test_pcm_count++;
            provider_test_sample_rate = sample_rate;
            if (pcm_data.get_size() == 0 || channels != 1 || bytes_per_sample != 2) {
                provider_test_pcm_valid = false;
            }
        });
        provider_test_session.start();
        iterate_default_context();
        provider_test_session.stop();
        iterate_default_context();
        assert_true(provider_test_pcm_count > 0, "audio device test should emit PCM frames");
        assert_true(provider_test_pcm_valid, "audio device test PCM format");
        assert_int_eq(provider_test_sample_rate, 48000, "audio device test PCM sample rate");
        assert_true(!FileUtils.test(provider_test_path, FileTest.EXISTS), "audio device test must not create a media file");
        provider_test_session.cancel();
        provider_context.close();

        run_optional_platform_audio_recorder_smoke();
        run_optional_platform_audio_provider_smoke();
        run_optional_platform_video_recorder_smoke();
        run_optional_platform_video_provider_smoke();
        run_optional_platform_device_test_smoke();
        run_optional_platform_lifecycle_stress();

        var counting_writer = new CountingAudioMessageWriter();
        string counting_audio_path = test_tmp_path("dinox-google-webrtc-audio-message-v2-writer-smoke.m4a");
        var writer_backed_audio_recorder = new AudioMessageRecorderV2.with_writer(
            (!) recorder_context,
            counting_audio_path,
            counting_writer);
        assert_true(writer_backed_audio_recorder.file_writer_enabled, "audio message v2 writer should be enabled");
        writer_backed_audio_recorder.start();
        iterate_default_context();
        assert_int_eq(counting_writer.start_count, 1, "audio message v2 writer start count");
        assert_str_eq(counting_writer.output_path, counting_audio_path, "audio message v2 writer output path");
        assert_str_eq(counting_writer.mime_type, AudioMessageRecorderV2.MIME_TYPE, "audio message v2 writer MIME type");
        assert_str_eq(counting_writer.codec, "aac-lc", "audio message v2 writer codec");
        assert_int_eq(counting_writer.bitrate_bps, 64000, "audio message v2 writer bitrate");
        assert_true(counting_writer.state == AudioMessageWriterState.STARTED, "audio message v2 writer should be started");
        assert_true(writer_backed_audio_recorder.file_writer_state == AudioMessageWriterState.STARTED, "audio message v2 should expose writer state");
        assert_true(counting_writer.write_count == 1, "audio message v2 writer first write count");
        assert_true(counting_writer.pcm_frame_count == 480, "audio message v2 writer first PCM frame count");
        assert_true(counting_writer.pcm_sample_count == 480, "audio message v2 writer first PCM sample count");
        assert_true(counting_writer.last_frame_id == 1, "audio message v2 writer first frame id");
        writer_backed_audio_recorder.push_synthetic_frame();
        iterate_default_context();
        assert_true(counting_writer.write_count == 2, "audio message v2 writer second write count");
        assert_true(counting_writer.pcm_frame_count == 960, "audio message v2 writer second PCM frame count");
        assert_true(counting_writer.pcm_sample_count == 960, "audio message v2 writer second PCM sample count");
        assert_true(counting_writer.last_frame_id == 2, "audio message v2 writer second frame id");
        writer_backed_audio_recorder.stop();
        iterate_default_context();
        assert_int_eq(counting_writer.finish_count, 1, "audio message v2 writer finish count");
        assert_true(counting_writer.state == AudioMessageWriterState.FINALIZED, "audio message v2 writer should be finalized");
        assert_true(writer_backed_audio_recorder.file_writer_state == AudioMessageWriterState.FINALIZED, "audio message v2 should expose finalized writer state");
        writer_backed_audio_recorder.cancel();

        var finalize_race_writer = new CountingAudioMessageWriter();
        var finalize_race_recorder = new AudioMessageRecorderV2.with_writer(
            (!) recorder_context,
            test_tmp_path("dinox-google-webrtc-audio-message-finalize-race.m4a"),
            finalize_race_writer);
        int finalize_race_error_count = 0;
        finalize_race_recorder.recording_error.connect((message) => {
            finalize_race_error_count++;
        });
        finalize_race_recorder.start();
        assert_true(
            wait_for_condition(() => finalize_race_writer.write_count >= 1),
            "audio finalize race should receive an initial PCM frame");
        uint64 finalized_write_count = finalize_race_writer.write_count;
        // Queue one more worker frame without dispatching its GTK-main-context
        // callback, then finalize immediately. A late PCM callback must not
        // write to or invalidate the already finalized message file.
        finalize_race_recorder.push_synthetic_frame();
        finalize_race_recorder.stop();
        run_default_context_for_ms(100);
        assert_int_eq(finalize_race_error_count, 0, "audio finalize race late PCM error count");
        assert_true(
            finalize_race_writer.write_count == finalized_write_count,
            "audio finalize race should discard queued PCM after stop");
        assert_true(
            finalize_race_writer.state == AudioMessageWriterState.FINALIZED,
            "audio finalize race writer should remain finalized");
        finalize_race_recorder.cancel();

        VideoMessageWriter default_video_writer = VideoMessageWriterFactory.create_default_mp4_h264_writer();
#if WINDOWS
        assert_true(
            default_video_writer.available,
            "Windows default MP4/H.264 writer must use Media Foundation");
#endif
        if (default_video_writer.available) {
            string ffmpeg_video_writer_path = test_tmp_path("dinox-google-webrtc-video-message-v2-ffmpeg-smoke.mp4");
            FileUtils.remove(ffmpeg_video_writer_path);
            var ffmpeg_backed_video_recorder = new VideoMessageRecorderV2.with_writer(
                (!) recorder_context,
                ffmpeg_video_writer_path,
                default_video_writer,
                160,
                90,
                15);
            ffmpeg_backed_video_recorder.start();
            iterate_default_context();
            assert_true(
                ffmpeg_backed_video_recorder.file_writer_state == VideoMessageWriterState.STARTED,
                "default MP4/H.264 writer should be started when available");
            for (int i = 0; i < 4; i++) {
                ffmpeg_backed_video_recorder.push_synthetic_frame();
                iterate_default_context();
            }
            ffmpeg_backed_video_recorder.stop();
            iterate_default_context();
            assert_true(
                ffmpeg_backed_video_recorder.file_writer_state == VideoMessageWriterState.FINALIZED,
                "default MP4/H.264 writer should finalize when available");
            File output_file = File.new_for_path(ffmpeg_video_writer_path);
            FileInfo output_info = output_file.query_info(
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE);
            assert_true(output_info.get_size() > 0, "default MP4/H.264 writer should create a non-empty file");
            ffmpeg_backed_video_recorder.cancel();
        } else {
            assert_true(
                default_video_writer.unavailable_reason != null && ((!) default_video_writer.unavailable_reason) != "",
                "default MP4/H.264 video writer should explain unavailability");
            try {
                default_video_writer.start(new VideoMessageWriterConfig(test_tmp_path("dinox-google-webrtc-unavailable.mp4")));
                throw new IOError.FAILED("unavailable video writer unexpectedly started");
            } catch (VideoMessageWriterError e) {
                assert_true(e is VideoMessageWriterError.UNAVAILABLE, "default video writer must fail as unavailable");
            }
        }

        var counting_video_writer = new CountingVideoMessageWriter();
        string counting_video_path = test_tmp_path("dinox-google-webrtc-video-message-v2-writer-smoke.mp4");
        var writer_backed_video_recorder = new VideoMessageRecorderV2.with_writer(
            (!) recorder_context,
            counting_video_path,
            counting_video_writer,
            160,
            90,
            15);
        assert_true(writer_backed_video_recorder.file_writer_enabled, "video message v2 writer should be enabled");
        writer_backed_video_recorder.start();
        iterate_default_context();
        assert_int_eq(counting_video_writer.start_count, 1, "video message v2 writer start count");
        assert_str_eq(counting_video_writer.output_path, counting_video_path, "video message v2 writer output path");
        assert_str_eq(counting_video_writer.mime_type, VideoMessageRecorderV2.MIME_TYPE, "video message v2 writer MIME type");
        assert_str_eq(counting_video_writer.video_codec, VideoMessageRecorderV2.VIDEO_CODEC, "video message v2 writer video codec");
        assert_str_eq(counting_video_writer.audio_codec, VideoMessageRecorderV2.AUDIO_CODEC, "video message v2 writer audio codec");
        assert_int_eq(counting_video_writer.width, 160, "video message v2 writer width");
        assert_int_eq(counting_video_writer.height, 90, "video message v2 writer height");
        assert_int_eq(counting_video_writer.max_fps, 15, "video message v2 writer max fps");
        assert_int_eq(counting_video_writer.video_bitrate_bps, VideoMessageWriterConfig.DEFAULT_VIDEO_BITRATE_BPS, "video message v2 writer bitrate");
        assert_true(counting_video_writer.state == VideoMessageWriterState.STARTED, "video message v2 writer should be started");
        assert_true(writer_backed_video_recorder.file_writer_state == VideoMessageWriterState.STARTED, "video message v2 should expose writer state");
        assert_true(counting_video_writer.write_count == 1, "video message v2 writer first write count");
        assert_true(counting_video_writer.last_frame_id == 1, "video message v2 writer first frame id");
        assert_true(counting_video_writer.last_byte_count == 160 * 90 * 4, "video message v2 writer first byte count");
        writer_backed_video_recorder.push_synthetic_frame();
        iterate_default_context();
        assert_true(counting_video_writer.write_count == 2, "video message v2 writer second write count");
        assert_true(counting_video_writer.last_frame_id == 2, "video message v2 writer second frame id");
        writer_backed_video_recorder.stop();
        iterate_default_context();
        assert_int_eq(counting_video_writer.finish_count, 1, "video message v2 writer finish count");
        assert_true(counting_video_writer.state == VideoMessageWriterState.FINALIZED, "video message v2 writer should be finalized");
        assert_true(writer_backed_video_recorder.file_writer_state == VideoMessageWriterState.FINALIZED, "video message v2 should expose finalized writer state");
        writer_backed_video_recorder.cancel();

        var video_finalize_race_writer = new CountingVideoMessageWriter();
        var video_finalize_race_recorder = new VideoMessageRecorderV2.with_writer(
            (!) recorder_context,
            test_tmp_path("dinox-google-webrtc-video-message-finalize-race.mp4"),
            video_finalize_race_writer,
            160,
            90,
            15);
        int video_finalize_race_error_count = 0;
        video_finalize_race_recorder.recording_error.connect((message) => {
            video_finalize_race_error_count++;
        });
        video_finalize_race_recorder.start();
        assert_true(
            wait_for_condition(() => video_finalize_race_writer.write_count >= 1),
            "video finalize race should receive an initial BGRA frame");
        uint64 finalized_video_write_count = video_finalize_race_writer.write_count;
        video_finalize_race_recorder.push_synthetic_frame();
        video_finalize_race_recorder.stop();
        run_default_context_for_ms(100);
        assert_int_eq(video_finalize_race_error_count, 0, "video finalize race late BGRA error count");
        assert_true(
            video_finalize_race_writer.write_count == finalized_video_write_count,
            "video finalize race should discard queued BGRA after stop");
        assert_true(
            video_finalize_race_writer.state == VideoMessageWriterState.FINALIZED,
            "video finalize race writer should remain finalized");
        video_finalize_race_recorder.cancel();

        var external_services = new ArrayList<ExternalServiceDiscovery.Service>();
        external_services.add(make_external_service("stun", "stun.example.test", 3478, "udp"));
        external_services.add(make_external_service("turn", "turn.example.test", 3478, "udp", "turn-user", "turn-pass"));
        external_services.add(make_external_service("turns", "2001:db8::1", 5349, "tcp", "turns-user", "turns-pass"));
        external_services.add(make_external_service("turn", "missing-credentials.example.test", 3478, "udp"));
        external_services.add(make_external_service("stuns", "invalid-udp-tls.example.test", 5349, "udp"));
        external_services.add(make_external_service("turn", "turn.example.test", 3478, "udp", "turn-user", "turn-pass"));
        Gee.List<EngineIceServer> mapped_ice_servers = EngineIceServer.from_external_services(external_services);
        assert_int_eq(mapped_ice_servers.size, 3, "mapped ICE server count");
        assert_str_eq(mapped_ice_servers[0].url, "stun:stun.example.test:3478", "mapped STUN URL");
        assert_str_eq(mapped_ice_servers[1].url, "turn:turn.example.test:3478?transport=udp", "mapped TURN URL");
        assert_str_eq(mapped_ice_servers[1].username, "turn-user", "mapped TURN username");
        assert_str_eq(mapped_ice_servers[2].url, "turns:[2001:db8::1]:5349?transport=tcp", "mapped TURNS IPv6 URL");

        Gee.List<EngineAudioDeviceInfo> microphones = ((!) context).get_audio_devices(false);
        Gee.List<EngineAudioDeviceInfo> speakers = ((!) context).get_audio_devices(true);
        Gee.List<EngineVideoDeviceInfo> cameras = ((!) context).get_video_devices();
        assert_int_eq(microphones.size, 1, "synthetic microphone count");
        assert_int_eq(speakers.size, 1, "synthetic speaker count");
        assert_str_eq(microphones[0].display_name, "DinoX synthetic microphone", "synthetic microphone name");
        assert_str_eq(speakers[0].display_name, "DinoX synthetic speaker", "synthetic speaker name");
        assert_true(!microphones[0].incoming, "synthetic microphone should be outgoing/capture");
        assert_true(speakers[0].incoming, "synthetic speaker should be incoming/playout");
        assert_true(cameras.size >= 0, "camera enumeration should return a non-negative count");
        if (cameras.size > 0) {
            assert_true(cameras[0].display_name != "", "first camera should have a display name");
            assert_true(cameras[0].unique_id != "", "first camera should have a unique id");
            assert_true(cameras[0].id.has_prefix("video:"), "camera id should be video-scoped");
        }
        ((!) context).set_audio_device(microphones[0]);
        ((!) context).set_audio_device(speakers[0]);
        ((!) context).play_test_tone('5', 120);
        ((!) context).set_audio_device(speakers[0]);
        uint8[] audio_test_pcm = new uint8[960 * 2];
        for (int index = 0; index < 960; index++) {
            int sample = (index % 48) < 24 ? 8000 : -8000;
            audio_test_pcm[index * 2] = (uint8) (sample & 0xff);
            audio_test_pcm[index * 2 + 1] = (uint8) ((sample >> 8) & 0xff);
        }
        uint audio_test_duration_ms = ((!) context).play_audio_test_clip(
            new Bytes(audio_test_pcm), 48000, 1, 2);
        assert_int_eq((int) audio_test_duration_ms, 20, "audio test clip duration");
        ((!) context).stop_audio_test_playout();

        ((!) context).start_media_audio_playout(48000, 1, 2);
        uint media_audio_queued_ms = ((!) context).push_media_audio_playout(
            new Bytes(audio_test_pcm));
        assert_true(
            media_audio_queued_ms > 0 && media_audio_queued_ms <= 20,
            "media audio playout should report a bounded worker queue");
        ((!) context).set_media_audio_playout_paused(true);
        ((!) context).flush_media_audio_playout();
        ((!) context).set_media_audio_playout_paused(false);
        ((!) context).push_media_audio_playout(new Bytes(audio_test_pcm));
        media_audio_queued_ms = ((!) context).finish_media_audio_playout();
        assert_true(media_audio_queued_ms <= 20, "media audio finish queue duration");
        ((!) context).stop_media_audio_playout();
        ((!) context).stop_media_audio_playout();

        var ice_config = new EngineSessionConfig();
        ice_config.add_ice_server(new EngineIceServer("stun:stun.example.test:3478"));
        EngineSessionOwner ice_config_session = ((!) context).create_session(ice_config);
        Native.SessionState ice_config_state = ice_config_session.get_state();
        assert_int_eq(ice_config_state.ice_server_count, 1, "configured native ICE server count");
        ice_config_session.close();

        offer_session = ((!) context).create_session();
        answer_session = ((!) context).create_session();
        Native.SessionState offer_initial_state = ((!) offer_session).get_state();
        assert_int_eq(offer_initial_state.local_video_capture_running, 0, "initial local video capture running");
        assert_int_eq((int) offer_initial_state.local_video_capture_frame_count, 0, "initial local video capture frames");
        ((!) offer_session).set_local_video_enabled(false);
        Native.SessionState offer_video_disabled_state = ((!) offer_session).get_state();
        assert_int_eq(offer_video_disabled_state.local_video_track_enabled, 0, "local video disabled state");
        ((!) offer_session).set_local_video_enabled(true);
        Native.SessionState offer_video_enabled_state = ((!) offer_session).get_state();
        assert_int_eq(offer_video_enabled_state.local_video_track_enabled, 1, "local video re-enabled state");
        wait_for_local_video_frame((!) offer_session, "offer local video preview frame");

        var offer_candidates = new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
        var answer_candidates = new ArrayList<JingleRtp.LibwebrtcJingleIceCandidate>();
        int next_offer_candidate = 0;
        int next_answer_candidate = 0;
        ulong offer_ice_handler = ((!) offer_session).local_ice_candidate.connect((candidate) => {
            offer_candidates.add(candidate);
        });
        ulong answer_ice_handler = ((!) answer_session).local_ice_candidate.connect((candidate) => {
            answer_candidates.add(candidate);
        });

        ((!) offer_session).create_offer();
        JingleRtp.LibwebrtcJingleDescription offer =
            wait_for_local_description((!) offer_session, "local offer");
        assert_true(((!) offer_session).has_local_content_map, "offer session should know local content map");
        assert_true(offer.sdp_type == JingleRtp.LibwebrtcSdpType.OFFER, "local description should be an offer");
        assert_int_eq(offer.contents.size, 2, "offer should contain audio and video");
        assert_str_eq(offer.contents[0].description.get_attribute("media"), "audio", "first offer content should be audio");
        assert_str_eq(offer.contents[1].description.get_attribute("media"), "video", "second offer content should be video");

        JingleRtp.LibwebrtcJingleDescription remote_offer =
            ((!) answer_session).set_remote_description_from_jingle(
                JingleRtp.LibwebrtcSdpType.OFFER,
                offer.contents,
                Jingle.Role.RESPONDER,
                JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
        assert_true(((!) answer_session).has_remote_content_map, "answer session should know remote content map");
        assert_true(remote_offer.sdp.contains("a=group:BUNDLE"), "remote offer SDP should preserve BUNDLE");
        wait_for_remote_description_set(
            (!) answer_session,
            JingleRtp.LibwebrtcSdpType.OFFER,
            "remote offer set");

        ((!) answer_session).create_answer();
        JingleRtp.LibwebrtcJingleDescription answer =
            wait_for_local_description((!) answer_session, "local answer");
        assert_true(answer.sdp_type == JingleRtp.LibwebrtcSdpType.ANSWER, "local description should be an answer");
        assert_int_eq(answer.contents.size, 2, "answer should contain audio and video");

        ((!) offer_session).set_remote_description_from_jingle(
            JingleRtp.LibwebrtcSdpType.ANSWER,
            answer.contents,
            Jingle.Role.INITIATOR,
            JingleRtp.SdpBundlePolicy.ALL_MEDIA_SECTIONS);
        wait_for_remote_description_set(
            (!) offer_session,
            JingleRtp.LibwebrtcSdpType.ANSWER,
            "remote answer set");

        wait_for_remote_video_frame(
            (!) offer_session,
            (!) answer_session,
            offer_candidates,
            answer_candidates,
            ref next_offer_candidate,
            ref next_answer_candidate,
            "offer-to-answer remote video frame");

        ((!) offer_session).disconnect(offer_ice_handler);
        ((!) answer_session).disconnect(answer_ice_handler);
        ((!) answer_session).close();
        ((!) offer_session).close();
        ((!) context).close();
        return 0;
    } catch (Error e) {
        printerr("google-webrtc-engine-smoke failed: %s\n", e.message);
        if (answer_session != null) ((!) answer_session).close();
        if (offer_session != null) ((!) offer_session).close();
        if (context != null) ((!) context).close();
        return 1;
    }
}

}

public int main(string[] args) {
    return Dino.Plugins.GoogleWebrtc.Test.run_smoke();
}
