/*
 * Copyright (C) 2016-2025 Dino Team
 * Modifications Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gtk;
using Adw;

using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui.Util {

public void show_remove_contact_failure(Gtk.Widget parent, Jid jid, RosterRemoveResult result) {
    string body = result == RosterRemoveResult.SERVER_REJECTED
        ? _("The server did not allow removing %s. This contact may be managed by the server.").printf(jid.to_string())
        : _("DinoX could not contact the server for %s. Check that the account is connected and try again.").printf(jid.to_string());
    var dialog = new Adw.AlertDialog(_("Could not remove contact"), body);
    dialog.add_response("ok", _("OK"));
    dialog.default_response = "ok";
    dialog.close_response = "ok";
    dialog.present(parent);
}

// Shared by account settings, account setup and all notification backends.
public string sasl_error_message(string? reason, string domain) {
    switch (reason) {
        case "plain-disabled":
            return _("This server only offers password login (PLAIN). You can explicitly allow it in this account's advanced settings. TLS remains required.");
        case "plain-downgrade-blocked":
            return _("This account previously used SCRAM. Login with PLAIN was blocked to protect your password. Contact your server administrator.");
        case "sasl-downgrade-detected":
        case "tls-version-mismatch":
            return _("The server's login security information does not match this connection. Login was stopped to protect your account.");
        case "invalid-scram-proof":
        case "invalid-scram-challenge":
            return _("The server sent an invalid authentication response. Login was stopped.");
        case "scram-pin-storage-failed":
            return _("Login protection could not be saved. Check the available disk space and try again.");
        case "plain-requires-tls":
            return _("Password login (PLAIN) requires a secure TLS connection.");
        case "no-supported-mechanism":
            return _("The server does not offer a supported login method.");
        case "channel-binding-required":
            return _("%s cannot provide the required extra protection. Sign-in was not continued.").printf(domain);
        default:
            return _("Wrong username or password");
    }
}

// Describe only the current connection, never a remembered SCRAM pin or the
// user's selected policy. Resumed streams may not have a fresh SASL proof.
public string login_protection_status_text(bool enabled, ConnectionManager.ConnectionState state,
        ConnectionManager.ConnectionError? error, string domain, bool tls_active, Sasl.Flag? flag) {
    if (!enabled) return _("Enable this account to check its login protection.");
    if (state == ConnectionManager.ConnectionState.CONNECTING) return _("Checking login protection…");
    if (state == ConnectionManager.ConnectionState.CONNECTED) {
        if (tls_active && flag != null && flag.finished && !flag.failed) {
            switch (flag.mechanism) {
                case Sasl.Mechanism.SCRAM_SHA_1_PLUS:
                case Sasl.Mechanism.SCRAM_SHA_256_PLUS:
                case Sasl.Mechanism.SCRAM_SHA_512_PLUS:
                    return _("Extra login protection is active for this connection.");
                case Sasl.Mechanism.SCRAM_SHA_1:
                case Sasl.Mechanism.SCRAM_SHA_256:
                case Sasl.Mechanism.SCRAM_SHA_512:
                case Sasl.Mechanism.PLAIN:
                    return _("Signed in without extra login protection. The connection is encrypted.");
            }
        }
        return _("The protection status is not known for this connection. It will be checked at the next login.");
    }
    if (error != null && error.source == ConnectionManager.ConnectionError.Source.SASL && error.identifier != null) {
        return sasl_error_message(error.identifier, domain);
    }
    return _("Login protection will be checked when this account connects.");
}

public enum LoginProtectionAvailability {
    UNKNOWN, CHECKING, AVAILABLE, UNAVAILABLE, INCOMPATIBLE, FAILED
}

public LoginProtectionAvailability login_protection_availability(bool enabled,
        ConnectionManager.ConnectionState state, bool tls_active, Sasl.Flag? flag,
        ConnectionManager.ConnectionError? error = null) {
    if (!enabled) return LoginProtectionAvailability.UNKNOWN;
    if (state == ConnectionManager.ConnectionState.CONNECTING) return LoginProtectionAvailability.CHECKING;
    if (state == ConnectionManager.ConnectionState.CONNECTED) {
        if (!tls_active || flag == null || !flag.finished || flag.failed) return LoginProtectionAvailability.UNKNOWN;
        // A successful login proves usability for this account/transport. An
        // advertised PLUS method alone must never unlock the policy control.
        switch (flag.mechanism) {
            case Sasl.Mechanism.SCRAM_SHA_1_PLUS:
            case Sasl.Mechanism.SCRAM_SHA_256_PLUS:
            case Sasl.Mechanism.SCRAM_SHA_512_PLUS:
                return LoginProtectionAvailability.AVAILABLE;
            case Sasl.Mechanism.SCRAM_SHA_1:
            case Sasl.Mechanism.SCRAM_SHA_256:
            case Sasl.Mechanism.SCRAM_SHA_512:
            case Sasl.Mechanism.PLAIN:
                if (flag.server_offers_channel_binding != null) {
                    return flag.server_offers_channel_binding == true
                        ? LoginProtectionAvailability.INCOMPATIBLE : LoginProtectionAvailability.UNAVAILABLE;
                }
                break;
        }
        return LoginProtectionAvailability.UNKNOWN;
    }
    if (error != null && error.source == ConnectionManager.ConnectionError.Source.SASL &&
            error.identifier == "channel-binding-required") return LoginProtectionAvailability.UNAVAILABLE;
    return error != null ? LoginProtectionAvailability.FAILED : LoginProtectionAvailability.UNKNOWN;
}

public string login_protection_availability_text(LoginProtectionAvailability availability) {
    switch (availability) {
        case LoginProtectionAvailability.AVAILABLE:
            return _("Available — the server supports extra login protection for this account.");
        case LoginProtectionAvailability.UNAVAILABLE:
            return _("Not available — this server does not provide usable extra login protection for this account.");
        case LoginProtectionAvailability.INCOMPATIBLE:
            return _("Not available — the server offers extra protection, but it cannot be used for this account.");
        case LoginProtectionAvailability.CHECKING:
            return _("Checking this account…");
        case LoginProtectionAvailability.FAILED:
            return _("Check failed. Reconnect this account to try again.");
        default:
            return _("Not checked. Use “Check now” to check this account.");
    }
}

// Shared rendering and selection gate, exercised with native GTK widgets.
// The caller suppresses selection notifications while refreshing the model.
public void render_login_protection_controls(Adw.ComboRow mode, Adw.ActionRow server,
        Gtk.Image icon, Gtk.Spinner spinner, LoginProtectionAvailability availability, bool required) {
    bool available = availability == LoginProtectionAvailability.AVAILABLE;
    bool checking = availability == LoginProtectionAvailability.CHECKING;
    bool negative = availability == LoginProtectionAvailability.UNAVAILABLE ||
        availability == LoginProtectionAvailability.INCOMPATIBLE;
    bool failed = availability == LoginProtectionAvailability.FAILED;
    server.subtitle = login_protection_availability_text(availability);
    icon.remove_css_class("success");
    icon.remove_css_class("error");
    icon.remove_css_class("dim-label");
    icon.remove_css_class("warning");
    icon.icon_name = available ? "object-select-symbolic" : negative ? "window-close-symbolic" :
        failed ? "dialog-warning-symbolic" : "dialog-question-symbolic";
    icon.add_css_class(available ? "success" : negative ? "error" : failed ? "warning" : "dim-label");
    icon.tooltip_text = server.subtitle;
    icon.update_property(Gtk.AccessibleProperty.LABEL, server.subtitle, -1);
    icon.visible = !checking;
    spinner.spinning = checking;
    spinner.visible = checking;
    if (available) {
        if (mode.model == null || mode.model.get_n_items() != 2) {
            var choices = new Gtk.StringList(null);
            choices.append(_("Use when available"));
            choices.append(_("Require for sign-in"));
            mode.model = choices;
        }
        mode.selected = required ? 1 : 0;
    } else {
        // No checked-looking policy choice when availability is not confirmed.
        string label = checking ? _("Checking…") : negative ? _("Not available") : failed ? _("Check failed") : _("Not checked");
        var items = mode.model as Gtk.StringList;
        if (items == null || items.get_n_items() != 1 || items.get_string(0) != label) {
            var choices = new Gtk.StringList(null);
            choices.append(label);
            mode.model = choices;
        }
        mode.selected = 0;
    }
    mode.sensitive = available;
}

public bool apply_verified_login_protection_mode(Account account, uint selected,
        ConnectionManager.ConnectionState state, bool tls_active, Sasl.Flag? flag,
        ConnectionManager.ConnectionError? error = null) {
    // Re-evaluate at activation, not just when the dropdown was displayed.
    if (selected > 1 || login_protection_availability(account.enabled, state, tls_active, flag, error) !=
            LoginProtectionAvailability.AVAILABLE) return false;
    account.require_channel_binding = selected == 1;
    return true;
}


private static Regex URL_REGEX;
private static Map<unichar, unichar> MATCHING_CHARS;
private static Regex QUOTE_REGEX_RAW;
private static Regex QUOTE_REGEX_ESC;
private static Regex[] MARKUP_REGEXES;
private const unichar[] NON_TRAILING_CHARS = {'\'', '"', ',', '.', ';', '!', '?', '»', '”', '’', '`', '~', '‽', ':', '>', '*', '_'};
private const string[] ALLOWED_SCHEMAS = {"http", "https", "ftp", "ftps", "irc", "ircs", "xmpp", "mailto", "sms", "smsto", "mms", "tel", "geo", "openpgp4fpr", "im", "news", "nntp", "sip", "ssh", "bitcoin", "sftp", "magnet", "vnc"};
private const string[] tango_colors_light = {"FCE94F", "FCAF3E", "E9B96E", "8AE234", "729FCF", "AD7FA8", "EF2929"};
private const string[] tango_colors_medium = {"EDD400", "F57900", "C17D11", "73D216", "3465A4", "75507B", "CC0000"};
private const string[] material_colors_800 = {"D32F2F", "C2185B", "7B1FA2", "512DA8", "303F9F", "1976D2", "0288D1", "0097A7", "00796B", "388E3C", "689F38", "AFB42B", "FFA000", "F57C00", "E64A19", "5D4037"};
private const string[] material_colors_500 = {"F44336", "E91E63", "9C27B0", "673AB7", "3f51B5", "2196F3", "03A9f4", "00BCD4", "009688", "4CAF50", "8BC34a", "CDDC39", "FFC107", "FF9800", "FF5722", "795548"};
private const string[] material_colors_300 = {"E57373", "F06292", "BA68C8", "9575CD", "7986CB", "64B5F6", "4FC3F7", "4DD0E1", "4DB6AC", "81C784", "AED581", "DCE775", "FFD54F", "FFB74D", "FF8A65", "A1887F"};
private const string[] material_colors_200 = {"EF9A9A", "F48FB1", "CE93D8", "B39DDB", "9FA8DA", "90CAF9", "81D4FA", "80DEEA", "80CBC4", "A5D6A7", "C5E1A5", "E6EE9C", "FFE082", "FFCC80", "FFAB91", "BCAAA4"};

[CCode (cname = "gtk_menu_button_set_popover", cheader_filename = "gtk/gtk.h")]
public extern static void set_menu_button_popover(MenuButton button, Widget? popover);

public static void clear_focus_before_detach(Widget subtree) {
    Gtk.Root? root = subtree.get_root();
    if (root == null) return;

    unowned Widget? focus = ((!) root).get_focus();
    if (focus != null &&
            (focus == subtree || ((!) focus).is_ancestor(subtree))) {
        // GtkWindow otherwise defers moving focus until AFTER_PAINT. The
        // detached subtree can be finalized before that phase on GTK 4.14,
        // leaving focus traversal with a stale previous-focus pointer.
        ((!) root).set_focus(null);
    }
}

[CCode (cname = "gdk_pixbuf_save_to_buffer", cheader_filename = "gdk-pixbuf/gdk-pixbuf.h")]
private extern static bool save_pixbuf_to_buffer (Gdk.Pixbuf pixbuf, [CCode (array_length_cname = "buffer_size", array_length_pos = 2.1, array_length_type = "gsize", type = "gchar**")] out uint8[] buffer, string type, ...) throws Error;

public static uint8[] pixbuf_to_png_bytes (Gdk.Pixbuf pixbuf) throws Error {
    uint8[] buffer;
    save_pixbuf_to_buffer (pixbuf, out buffer, "png", null);
    return buffer;
}

public static string join_strings (string separator, Collection<string> values) {
    string[] parts = new string[values.size + 1];
    int i = 0;
    foreach (string value in values) {
        parts[i++] = value;
    }
    parts[i] = null;
    return string.joinv(separator, parts);
}

public static string sanitize_utf8(string? s) {
    if (s == null) return "";
    return s.validate() ? (!) s : ((!) s).make_valid();
}

public static string sanitize_utf8_with_length(string? s, ssize_t len) {
    if (s == null) return "";
    if (len < 0) return sanitize_utf8(s);
    return ((!) s).make_valid(len);
}

private static bool is_allowed_schema (string? scheme) {
    if (scheme == null) return false;
    foreach (string allowed_schema in ALLOWED_SCHEMAS) {
        if (scheme == allowed_schema) return true;
    }
    return false;
}

public static string get_consistent_hex_color(StreamInteractor stream_interactor, Account account, Jid jid, bool dark_theme = false) {
    uint8[] rgb;
    if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_groupchat(jid.bare_jid, account) && jid.resourcepart != null) {
        rgb = ConsistentColor.string_to_rgb(jid.resourcepart);
    } else {
        rgb = ConsistentColor.string_to_rgb(jid.bare_jid.to_string());
    }
    return "%.2x%.2x%.2x".printf(rgb[0], rgb[1], rgb[2]);
}

public static string get_avatar_hex_color(StreamInteractor stream_interactor, Account account, Jid jid, Conversation? conversation = null) {
    return get_consistent_hex_color(stream_interactor, account, get_relevant_jid(stream_interactor, account, jid, conversation));
}

public static string get_name_hex_color(StreamInteractor stream_interactor, Account account, Jid jid, bool dark_theme = false, Conversation? conversation = null) {
    return get_consistent_hex_color(stream_interactor, account, get_relevant_jid(stream_interactor, account, jid, conversation), dark_theme);
}

private static Jid get_relevant_jid(StreamInteractor stream_interactor, Account account, Jid jid, Conversation? conversation = null) {
    Conversation conversation_ = conversation ?? stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(jid.bare_jid, account);
    if (conversation_ != null && conversation_.type_ == Conversation.Type.GROUPCHAT) {
        Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(jid, account);
        if (real_jid != null) {
            return real_jid.bare_jid;
        }
    } else {
        return jid.bare_jid;
    }
    return jid;
}

public static string color_for_show(string show) {
    switch(show) {
        case "online": return "#9CCC65";
        case "away": return "#FFCA28";
        case "chat": return "#66BB6A";
        case "xa": return "#EF5350";
        case "dnd": return "#EF5350";
        default: return "#BDBDBD";
    }
}

public static string get_conversation_display_name(StreamInteractor stream_interactor, Conversation conversation) {
    return Dino.get_conversation_display_name(stream_interactor, conversation, _("%s from %s"));
}

public static Gdk.Texture texture_from_pixbuf(Gdk.Pixbuf pixbuf) {
    Gdk.MemoryFormat format = pixbuf.get_has_alpha() ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
    return new Gdk.MemoryTexture(pixbuf.width, pixbuf.height, format, pixbuf.read_pixel_bytes(), pixbuf.rowstride);
}

// Optional thumbnails are untrusted message data. Bound both the compressed
// input and decoded size, and never expand a tiny placeholder to file dimensions.
public static Gdk.Pixbuf? get_thumbnail_preview(Gee.List<Xep.JingleContentThumbnails.Thumbnail> thumbnails, Cancellable? cancellable = null) {
    int examined = 0;
    foreach (var thumbnail in thumbnails) {
        if (cancellable != null && cancellable.is_cancelled()) return null;
        if (++examined > 4) break;
        if (thumbnail.data == null) continue;
        unowned uint8[] raw = thumbnail.data.get_data();
        if (raw == null || raw.length == 0 || raw.length > 262144) continue;
        if (thumbnail.media_type == "image/thumbhash" ||
                (thumbnail.media_type != null && thumbnail.media_type.has_prefix("image/svg"))) continue;
        var loader = new Gdk.PixbufLoader();
        bool oversized = false;
        bool closed = false;
        ulong size_handler = loader.size_prepared.connect((width, height) => {
            oversized = width <= 0 || height <= 0 || (int64) width * height > 4000000;
            if (oversized) { loader.set_size(1, 1); return; }
            double scale = double.min(1.0, double.min(320.0 / width, 320.0 / height));
            loader.set_size(int.max(1, (int) (width * scale)), int.max(1, (int) (height * scale)));
        });
        try {
            for (int offset = 0; offset < raw.length && !oversized; offset += 4096) {
                if (cancellable != null && cancellable.is_cancelled()) return null;
                loader.write(raw[offset:int.min(offset + 4096, raw.length)]);
            }
            loader.close();
            closed = true;
            if (oversized || (cancellable != null && cancellable.is_cancelled())) continue;
            Gdk.Pixbuf? pixbuf = loader.get_pixbuf();
            if (pixbuf != null) pixbuf = pixbuf.apply_embedded_orientation();
            if (pixbuf != null && pixbuf.get_pixels() != null) return pixbuf;
        } catch (Error e) {
            // Thumbnails are optional and may use formats such as ThumbHash
            // that the installed image loaders do not support. Try the next.
            debug("Thumbnail not parseable (%d bytes): %s", raw.length, e.message);
        } finally {
            if (!closed) { try { loader.close(); } catch (Error ignored) { } }
            loader.disconnect(size_handler);
        }
    }
    return null;
}

private class ThumbnailPreviewJob : Object {
    public Gee.ArrayList<Xep.JingleContentThumbnails.Thumbnail> thumbnails = new Gee.ArrayList<Xep.JingleContentThumbnails.Thumbnail>();
    public Cancellable cancellable;
    public Gdk.Pixbuf? result;
    public MainContext context;
    public SourceFunc? completed;

    public void run() {
        result = get_thumbnail_preview(thumbnails, cancellable);
        var idle = new IdleSource();
        idle.set_callback(() => {
            SourceFunc? callback = (owned) completed;
            if (callback != null) callback();
            return Source.REMOVE;
        });
        idle.attach(context);
    }
}

private static ThreadPool<ThumbnailPreviewJob>? thumbnail_pool;

public static async Gdk.Pixbuf? get_thumbnail_preview_async(Gee.List<Xep.JingleContentThumbnails.Thumbnail> thumbnails, Cancellable cancellable) {
    var job = new ThumbnailPreviewJob() {
        cancellable = cancellable,
        context = MainContext.ref_thread_default(),
        completed = get_thumbnail_preview_async.callback
    };
    // Copy immutable bytes and scalar metadata before handing work to a thread.
    // Opening a large group must not create one decoder thread per message.
    foreach (var thumbnail in thumbnails) {
        if (job.thumbnails.size == 4) break;
        job.thumbnails.add(new Xep.JingleContentThumbnails.Thumbnail() {
            data = thumbnail.data, media_type = thumbnail.media_type
        });
    }
    try {
        if (thumbnail_pool == null) {
            thumbnail_pool = new ThreadPool<ThumbnailPreviewJob>.with_owned_data((item) => item.run(), 2, false);
        }
        thumbnail_pool.add(job);
    } catch (ThreadError e) {
        // GLib may retain a queued item even when starting a worker fails.
        // The async caller returns now; a later worker must not resume it twice.
        job.completed = null;
        return null;
    }
    yield;
    return cancellable.is_cancelled() ? null : job.result;
}

public static string get_participant_display_name(StreamInteractor stream_interactor, Conversation conversation, Jid participant, bool me_is_me = false) {
    return Dino.get_participant_display_name(stream_interactor, conversation, participant, me_is_me ? _("Me") : null);
}

public static string? get_real_display_name(StreamInteractor stream_interactor, Account account, Jid jid, bool me_is_me = false) {
    return Dino.get_real_display_name(stream_interactor, account, jid, me_is_me ? _("Me") : null);
}

public static string get_groupchat_display_name(StreamInteractor stream_interactor, Account account, Jid jid) {
    return Dino.get_groupchat_display_name(stream_interactor, account, jid);
}

public static string get_occupant_display_name(StreamInteractor stream_interactor, Conversation conversation, Jid jid, bool me_is_me = false, bool muc_real_name = false) {
    return Dino.get_occupant_display_name(stream_interactor, conversation, jid, me_is_me ? _("Me") : null);
}

public static Gdk.RGBA get_label_pango_color(Label label, string css_color) {
    // GTK 4.10+: Direct CSS manipulation without deprecated StyleContext
    Gdk.RGBA result = {0, 0, 0, 1};
    
    // Parse CSS color to RGBA
    if (css_color.has_prefix("@")) {
        // Theme color - create temporary label with CSS class
        var temp_label = new Label("");
        temp_label.add_css_class(css_color.substring(1));
        result = temp_label.get_color();
    } else {
        // Direct color value
        result.parse(css_color);
    }
    
    return result;
}

public static string rgba_to_hex(Gdk.RGBA rgba) {
    return "#%02x%02x%02x%02x".printf(
            (uint8)(Math.round(rgba.red.clamp(0,1)*255)),
            (uint8)(Math.round(rgba.green.clamp(0,1)*255)),
            (uint8)(Math.round(rgba.blue.clamp(0,1)*255)),
            (uint8)(Math.round(rgba.alpha.clamp(0,1)*255)))
            .up();
}

private const string force_background_css = "%s { background-color: %s; }";
private const string force_color_css = "%s { color: %s; }";

public static Gtk.CssProvider force_css(Gtk.Widget widget, string css) {
    // GTK 4.10+: Inline style without deprecated StyleContext
    string class_name = "dino-style-%u".printf(Random.next_int());
    string scoped_css = ".%s %s".printf(class_name, css);

    var provider = new Gtk.CssProvider();
#if GTK_4_12 && (VALA_0_56_GREATER_11 || VALA_0_58)
    provider.load_from_string(scoped_css);
#elif (VALA_0_56_11 || VALA_0_56_12)
    provider.load_from_data(scoped_css, scoped_css.length);
#else
    provider.load_from_data(scoped_css.data);
#endif

    widget.add_css_class(class_name);
    
    // Store provider in widget data to keep it alive
    widget.set_data("dino-css-provider", provider);
    widget.set_data("dino-style-class", class_name);

    return provider;
}

public static void force_background(Gtk.Widget widget, string color, string selector = "*") {
    force_css(widget, force_background_css.printf(selector, color));
}

public static Gtk.CssProvider force_color(Gtk.Widget widget, string color, string selector = "*") {
    return force_css(widget, force_color_css.printf(selector, color));
}

public static void force_error_color(Gtk.Widget widget, string selector = "*") {
    force_color(widget, "@error_color", selector);
}

public static bool is_dark_theme(Gtk.Widget widget) {
    return Adw.StyleManager.get_default().dark;
}

public static bool is_24h_format() {
    return true;
}

public static string format_time(DateTime datetime, string format_24h, string format_12h) {
    string format = Util.is_24h_format() ? format_24h : format_12h;
    if (!get_charset(null)) {
        // No UTF-8 support, use simple colon for time instead
        format = format.replace("∶", ":");
    }
    return datetime.format(format);
}

public static Regex get_url_regex() {
    if (URL_REGEX == null) {
        URL_REGEX = /\b(((http|ftp)s?:\/\/|(ircs?|xmpp|mailto|sms|smsto|mms|tel|geo|openpgp4fpr|im|news|nntp|sip|ssh|bitcoin|sftp|magnet|vnc|urn):)\S+)/i;
    }
    return URL_REGEX;
}

public static Map<unichar, unichar> get_matching_chars() {
    if (MATCHING_CHARS == null) {
        MATCHING_CHARS = new HashMap<unichar, unichar>();
        MATCHING_CHARS[")".get_char(0)] = "(".get_char(0);
        MATCHING_CHARS["]".get_char(0)] = "[".get_char(0);
        MATCHING_CHARS["}".get_char(0)] = "{".get_char(0);
    }
    return MATCHING_CHARS;
}

/**
 * This replaces spaces with non-breaking spaces when they are adjacent to a non-spacing mark.
 *
 * We do this to work-around a bug in Pango. See https://gitlab.gnome.org/GNOME/pango/-/issues/798 and
 * https://gitlab.gnome.org/GNOME/pango/-/issues/832
 *
 * This is zero-copy iff no space is adjacent to a non-spacing mark, otherwise the provided string will be destroyed
 * and the returned string should be used instead.
 */
