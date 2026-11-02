using Gtk;

namespace Dino.Ui.Test {

// Drive the real preferences page and profile-wide Settings binding against an
// isolated encrypted database. No live account or native user profile is used.
class ChatFontPreferencesRuntimeTest : Gee.TestCase {
    public ChatFontPreferencesRuntimeTest() {
        base("ChatFontPreferencesRuntime");
        add_test("missing_saved_font_is_explicit_and_native_default_selection_resets_it", test_missing_font_reset);
        add_test("model_updates_preserve_saved_names_without_stale_missing_choices", test_model_updates);
        add_test("font_names_with_markup_characters_remain_literal", test_literal_font_name);
        add_test("all_text_sizes_persist_and_page_initialization_does_not_write_settings", test_text_sizes);
        add_test("case_aliases_are_installed_and_replaced_models_are_disconnected", test_model_replacement);
    }

    private class Fixture : Object {
        public string root;
        public string path;
        public Dino.Database db;
        public Dino.Entities.Settings settings;
        public ViewModel.GeneralPreferencesPage model;
        public GeneralPreferencesPage page;
        public Adw.ComboRow family;
        public Adw.ComboRow scale;
        public Gtk.Window window;
        private Binding family_binding;
        private Binding scale_binding;
        private bool closed = false;

        public Fixture(string saved_family = "system") throws Error {
            root = DirUtils.make_tmp("dinox-chat-font-ui-XXXXXX");
            path = Path.build_filename(root, "dino.db");
            db = new Dino.Database(path, "isolated font preferences runtime test");
            settings = new Dino.Entities.Settings.from_db(db);
            settings.chat_font_family = saved_family;
            try {
                rebuild();
            } catch (Error error) {
                close();
                throw error;
            }
        }

