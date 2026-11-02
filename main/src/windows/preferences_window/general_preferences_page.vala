/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;

public class Dino.Ui.ViewModel.GeneralPreferencesPage : Object {
    public bool send_typing { get; set; }
    public bool send_marker { get; set; }
    public bool sync_displayed_state { get; set; }
    public bool notifications { get; set; }
    public bool notification_sounds { get; set; }
    public bool keep_background { get; set; }
    public bool convert_emojis { get; set; }
    public bool send_on_ctrl_enter { get; set; default = false; }
    public string window_controls { get; set; default = "system"; }
    public string interface_style { get; set; default = "classic"; }
    public string color_scheme { get; set; }
    public string accent_color { get; set; default = "default"; }
    public string chat_font_family { get; set; default = "system"; }
    public int chat_font_scale { get; set; default = 100; }

    public bool stickers_enabled { get; set; }
    public bool sticker_animations_enabled { get; set; }
    public bool location_sharing_enabled { get; set; }
    public bool bot_features_enabled { get; set; }
    public string api_mode { get; set; default = "local"; }
    public int api_port { get; set; default = 7842; }
    public string api_tls_cert { get; set; default = ""; }
    public string api_tls_key { get; set; default = ""; }
    public string language { get; set; default = "system"; }
}

public class Dino.Ui.GeneralPreferencesPage : Adw.PreferencesPage {
    private unowned Adw.SwitchRow typing_row;
    private unowned Adw.SwitchRow marker_row;
    private unowned Adw.SwitchRow sync_displayed_state_row;
    private unowned Adw.SwitchRow notification_row;
    private unowned Adw.SwitchRow notification_sounds_row;
    private unowned Adw.SwitchRow keep_background_row;
    private unowned Adw.SwitchRow emoji_row;
    private unowned Adw.SwitchRow send_on_ctrl_enter_row;
    private unowned Adw.SwitchRow stickers_enabled_row;
    private unowned Adw.SwitchRow sticker_animations_row;
    private unowned Adw.SwitchRow location_sharing_row;
    private unowned Adw.SwitchRow bot_features_row;
    private unowned Adw.ComboRow api_mode_row;
    private unowned Adw.SpinRow api_port_row;
    private unowned Adw.EntryRow api_tls_cert_row;
    private unowned Adw.EntryRow api_tls_key_row;
    private unowned Adw.ActionRow api_cert_renew_row;
    private unowned Adw.ActionRow api_cert_delete_row;
    private unowned Adw.ComboRow window_controls_row;
    private unowned Adw.ComboRow interface_style_row;
    private unowned Adw.ComboRow color_scheme_row;
    private unowned Adw.ComboRow accent_color_row;
    private unowned Adw.ComboRow chat_font_row;
    private unowned Adw.ComboRow chat_font_scale_row;
    private unowned Adw.ComboRow language_row;
    private unowned Adw.ActionRow backup_row;
    private unowned Adw.ActionRow restore_backup_row;
    private unowned Adw.ActionRow data_location_row;
    private unowned Adw.ActionRow change_db_password_row;
    private unowned Adw.ActionRow clear_cache_row;
    private unowned Adw.ActionRow reset_database_row;
    private unowned Adw.ActionRow factory_reset_row;

    public ViewModel.GeneralPreferencesPage model { get; set; default = new ViewModel.GeneralPreferencesPage(); }
    private Binding[] model_bindings = new Binding[0];
    private bool content_initialized = false;

    private const string[] ACCENT_COLOR_CODES = {
        "default", "blue", "green", "yellow", "orange", "red", "purple"
    };

    private const int[] CHAT_FONT_SCALES = {
        100, 110, 125, 150, 175, 200
    };
    private Gee.ArrayList<string> chat_font_families = new Gee.ArrayList<string>();
    private Gtk.StringList chat_font_model = new Gtk.StringList(null);
    private uint installed_chat_font_count = 0;
    private bool chat_font_family_updating = false;
    private string? unavailable_chat_font_family = null;
    // Keep the previous source alive until its handlers are disconnected: the
    // model property setter can release it before notify::model is emitted.
    // connect_object() keeps the page weak, so this creates no ownership cycle.
    private ViewModel.GeneralPreferencesPage? chat_font_bound_model = null;
    private ulong chat_font_family_handler = 0;
    private ulong chat_font_scale_handler = 0;
    
