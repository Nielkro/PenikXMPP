using Gtk;
using Dino.Ui.ConversationSummary;

namespace Dino.Ui.Test {

class FrameRenderQueueRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public FrameRenderQueueRuntimeTest() {
        base("FrameRenderQueueRuntime");
        add_test("bottom_anchor_is_correct_in_each_painted_frame", test_bottom_anchor);
        add_test("chat_switch_cancels_previous_scroll_animation", test_scroll_cancel);
        add_test("narrow_row_activation_yields_to_paint_between_batches", test_navigation);
        add_test("cheap_rows_also_yield_before_accumulating_layout_work", test_cheap_rows);
        add_test("hidden_page_waits_and_cancel_discards_old_rows", test_hidden_cancel);
        add_test("reload_inside_callback_does_not_consume_replacement_batch", test_reentrant_reload);
        add_test("pending_tick_does_not_retain_queue", test_lifetime);
    }

    private class Fixture : Object {
        public Adw.Window window = new Adw.Window();
        public Adw.NavigationSplitView navigation = new Adw.NavigationSplitView() { collapsed = true };
        public Adw.HeaderBar header = new Adw.HeaderBar();
        public ListBox contacts = new ListBox();
        public ListBoxRow row = new ListBoxRow() { child = new Label("Алексей — Test chat") };
        public Box messages = new Box(Orientation.VERTICAL, 4);
        public FrameRenderQueue queue;

        public Fixture() {
            window.set_default_size(500, 400);
            var sidebar = new Adw.ToolbarView();
            sidebar.add_top_bar(new Adw.HeaderBar());
            contacts.append(row);
            sidebar.content = contacts;
            var chat = new Adw.ToolbarView();
            chat.add_top_bar(header);
            chat.content = new ScrolledWindow() {
                child = messages, vexpand = true, hscrollbar_policy = PolicyType.NEVER
            };
            navigation.sidebar = new Adw.NavigationPage.with_tag(sidebar, "Chats", "sidebar");
            navigation.content = new Adw.NavigationPage.with_tag(chat, "Алексей", "chat");
            window.content = navigation;
            queue = new FrameRenderQueue(messages);
            window.present();
        }

        public void close() {
            queue.dispose();
            window.content = null;
            window.destroy();
            iterate_for(30);
        }
    }

    private void test_bottom_anchor() {
        var messages = new Box(Orientation.VERTICAL, 0);
        var scrolled = new ScrolledWindow() { child = messages };
        var layout = new Box(Orientation.VERTICAL, 0) { layout_manager = new ChatScrollLayout(scrolled) };
        layout.append(scrolled);
        var window = new Gtk.Window() { child = layout, default_width = 400, default_height = 250 };
        var motion = new ChatScrollMotion(scrolled);
        var queue = new FrameRenderQueue(messages);
        int painted = 0;
        ulong changed = scrolled.vadjustment.changed.connect(motion.snap_to_bottom);
        window.present();
        var clock = window.get_frame_clock();
        ulong after_paint = clock.after_paint.connect(() => {
            var a = scrolled.vadjustment;
            if (a.upper <= a.page_size) return;
            painted++;
            fail_if((a.value - (a.upper - a.page_size)).abs() > 0.5,
                "no frame may paint a stale bottom position while queued rows grow");
            Graphene.Rect last_row;
            fail_if_not(messages.get_last_child().compute_bounds(scrolled, out last_row));
            fail_if((last_row.origin.y + last_row.size.height - scrolled.get_height()).abs() > 0.5,
                "the last row must actually be allocated at the viewport bottom before painting");
        });
        try {
            for (int i = 0; i < 40; i++) queue.add(() => messages.append(new Label("Message") { height_request = 45 }));
            wait_for(() => !queue.pending && painted > 3);
            messages.get_last_child().height_request = 160;
            iterate_for(80);
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            clock.disconnect(after_paint);
            scrolled.vadjustment.disconnect(changed);
            queue.cancel();
            window.destroy();
        }
    }

