namespace Dino.Ui.Test {

[CCode (cname = "gdk_display_get_setting", cheader_filename = "gtk/gtk.h")]
private static extern bool read_runtime_display_setting(Gdk.Display display, string name, ref Value value);

class WindowsFontSettingsRuntimeTest : Gee.TestCase {
    public WindowsFontSettingsRuntimeTest() {
        base("WindowsFontSettingsRuntime");
        add_test("native_font_descriptions_keep_family_and_explicit_size", test_native_fonts);
        add_test("missing_or_invalid_native_fonts_keep_safe_fallback", test_invalid_fonts);
        add_test("native_font_restores_session_choice_with_readable_minimum", test_session_setting);
        add_test("fallback_is_removed_when_native_setting_becomes_available", test_fallback_recovery);
        add_test("display_query_uses_native_setting_before_packaged_default", test_display_query);
        add_test("rendering_hints_reach_widgets_without_replacing_font_or_dpi", test_rendering);
        add_test("interface_minimum_retains_larger_and_absolute_fonts", test_readability);
        add_test("display_changes_refresh_the_native_font", test_display_changes);
    }

    private void test_native_fonts() {
        foreach (string font in new string[] {
                "Segoe UI 9", "Segoe UI Variable 12", "Arial 16", "Yu Gothic UI 11",
                "Noto Sans Arabic 14", "游ゴシック 12", "Sans 13.5", "Sans 15px" }) {
            fail_if_not(WindowsFontSettings.is_usable_font(font), font);
        }
    }

    private void test_invalid_fonts() {
        fail_if(WindowsFontSettings.is_usable_font(null));
        foreach (string font in new string[] {
                "", "  ", "Segoe UI", "Segoe UI 0", "0", "12", "Sans\n12", "Sans\t12" }) {
            fail_if(WindowsFontSettings.is_usable_font(font), font);
        }
        var settings = Gtk.Settings.get_default();
        try {
            fail_if(WindowsFontSettings.apply_backend_font(settings, false, "Arial 16"));
            fail_if_not_eq_str(WindowsFontSettings.FALLBACK_FONT, settings.gtk_font_name);
            foreach (string? font in new string?[] { null, "", "Arial", "Arial 0" }) {
                fail_if(WindowsFontSettings.apply_backend_font(settings, true, font));
                fail_if_not_eq_str(WindowsFontSettings.FALLBACK_FONT, settings.gtk_font_name);
            }
        } finally {
            settings.reset_property("gtk-font-name");
        }
    }

    private void test_session_setting() {
        var settings = Gtk.Settings.get_default();
        settings.reset_property("gtk-font-name");
        string session_font = WindowsFontSettings.readable_interface_font(settings.gtk_font_name, settings.gtk_xft_dpi);
        try {
            settings.gtk_font_name = "Monospace 23";
            fail_if_not(WindowsFontSettings.apply_backend_font(settings, true, "Arial 16"));
            fail_if_not_eq_str(session_font, settings.gtk_font_name,
                "the native choice must refresh the session font and its readability minimum");
            settings.gtk_font_name = "Sans 17";
            fail_if_not_eq_str("Sans 17", settings.gtk_font_name,
                "later GTK font updates must not be overwritten by a font notify callback");
        } finally {
            settings.reset_property("gtk-font-name");
        }
    }

    private void test_fallback_recovery() {
        var settings = Gtk.Settings.get_default();
        settings.reset_property("gtk-font-name");
        string session_font = WindowsFontSettings.readable_interface_font(settings.gtk_font_name, settings.gtk_xft_dpi);
        try {
            WindowsFontSettings.apply_backend_font(settings, false, null);
            fail_if_not_eq_str(WindowsFontSettings.FALLBACK_FONT, settings.gtk_font_name);
            fail_if_not(WindowsFontSettings.apply_backend_font(settings, true, "Segoe UI 13"));
            fail_if_not_eq_str(session_font, settings.gtk_font_name);
        } finally {
            settings.reset_property("gtk-font-name");
        }
    }

    private void test_display_query() {
        var settings = Gtk.Settings.get_default();
        var display = Gdk.Display.get_default();
        settings.reset_property("gtk-font-name");
        string session_font = WindowsFontSettings.readable_interface_font(settings.gtk_font_name, settings.gtk_xft_dpi);
        string? font;
        bool found = WindowsFontSettings.try_native_font(display, out font);
        Value raw = Value(typeof(string));
        bool raw_found = read_runtime_display_setting(display, "gtk-font-name", ref raw);
        fail_if(found != raw_found);
        fail_if((raw_found ? raw.get_string() : null) != font,
            "the native GValue output must survive the Vala call boundary");
        bool native_font = found && WindowsFontSettings.is_usable_font(font);
        try {
            settings.gtk_font_name = "Monospace 23";
            WindowsFontSettings.apply_for_display(settings, display);
            fail_if_not_eq_str(native_font ? session_font : WindowsFontSettings.FALLBACK_FONT,
                settings.gtk_font_name);
        } finally {
            settings.reset_property("gtk-font-name");
        }
    }