public static string unbreak_space_around_non_spacing_mark(owned string s) {
    s = sanitize_utf8(s);
    int current_index = 0;
    unichar current_char = 0;
    int prev_index = 0;
    unichar prev_char = 0;
    bool is_non_spacing_mark = false;
    while (s.get_next_char(ref current_index, out current_char)) {
        int replace_index = -1;
        if (is_non_spacing_mark && current_char == ' ') {
            replace_index = prev_index;
            current_char = (unichar) 0x00A0; // Non-breaking space
        }
        is_non_spacing_mark = ICU.get_int_property_value(current_char, ICU.Property.BIDI_CLASS) == ICU.CharDirection.DIR_NON_SPACING_MARK;
        if (prev_char == ' ' && is_non_spacing_mark) {
            replace_index = prev_index - 1;
        }
        if (replace_index != -1) {
            s = s[0:replace_index] + "\u00A0" + s[(replace_index + 1):s.length];
            current_index += 1;
        }
        prev_index = current_index;
        prev_char = current_char;
    }
    return (owned) s;
}

public static string parse_add_markup(string s_, string? highlight_word, bool parse_links, bool parse_text_markup) {
    bool ignore_out_var = false;
    return parse_add_markup_theme(s_, highlight_word, parse_links, parse_text_markup, parse_text_markup, false, ref ignore_out_var);
}