    public signal void backup_requested();
    public signal void restore_backup_requested();
    public signal void show_data_location();
    public signal void change_db_password_requested();
    public signal void clear_cache_requested();
    public signal void reset_database_requested();
    public signal void factory_reset_requested();


    construct {
        this.notify["model"].connect(() => {
            if (content_initialized) on_model_changed();
        });
    }

    public void ensure_content() {
        if (content_initialized) return;
        content_initialized = true;

        Builder builder = new Builder.from_resource(
            "/im/dinox/dinox/preferences_window/general_preferences_page.ui");
        var content_page = (Adw.PreferencesPage) builder.get_object("content_page");

        typing_row = (Adw.SwitchRow) builder.get_object("typing_row");
        marker_row = (Adw.SwitchRow) builder.get_object("marker_row");
        sync_displayed_state_row = (Adw.SwitchRow) builder.get_object(
            "sync_displayed_state_row");
        notification_row = (Adw.SwitchRow) builder.get_object("notification_row");
        notification_sounds_row = (Adw.SwitchRow) builder.get_object("notification_sounds_row");
        keep_background_row = (Adw.SwitchRow) builder.get_object("keep_background_row");
        emoji_row = (Adw.SwitchRow) builder.get_object("emoji_row");
        send_on_ctrl_enter_row = (Adw.SwitchRow) builder.get_object("send_on_ctrl_enter_row");
        stickers_enabled_row = (Adw.SwitchRow) builder.get_object("stickers_enabled_row");
        sticker_animations_row = (Adw.SwitchRow) builder.get_object("sticker_animations_row");
        location_sharing_row = (Adw.SwitchRow) builder.get_object("location_sharing_row");
        bot_features_row = (Adw.SwitchRow) builder.get_object("bot_features_row");
        api_mode_row = (Adw.ComboRow) builder.get_object("api_mode_row");
        api_port_row = (Adw.SpinRow) builder.get_object("api_port_row");
        api_tls_cert_row = (Adw.EntryRow) builder.get_object("api_tls_cert_row");
        api_tls_key_row = (Adw.EntryRow) builder.get_object("api_tls_key_row");
        api_cert_renew_row = (Adw.ActionRow) builder.get_object("api_cert_renew_row");
        api_cert_delete_row = (Adw.ActionRow) builder.get_object("api_cert_delete_row");
        window_controls_row = (Adw.ComboRow) builder.get_object("window_controls_row");
        var window_controls_model = new Gtk.StringList(null);
        window_controls_model.append(_("Default (Follow System)"));
        window_controls_model.append(_("Left"));
        window_controls_model.append(_("Right"));
        window_controls_row.model = window_controls_model;
        interface_style_row = (Adw.ComboRow) builder.get_object("interface_style_row");
        color_scheme_row = (Adw.ComboRow) builder.get_object("color_scheme_row");
        accent_color_row = (Adw.ComboRow) builder.get_object("accent_color_row");
        chat_font_row = (Adw.ComboRow) builder.get_object("chat_font_row");
        chat_font_scale_row = (Adw.ComboRow) builder.get_object("chat_font_scale_row");
        language_row = (Adw.ComboRow) builder.get_object("language_row");
        backup_row = (Adw.ActionRow) builder.get_object("backup_row");
        restore_backup_row = (Adw.ActionRow) builder.get_object("restore_backup_row");
        data_location_row = (Adw.ActionRow) builder.get_object("data_location_row");
        change_db_password_row = (Adw.ActionRow) builder.get_object("change_db_password_row");
        clear_cache_row = (Adw.ActionRow) builder.get_object("clear_cache_row");
        reset_database_row = (Adw.ActionRow) builder.get_object("reset_database_row");
        factory_reset_row = (Adw.ActionRow) builder.get_object("factory_reset_row");

        string[] group_ids = {
            "behavior_group", "notifications_group", "appearance_group", "emoji_group",
            "stickers_group", "botmother_group", "user_data_group", "database_group"
        };
        foreach (string group_id in group_ids) {
            var group = (Adw.PreferencesGroup) builder.get_object(group_id);
            content_page.remove(group);
            this.add(group);
        }

        var interface_style_model = new Gtk.StringList(null);
        interface_style_model.append(_("Classic"));
        interface_style_model.append(_("DinoX Design"));
        interface_style_row.model = interface_style_model;

        // Setup color scheme options
        var scheme_model = new Gtk.StringList(null);
        scheme_model.append(_("Default (Follow System)"));
        scheme_model.append(_("Light"));
        scheme_model.append(_("Dark"));
        color_scheme_row.model = scheme_model;

        var accent_model = new Gtk.StringList(null);
        accent_model.append(_("Default"));
        accent_model.append(_("Blue"));
        accent_model.append(_("Green"));
        accent_model.append(_("Yellow"));
        accent_model.append(_("Orange"));
        accent_model.append(_("Red"));
        accent_model.append(_("Purple"));
        accent_color_row.model = accent_model;

        // Family names come from installed fonts or a restored profile, and
        // must remain literal text even if they contain markup characters.
        chat_font_row.use_markup = false;
        chat_font_row.use_subtitle = true;
        chat_font_row.title_lines = 1;
        chat_font_row.subtitle_lines = 1;
        chat_font_model.append(_("System default"));
        chat_font_families.add("system");

        var font_names = new Gee.ArrayList<string>();
        (unowned Pango.FontFamily)[] families;
        this.get_pango_context().get_font_map().list_families(out families);
        foreach (unowned Pango.FontFamily family in families) {
            string name = family.get_name();
            if (name != "") font_names.add(name);
        }
        font_names.sort((left, right) => strcmp(left, right));
        string? previous_name = null;
        foreach (string name in font_names) {
            if (name == previous_name) continue;
            chat_font_model.append(name);
            chat_font_families.add(name);
            previous_name = name;
        }
        installed_chat_font_count = (uint) chat_font_families.size;
        chat_font_row.model = chat_font_model;

        var chat_font_scale_model = new Gtk.StringList(null);
        chat_font_scale_model.append(_("Default") + " (100%)");
        for (int i = 1; i < CHAT_FONT_SCALES.length; i++) {
            chat_font_scale_model.append("%d%%".printf(CHAT_FONT_SCALES[i]));
        }
        chat_font_scale_row.model = chat_font_scale_model;
        chat_font_row.notify["selected"].connect(on_ui_chat_font_family_changed);
        chat_font_scale_row.notify["selected"].connect(on_ui_chat_font_scale_changed);

        language_row.model = InterfaceLanguage.create_model();

        // Setup API mode options
        var mode_model = new Gtk.StringList(null);
        mode_model.append(_( "Local (localhost)"));
        mode_model.append(_( "Network (0.0.0.0 + TLS)"));
        api_mode_row.model = mode_model;

        // Initially hide network-only settings
        update_api_visibility();

        // Connect cert management rows
        api_cert_renew_row.activated.connect(on_cert_renew_clicked);
        api_cert_delete_row.activated.connect(on_cert_delete_clicked);
        
        // Connect backup and data location rows
        backup_row.activated.connect(() => backup_requested());
        restore_backup_row.activated.connect(() => restore_backup_requested());
        data_location_row.activated.connect(() => show_data_location());

        change_db_password_row.activated.connect(() => change_db_password_requested());
        
        // Connect database maintenance rows
        clear_cache_row.activated.connect(() => clear_cache_requested());
        reset_database_row.activated.connect(() => reset_database_requested());
        factory_reset_row.activated.connect(() => factory_reset_requested());

        on_model_changed();
    }