        public void rebuild() throws Error {
            if (window != null) window.destroy();
            if (family_binding != null) family_binding.unbind();
            if (scale_binding != null) scale_binding.unbind();
            model = new ViewModel.GeneralPreferencesPage();
            family_binding = settings.bind_property("chat-font-family", model,
                "chat-font-family", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            scale_binding = settings.bind_property("chat-font-scale", model,
                "chat-font-scale", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            page = new GeneralPreferencesPage() { model = model };
            page.ensure_content();
            family = find_combo(page, _("Chat _Font"));
            scale = find_combo(page, _("Chat Text _Size"));
            if (family == null || scale == null) {
                throw new IOError.FAILED(
                    "Font rows were not found in the native preferences page. " +
                    "The test's GtkBuilder and gettext domains must match. " +
                    "Expected titles: [%s], [%s].".printf(
                        _("Chat _Font"), _("Chat Text _Size")));
            }
            window = new Gtk.Window() {
                default_width = 700, default_height = 600, child = page
            };
            window.present();
            settle();
        }

        public string saved_family() {
            return new Dino.Entities.Settings.from_db(db).chat_font_family;
        }

        public int saved_scale() {
            return new Dino.Entities.Settings.from_db(db).chat_font_scale;
        }

        public void replace_model() {
            family_binding.unbind();
            scale_binding.unbind();
            model = new ViewModel.GeneralPreferencesPage();
            family_binding = settings.bind_property("chat-font-family", model,
                "chat-font-family", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            scale_binding = settings.bind_property("chat-font-scale", model,
                "chat-font-scale", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            page.model = model;
        }

        public void close() {
            if (closed) return;
            closed = true;
            if (window != null) window.destroy();
            if (family_binding != null) family_binding.unbind();
            if (scale_binding != null) scale_binding.unbind();
            settle();
            db.close();
            FileUtils.remove(path);
            FileUtils.remove(path + "-wal");
            FileUtils.remove(path + "-shm");
            DirUtils.remove(root);
        }
    }

    private static void settle() {
        int64 deadline = get_monotonic_time() + 30000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static Adw.ComboRow? find_combo(Widget widget, string title) {
        if (widget is Adw.ComboRow && ((Adw.ComboRow) widget).title == title)
            return (Adw.ComboRow) widget;
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            var found = find_combo(child, title);
            if (found != null) return found;
        }
        return null;
    }

    private static Gtk.ListView? popup_list(Widget widget) {
        if (widget is Gtk.ListView && widget.get_ancestor(typeof(Gtk.Popover)) != null)
            return (Gtk.ListView) widget;
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            var found = popup_list(child);
            if (found != null) return found;
        }
        return null;
    }

    private static void native_select(Adw.ComboRow row, uint position) {
        // The full UI suite also runs on a 1024x768 display. Focus the row and
        // wait for PreferencesPage's scrolling before opening its popup;
        // directly activating an off-screen row is not a user interaction.
        var scroller = row.get_ancestor(typeof(Gtk.ScrolledWindow)) as Gtk.ScrolledWindow;
        if (fail_if(scroller == null, "font row must have a scrolling viewport")) return;
        if (fail_if(!row.grab_focus(), "font selection must accept keyboard focus")) return;
        bool visible = false;
        int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
        while (get_monotonic_time() < deadline) {
            Graphene.Rect bounds;
            if (row.compute_bounds(scroller, out bounds) && bounds.origin.y >= 0 &&
                    bounds.origin.y + bounds.size.height <= scroller.vadjustment.page_size) {
                visible = true;
                break;
            }
            settle();
        }
        if (fail_if(!visible, "font row must be visible before popup activation")) return;
        row.activate();
        settle();
        var list = popup_list(row);
        if (fail_if(list == null, "native font selection popup must exist")) return;
        // Native ListView selection happens before its activation signal. The
        // actual AdwComboRow handler then commits that popup selection.
        list.model.select_item(position, true);
        list.activate(position);
        settle();
    }

    private static string selected_text(Adw.ComboRow row) {
        return ((Gtk.StringObject) row.selected_item).string;
    }

    private void test_missing_font_reset() {
        Fixture? fixture = null;
        try {
            const string MISSING = "DinoX Test Missing Font 986754";
            fixture = new Fixture(MISSING);
            uint with_missing = fixture.family.model.get_n_items();
            fail_if(fixture.family.selected == 0,
                "an unavailable saved font must not impersonate System default");
            fail_if_not_eq_str(_("Not installed: %s").printf(MISSING),
                selected_text(fixture.family));
            fail_if_not_eq_str(MISSING, fixture.model.chat_font_family);
            fail_if_not_eq_str(MISSING, fixture.saved_family());

            native_select(fixture.family, 0);
            fail_if_not_eq_str("system", fixture.model.chat_font_family);
            fail_if_not_eq_str("system", fixture.saved_family());
            fail_if(fixture.family.model.get_n_items() != with_missing - 1,
                "reset must retire the no-longer-current missing font");
        } catch (Error error) { fail_if(true, error.message); }
        if (fixture != null) fixture.close();
    }

    private void test_model_updates() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            uint installed_count = fixture.family.model.get_n_items();
            if (fail_if(installed_count < 2, "Pango must expose at least one font")) {
                fixture.close();
                return;
            }
            string installed = ((Gtk.StringObject) fixture.family.model.get_item(1)).string;
            native_select(fixture.family, 1);
            fail_if_not_eq_str(installed, fixture.saved_family());

            foreach (string missing in new string[] {
                    "DinoX Missing Font A 986754", "DinoX Missing Font B 986754",
                    "DinoX Missing Font B 986754", "DinoX Missing Font A 986754" }) {
                fixture.settings.chat_font_family = missing;
                fail_if_not_eq_str(missing, fixture.model.chat_font_family);
                fail_if_not_eq_str(missing, fixture.saved_family());
                fail_if(fixture.family.selected != installed_count,
                    "the current unavailable family must be explicitly selected");
                fail_if(fixture.family.model.get_n_items() != installed_count + 1,
                    "only the current missing family may remain in the model");
                fail_if_not_eq_str(_("Not installed: %s").printf(missing),
                    selected_text(fixture.family));
            }

            string saved = fixture.saved_family();
            fixture.rebuild();
            fail_if_not_eq_str(saved, fixture.model.chat_font_family);
            fail_if_not_eq_str(saved, fixture.saved_family());
            fail_if(fixture.family.model.get_n_items() != installed_count + 1,
                "fresh pages must have exactly one unavailable choice");

            fixture.settings.chat_font_family = installed;
            fail_if_not_eq_str(installed, selected_text(fixture.family));
            fail_if(fixture.family.model.get_n_items() != installed_count,
                "an installed family must remove the temporary missing choice");
            fail_if(fixture.family.tooltip_text != null,
                "installed choices must not retain a stale missing-font tooltip");
        } catch (Error error) { fail_if(true, error.message); }
        if (fixture != null) fixture.close();
    }