public static string parse_add_markup_theme(string s_, string? highlight_word, bool parse_links, bool parse_text_markup, bool parse_quotes, bool dark_theme, ref bool theme_dependent, bool already_escaped_ = false) {
    string s = sanitize_utf8(s_);
    bool already_escaped = already_escaped_;

    // MatchInfo borrows its subject until it is freed. Match the live original
    // string: a temporary s.down() would be freed before match_info.next(), and
    // Unicode case conversion can also change byte offsets used to slice s.

    if (parse_quotes) {
        string gt = already_escaped ? "&gt;" : ">";
        try {
            Regex quote_regex;
            if (already_escaped) {
                if (QUOTE_REGEX_ESC == null) QUOTE_REGEX_ESC = new Regex("((?<=\n)&gt;.*(\n|$))|(^&gt;.*(\n|$))");
                quote_regex = QUOTE_REGEX_ESC;
            } else {
                if (QUOTE_REGEX_RAW == null) QUOTE_REGEX_RAW = new Regex("((?<=\n)>.*(\n|$))|(^>.*(\n|$))");
                quote_regex = QUOTE_REGEX_RAW;
            }
            MatchInfo quote_match_info;
            quote_regex.match(s, 0, out quote_match_info);
            if (quote_match_info.matches()) {
                int start, end;

                string dim_color = dark_theme ? "#BDBDBD": "#707070";

                theme_dependent = true;
                quote_match_info.fetch_pos(0, out start, out end);
                return parse_add_markup_theme(s[0:start], highlight_word, parse_links, parse_text_markup, parse_quotes, dark_theme, ref theme_dependent, already_escaped) +
                        @"<span color='$dim_color'>$gt" + parse_add_markup_theme(s[start + gt.length:end], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped) + "</span>" +
                        parse_add_markup_theme(s[end:s.length], highlight_word, parse_links, parse_text_markup, parse_quotes, dark_theme, ref theme_dependent, already_escaped);
            }
        } catch (RegexError e) {
            warning("Failed to create quote regex: %s", e.message);
        }
    }

    if (parse_links && !already_escaped) {
        MatchInfo match_info;
        get_url_regex().match(s, 0, out match_info);
        while (match_info.matches()) {
            int start, end;
            match_info.fetch_pos(0, out start, out end);
            string link = s[start:end];
            if (is_allowed_schema(GLib.Uri.parse_scheme(link))) {
                Map<unichar, unichar> matching_chars = get_matching_chars();
                unichar close_char;
                int last_char_index = link.length;
                while (link.get_prev_char(ref last_char_index, out close_char)) {
                    if (matching_chars.has_key(close_char)) {
                        unichar open_char = matching_chars[close_char];
                        unichar char;
                        int index = 0;
                        int open = 0, close = 0;
                        while (link.get_next_char(ref index, out char)) {
                            if (char == open_char) {
                                open++;
                            } else if (char == close_char) {
                                close++;
                            }
                        }
                        if (close > open) {
                            // Remove last char from url
                            end -= close_char.to_string().length;
                            link = s[start:end];
                        } else {
                            break;
                        }
                    } else if (close_char in NON_TRAILING_CHARS) {
                        // Remove last char from url
                        end -= close_char.to_string().length;
                        link = s[start:end];
                    } else {
                        break;
                    }
                }

                // For xmpp: command URIs, show only the command text
                string display = link;
                if (link.has_prefix("xmpp:") && link.contains("?message;body=")) {
                    int body_idx = link.index_of("?message;body=") + "?message;body=".length;
                    string? decoded = GLib.Uri.unescape_string(link.substring(body_idx));
                    if (decoded != null && decoded != "") display = sanitize_utf8(decoded);
                }

                return parse_add_markup_theme(s[0:start], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped) +
                        "<a href=\"" + Markup.escape_text(link) + "\">" +
                        parse_add_markup_theme(display, highlight_word, false, false, false, dark_theme, ref theme_dependent, already_escaped) +
                        "</a>" +
                        parse_add_markup_theme(s[end:s.length], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped);
            }
            try {
                match_info.next();
            } catch (RegexError e) {
                warning("Failed to advance regex match: %s", e.message);
                break;
            }
        }
    }

    if (!already_escaped) {
        s = Markup.escape_text(s);
        already_escaped = true;
    }

    if (highlight_word != null) {
        try {
            Regex highlight_regex = new Regex("\\b" + Regex.escape_string(highlight_word) + "\\b", RegexCompileFlags.CASELESS);
            MatchInfo match_info;
            highlight_regex.match(s, 0, out match_info);
            if (match_info.matches()) {
                int start, end;
                match_info.fetch_pos(0, out start, out end);
                return parse_add_markup_theme(s[0:start], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped) +
                    "<b>" + s[start:end] + "</b>" +
                    parse_add_markup_theme(s[end:s.length], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped);
            }
        } catch (RegexError e) {
            assert_not_reached();
        }
    }

    if (parse_text_markup) {
        string[] convenience_tag = new string[]{"tt", "i", "b", "s"};

        if (MARKUP_REGEXES == null) {
            string[] markup_string = new string[]{"`", "_", "*", "~"};
            MARKUP_REGEXES = new Regex[markup_string.length];
            for (int k = 0; k < markup_string.length; k++) {
                string me = Regex.escape_string(markup_string[k]);
                try { MARKUP_REGEXES[k] = new Regex("(^|\\s)" + me + "(\\S|\\S.*?\\S)" + me); } catch (RegexError e) {}
            }
        }

        for (int i = 0; i < MARKUP_REGEXES.length; i++) {
            Regex regex = MARKUP_REGEXES[i];
            if (regex == null) continue;
            MatchInfo match_info;
            regex.match(s, 0, out match_info);
            if (match_info.matches()) {
                int start, end;
                match_info.fetch_pos(2, out start, out end);
                return parse_add_markup_theme(s[0:start-1], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped) +
                    "<span color='#9E9E9E'>" +  s[start-1:start] + "</span>" +
                    @"<$(convenience_tag[i])>" + s[start:end] + @"</$(convenience_tag[i])>" +
                    "<span color='#9E9E9E'>" + s[end:end+1] + "</span>" +
                    parse_add_markup_theme(s[end+1:s.length], highlight_word, parse_links, parse_text_markup, false, dark_theme, ref theme_dependent, already_escaped);
            }
        }
    }

    return s;
}

    // Modifies `markups`.
    public string remove_fallbacks_adjust_markups(string text, bool contains_quote, Gee.List<Xep.FallbackIndication.Fallback> fallbacks, Gee.List<Xep.MessageMarkup.Span> markups) {
        string processed_text = text;

        foreach (var fallback in fallbacks) {
            if (fallback.ns_uri == Xep.Replies.NS_URI && contains_quote) {
                foreach (var fallback_location in fallback.locations) {
                    if (fallback_location.from_char < 0 || fallback_location.to_char < 0 || fallback_location.from_char > fallback_location.to_char) {
                        continue;
                    }

                    int from_index = processed_text.index_of_nth_char(fallback_location.from_char);
                    int to_index = processed_text.index_of_nth_char(fallback_location.to_char);
                    if (from_index < 0 || to_index < 0 || from_index > to_index || to_index > processed_text.length) {
                        continue;
                    }

                    processed_text = processed_text[0:from_index] + processed_text[to_index:processed_text.length];

                    int length = fallback_location.to_char - fallback_location.from_char;
                    foreach (Xep.MessageMarkup.Span span in markups) {
                        if (span.start_char > fallback_location.to_char) {
                            span.start_char -= length;
                        }
                        if (span.end_char > fallback_location.to_char) {
                            span.end_char -= length;
                        }
                    }
                }
            }
        }
        return processed_text;
    }

