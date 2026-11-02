/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Linux Systray - StatusNotifierItem (SNI) with an in-tree DBusMenu exporter.
 * Works natively on KDE, Cinnamon, MATE, XFCE.
 * On GNOME, requires AppIndicator/KStatusNotifierItem extension.
 * Falls back to GApplication.hold() if no SNI watcher is available.
 */

using Gtk;
using Gee;
using GLib;
using Dino.Entities;

namespace Dino.Ui {

// Plain data holder for SNI properties.
// D-Bus registration is done manually via systray_sni_dbus.c
// so we can export IconPixmap as the correct a(iiay) type.
public class StatusNotifierItem : Object {

    public string status { get; set; default = "Active"; }
    public string icon_name { get; set; default = "im.dinox.dinox"; }
    public string title { get; set; default = "DinoX"; }
    public string category { get; set; default = "Communications"; }
    public string id { get; set; default = "dinox"; }
    public bool item_is_menu { get; set; default = false; }
    public string icon_theme_path { get; set; default = ""; }

    // IconPixmap variant of type a(iiay) for Qt-based trays (Quickshell, etc.)
    private GLib.Variant? _icon_pixmap = null;

    public signal void activate(int x, int y);
    public signal void secondary_activate(int x, int y);

    // Return the D-Bus value for a given property name
    public GLib.Variant? get_dbus_property(string name) {
        switch (name) {
            case "Status":        return new Variant.string(status);
            case "IconName":      return new Variant.string(icon_name);
            case "IconThemePath": return new Variant.string(icon_theme_path);
            case "Title":         return new Variant.string(title);
            case "Category":      return new Variant.string(category);
            case "Id":            return new Variant.string(id);
            case "ItemIsMenu":    return new Variant.boolean(item_is_menu);
            case "Menu":          return new Variant.object_path("/MenuBar");
            case "IconPixmap":    return get_icon_pixmap();
            default:              return null;
        }
    }

    private GLib.Variant get_icon_pixmap() {
        if (_icon_pixmap != null) return _icon_pixmap;
        return new Variant("a(iiay)", null);
    }

    // Load icon PNGs as ARGB32 pixel data for IconPixmap.
    // Also sets icon_theme_path so Qt trays can find the icon by name.
    public void load_icon_pixmaps() {
        string icon_id = "im.dinox.dinox";
        int[] sizes = {32, 48};

        string? hicolor = find_hicolor_dir(icon_id);
        if (hicolor == null) {
            debug("Systray: no hicolor dir found for IconPixmap");
            return;
        }

        // Set IconThemePath to the parent of hicolor so Qt/KDE trays
        // can look up the icon by name (e.g. /usr/share/icons).
        string icons_dir = Path.get_dirname(hicolor);
        if (icons_dir.length > 0) {
            icon_theme_path = icons_dir;
            debug("Systray: IconThemePath set to %s (from %s)", icons_dir, hicolor);
        }

        var builder = new VariantBuilder(new VariantType("a(iiay)"));
        int count = 0;

        foreach (int sz in sizes) {
            string path = Path.build_filename(hicolor, "%dx%d".printf(sz, sz), "apps", icon_id + ".png");
            uint8[]? argb = load_png_as_argb32(path, sz);
            if (argb == null) continue;

            var bytes_builder = new VariantBuilder(new VariantType("ay"));
            foreach (uint8 b in argb) {
                bytes_builder.add("y", b);
            }
            builder.add("(ii@ay)", (int32) sz, (int32) sz, bytes_builder.end());
            count++;
            debug("Systray: IconPixmap loaded %dx%d", sz, sz);
        }

        if (count > 0) {
            _icon_pixmap = builder.end();
            // Keep icon_name set! Tray hosts that support IconPixmap will use
            // the pixel data; older hosts fall back to IconName + IconThemePath.
            debug("Systray: IconPixmap ready (%d sizes)", count);
        }
    }

