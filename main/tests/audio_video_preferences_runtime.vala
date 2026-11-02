using Dino.Entities;
using Dino.Plugins;
using Dino.Security;
using Gee;
using Gtk;
using Xmpp;

namespace Dino.Ui.Test {

// Exercise the actual preferences page and recorder adapters. Device hardware
// and the application profile are replaced; no production account is touched.
class AudioVideoPreferencesRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public AudioVideoPreferencesRuntimeTest() {
        base("AudioVideoPreferencesRuntime");
        add_test("call_defaults_do_not_reuse_message_preferences", test_call_defaults);
        add_test("identical_names_preserve_selected_device_and_saved_identity", test_identity);
        add_test("refresh_cancelled_by_unmap_reloads_on_remap", test_refresh);
        add_test("finished_and_cancelled_tests_release_callbacks", test_lifetime);
        add_test("recorder_sessions_do_not_retain_backends", test_recorder_lifetime);
        add_test("device_tests_preserve_focused_row_and_scroll_position", test_focus_and_scroll);
        add_test("completed_voice_recording_remains_available_for_send", test_voice_recording_handoff);
        add_test("failed_audio_session_creation_allows_a_new_recording", test_audio_session_creation_retry);
    }

    private class Device : Object, MediaDevice {
        private string runtime_id;
        private string saved_id;
        private string title;
        private string kind;
        private bool input;
        public string id { owned get { return runtime_id; } }
        public string persistent_id { owned get { return saved_id; } }
        public string display_name { owned get { return title; } }
        public string? detail_name { owned get { return null; } }
        public string? media { owned get { return kind; } }
        public bool incoming { get { return input; } }
        public Device(string runtime_id, string saved_id, string title, string kind, bool input) {
            this.runtime_id = runtime_id;
            this.saved_id = saved_id;
            this.title = title;
            this.kind = kind;
            this.input = input;
        }
    }

    private class CallEngine : Object, JmiCallEnginePlugin {
        public string engine_id { get { return "google-libwebrtc"; } }
        public ArrayList<MediaDevice> microphones = new ArrayList<MediaDevice>();
        public ArrayList<MediaDevice> speakers = new ArrayList<MediaDevice>();
        public ArrayList<MediaDevice> cameras = new ArrayList<MediaDevice>();
        public bool block_next_catalog = false;
        public AsyncQueue<Object> catalog_entered = new AsyncQueue<Object>();
        public AsyncQueue<Object> catalog_release = new AsyncQueue<Object>();
        public int catalog_count = 0;
        public int playout_count = 0;
        public int stop_count = 0;
        private Mutex catalog_mutex = Mutex();

        public bool runtime_enabled() { return true; }
        public bool can_start_audio_only(Account account) { return true; }
        public Gee.List<MediaDevice> get_audio_devices(bool incoming) {
            bool block = false;
            if (!incoming) {
                catalog_mutex.lock();
                catalog_count++;
                block = block_next_catalog;
                block_next_catalog = false;
                catalog_mutex.unlock();
            }
            if (block) {
                catalog_entered.push(new Object());
                catalog_release.pop();
            }
            return incoming ? speakers : microphones;
        }
        public Gee.List<MediaDevice> get_video_devices() { return cameras; }
        public MediaDevice? get_preferred_audio_device(bool incoming) { return null; }
        public void set_audio_device(MediaDevice device) throws Error { }
        public void play_test_tone(MediaDevice? device, char digit = '5', uint duration_ms = 360) throws Error {
            playout_count++;
        }
        public uint play_audio_test_clip(MediaDevice? device, Bytes pcm_data,
                int sample_rate, int channels, int bytes_per_sample) throws Error {
            playout_count++;
            return 10;
        }
        public void stop_audio_test_playout() throws Error { stop_count++; }
        public JmiCallEngineSession start_outgoing_audio_session(XmppStream stream,
                Jid local_full_jid, Jid peer_bare_jid, string sid, uint64 logical_call_id) throws Error {
            throw new IOError.NOT_SUPPORTED("No calls in isolated device tests");
        }
        public JmiCallEngineSession create_incoming_session(XmppStream stream,
                Jid local_full_jid, Jid peer_full_jid, string sid, uint64 logical_call_id,
                Gee.List<StanzaNode> descriptions) throws Error {
            throw new IOError.NOT_SUPPORTED("No calls in isolated device tests");
        }
        public bool handle_proceed(Jid from, Jid to, string sid) throws Error { return false; }
    }

