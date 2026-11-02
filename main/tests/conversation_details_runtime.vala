using Gtk;

namespace Dino.Ui.Test {

// Exercise the actual details dialog, template, model and preference factory.
// No accounts are connected and no user profile or server data is used.
class ConversationDetailsRuntimeTest : Gee.TestCase {
    public ConversationDetailsRuntimeTest() {
        base("ConversationDetailsRuntime");
        add_test("public_and_private_room_tabs_fit_narrow_parent", test_room_layout);
        add_test("contact_actions_reflow_and_restore_without_state_changes", test_contact_layout);
        add_test("native_tab_focus_scrolls_to_hidden_encryption_tab", test_tab_focus);
        add_test("all_preference_model_variants_fit_and_keep_values", test_preference_models);
        add_test("close_cancels_pending_about_rebuild", test_close_pending);
        add_test("row_updates_keep_encryption_root_and_batch_settings", test_stable_encryption_page);
        add_test("close_cancels_pending_settings_and_administration", test_close_pending_preferences);
        add_test("contact_removal_waits_for_success", () => test_contact_removal(0));
        add_test("contact_removal_rejection_remains_visible", () => test_contact_removal(1));
        add_test("contact_removal_closed_dialog_ignores_late_failure", () => test_contact_removal(2));
        add_test("native_details_visual_fixture", test_visual_fixture);
    }

    private class Fixture : Object {
        public Adw.Window window;
        public ConversationDetails.Dialog dialog;
        private TextDirection previous_direction;
        private bool closed = false;

        public Fixture(int width, bool room, TextDirection direction = TextDirection.LTR,
                string? initial_page = null) {
            previous_direction = Widget.get_default_direction();
            Widget.set_default_direction(direction);
            window = new Adw.Window() {
                default_width = width, default_height = 700,
                title = "DinoX isolated responsive details fixture"
            };
            window.set_content(new Box(Orientation.VERTICAL, 0));
            dialog = new ConversationDetails.Dialog();
            dialog.set_direction(direction);
            dialog.model.avatar = new ViewModel.CompatAvatarPictureModel(null)
                .add(room ? "R" : "C", "details-fixture");
            dialog.model.name = room
                ? "XMPP DinoX Client Support – a long room name"
                : "A very long contact display name in the current account";
            dialog.model.account_jid = "a-long-multi-account-address-with-an-explicit-current-account@example.test";
            dialog.model.pinned = true;
            dialog.model.notification_options = room
                ? ViewModel.ConversationDetails.NotificationOptions.ON_HIGHLIGHT_OFF
                : ViewModel.ConversationDetails.NotificationOptions.ON_OFF;
            dialog.model.notification = room
                ? ViewModel.ConversationDetails.NotificationSetting.HIGHLIGHT
                : ViewModel.ConversationDetails.NotificationSetting.OFF;
            dialog.model.notification_is_default = false;
            dialog.model.show_blocked = !room;
            dialog.model.show_remove_contact = !room;
            dialog.model.settings_in_separate_tab = room;
            dialog.model.about_rows.append(new ViewModel.PreferencesRow.Text() {
                title = _("XMPP Address"), text = "room@conference.example.test"
            });
            dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Toggle() {
                title = _("Show member status messages"),
                subtitle = _("Show routine role and affiliation changes; forced-removal notices remain visible"),
                state = true
            });
            if (room) {
                dialog.model.room_administration_rows.append(new ViewModel.PreferencesRow.Button() {
                    title = _("Administration"), button_text = _("Open")
                });
                var configuration = new GLib.ListStore(typeof(ViewModel.PreferencesRow.Any));
                configuration.append(new ViewModel.PreferencesRow.Entry() {
                    title = _("Topic"), text = "Current room topic"
                });
                dialog.model.room_configuration_rows = configuration;
            }
            var encryption = new Adw.PreferencesGroup() { title = "OMEMO" };
            encryption.add(new Adw.ActionRow() {
                title = _("Encryption"), subtitle = "Account-scoped encryption state"
            });
            dialog.add_encryption_tab_element(encryption);
            if (initial_page != null) dialog.select_page(initial_page);
            window.present();
            dialog.present(window);
            iterate_for(200);
        }

