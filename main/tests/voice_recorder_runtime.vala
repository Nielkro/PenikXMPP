using Gtk;
using Dino.Ui.ChatInput;

namespace Dino.Ui.Test {

class VoiceRecorderRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public VoiceRecorderRuntimeTest() {
        base("VoiceRecorderRuntime");
        add_test("recording_controls_reset_and_render_real_input", test_controls);
        add_test("send_discard_and_maximum_are_deferred_single_shot", test_actions);
        add_test("closed_popover_releases_with_backend_retained", test_release);
    }

    private class Backend : Object, MediaMessageRecorderBackend, AudioMessageRecorderBackend {
        public MediaMessageRecorderState current_state = MediaMessageRecorderState.RECORDING;
        public int stop_count = 0;
        public int cancel_count = 0;
        public MediaMessageKind kind { get { return MediaMessageKind.AUDIO; } }
        public MediaMessageRecorderState state { get { return current_state; } }
        public string? current_output_path { get { return null; } }
        public void start_recording(string path) throws Error { current_state = MediaMessageRecorderState.RECORDING; }
        public void stop_recording() { stop_count++; current_state = MediaMessageRecorderState.IDLE; }
        public void cancel_recording() { cancel_count++; current_state = MediaMessageRecorderState.IDLE; }
    }

    private class Fixture : Object {
        public Backend backend = new Backend();
        public Adw.Window window = new Adw.Window();
        public Gtk.Button anchor = new Gtk.Button.from_icon_name("microphone-sensitivity-medium-symbolic");
        public VoiceRecorderPopover? popover;
        public int sends = 0;
        public int discards = 0;
        private bool window_disposed = false;

        public Fixture() {
            popover = new VoiceRecorderPopover(backend);
            ((!) popover).set_parent(anchor);
            ((!) popover).send_clicked.connect(() => { sends++; });
            ((!) popover).cancel_clicked.connect(() => { discards++; });
            var content = new Gtk.Box(Orientation.VERTICAL, 0) { halign = Align.CENTER, valign = Align.CENTER };
            content.append(anchor);
            window.content = content;
            window.set_default_size(380, 260);
        }
        public void show() throws Error {
            window.present();
            wait_for(() => anchor.get_mapped(), "Popover anchor is mapped");
            ((!) popover).prepare_for_recording();
            ((!) popover).popup();
            wait_for(() => ((!) popover).get_mapped(), "Recording popover is mapped");
            iterate_for(60);
        }
        public void hide() throws Error {
            ((!) popover).popdown();
            wait_for(() => !((!) popover).get_mapped(), "Recording popover is unmapped");
        }
        public Gtk.Button button(string label) {
            var button = find_button((!) popover, GLib.dgettext("dino", label));
            assert(button != null);
            return (!) button;
        }
        public void release_popover() {
            if (popover == null) return;
            ((!) popover).popdown();
            if (((!) popover).get_parent() != null) ((!) popover).unparent();
            popover = null;
        }
        public void close() {
            release_popover();
            if (!window_disposed) {
                window_disposed = true;
                window.content = null;
                window.destroy();
                // The fixture retains the root; complete GTK focus cleanup.
                window.dispose();
            }
            iterate_for(40);
        }
    }