    private class AudioSession : AudioMessageRecorderSession {
        private string path;
        private bool write_output;
        private Dino.Plugins.MediaMessageRecorderState current = Dino.Plugins.MediaMessageRecorderState.IDLE;
        public int cancel_count = 0;
        public override Dino.Plugins.MediaMessageRecorderState state { get { return current; } }
        public override string? current_output_path { owned get { return path; } }
        public AudioSession(string path, bool write_output = false) {
            this.path = path;
            this.write_output = write_output;
        }
        public override void start() throws Error {
            if (write_output) FileUtils.set_contents(path, "isolated nonempty voice recording");
            current = Dino.Plugins.MediaMessageRecorderState.RECORDING;
        }
        public override void stop() throws Error {
            current = Dino.Plugins.MediaMessageRecorderState.IDLE;
            recording_stopped(new Dino.Plugins.MediaMessageRecorderOutput(Dino.Plugins.MediaMessageKind.AUDIO, path, "audio/ogg", "test.ogg"));
        }
        public override void cancel() {
            cancel_count++;
            current = Dino.Plugins.MediaMessageRecorderState.IDLE;
            // Some backends report an error synchronously while cancelling.
            recording_error("cancelled isolated audio test");
        }
        public void emit_pcm() {
            uint8[] pcm = new uint8[48000 * 2];
            pcm_frame(new Bytes(pcm), 48000, 1, 2);
            level_changed(0.5);
        }
    }

    private class VideoSession : VideoMessageRecorderSession {
        private string path;
        private Dino.Plugins.MediaMessageRecorderState current = Dino.Plugins.MediaMessageRecorderState.IDLE;
        public int cancel_count = 0;
        public AsyncQueue<Object> started_queue = new AsyncQueue<Object>();
        public override Dino.Plugins.MediaMessageRecorderState state { get { return current; } }
        public override string? current_output_path { owned get { return path; } }
        public VideoSession(string path) { this.path = path; }
        public override void start() throws Error {
            current = Dino.Plugins.MediaMessageRecorderState.RECORDING;
            started_queue.push(new Object());
        }
        public override void stop() throws Error { current = Dino.Plugins.MediaMessageRecorderState.IDLE; }
        public override void cancel() { cancel_count++; current = Dino.Plugins.MediaMessageRecorderState.IDLE; }
    }

    private class Recorder : Object, MediaMessageRecorderProvider {
        public string id { get { return "google-libwebrtc"; } }
        public bool audio_available { get { return true; } }
        public string? audio_unavailable_reason { owned get { return null; } }
        public bool video_available { get { return true; } }
        public string? video_unavailable_reason { owned get { return null; } }
        public CallEngine engine;
        public MediaDevice? last_audio_device = null;
        public MediaDevice? last_video_device = null;
        public AudioSession? audio = null;
        public bool write_audio_output = false;
        public bool fail_audio_creation_once = false;
        public AsyncQueue<VideoSession> videos = new AsyncQueue<VideoSession>();
        public Recorder(CallEngine engine) { this.engine = engine; }
        public Gee.List<MediaDevice> get_audio_input_devices() { return engine.microphones; }
        public Gee.List<MediaDevice> get_video_input_devices() { return engine.cameras; }
        public AudioMessageRecorderSession create_audio_message_recorder(string output_path) throws Error {
            return create_audio_test_for_device(output_path, null);
        }
        public VideoMessageRecorderSession create_video_message_recorder(string output_path) throws Error {
            return create_video_preview_for_device(output_path, null);
        }
        public AudioMessageRecorderSession create_audio_test_for_device(string output_path, MediaDevice? device) throws Error {
            if (fail_audio_creation_once) {
                fail_audio_creation_once = false;
                throw new IOError.FAILED("isolated audio session creation failure");
            }
            last_audio_device = device;
            audio = new AudioSession(output_path, write_audio_output);
            return (!) audio;
        }
        public VideoMessageRecorderSession create_video_preview_for_device(string output_path, MediaDevice? device) throws Error {
            last_video_device = device;
            var video = new VideoSession(output_path);
            videos.push(video);
            return video;
        }
    }

    private class Playback : Object, MediaMessagePlaybackProvider {
        public string id { get { return "google-libwebrtc"; } }
        public bool available { get { return true; } }
        public string? unavailable_reason { owned get { return null; } }
        public CallEngine engine;
        public Playback(CallEngine engine) { this.engine = engine; }
        public Gee.List<MediaDevice> get_audio_output_devices() { return engine.speakers; }
        public MediaMessagePlaybackSession create_audio_playback_session() throws Error {
            throw new IOError.NOT_SUPPORTED("No message playback in isolated UI test");
        }
    }