        public void close() {
            if (closed) return;
            closed = true;
            Util.clear_focus_before_detach(dialog);
            dialog.force_close();
            window.destroy();
            iterate_for(30);
            Widget.set_default_direction(previous_direction);
        }
    }

    private static void assert_layout(Fixture fixture, int target) {
        var dialog = fixture.dialog;
        int minimum, natural;
        dialog.child.measure(Orientation.HORIZONTAL, -1,
            out minimum, out natural, null, null);
        fail_if(minimum > fixture.window.get_width(),
            "the actual content minimum must fit, independently of the breakpoint bin minimum");
        fail_if(fixture.window.get_width() > target + 2,
            "a details dialog must not enlarge its parent window");
        fail_if_not(dialog.get_mapped(), "the real Adw.Dialog must be mapped");
        Graphene.Rect bounds;
        bool has_bounds = dialog.compute_bounds(fixture.window, out bounds);
        GLib.Test.message("Details target=%d client=%d dialog=%d content=%d bounds=%.1f..%.1f",
            target, fixture.window.get_width(), dialog.get_width(),
            dialog.child.get_width(), bounds.origin.x,
            bounds.origin.x + bounds.size.width);
        fail_if_not(has_bounds, "the dialog must have native bounds within its parent");
        fail_if(bounds.origin.x < -0.5f || bounds.origin.x +
            bounds.size.width > fixture.window.get_width() + 0.5f,
            "the dialog must fit the actual client area, including at CSD window widths");
        bool narrow = dialog.child.get_width() <= 550;
        fail_if_not(dialog.primary_actions.orientation ==
            (narrow ? Orientation.VERTICAL : Orientation.HORIZONTAL),
            "the dialog breakpoint must adapt the actual action row");
        fail_if_not(dialog.contact_actions.orientation ==
            (narrow ? Orientation.VERTICAL : Orientation.HORIZONTAL),
            "contact actions must follow the same breakpoint");
        fail_if_not_eq_str(dialog.pin_button_content.label,
            dialog.pin_button.tooltip_text ?? "", "the complete pin label remains accessible");
        if (dialog.notification_button_menu.visible) {
            fail_if_not_eq_str(dialog.notification_button_menu_content.label,
                dialog.notification_button_menu.tooltip_text ?? "");
        }
        fail_if_not_eq_int(1, (int) dialog.model.about_rows.get_n_items(),
            "layout must not alter the selected conversation model");
        var viewport = dialog.tabs_scroller.get_child() as Viewport;
        fail_if_not(viewport != null, "native tabs must retain their focus-scrolling viewport");
        if (viewport != null) {
            Graphene.Rect tab_bounds;
            fail_if_not(dialog.tabs_switcher.compute_bounds(viewport, out tab_bounds));
            fail_if(tab_bounds.origin.y < -0.5f || tab_bounds.origin.y +
                tab_bounds.size.height > viewport.get_height() + 0.5f,
                "an overflowing tab row must remain fully visible above its scrollbar");
            var adjustment = dialog.tabs_scroller.hadjustment;
            fail_if_not(dialog.tabs_scrollbar.visible ==
                (adjustment.upper > adjustment.page_size + 0.5),
                "show the native scrollbar only when tab labels overflow");
        }
    }

