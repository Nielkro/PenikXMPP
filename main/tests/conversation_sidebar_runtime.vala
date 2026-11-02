using Gtk;

namespace Dino.Ui.Test {

[CCode (cname = "gtk_test_accessible_check_property", cheader_filename = "gtk/gtk.h")]
private static extern string? check_sidebar_accessible_property(Accessible accessible,
    AccessibleProperty property, ...);

class ConversationSidebarRuntimeTest : Gee.TestCase {
    private delegate bool Ready();

    public ConversationSidebarRuntimeTest() {
        base("ConversationSidebarRuntime");
        add_test("manual_compaction_preserves_chat_and_restores_original_widths", test_manual_compaction);
        add_test("resize_and_native_back_preserve_navigation_and_compact_choice", test_adaptive_navigation);
        add_test("unavailable_chats_restore_full_layout_without_navigation", test_unavailable);
        add_test("handle_controls_remain_usable_across_theme_direction_and_height", test_controls);
        add_test("layout_releases_with_live_widgets_and_disconnects_callbacks", test_lifetime);
    }

    private class Fixture : Object {
        public Adw.Window window = new Adw.Window() { width_request = 500, height_request = 160 };
        public Adw.NavigationSplitView navigation = new Adw.NavigationSplitView();
        public Adw.HeaderBar full_header = new Adw.HeaderBar();
        public Adw.HeaderBar chat_header = new Adw.HeaderBar();
        public Box toggle_strip = new Box(Orientation.VERTICAL, 0);
        public Button toggle_button = new Button.from_icon_name("pan-start-symbolic");
        public WindowControls compact_controls = new WindowControls(PackType.START);
        public MenuButton compact_menu = new MenuButton() { icon_name = "open-menu-symbolic" };
        public Button header_action = new Button.from_icon_name("list-add-symbolic");
        public ListBox contacts = new ListBox() { selection_mode = SelectionMode.SINGLE };
        public ListBoxRow selected_row = new ListBoxRow() { child = new Label("A") };
        public Label chat = new Label("Existing chat") { hexpand = true, vexpand = true };
        public Entry composer = new Entry() { text = "Unsent draft", hexpand = true };
        public Box chat_body = new Box(Orientation.VERTICAL, 0);
        public Adw.ToolbarView chat_toolbar = new Adw.ToolbarView() { hexpand = true };
        public ConversationSidebarLayout? layout;
        public unowned ConversationSidebarLayout state { get { return (!) layout; } }

        public Fixture(bool show_content = true) {
            window.add_css_class("dino-main");
            window.set_default_size(1000, 420);
            full_header.show_title = false;
            full_header.pack_start(header_action);
            full_header.pack_end(new MenuButton() { icon_name = "open-menu-symbolic" });
            contacts.append(selected_row);
            contacts.append(new ListBoxRow() { child = new Label("B") });
            contacts.select_row(selected_row);
            var sidebar = new Adw.ToolbarView();
            sidebar.add_top_bar(full_header);
            sidebar.content = new ScrolledWindow() {
                child = contacts, vexpand = true,
                hscrollbar_policy = PolicyType.NEVER
            };
            toggle_strip.add_css_class("sidebar-toggle-strip");
            toggle_button.add_css_class("sidebar-toggle-button");
            toggle_button.has_frame = false;
            toggle_button.valign = Align.CENTER;
            toggle_button.vexpand = true;
            toggle_strip.append(toggle_button);
            compact_controls.decoration_layout = "close:";
            chat_header.pack_start(compact_controls);
            chat_header.pack_end(compact_menu);
            chat_toolbar.add_top_bar(chat_header);
            chat_body.append(chat);
            chat_body.append(composer);
            chat_toolbar.content = chat_body;
            var content = new Box(Orientation.HORIZONTAL, 0);
            content.append(toggle_strip);
            content.append(chat_toolbar);
            navigation.sidebar = new Adw.NavigationPage.with_tag(sidebar, "Chats", "sidebar");
            navigation.content = new Adw.NavigationPage.with_tag(content, "Existing chat", "chat");
            navigation.min_sidebar_width = 240;
            navigation.max_sidebar_width = 320;
            navigation.sidebar_width_fraction = 0.3;
            navigation.show_content = show_content;
            window.content = navigation;
            var breakpoint = new Adw.Breakpoint(Adw.BreakpointCondition.parse("max-width: 860sp"));
            breakpoint.add_setter(navigation, "collapsed", true);
            window.add_breakpoint(breakpoint);
            layout = new ConversationSidebarLayout(navigation, full_header,
                toggle_strip, toggle_button, compact_controls, compact_menu);
        }