    private string? find_hicolor_dir(string icon_id) {
        string[] dirs = {};

        string? appdir = Environment.get_variable("APPDIR");
        if (appdir != null) {
            dirs += Path.build_filename(appdir, "usr", "share", "icons", "hicolor");
        }

        // Executable-relative paths: handles both installed prefix layout
        // (bin/../share/icons) and running from build dir (build/main/../../main/data/icons).
        try {
            string exe = FileUtils.read_link("/proc/self/exe");
            string exe_dir = Path.get_dirname(exe);
            // Installed: /usr[/local]/bin/dinox → ../share/icons/hicolor
            dirs += Path.build_filename(exe_dir, "..", "share", "icons", "hicolor");
            // Build dir: build/main/dinox → ../../main/data/icons/hicolor
            dirs += Path.build_filename(exe_dir, "..", "..", "main", "data", "icons", "hicolor");
        } catch (FileError e) {
            // /proc/self/exe not available (non-Linux) — skip
        }

        string? xdg = Environment.get_variable("XDG_DATA_DIRS");
        if (xdg != null) {
            foreach (string d in xdg.split(":")) {
                if (d.length > 0) dirs += Path.build_filename(d, "icons", "hicolor");
            }
        }
        dirs += "/usr/local/share/icons/hicolor";
        dirs += "/usr/share/icons/hicolor";

        foreach (string dir in dirs) {
            string test = Path.build_filename(dir, "48x48", "apps", icon_id + ".png");
            if (FileUtils.test(test, FileTest.IS_REGULAR)) return dir;
        }
        return null;
    }

    private uint8[]? load_png_as_argb32(string path, int size) {
        if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;

        try {
            var pb = new Gdk.Pixbuf.from_file_at_size(path, size, size);
            if (pb == null) return null;
            if (!pb.get_has_alpha()) pb = pb.add_alpha(false, 0, 0, 0);

            int w = pb.get_width();
            int h = pb.get_height();
            int rs = pb.get_rowstride();
            unowned uint8[] px = pb.get_pixels();

            // GdkPixbuf RGBA -> SNI ARGB32 network byte order (A R G B)
            uint8[] argb = new uint8[w * h * 4];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int s = y * rs + x * 4;
                    int d = (y * w + x) * 4;
                    argb[d]     = px[s + 3]; // A
                    argb[d + 1] = px[s];     // R
                    argb[d + 2] = px[s + 1]; // G
                    argb[d + 3] = px[s + 2]; // B
                }
            }
            return argb;
        } catch (Error e) {
            return null;
        }
    }
}

public class SystrayManager : Object {
    
    private unowned Application application;
    public MainWindow? window;
    private StatusNotifierItem? status_notifier;
    private SystrayDbusMenu.Server? menu_server;
    private uint dbus_id = 0;
    private DBusConnection? connection;
    private ulong status_changed_id = 0;
    private ulong notifications_changed_id = 0;
    private ulong notification_sounds_changed_id = 0;
    private ulong menu_dark_changed_id = 0;
    private ulong menu_contrast_changed_id = 0;
    private uint[] watcher_ids = {};
    private HashTable<string, string> watcher_owners = new HashTable<string, string>(str_hash, str_equal);
    private HashTable<string, uint> watcher_attempts = new HashTable<string, uint>(str_hash, str_equal);
    private HashTable<string, bool> registered_owners = new HashTable<string, bool>(str_hash, str_equal);
    private uint next_watcher_attempt = 0;
    private bool holding = false;
    private bool menu_icons_initialized = false;
    private bool menu_icons_dark = false;
    private bool menu_icons_high_contrast = false;
    private bool menu_icons_sound = false;
    private bool menu_icons_notifications = false;

    private const int MENU_STATUS_FIRST_ID = 1;
    private const int MENU_STATUS_LAST_ID = 4;
    private const int MENU_STATUS_MESSAGE_ID = 5;
    private const int MENU_SOUND_ID = 6;
    private const int MENU_NOTIFICATIONS_ID = 7;
    private const int MENU_PREFERENCES_ID = 9;
    private const int MENU_QUIT_ID = 11;
    
    public bool is_hidden {
        get { return window != null && !window.is_visible(); }
    }
    