    private void test_scroll_cancel() {
        var scrolled = new ScrolledWindow() { child = new Box(Orientation.VERTICAL, 0) { height_request = 3000 } };
        var window = new Gtk.Window() { child = scrolled, default_height = 250 };
        var motion = new ChatScrollMotion(scrolled);
        bool completed = false;
        var settings = Gtk.Settings.get_default();
        bool animations = settings.gtk_enable_animations;
        settings.gtk_enable_animations = true;
        window.present();
        try {
            wait_for(() => scrolled.vadjustment.upper > 2500);
            motion.animate_to(2000, 500, () => completed = true);
            wait_for(() => scrolled.vadjustment.value > 0);
            motion.cancel();
            scrolled.vadjustment.value = 300;
            iterate_for(600);
            fail_if(completed, "an old chat must not receive completion callbacks");
            fail_if((scrolled.vadjustment.value - 300).abs() > 0.5,
                "a cancelled old animation must not scroll the next chat");
            // Search/reply jumps still finish normally, including the
            // synchronous completion used by reduced-motion preferences.
            foreach (bool enabled in new bool[] { true, false }) {
                settings.gtk_enable_animations = enabled;
                completed = false;
                scrolled.vadjustment.value = 300;
                motion.animate_to(750, 30, () => completed = true);
                wait_for(() => completed);
                fail_if((scrolled.vadjustment.value - 750).abs() > 0.5);
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally { motion.cancel(); window.destroy(); settings.gtk_enable_animations = animations; }
    }

    private void test_navigation() {
        var fixture = new Fixture();
        ulong activation_handler = 0;
        ulong paint_handler = 0;
        Gdk.FrameClock? clock = null;
        try {
            wait_for(() => fixture.row.get_mapped());
            int completed = 0;
            int intermediate_paints = 0;
            int64 last_frame = -1;
            clock = fixture.window.get_frame_clock();
            paint_handler = clock.after_paint.connect(() => {
                if (completed > 0 && completed < 12) intermediate_paints++;
            });
            activation_handler = fixture.contacts.row_activated.connect(() => {
                for (int i = 0; i < 12; i++) {
                    fixture.queue.add(() => {
                        int64 frame = clock.get_frame_counter();
                        fail_if(frame == last_frame,
                            "a row exceeding the frame budget must yield before the next row");
                        last_frame = frame;
                        // Simulate an indivisible expensive row. Check paint
                        // interleaving rather than machine-dependent speed.
                        Thread.usleep(6000);
                        fixture.messages.append(new Label("Nachricht — Привет — مرحبا 👋") {
                            wrap = true, hexpand = true, xalign = 0
                        });
                        completed++;
                    });
                }
                fixture.navigation.show_content = true;
            });
            fixture.row.activate();
            wait_for(() => completed == 12 && !fixture.queue.pending);
            fail_if(intermediate_paints < 2,
                "narrow navigation must paint while initial rows are populated");
            fail_if(!fixture.messages.get_mapped() || !fixture.navigation.show_content);
            GLib.Test.message("12 initial rows; %d intermediate paints", intermediate_paints);
            clock.disconnect(paint_handler);
            paint_handler = 0;
            fail_if_not(fixture.header.activate_action("navigation.pop", null));
            wait_for(() => !fixture.messages.get_mapped());
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (activation_handler != 0) fixture.contacts.disconnect(activation_handler);
            if (paint_handler != 0) clock.disconnect(paint_handler);
            fixture.close();
        }
    }

    private void test_cheap_rows() {
        var fixture = new Fixture();
        try {
            int completed = 0;
            int frames = 0;
            int64 last_frame = -1;
            for (int i = 0; i < 40; i++) {
                fixture.queue.add(() => {
                    int64 frame = fixture.window.get_frame_clock().get_frame_counter();
                    if (frame != last_frame) frames++;
                    last_frame = frame;
                    completed++;
                });
            }
            fixture.navigation.show_content = true;
            wait_for(() => completed == 40);
            fail_if(frames < 2,
                "cheap constructors must not put the whole chat's layout work in one frame");
            GLib.Test.message("40 cheap row callbacks spread over %d frames", frames);
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_hidden_cancel() {
        var fixture = new Fixture();
        try {
            wait_for(() => fixture.row.get_mapped());
            int stale = 0;
            int current = 0;
            fixture.queue.add(() => stale++);
            iterate_for(60);
            fail_if(stale != 0, "hidden rows must wait for a mapped viewport");
            fixture.queue.cancel();
            fixture.queue.add(() => current++);
            fixture.navigation.show_content = true;
            wait_for(() => current == 1);
            fail_if(stale != 0 || fixture.queue.pending,
                "changing chats must discard every old render request");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_reentrant_reload() {
        var fixture = new Fixture();
        try {
            int stale = 0;
            int replacement = 0;
            int64 old_frame = -1;
            fixture.queue.add(() => {
                old_frame = fixture.window.get_frame_clock().get_frame_counter();
                fixture.queue.cancel();
                fixture.queue.add(() => {
                    fail_if(fixture.window.get_frame_clock().get_frame_counter() == old_frame,
                        "a cancelled frame must not drain the replacement conversation");
                    replacement++;
                });
            });
            fixture.queue.add(() => stale++);
            fixture.navigation.show_content = true;
            wait_for(() => replacement == 1);
            fail_if(stale != 0 || fixture.queue.pending);
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_lifetime() {
        var widget = new Box(Orientation.VERTICAL, 0);
        FrameRenderQueue? queue = new FrameRenderQueue(widget);
        var queue_ref = WeakRef(queue);
        int calls = 0;
        queue.add(() => calls++);
        queue = null;
        fail_if(queue_ref.get() != null, "a GTK tick callback must not keep the queue alive");
        var window = new Adw.Window() { content = widget };
        window.present();
        iterate_for(60);
        fail_if(calls != 0, "disposing the queue must cancel its pending tick");
        window.destroy();
    }

    private static void iterate_for(uint milliseconds) {
        int64 until = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < until) {
            MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
    }

    private static void wait_for(Ready ready) throws Error {
        int64 deadline = get_monotonic_time() + 4000000;
        while (!ready()) {
            if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT("UI condition timed out");
            MainContext.default().iteration(false);
            Thread.usleep(1000);
        }
    }
}

}