    private class TestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Registry plugin_registry { get; set; default = new Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }
        public TestApplication(Database db) {
            Object(application_id: "im.dinox.audio-video-runtime-test", flags: ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "isolated device tests";
            this.file_encryption = new FileEncryption("isolated device tests");
            this.stream_interactor = new StreamInteractor.for_tests(db);
            this.settings = new Dino.Entities.Settings.from_db(db);
        }
        public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
    }

    private class Fixture : Object {
        public TestApplication app;
        public CallEngine engine = new CallEngine();
        public Recorder recorder;
        public Adw.Window window = new Adw.Window();
        public Dino.Ui.AudioVideoPreferencesPage? page;
        private GLib.Application? previous_app;
        private bool window_disposed = false;
        public Fixture() throws Error {
            previous_app = GLib.Application.get_default();
            var db = new Database(":memory:", "isolated device tests");
            app = new TestApplication(db);
            GLib.Application.set_default(app);
            engine.microphones.add(new Device("recording:0:guid-a", "recording-guid:guid-a", "Duplicate microphone", "audio", false));
            engine.microphones.add(new Device("recording:1:guid-b", "recording-guid:guid-b", "Duplicate microphone", "audio", false));
            engine.speakers.add(new Device("playout:0:guid-a", "playout-guid:guid-a", "Speaker", "audio", true));
            engine.cameras.add(new Device("video:0:camera-a", "video-uid:camera-a", "Duplicate camera", "video", false));
            engine.cameras.add(new Device("video:1:camera-b", "video-uid:camera-b", "Duplicate camera", "video", false));
            recorder = new Recorder(engine);
            app.plugin_registry.jmi_call_engine_plugin = engine;
            app.plugin_registry.media_message_recorder_provider = recorder;
            app.plugin_registry.media_message_playback_provider = new Playback(engine);
            page = new Dino.Ui.AudioVideoPreferencesPage();
            ((!) page).ensure_content();
            window.content = (!) page;
            window.set_default_size(640, 900);
        }
        public void present() { window.present(); }
        public Adw.ActionRow row(string title) {
            Adw.ActionRow? found = find_row((!) page, GLib.dgettext("dino", title));
            assert(found != null);
            return (!) found;
        }
        private Adw.ActionRow? find_row(Gtk.Widget parent, string title) {
            var row = parent as Adw.ActionRow;
            if (row != null && row.title == title) return row;
            for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
                var found = find_row((!) child, title);
                if (found != null) return found;
            }
            return null;
        }
        public void release_page() {
            window.content = null;
            page = null;
        }
        public void close_window() {
            if (window_disposed) return;
            window_disposed = true;
            window.set_visible(false);
            release_page();
            window.destroy();
            // The fixture still owns its root window after destroy(). Dispose
            // that unparented root to release GTK's pending focus target too.
            window.dispose();
        }
        public void close() {
            engine.catalog_release.push(new Object());
            close_window();
            iterate_for(30);
            GLib.Application.set_default(previous_app);
        }
    }

    private void test_call_defaults() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.app.settings.msg_audio_input_device = f.engine.microphones[1].persistent_id;
            f.app.settings.msg_video_device = f.engine.cameras[1].persistent_id;
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Microphone").sensitive), "Device catalog loaded")) return;
            f.row("Test Call Microphone").activated();
            fail_if_not(f.recorder.last_audio_device is SystemDefaultMediaDevice,
                "Explicit call default must not turn into the message-preference null override");
            f.window.set_visible(false);
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Camera").sensitive), "Tests enabled after cancellation")) return;
            f.row("Test Call Camera").activated();
            VideoSession? video = null;
            if (fail_if_not(wait_for(() => { video = f.recorder.videos.try_pop(); return video != null; }), "Camera preview session created")) return;
            fail_if_not(f.recorder.last_video_device is SystemDefaultMediaDevice,
                "Explicit call camera default must bypass message camera preference");
            if (fail_if_not(wait_for(() => f.window.visible_dialog is Adw.AlertDialog), "Call preview dialog visible")) return;
            var call_dialog = (Adw.AlertDialog) f.window.visible_dialog;
            fail_if_not_eq_str(GLib.dgettext("dino", "Call Camera Preview"), call_dialog.heading, "Call camera preview identifies its scope");
            fail_if_not_eq_str(GLib.dgettext("dino", "Camera: %s\nUses the camera selected under Audio/Video Calls.").printf(
                    GLib.dgettext("dino", "System Default")), call_dialog.body,
                "Call preview names its explicit default and the call settings section");
            if (!close_current_preview(f)) return;
            if (fail_if_not(wait_for(() => f.row("Test Recording Camera").sensitive), "Message camera test enabled after closing call preview")) return;
            f.row("Test Recording Camera").activated();
            video = null;
            if (fail_if_not(wait_for(() => { video = f.recorder.videos.try_pop(); return video != null; }), "Message camera preview created")) return;
            fail_if_not(f.recorder.last_video_device == f.engine.cameras[1],
                "Message camera preview uses its separate message preference");
            if (fail_if_not(wait_for(() => f.window.visible_dialog is Adw.AlertDialog), "Message preview dialog visible")) return;
            var message_dialog = (Adw.AlertDialog) f.window.visible_dialog;
            fail_if_not_eq_str(GLib.dgettext("dino", "Message Camera Preview"), message_dialog.heading, "Message camera preview identifies its scope");
            fail_if_not_eq_str(GLib.dgettext("dino", "Camera: %s\nUses the camera selected under Voice/Video Messages.").printf(
                    f.engine.cameras[1].display_name), message_dialog.body,
                "Message preview names its selected camera and the message settings section");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_identity() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            // Cover old indexed preferences as well as new stable preferences.
            f.app.settings.call_audio_input_device = f.engine.microphones[1].id;
            f.app.settings.call_video_device = f.engine.cameras[1].persistent_id;
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Microphone").sensitive), "Device catalog loaded")) return;
            var mic_row = (Adw.ComboRow) f.row("Microphone");
            fail_if_not_eq_int(2, (int) mic_row.selected, "Exact ID wins over identical earlier label");
            f.row("Test Call Microphone").activated();
            fail_if_not(f.recorder.last_audio_device == f.engine.microphones[1], "Selected second microphone is tested");
            f.window.set_visible(false);
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Camera").sensitive), "Tests enabled after cancellation")) return;
            var camera_row = (Adw.ComboRow) f.row("Camera");
            fail_if_not_eq_int(2, (int) camera_row.selected, "Stable camera preference selects duplicate-name device");
            f.row("Test Call Camera").activated();
            VideoSession? video = null;
            if (fail_if_not(wait_for(() => { video = f.recorder.videos.try_pop(); return video != null; }), "Camera preview created")) return;
            fail_if_not(f.recorder.last_video_device == f.engine.cameras[1], "Exact camera identity wins over first label");
            if (fail_if_not(wait_for(() => f.window.visible_dialog is Adw.AlertDialog), "Selected call camera dialog visible")) return;
            var call_dialog = (Adw.AlertDialog) f.window.visible_dialog;
            fail_if_not_eq_str(GLib.dgettext("dino", "Call Camera Preview"), call_dialog.heading);
            fail_if_not_eq_str(GLib.dgettext("dino", "Camera: %s\nUses the camera selected under Audio/Video Calls.").printf(
                    f.engine.cameras[1].display_name), call_dialog.body,
                "Call preview describes the selected concrete camera");
            f.window.set_visible(false);
            mic_row.selected = 1;
            mic_row.selected = 2;
            fail_if_not_eq_str(f.engine.microphones[1].persistent_id, f.app.settings.call_audio_input_device,
                "Device selection saves an index-independent identifier");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_refresh() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Microphone").sensitive), "First catalog loaded")) return;
            f.engine.block_next_catalog = true;
            f.row("Refresh Devices").activated();
            if (fail_if_not(wait_for(() => f.engine.catalog_entered.try_pop() != null), "Refresh reached worker")) return;
            fail_if(f.row("Microphone").sensitive, "Device row disabled while refreshing");
            f.window.set_visible(false);
            f.engine.catalog_release.push(new Object());
            iterate_for(30);
            f.present();
            fail_if_not(wait_for(() => f.row("Microphone").sensitive), "Remapping retries canceled refresh automatically");
            fail_if(f.engine.catalog_count < 3, "A new catalog enumeration must run after cancellation");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_lifetime() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.present();
            if (fail_if_not(wait_for(() => f.row("Test Call Microphone").sensitive), "Device catalog loaded")) return;
            var mic_row = f.row("Test Call Microphone");
            f.row("Test Call Microphone").activated();
            var completed_audio = (!) f.recorder.audio;
            completed_audio.emit_pcm();
            completed_audio.stop();
            if (fail_if_not(wait_for(() => f.row("Test Call Camera").sensitive), "Completed microphone playback releases test")) return;
            string completed_status = mic_row.subtitle;
            completed_audio.recording_error("late completed test error");
            completed_audio.emit_pcm();
            fail_if_not_eq_str(completed_status, mic_row.subtitle, "Completed backend callbacks are disconnected");
            f.row("Test Call Microphone").activated();
            var cancelled_audio = (!) f.recorder.audio;
            f.window.set_visible(false);
            fail_if_not_eq_int(1, cancelled_audio.cancel_count, "Unmapping cancels recording once");
            f.present();
            if (fail_if_not(wait_for(() => mic_row.sensitive), "Tests available after cancellation")) return;
            f.row("Test Call Camera").activated();
            VideoSession? cancelled_video = null;
            if (fail_if_not(wait_for(() => { cancelled_video = f.recorder.videos.try_pop(); return cancelled_video != null; }), "Camera preview created")) return;
            if (fail_if_not(wait_for(() => ((!) cancelled_video).started_queue.try_pop() != null), "Camera preview started")) return;
            iterate_for(30);
            WeakRef page_weak = WeakRef((!) f.page);
            // Retain old sessions while closing the complete GTK root.
            f.close_window();
            int64 release_started_us = get_monotonic_time();
            bool page_released = wait_for(() => page_weak.get() == null);
            fail_if_not(page_released,
                "Cancelled microphone and camera backends must not retain the settings page");
            GLib.Test.message("Settings page release=%s, elapsed=%" + int64.FORMAT + " ms",
                page_released.to_string(), (get_monotonic_time() - release_started_us) / 1000);
            cancelled_audio.recording_error("late cancelled test error");
            ((!) cancelled_video).recording_error("late cancelled camera error");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private void test_focus_and_scroll() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.window.set_default_size(640, 440);
            f.present();
            // Rows start sensitive before the delayed device catalog load.
            // Wait for its applied model so that loading cannot steal the
            // keyboard focus that this test is about to exercise.
            if (fail_if_not(wait_for(() => {
                var microphones = ((Adw.ComboRow) f.row("Microphone")).model;
                return microphones != null && microphones.get_n_items() == 3 &&
                    f.row("Test Call Microphone").sensitive;
            }), "Device catalog applied before focusing a test action")) return;
            Gtk.ScrolledWindow? scroller = find_scroller((!) f.page);
            if (fail_if_not(scroller != null, "Actual preferences page contains a scrolled viewport")) return;
            var adjustment = ((!) scroller).vadjustment;
            if (fail_if_not(wait_for(() => adjustment.upper > adjustment.page_size), "Preferences exceed the viewport")) return;

            var mic = f.row("Test Call Microphone");
            var speaker = f.row("Test Call Speaker");
            var camera = f.row("Test Call Camera");
            fail_if_not(mic.grab_focus(), "Microphone action is keyboard focusable");
            if (fail_if_not(wait_for_focused_row_visible(f.window, mic, (!) scroller),
                    "Natural focus scrolling brings the microphone action into view")) return;
            double mic_scroll = adjustment.value;
            fail_if_not(mic_scroll > 0, "Focused microphone test is below the first settings group");
            mic.activated();
            var audio = (!) f.recorder.audio;
            iterate_for(40);
            fail_if_not(row_has_focus(f.window, mic), "Running microphone test keeps its original focus anchor");
            fail_if_not(mic.sensitive && !speaker.sensitive && !camera.sensitive,
                "Active status remains focusable while other device tests are disabled");
            string running_status = mic.subtitle;
            mic.activated();
            fail_if_not(f.recorder.audio == audio, "Repeated activation cannot start a second recording");
            fail_if_not_eq_str(running_status, mic.subtitle, "Repeated active test activation preserves its current status");
            audio.emit_pcm();
            audio.stop();
            if (fail_if_not(wait_for(() => camera.sensitive), "Microphone playback completed")) return;
            assert_focus_and_scroll(f.window, mic, adjustment, mic_scroll, "Microphone completion");

            fail_if_not(speaker.grab_focus(), "Speaker action is keyboard focusable");
            if (fail_if_not(wait_for_focused_row_visible(f.window, speaker, (!) scroller),
                    "Natural focus scrolling brings the speaker action into view")) return;
            double speaker_scroll = adjustment.value;
            speaker.activated();
            iterate_for(40);
            fail_if_not(row_has_focus(f.window, speaker), "Speaker playback keeps its original focus anchor");
            if (fail_if_not(wait_for(() => camera.sensitive), "Speaker playback completed")) return;
            assert_focus_and_scroll(f.window, speaker, adjustment, speaker_scroll, "Speaker completion");

            fail_if_not(camera.grab_focus(), "Camera action is keyboard focusable");
            if (fail_if_not(wait_for_focused_row_visible(f.window, camera, (!) scroller),
                    "Natural focus scrolling brings the camera action into view")) return;
            double camera_scroll = adjustment.value;
            camera.activated();
            if (fail_if_not(wait_for(() => f.window.visible_dialog is Adw.AlertDialog), "Camera preview dialog presented")) return;
            var dialog = (Adw.AlertDialog) f.window.visible_dialog;
            if (fail_if_not(wait_for(() => dialog.get_mapped()), "Camera dialog mapped")) return;
            int frames = 0;
            uint tick = dialog.add_tick_callback((widget, clock) => {
                frames++;
                return frames < 2;
            });
            bool rendered = wait_for(() => frames == 2);
            if (!rendered) dialog.remove_tick_callback(tick);
            if (fail_if_not(rendered, "Camera preview renders before a real close activation")) return;
            Gtk.Button? close = find_button(dialog, GLib.dgettext("dino", "Close"));
            if (fail_if_not(close != null, "Camera dialog offers its close action")) return;
            ((!) close).clicked();
            if (fail_if_not(wait_for(() => f.window.visible_dialog == null && row_has_focus(f.window, camera)),
                    "Closing camera preview restores the clicked action")) return;
            assert_focus_and_scroll(f.window, camera, adjustment, camera_scroll, "Camera dialog close");

            // Cancelling through page unmap must also retain the page's
            // natural focus/scroll anchor when the same page is shown again.
            mic.grab_focus();
            if (fail_if_not(wait_for_focused_row_visible(f.window, mic, (!) scroller),
                    "Natural focus scrolling restores the microphone action before cancellation")) return;
            double cancel_scroll = adjustment.value;
            mic.activated();
            f.window.set_visible(false);
            f.present();
            if (fail_if_not(wait_for(() => camera.sensitive && row_has_focus(f.window, mic)),
                    "Unmapped microphone test is cancelled without changing focus on remap")) return;
            assert_focus_and_scroll(f.window, mic, adjustment, cancel_scroll, "Cancelled test remap");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) fixture.close(); }
    }

    private static bool close_current_preview(Fixture f) {
        var dialog = f.window.visible_dialog as Adw.AlertDialog;
        if (fail_if_not(dialog != null && wait_for(() => ((!) dialog).get_mapped()), "Preview dialog is mapped")) return false;
        // Match a real user's rendered close-button activation. libadwaita
        // starts the sheet on its second frame after the initial map.
        int frames = 0;
        uint tick = ((!) dialog).add_tick_callback((widget, clock) => {
            frames++;
            return frames < 2;
        });
        bool rendered = wait_for(() => frames == 2);
        if (!rendered) ((!) dialog).remove_tick_callback(tick);
        if (fail_if_not(rendered, "Preview renders before close activation")) return false;
        Gtk.Button? close = find_button((!) dialog, GLib.dgettext("dino", "Close"));
        if (fail_if_not(close != null, "Preview provides a close button")) return false;
        ((!) close).clicked();
        return !fail_if_not(wait_for(() => f.window.visible_dialog == null), "Preview closes through its real response button");
    }

    private static Gtk.ScrolledWindow? find_scroller(Gtk.Widget parent) {
        if (parent is Gtk.ScrolledWindow) return (Gtk.ScrolledWindow) parent;
        for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var scroller = find_scroller((!) child);
            if (scroller != null) return scroller;
        }
        return null;
    }
    private static Gtk.Button? find_button(Gtk.Widget parent, string label) {
        var button = parent as Gtk.Button;
        if (button != null && button.label == label) return button;
        for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_button((!) child, label);
            if (found != null) return found;
        }
        return null;
    }
    private static bool row_has_focus(Gtk.Window window, Adw.ActionRow row) {
        Gtk.Widget? focus = window.get_focus();
        return focus != null && (focus == row || focus.is_ancestor(row));
    }
    private static bool wait_for_focused_row_visible(Gtk.Window window, Adw.ActionRow row,
            Gtk.ScrolledWindow scroller) {
        // Focus scrolling is animated under Adwaita. Record the baseline
        // after the real action enters the viewport, not after a fixed delay
        // that can sample its unfinished focus animation.
        return wait_for(() => {
            Graphene.Rect bounds = Graphene.Rect();
            return row_has_focus(window, row) && row.compute_bounds(scroller, out bounds) &&
                bounds.origin.y >= 0 &&
                bounds.origin.y + bounds.size.height <= scroller.vadjustment.page_size;
        });
    }
    private static void assert_focus_and_scroll(Gtk.Window window, Adw.ActionRow row,
            Gtk.Adjustment adjustment, double before, string stage) {
        fail_if_not(row_has_focus(window, row), stage + " must preserve the activated row's keyboard focus");
        // Subtitle wrapping may change one row's height. A viewport jump to
        // the first device group is substantially larger than this tolerance.
        fail_if_not(adjustment.value > 0 && Math.fabs(adjustment.value - before) <= 32,
            stage + " must keep the same part of the settings page visible");
    }

    private void test_voice_recording_handoff() {
        string? directory = null;
        Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend? recorder = null;
        try {
            directory = Path.build_filename(Environment.get_user_cache_dir(), "voice-handoff-" + Uuid.string_random());
            if (DirUtils.create_with_parents((!) directory, 0700) != 0) {
                throw new IOError.FAILED("Could not create isolated voice handoff directory");
            }
            var provider = new Recorder(new CallEngine()) { write_audio_output = true };
            // This is message-recording mode, not the microphone-test mode.
            recorder = new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend(provider);
            int stop_count = 0;
            int error_count = 0;
            Dino.Ui.ChatInput.MediaMessageRecorderOutput? stopped_output = null;
            recorder.recording_stopped.connect((output) => {
                stop_count++;
                stopped_output = output;
            });
            recorder.recording_error.connect((message) => { error_count++; });
            string completed_path = Path.build_filename((!) directory, "completed.ogg");
            recorder.start_recording(completed_path);
            var completed_session = (!) provider.audio;
            recorder.stop_recording();

            // ChatInputController.stop_recording reads this property only
            // after stop() has synchronously emitted recording_stopped. Its
            // send decision then queries the actual file size through GIO.
            string? send_path = recorder.current_output_path;
            if (fail_if_not(send_path != null, "Completed voice output must remain readable after synchronous stop")) return;
            fail_if_not_eq_str(completed_path, (!) send_path, "Send handoff retains the finalized recording path");
            FileInfo info = File.new_for_path((!) send_path).query_info(
                FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            fail_if_not(info.get_size() > 0, "Voice send consumer must receive a nonempty existing recording");
            fail_if_not_eq_int(1, stop_count, "A completed voice recording emits exactly one output");
            fail_if_not(stopped_output != null && ((!) stopped_output).path == send_path,
                "Stopped signal and post-stop send path describe the same file");
            recorder.stop_recording();
            completed_session.recording_error("late completed-session error");
            completed_session.stop();
            fail_if_not_eq_int(1, stop_count, "A detached old session cannot emit a second completion");
            fail_if_not_eq_int(0, error_count, "Late errors cannot revoke a successfully handed-off recording");
            fail_if_not_eq_str(completed_path, recorder.current_output_path ?? "", "Late errors preserve the send handoff");
            recorder.dispose();
            recorder = null;
            fail_if_not(FileUtils.test(completed_path, FileTest.IS_REGULAR),
                "Disposing the finished backend must not remove the file awaiting FileManager");

            string cancelled_path = Path.build_filename((!) directory, "cancelled.ogg");
            recorder = new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend(provider);
            recorder.start_recording(cancelled_path);
            fail_if_not(FileUtils.test(cancelled_path, FileTest.IS_REGULAR), "Cancellation fixture contains real recorded bytes");
            recorder.cancel_recording();
            fail_if_not(recorder.current_output_path == null && !FileUtils.test(cancelled_path, FileTest.EXISTS),
                "Cancelling an unfinished recording clears the path and deletes its bytes");
            recorder = null;

            string failed_path = Path.build_filename((!) directory, "failed.ogg");
            recorder = new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend(provider);
            recorder.start_recording(failed_path);
            fail_if_not(FileUtils.test(failed_path, FileTest.IS_REGULAR), "Failure fixture contains real recorded bytes");
            ((!) provider.audio).recording_error("isolated voice recording failure");
            fail_if_not(recorder.current_output_path == null && !FileUtils.test(failed_path, FileTest.EXISTS),
                "Failed recordings clear the send path and delete incomplete bytes");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (recorder != null) recorder.dispose();
            if (directory != null) {
                foreach (string name in new string[] { "completed.ogg", "cancelled.ogg", "failed.ogg" }) {
                    FileUtils.unlink(Path.build_filename((!) directory, name));
                }
                DirUtils.remove((!) directory);
            }
        }
    }

    private void test_audio_session_creation_retry() {
        string? directory = null;
        Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend? backend = null;
        try {
            directory = Path.build_filename(Environment.get_user_cache_dir(), "voice-start-retry-" + Uuid.string_random());
            if (DirUtils.create_with_parents((!) directory, 0700) != 0) {
                throw new IOError.FAILED("Could not create isolated recording retry directory");
            }
            var provider = new Recorder(new CallEngine()) {
                write_audio_output = true,
                fail_audio_creation_once = true
            };
            backend = new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend(provider);
            string failed_path = Path.build_filename((!) directory, "failed-start.ogg");
            bool failed = false;
            try {
                backend.start_recording(failed_path);
            } catch (IOError error) {
                failed = true;
                fail_if_not(error is IOError.FAILED, "Factory creation error propagates to the chat");
            }
            if (fail_if_not(failed, "First session creation must exercise the factory failure")) return;
            fail_if_not(provider.audio == null && !provider.fail_audio_creation_once,
                "Factory failure happens before any capture session is created");
            fail_if_not(backend.state == Dino.Ui.ChatInput.MediaMessageRecorderState.FAILED && !backend.state.is_busy(),
                "Session creation failure must not leave the reusable backend stuck in STARTING");
            fail_if_not(backend.current_output_path == null && !FileUtils.test(failed_path, FileTest.EXISTS),
                "Failed session creation leaves no send path or recording file");

            // The chat retains this same backend after showing the error.
            string retry_path = Path.build_filename((!) directory, "retry.ogg");
            backend.start_recording(retry_path);
            fail_if_not(backend.state == Dino.Ui.ChatInput.MediaMessageRecorderState.RECORDING,
                "The same backend must start a new recording after factory failure");
            fail_if_not_eq_str(retry_path, backend.current_output_path ?? "", "Retry owns the new recording path");
            fail_if_not(FileUtils.test(retry_path, FileTest.IS_REGULAR), "Retried capture creates real recording bytes");
            var retried_session = (!) provider.audio;
            backend.cancel_recording();
            fail_if_not_eq_int(1, retried_session.cancel_count, "Retry cancellation releases its capture session once");
            fail_if_not(backend.state == Dino.Ui.ChatInput.MediaMessageRecorderState.IDLE &&
                    backend.current_output_path == null && !FileUtils.test(retry_path, FileTest.EXISTS),
                "Cancelling the retry clears state, path and incomplete bytes");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (backend != null) backend.dispose();
            if (directory != null) {
                foreach (string name in new string[] { "failed-start.ogg", "retry.ogg" }) {
                    FileUtils.unlink(Path.build_filename((!) directory, name));
                }
                DirUtils.remove((!) directory);
            }
        }
    }

    private void test_recorder_lifetime() {
        try {
            var recorder = new Recorder(new CallEngine());
            string path = Path.build_filename(Environment.get_user_cache_dir(), "av-recorder-" + Uuid.string_random());
            for (int mode = 0; mode < 3; mode++) {
                Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend? audio =
                    new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend(recorder, null, true);
                audio.start_recording(path);
                var retained_session = (!) recorder.audio;
                WeakRef audio_weak = WeakRef(audio);
                if (mode == 0) audio.stop_recording();
                else if (mode == 1) retained_session.recording_error("isolated recording failure");
                else audio.cancel_recording();
                audio = null;
                fail_if_not(wait_for(() => audio_weak.get() == null),
                    "Audio stop, error and cancel release backend despite retained session");
                retained_session.recording_error("late audio error");
            }
            for (int mode = 0; mode < 3; mode++) {
                Dino.Ui.ChatInput.ProviderVideoMessageRecorderBackend? video =
                    new Dino.Ui.ChatInput.ProviderVideoMessageRecorderBackend(recorder, null, true);
                video.start_recording(path);
                VideoSession? retained_session = null;
                if (fail_if_not(wait_for(() => { retained_session = recorder.videos.try_pop(); return retained_session != null; }),
                        "Video session created")) return;
                if (fail_if_not(wait_for(() => video.state == Dino.Ui.ChatInput.MediaMessageRecorderState.RECORDING),
                        "Video worker handoff completed")) return;
                WeakRef video_weak = WeakRef(video);
                if (mode == 0) video.cancel_recording();
                else if (mode == 1) ((!) retained_session).recording_error("isolated video failure");
                // Mode 2 intentionally drops a running preview without an
                // explicit cancel: weak callbacks let dispose clean it up.
                video = null;
                fail_if_not(wait_for(() => video_weak.get() == null),
                    "Video cancellation, error and dispose release generation callback captures");
                ((!) retained_session).recording_error("late video error");
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private static bool wait_for(owned Ready ready, uint timeout_ms = 3000) {
        int64 end = get_monotonic_time() + (int64) timeout_ms * 1000;
        while (get_monotonic_time() < end) {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            if (ready()) return true;
            Thread.usleep(1000);
        }
        return ready();
    }
    private static void iterate_for(uint ms) {
        int64 end = get_monotonic_time() + (int64) ms * 1000;
        do {
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            Thread.usleep(1000);
        } while (get_monotonic_time() < end);
    }
}

}