    public SystrayManager(Application application) {
        this.application = application;
        initialize_dbus.begin();
    }
    
    public void set_window(MainWindow window) {
        this.window = window;
        
        window.close_request.connect(() => {
            // Check if background mode is enabled
            if (Dino.Application.get_default().settings.keep_background) {
                // Keep running in background - just hide the window
                hide_window();
                return true;  // Prevent window destruction
            } else {
                // User wants normal quit - quit the application
                quit_application();
                return true;  // Handler handled
            }
        });
    }
    
    public void quit_application() {
        debug("Systray: quit_application() called");

        // Hide window immediately for instant visual feedback
        if (window != null) {
            window.set_visible(false);
        }

        // Cleanup systray (DBus unregister etc.)
        cleanup();

        // Use disconnect_all() to close connections WITHOUT firing account_removed.
        // stream_interactor.disconnect_account() fires account_removed which
        // causes the OMEMO plugin to DELETE all identity keys and sessions.
        debug("Systray: Disconnecting all accounts...");
        application.stream_interactor.connection_manager.disconnect_all();

        finalize_quit();
    }
    
    private void finalize_quit() {
        // Graceful GTK quit — triggers application.shutdown() for final cleanup.
        // shutdown() handles cleanup_temp_files() and disconnect_all() (no-op since
        // connections are already cleared above).
        debug("Systray: Calling application.quit()");
        application.quit();

        // Force exit only as a delayed fallback.  A synchronous Process.exit()
        // here would skip app.run() unwinding and plugin shutdown.
        Timeout.add(1500, () => {
            // Plugins may run a nested main loop while draining owned
            // subprocesses. Do not interrupt that cleanup with Process.exit.
            if (application.plugin_shutdown_in_progress) return Source.CONTINUE;
            debug("Systray: Force exit fallback");
            application.shutdown_plugins_once();
            force_process_exit();
            return Source.REMOVE;
        });
    }

    private void force_process_exit() {
        Process.exit(0);
    }
    
    private async void initialize_dbus() {
        try {
            var conn = yield Bus.get(BusType.SESSION);
            if (disposed) return;
            connection = conn;
            
            status_notifier = new StatusNotifierItem();

            // Load inline pixel data and set IconThemePath based on where
            // the icon was actually found — not hardcoded.  This ensures
            // Qt-based trays (KDE Plasma, LXQt) can find the icon both
            // when installed and when running from the build directory.
            status_notifier.load_icon_pixmaps();
            
            menu_server = new SystrayDbusMenu.Server(connection, "/MenuBar",
                menu_item_activated_cb, (void*) this);

            // Connect to PresenceManager status changes
            var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            status_changed_id = pm.status_changed.connect((show, msg) => {
                update_status_items(show, msg);
            });
            notifications_changed_id = application.settings.notify["notifications"].connect(() => {
                update_status_items(pm.get_current_show(), pm.get_current_status_msg());
            });
            notification_sounds_changed_id = application.settings.notify["notification-sounds"].connect(() => {
                update_status_items(pm.get_current_show(), pm.get_current_status_msg());
            });
            var style = Adw.StyleManager.get_default();
            menu_dark_changed_id = style.notify["dark"].connect(() => {
                update_status_items(pm.get_current_show(), pm.get_current_status_msg());
            });
            menu_contrast_changed_id = style.notify["high-contrast"].connect(() => {
                update_status_items(pm.get_current_show(), pm.get_current_status_msg());
            });
            update_status_items(pm.get_current_show(), pm.get_current_status_msg());
            
            debug("Systray: DBusMenu server initialized on /MenuBar");
            
            // Register SNI via C helper (supports IconPixmap a(iiay) type)
            dbus_id = SniDbus.register(connection, "/StatusNotifierItem",
                sni_get_property_cb, sni_method_call_cb, (void*) this);
            
            debug("Systray: StatusNotifierItem registered on D-Bus");
            
            start_watching();
            
        } catch (Error e) {
            warning("Systray: Failed to initialize D-Bus: %s", e.message);
            // Fallback: hold application so it stays alive when window is hidden
            hold_app();
            debug("Systray: Using GApplication.hold() fallback for background mode");
        }
    }
    