/**
 * This is a heuristic to count emojis in a string {@link http://example.com/}
 *
 * @param markup_text string to search in
 * @return number of emojis, or -1 if text includes non-emojis.
 */
public int get_only_emoji_count(string markup_text) {
    int emoji_no = 0;
    int index_ref = 0;
    unichar curchar = 0, altchar = 0;
    bool last_was_emoji = false, last_was_modifier_base = false, last_was_keycap = false;
    while (markup_text.get_next_char(ref index_ref, out curchar)) {
        if (last_was_emoji && last_was_keycap && curchar == 0x20E3) {
            // keycap sequence
            continue;
        }

        last_was_keycap = false;

        if (last_was_emoji && curchar == 0x200D && markup_text.get_next_char(ref index_ref, out curchar)) {
            // zero width joiner
            last_was_emoji = false;
            emoji_no--;
        }

        if (last_was_emoji && curchar == 0xFE0F) {
            // Variation selector after emoji is useless, ignoring.
        } else if (last_was_emoji && last_was_modifier_base && ICU.has_binary_property(curchar, ICU.Property.EMOJI_MODIFIER)) {
            // still an emoji, but no longer a modifier base
            last_was_modifier_base = false;
        } else if (ICU.has_binary_property(curchar, ICU.Property.EMOJI_PRESENTATION)) {
            if (ICU.has_binary_property(curchar, ICU.Property.EMOJI_MODIFIER_BASE)) {
                last_was_modifier_base = true;
            }
            emoji_no++;
            last_was_emoji = true;
        } else if (curchar == ' ') {
            last_was_emoji = false;
        } else if (markup_text.get_next_char(ref index_ref, out altchar) && altchar == 0xFE0F) {
            // U+FE0F = VARIATION SELECTOR-16
            emoji_no++;
            last_was_emoji = true;
            last_was_keycap = (curchar >= 0x30 && curchar <= 0x39) || curchar == 0x23 || curchar == 0x2A;
        } else {
            return -1;
        }
    }
    return emoji_no;
}

