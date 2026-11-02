using Dino.Entities;
using Dino.Security;
using Dino.Ui.ConversationSummary;
using Gtk;

namespace Dino.Ui.Test {

// Real encrypted input, decoder and GTK widgets; never uses a user account,
// network connection, camera or physical audio output.
class VideoPlayerRuntimeTest : Gee.TestCase {
    private delegate bool Ready();
    private Database? db;
    private Dino.Ui.Application? app;
    private GLib.Application? previous_app;
    private string? source_path;
    private FileTransfer file;
    private Window window;
    private VideoPlayerWidget? player;

    public VideoPlayerRuntimeTest() {
        base("VideoPlayerRuntime");
        add_test("delayed_first_map_generates_poster", test_delayed_map);
        add_test("h264_aac_first_map_generates_poster", test_h264);
        add_test("unicode_file_path_generates_poster", test_unicode_path);
        add_test("cached_reentry_has_poster_before_mapping", test_cached_reentry);
        add_test("portrait_poster_keeps_reserved_height", test_portrait_geometry);
        add_test("unmap_stops_playback_and_restores_poster", test_unmap_playback);
    }

    private class OutputSession : Dino.Plugins.MediaMessagePlaybackSession {
        public override bool active { get { return false; } }
        public override void start(int rate, int channels, int bytes_per_sample) throws Error { }
        public override uint push_pcm(Bytes pcm) throws Error { return 0; }
        public override void set_paused(bool paused) throws Error { }
        public override void flush() throws Error { }
        public override uint finish() throws Error { return 0; }
        public override void stop() { }
    }
    private class OutputProvider : Object, Dino.Plugins.MediaMessagePlaybackProvider {
        public string id { get { return "isolated-video-output"; } }
        public bool available { get { return true; } }
        public string? unavailable_reason { owned get { return null; } }
        public Dino.Plugins.MediaMessagePlaybackSession create_audio_playback_session() throws Error {
            return new OutputSession();
        }
    }

    private static void iterate_for(uint milliseconds) {
        int64 end = get_monotonic_time() + milliseconds * 1000;
        do {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        } while (get_monotonic_time() < end);
    }
    private static bool wait_for(Ready ready, string reason) {
        int64 end = get_monotonic_time() + 6 * TimeSpan.SECOND;
        while (!ready() && get_monotonic_time() < end) iterate_for(5);
        bool result = ready();
        fail_if_not(result, reason);
        return result;
    }
    private static Stack stack_of(VideoPlayerWidget widget) {
        return (Stack) ((Overlay) widget.get_first_child()).get_child();
    }
    private static Gdk.Texture? poster(VideoPlayerWidget widget) {
        var child = stack_of(widget).visible_child as FixedRatioPicture;
        return child == null ? null : child.paintable as Gdk.Texture;
    }
    private static Button? start_button(Widget root) {
        if (root is Button && ((Button) root).icon_name == "media-playback-start-symbolic") return (Button) root;
        for (Widget? child = root.get_first_child(); child != null; child = child.get_next_sibling()) {
            var button = start_button(child);
            if (button != null) return button;
        }
        return null;
    }
    private static int natural_height(Widget widget) {
        int minimum, natural, min_baseline, nat_baseline;
        widget.measure(Orientation.VERTICAL, 320, out minimum, out natural, out min_baseline, out nat_baseline);
        return natural;
    }

