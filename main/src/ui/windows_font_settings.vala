/*
 * Copyright (C) 2026 DinoX Team
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui {

// The Vala binding passes GValue by value and loses the value GTK writes back.
// This API requires an initialized, mutable GValue location.
[CCode (cname = "gdk_display_get_setting", cheader_filename = "gtk/gtk.h")]
private extern bool get_windows_display_setting(Gdk.Display display, string name, ref Value value);

// Keep the native Windows message font when GDK can retrieve it. Querying the
// setting does not enumerate or load font families, which is important during
// early GDK-Win32 startup. This helper is platform-independent for native tests.
internal class WindowsFontSettings : Object {
    internal const string FALLBACK_FONT = "Segoe UI 11";

    internal static string readable_interface_font(string font, int dpi) {
        if (!is_usable_font(font)) return FALLBACK_FONT;
        var description = Pango.FontDescription.from_string(font);
        double minimum = 11 * Pango.SCALE;
        if (description.get_size_is_absolute()) {
            minimum *= (dpi > 0 ? dpi / 1024.0 : 96.0) / 72.0;
        }
        if (description.get_size() >= minimum) return font;
        if (description.get_size_is_absolute()) description.set_absolute_size(Math.ceil(minimum));
        else description.set_size((int) minimum);
        return description.to_string();
    }

    internal static void apply_for_display(Gtk.Settings settings, Gdk.Display display) {
        string? font;
        bool found = try_native_font(display, out font);
        apply_backend_font(settings, found, font);
    }

    internal static ulong watch_display(Gtk.Settings settings, Gdk.Display display) {
        var settings_ref = WeakRef(settings);
        var display_ref = WeakRef(display);
        return display.setting_changed.connect((name) => {
            var target_settings = settings_ref.get() as Gtk.Settings;
            var target_display = display_ref.get() as Gdk.Display;
            if ((name == "gtk-font-name" || name == "gtk-xft-dpi") &&
                    target_settings != null && target_display != null) {
                apply_for_display(target_settings, target_display);
            }
        });
    }

    internal static void apply_rendering(Gtk.Settings settings) {
        // GTK 4.16+ otherwise ignores these options in its automatic mode.
        // Look up the property at runtime to keep the GTK 4.14 build baseline.
        if (settings.get_class().find_property("gtk-font-rendering") != null) {
            settings.set("gtk-font-rendering", 1); // Gtk.FontRendering.MANUAL
        }
        settings.gtk_hint_font_metrics = true;
        settings.gtk_xft_antialias = 1;
        settings.gtk_xft_hinting = 1;
        settings.gtk_xft_hintstyle = "hintslight";
        // Allow GDK to supply the display's text resolution.
    }

    internal static bool try_native_font(Gdk.Display display, out string? font) {
        Value value = Value(typeof(string));
        bool found = get_windows_display_setting(display, "gtk-font-name", ref value);
        font = found ? value.get_string() : null;
        return found;
    }

    internal static bool apply_backend_font(Gtk.Settings settings, bool found, string? font) {
        if (found && is_usable_font(font)) {
            // Refresh the native choice before applying the readability floor.
            // Display setting changes reapply it, including larger system fonts.
            settings.reset_property("gtk-font-name");
            string native_font = settings.gtk_font_name;
            string readable_font = readable_interface_font(native_font, settings.gtk_xft_dpi);
            if (readable_font != native_font) settings.gtk_font_name = readable_font;
            return true;
        }
        settings.gtk_font_name = FALLBACK_FONT;
        return false;
    }

    internal static bool is_usable_font(string? font) {
        if (font == null || !font.validate() || font.strip() == "") return false;
        int offset = 0;
        unichar character;
        while (font.get_next_char(ref offset, out character)) {
            if (character < 0x20 || character == 0x7f) return false;
        }
        var description = Pango.FontDescription.from_string(font);
        string? family = description.get_family();
        Pango.FontMask required = Pango.FontMask.FAMILY | Pango.FontMask.SIZE;
        return (description.get_set_fields() & required) == required &&
            family != null && family.strip() != "" && description.get_size() > 0;
    }
}

}
