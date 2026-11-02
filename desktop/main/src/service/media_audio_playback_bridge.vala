using Gst;

namespace Dino.Ui {

/**
 * Bridges decoded media-file PCM to the selected Google/libwebrtc speaker.
 *
 * GStreamer owns demuxing/decoding only. This class deliberately exposes an
 * appsink bin, never an operating-system audio sink.
 */
public class MediaAudioPlaybackBridge : GLib.Object {
    public const int SAMPLE_RATE = 48000;
    public const int CHANNELS = 2;
    public const int BYTES_PER_SAMPLE = 2;

    private const uint PCM_BATCH_BYTES = 7680; // 40 ms, stereo S16LE at 48 kHz

    public signal void playback_error(string message);

    private Dino.Plugins.MediaMessagePlaybackSession? session = null;
    private Gst.App.Sink? app_sink = null;
    private ulong new_sample_handler_id = 0;
    private ByteArray pending_pcm = new ByteArray();
    private uint pending_pcm_bytes = 0;
    private Mutex state_mutex = Mutex();
    private Mutex operation_mutex = Mutex();
    private bool finishing = false;
    private bool stopped = false;
    private bool error_reported = false;

    public MediaAudioPlaybackBridge(
            Dino.Plugins.MediaMessagePlaybackProvider provider,
            double playback_rate = 1.0) throws Error {
        if (!provider.available) {
            throw new IOError.NOT_SUPPORTED(
                provider.unavailable_reason ?? "Google/libwebrtc media playback is not available");
        }
        if (playback_rate < 1.0 || playback_rate > 2.0) {
            throw new IOError.INVALID_ARGUMENT("Unsupported media audio playback rate");
        }
        // GStreamer keeps decoded PCM at 48 kHz but schedules accelerated
        // segments faster. The logical source rate makes libwebrtc consume the
        // same PCM at the selected speed instead of accumulating a stale queue.
        int logical_sample_rate = (int) Math.round(SAMPLE_RATE * playback_rate);
        Dino.Plugins.MediaMessagePlaybackSession created_session =
            provider.create_audio_playback_session();
        try {
            created_session.start(logical_sample_rate, CHANNELS, BYTES_PER_SAMPLE);
        } catch (Error e) {
            created_session.stop();
            throw e;
        }
        created_session.playback_error.connect(report_error);
        session = created_session;
    }

    public Gst.Element create_sink_bin() throws Error {
        var convert = ElementFactory.make("audioconvert", "media-playback-convert");
        var resample = ElementFactory.make("audioresample", "media-playback-resample");
        var caps_filter = ElementFactory.make("capsfilter", "media-playback-caps");
        var sink = ElementFactory.make("appsink", "media-playback-appsink") as Gst.App.Sink;
        if (convert == null || resample == null || caps_filter == null || sink == null) {
            throw new IOError.NOT_SUPPORTED("Required media audio decoder bridge elements are unavailable");
        }

        caps_filter.set(
            "caps",
            Caps.from_string(
                "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=2"));
        sink.emit_signals = true;
        sink.sync = true;
        sink.max_buffers = 16;
        sink.drop = false;
        new_sample_handler_id = sink.new_sample.connect(on_new_sample);
        app_sink = sink;

        var bin = new Gst.Bin("media-audio-playback-bin");
        bin.add_many(convert, resample, caps_filter, sink);
        if (!convert.link(resample) ||
                !resample.link(caps_filter) ||
                !caps_filter.link(sink)) {
            throw new IOError.FAILED("Could not link media audio decoder bridge");
        }
        var convert_sink_pad = convert.get_static_pad("sink");
        if (convert_sink_pad == null ||
                !bin.add_pad(new Gst.GhostPad("sink", (!) convert_sink_pad))) {
            throw new IOError.FAILED("Could not expose media audio decoder bridge sink pad");
        }
        return bin;
    }

    public void set_paused(bool paused) throws Error {
        operation_mutex.lock();
        try {
            if (is_stopped()) return;
            require_session().set_paused(paused);
        } finally {
            operation_mutex.unlock();
        }
    }

    public void flush() throws Error {
        operation_mutex.lock();
        try {
            if (is_stopped()) return;
            clear_pending_pcm();
            require_session().flush();
        } finally {
            operation_mutex.unlock();
        }
    }