        public void present() throws Error {
            window.present();
            wait_for(() => chat.get_mapped() && !navigation.collapsed,
                "the wide fixture must show its existing chat");
            iterate_for(60);
        }

        public void resize(int width, int height, bool collapsed) throws Error {
            window.set_default_size(width, height);
            wait_for(() => navigation.collapsed == collapsed &&
                (collapsed ? window.get_width() <= 860 : window.get_width() > 860),
                "the real window must reach the requested breakpoint and width");
            iterate_for(80);
        }

        public void close() {
            layout = null;
            window.content = null;
            window.destroy();
            window.dispose();
            iterate_for(20);
        }
    }

    private void test_manual_compaction() {
        var fixture = new Fixture();
        try {
            fixture.present();
            int transitions = 0;
            fixture.state.compact_changed.connect(() => transitions++);
            fixture.toggle_button.clicked();
            wait_for(() => fixture.state.compact && fixture.contacts.get_width() <= 74,
                "manual compaction must allocate an avatar-width sidebar");
            fail_if(!fixture.state.compact_requested || fixture.navigation.collapsed,
                "manual compaction must stay separate from adaptive navigation");
            fail_if(!fixture.navigation.show_content || !fixture.chat.get_mapped(),
                "compacting the chat list must leave the existing chat visible");
            fail_if(fixture.full_header.visible || !fixture.compact_menu.get_mapped(),
                "the compact layout must replace the full sidebar header with usable chat controls");
            fail_if(fixture.contacts.get_selected_row() != fixture.selected_row ||
                fixture.composer.text != "Unsent draft",
                "compaction must preserve the selected conversation and draft");
            fail_if(fixture.navigation.min_sidebar_width != 72 || fixture.navigation.max_sidebar_width != 72,
                "manual compaction must use the bounded 72px rail");
            fixture.state.compact_requested = true;
            fail_if_not_eq_int(1, transitions, "repeating the current preference must not repeat transitions");
            fixture.toggle_button.clicked();
            wait_for(() => !fixture.state.compact && fixture.full_header.get_mapped(),
                "expanding must restore the sidebar header");
            fail_if(fixture.navigation.min_sidebar_width != 240 ||
                fixture.navigation.max_sidebar_width != 320 ||
                Math.fabs(fixture.navigation.sidebar_width_fraction - 0.3) > 0.0001,
                "expansion must restore the original non-default sizing configuration");
            fail_if(fixture.compact_menu.visible || fixture.compact_controls.visible,
                "expansion must return window and menu controls to the original header");
            fail_if_not_eq_int(2, transitions, "each manual change must publish one effective transition");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_adaptive_navigation() {
        var fixture = new Fixture();
        try {
            fixture.present();
            fixture.state.compact_requested = true;
            for (int cycle = 0; cycle < 2; cycle++) {
                fixture.resize(500, 320, true);
                wait_for(() => fixture.chat.get_mapped(), "shrinking must keep the open chat visible");
                fail_if(!fixture.navigation.show_content || fixture.state.compact ||
                    !fixture.state.compact_requested || fixture.toggle_strip.visible,
                    "the narrow view must keep navigation and remember the manual preference");
                fail_if(fixture.navigation.min_sidebar_width != 240 ||
                    fixture.navigation.max_sidebar_width != 320,
                    "the single-pane layout must restore full row sizing");
                navigate_and_wait_shown(fixture.chat_header, fixture.navigation.sidebar, null);
                wait_for(() => !fixture.navigation.show_content && fixture.contacts.get_mapped() &&
                    !fixture.chat.get_mapped(), "native Back must show the contact list");
                fixture.resize(1000, 420, false);
                wait_for(() => fixture.state.compact && fixture.chat.get_mapped(),
                    "wide layout must restore the manual compact preference");
                fail_if(fixture.navigation.show_content,
                    "expansion must not overwrite the user's native Back selection");
                fixture.resize(500, 320, true);
                wait_for(() => fixture.contacts.get_mapped() && !fixture.chat.get_mapped(),
                    "a second collapse must retain the Back selection");
                fail_if_not(fixture.full_header.get_mapped(),
                    "the narrow contact list must regain its full header");
                navigate_and_wait_shown(fixture.full_header, fixture.navigation.content, "chat");
                wait_for(() => fixture.navigation.show_content && fixture.chat.get_mapped(),
                    "reopening must reveal the same existing chat widget");
                fixture.resize(1000, 420, false);
                fail_if(fixture.contacts.get_selected_row() != fixture.selected_row ||
                    fixture.composer.text != "Unsent draft",
                    "responsive navigation must preserve the selected row and draft");
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_unavailable() {
        var fixture = new Fixture(false);
        try {
            fixture.present();
            fixture.state.compact_requested = true;
            fixture.state.available = false;
            wait_for(() => fixture.full_header.get_mapped() && !fixture.toggle_strip.visible,
                "a welcome or empty-chat state must restore the full header");
            fail_if(fixture.state.compact || !fixture.state.compact_requested || fixture.navigation.show_content,
                "an unavailable chat list must retain the preference without creating navigation");
            fixture.toggle_button.clicked();
            fail_if_not(fixture.state.compact_requested,
                "a hidden unavailable handle must not change the retained choice");
            fixture.resize(500, 320, true);
            fail_if(fixture.navigation.show_content || fixture.chat.get_mapped(),
                "empty-state resizes must not open a chat automatically");
            fixture.state.available = true;
            fail_if(fixture.state.compact || fixture.toggle_strip.visible,
                "restoring conversations while narrow must still use native single-pane navigation");
            fixture.resize(1000, 420, false);
            wait_for(() => fixture.state.compact, "the retained preference must return on a wide available view");
            fail_if(fixture.navigation.show_content,
                "restoring the manual preference must not force content selection");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private void test_controls() {
        var style = Adw.StyleManager.get_default();
        Adw.ColorScheme previous_scheme = style.color_scheme;
        TextDirection previous_direction = Widget.get_default_direction();
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            fixture.present();
            foreach (Adw.ColorScheme scheme in new Adw.ColorScheme[] { Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                style.color_scheme = scheme;
                foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
                    Widget.set_default_direction(direction);
                    fixture.resize(1000, 300, false);
                    fail_if_not(fixture.composer.grab_focus(), "the draft composer must accept keyboard focus");
                    fixture.toggle_button.clicked();
                    wait_for(() => fixture.state.compact && fixture.toggle_button.get_mapped() && fixture.contacts.get_width() <= 74,
                        "the compact handle must map in each theme and direction");
                    fail_if_not(focus_inside(fixture.window, fixture.composer),
                        "pointer-style activation must not steal focus from the unsent draft");
                    fail_if(fixture.toggle_button.focus_on_click,
                        "the pointer handle must preserve normal composer focus");
                    fail_if(fixture.toggle_button.icon_name != "pan-end-symbolic" ||
                        fixture.toggle_button.get_direction() != direction,
                        "GTK must render the logical expand icon using its native RTL variant");
                    assert_handle_bounds(fixture);
                    wait_for(() => !fixture.compact_controls.empty && fixture.compact_controls.get_mapped(),
                        "left-side native window controls must remain available when the original header is hidden");
                    fixture.compact_controls.decoration_layout = ":close";
                    wait_for(() => fixture.compact_controls.empty && !fixture.compact_controls.visible,
                        "an empty native control group must not occupy compact header space");
                    fixture.compact_controls.decoration_layout = "close:";
                    wait_for(() => !fixture.compact_controls.empty && fixture.compact_controls.get_mapped(),
                        "returning native left-side controls must be shown again");
                    string expand = GLib.dgettext("dino", "Expand chat list");
                    if (Util.use_tooltips()) fail_if(fixture.toggle_button.tooltip_text != expand,
                        "the compact handle must describe its next action");
                    if (Environment.get_variable("GTK_A11Y") == "test") {
                        fail_if(check_sidebar_accessible_property(fixture.toggle_button,
                            AccessibleProperty.LABEL, expand) != null,
                            "the accessible label must describe expansion");
                    }
                    fail_if_not(fixture.toggle_button.grab_focus(), "the handle must accept native keyboard focus");
                    fixture.toggle_button.activate();
                    wait_for(() => !fixture.state.compact, "keyboard activation must expand the list");
                    fail_if_not(focus_inside(fixture.window, fixture.toggle_button),
                        "keyboard activation must retain a reachable focused handle");
                    if (Environment.get_variable("GTK_A11Y") != "none")
                        fail_if(fixture.toggle_button.get_accessible_role() != AccessibleRole.BUTTON,
                            "resizing and theme changes must preserve the native button role");
                    wait_for(() => fixture.header_action.get_mapped(), "the expanded sidebar action must map before the focus test");
                    fail_if_not(fixture.header_action.grab_focus(), "the original header action must accept focus");
                    fail_if_not(focus_inside(fixture.window, fixture.header_action), "the original header must own focus before it is hidden");
                    fixture.state.compact_requested = true;
                    fail_if_not(focus_inside(fixture.window, fixture.toggle_button),
                        "hiding a focused sidebar-header control must move focus to the remaining handle");
                    fixture.state.compact_requested = false;
                }
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (fixture != null) fixture.close();
            Widget.set_default_direction(previous_direction);
            style.color_scheme = previous_scheme;
        }
    }

    private void assert_handle_bounds(Fixture fixture) {
        Graphene.Rect strip;
        Graphene.Rect toolbar;
        Graphene.Rect handle;
        fail_if_not(fixture.toggle_strip.compute_bounds(fixture.window, out strip), "the strip must have window bounds");
        fail_if_not(fixture.chat_toolbar.compute_bounds(fixture.window, out toolbar), "the chat must have window bounds");
        fail_if_not(fixture.toggle_button.compute_bounds(fixture.window, out handle), "the handle must have window bounds");
        fail_if(strip.size.width <= 0 || strip.size.width > 16 || handle.size.height < 32,
            "the separately allocated handle must remain compact and usable at short heights");
        bool separate = strip.origin.x + strip.size.width <= toolbar.origin.x + 1 ||
            toolbar.origin.x + toolbar.size.width <= strip.origin.x + 1;
        fail_if_not(separate, "the handle strip must not overlap the chat or message actions");
        fail_if(handle.origin.y < 0 || handle.origin.y + handle.size.height > fixture.window.get_height() + 1,
            "the handle must stay inside the visible short window");
    }

    private void test_lifetime() {
        var fixture = new Fixture();
        try {
            fixture.present();
            fixture.state.compact_requested = true;
            WeakRef weak_layout = WeakRef(fixture.layout);
            fixture.layout = null;
            wait_for(() => weak_layout.get() == null,
                "retaining native widgets must not retain the layout through its signal callbacks");
            double width = fixture.navigation.min_sidebar_width;
            fixture.toggle_button.clicked();
            fixture.compact_controls.decoration_layout = ":close";
            fixture.resize(500, 320, true);
            fail_if(fixture.navigation.min_sidebar_width != width,
                "disposed layout callbacks must not mutate surviving navigation widgets");
        } catch (Error error) { fail_if_reached(error.message); }
        finally { fixture.close(); }
    }

    private static void drain() {
        var context = MainContext.default();
        while (context.pending()) context.iteration(false);
    }
    private static void navigate_and_wait_shown(Widget trigger, Adw.NavigationPage page, string? tag) throws Error {
        // Mapping starts before the native navigation animation finishes.
        // Wait for the actual completed action before testing a later resize.
        bool shown = false;
        ulong handler = page.shown.connect(() => shown = true);
        try {
            bool invoked = tag == null
                ? trigger.activate_action("navigation.pop", null)
                : trigger.activate_action("navigation.push", "s", tag);
            if (!invoked) throw new IOError.FAILED("The native navigation action is not available");
            wait_for(() => shown && page.get_mapped(),
                "the native navigation action must fully show its target page");
        } finally {
            page.disconnect(handler);
        }
    }
    private static bool focus_inside(Gtk.Window window, Widget widget) {
        Widget? focused = window.get_focus();
        return focused != null && (focused == widget || focused.is_ancestor(widget));
    }
    private static void iterate_for(uint milliseconds) {
        int64 deadline = get_monotonic_time() + milliseconds * 1000;
        while (get_monotonic_time() < deadline) {
            drain();
            Thread.usleep(1000);
        }
    }
    private static void wait_for(Ready ready, string reason, uint timeout_ms = 4000) throws Error {
        int64 deadline = get_monotonic_time() + timeout_ms * 1000;
        while (!ready()) {
            if (get_monotonic_time() >= deadline) throw new IOError.TIMED_OUT(reason);
            drain();
            Thread.usleep(1000);
        }
    }
}

}