public string summarize_whitespaces_to_space(string s) {
    string safe = sanitize_utf8(s);
    try {
        return (/\s+/).replace_literal(safe, -1, 0, " ");
    } catch (RegexError e) {
        critical("RegexError when summarizing whitespaces in '%s': %s", safe, e.message);
        return safe;
    }
}

public void present_window(Gtk.Window window) {
#if GDK3_WITH_X11
        Gdk.X11.Window x11window = window.get_window() as Gdk.X11.Window;
    if (x11window != null) {
        window.present_with_time(Gdk.X11.get_server_time(x11window));
    } else {
        window.present();
    }
#else
    window.present();
#endif
}

public Widget? widget_if_tooltips_active(Widget w) {
    return use_tooltips() ? w : null;
}

public string? string_if_tooltips_active(string? s) {
    return use_tooltips() ? s : null;
}

public bool use_tooltips() {
    return Gtk.MINOR_VERSION != 6 || (Gtk.MICRO_VERSION < 4 || Gtk.MICRO_VERSION > 6);
}

public static void menu_button_set_icon_with_size(MenuButton menu_button, string icon_name, int pixel_size) {
#if GTK_4_6 && VALA_0_52
    menu_button.set_child(new Image.from_icon_name(icon_name) { pixel_size=pixel_size });
#else
    menu_button.set_icon_name(icon_name);
    var button = menu_button.get_first_child() as Button;
    if (button == null) return;
    var box = button.child as Box;
    if (box == null) return;
    var image = box.get_first_child() as Image;
    if (image == null) return;
    image.pixel_size = pixel_size;
#endif
}

