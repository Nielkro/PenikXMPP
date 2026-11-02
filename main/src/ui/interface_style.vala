namespace Dino.Ui {

// Only presentation choices may be read before unlocking. The encrypted
// settings remain authoritative and refresh this mirror after every unlock.
// Keeping it inside the profile also includes it in profile restore/deletion.
public class StartupAppearance : Object {
    public string interface_style { get; private set; default = "classic"; }
    public string color_scheme { get; private set; default = "dark"; }
    public string accent_color { get; private set; default = "default"; }
    public string window_controls { get; private set; default = "system"; }
    private const string FILENAME = "appearance.ini";

    private static bool allowed(string value, string[] choices) {
        return value in choices;
    }

    public static StartupAppearance load(string profile) {
        var result = new StartupAppearance();
        // An orphaned mirror must not change a new profile's defaults.
        if (!FileUtils.test(Path.build_filename(profile, "dino.db"), FileTest.IS_REGULAR)) return result;
        try {
            var file = File.new_for_path(Path.build_filename(profile, FILENAME));
            var info = file.query_info("standard::size,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (info.get_file_type() != FileType.REGULAR || info.get_size() > 1024) return result;
            var keyfile = new KeyFile();
            keyfile.load_from_file(file.get_path(), KeyFileFlags.NONE);
            string style = keyfile.get_string("Appearance", "style");
            string scheme = keyfile.get_string("Appearance", "scheme");
            string accent = keyfile.get_string("Appearance", "accent");
            if (!allowed(style, { "classic", "website" }) ||
                    !allowed(scheme, { "default", "light", "dark" }) ||
                    !allowed(accent, { "default", "blue", "green", "yellow", "orange", "red", "purple" })) return result;
            result.interface_style = style;
            result.color_scheme = scheme;
            result.accent_color = accent;
            if (keyfile.has_key("Appearance", "window-controls")) {
                string placement = keyfile.get_string("Appearance", "window-controls");
                if (allowed(placement, { "system", "left", "right" })) result.window_controls = placement;
            }
        } catch (Error error) {
            // Missing or damaged presentation metadata must never block login.
            debug("Startup appearance unavailable: %s", error.message);
        }
        return result;
    }

    public static void save(string profile, string style, string scheme, string accent, string window_controls = "system") {
        var keyfile = new KeyFile();
        keyfile.set_string("Appearance", "window-controls",
            allowed(window_controls, { "left", "right" }) ? window_controls : "system");
        keyfile.set_string("Appearance", "style", style == "website" ? "website" : "classic");
        keyfile.set_string("Appearance", "scheme", allowed(scheme, { "light", "dark" }) ? scheme : "default");
        keyfile.set_string("Appearance", "accent",
            allowed(accent, { "blue", "green", "yellow", "orange", "red", "purple" }) ? accent : "default");
        try {
            string data = keyfile.to_data();
            File.new_for_path(Path.build_filename(profile, FILENAME)).replace_contents(
                data.data, null, false, FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION, null);
        } catch (Error error) {
            debug("Could not save startup appearance: %s", error.message);
        }
    }
}

// Optional palette only: widget layout, semantic colors and system accessibility
// remain owned by GTK/libadwaita. The encrypted profile supplies the selection.
public class InterfaceStyle : Object {
    private Gtk.CssProvider? palette;
    private Gtk.CssProvider? variables;
    private Gtk.CssProvider? dialogs;
    private Gdk.Display display;
    private Adw.StyleManager manager;
    private ulong dark_handler;
    private ulong contrast_handler;
    private string selected = "classic";

    [CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
    private static extern void add_provider(Gdk.Display display, Gtk.StyleProvider provider, uint priority);
    [CCode (cname = "gtk_style_context_remove_provider_for_display", cheader_filename = "gtk/gtk.h")]
    private static extern void remove_provider(Gdk.Display display, Gtk.StyleProvider provider);

    public InterfaceStyle(Gdk.Display display) {
        this.display = display;
        manager = Adw.StyleManager.get_default();
        dark_handler = manager.notify["dark"].connect(refresh);
        contrast_handler = manager.notify["high-contrast"].connect(refresh);
    }

    public void apply(string style) {
        selected = style;
        refresh();
    }

    private void clear() {
        if (palette != null) remove_provider(display, palette);
        if (variables != null) remove_provider(display, variables);
        if (dialogs != null) remove_provider(display, dialogs);
        palette = null;
        variables = null;
        dialogs = null;
    }

    private void refresh() {
        clear();
        if (selected != "website" || manager.high_contrast) return;
        palette = new Gtk.CssProvider();
        palette.load_from_resource(manager.dark
            ? "/im/dinox/dinox/website-dark.css"
            : "/im/dinox/dinox/website-light.css");
        add_provider(display, palette, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5);
        dialogs = new Gtk.CssProvider();
        dialogs.load_from_resource("/im/dinox/dinox/website-dialogs.css");
        add_provider(display, dialogs, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5);

        // libadwaita 1.6+ uses CSS custom properties (GTK 4.16+). Older GTK
        // must never parse this sheet. Named colors still serve DinoX's CSS.
        if (Gtk.get_major_version() > 4 || Gtk.get_minor_version() >= 16) {
            variables = new Gtk.CssProvider();
            variables.load_from_resource("/im/dinox/dinox/website-variables.css");
            add_provider(display, variables, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5);
        }
    }

    public void close() {
        if (dark_handler != 0) manager.disconnect(dark_handler);
        if (contrast_handler != 0) manager.disconnect(contrast_handler);
        dark_handler = 0;
        contrast_handler = 0;
        clear();
    }

    public override void dispose() {
        close();
        base.dispose();
    }
}

}