    private bool prepare(bool portrait = false, bool mp4 = false, bool unicode_path = false) {
        if (Gst.ElementFactory.find("vp8enc") == null || Gst.ElementFactory.find("webmmux") == null ||
                Gst.ElementFactory.find("videotestsrc") == null) {
            GLib.Test.skip("Synthetic video fixture requires videotestsrc, vp8enc and webmmux");
            return false;
        }
        if (mp4 && (Gst.ElementFactory.find("x264enc") == null ||
                Gst.ElementFactory.find("avenc_aac") == null)) {
            GLib.Test.skip("H.264/AAC fixture requires x264enc and avenc_aac");
            return false;
        }
        try {
            previous_app = GLib.Application.get_default();
            db = new Database(":memory:", "isolated video runtime");
            var interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new FileEncryption("isolated video runtime");
            FileManager.start(interactor, (!) db, encryption);
            app = new Dino.Ui.Application() {
                db = db, file_encryption = encryption, stream_interactor = interactor,
                settings = new Dino.Entities.Settings.from_db(db)
            };
            app.plugin_registry.media_message_playback_provider = new OutputProvider();
            GLib.Application.set_default(app);
            string name = "video-runtime-" + Uuid.string_random();
            if (unicode_path) name += " - العربية 日本語 Türkçe";
            DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
            source_path = Path.build_filename(FileManager.get_storage_dir(), name + ".enc");
            string raw_path = source_path + (mp4 ? ".mp4" : ".webm");
            int width = portrait ? 108 : 160;
            int height = portrait ? 192 : 90;
            string encoding = mp4 ?
                "x264enc speed-preset=ultrafast tune=zerolatency threads=1 ! h264parse ! mp4mux name=mux" :
                "vp8enc deadline=1 threads=1 ! webmmux";
            string audio = mp4 ? " audiotestsrc num-buffers=40 samplesperbuffer=4410 ! " +
                "audio/x-raw,rate=44100 ! audioconvert ! avenc_aac ! aacparse ! mux." : "";
            var pipeline = Gst.parse_launch("videotestsrc num-buffers=40 pattern=smpte ! " +
                "video/x-raw,width=%d,height=%d,framerate=10/1 ! ".printf(width, height) +
                encoding + " ! filesink name=fixture_output" + audio);
            // A native Windows path contains backslashes. Set the property
            // directly so the launch parser cannot consume them as escapes.
            ((Gst.Bin) pipeline).get_by_name("fixture_output").set("location", raw_path);
            pipeline.set_state(Gst.State.PLAYING);
            var message = pipeline.get_bus().timed_pop_filtered(5 * Gst.SECOND,
                Gst.MessageType.EOS | Gst.MessageType.ERROR);
            pipeline.set_state(Gst.State.NULL);
            if (message == null || message.type != Gst.MessageType.EOS) {
                FileUtils.remove(raw_path);
                fail_if_reached("Synthetic video encoding did not complete");
                return false;
            }
            uint8[] data;
            FileUtils.get_data(raw_path, out data);
            FileUtils.remove(raw_path);
            FileUtils.set_data(source_path, encryption.encrypt_data(data));
            file = new FileTransfer() {
                path = name + ".enc", file_name = unicode_path ? "العربية 日本語 Türkçe.webm" :
                    (mp4 ? "fixture.mp4" : "fixture.webm"),
                mime_type = mp4 ? "video/mp4" : "video/webm",
                size = data.length, width = width, height = height,
                direction = FileTransfer.DIRECTION_RECEIVED, provider = FileManager.SFS_PROVIDER_ID
            };
            file.set_transfer_phase(FileTransfer.Phase.COMPLETE);
            player = new VideoPlayerWidget(file, interactor);
            window = new Window() { default_width = 480, default_height = 360 };
            return true;
        } catch (Error error) {
            fail_if_reached(error.message);
            return false;
        }
    }

    private void map_player() {
        window.set_child(player);
        window.present();
        wait_for(() => player.get_mapped(), "video widget must map");
    }
    public override void tear_down() {
        if (window != null) {
            window.set_child(null);
            window.destroy();
            window.dispose();
        }
        if (player != null) { player.dispose(); player = null; }
        iterate_for(80);
        GLib.Application.set_default(previous_app);
        app = null;
        if (db != null) { db.close(); db = null; }
        if (source_path != null) { FileUtils.remove(source_path); source_path = null; }
    }
    private void test_delayed_map() {
        if (!prepare()) return;
        iterate_for(550);
        map_player();
        wait_for(() => poster(player) != null,
            "first mapping after the initial retry window must still generate the poster");
    }
    private void test_h264() {
        if (!prepare(false, true)) return;
        map_player();
        wait_for(() => poster(player) != null, "H.264 video with AAC audio must generate a poster on first entry");
    }
    private void test_unicode_path() {
        if (!prepare(false, false, true)) return;
        map_player();
        wait_for(() => poster(player) != null,
            "non-ASCII storage paths and filenames must not prevent video previews");
    }
    private void test_cached_reentry() {
        if (!prepare()) return;
        map_player();
        if (!wait_for(() => poster(player) != null, "initial poster must decode")) return;
        var original = poster(player);
        int height = natural_height(player);
        window.set_child(null);
        player.dispose();
        player = new VideoPlayerWidget(file, app.stream_interactor);
        fail_if_not(poster(player) == original,
            "a cached poster must be installed before the replacement widget is mapped");
        fail_if_not_eq_int(height, natural_height(player), "chat reentry must reserve the same height immediately");
        map_player();
    }
    private void test_portrait_geometry() {
        if (!prepare(true)) return;
        int height = natural_height(player);
        map_player();
        if (!wait_for(() => poster(player) != null, "portrait poster must decode")) return;
        iterate_for(120); // Include actual layout and painted frames, not only the property update.
        fail_if_not(poster(player).get_height() > poster(player).get_width(), "portrait frame must retain its aspect");
        fail_if_not_eq_int(height, natural_height(player), "decoding a portrait must not move surrounding messages");
    }
    private void test_unmap_playback() {
        if (!prepare()) return;
        map_player();
        if (!wait_for(() => poster(player) != null, "poster must decode before playback")) return;
        var preview = stack_of(player).visible_child;
        int height = natural_height(player);
        var button = start_button(player);
        fail_if_not(button != null, "play button must exist");
        button.clicked();
        if (!wait_for(() => stack_of(player).visible_child != preview, "playback must show its video surface")) return;
        iterate_for(150);
        fail_if_not_eq_int(height, natural_height(player), "starting playback must not resize the message row");
        window.set_child(null);
        fail_if_not(stack_of(player).visible_child == preview,
            "leaving the chat must restore its poster, not retain an empty playback surface");
        fail_if_not(button.visible, "leaving the chat must restore the play affordance");
        map_player();
        fail_if_not(stack_of(player).visible_child == preview, "reentry must show the same poster without restarting playback");
    }
}

}