// Show "clear conversation history" confirmation dialog (clone removal).
// Shared by menu_entry.vala and conversation_selector_row.vala.
public static void show_clear_history_dialog(Conversation conversation, StreamInteractor stream_interactor, Gtk.Window? parent) {
    bool supports_global_deletion =
        conversation.type_ == Conversation.Type.CHAT ||
        conversation.type_ == Conversation.Type.GROUPCHAT;
    var dialog = new Adw.AlertDialog(
        _("Delete all message history?"),
        supports_global_deletion
            ? _("Local deletion removes the saved messages from this device. Unencrypted messages can be loaded again while they remain in the server archive. OMEMO messages already decrypted on this device cannot be restored from the archive alone after local deletion. Deleting for everyone also sends removal requests for your own sent messages.")
            : _("This will permanently delete all messages in this conversation. This action cannot be undone.")
    );

    dialog.add_response("cancel", _("Cancel"));
    dialog.add_response("local", _("Delete locally"));
    if (supports_global_deletion) {
        dialog.add_response("global", _("Delete for everyone"));
        dialog.set_response_appearance("global", Adw.ResponseAppearance.DESTRUCTIVE);
    }
    dialog.set_default_response("cancel");
    dialog.set_close_response("cancel");

    dialog.response.connect((response) => {
        if (response == "local") {
            stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).clear_conversation_history(conversation, false);
        } else if (response == "global" && supports_global_deletion) {
            stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).clear_conversation_history(conversation, true);
        }
    });

    dialog.present(parent);
}