    private void on_model_changed() {
        foreach (Binding binding in model_bindings) {
            binding.unbind();
        }
        disconnect_chat_font_model();
        if (model != null) {
            model_bindings = new Binding[] {
                model.bind_property("window-controls", window_controls_row, "selected",
                    BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL,
                    (binding, source, ref target) => {
                        string placement = source.get_string();
                        target.set_uint(placement == "left" ? 1 : placement == "right" ? 2 : 0);
                        return true;
                    },
                    (binding, source, ref target) => {
                        uint index = source.get_uint();
                        target.set_string(index == 1 ? "left" : index == 2 ? "right" : "system");
                        return true;
                    }),
                model.bind_property("interface-style", interface_style_row, "selected",
                    BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL,
                    (binding, source, ref target) => {
                        target.set_uint(source.get_string() == "website" ? 1 : 0);
                        return true;
                    },
                    (binding, source, ref target) => {
                        target.set_string(source.get_uint() == 1 ? "website" : "classic");
                        return true;
                    }),
                model.bind_property("send-typing", typing_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("send-marker", marker_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("sync-displayed-state",
                    sync_displayed_state_row, "active",
                    BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("notifications", notification_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("notification-sounds", notification_sounds_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("keep-background", keep_background_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("convert-emojis", emoji_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("send-on-ctrl-enter", send_on_ctrl_enter_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("stickers-enabled", stickers_enabled_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("sticker-animations-enabled", sticker_animations_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("location-sharing-enabled", location_sharing_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL),
                model.bind_property("bot-features-enabled", bot_features_row, "active", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL)
            };

            // Bind API mode with custom conversion
            model.notify["api-mode"].connect(on_model_api_mode_changed);
            api_mode_row.notify["selected"].connect(on_ui_api_mode_changed);
            on_model_api_mode_changed();

            // Bind API port
            model.notify["api-port"].connect(() => {
                api_port_row.value = model.api_port;
            });
            api_port_row.notify["value"].connect(() => {
                model.api_port = (int) api_port_row.value;
            });
            api_port_row.value = model.api_port;

            // Bind TLS cert/key paths
            model.notify["api-tls-cert"].connect(() => {
                if (api_tls_cert_row.text != model.api_tls_cert) {
                    api_tls_cert_row.text = model.api_tls_cert;
                }
                update_api_visibility();
            });
            api_tls_cert_row.notify["text"].connect(() => {
                if (model.api_tls_cert != api_tls_cert_row.text) {
                    model.api_tls_cert = api_tls_cert_row.text;
                }
                update_api_visibility();
            });
            api_tls_cert_row.text = model.api_tls_cert ?? "";

            model.notify["api-tls-key"].connect(() => {
                if (api_tls_key_row.text != model.api_tls_key) {
                    api_tls_key_row.text = model.api_tls_key;
                }
                update_api_visibility();
            });
            api_tls_key_row.notify["text"].connect(() => {
                if (model.api_tls_key != api_tls_key_row.text) {
                    model.api_tls_key = api_tls_key_row.text;
                }
                update_api_visibility();
            });
            api_tls_key_row.text = model.api_tls_key ?? "";

            // Show/hide API settings based on bot_features_enabled
            bot_features_row.notify["active"].connect(update_api_visibility);
            update_api_visibility();
            
            // Bind color scheme with custom conversion
            model.notify["color-scheme"].connect(on_model_color_scheme_changed);
            color_scheme_row.notify["selected"].connect(on_ui_color_scheme_changed);
            on_model_color_scheme_changed();

            model.notify["accent-color"].connect(on_model_accent_color_changed);
            accent_color_row.notify["selected"].connect(on_ui_accent_color_changed);
            on_model_accent_color_changed();

            chat_font_bound_model = model;
            chat_font_family_handler = model.notify["chat-font-family"].connect(on_model_chat_font_family_changed);
            chat_font_scale_handler = model.notify["chat-font-scale"].connect(on_model_chat_font_scale_changed);
            on_model_chat_font_family_changed();
            on_model_chat_font_scale_changed();

            // Bind language with custom conversion
            initial_language = InterfaceLanguage.normalize_setting(model.language);
            model.notify["language"].connect(on_model_language_changed);
            language_row.notify["selected"].connect(on_ui_language_changed);
            on_model_language_changed();
        } else {
            model_bindings = new Binding[0];
        }
    }

    private void on_model_color_scheme_changed() {
        switch (model.color_scheme) {
            case "light":
                color_scheme_row.selected = 1;
                break;
            case "dark":
                color_scheme_row.selected = 2;
                break;
            default:
                color_scheme_row.selected = 0;
                break;
        }
    }

    private void on_ui_color_scheme_changed() {
        switch (color_scheme_row.selected) {
            case 1:
                model.color_scheme = "light";
                break;
            case 2:
                model.color_scheme = "dark";
                break;
            default:
                model.color_scheme = "default";
                break;
        }
    }

    private void on_model_accent_color_changed() {
        string code = model.accent_color ?? "default";
        for (uint i = 0; i < ACCENT_COLOR_CODES.length; i++) {
            if (ACCENT_COLOR_CODES[i] == code) {
                accent_color_row.selected = i;
                return;
            }
        }
        accent_color_row.selected = 0;
    }

    private void on_ui_accent_color_changed() {
        uint selected = accent_color_row.selected;
        model.accent_color = selected < ACCENT_COLOR_CODES.length ? ACCENT_COLOR_CODES[selected] : "default";
    }

    private void on_model_chat_font_family_changed() {
        if (model == null || chat_font_family_updating) return;
        string family = model.chat_font_family ?? "system";
        if (family.strip() == "") family = "system";
        string folded_family = family.casefold();

        // Updating the model can change its selection too. Never write those
        // notifications back to Settings: the saved name may belong to another
        // OS or to a font that is temporarily not installed on this machine.
        chat_font_family_updating = true;
        try {
            uint selected = installed_chat_font_count;
            for (uint i = 0; i < installed_chat_font_count; i++) {
                if (chat_font_families[(int) i] == family ||
                        (i > 0 && chat_font_families[(int) i].casefold() == folded_family)) {
                    selected = i;
                    break;
                }
            }

            if (selected < installed_chat_font_count ||
                    unavailable_chat_font_family != family) {
                if (unavailable_chat_font_family != null) {
                    chat_font_model.remove(installed_chat_font_count);
                    chat_font_families.remove_at((int) installed_chat_font_count);
                    unavailable_chat_font_family = null;
                }
                if (selected == installed_chat_font_count) {
                    chat_font_families.add(family);
                    chat_font_model.append(_("Not installed: %s").printf(family));
                    unavailable_chat_font_family = family;
                }
            }

            chat_font_row.tooltip_text = unavailable_chat_font_family != null
                ? _("Not installed: %s").printf(family) : null;
            chat_font_row.selected = selected;
        } finally {
            chat_font_family_updating = false;
        }
    }

    private void on_ui_chat_font_family_changed() {
        if (model == null || chat_font_family_updating) return;
        uint selected = chat_font_row.selected;
        if (selected >= chat_font_families.size) return;
        model.chat_font_family = chat_font_families[(int) selected];
    }

    private bool chat_font_scale_updating = false;

    private void on_model_chat_font_scale_changed() {
        if (model == null) return;
        chat_font_scale_updating = true;
        for (uint i = 0; i < CHAT_FONT_SCALES.length; i++) {
            if (CHAT_FONT_SCALES[i] == model.chat_font_scale) {
                chat_font_scale_row.selected = i;
                chat_font_scale_updating = false;
                return;
            }
        }
        chat_font_scale_row.selected = 0;
        chat_font_scale_updating = false;
    }

    private void on_ui_chat_font_scale_changed() {
        if (model == null || chat_font_scale_updating) return;
        uint selected = chat_font_scale_row.selected;
        model.chat_font_scale = selected < CHAT_FONT_SCALES.length ? CHAT_FONT_SCALES[selected] : 100;
    }

    private void disconnect_chat_font_model() {
        if (chat_font_bound_model != null) {
            if (chat_font_family_handler != 0 &&
                    SignalHandler.is_connected(chat_font_bound_model, chat_font_family_handler))
                chat_font_bound_model.disconnect(chat_font_family_handler);
            if (chat_font_scale_handler != 0 &&
                    SignalHandler.is_connected(chat_font_bound_model, chat_font_scale_handler))
                chat_font_bound_model.disconnect(chat_font_scale_handler);
        }
        chat_font_family_handler = 0;
        chat_font_scale_handler = 0;
        chat_font_bound_model = null;
    }

    private string initial_language = "system";
    private bool language_updating = false;

    private void on_model_language_changed() {
        language_updating = true;
        string code = InterfaceLanguage.normalize_setting(model.language);
        for (uint i = 0; i < InterfaceLanguage.CODES.length; i++) {
            if (InterfaceLanguage.CODES[i] == code) {
                language_row.selected = i;
                language_updating = false;
                return;
            }
        }
        language_row.selected = 0;
        language_updating = false;
    }

    private void on_ui_language_changed() {
        if (language_updating) return;
        uint sel = language_row.selected;
        string new_code = (sel < InterfaceLanguage.CODES.length) ? InterfaceLanguage.CODES[sel] : "system";
        model.language = new_code;
        // Show restart hint if language changed from initial value
        if (new_code != initial_language) {
            language_row.subtitle = _("Restart DinoX to apply the new language");
        } else {
            language_row.subtitle = _("Override the system language for the DinoX interface");
        }
    }

    private void on_model_api_mode_changed() {
        if (model.api_mode == "network") {
            api_mode_row.selected = 1;
        } else {
            api_mode_row.selected = 0;
        }
        update_api_visibility();
    }

    private void on_ui_api_mode_changed() {
        if (api_mode_row.selected == 1) {
            model.api_mode = "network";
        } else {
            model.api_mode = "local";
        }
        update_api_visibility();
    }

    private void update_api_visibility() {
        bool bot_enabled = bot_features_row.active;
        bool network_mode = (api_mode_row.selected == 1);

        api_mode_row.visible = bot_enabled;
        api_port_row.visible = bot_enabled;
        api_tls_cert_row.visible = bot_enabled && network_mode;
        api_tls_key_row.visible = bot_enabled && network_mode;

        // Cert management buttons: only in network mode with empty (auto) cert paths
        bool auto_cert = (api_tls_cert_row.text == null || api_tls_cert_row.text == "") &&
                         (api_tls_key_row.text == null || api_tls_key_row.text == "");
        string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
        string cert_path = Path.build_filename(cert_dir, "server.crt");
        bool cert_exists = FileUtils.test(cert_path, FileTest.EXISTS);

        api_cert_renew_row.visible = bot_enabled && network_mode && auto_cert && cert_exists;
        api_cert_delete_row.visible = bot_enabled && network_mode && auto_cert && cert_exists;

        // Update subtitle for TLS rows
        if (network_mode) {
            string cert_hint = (api_tls_cert_row.text == null || api_tls_cert_row.text == "")
                ? _( "Empty = auto-generated self-signed") : "";
            string key_hint = (api_tls_key_row.text == null || api_tls_key_row.text == "")
                ? _( "Empty = auto-generated self-signed") : "";
            // Placeholder text to hint auto-generation
            api_tls_cert_row.set_tooltip_text(cert_hint);
            api_tls_key_row.set_tooltip_text(key_hint);
        }
    }

    private void on_cert_renew_clicked() {
        if (!can_manage_automatic_api_certificate()) return;
        string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
        string cert_path = Path.build_filename(cert_dir, "server.crt");
        string key_path = Path.build_filename(cert_dir, "server.key");

        // Delete existing cert files
        if (FileUtils.test(cert_path, FileTest.EXISTS)) {
            FileUtils.remove(cert_path);
        }
        if (FileUtils.test(key_path, FileTest.EXISTS)) {
            FileUtils.remove(key_path);
        }

        // Update subtitle to show status
        api_cert_renew_row.subtitle = _( "Certificate deleted. Server will restart with new certificate.");
        update_api_visibility();

        // Trigger API server restart by toggling a setting
        model.api_tls_cert = " ";
        model.api_tls_cert = "";
    }

    private void on_cert_delete_clicked() {
        if (!can_manage_automatic_api_certificate()) return;
        string cert_dir = Path.build_filename(Environment.get_user_data_dir(), "dinox", "api-tls");
        string cert_path = Path.build_filename(cert_dir, "server.crt");
        string key_path = Path.build_filename(cert_dir, "server.key");

        if (FileUtils.test(cert_path, FileTest.EXISTS)) {
            FileUtils.remove(cert_path);
        }
        if (FileUtils.test(key_path, FileTest.EXISTS)) {
            FileUtils.remove(key_path);
        }

        api_cert_delete_row.subtitle = _( "Certificate and key deleted.");
        update_api_visibility();

        // Trigger API server restart
        model.api_tls_cert = " ";
        model.api_tls_cert = "";
    }

    private bool can_manage_automatic_api_certificate() {
        // Recheck at activation: stale visibility must never erase a custom
        // certificate setting or act while the API is disabled/local-only.
        return model != null && model.bot_features_enabled && model.api_mode == "network" &&
            (model.api_tls_cert == null || model.api_tls_cert == "") &&
            (model.api_tls_key == null || model.api_tls_key == "") &&
            api_tls_cert_row.text == "" && api_tls_key_row.text == "";
    }

    ~GeneralPreferencesPage() {
        disconnect_chat_font_model();
        foreach (Binding binding in model_bindings) {
            binding.unbind();
        }
    }
}