    /** Returns the remaining worker queue duration after the final PCM batch. */
    public uint finish() throws Error {
        operation_mutex.lock();
        try {
            if (is_stopped()) return 0;
            state_mutex.lock();
            finishing = true;
            Bytes? final_batch = take_pending_pcm_locked();
            state_mutex.unlock();
            if (final_batch != null) push_batch((!) final_batch);
            return require_session().finish();
        } finally {
            operation_mutex.unlock();
        }
    }

    public void stop() {
        operation_mutex.lock();
        try {
            state_mutex.lock();
            if (stopped) {
                state_mutex.unlock();
                return;
            }
            stopped = true;
            finishing = false;
            pending_pcm = new ByteArray();
            pending_pcm_bytes = 0;
            state_mutex.unlock();

            if (app_sink != null && new_sample_handler_id != 0 &&
                    SignalHandler.is_connected((!) app_sink, new_sample_handler_id)) {
                SignalHandler.disconnect((!) app_sink, new_sample_handler_id);
            }
            new_sample_handler_id = 0;
            app_sink = null;
            Dino.Plugins.MediaMessagePlaybackSession? current_session = session;
            session = null;
            if (current_session != null) ((!) current_session).stop();
        } finally {
            operation_mutex.unlock();
        }
    }

    private Gst.FlowReturn on_new_sample(Gst.App.Sink sink) {
        Gst.Sample? sample = sink.pull_sample();
        if (sample == null) return Gst.FlowReturn.EOS;
        Gst.Buffer? buffer = ((!) sample).get_buffer();
        if (buffer == null) return Gst.FlowReturn.ERROR;

        Gst.MapInfo map_info;
        if (!((!) buffer).map(out map_info, Gst.MapFlags.READ)) {
            report_error("Could not map decoded media PCM");
            return Gst.FlowReturn.ERROR;
        }

        Bytes? batch = null;
        state_mutex.lock();
        if (!stopped && !finishing && map_info.size > 0) {
            pending_pcm.append(map_info.data[0:map_info.size]);
            pending_pcm_bytes += (uint) map_info.size;
            if (pending_pcm_bytes >= PCM_BATCH_BYTES) {
                batch = take_pending_pcm_locked();
            }
        }
        bool should_continue = !stopped && !finishing;
        state_mutex.unlock();
        ((!) buffer).unmap(map_info);

        if (!should_continue) return Gst.FlowReturn.FLUSHING;
        if (batch == null) return Gst.FlowReturn.OK;

        operation_mutex.lock();
        try {
            if (is_stopped()) return Gst.FlowReturn.FLUSHING;
            push_batch((!) batch);
        } catch (Error e) {
            report_error(e.message);
            return Gst.FlowReturn.ERROR;
        } finally {
            operation_mutex.unlock();
        }
        return Gst.FlowReturn.OK;
    }

    private void push_batch(Bytes batch) throws Error {
        const size_t max_chunk_bytes = 262144;
        size_t offset = 0;
        while (offset < batch.get_size()) {
            size_t remaining = batch.get_size() - offset;
            size_t chunk_size = remaining < max_chunk_bytes ? remaining : max_chunk_bytes;
            chunk_size -= chunk_size % (CHANNELS * BYTES_PER_SAMPLE);
            if (chunk_size == 0) {
                throw new IOError.INVALID_DATA("Decoded media PCM is not frame-aligned");
            }
            require_session().push_pcm(new Bytes.from_bytes(batch, offset, chunk_size));
            offset += chunk_size;
        }
    }

    private Bytes? take_pending_pcm_locked() {
        if (pending_pcm_bytes == 0) return null;
        ByteArray batch = (owned) pending_pcm;
        pending_pcm = new ByteArray();
        pending_pcm_bytes = 0;
        return ByteArray.free_to_bytes((owned) batch);
    }

    private void clear_pending_pcm() {
        state_mutex.lock();
        pending_pcm = new ByteArray();
        pending_pcm_bytes = 0;
        state_mutex.unlock();
    }

    private bool is_stopped() {
        state_mutex.lock();
        bool value = stopped;
        state_mutex.unlock();
        return value;
    }

    private Dino.Plugins.MediaMessagePlaybackSession require_session() throws Error {
        if (session == null) {
            throw new IOError.CLOSED("Google/libwebrtc media playback session is closed");
        }
        return (!) session;
    }

    private void report_error(string message) {
        state_mutex.lock();
        if (error_reported) {
            state_mutex.unlock();
            return;
        }
        error_reported = true;
        state_mutex.unlock();
        Idle.add(() => {
            playback_error(message);
            return Source.REMOVE;
        });
    }

    ~MediaAudioPlaybackBridge() {
        stop();
    }
}

}