public static void show_muc_invite_dialog(Conversation conversation, StreamInteractor stream_interactor, Gtk.Window? parent) {
    MucManager muc_manager = stream_interactor.get_module<MucManager>(
        MucManager.IDENTITY);
    if (!muc_manager.is_joined(conversation.counterpart,
            conversation.account)) {
        show_muc_invite_error_dialog_for_error(parent, "not-joined");
        return;
    }
    if (!muc_manager.mediated_invite_possible(conversation.account,
            conversation.counterpart)) {
        show_muc_invite_error_dialog_for_error(parent, "not-allowed");
        return;
    }

    var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
    box.margin_top = 6;
    box.margin_bottom = 6;
    box.margin_start = 6;
    box.margin_end = 6;

    var invitee_label = new Gtk.Label(_("Contact JID"));
    invitee_label.halign = Gtk.Align.START;
    invitee_label.add_css_class("dim-label");
    box.append(invitee_label);

    var invitee_entry = new Gtk.Entry();
    invitee_entry.placeholder_text = _("user@example.org");
    box.append(invitee_entry);

    var reason_label = new Gtk.Label(_("Invitation reason"));
    reason_label.halign = Gtk.Align.START;
    reason_label.add_css_class("dim-label");
    box.append(reason_label);

    var reason_entry = new Gtk.Entry();
    reason_entry.placeholder_text = _("Optional message");
    box.append(reason_entry);

    var dialog = new Adw.AlertDialog(
        _("Invite Contact"),
        _("Send an invitation for %s.").printf(conversation.counterpart.bare_jid.to_string())
    );
    dialog.set_extra_child(box);
    dialog.add_response("cancel", _("Cancel"));
    dialog.add_response("send", _("Send"));
    dialog.set_response_appearance("send", Adw.ResponseAppearance.SUGGESTED);
    dialog.set_default_response("send");
    dialog.set_close_response("cancel");

    dialog.response.connect((response) => {
        if (response != "send") return;

        string invitee_text = invitee_entry.text.strip();
        if (invitee_text == "") {
            show_muc_invite_error_dialog_for_error(parent, "invalid-jid");
            return;
        }

        Jid invitee;
        try {
            invitee = new Jid(invitee_text).bare_jid;
        } catch (InvalidJidError e) {
            show_muc_invite_error_dialog_for_error(parent, "invalid-jid");
            return;
        }

        // A room-internal invitation must go through the room so its
        // XEP-0045 invitation policy remains authoritative. Re-check the
        // current join state because the user can leave while this dialog is
        // open.
        if (!muc_manager.is_joined(conversation.counterpart,
                conversation.account)) {
            show_muc_invite_error_dialog_for_error(parent, "not-joined");
            return;
        }
        if (!muc_manager.mediated_invite_possible(conversation.account,
                conversation.counterpart)) {
            show_muc_invite_error_dialog_for_error(parent, "not-allowed");
            return;
        }
        muc_manager.invite.begin(
            conversation.account,
            conversation.counterpart,
            invitee,
            reason_entry.text,
            MucInviteDelivery.MEDIATED,
            (_, res) => {
                MucInviteSendResult result = muc_manager.invite.end(res);
                if (!result.sent) {
                    show_muc_invite_error_dialog(parent, result);
                }
            }
        );
    });

    dialog.present(parent);
}

private static void show_muc_invite_error_dialog(Gtk.Window? parent, MucInviteSendResult result) {
    show_muc_invite_error_dialog_for_error(parent, result.error);
}

private static void show_muc_invite_error_dialog_for_error(Gtk.Window? parent, string? error) {
    string body;
    switch (error) {
        case "account-not-connected":
            body = _("The account is not connected.");
            break;
        case "muc-module-missing":
            body = _("Group chat invitations are not available for this account.");
            break;
        case "not-joined":
            body = _("You are not currently in this room.");
            break;
        case "not-allowed":
            body = _("Your current room role or affiliation is not allowed to invite contacts.");
            break;
        case "direct-invite-module-missing":
            body = _("Direct invitations are not available for this account.");
            break;
        case "send-failed":
            body = _("The invitation could not be sent through the current connection.");
            break;
        case "invalid-jid":
            body = _("Enter a contact JID to invite.");
            break;
        default:
            body = _("The invitation could not be sent.");
            break;
    }

    var dialog = new Adw.AlertDialog(_("Invitation not sent"), body);
    dialog.add_response("close", _("Close"));
    dialog.present(parent);
}

}
