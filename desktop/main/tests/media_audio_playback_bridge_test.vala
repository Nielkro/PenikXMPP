namespace Dino.Ui.Test {

private class FakeMediaPlaybackSession : Dino.Plugins.MediaMessagePlaybackSession {
    private Mutex mutex = Mutex();
    private bool running = false;
    public int start_count = 0;
    public int push_count = 0;
    public int pause_count = 0;
    public int flush_count = 0;
    public int finish_count = 0;
    public int stop_count = 0;
    public size_t pushed_bytes = 0;
    public int sample_rate = 0;
    public int channels = 0;
    public int bytes_per_sample = 0;

    public override bool active {
        get {
            mutex.lock();
            bool value = running;
            mutex.unlock();
            return value;
        }
    }

    public override void start(int sample_rate, int channels, int bytes_per_sample) throws Error {
        mutex.lock();
        running = true;
        start_count++;
        this.sample_rate = sample_rate;
        this.channels = channels;
        this.bytes_per_sample = bytes_per_sample;
        mutex.unlock();
    }

    public override uint push_pcm(Bytes pcm_data) throws Error {
        mutex.lock();
        if (!running) {
            mutex.unlock();
            throw new IOError.CLOSED("fake playback is stopped");
        }
        push_count++;
        pushed_bytes += pcm_data.get_size();
        mutex.unlock();
        return 40;
    }

    public override void set_paused(bool paused) throws Error {
        mutex.lock();
        pause_count++;
        mutex.unlock();
    }

    public override void flush() throws Error {
        mutex.lock();
        flush_count++;
        mutex.unlock();
    }

    public override uint finish() throws Error {
        mutex.lock();
        finish_count++;
        mutex.unlock();
        return 40;
    }

    public override void stop() {
        mutex.lock();
        if (running) {
            running = false;
            stop_count++;
        }
        mutex.unlock();
    }
}

private class FakeMediaPlaybackProvider : Object, Dino.Plugins.MediaMessagePlaybackProvider {
    public string id { get { return "fake-playback"; } }
    public bool is_available = true;
    public bool available { get { return is_available; } }
    public string? unavailable_reason {
        owned get { return available ? null : "fake playback unavailable"; }
    }
    public FakeMediaPlaybackSession session = new FakeMediaPlaybackSession();

    public Dino.Plugins.MediaMessagePlaybackSession create_audio_playback_session() throws Error {
        return session;
    }
}

public class MediaAudioPlaybackBridgeTest : Gee.TestCase {
    public MediaAudioPlaybackBridgeTest() {
        base("MediaAudioPlaybackBridge");
        add_test("appsink forwards bounded PCM", test_appsink_forwards_pcm);
        add_test("playback rate configures worker clock", test_playback_rate);
        add_test("unavailable provider fails closed", test_unavailable_provider);
    }

    private void test_appsink_forwards_pcm() {
        var provider = new FakeMediaPlaybackProvider();
        Dino.Ui.MediaAudioPlaybackBridge bridge;
        Gst.Element sink_bin;
        try {
            bridge = new Dino.Ui.MediaAudioPlaybackBridge(provider);
            sink_bin = bridge.create_sink_bin();
        } catch (Error e) {
            GLib.Test.message("Could not create media playback bridge: %s", e.message);
            GLib.Test.fail();
            return;
        }

        assert_true(provider.session.start_count == 1, "playback session should start once");
        assert_true(
            provider.session.sample_rate == Dino.Ui.MediaAudioPlaybackBridge.SAMPLE_RATE &&
            provider.session.channels == Dino.Ui.MediaAudioPlaybackBridge.CHANNELS &&
            provider.session.bytes_per_sample == Dino.Ui.MediaAudioPlaybackBridge.BYTES_PER_SAMPLE,
            "playback session should use the bridge PCM format");

        var pipeline = new Gst.Pipeline("media-audio-playback-bridge-test");
        var app_src = Gst.ElementFactory.make("appsrc", "media-audio-test-src") as Gst.App.Src;
        if (app_src == null) {
            GLib.Test.message("GStreamer appsrc is unavailable");
            GLib.Test.fail();
            bridge.stop();
            return;
        }
        ((!) app_src).caps = Gst.Caps.from_string(
            "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=2");
        ((!) app_src).format = Gst.Format.TIME;
        pipeline.add_many((!) app_src, sink_bin);
        assert_true(((!) app_src).link(sink_bin), "appsrc should link to the appsink bridge");

        uint8[] pcm = new uint8[7680];
        Gst.Buffer buffer = new Gst.Buffer.wrapped_bytes(new Bytes(pcm));
        buffer.pts = 0;
        buffer.duration = 40 * Gst.MSECOND;
        assert_true(
            pipeline.set_state(Gst.State.PLAYING) != Gst.StateChangeReturn.FAILURE,
            "bridge test pipeline should enter PLAYING");
        assert_true(
            ((!) app_src).push_buffer((owned) buffer) == Gst.FlowReturn.OK,
            "bridge test PCM push should succeed");
        ((!) app_src).end_of_stream();

        int64 deadline = GLib.get_monotonic_time() + 2 * GLib.TimeSpan.SECOND;
        while (provider.session.push_count == 0 && GLib.get_monotonic_time() < deadline) {
            while (MainContext.default().iteration(false)) {}
            Thread.usleep(1000);
        }
        assert_true(provider.session.push_count == 1, "bridge should batch one PCM push");
        assert_true(provider.session.pushed_bytes == pcm.length, "bridge should forward all PCM bytes");

        try {
            bridge.set_paused(true);
            bridge.set_paused(false);
            bridge.flush();
            assert_true(bridge.finish() == 40, "bridge should return the worker drain duration");
        } catch (Error e) {
            GLib.Test.message("Bridge lifecycle operation failed: %s", e.message);
            GLib.Test.fail();
        }
        pipeline.set_state(Gst.State.NULL);
        bridge.stop();
        bridge.stop();
        assert_true(provider.session.pause_count == 2, "bridge should forward pause and resume");
        assert_true(provider.session.flush_count == 1, "bridge should forward flush");
        assert_true(provider.session.finish_count == 1, "bridge should finish once");
        assert_true(provider.session.stop_count == 1, "bridge stop should be idempotent");
    }

    private void test_playback_rate() {
        var provider = new FakeMediaPlaybackProvider();
        try {
            var bridge = new Dino.Ui.MediaAudioPlaybackBridge(provider, 1.5);
            assert_true(
                provider.session.sample_rate == 72000,
                "accelerated playback should use a matching worker source clock");
            bridge.stop();
        } catch (Error e) {
            GLib.Test.message("Could not create accelerated media playback bridge: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void test_unavailable_provider() {
        var provider = new FakeMediaPlaybackProvider();
        provider.is_available = false;
        try {
            new Dino.Ui.MediaAudioPlaybackBridge(provider);
            GLib.Test.message("Unavailable playback provider unexpectedly created a bridge");
            GLib.Test.fail();
        } catch (IOError.NOT_SUPPORTED e) {
            assert_true(e.message == "fake playback unavailable", "provider error should be preserved");
        } catch (Error e) {
            GLib.Test.message("Unexpected playback provider error: %s", e.message);
            GLib.Test.fail();
        }
    }
}

}