    private void start_watching() {
        // Cinnamon can expose only org.x. Watch both names, but register once
        // when a host owns both aliases. Never activate a desktop service here.
        string[] names = {"org.kde.StatusNotifierWatcher", "org.x.StatusNotifierWatcher"};
        foreach (string watcher_name in names) {
            watcher_ids += Bus.watch_name(BusType.SESSION, watcher_name,
                BusNameWatcherFlags.NONE,
                (conn, name, owner) => {
                    if (disposed) return;
                    watcher_owners.insert(name, owner);
                    if (watcher_attempts.contains(owner)) return;
                    uint attempt = ++next_watcher_attempt;
                    watcher_attempts.insert(owner, attempt);
                    register_with_watcher.begin(owner, attempt);
                },
                (conn, name) => {
                    if (disposed) return;
                    string? owner = watcher_owners.lookup(name);
                    watcher_owners.remove(name);
                    bool still_present = false;
                    if (owner != null) {
                        watcher_owners.foreach((other_name, other_owner) => {
                            if (other_owner == owner) still_present = true;
                        });
                        if (!still_present) {
                            watcher_attempts.remove(owner);
                            registered_owners.remove(owner);
                        }
                    }
                    if (registered_owners.size() == 0) hold_app();
                }
            );
        }
    }
    
    private async void register_with_watcher(string owner, uint attempt) {
        if (disposed || connection == null) return;
        try {
            StatusNotifierWatcher watcher = yield connection.get_proxy(
                owner,
                "/StatusNotifierWatcher",
                DBusProxyFlags.DO_NOT_AUTO_START
            );

            if (disposed || connection == null || watcher_attempts.lookup(owner) != attempt) return;
            string service_name = connection.unique_name;
            yield watcher.register_status_notifier_item(service_name);
            // The host may disappear, or DinoX may shut down while awaiting
            // the reply. An old completion must not revive a tray export.
            if (disposed || connection == null || watcher_attempts.lookup(owner) != attempt) return;
            registered_owners.insert(owner, true);
            debug("Systray: Successfully registered with %s as %s", owner, service_name);
        
            // Emit NewIcon so the tray host refreshes the icon immediately.
            // KDE Plasma sometimes caches a placeholder if it fetches
            // properties before the watcher registration completes.
            if (connection != null && !connection.is_closed()) {
                SniDbus.emit_signal(connection, "/StatusNotifierItem",
                    "NewIcon", null);
            }
        } catch (Error e) {
            if (disposed || watcher_attempts.lookup(owner) != attempt) return;
            watcher_attempts.remove(owner);
            debug("Systray: Watcher registration failed: %s", e.message);
            hold_app();
        }
    }
    
    public void toggle_window_visibility() {
        if (window == null) return;
        
        if (!window.is_visible()) {
            show_window();
        } else {
            hide_window();
        }
    }
    
    private void show_window() {
        if (window == null) return;
        
        window.present();
        window.set_visible(true);
    }
    
    public void hide_window() {
        if (window == null) return;

        Conversation? conversation = null;
        if (application.controller != null) {
            conversation = application.controller.conversation;
        }
        application.stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_window_focus_out(conversation);

        window.set_visible(false);
    }

    private void open_preferences() {
        show_window();
        application.activate_action("preferences-page", new Variant.string("general"));
    }
    
