namespace Dino.Entities {

public class Settings : Object {

    private Database db;

    public Settings.from_db(Database db) {
        this.db = db;

        send_typing_ = col_to_bool_or_default("send_typing", true);
        send_marker_ = col_to_bool_or_default("send_marker", true);
        sync_displayed_state_ = col_to_bool_or_default(
            "sync_displayed_state", true);
        notifications_ = col_to_bool_or_default("notifications", true);
        notification_sounds_ = col_to_bool_or_default("notification_sounds", true);
        convert_utf8_smileys_ = col_to_bool_or_default("convert_utf8_smileys", true);
        send_on_ctrl_enter_ = col_to_bool_or_default("send_on_ctrl_enter", false);
        check_spelling = col_to_bool_or_default("check_spelling", true);
        keep_background_ = col_to_bool_or_default("keep_background", true);
        window_controls_ = normalize_window_controls(col_to_string_or_default("window_controls", "system"));
        interface_style_ = col_to_string_or_default("interface_style", "classic");
        color_scheme_ = col_to_string_or_default("color_scheme", "default");
        accent_color_ = col_to_string_or_default("accent_color", "default");
        chat_font_family_ = col_to_string_or_default("chat_font_family", "system");
        if (chat_font_family_.strip() == "") chat_font_family_ = "system";
        chat_font_scale_ = normalize_chat_font_scale(col_to_int_or_default("chat_font_scale", 100));

        stickers_enabled_ = col_to_bool_or_default("stickers_enabled", true);
        sticker_animations_enabled_ = col_to_bool_or_default("sticker_animations_enabled", true);
        location_sharing_enabled_ = col_to_bool_or_default("location_sharing_enabled", true);
        bot_features_enabled_ = col_to_bool_or_default("bot_features_enabled", false);
        api_mode_ = col_to_string_or_default("api_mode", "local");
        api_port_ = col_to_int_or_default("api_port", 7842);
        api_tls_cert_ = col_to_string_or_default("api_tls_cert", "");
        api_tls_key_ = col_to_string_or_default("api_tls_key", "");
        presence_show_ = col_to_string_or_default("presence_show", "online");
        presence_status_msg_ = col_to_string_or_default("presence_status_msg", "");
        language_ = col_to_string_or_default("language", "system");

        call_audio_input_device_ = col_to_string_or_default("call_audio_input_device", "");
        call_audio_output_device_ = col_to_string_or_default("call_audio_output_device", "");
        call_video_device_ = col_to_string_or_default("call_video_device", "");
        call_network_mode_ = col_to_string_or_default("call_network_mode", "automatic");
        msg_audio_input_device_ = col_to_string_or_default("msg_audio_input_device", "");
        msg_audio_output_device_ = col_to_string_or_default("msg_audio_output_device", "");
        msg_video_device_ = col_to_string_or_default("msg_video_device", "");
    }

    private bool col_to_bool_or_default(string key, bool def) {
        string? val = db.settings.select({db.settings.value}).with(db.settings.key, "=", key)[db.settings.value];
        return val != null ? bool.parse(val) : def;
    }

    private string col_to_string_or_default(string key, string def) {
        string? val = db.settings.select({db.settings.value}).with(db.settings.key, "=", key)[db.settings.value];
        return val ?? def;
    }

    private int col_to_int_or_default(string key, int def) {
        string? val = db.settings.select({db.settings.value}).with(db.settings.key, "=", key)[db.settings.value];
        return val != null ? int.parse(val) : def;
    }

    private bool send_typing_;
    public bool send_typing {
        get { return send_typing_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "send_typing", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            send_typing_ = value;
        }
    }

    private bool send_marker_;
    public bool send_marker {
        get { return send_marker_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "send_marker", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            send_marker_ = value;
        }
    }

    private bool sync_displayed_state_;
    public bool sync_displayed_state {
        get { return sync_displayed_state_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "sync_displayed_state", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            sync_displayed_state_ = value;
        }
    }

    private bool notifications_;
    public bool notifications {
        get { return notifications_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "notifications", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            notifications_ = value;
        }
    }

    private bool notification_sounds_;
    public bool notification_sounds {
        get { return notification_sounds_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "notification_sounds", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            notification_sounds_ = value;
        }
    }