    private void test_controls() {
        var f = new Fixture();
        try {
            f.show();
            fail_if_not(has_label((!) f.popover, GLib.dgettext("dino", "Recording voice message")), "Recording status is visible text, not only a red dot");
            fail_if_not(has_label((!) f.popover, "0:00 / 5:00"), "The recording limit is visible from the start");
            var send = f.button("Send");
            var discard = f.button("Discard");
            fail_if_not_eq_str(GLib.dgettext("dino", "Send voice message"), send.tooltip_text ?? "", "Send action has a clear tooltip");
            fail_if_not_eq_str(GLib.dgettext("dino", "Discard voice message"), discard.tooltip_text ?? "", "Discard action has a clear tooltip");
            fail_if_not(send.sensitive && discard.sensitive, "Recording actions are available during capture");
            Gtk.DrawingArea? waveform = find_waveform((!) f.popover);
            if (fail_if_not(waveform != null, "The real recording waveform exists")) return;
            fail_if_not_eq_int(44, ((!) waveform).get_height(), "Recording waveform remains compact");
            string empty = waveform_hash(f, (!) waveform);
            if (fail_if_not(empty != "", "The initial waveform has a rendered frame")) return;
            f.backend.duration_changed("1:23");
            f.backend.level_changed(1.0);
            fail_if_not(has_label((!) f.popover, "1:23 / 5:00"), "Elapsed time updates without losing the limit");
            wait_for(() => {
                string updated = waveform_hash(f, (!) waveform);
                return updated != "" && updated != empty;
            }, "Actual Cairo waveform renders captured input");
            // Screenshot support remains isolated from production capture.
            if (Environment.get_variable("DINOX_VOICE_RECORDER_TEST_SCREENSHOT_HOLD") == "1") {
                // Capture a steady visible indicator; production keeps its
                // normal animation preference and reduced-motion behavior.
                Gtk.Settings.get_default().gtk_enable_animations = false;
                f.window.title = "DinoX voice recorder fixture";
                f.backend.duration_changed("0:23");
                for (int i = 0; i < 60; i++) {
                    f.backend.level_changed(0.12 + 0.68 * Math.fabs(Math.sin(i * 0.37)));
                }
                GLib.Test.message("Screenshot fixture ready: DinoX voice recorder fixture");
                iterate_for(15000);
            }
            f.backend.duration_changed("4:35 (-25s)");
            fail_if_not(has_label((!) f.popover, "4:35 / 5:00"), "The existing backend countdown displays as elapsed and limit");
            f.hide();
            f.backend.duration_changed("4:59 (-1s)");
            f.backend.level_changed(0.5);
            fail_if_not(has_label((!) f.popover, "4:35 / 5:00"), "Late hidden callbacks do not change the recording controls");
            f.show();
            fail_if_not(has_label((!) f.popover, "0:00 / 5:00"), "Reopening clears elapsed time");
            wait_for(() => waveform_hash(f, (!) waveform) == empty, "Reopening clears the old waveform samples");
            ((!) f.popover).set_direction(TextDirection.RTL);
            iterate_for(40);
            fail_if_not(f.button("Send").get_mapped() && f.button("Discard").get_mapped(), "Both actions remain visible in RTL layout");
            fail_if_not(((!) waveform).get_width() > 0, "RTL recording retains a usable waveform width");
            fail_if_not_eq_int(0, f.backend.stop_count, "UI reset does not finalize capture by itself");
            fail_if_not_eq_int(0, f.backend.cancel_count, "UI hiding does not change the controller-owned cancel behavior");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { f.close(); }
    }

    private void test_actions() {
        var f = new Fixture();
        try {
            f.show();
            var send = f.button("Send");
            send.clicked();
            send.clicked();
            fail_if_not_eq_int(0, f.sends, "Send waits for the native GTK pointer event to finish");
            wait_for(() => f.sends == 1, "One send is dispatched");
            f.backend.max_duration_reached();
            iterate_for(30);
            fail_if_not_eq_int(1, f.sends, "The duration limit cannot duplicate an already dispatched send");
            f.hide();
            f.backend.max_duration_reached();
            iterate_for(30);
            fail_if_not_eq_int(1, f.sends, "A hidden popover ignores the recording limit callback");
            f.show();
            f.backend.max_duration_reached();
            fail_if_not_eq_int(1, f.sends, "Automatic send is deferred as well");
            wait_for(() => f.sends == 2, "A new active recording can send at its limit");
            f.hide();
            f.show();
            f.backend.current_state = MediaMessageRecorderState.IDLE;
            f.backend.max_duration_reached();
            iterate_for(30);
            fail_if_not_eq_int(2, f.sends, "The limit callback cannot send an idle recorder");
            f.backend.current_state = MediaMessageRecorderState.RECORDING;
            f.backend.duration_changed("0:01");
            send.clicked();
            f.backend.current_state = MediaMessageRecorderState.IDLE;
            iterate_for(30);
            fail_if_not_eq_int(2, f.sends, "A queued send is ignored if capture stops before dispatch");
            f.backend.current_state = MediaMessageRecorderState.RECORDING;
            f.backend.duration_changed("0:01");
            send.clicked();
            ((!) f.popover).popdown();
            iterate_for(40);
            fail_if_not_eq_int(2, f.sends, "Closing the popover cancels a pending send");
            wait_for(() => !((!) f.popover).get_mapped(), "Closed pending-send popover is unmapped");
            f.show();
            var discard = f.button("Discard");
            discard.clicked();
            discard.clicked();
            fail_if_not_eq_int(0, f.discards, "Discard also waits for the triggering native event");
            wait_for(() => f.discards == 1, "Discard is dispatched once");
            fail_if_not_eq_int(0, f.backend.stop_count, "The popover emits intent instead of directly stopping capture");
            fail_if_not_eq_int(0, f.backend.cancel_count, "The chat controller retains ownership of capture cancellation");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { f.close(); }
    }

    private void test_release() {
        var f = new Fixture();
        try {
            f.show();
            f.backend.duration_changed("0:03");
            f.backend.level_changed(0.5);
            WeakRef popover_weak = WeakRef((!) f.popover);
            f.hide();
            f.close();
            wait_for(() => popover_weak.get() == null,
                "Closed popover releases despite retained backend, Cairo callbacks and blink source");
            f.backend.duration_changed("0:04");
            f.backend.level_changed(0.7);
            f.backend.max_duration_reached();
            iterate_for(30);
            fail_if_not_eq_int(0, f.sends, "Detached late callbacks cannot send a voice message");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { f.close(); }
    }

    private static Gtk.Button? find_button(Gtk.Widget parent, string label) {
        var button = parent as Gtk.Button;
        if (button != null && button.child is Adw.ButtonContent &&
                ((Adw.ButtonContent) button.child).label == label) return button;
        for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_button((!) child, label);
            if (found != null) return found;
        }
        return null;
    }
    private static bool has_label(Gtk.Widget parent, string text) {
        if (parent is Gtk.Label && ((Gtk.Label) parent).label == text) return true;
        for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            if (has_label((!) child, text)) return true;
        }
        return false;
    }
    private static Gtk.DrawingArea? find_waveform(Gtk.Widget parent) {
        if (parent is Gtk.DrawingArea && parent.has_css_class("voice-recorder-waveform")) return (Gtk.DrawingArea) parent;
        for (Gtk.Widget? child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_waveform((!) child);
            if (found != null) return found;
        }
        return null;
    }
    private static string waveform_hash(Fixture f, Gtk.DrawingArea waveform) {
        var paintable = new Gtk.WidgetPaintable(waveform);
        var snapshot = new Gtk.Snapshot();
        paintable.snapshot(snapshot, waveform.get_width(), waveform.get_height());
        Gsk.RenderNode? node = snapshot.to_node();
        Gsk.Renderer? renderer = f.window.get_renderer();
        if (node == null || renderer == null) return "";
        var texture = ((!) renderer).render_texture((!) node, null);
        size_t stride = texture.get_width() * 4;
        uint8[] pixels = new uint8[stride * texture.get_height()];
        texture.download(pixels, stride);
        return Checksum.compute_for_data(ChecksumType.SHA256, pixels);
    }
    private static void wait_for(owned Ready ready, string reason, uint timeout_ms = 3000) throws Error {
        int64 deadline = get_monotonic_time() + timeout_ms * 1000;
        while (!ready()) {
            if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT(reason);
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }
    private static void iterate_for(uint ms) {
        int64 deadline = get_monotonic_time() + ms * 1000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }
}

}
