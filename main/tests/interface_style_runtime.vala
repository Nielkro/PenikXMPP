using Gtk;

namespace Dino.Ui.Test {

class InterfaceStyleRuntimeTest : Gee.TestCase {
    [CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
    private static extern void add_style_provider(Gdk.Display display, Gtk.StyleProvider provider, uint priority);
    [CCode (cname = "gtk_style_context_remove_provider_for_display", cheader_filename = "gtk/gtk.h")]
    private static extern void remove_style_provider(Gdk.Display display, Gtk.StyleProvider provider);
    [CCode (cname = "gtk_icon_theme_set_search_path", cheader_filename = "gtk/gtk.h")]
    private static extern void set_icon_search_path(Gtk.IconTheme theme,
        [CCode (array_length = false, array_null_terminated = true, type = "const char* const*")] string[] path);

    public InterfaceStyleRuntimeTest() {
        base("InterfaceStyleRuntime");
        add_test("window_controls_follow_system_or_saved_side", test_window_controls);
        add_test("switch_palettes_restore_classic_and_preserve_semantic_colors", test_palettes);
        add_test("design_selection_persists_without_changing_color_scheme", test_preferences);
        add_test("application_icon_is_available_from_resources", test_icon);
        add_test("startup_appearance_is_profile_scoped_and_contains_only_validated_choices", test_startup_appearance);
        add_test("confirmation_and_error_dialogs_use_palette_in_all_presentations", test_dialogs);
        add_test("call_controls_and_device_popovers_follow_design", test_calls);
    }

    private static void settle() {
        int64 deadline = get_monotonic_time() + 50000;
        while (get_monotonic_time() < deadline) {
            if (MainContext.default().pending()) MainContext.default().iteration(false);
            else Thread.usleep(1000);
        }
    }

    private static Gdk.RGBA color(Widget widget, string name) {
#if GTK_4_12
        // Resolve the named palette color through CSS, then read the actual
        // widget color without the deprecated GtkStyleContext lookup API.
        var provider = new CssProvider();
        provider.parsing_error.connect((section, error) => {
            fail_if_reached("Palette color probe: " + error.message);
        });
        provider.load_from_string(".dinox-palette-color-probe { color: @%s; transition: none; }".printf(name));
        add_style_provider(widget.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 100);
        widget.add_css_class("dinox-palette-color-probe");
        settle();
        var result = widget.get_color();
        widget.remove_css_class("dinox-palette-color-probe");
        remove_style_provider(widget.get_display(), provider);
        return result;
#else
        // Compatibility with older GTK builds, matching the other color tests.
        Gdk.RGBA result;
        assert_true(widget.get_style_context().lookup_color(name, out result), name);
        return result;
#endif
    }

    private static void expect_color(Widget widget, string name, string hex) {
        Gdk.RGBA expected = Gdk.RGBA();
        expected.parse(hex);
        var actual = color(widget, name);
        assert_true(actual.equal(expected), "%s: expected %s, got %s".printf(
            name, expected.to_string(), actual.to_string()));
    }

    private void test_palettes() {
        var manager = Adw.StyleManager.get_default();
        if (Environment.get_variable("ADW_DEBUG_HIGH_CONTRAST") == "1")
            assert_true(manager.high_contrast, "The high-contrast test must actually enable high contrast");
        var previous = manager.color_scheme;
        var style = new InterfaceStyle(Gdk.Display.get_default());
        var label = new Label("DinoX");
        var window = new Gtk.Window() { child = label };
        window.present();
        foreach (var scheme in new Adw.ColorScheme[] {
                Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
            manager.color_scheme = scheme;
            settle();
            var native_bg = color(window, "window_bg_color");
            var native_error = color(label, "error_color");
            var native_warning = color(label, "warning_color");
            style.apply("website");
            settle();
            if (manager.high_contrast) {
                assert_true(color(window, "window_bg_color").equal(native_bg),
                    "High contrast must take precedence over the website palette");
            } else {
                expect_color(window, "window_bg_color", manager.dark ? "#111c18" : "#f9faf7");
                expect_color(label, "window_fg_color", manager.dark ? "#ecf1e9" : "#20372f");
                expect_color(label, "accent_color", manager.dark ? "#bcd8c3" : "#315e4d");
            }
            assert_true(color(label, "error_color").equal(native_error));
            assert_true(color(label, "warning_color").equal(native_warning));
            style.apply("classic");
            settle();
            assert_true(color(window, "window_bg_color").equal(native_bg), "Classic restored");
        }
        style.apply("website");
        manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
        settle();
        if (!manager.high_contrast) expect_color(window, "window_bg_color", "#f9faf7");
        manager.color_scheme = Adw.ColorScheme.FORCE_DARK;
        settle();
        if (!manager.high_contrast) expect_color(window, "window_bg_color", "#111c18");
        // Cleanup is safe more than once and disconnects global style signals.
        style.close();
        style.close();
        window.destroy();
        manager.color_scheme = previous;
        settle();
    }

    private static Adw.ComboRow? find_design(Widget widget) {
        if (widget is Adw.ComboRow && ((Adw.ComboRow) widget).title == _("_Design"))
            return (Adw.ComboRow) widget;
        for (Widget? child = widget.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            var found = find_design(child);
            if (found != null) return found;
        }
        return null;
    }

    private void test_startup_appearance() {
        string? profile = null;
        try {
            profile = DirUtils.make_tmp("dinox-appearance-XXXXXX");
            // Exercise UTF-8 paths without opening or decrypting any database.
            profile = Path.build_filename(profile, "Profil-ő-é-日本語");
            DirUtils.create(profile, 0700);
            string database = Path.build_filename(profile, "dino.db");
            string mirror = Path.build_filename(profile, "appearance.ini");
            assert_true(StartupAppearance.load(profile).interface_style == "classic");
            StartupAppearance.save(profile, "website", "light", "purple", "right");
            assert_true(StartupAppearance.load(profile).interface_style == "classic", "Orphaned preferences are ignored");
            FileUtils.set_contents(database, "not an opened database");
            var loaded = StartupAppearance.load(profile);
            assert_true(loaded.interface_style == "website" && loaded.color_scheme == "light" && loaded.accent_color == "purple");
            assert_true(loaded.window_controls == "right");
            var keyfile = new KeyFile();
            keyfile.load_from_file(mirror, KeyFileFlags.NONE);
            assert_true(keyfile.get_groups().length == 1 && keyfile.get_keys("Appearance").length == 4,
                "The mirror contains only appearance choices");
            StartupAppearance.save(profile, "classic", "default", "default");
            loaded = StartupAppearance.load(profile);
            assert_true(loaded.interface_style == "classic" && loaded.color_scheme == "default");
            FileUtils.set_contents(mirror, "[Appearance]\nstyle=website\nscheme=invalid\naccent=default\n");
            assert_true(StartupAppearance.load(profile).interface_style == "classic", "Invalid mirrors are ignored as a whole");
            FileUtils.set_contents(mirror, "broken");
            assert_true(StartupAppearance.load(profile).color_scheme == "dark", "Malformed metadata cannot block unlock");
            StartupAppearance.save(profile, "untrusted CSS", "invalid", "invalid");
            loaded = StartupAppearance.load(profile);
            assert_true(loaded.interface_style == "classic" && loaded.color_scheme == "default" && loaded.accent_color == "default");
            string contents;
            FileUtils.get_contents(database, out contents);
            assert_true(contents == "not an opened database", "Presentation persistence never touches the database");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (profile != null) {
                FileUtils.remove(Path.build_filename(profile, "appearance.ini"));
                FileUtils.remove(Path.build_filename(profile, "dino.db"));
                DirUtils.remove(profile);
                DirUtils.remove(Path.get_dirname(profile));
            }
        }
    }

    private static Widget? find_css_node(Widget widget, string name) {
        // GtkGizmo instances (including Adwaita sheets) override the class name.
        if (widget.css_name == name) return widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var found = find_css_node(child, name);
            if (found != null) return found;
        }
        return null;
    }

    private static Gdk.RGBA rendered_dialog_background(Widget surface) {
        var snapshot = new Snapshot();
        new WidgetPaintable(surface).snapshot(snapshot, surface.get_width(), surface.get_height());
        var node = snapshot.to_node();
        var renderer = ((Gtk.Native) surface.get_native()).get_renderer();
        assert_true(node != null && renderer != null);
        // Clip to widget coordinates; sheet shadows extend the render node's
        // bounds and would otherwise shift the pixel probe into the shadow.
        Graphene.Rect viewport = Graphene.Rect();
        viewport.init(0, 0, surface.get_width(), surface.get_height());
        var texture = renderer.render_texture(node, viewport);
#if GTK_4_12
        var downloader = new Gdk.TextureDownloader(texture);
        downloader.set_format(Gdk.MemoryFormat.R8G8B8A8);
        size_t stride;
        var bytes = downloader.download_bytes(out stride);
        unowned uint8[] pixels = bytes.get_data();
        size_t offset = (texture.get_height() / 2) * stride + 6 * 4;
#else
        var pixbuf = Gdk.pixbuf_get_from_texture(texture);
        // Sample side padding, clear of the heading, controls and corners.
        int offset = (pixbuf.height / 2) * pixbuf.rowstride + 6 * pixbuf.n_channels;
        unowned uint8[] pixels = pixbuf.get_pixels();
#endif
        return { pixels[offset] / 255.0f, pixels[offset + 1] / 255.0f,
            pixels[offset + 2] / 255.0f, 1.0f };
    }

    private void test_dialogs() {
        var manager = Adw.StyleManager.get_default();
        var previous = manager.color_scheme;
        var style = new InterfaceStyle(Gdk.Display.get_default());
        var window = new Adw.Window() { default_width = 700, default_height = 540 };
        window.content = new Label("DinoX");
        window.present();
        try {
            foreach (var scheme in new Adw.ColorScheme[] { Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                foreach (int mode in new int[] { 0, 1, 2 }) {
                    style.apply("classic");
                    var dialog = new Adw.AlertDialog(_("Error"), _("Please enter your password to open the encrypted database."));
                    dialog.add_response("cancel", _("Cancel"));
                    dialog.add_response("confirm", _("OK"));
                    dialog.add_response("delete", _("Delete"));
                    dialog.set_response_appearance("confirm", Adw.ResponseAppearance.SUGGESTED);
                    dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
                    var password = new PasswordEntry() { show_peek_icon = true };
                    dialog.extra_child = password;
                    dialog.presentation_mode = mode == 1 ? Adw.DialogPresentationMode.BOTTOM_SHEET : Adw.DialogPresentationMode.FLOATING;
                    dialog.present(mode == 2 ? null : window);
                    for (int i = 0; i < 8; i++) settle();
                    Widget surface = find_css_node(dialog, "sheet") ?? (Widget) dialog.get_root();
                    var native_bg = rendered_dialog_background(surface);
                    style.apply("website");
                    for (int i = 0; i < 4; i++) settle();
                    var actual = rendered_dialog_background(surface);
                    Gdk.RGBA expected = Gdk.RGBA();
                    expected.parse(manager.dark ? "#111c18" : "#f9faf7");
                    expected = manager.high_contrast ? native_bg : expected;
                    assert_true(actual.equal(expected),
                        "Dialog dark=%s mode=%d: expected %s, got %s".printf(
                            manager.dark.to_string(), mode, expected.to_string(), actual.to_string()));
                    assert_true(password.get_mapped() && password.grab_focus(), "The themed password input remains usable");
                    string? captures = Environment.get_variable("DINOX_THEME_CAPTURE_DIR");
                    if (captures != null) {
                        var host = (Gtk.Window) dialog.get_root();
                        var snapshot = new Snapshot();
                        new WidgetPaintable(host).snapshot(snapshot, host.get_width(), host.get_height());
                        var node = snapshot.to_node();
                        assert_true(host.get_renderer().render_texture(node, null).save_to_png(
                            Path.build_filename(captures, "%s-%d.png".printf(manager.dark ? "dark" : "light", mode))));
                    }
                    style.apply("classic");
                    for (int i = 0; i < 4; i++) settle();
                    assert_true(rendered_dialog_background(surface).equal(native_bg), "Closing the palette restores native dialog colors");
                    dialog.force_close();
                    settle();
                }
            }
        } finally {
            style.close();
            window.destroy();
            manager.color_scheme = previous;
            settle();
        }
    }

    private void test_calls() {
        var manager = Adw.StyleManager.get_default();
        var previous = manager.color_scheme;
        var style = new InterfaceStyle(Gdk.Display.get_default());
        var window = new Gtk.Window() { default_width = 720, default_height = 480 };
        window.add_css_class("dino-call-window");
        var content = new Box(Orientation.VERTICAL, 0);
        var title = new Label("DinoX") { margin_top = 24, margin_bottom = 24 };
        title.add_css_class("titles");
        var header = new Box(Orientation.VERTICAL, 0);
        header.add_css_class("participant-header-bar");
        header.append(title);
        // An empty top area gives a background sample unaffected by overlays.
        content.append(new Box(Orientation.VERTICAL, 0) { height_request = 32 });
        content.append(header);
        content.append(new Label("") { vexpand = true });
        var bar = new CallBottomBar();
        content.append(bar);
        window.child = content;
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        var audio = bar.show_audio_device_choices(true, devices, devices, false);
        var video = bar.show_video_device_choices(true, devices);
        window.present();
        try {
            foreach (var scheme in new Adw.ColorScheme[] { Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.FORCE_DARK }) {
                manager.color_scheme = scheme;
                style.apply("classic");
                for (int i = 0; i < 4; i++) settle();
                var native_bg = rendered_dialog_background(window);
                var native_error = color(title, "error_color");
                style.apply("website");
                for (int i = 0; i < 4; i++) settle();
                var expected = color(window, "window_bg_color");
                assert_true(rendered_dialog_background(window).equal(manager.high_contrast ? native_bg : expected),
                    "The call window must use the selected background");
#if GTK_4_12
                if (!manager.high_contrast) {
                    var foreground = color(title, "headerbar_fg_color");
                    settle();
                    assert_true(title.get_color().equal(foreground), "Call names must be readable in light and dark mode");
                }
#endif
                assert_true(color(title, "error_color").equal(native_error), "Call warnings keep their semantic color");
                foreach (var popover in new Popover[] { audio, video }) {
                    popover.popup();
                    for (int i = 0; i < 4; i++) settle();
                    assert_true(popover.get_mapped() && bar.is_menu_active(), "Device selection remains accessible");
                    var surface = find_css_node(popover, "contents");
                    assert_true(surface != null);
                    var actual_popover = rendered_dialog_background(surface);
                    var expected_popover = color(window, "popover_bg_color");
                    assert_true(actual_popover.equal(expected_popover),
                        "Device popover: expected %s, got %s".printf(expected_popover.to_string(), actual_popover.to_string()));
                    string? captures = Environment.get_variable("DINOX_THEME_CAPTURE_DIR");
                    if (captures != null) {
                        var snapshot = new Snapshot();
                        new WidgetPaintable(window).snapshot(snapshot, window.get_width(), window.get_height());
                        assert_true(window.get_renderer().render_texture(snapshot.to_node(), null).save_to_png(
                            Path.build_filename(captures, "call-%s-%s.png".printf(manager.dark ? "dark" : "light", popover == audio ? "audio" : "video"))));
                        var popup_snapshot = new Snapshot();
                        new WidgetPaintable(surface).snapshot(popup_snapshot, surface.get_width(), surface.get_height());
                        assert_true(popover.get_renderer().render_texture(popup_snapshot.to_node(), null).save_to_png(
                            Path.build_filename(captures, "popover-%s-%s.png".printf(manager.dark ? "dark" : "light", popover == audio ? "audio" : "video"))));
                    }
                    popover.popdown();
                    for (int i = 0; i < 4; i++) settle();
                }
                style.apply("classic");
                for (int i = 0; i < 4; i++) settle();
                assert_true(rendered_dialog_background(window).equal(native_bg), "Classic call appearance is restored");
            }
        } finally {
            bar.shutdown();
            window.destroy();
            style.close();
            manager.color_scheme = previous;
            settle();
        }
    }

    private static Adw.ComboRow? find_controls(Widget widget) {
        if (widget is Adw.ComboRow && ((Adw.ComboRow) widget).title == _("Window Controls")) return (Adw.ComboRow) widget;
        for (Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
            var result = find_controls(child);
            if (result != null) return result;
        }
        return null;
    }

    private void test_window_controls() {
        string? root = null;
        Dino.Database? db = null;
        Binding? binding = null;
        var gtk_settings = Gtk.Settings.get_default();
        string original = gtk_settings.gtk_decoration_layout;
        WindowControlPlacement.apply("system");
        string system_layout = gtk_settings.gtk_decoration_layout;
        var start = new Gtk.WindowControls(PackType.START);
        var end = new Gtk.WindowControls(PackType.END);
        var box = new Box(Orientation.HORIZONTAL, 0);
        box.append(start);
        box.append(new Box(Orientation.HORIZONTAL, 0) { hexpand = true });
        box.append(end);
        var layout = new Box(Orientation.VERTICAL, 0);
        layout.append(box);
        var window = new Gtk.Window() { child = layout, default_width = 480, default_height = 680 };
        try {
            root = DirUtils.make_tmp("dinox-window-controls-XXXXXX");
            db = new Dino.Database(Path.build_filename(root, "dino.db"), "isolated control placement test");
            var settings = new Dino.Entities.Settings.from_db(db);
            var model = new ViewModel.GeneralPreferencesPage();
            binding = settings.bind_property("window-controls", model, "window-controls",
                BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            var page = new GeneralPreferencesPage() { model = model };
            page.ensure_content();
            var row = find_controls(page);
            assert_true(row != null && row.selected == 0);
            page.vexpand = true;
            layout.append(page);
            window.present();
            foreach (uint selected in new uint[] { 2, 1, 0 }) {
                row.selected = selected;
                string placement = selected == 2 ? "right" : selected == 1 ? "left" : "system";
                assert_true(settings.window_controls == placement);
                assert_true(new Dino.Entities.Settings.from_db(db).window_controls == placement);
                WindowControlPlacement.apply(settings.window_controls);
                settle();
                if (selected != 0) {
                    assert_true(start.empty != end.empty);
                    Widget controls = start.empty ? end : start;
                    Graphene.Rect bounds;
                    assert_true(controls.compute_bounds(window, out bounds));
                    if (selected == 2) assert_true(bounds.origin.x >= window.get_width() / 2,
                        "Right must mean the physical right side, including RTL layouts");
                    if (selected == 1) assert_true(bounds.origin.x + bounds.size.width <= window.get_width() / 2,
                        "Left must mean the physical left side, including RTL layouts");
                }
                if (selected == 0) assert_true(gtk_settings.gtk_decoration_layout == system_layout);
                string? captures = Environment.get_variable("DINOX_THEME_CAPTURE_DIR");
                if (selected == 2 && captures != null) {
                    row.grab_focus();
                    settle();
                    var snapshot = new Snapshot();
                    new WidgetPaintable(window).snapshot(snapshot, window.get_width(), window.get_height());
                    assert_true(window.get_renderer().render_texture(snapshot.to_node(), null).save_to_png(
                        Path.build_filename(captures, "window-controls.png")));
                }
            }
            settings.window_controls = "unexpected";
            assert_true(settings.window_controls == "system");
            var replacement = new ViewModel.GeneralPreferencesPage() { window_controls = "right" };
            page.model = replacement;
            model.window_controls = "left";
            assert_true(row.selected == 2, "the old model must not update a replaced page");
        } catch (Error error) { fail_if_reached(error.message); }
        finally {
            if (binding != null) binding.unbind();
            window.destroy();
            gtk_settings.gtk_decoration_layout = original;
            if (db != null) db.close();
            if (root != null) {
                FileUtils.remove(Path.build_filename(root, "dino.db"));
                FileUtils.remove(Path.build_filename(root, "dino.db-wal"));
                FileUtils.remove(Path.build_filename(root, "dino.db-shm"));
                DirUtils.remove(root);
            }
        }
    }

    private void test_preferences() {
        string? root = null;
        Dino.Database? db = null;
        Gtk.Window? window = null;
        Binding? binding = null;
        try {
            root = DirUtils.make_tmp("dinox-design-ui-XXXXXX");
            string path = Path.build_filename(root, "dino.db");
            db = new Dino.Database(path, "isolated design preferences runtime test");
            var settings = new Dino.Entities.Settings.from_db(db);
            assert_true(settings.interface_style == "classic");
            settings.color_scheme = "dark";
            settings.accent_color = "purple";
            var model = new ViewModel.GeneralPreferencesPage();
            binding = settings.bind_property("interface-style", model, "interface-style",
                BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
            var page = new GeneralPreferencesPage() { model = model };
            page.ensure_content();
            var row = find_design(page);
            assert_true(row != null);
            window = new Gtk.Window() { child = page, default_width = 700, default_height = 800 };
            window.present();
            settle();
            assert_true(row.selected == 0);
            // Opening preferences must not write a setting for an older profile.
            assert_true(db.settings.select({db.settings.value})
                .with(db.settings.key, "=", "interface_style")[db.settings.value] == null);
            row.selected = 1;
            settle();
            assert_true(settings.interface_style == "website");
            var restored = new Dino.Entities.Settings.from_db(db);
            assert_true(restored.interface_style == "website");
            assert_true(restored.color_scheme == "dark");
            assert_true(restored.accent_color == "purple");
            row.selected = 0;
            assert_true(new Dino.Entities.Settings.from_db(db).interface_style == "classic");
            // Replacing a lazy page model must detach the old row binding.
            var replacement = new ViewModel.GeneralPreferencesPage() { interface_style = "website" };
            page.model = replacement;
            assert_true(row.selected == 1);
            model.interface_style = "website";
            model.interface_style = "classic";
            assert_true(row.selected == 1);
            row.selected = 0;
            assert_true(replacement.interface_style == "classic");
        } catch (Error error) {
            fail_if_reached(error.message);
        } finally {
            if (binding != null) binding.unbind();
            if (window != null) window.destroy();
            settle();
            if (db != null) db.close();
            if (root != null) {
                FileUtils.remove(Path.build_filename(root, "dino.db"));
                FileUtils.remove(Path.build_filename(root, "dino.db-wal"));
                FileUtils.remove(Path.build_filename(root, "dino.db-shm"));
                DirUtils.remove(root);
            }
        }
    }

    private void test_icon() {
        // Isolate this lookup from any installed icon belonging to an old build.
        var theme = new Gtk.IconTheme();
        // GTK needs an empty, terminated vector here, not a null pointer.
        set_icon_search_path(theme, {});
        assert_true(theme.get_search_path().length == 0);
        theme.add_resource_path("/im/dinox/dinox/icons");
        foreach (int size in new int[] {16, 32, 48, 128, 256, 512}) {
            var icon = theme.lookup_icon("im.dinox.dinox", null, size, 1,
                TextDirection.LTR, (IconLookupFlags) 0);
            assert_true(icon.get_file() != null);
            assert_true(icon.get_file().get_uri().has_prefix("resource:///im/dinox/dinox/"));
        }
    }
}

}