    private void test_literal_font_name() {
        Fixture? fixture = null;
        try {
            const string LITERAL = "<b>Office & Chat</b> 986754";
            fixture = new Fixture(LITERAL);
            fail_if(fixture.family.use_markup,
                "restored family names must never be interpreted as markup");
            fail_if_not_eq_str(_("Not installed: %s").printf(LITERAL),
                selected_text(fixture.family));
            fail_if_not_eq_str(_("Not installed: %s").printf(LITERAL),
                fixture.family.subtitle);
            int minimum;
            fixture.family.measure(Orientation.HORIZONTAL, -1,
                out minimum, null, null, null);
            fail_if(minimum > 256,
                "long literal font names must fit a narrow preferences content area");
            fail_if_not_eq_str(LITERAL, fixture.saved_family());
            native_select(fixture.family, fixture.family.selected);
            fail_if_not_eq_str(LITERAL, fixture.saved_family());
        } catch (Error error) { fail_if(true, error.message); }
        if (fixture != null) fixture.close();
    }

    private void test_text_sizes() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            int[] scales = { 100, 110, 125, 150, 175, 200 };
            for (uint i = 0; i < scales.length; i++) {
                fixture.scale.selected = i;
                fail_if_not_eq_int(scales[i], fixture.saved_scale());
            }
            uint font_writes = 0;
            uint scale_writes = 0;
            ulong family_handler = fixture.settings.notify["chat-font-family"].connect(() => font_writes++);
            ulong scale_handler = fixture.settings.notify["chat-font-scale"].connect(() => scale_writes++);
            fixture.rebuild();
            fail_if(font_writes != 0 || scale_writes != 0,
                "building a preferences page must not write typography settings");
            fail_if_not_eq_int(200, fixture.saved_scale());
            fail_if_not_eq_int(5, (int) fixture.scale.selected);
            fixture.settings.disconnect(family_handler);
            fixture.settings.disconnect(scale_handler);
        } catch (Error error) { fail_if(true, error.message); }
        if (fixture != null) fixture.close();
    }

    private void test_model_replacement() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            uint installed_count = fixture.family.model.get_n_items();
            if (fail_if(installed_count < 2, "Pango must expose at least one font")) {
                fixture.close();
                return;
            }
            string installed = ((Gtk.StringObject) fixture.family.model.get_item(1)).string;
            string alias = installed.casefold();
            fixture.settings.chat_font_family = alias;
            fail_if_not_eq_str(alias, fixture.saved_family());
            fail_if_not_eq_str(alias, fixture.model.chat_font_family);
            fail_if_not_eq_str(installed, selected_text(fixture.family));
            fail_if(fixture.family.model.get_n_items() != installed_count,
                "case variants of an installed family are not missing fonts");

            var old_model = fixture.model;
            fixture.replace_model();
            uint notify_signal = Signal.lookup("notify", typeof(Object));
            fail_if(Signal.has_handler_pending(old_model, notify_signal,
                Quark.from_string("chat-font-family"), false),
                "font-family notifications must be disconnected from the old model");
            fail_if(Signal.has_handler_pending(old_model, notify_signal,
                Quark.from_string("chat-font-scale"), false),
                "font-size notifications must be disconnected from the old model");
            old_model.chat_font_family = "Old Detached Font 986754";
            old_model.chat_font_scale = 200;
            fail_if_not_eq_str(alias, fixture.model.chat_font_family);
            fail_if_not_eq_int(100, fixture.model.chat_font_scale);
            WeakRef replaced_model = WeakRef(fixture.model);
            fixture.replace_model();
            fail_if(replaced_model.get() != null,
                "replacing a model without an external owner must safely release it");
            native_select(fixture.family, 0);
            fail_if_not_eq_str("system", fixture.saved_family());
        } catch (Error error) { fail_if(true, error.message); }
        if (fixture != null) fixture.close();
    }
}

}