    private void update_status_items(string current_status, string? status_msg) {
        if (menu_server == null) return;

        menu_server.set_rtl(Gtk.Widget.get_default_direction() == Gtk.TextDirection.RTL);
        update_menu_icons();

        string[] statuses = {"online", "away", "dnd", "xa"};
        string[] labels = {_("Online"), _("Away"), _("Busy"), _("Not Available")};
        string?[] menu_labels = new string?[13];
        uint32 checked_mask = 0;

        menu_labels[0] = "";

        for (int i = 0; i < statuses.length; i++) {
            int item_id = MENU_STATUS_FIRST_ID + i;
            menu_labels[item_id] = labels[i];
            if (statuses[i] == current_status) {
                checked_mask |= (1u << (item_id - 1));
            }
        }
        if (status_msg != null && status_msg.strip() != "") {
            menu_labels[MENU_STATUS_MESSAGE_ID] = _("Status Message: %s").printf(status_msg.strip());
        } else {
            menu_labels[MENU_STATUS_MESSAGE_ID] = _("Set Status Message…");
        }
        menu_labels[MENU_SOUND_ID] = _("Sound");
        menu_labels[MENU_NOTIFICATIONS_ID] = _("Notify");
        if (application.settings.notification_sounds) checked_mask |= (1u << (MENU_SOUND_ID - 1));
        if (application.settings.notifications) checked_mask |= (1u << (MENU_NOTIFICATIONS_ID - 1));
        menu_labels[8] = "";
        menu_labels[MENU_PREFERENCES_ID] = _("Preferences");
        menu_labels[10] = "";
        menu_labels[MENU_QUIT_ID] = _("Quit");
        menu_labels[12] = null;

        menu_server.set_menu(menu_labels, checked_mask);

        // SNI status describes the tray item, not the XMPP presence.
        // Keep the signal consistent with the exported Status property.
        if (status_notifier != null) emit_new_status(status_notifier.status);
    }

    private void update_menu_icons() {
        if (disposed || menu_server == null) return;
        var style = Adw.StyleManager.get_default();
        if (menu_icons_initialized && menu_icons_dark == style.dark &&
            menu_icons_high_contrast == style.high_contrast &&
            menu_icons_sound == application.settings.notification_sounds &&
            menu_icons_notifications == application.settings.notifications) return;
        int[] item_ids = {1, 2, 3, 4, MENU_STATUS_MESSAGE_ID, MENU_SOUND_ID,
            MENU_NOTIFICATIONS_ID, MENU_PREFERENCES_ID, MENU_QUIT_ID};
        foreach (int item_id in item_ids) {
            menu_server.set_icon_data(item_id, render_menu_icon(item_id, style.dark, style.high_contrast));
        }
        menu_icons_initialized = true;
        menu_icons_dark = style.dark;
        menu_icons_high_contrast = style.high_contrast;
        menu_icons_sound = application.settings.notification_sounds;
        menu_icons_notifications = application.settings.notifications;
    }

    // DBusMenu carries transparent PNG icons; the desktop host still owns the
    // menu background. A contrasting outline keeps these legible on either host theme.
    private Bytes? render_menu_icon(int item_id, bool dark, bool high_contrast) {
        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 48, 48);
        var cr = new Cairo.Context(surface);
        cr.scale(2, 2);
        cr.set_line_cap(Cairo.LineCap.ROUND);
        cr.set_line_join(Cairo.LineJoin.ROUND);

        double r = dark ? 0.60 : 0.11;
        double g = dark ? 0.76 : 0.44;
        double b = dark ? 0.95 : 0.85;
        bool enabled = item_id != MENU_SOUND_ID || application.settings.notification_sounds;
        if (item_id == MENU_NOTIFICATIONS_ID) enabled = application.settings.notifications;
        if (item_id == 1 || item_id == MENU_SOUND_ID) { r = 0.32; g = 0.70; b = 0.38; }
        if (item_id == 2) { r = 1.0; g = 0.65; b = 0.15; }
        if (item_id == 3 || item_id == MENU_QUIT_ID) { r = 0.90; g = 0.33; b = 0.33; }
        if (item_id == 4 || !enabled) { r = 0.50; g = 0.50; b = 0.50; }
        if (high_contrast) { r = g = b = dark ? 1.0 : 0.0; }