    private bool convert_utf8_smileys_;
    public bool convert_utf8_smileys {
        get { return convert_utf8_smileys_; }
        set {
            db.settings.upsert()
                    .value(db.settings.key, "convert_utf8_smileys", true)
                    .value(db.settings.value, value.to_string())
                    .perform();
            convert_utf8_smileys_ = value;
        }
    }

    private bool send_on_ctrl_enter_;
    public bool send_on_ctrl_enter {
        get { return send_on_ctrl_enter_; }
        set {
            if (send_on_ctrl_enter_ == value) return;
            db.settings.upsert()
                .value(db.settings.key, "send_on_ctrl_enter", true)
                .value(db.settings.value, value.to_string())
                .perform();
            send_on_ctrl_enter_ = value;
        }
    }

    // There is currently no spell checking for GTK4, thus there is currently no UI for this setting.
    private bool check_spelling_;
    public bool check_spelling {
        get { return check_spelling_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "check_spelling", true)
                .value(db.settings.value, value.to_string())
                .perform();
            check_spelling_ = value;
        }
    }

    private bool keep_background_;
    public bool keep_background {
        get { return keep_background_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "keep_background", true)
                .value(db.settings.value, value.to_string())
                .perform();
            keep_background_ = value;
        }
    }

    private static string normalize_window_controls(string value) {
        return value == "left" || value == "right" ? value : "system";
    }

    private string window_controls_;
    public string window_controls {
        get { return window_controls_; }
        set {
            string placement = normalize_window_controls(value);
            if (placement == window_controls_) return;
            db.settings.upsert()
                .value(db.settings.key, "window_controls", true)
                .value(db.settings.value, placement)
                .perform();
            window_controls_ = placement;
        }
    }

    private string interface_style_;
    public string interface_style {
        get { return interface_style_; }
        set {
            if (value == interface_style_) return;
            db.settings.upsert()
                .value(db.settings.key, "interface_style", true)
                .value(db.settings.value, value)
                .perform();
            interface_style_ = value;
        }
    }

    private string color_scheme_;
    public string color_scheme {
        get { return color_scheme_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "color_scheme", true)
                .value(db.settings.value, value)
                .perform();
            color_scheme_ = value;
        }
    }

    private string accent_color_;
    public string accent_color {
        get { return accent_color_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "accent_color", true)
                .value(db.settings.value, value)
                .perform();
            accent_color_ = value;
        }
    }

    private string chat_font_family_;
    public string chat_font_family {
        get { return chat_font_family_; }
        set {
            string normalized = value.strip() == "" ? "system" : value;
            db.settings.upsert()
                .value(db.settings.key, "chat_font_family", true)
                .value(db.settings.value, normalized)
                .perform();
            chat_font_family_ = normalized;
        }
    }

    private int chat_font_scale_;
    public int chat_font_scale {
        get { return chat_font_scale_; }
        set {
            int normalized = normalize_chat_font_scale(value);
            db.settings.upsert()
                .value(db.settings.key, "chat_font_scale", true)
                .value(db.settings.value, normalized.to_string())
                .perform();
            chat_font_scale_ = normalized;
        }
    }

    private int normalize_chat_font_scale(int value) {
        switch (value) {
            case 100:
            case 110:
            case 125:
            case 150:
            case 175:
            case 200:
                return value;
            default:
                return 100;
        }
    }

    private bool stickers_enabled_;
    public bool stickers_enabled {
        get { return stickers_enabled_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "stickers_enabled", true)
                .value(db.settings.value, value.to_string())
                .perform();
            stickers_enabled_ = value;
        }
    }

    private bool sticker_animations_enabled_;
    public bool sticker_animations_enabled {
        get { return sticker_animations_enabled_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "sticker_animations_enabled", true)
                .value(db.settings.value, value.to_string())
                .perform();
            sticker_animations_enabled_ = value;
        }
    }

    private bool location_sharing_enabled_;
    public bool location_sharing_enabled {
        get { return location_sharing_enabled_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "location_sharing_enabled", true)
                .value(db.settings.value, value.to_string())
                .perform();
            location_sharing_enabled_ = value;
        }
    }

    private bool bot_features_enabled_;
    public bool bot_features_enabled {
        get { return bot_features_enabled_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "bot_features_enabled", true)
                .value(db.settings.value, value.to_string())
                .perform();
            bot_features_enabled_ = value;
        }
    }

    private string api_mode_;
    public string api_mode {
        get { return api_mode_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "api_mode", true)
                .value(db.settings.value, value)
                .perform();
            api_mode_ = value;
        }
    }

    private int api_port_;
    public int api_port {
        get { return api_port_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "api_port", true)
                .value(db.settings.value, value.to_string())
                .perform();
            api_port_ = value;
        }
    }

    private string api_tls_cert_;
    public string api_tls_cert {
        get { return api_tls_cert_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "api_tls_cert", true)
                .value(db.settings.value, value)
                .perform();
            api_tls_cert_ = value;
        }
    }

    private string api_tls_key_;
    public string api_tls_key {
        get { return api_tls_key_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "api_tls_key", true)
                .value(db.settings.value, value)
                .perform();
            api_tls_key_ = value;
        }
    }

    private string presence_show_;
    public string presence_show {
        get { return presence_show_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "presence_show", true)
                .value(db.settings.value, value)
                .perform();
            presence_show_ = value;
        }
    }

    private string presence_status_msg_;
    public string presence_status_msg {
        get { return presence_status_msg_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "presence_status_msg", true)
                .value(db.settings.value, value)
                .perform();
            presence_status_msg_ = value;
        }
    }

    private string language_;
    public string language {
        get { return language_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "language", true)
                .value(db.settings.value, value)
                .perform();
            language_ = value;
            // Also write to plain text file so it can be read at early startup
            // before the encrypted DB is opened
            string dir = Path.build_filename(Environment.get_user_data_dir(), "dinox");
            DirUtils.create_with_parents(dir, 0700);
            string lang_file = Path.build_filename(dir, "language");
            try {
                FileUtils.set_contents(lang_file, value);
            } catch (FileError e) {
                warning("Could not write language file: %s", e.message);
            }
        }
    }

    private string call_audio_input_device_;
    public string call_audio_input_device {
        get { return call_audio_input_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "call_audio_input_device", true)
                .value(db.settings.value, value)
                .perform();
            call_audio_input_device_ = value;
        }
    }

    private string call_audio_output_device_;
    public string call_audio_output_device {
        get { return call_audio_output_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "call_audio_output_device", true)
                .value(db.settings.value, value)
                .perform();
            call_audio_output_device_ = value;
        }
    }

    private string call_video_device_;
    public string call_video_device {
        get { return call_video_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "call_video_device", true)
                .value(db.settings.value, value)
                .perform();
            call_video_device_ = value;
        }
    }

    private string call_network_mode_;
    public string call_network_mode {
        get { return call_network_mode_; }
        set {
            string normalized = value == "low-bandwidth-2g" ? value : "automatic";
            db.settings.upsert()
                .value(db.settings.key, "call_network_mode", true)
                .value(db.settings.value, normalized)
                .perform();
            call_network_mode_ = normalized;
        }
    }

    private string msg_audio_input_device_;
    public string msg_audio_input_device {
        get { return msg_audio_input_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "msg_audio_input_device", true)
                .value(db.settings.value, value)
                .perform();
            msg_audio_input_device_ = value;
        }
    }

    private string msg_audio_output_device_;
    public string msg_audio_output_device {
        get { return msg_audio_output_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "msg_audio_output_device", true)
                .value(db.settings.value, value)
                .perform();
            msg_audio_output_device_ = value;
        }
    }

    private string msg_video_device_;
    public string msg_video_device {
        get { return msg_video_device_; }
        set {
            db.settings.upsert()
                .value(db.settings.key, "msg_video_device", true)
                .value(db.settings.value, value)
                .perform();
            msg_video_device_ = value;
        }
    }

    public Encryption get_default_encryption(Account account) {
        string? setting = db.account_settings.get_value(account.id, "default-encryption");
        if (setting != null) {
            return (Encryption) int.parse(setting);
        }
        return Encryption.OMEMO;
    }

    public void set_default_encryption(Account account, Encryption encryption) {
        db.account_settings.upsert()
                .value(db.account_settings.key, "default-encryption", true)
                .value(db.account_settings.account_id, account.id, true)
                .value(db.account_settings.value, ((int)encryption).to_string())
                .perform();


    }
}

}