    private void test_room_layout() {
        foreach (TextDirection direction in new TextDirection[] {
                TextDirection.LTR, TextDirection.RTL }) {
            foreach (int width in new int[] { 640, 500, 320 }) {
                var fixture = new Fixture(width, true, direction);
                try {
                    assert_layout(fixture, width);
                    var dialog = fixture.dialog;
                    fail_if_not_eq_int(5, (int) dialog.stack.get_pages().get_n_items(),
                        "all room pages must remain available");
                    foreach (string name in new string[] {
                            "about", "settings", "room_administration", "room_config", "encryption" }) {
                        dialog.stack.visible_child_name = name;
                        iterate_for(30);
                        assert_layout(fixture, width);
                    }
                    var selected = dialog.stack.visible_child;
                    dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Toggle() {
                        title = _("Show member status messages"), state = false
                    });
                    iterate_for(30);
                    fail_if_not(dialog.stack.visible_child == selected,
                        "late settings updates must preserve the selected page");
                } finally { fixture.close(); }
            }
        }
    }

    private static Gtk.Button? find_response_button(Gtk.Widget widget, string label) {
        var button = widget as Gtk.Button;
        if (button != null && button.label == label) return button;
        for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            Gtk.Button? found = find_response_button(child, label);
            if (found != null) return found;
        }
        return null;
    }

    private void test_contact_removal(int variant) {
        var fixture = new Fixture(500, false);
        try {
            var dialog = fixture.dialog;
            int requested = 0;
            dialog.model.remove_contact.connect(() => {
                requested++;
                dialog.model.removing_contact = true;
            });
            dialog.remove_contact_button.clicked();
            iterate_for(250);
            var confirmation = fixture.window.visible_dialog as Adw.AlertDialog;
            if (fail_if_not(confirmation != null, "removal needs the actual confirmation dialog")) return;
            var remove = find_response_button(confirmation, _("Remove"));
            if (fail_if_not(remove != null, "removal confirmation button exists")) return;
            remove.clicked();
            iterate_for(250);
            fail_if_not_eq_int(1, requested);
            fail_if(fixture.window.visible_dialog != dialog || dialog.remove_contact_button.sensitive,
                "details must stay open and prevent duplicate removal while waiting");
            if (variant == 2) { dialog.force_close(); iterate_for(100); }
            dialog.model.removing_contact = false;
            dialog.model.remove_contact_finished(new Xmpp.Jid("bob@example.test"),
                variant == 0 ? RosterRemoveResult.SUCCESS : RosterRemoveResult.SERVER_REJECTED);
            iterate_for(250);
            if (variant == 1) {
                var failure = fixture.window.visible_dialog as Adw.AlertDialog;
                if (fail_if_not(failure != null, "rejected removal must show a failure")) return;
                fail_if_not(failure.body.contains("bob@example.test"), "failure belongs to the selected contact");
                fail_if_not(dialog.remove_contact_button.sensitive, "failed removal permits retry");
                failure.force_close();
                iterate_for(100);
                fail_if(fixture.window.visible_dialog != dialog, "rejection must retain the details dialog");
            } else {
                fail_if(fixture.window.visible_dialog != null, "success closes details; closed details ignore late errors");
            }
        } catch (Error e) { fail_if_reached(e.message); }
        finally { fixture.close(); }
    }

    private void test_contact_layout() {
        var fixture = new Fixture(500, false);
        try {
            assert_layout(fixture, 500);
            int pin_actions = 0, notification_actions = 0;
            fixture.dialog.model.pin_changed.connect(() => pin_actions++);
            fixture.dialog.model.notification_flipped.connect(() => notification_actions++);
            fixture.dialog.pin_button.clicked();
            fixture.dialog.notification_button_split.clicked();
            fail_if_not_eq_int(1, pin_actions);
            fail_if_not_eq_int(1, notification_actions);
            fail_if_not(fixture.dialog.remove_contact_button.visible &&
                fixture.dialog.block_button.visible, "narrow mode must keep contact controls");
            fixture.window.set_default_size(800, 700);
            iterate_for(200);
            assert_layout(fixture, 800);
            fail_if(fixture.dialog.primary_actions.orientation != Orientation.HORIZONTAL,
                "expanding must restore horizontal actions");
            fixture.window.set_default_size(320, 700);
            iterate_for(200);
            assert_layout(fixture, 320);
            fail_if_not(fixture.dialog.model.pinned, "resizing must not toggle pinned state");
            fail_if_not(fixture.dialog.model.notification ==
                ViewModel.ConversationDetails.NotificationSetting.OFF,
                "resizing must not change notification settings");
        } finally { fixture.close(); }
    }

    private void test_tab_focus() {
        var fixture = new Fixture(320, true);
        try {
            var dialog = fixture.dialog;
            // Short translations (for example Chinese) can fit all five tabs.
            // Force overflow in this scrolling fixture independently of locale;
            // the other fixtures still exercise the unchanged translated titles.
            var pages = dialog.stack.get_pages();
            for (uint i = 0; i < pages.get_n_items(); i++) {
                var page = (StackPage) pages.get_item(i);
                page.title = "%s — extended test tab".printf(page.title ?? "");
            }
            iterate_for(200);
            Widget? button = dialog.tabs_switcher.get_last_child();
            fail_if_not(button is ToggleButton, "the switcher keeps native toggle buttons");
            if (!(button is ToggleButton)) return;
            fail_if_not(button.grab_focus(), "the last tab must remain keyboard-focusable");
            iterate_for(80);
            ((ToggleButton) button).active = true;
            iterate_for(80);
            fail_if_not_eq_str("encryption", dialog.stack.visible_child_name ?? "");
            var adjustment = dialog.tabs_scroller.hadjustment;
            fail_if_not(adjustment.upper > adjustment.page_size,
                "extended fixture tab labels must overflow the narrow viewport");
            fail_if_not(adjustment.value > 0,
                "native keyboard focus must reveal a tab beyond the initial viewport");
        } finally { fixture.close(); }

        foreach (TextDirection direction in new TextDirection[] { TextDirection.LTR, TextDirection.RTL }) {
            var direct = new Fixture(320, true, direction, "encryption");
            try {
                assert_selected_tab_visible(direct.dialog, "encryption");
                direct.dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Toggle() {
                    title = _("Show member status messages"), state = false
                });
                iterate_for(200);
                assert_selected_tab_visible(direct.dialog, "encryption");
                var entry = new Entry() { text = "Keep the user's input focus" };
                direct.dialog.encryption_box.append(entry);
                iterate_for(30);
                fail_if_not(direct.dialog.tabs_switcher.get_last_child().grab_focus());
                direct.dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Toggle() {
                    title = _("Show member status messages"), state = true
                });
                fail_if_not(entry.grab_focus(), "the input must accept focus before the queued reorder reveal runs");
                Widget? input_focus = direct.dialog.focus_widget;
                fail_if(input_focus == null);
                iterate_for(200);
                fail_if(direct.dialog.focus_widget != input_focus,
                    "a queued tab-reorder reveal must not steal a later input focus");
                fail_if_not_eq_str("encryption", direct.dialog.stack.visible_child_name ?? "");
                direct.dialog.select_page("about");
                iterate_for(200);
                assert_selected_tab_visible(direct.dialog, "about");
            } finally { direct.close(); }
        }
    }

    private static void assert_selected_tab_visible(ConversationDetails.Dialog dialog, string name) {
        // GtkViewport animates native scrolling; observe the actual geometry
        // rather than assuming a fixed time at which that animation finishes.
        int64 deadline = GLib.get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (!selected_tab_is_visible(dialog, name) && GLib.get_monotonic_time() < deadline) {
            iterate_for(10);
        }
        fail_if_not_eq_str(name, dialog.stack.visible_child_name ?? "");
        var viewport = dialog.tabs_scroller.get_child() as Viewport;
        fail_if(viewport == null);
        if (viewport == null) return;
        ToggleButton? active = null;
        for (Widget? child = dialog.tabs_switcher.get_first_child();
                child != null; child = child.get_next_sibling()) {
            var button = child as ToggleButton;
            if (button != null && button.active) { active = button; break; }
        }
        fail_if(active == null, "the selected page must have a native active tab");
        if (active == null) return;
        Graphene.Rect bounds;
        fail_if_not(active.compute_bounds(viewport, out bounds));
        var adjustment = dialog.tabs_scroller.hadjustment;
        GLib.Test.message("Selected tab page=%s direction=%s bounds=%.2f..%.2f width=%.2f viewport=%d adjustment=%.2f/%.2f/%.2f focus=%s",
            name, dialog.get_direction() == TextDirection.RTL ? "RTL" : "LTR",
            bounds.get_x(), bounds.get_x() + bounds.get_width(), bounds.get_width(), viewport.get_width(),
            adjustment.value, adjustment.page_size, adjustment.upper,
            dialog.focus_widget != null ? dialog.focus_widget.get_type().name() : "none");
        fail_if(bounds.get_x() < -0.5f || bounds.get_x() + bounds.get_width() > viewport.get_width() + 0.5f,
            "direct selection must reveal the complete native tab: page=%s direction=%s bounds=%.2f..%.2f viewport=%d".printf(
                name, dialog.get_direction() == TextDirection.RTL ? "RTL" : "LTR",
                bounds.get_x(), bounds.get_x() + bounds.get_width(), viewport.get_width()));
        var label = active.child as Label;
        fail_if(label == null, "the native tab must retain its actual text label");
        if (label != null) {
            // Widget.measure includes CSS padding, while get_width returns
            // the content box. Check the actual caption layout inside it.
            var layout = label.get_layout();
            int text_width, text_height;
            layout.get_pixel_size(out text_width, out text_height);
            fail_if(layout.is_ellipsized() || label.get_width() < text_width,
                "the complete caption must fit without truncating its text");
        }
    }

    private static bool selected_tab_is_visible(ConversationDetails.Dialog dialog, string name) {
        if (dialog.stack.visible_child_name != name) return false;
        var viewport = dialog.tabs_scroller.child as Viewport;
        if (viewport == null || !viewport.get_mapped()) return false;
        for (Widget? child = dialog.tabs_switcher.get_first_child();
                child != null; child = child.get_next_sibling()) {
            var button = child as ToggleButton;
            if (button == null || !button.active) continue;
            Graphene.Rect bounds;
            return button.compute_bounds(viewport, out bounds) && bounds.get_width() > 0 &&
                bounds.get_x() >= -0.5f && bounds.get_x() + bounds.get_width() <= viewport.get_width() + 0.5f;
        }
        return false;
    }

    private void test_preference_models() {
        var fixture = new Fixture(320, true);
        try {
            var rows = fixture.dialog.model.settings_rows;
            rows.append(new ViewModel.PreferencesRow.Section() { title = _("Settings") });
            rows.append(new ViewModel.PreferencesRow.Text() {
                title = _("XMPP Address"), text = "some-long-account-identifier-without-a-short-cut@example.test"
            });
            var entry = new ViewModel.PreferencesRow.Entry() {
                title = _("Topic"), text = "An unchanged, long editable value"
            };
            rows.append(entry);
            rows.append(new ViewModel.PreferencesRow.PrivateText() {
                title = _("Password"), text = "isolated fixture only"
            });
            var combo = new ViewModel.PreferencesRow.ComboBox() {
                title = _("Send typing notifications"), active_item = 1
            };
            combo.items.add(_("Default: %s").printf(_("On")));
            combo.items.add(_("On"));
            rows.append(combo);
            var number = new ViewModel.PreferencesRow.Number() {
                title = _("Days to load"), minimum = 1, maximum = 365, value = 30
            };
            rows.append(number);
            rows.append(new ViewModel.PreferencesRow.MultiText() {
                title = _("Settings"), text = "one\ntwo", description = _("One value per line")
            });
            var multi = new ViewModel.PreferencesRow.MultiCheck() { title = _("Settings") };
            multi.items.add(_("On")); multi.states.add(true);
            rows.append(multi);
            rows.append(new ViewModel.PreferencesRow.Button() {
                title = _("Load message history"), button_text = _("Load now")
            });
            fixture.dialog.stack.visible_child_name = "settings";
            iterate_for(50);
            assert_layout(fixture, 320);
            fail_if_not_eq_str("An unchanged, long editable value", entry.text);
            fail_if_not_eq_int(1, combo.active_item);
            fail_if_not_eq_int(30, number.value);
        } finally { fixture.close(); }
    }

    private void test_close_pending() {
        var fixture = new Fixture(500, false);
        int child_count = child_count_of(fixture.dialog.about_box);
        fixture.dialog.model.about_rows.append(new ViewModel.PreferencesRow.Text() {
            title = _("About"), text = "queued before close"
        });
        fixture.dialog.select_page("about");
        fixture.dialog.force_close();
        iterate_for(40);
        fail_if_not_eq_int(child_count, child_count_of(fixture.dialog.about_box),
            "a pending rebuild must not mutate an already closed dialog");
        fixture.close();
    }

    private void test_stable_encryption_page() {
        var fixture = new Fixture(500, true, TextDirection.LTR, "encryption");
        var dialog = fixture.dialog;
        int unroots = 0;
        int commits = 0;
        var encryption = dialog.encryption_box.get_first_child();
        ulong root_id = encryption.notify["root"].connect(() => {
            if (encryption.get_root() == null) unroots++;
        });
        try {
            var number = new ViewModel.PreferencesRow.Number() {
                title = "Days", minimum = 1, maximum = 365, value = 30
            };
            dialog.model.settings_rows.append(number);
            iterate_for(30);
            number.commit.connect(() => { commits++; });
            int64 started = GLib.get_monotonic_time();
            for (int i = 0; i < 80; i++) {
                dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Text() {
                    title = "Настройка %d".printf(i), text = "A room setting"
                });
            }
            dialog.model.room_administration_rows.append(new ViewModel.PreferencesRow.Button() {
                title = "Room action", button_text = "Open"
            });
            iterate_for(50);
            GLib.Test.message("Details row batch: %.1f ms including 50 ms event dispatch",
                (GLib.get_monotonic_time() - started) / 1000.0);
            fail_if_not_eq_int(1, commits, "a row batch must commit existing editors only once");
            fail_if_not_eq_int(0, unroots, "unrelated rows must not detach encryption controls");
            fail_if_not_eq_str("encryption", dialog.stack.visible_child_name);
            fail_if_not(encryption.get_root() == fixture.window);
        } finally {
            SignalHandler.disconnect(encryption, root_id);
            fixture.close();
        }
    }

    private void test_close_pending_preferences() {
        var fixture = new Fixture(500, true);
        var dialog = fixture.dialog;
        var settings = dialog.settings_box.get_first_child();
        var administration = dialog.room_administration_box.get_first_child();
        dialog.model.settings_rows.append(new ViewModel.PreferencesRow.Text() {
            title = "Queued setting", text = "Do not render after close"
        });
        dialog.model.room_administration_rows.append(new ViewModel.PreferencesRow.Button() {
            title = "Queued action", button_text = "Open"
        });
        dialog.force_close();
        iterate_for(40);
        fail_if_not(settings == dialog.settings_box.get_first_child());
        fail_if_not(administration == dialog.room_administration_box.get_first_child());
        fixture.close();
    }

    private void test_visual_fixture() {
        string? width_value = Environment.get_variable("DINOX_DETAILS_SCREENSHOT_WIDTH");
        if (width_value == null) return;
        int width = int.parse(width_value);
        bool room = Environment.get_variable("DINOX_DETAILS_SCREENSHOT_KIND") != "contact";
        var fixture = new Fixture(width, room);
        try {
            assert_layout(fixture, width);
            GLib.Test.message("Responsive details screenshot fixture ready (%dpx)", width);
            iterate_for(12000);
        } finally { fixture.close(); }
    }

    private static int child_count_of(Widget widget) {
        int count = 0;
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) count++;
        return count;
    }

    private static void iterate_for(uint milliseconds) {
        int64 until = get_monotonic_time() + milliseconds * 1000;
        var context = MainContext.default();
        while (get_monotonic_time() < until) {
            while (context.pending()) context.iteration(false);
            Thread.usleep(1000);
        }
        while (context.pending()) context.iteration(false);
    }
}

}