        if (item_id >= MENU_STATUS_FIRST_ID && item_id <= MENU_STATUS_LAST_ID) {
            cr.arc(12, 12, 8, 0, 2 * Math.PI);
            if (item_id != 4) {
                cr.set_source_rgb(r, g, b);
                cr.fill_preserve();
            }
            stroke_menu_icon(cr, dark, r, g, b);
            // The clock, minus and hollow circle remain distinguishable without color.
            if (item_id == 2) { cr.move_to(12, 7); cr.line_to(12, 12); cr.line_to(16, 12); }
            if (item_id == 3) { cr.move_to(8, 12); cr.line_to(16, 12); }
            if (item_id == 2 || item_id == 3) {
                double mark = high_contrast ? (dark ? 0.0 : 1.0) : 1.0;
                cr.set_source_rgb(mark, mark, mark);
                cr.set_line_width(2);
                cr.stroke();
            }
        } else if (item_id == MENU_STATUS_MESSAGE_ID) {
            cr.move_to(5, 16); cr.line_to(15, 6); cr.line_to(18, 9);
            cr.line_to(8, 19); cr.line_to(4, 20); cr.close_path();
            stroke_menu_icon(cr, dark, r, g, b);
        } else if (item_id == MENU_SOUND_ID) {
            cr.move_to(4, 9); cr.line_to(8, 9); cr.line_to(12, 5);
            cr.line_to(12, 19); cr.line_to(8, 15); cr.line_to(4, 15); cr.close_path();
            if (enabled) {
                cr.new_sub_path(); cr.arc(12, 12, 5, -0.70, 0.70);
                cr.new_sub_path(); cr.arc(12, 12, 9, -0.70, 0.70);
            } else {
                cr.move_to(16, 9); cr.line_to(21, 15);
                cr.move_to(21, 9); cr.line_to(16, 15);
            }
            stroke_menu_icon(cr, dark, r, g, b);
        } else if (item_id == MENU_NOTIFICATIONS_ID) {
            cr.move_to(5, 17); cr.line_to(7, 14); cr.line_to(7, 10);
            cr.curve_to(7, 3, 17, 3, 17, 10); cr.line_to(17, 14);
            cr.line_to(19, 17); cr.close_path();
            cr.move_to(10, 20); cr.line_to(14, 20);
            if (!enabled) { cr.move_to(4, 4); cr.line_to(20, 20); }
            stroke_menu_icon(cr, dark, r, g, b);
        } else if (item_id == MENU_PREFERENCES_ID) {
            for (int i = 0; i < 24; i++) {
                double angle = (i * Math.PI / 12.0) - Math.PI / 2;
                double radius = (i % 4 == 0 || i % 4 == 3) ? 9 : 7;
                double x = 12 + radius * Math.cos(angle);
                double y = 12 + radius * Math.sin(angle);
                if (i == 0) cr.move_to(x, y); else cr.line_to(x, y);
            }
            cr.close_path(); cr.new_sub_path(); cr.arc(12, 12, 3, 0, 2 * Math.PI);
            stroke_menu_icon(cr, dark, r, g, b);
        } else if (item_id == MENU_QUIT_ID) {
            cr.arc(12, 13, 8, -Math.PI / 4, 5 * Math.PI / 4);
            cr.move_to(12, 3); cr.line_to(12, 12);
            stroke_menu_icon(cr, dark, r, g, b);
        }