    private void test_rendering() {
        var settings = Gtk.Settings.get_default();
        string original_font = settings.gtk_font_name;
        int original_dpi = settings.gtk_xft_dpi;
        int original_antialias = settings.gtk_xft_antialias;
        int original_hinting = settings.gtk_xft_hinting;
        string? original_hintstyle = settings.gtk_xft_hintstyle;
        bool original_metrics = settings.gtk_hint_font_metrics;
        bool has_rendering = settings.get_class().find_property("gtk-font-rendering") != null;
        int original_rendering = 0;
        if (has_rendering) settings.get("gtk-font-rendering", out original_rendering);
        try {
            settings.gtk_font_name = "Sans 17";
            settings.gtk_xft_dpi = 144 * 1024;
            settings.gtk_xft_antialias = 0;
            settings.gtk_xft_hinting = 0;
            settings.gtk_hint_font_metrics = false;
            if (has_rendering) settings.set("gtk-font-rendering", 0);

            WindowsFontSettings.apply_rendering(settings);

            fail_if_not_eq_str("Sans 17", settings.gtk_font_name);
            fail_if_not_eq_int(144 * 1024, settings.gtk_xft_dpi,
                "rendering must preserve the display's text resolution");
            var label = new Gtk.Label("Windows interface text: ÄÖÜ 0123456789");
            var context = label.get_pango_context();
            unowned Cairo.FontOptions? options = Pango.cairo_context_get_font_options(context);
            if (fail_if(options == null, "the widget must expose its effective font options")) return;
            fail_if(options.get_antialias() == Cairo.Antialias.NONE,
                "interface text must be antialiased");
            fail_if(options.get_hint_metrics() != Cairo.HintMetrics.ON,
                "GTK must use the requested grid-fitted metrics, including on GTK 4.16+");
            fail_if(options.get_hint_style() != Cairo.HintStyle.SLIGHT);
            fail_if_not(context.get_round_glyph_positions(),
                "fractional glyph positions must not bypass metrics hinting");
        } finally {
            settings.gtk_font_name = original_font;
            settings.gtk_xft_dpi = original_dpi;
            settings.gtk_xft_antialias = original_antialias;
            settings.gtk_xft_hinting = original_hinting;
            settings.gtk_xft_hintstyle = original_hintstyle;
            settings.gtk_hint_font_metrics = original_metrics;
            if (has_rendering) settings.set("gtk-font-rendering", original_rendering);
        }
    }

    private void test_readability() {
        fail_if_not_eq_str("Segoe UI 11", WindowsFontSettings.readable_interface_font("Segoe UI 9", 96 * 1024));
        foreach (string font in new string[] { "Arial 16", "Yu Gothic UI 12", "Noto Sans Arabic 14", "Sans 18px" }) {
            fail_if_not_eq_str(font, WindowsFontSettings.readable_interface_font(font, 96 * 1024));
        }
        var absolute = Pango.FontDescription.from_string(WindowsFontSettings.readable_interface_font("Segoe UI 12px", 144 * 1024));
        fail_if_not(absolute.get_size_is_absolute());
        fail_if_not_eq_int(22 * Pango.SCALE, absolute.get_size());
        fail_if_not_eq_str("Segoe UI", absolute.get_family());
    }

    private void test_display_changes() {
        var settings = Gtk.Settings.get_default();
        var display = Gdk.Display.get_default();
        WindowsFontSettings.apply_for_display(settings, display);
        string native_font = settings.gtk_font_name;
        ulong handler = WindowsFontSettings.watch_display(settings, display);
        try {
            settings.gtk_font_name = "Monospace 23";
            display.setting_changed("gtk-font-name");
            fail_if_not_eq_str(native_font, settings.gtk_font_name,
                "a later native font change must retire the previous application override");
            settings.gtk_font_name = "Monospace 23";
            display.setting_changed("gtk-xft-dpi");
            fail_if_not_eq_str(native_font, settings.gtk_font_name);
        } finally {
            display.disconnect(handler);
            settings.reset_property("gtk-font-name");
        }
    }
}

}