        var data = new ByteArray();
        if (surface.write_to_png_stream((chunk) => {
            data.append(chunk);
            return Cairo.Status.SUCCESS;
        }) != Cairo.Status.SUCCESS) return null;
        return ByteArray.free_to_bytes((owned) data);
    }

    private void stroke_menu_icon(Cairo.Context cr, bool dark, double r, double g, double b) {
        double outline = dark ? 0.08 : 1.0;
        cr.set_source_rgba(outline, outline, outline, 0.85);
        cr.set_line_width(4);
        cr.stroke_preserve();
        cr.set_source_rgb(r, g, b);
        cr.set_line_width(2);
        cr.stroke();
    }
    
    private bool disposed = false;

    private void hold_app() {
        if (!holding) {
            application.hold();
            holding = true;
        }
    }

    private void release_app() {
        if (holding) {
            application.release();
            holding = false;
        }
    }
    
    public void cleanup() {
        if (disposed) {
            return;
        }
        disposed = true;
        
        foreach (uint watcher_id in watcher_ids) Bus.unwatch_name(watcher_id);
        watcher_ids = {};
        watcher_owners.remove_all();
        watcher_attempts.remove_all();
        registered_owners.remove_all();
        
        if (status_changed_id != 0) {
            var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            SignalHandler.disconnect(pm, status_changed_id);
            status_changed_id = 0;
        }
        if (notifications_changed_id != 0) {
            SignalHandler.disconnect(application.settings, notifications_changed_id);
            notifications_changed_id = 0;
        }
        if (notification_sounds_changed_id != 0) {
            SignalHandler.disconnect(application.settings, notification_sounds_changed_id);
            notification_sounds_changed_id = 0;
        }
        if (menu_dark_changed_id != 0 || menu_contrast_changed_id != 0) {
            var style = Adw.StyleManager.get_default();
            if (menu_dark_changed_id != 0) {
                SignalHandler.disconnect(style, menu_dark_changed_id);
                menu_dark_changed_id = 0;
            }
            if (menu_contrast_changed_id != 0) {
                SignalHandler.disconnect(style, menu_contrast_changed_id);
                menu_contrast_changed_id = 0;
            }
        }

        if (connection != null && !connection.is_closed() && dbus_id != 0) {
            connection.unregister_object(dbus_id);
            dbus_id = 0;
        }
        
        release_app();

        menu_server = null;
        status_notifier = null;
        connection = null;
    }

    ~SystrayManager() {
        cleanup();
    }

    // --- Static D-Bus callbacks for the C helper ---

    private static GLib.Variant? sni_get_property_cb(string property_name, void* user_data) {
        unowned SystrayManager self = (SystrayManager) user_data;
        if (self.disposed || self.status_notifier == null) return null;
        return self.status_notifier.get_dbus_property(property_name);
    }

    private static void sni_method_call_cb(string method_name, GLib.Variant parameters,
                                            GLib.DBusMethodInvocation invocation, void* user_data) {
        unowned SystrayManager self = (SystrayManager) user_data;
        if (self.disposed) {
            invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", "Shutting down");
            return;
        }
        switch (method_name) {
            case "Activate":
            case "SecondaryActivate":
                self.toggle_window_visibility();
                invocation.return_value(null);
                break;
            case "ContextMenu":
                debug("Systray: ContextMenu called");
                invocation.return_value(null);
                break;
            case "Scroll":
                invocation.return_value(null);
                break;
            default:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod",
                    "Unknown method: " + method_name);
                break;
        }
    }

    private static void menu_item_activated_cb(int item_id, void* user_data) {
        unowned SystrayManager self = (SystrayManager) user_data;
        if (self.disposed) return;

        string[] statuses = {"online", "away", "dnd", "xa"};
        if (item_id >= MENU_STATUS_FIRST_ID && item_id <= MENU_STATUS_LAST_ID) {
            self.application.activate_action("set-status", new Variant.string(statuses[item_id - 1]));
        } else if (item_id == MENU_STATUS_MESSAGE_ID) {
            self.show_window();
            self.application.activate_action("set-status-message", null);
        } else if (item_id == MENU_SOUND_ID) {
            self.application.settings.notification_sounds = !self.application.settings.notification_sounds;
        } else if (item_id == MENU_NOTIFICATIONS_ID) {
            self.application.settings.notifications = !self.application.settings.notifications;
        } else if (item_id == MENU_PREFERENCES_ID) {
            self.open_preferences();
        } else if (item_id == MENU_QUIT_ID) {
            Timeout.add(50, () => {
                self.quit_application();
                return false;
            });
        }
    }

    // Emit D-Bus signals (replaces [DBus] auto-generated signal emission)
    private void emit_new_status(string new_status_value) {
        if (connection != null && !connection.is_closed()) {
            SniDbus.emit_signal(connection, "/StatusNotifierItem",
                "NewStatus", new Variant("(s)", new_status_value));
        }
    }
}

[DBus (name = "org.kde.StatusNotifierWatcher")]
interface StatusNotifierWatcher : Object {
    public abstract async void register_status_notifier_item(string service) throws Error;
}

}
