/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Gdk;
using Gee;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

private class BotTargetCandidate : Object {
    public string jid { get; private set; }
    public string title { get; private set; }
    public string subtitle { get; private set; }
    public string message_type { get; private set; }

    public BotTargetCandidate(string jid, string title, string subtitle, string message_type = "chat") {
        this.jid = jid;
        this.title = title;
        this.subtitle = subtitle;
        this.message_type = message_type;
    }
}

private class CloudBotMetadata : Object {
    public string bot_jid { get; private set; }
    public string owner_jid { get; private set; }
    public string display_name { get; private set; }
    public string status { get; private set; }

    public CloudBotMetadata(string bot_jid, string owner_jid, string display_name, string status) {
        this.bot_jid = bot_jid;
        this.owner_jid = owner_jid;
        this.display_name = display_name;
        this.status = status;
    }
}

[GtkTemplate (ui = "/im/dinox/dinox/bot_manager_dialog.ui")]
public class BotManagerDialog : Adw.Dialog {

    [GtkChild] private unowned Gtk.Stack main_stack;
    [GtkChild] private unowned Gtk.ListBox bot_list;
    [GtkChild] private unowned Gtk.Button create_button;
    [GtkChild] private unowned Gtk.Label api_status_label;
    [GtkChild] private unowned Adw.StatusPage error_page;
    [GtkChild] private unowned Adw.SwitchRow account_enabled_switch;

    private Soup.Session http;
    private bool toggle_loading = false; // suppress signal during load
    private bool api_reachable = false; // track API availability
    private Gee.ArrayList<string> cloud_management_tokens = new Gee.ArrayList<string>();

    private const string[] PERMISSION_KEYS = {
        "all",
        "send_message",
        "receive_updates",
        "webhook",
        "file_send",
        "muc_join",
        "muc_send",
        "admin"
    };

    private const uint AI_CONSOLE_TIMEOUT_SECONDS = 30;
    private const int MAX_BOT_AVATAR_PIXEL = 256;
    private const string CLOUD_BOT_BASE_URL = "https://cloud.dinox.im";
    private const string[] AI_MODEL_PRESET_VALUES = {
        "",
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "grok-4.20-reasoning",
        "grok-4.3",
        "llama-3.3-70b-versatile",
        "gpt-4o-mini"
    };

    public string account_jid { get; set; default = ""; }

    construct {
        http = new Soup.Session();

        create_button.clicked.connect(on_create_clicked);

        // Toggle per-account Botmother enabled/disabled
        account_enabled_switch.notify["active"].connect(() => {
            if (!toggle_loading && account_jid != "") {
                start_set_account_enabled(account_enabled_switch.active);
            }
        });

        // Load when mapped (account_jid may be set after construct)
        this.notify["account-jid"].connect(() => {
            if (account_jid != "") {
                this.title = _("Botmother") + " \u2014 %s".printf(account_jid);
                main_stack.visible_child_name = "loading";
                start_load_account_status();
            }
        });

        // Auto-refresh when dialog gets focus — BUT NOT when clicking inside the dialog
        // Only refresh when the entire dialog regains focus from outside
        this.map.connect(() => {
            if (account_jid != "" && api_reachable) {
                start_load_bots();
            }
        });

        main_stack.visible_child_name = "loading";
        // Initial load deferred until account_jid is set
    }

    private void start_set_account_enabled(bool new_enabled) {
        set_account_enabled.begin(new_enabled, (obj, res) => {
            set_account_enabled.end(res);
        });
    }

    private void start_load_account_status() {
        load_account_status.begin((obj, res) => {
            load_account_status.end(res);
        });
    }

    private void start_load_bots() {
        load_bots.begin((obj, res) => {
            load_bots.end(res);
        });
    }

    private void present_action_error(string detail) {
        show_action_error.begin(detail, (obj, res) => {
            show_action_error.end(res);
        });
    }

    private void start_cloud_load_bot(string token, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        cloud_load_bot.begin(token, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, (obj, res) => {
            cloud_load_bot.end(res);
        });
    }

    private void start_cloud_set_bot_status(string token, string status, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        cloud_set_bot_status.begin(token, status, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, (obj, res) => {
            cloud_set_bot_status.end(res);
        });
    }

    private void start_cloud_confirm_rotate_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        cloud_confirm_rotate_token.begin(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, (obj, res) => {
            cloud_confirm_rotate_token.end(res);
        });
    }

    private void start_cloud_confirm_event_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        cloud_confirm_event_token.begin(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, (obj, res) => {
            cloud_confirm_event_token.end(res);
        });
    }

    private void start_cloud_confirm_deprovision(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        cloud_confirm_deprovision.begin(token_row, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, (obj, res) => {
            cloud_confirm_deprovision.end(res);
        });
    }

    private void start_remove_cloud_token(string token) {
        remove_cloud_token.begin(token, (obj, res) => {
            remove_cloud_token.end(res);
        });
    }

    private void start_save_cloud_token(string token) {
        save_cloud_token.begin(token, (obj, res) => {
            save_cloud_token.end(res);
        });
    }

    private void present_new_cloud_token_dialog(string token) {
        show_new_cloud_token_dialog.begin(token, (obj, res) => {
            show_new_cloud_token_dialog.end(res);
        });
    }

    private void present_new_cloud_event_token_dialog(string token) {
        show_new_cloud_event_token_dialog.begin(token, (obj, res) => {
            show_new_cloud_event_token_dialog.end(res);
        });
    }

    private void start_add_cloud_token_from_create(string token) {
        add_cloud_token_from_create.begin(token, (obj, res) => {
            add_cloud_token_from_create.end(res);
        });
    }

    private void start_save_permissions(int64 bot_id, string permissions) {
        save_permissions.begin(bot_id, permissions, (obj, res) => {
            save_permissions.end(res);
        });
    }

    private void start_choose_bot_avatar(int64 bot_id, Adw.ExpanderRow expander, Adw.ActionRow status_row, Gtk.Button remove_btn) {
        choose_bot_avatar.begin(bot_id, expander, status_row, remove_btn, (obj, res) => {
            choose_bot_avatar.end(res);
        });
    }

    private void start_remove_bot_avatar(int64 bot_id, Adw.ExpanderRow expander, Adw.ActionRow status_row, Gtk.Button remove_btn) {
        remove_bot_avatar.begin(bot_id, expander, status_row, remove_btn, (obj, res) => {
            remove_bot_avatar.end(res);
        });
    }

    private void start_save_targets(int64 bot_id, string target_mode, string target_list) {
        save_targets.begin(bot_id, target_mode, target_list, (obj, res) => {
            save_targets.end(res);
        });
    }

    private void start_save_ai_setup(int64 bot_id, string provider, string api_key, string model, Adw.ExpanderRow expander, Adw.SwitchRow active_row, Adw.ActionRow status_row, Gtk.Button save_btn) {
        save_ai_setup.begin(bot_id, provider, api_key, model, expander, active_row, status_row, save_btn, (obj, res) => {
            save_ai_setup.end(res);
        });
    }

    private void start_save_ai_enabled(int64 bot_id, bool enabled, Adw.ExpanderRow expander, Adw.SwitchRow active_row) {
        save_ai_enabled.begin(bot_id, enabled, expander, active_row, (obj, res) => {
            save_ai_enabled.end(res);
        });
    }

    private void start_save_ai_behavior(int64 bot_id, string? system_prompt, string? muc_owner_notify, string? muc_ai_mode, Adw.ActionRow status_row) {
        save_ai_behavior.begin(bot_id, system_prompt, muc_owner_notify, muc_ai_mode, status_row, (obj, res) => {
            save_ai_behavior.end(res);
        });
    }

    private void start_ask_ai_console(int64 bot_id, string question, Adw.ActionRow answer_row, Gtk.Button ask_btn) {
        ask_ai_console.begin(bot_id, question, answer_row, ask_btn, (obj, res) => {
            ask_ai_console.end(res);
        });
    }

    private void start_save_telegram_setup(int64 bot_id, string token, string chat_id, string mode, bool configured, Adw.ExpanderRow expander, Adw.SwitchRow active_row, Adw.ActionRow status_row, Gtk.Button save_btn) {
        save_telegram_setup.begin(bot_id, token, chat_id, mode, configured, expander, active_row, status_row, save_btn, (obj, res) => {
            save_telegram_setup.end(res);
        });
    }

    private void start_save_telegram_enabled(int64 bot_id, bool enabled, Adw.ExpanderRow expander, Adw.SwitchRow active_row) {
        save_telegram_enabled.begin(bot_id, enabled, expander, active_row, (obj, res) => {
            save_telegram_enabled.end(res);
        });
    }

    private void start_save_webhook(int64 bot_id, string webhook_url, Adw.ExpanderRow expander, Adw.ActionRow secret_row, Gtk.Button save_btn, Gtk.Button disable_btn) {
        save_webhook.begin(bot_id, webhook_url, expander, secret_row, save_btn, disable_btn, (obj, res) => {
            save_webhook.end(res);
        });
    }

    private void start_disable_webhook(int64 bot_id, Adw.EntryRow url_row, Adw.ExpanderRow expander, Adw.ActionRow secret_row, Gtk.Button save_btn, Gtk.Button disable_btn) {
        disable_webhook.begin(bot_id, url_row, expander, secret_row, save_btn, disable_btn, (obj, res) => {
            disable_webhook.end(res);
        });
    }

    private void present_webhook_secret_dialog(string secret) {
        show_webhook_secret_dialog.begin(secret, (obj, res) => {
            show_webhook_secret_dialog.end(res);
        });
    }

    private void start_join_bot_room(int64 bot_id, string room_jid, string nick, Adw.ActionRow status_row, Gtk.Button join_btn) {
        join_bot_room.begin(bot_id, room_jid, nick, status_row, join_btn, (obj, res) => {
            join_bot_room.end(res);
        });
    }

    private void start_leave_bot_room(int64 bot_id, string room_jid, Adw.ActionRow status_row, Gtk.Button leave_btn) {
        leave_bot_room.begin(bot_id, room_jid, status_row, leave_btn, (obj, res) => {
            leave_bot_room.end(res);
        });
    }

    private void start_send_bot_console_message(int64 bot_id, string target, string text, string msg_type, Adw.ActionRow status_row, Gtk.Button send_btn) {
        send_bot_console_message.begin(bot_id, target, text, msg_type, status_row, send_btn, (obj, res) => {
            send_bot_console_message.end(res);
        });
    }

    private void start_confirm_delete(int64 bot_id, string bot_name) {
        confirm_delete.begin(bot_id, bot_name, (obj, res) => {
            confirm_delete.end(res);
        });
    }

    private void start_regenerate_token(int64 bot_id) {
        regenerate_token.begin(bot_id, (obj, res) => {
            regenerate_token.end(res);
        });
    }

    private void present_new_token_dialog(string token) {
        show_new_token_dialog.begin(token, (obj, res) => {
            show_new_token_dialog.end(res);
        });
    }

    private void start_confirm_revoke(int64 bot_id, string bot_name) {
        confirm_revoke.begin(bot_id, bot_name, (obj, res) => {
            confirm_revoke.end(res);
        });
    }

    private void start_set_bot_status(int64 bot_id, string status) {
        set_bot_status.begin(bot_id, status, (obj, res) => {
            set_bot_status.end(res);
        });
    }

    /**
     * Quick connectivity check — try to reach the Botmother API.
     * Returns true if the API responded, false on connection error.
     */
    private async bool check_api_reachable(bool start_if_disabled = false) {
        if (yield probe_api()) return true;

        if (!start_if_disabled) {
            api_reachable = false;
            return false;
        }

        var app = Dino.Application.get_default();
        if (!app.settings.bot_features_enabled) {
            app.settings.bot_features_enabled = true;
        }

        for (int i = 0; i < 12; i++) {
            yield wait_ms(150);
            if (yield probe_api()) return true;
        }

        api_reachable = false;
        return false;
    }

    private async bool probe_api() {
        try {
            var msg = create_api_message("GET", "/health");
            yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            api_reachable = msg.status_code == 200;
            return api_reachable;
        } catch (Error e) {
            api_reachable = false;
            return false;
        }
    }

    private async void wait_ms(uint interval) {
        SourceFunc callback = wait_ms.callback;
        Timeout.add(interval, () => {
            callback();
            return false;
        });
        yield;
    }

    // Shared helper: POST JSON and return parsed response bytes (clone removal).
    private async Soup.Message post_bot_api_with_response(string path, string json_body, out Bytes response) throws Error {
        if (!(yield check_api_reachable(true))) {
            throw new IOError.FAILED("Botmother API is not available on port %u".printf(get_api_port()));
        }
        var msg = create_api_message("POST", path);
        msg.set_request_body_from_bytes("application/json", new Bytes(json_body.data));
        response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
        return msg;
    }

    // Load the per-account enabled status from the API, then load bots
    private async void load_account_status() {
        /* First check if the Botmother API is running at all */
        if (!(yield check_api_reachable())) {
            toggle_loading = false;
            api_status_label.label = _("Botmother API not running (port %u)").printf(get_api_port());
            create_button.sensitive = true;
            account_enabled_switch.sensitive = false;
            Gtk.ListBoxRow? old_row;
            while ((old_row = bot_list.get_row_at_index(0)) != null) {
                bot_list.remove(old_row);
            }
            append_configured_cloud_bot_rows();
            main_stack.visible_child_name = "list";
            return;  /* Don't spam warnings — API is simply not started */
        }
        create_button.sensitive = true;
        account_enabled_switch.sensitive = true;

        toggle_loading = true;
        try {
            var msg = create_api_message("GET", "/bot/account/status?account=%s".printf(
                GLib.Uri.escape_string(account_jid, null, false)));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code == 200) {
                var parser = new Json.Parser();
                Util.load_json_response(parser, response);
                var root = parser.get_root().get_object();
                if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                    var result = root.get_object_member("result");
                    if (result.has_member("enabled")) {
                        account_enabled_switch.active = result.get_boolean_member("enabled");
                    }
                } else if (root.has_member("enabled")) {
                    account_enabled_switch.active = root.get_boolean_member("enabled");
                }
            }
        } catch (Error e) {
            warning("BotManager: Failed to load account status: %s", e.message);
        }
        toggle_loading = false;
        yield load_bots();
    }

    // Toggle per-account enabled via POST to API
    private async void set_account_enabled(bool new_enabled) {
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("account");
            builder.add_string_value(account_jid);
            builder.set_member_name("enabled");
            builder.add_boolean_value(new_enabled);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);
            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/account/status", json_body, out response);

            if (msg.status_code != 200) {
                string detail = format_api_failure(_("Updating account setting"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_account_status();
            }
        } catch (Error e) {
            warning("BotManager: Toggle error: %s", e.message);
            present_action_error(action_error_message(_("Updating account setting"), e.message));
            start_load_account_status();
        }
    }

    private async void load_bots() {
        try {
            yield load_persisted_cloud_tokens();

            string url = "/bot/list";
            if (account_jid != "") {
                url += "?account=%s".printf(GLib.Uri.escape_string(account_jid, null, false));
            }
            var msg = create_api_message("GET", url);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            if (msg.status_code != 200) {
                show_error(_("API returned status %u").printf(msg.status_code));
                return;
            }

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();

            if (!root.has_member("bots")) {
                show_error(_("Invalid response from API"));
                return;
            }

            var bots = root.get_array_member("bots");

            // Clear existing rows (use get_row_at_index to avoid removing GtkListBox internal widgets)
            Gtk.ListBoxRow? old_row;
            while ((old_row = bot_list.get_row_at_index(0)) != null) {
                bot_list.remove(old_row);
            }

            if (bots.get_length() == 0) {
                // Still show the list page so the per-account toggle remains visible.
                append_configured_cloud_bot_rows();
                api_status_label.label = _("Botmother API: %s").printf(get_api_base_url());
                main_stack.visible_child_name = "list";
                return;
            }

            for (uint i = 0; i < bots.get_length(); i++) {
                var bot = bots.get_object_element(i);
                int64 bot_id = bot.get_int_member("id");
                string name = bot.get_string_member("name");
                string mode = bot.has_member("mode") ? bot.get_string_member("mode") : "personal";
                string purpose = bot.has_member("purpose") ? bot.get_string_member("purpose") : "advanced";
                string status = bot.has_member("status") ? bot.get_string_member("status") : "active";
                string permissions = bot.has_member("permissions") ? bot.get_string_member("permissions") : "all";
                string target_mode = bot.has_member("target_mode") ? bot.get_string_member("target_mode") : "";
                string target_list = bot.has_member("target_list") ? bot.get_string_member("target_list") : "";
                if (target_list == "" && bot.has_member("allowed_targets")) target_list = bot.get_string_member("allowed_targets");
                if (target_mode == "") target_mode = target_list == "" ? "all" : "allow";
                bool webhook_enabled = bot.has_member("webhook_enabled") && bot.get_boolean_member("webhook_enabled");
                string webhook_url = bot.has_member("webhook_url") ? bot.get_string_member("webhook_url") : "";
                bool avatar_configured = bot.has_member("avatar_configured") && bot.get_boolean_member("avatar_configured");
                string avatar_type = bot.has_member("avatar_type") ? bot.get_string_member("avatar_type") : "";
                bool telegram_enabled = false;
                bool telegram_configured = false;
                string telegram_chat_id = "";
                string telegram_mode = "bridge";
                if (bot.has_member("telegram") && bot.get_member("telegram").get_node_type() == Json.NodeType.OBJECT) {
                    var telegram = bot.get_object_member("telegram");
                    telegram_enabled = telegram.has_member("enabled") && telegram.get_boolean_member("enabled");
                    telegram_configured = telegram.has_member("configured") && telegram.get_boolean_member("configured");
                    telegram_chat_id = telegram.has_member("chat_id") ? telegram.get_string_member("chat_id") : "";
                    telegram_mode = telegram.has_member("mode") ? telegram.get_string_member("mode") : "bridge";
                }
                bool ai_enabled = false;
                bool ai_configured = false;
                string ai_provider = "ollama";
                string ai_model = "";
                string ai_system_prompt = "";
                string muc_owner_notify = "off";
                string muc_ai_mode = "mention_only";
                if (bot.has_member("ai") && bot.get_member("ai").get_node_type() == Json.NodeType.OBJECT) {
                    var ai = bot.get_object_member("ai");
                    ai_enabled = ai.has_member("enabled") && ai.get_boolean_member("enabled");
                    ai_configured = ai.has_member("configured") && ai.get_boolean_member("configured");
                    ai_provider = ai.has_member("provider") && ai.get_string_member("provider") != "" ? ai.get_string_member("provider") : "ollama";
                    ai_model = ai.has_member("model") ? ai.get_string_member("model") : "";
                    ai_system_prompt = ai.has_member("system_prompt") ? ai.get_string_member("system_prompt") : "";
                    muc_owner_notify = ai.has_member("muc_owner_notify") ? ai.get_string_member("muc_owner_notify") : "off";
                    muc_ai_mode = ai.has_member("muc_ai_mode") ? ai.get_string_member("muc_ai_mode") : "mention_only";
                }
                string muc_rooms = bot.has_member("muc_rooms") ? bot.get_string_member("muc_rooms") : "";
                Json.Array? muc_rooms_list = null;
                if (bot.has_member("muc_rooms_list") && bot.get_member("muc_rooms_list").get_node_type() == Json.NodeType.ARRAY) {
                    muc_rooms_list = bot.get_array_member("muc_rooms_list");
                }
                string? bot_jid = bot.has_member("jid") ? bot.get_string_member("jid") : null;
                string status_icon = get_bot_status_icon(status);
                string status_label = get_bot_status_label(status);

                var bot_group = new Adw.ExpanderRow();
                bot_group.title = "%s %s".printf(status_icon, name);
                if (bot_jid != null && bot_jid != "") {
                    bot_group.subtitle = "ID: %lld \u00b7 %s \u00b7 %s \u00b7 %s \u00b7 %s".printf(bot_id, mode, purpose_label(purpose), status_label, bot_jid);
                } else {
                    bot_group.subtitle = "ID: %lld \u00b7 %s \u00b7 %s \u00b7 %s".printf(bot_id, mode, purpose_label(purpose), status_label);
                }

                bool is_active = (status == "active");
                bool is_disabled = (status == "disabled");
                int64 status_bot_id = bot_id;

                var runtime_btn = new Gtk.Button.from_icon_name(
                    is_active ? "media-playback-pause-symbolic" : "media-playback-start-symbolic");
                runtime_btn.valign = Gtk.Align.CENTER;
                runtime_btn.tooltip_text = is_active ? _("Pause") : (is_disabled ? _("Activate") : _("Resume"));
                runtime_btn.add_css_class("flat");
                if (!is_active) runtime_btn.add_css_class("success");
                runtime_btn.clicked.connect(() => {
                    start_set_bot_status(status_bot_id, is_active ? "paused" : "active");
                });
                bot_group.add_suffix(runtime_btn);

                if (!is_disabled) {
                    var deactivate_btn = new Gtk.Button.from_icon_name("process-stop-symbolic");
                    deactivate_btn.valign = Gtk.Align.CENTER;
                    deactivate_btn.tooltip_text = _("Deactivate");
                    deactivate_btn.add_css_class("flat");
                    deactivate_btn.clicked.connect(() => {
                        start_set_bot_status(status_bot_id, "disabled");
                    });
                    bot_group.add_suffix(deactivate_btn);
                }

                var delete_btn = new Gtk.Button.from_icon_name("user-trash-symbolic");
                delete_btn.valign = Gtk.Align.CENTER;
                delete_btn.tooltip_text = _("Delete Botmother");
                delete_btn.add_css_class("flat");
                delete_btn.add_css_class("error");
                int64 del_id = bot_id;
                string del_name = name;
                delete_btn.clicked.connect(() => {
                    start_confirm_delete(del_id, del_name);
                });
                bot_group.add_suffix(delete_btn);

                var bot_details = new Gtk.ListBox();
                bot_details.selection_mode = Gtk.SelectionMode.NONE;

                append_avatar_row(bot_details, bot_id, avatar_configured, avatar_type);
                if (purpose == "ai" || purpose == "advanced") {
                    append_ai_row(bot_details, bot_id, ai_configured, ai_enabled, ai_provider, ai_model, ai_system_prompt, muc_owner_notify, muc_ai_mode);
                }
                if (purpose == "telegram" || purpose == "advanced") {
                    append_telegram_row(bot_details, bot_id, telegram_configured, telegram_enabled, telegram_chat_id, telegram_mode);
                }
                if (purpose == "webhook" || purpose == "ai" || purpose == "telegram" || purpose == "advanced") {
                    append_webhook_row(bot_details, bot_id, webhook_enabled, webhook_url);
                }
                if (purpose == "ai" || purpose == "webhook" || purpose == "telegram" || purpose == "advanced") {
                    append_targets_row(bot_details, bot_id, target_mode, target_list);
                }
                if (mode == "dedicated" && (purpose == "ai" || purpose == "advanced")) {
                    append_muc_room_row(bot_details, bot_id, name, muc_rooms, muc_rooms_list);
                    append_ai_group_behavior_row(bot_details, bot_id, muc_owner_notify, muc_ai_mode);
                }
                if (purpose == "ai" || purpose == "advanced") {
                    append_ai_console_row(bot_details, bot_id, ai_configured, ai_enabled);
                }
                if (purpose == "webhook" || purpose == "advanced") {
                    append_permissions_row(bot_details, bot_id, permissions);
                }

                int64 token_bot_id = bot_id;
                var token_row = new Adw.ActionRow();
                token_row.title = _("Local API token");
                token_row.subtitle = _("Generate a local Botmother API token. This is not a CloudBot management token.");
                token_row.add_css_class("dim-label");
                token_row.activatable = false;
                token_row.selectable = false;

                var gen_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
                gen_btn.valign = Gtk.Align.CENTER;
                gen_btn.tooltip_text = _("Generate token");
                gen_btn.add_css_class("flat");
                gen_btn.add_css_class("suggested-action");
                gen_btn.clicked.connect(() => {
                    start_regenerate_token(token_bot_id);
                });
                token_row.add_suffix(gen_btn);

                var revoke_btn = new Gtk.Button.from_icon_name("action-unavailable-symbolic");
                revoke_btn.valign = Gtk.Align.CENTER;
                revoke_btn.tooltip_text = _("Revoke token");
                revoke_btn.add_css_class("flat");
                revoke_btn.add_css_class("error");
                revoke_btn.clicked.connect(() => {
                    start_confirm_revoke(token_bot_id, name);
                });
                token_row.add_suffix(revoke_btn);

                bot_details.append(token_row);
                if (purpose == "webhook" || purpose == "advanced") {
                    append_console_row(bot_details, bot_id);
                }
                bot_group.add_row(bot_details);
                bot_list.append(bot_group);
            }

            append_configured_cloud_bot_rows();

            api_status_label.label = _("Botmother API: %s").printf(get_api_base_url());
            main_stack.visible_child_name = "list";

        } catch (Error e) {
            show_error(e.message);
        }
    }

    private async void load_persisted_cloud_tokens() {
        if (account_jid == "") return;

        try {
            var msg = create_api_message("GET", "/bot/cloud/tokens?account=%s".printf(
                GLib.Uri.escape_string(account_jid, null, false)));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) return;

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            Json.Object data = root;
            if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                data = root.get_object_member("result");
            }
            if (!data.has_member("tokens") || data.get_member("tokens").get_node_type() != Json.NodeType.ARRAY) return;

            cloud_management_tokens.clear();
            var tokens = data.get_array_member("tokens");
            for (uint i = 0; i < tokens.get_length(); i++) {
                string token = tokens.get_string_element(i).strip();
                if (token != "" && !cloud_management_tokens.contains(token)) {
                    cloud_management_tokens.add(token);
                }
            }
        } catch (Error e) {
            warning("BotManager: Failed to load CloudBot tokens: %s", e.message);
        }
    }

    private async bool save_cloud_token(string token) {
        if (account_jid == "" || token.strip() == "") return false;

        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("account");
            builder.add_string_value(account_jid);
            builder.set_member_name("token");
            builder.add_string_value(token.strip());
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/cloud/tokens", json_body, out response);
            if (msg.status_code != 200) {
                string detail = format_api_failure(_("Saving CloudBot"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                return false;
            }
            return true;
        } catch (Error e) {
            warning("BotManager: CloudBot token save error: %s", e.message);
            present_action_error(action_error_message(_("Saving CloudBot"), e.message));
            return false;
        }
    }

    private async void remove_cloud_token(string token) {
        if (account_jid == "" || token.strip() == "") return;

        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("account");
            builder.add_string_value(account_jid);
            builder.set_member_name("token");
            builder.add_string_value(token.strip());
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            var msg = create_api_message("DELETE", "/bot/cloud/tokens");
            msg.set_request_body_from_bytes("application/json", new Bytes(json_body.data));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                string detail = format_api_failure(_("Removing CloudBot"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: CloudBot token remove error: %s", e.message);
            present_action_error(action_error_message(_("Removing CloudBot"), e.message));
        }
    }

    private void append_configured_cloud_bot_rows() {
        foreach (string token in cloud_management_tokens) {
            append_cloud_bot_row(token);
        }
    }

    private void append_cloud_bot_row(string token) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("DinoX-Client CloudBot");
        expander.subtitle = _("Manage a hosted CloudBot loaded from cloud.dinox.im.");

        var token_row = new Adw.PasswordEntryRow();
        token_row.title = _("Management token");
        token_row.text = token;
        token_row.show_apply_button = false;
        expander.add_row(token_row);

        var status_row = new Adw.ActionRow();
        status_row.title = _("Cloud bot status");
        status_row.subtitle = _("Paste a management token and load the bot.");

        var usage_row = new Adw.ActionRow();
        usage_row.title = _("Usage");
        usage_row.subtitle = _("Load the cloud bot to show usage.");

        var diagnostics_row = new Adw.ActionRow();
        diagnostics_row.title = _("Recent diagnostics");
        diagnostics_row.subtitle = _("Load the cloud bot to show diagnostics.");

        var load_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        load_btn.valign = Gtk.Align.CENTER;
        load_btn.tooltip_text = _("Load");
        load_btn.add_css_class("flat");
        load_btn.add_css_class("suggested-action");
        status_row.add_suffix(load_btn);

        var activate_btn = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        activate_btn.valign = Gtk.Align.CENTER;
        activate_btn.tooltip_text = _("Activate");
        activate_btn.add_css_class("flat");
        activate_btn.sensitive = false;
        status_row.add_suffix(activate_btn);

        var pause_btn = new Gtk.Button.from_icon_name("media-playback-pause-symbolic");
        pause_btn.valign = Gtk.Align.CENTER;
        pause_btn.tooltip_text = _("Pause");
        pause_btn.add_css_class("flat");
        pause_btn.sensitive = false;
        status_row.add_suffix(pause_btn);

        var rotate_token_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        rotate_token_btn.valign = Gtk.Align.CENTER;
        rotate_token_btn.tooltip_text = _("Rotate token");
        rotate_token_btn.add_css_class("flat");
        rotate_token_btn.sensitive = false;
        status_row.add_suffix(rotate_token_btn);

        var event_token_btn = new Gtk.Button.from_icon_name("network-transmit-symbolic");
        event_token_btn.valign = Gtk.Align.CENTER;
        event_token_btn.tooltip_text = _("Create event token");
        event_token_btn.add_css_class("flat");
        event_token_btn.sensitive = false;
        status_row.add_suffix(event_token_btn);

        var delete_btn = new Gtk.Button.from_icon_name("edit-delete-symbolic");
        delete_btn.valign = Gtk.Align.CENTER;
        delete_btn.tooltip_text = _("Delete cloud bot");
        delete_btn.add_css_class("flat");
        delete_btn.add_css_class("error");
        delete_btn.sensitive = false;
        status_row.add_suffix(delete_btn);

        var forget_btn = new Gtk.Button.from_icon_name("edit-clear-symbolic");
        forget_btn.valign = Gtk.Align.CENTER;
        forget_btn.tooltip_text = _("Forget token");
        forget_btn.add_css_class("flat");
        status_row.add_suffix(forget_btn);

        load_btn.clicked.connect(() => {
            start_cloud_load_bot(token_row.text.strip(), status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        activate_btn.clicked.connect(() => {
            start_cloud_set_bot_status(token_row.text.strip(), "active", status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        pause_btn.clicked.connect(() => {
            start_cloud_set_bot_status(token_row.text.strip(), "paused", status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        rotate_token_btn.clicked.connect(() => {
            start_cloud_confirm_rotate_token(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        event_token_btn.clicked.connect(() => {
            start_cloud_confirm_event_token(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        delete_btn.clicked.connect(() => {
            start_cloud_confirm_deprovision(token_row, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        });
        forget_btn.clicked.connect(() => {
            string current_token = token_row.text.strip();
            token_row.text = "";
            cloud_management_tokens.remove(token);
            if (current_token != "") {
                cloud_management_tokens.remove(current_token);
                start_remove_cloud_token(current_token);
            }
            status_row.subtitle = _("Paste a management token and load the bot.");
            usage_row.subtitle = _("Load the cloud bot to show usage.");
            diagnostics_row.subtitle = _("Load the cloud bot to show diagnostics.");
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
            start_load_bots();
        });

        expander.add_row(status_row);
        expander.add_row(usage_row);
        expander.add_row(diagnostics_row);
        bot_list.append(expander);
        start_cloud_load_bot(token, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
    }

    private async void cloud_load_bot(string token, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        if (token == "") {
            status_row.subtitle = _("Enter a management token.");
            return;
        }
        set_cloud_buttons_busy(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, true);
        status_row.subtitle = _("Loading cloud bot...");
        try {
            var msg = create_cloud_api_message("GET", "/api/v1/bot/me", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                status_row.subtitle = format_cloud_api_failure(_("Loading cloud bot"), msg.status_code, response);
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }
            CloudBotMetadata metadata = parse_cloud_bot_metadata(response);
            if (!cloud_metadata_matches_account(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn)) return;
            update_cloud_status(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
            prepare_cloud_bot_contact(metadata);
            yield cloud_update_runtime_status(token, status_row);
            yield cloud_update_usage(token, usage_row);
            yield cloud_update_diagnostics(token, diagnostics_row);
        } catch (Error e) {
            status_row.subtitle = action_error_message(_("Loading cloud bot"), e.message);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
        }
    }

    private async void cloud_set_bot_status(string token, string status, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        if (token == "") {
            status_row.subtitle = _("Enter a management token.");
            return;
        }
        set_cloud_buttons_busy(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, true);
        status_row.subtitle = status == "paused" ? _("Pausing cloud bot...") : _("Activating cloud bot...");
        try {
            var msg = create_cloud_api_message("POST", "/api/v1/bot/status", token);
            string body = "{\"status\":\"%s\"}".printf(status);
            msg.set_request_body_from_bytes("application/json", new Bytes(body.data));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                status_row.subtitle = format_cloud_api_failure(_("Changing cloud bot status"), msg.status_code, response);
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }
            CloudBotMetadata metadata = parse_cloud_bot_metadata(response);
            if (!cloud_metadata_matches_account(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn)) return;
            update_cloud_status(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
            prepare_cloud_bot_contact(metadata);
            yield cloud_update_runtime_status(token, status_row);
            yield cloud_update_usage(token, usage_row);
            yield cloud_update_diagnostics(token, diagnostics_row);
        } catch (Error e) {
            status_row.subtitle = action_error_message(_("Changing cloud bot status"), e.message);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
        }
    }

    private async void cloud_confirm_rotate_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        var alert = new Adw.AlertDialog(
            _("Rotate CloudBot Token?"),
            _("Rotate the management token for this cloud bot? Existing active tokens will stop working.")
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("rotate", _("Rotate"));
        alert.set_response_appearance("rotate", Adw.ResponseAppearance.DESTRUCTIVE);
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response == "rotate") {
            yield cloud_rotate_token(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        }
    }

    private async void cloud_rotate_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        string token = token_row.text.strip();
        if (token == "") {
            status_row.subtitle = _("Enter a management token.");
            return;
        }
        set_cloud_buttons_busy(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, true);
        status_row.subtitle = _("Rotating cloud bot token...");
        try {
            var msg = create_cloud_api_message("POST", "/api/v1/bot/token/rotate", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                status_row.subtitle = format_cloud_api_failure(_("Rotating cloud bot token"), msg.status_code, response);
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("token") || root.get_member("token").get_node_type() != Json.NodeType.VALUE) {
                status_row.subtitle = _("Invalid response from cloud bot service.");
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }

            string new_token = root.get_string_member("token");
            if (new_token == "") {
                status_row.subtitle = _("Invalid response from cloud bot service.");
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }
            cloud_management_tokens.remove(token);
            start_remove_cloud_token(token);
            if (!cloud_management_tokens.contains(new_token)) cloud_management_tokens.add(new_token);
            start_save_cloud_token(new_token);
            token_row.text = new_token;
            copy_to_clipboard(new_token);
            present_new_cloud_token_dialog(new_token);
            CloudBotMetadata metadata = parse_cloud_bot_metadata(response);
            if (!cloud_metadata_matches_account(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn)) return;
            update_cloud_status(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
            prepare_cloud_bot_contact(metadata);
            yield cloud_update_runtime_status(new_token, status_row);
            yield cloud_update_usage(new_token, usage_row);
            yield cloud_update_diagnostics(new_token, diagnostics_row);
        } catch (Error e) {
            status_row.subtitle = action_error_message(_("Rotating cloud bot token"), e.message);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
        }
    }

    private async void cloud_confirm_event_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        var alert = new Adw.AlertDialog(
            _("Create CloudBot Event Token?"),
            _("Create a scoped event token for this cloud bot? Existing event tokens will stop working, but the management token stays valid.")
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("create", _("Create"));
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response == "create") {
            yield cloud_create_event_token(token_row, status_row, usage_row, diagnostics_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        }
    }

    private async void cloud_create_event_token(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Adw.ActionRow usage_row, Adw.ActionRow diagnostics_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        string token = token_row.text.strip();
        if (token == "") {
            status_row.subtitle = _("Enter a management token.");
            return;
        }
        set_cloud_buttons_busy(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, true);
        status_row.subtitle = _("Creating cloud bot event token...");
        try {
            var msg = create_cloud_api_message("POST", "/api/v1/bot/events/token/rotate", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                status_row.subtitle = format_cloud_api_failure(_("Creating cloud bot event token"), msg.status_code, response);
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("token") || root.get_member("token").get_node_type() != Json.NodeType.VALUE) {
                status_row.subtitle = _("Invalid response from cloud bot service.");
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }

            string event_token = root.get_string_member("token");
            if (event_token == "") {
                status_row.subtitle = _("Invalid response from cloud bot service.");
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }
            copy_to_clipboard(event_token);
            present_new_cloud_event_token_dialog(event_token);
            CloudBotMetadata metadata = parse_cloud_bot_metadata(response);
            if (!cloud_metadata_matches_account(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn)) return;
            update_cloud_status(metadata, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
            prepare_cloud_bot_contact(metadata);
            status_row.subtitle = "%s · %s".printf(status_row.subtitle, _("Event token created"));
            yield cloud_update_runtime_status(token, status_row);
            yield cloud_update_usage(token, usage_row);
            yield cloud_update_diagnostics(token, diagnostics_row);
        } catch (Error e) {
            status_row.subtitle = action_error_message(_("Creating cloud bot event token"), e.message);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
        }
    }

    private async void cloud_confirm_deprovision(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        var alert = new Adw.AlertDialog(
            _("Delete CloudBot?"),
            _("Delete this cloud bot and unregister its XMPP account? This cannot be undone.")
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("delete", _("Delete"));
        alert.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response == "delete") {
            yield cloud_deprovision(token_row, status_row, activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn);
        }
    }

    private async void cloud_deprovision(Adw.PasswordEntryRow token_row, Adw.ActionRow status_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        string token = token_row.text.strip();
        if (token == "") {
            status_row.subtitle = _("Enter a management token.");
            return;
        }
        set_cloud_buttons_busy(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, true);
        status_row.subtitle = _("Deleting cloud bot...");
        try {
            var msg = create_cloud_api_message("POST", "/api/v1/bot/deprovision", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                status_row.subtitle = format_cloud_api_failure(_("Deleting cloud bot"), msg.status_code, response);
                set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
                return;
            }
            token_row.text = "";
            cloud_management_tokens.remove(token);
            start_remove_cloud_token(token);
            status_row.subtitle = _("Cloud bot deleted.");
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
            start_load_bots();
        } catch (Error e) {
            status_row.subtitle = action_error_message(_("Deleting cloud bot"), e.message);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
        }
    }

    private async void cloud_update_runtime_status(string token, Adw.ActionRow status_row) {
        try {
            var msg = create_cloud_api_message("GET", "/api/v1/bot/runtime", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) return;

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("runtime") || root.get_member("runtime").get_node_type() != Json.NodeType.OBJECT) return;

            var runtime = root.get_object_member("runtime");
            bool runtime_enabled = runtime.has_member("runtime_enabled") && runtime.get_boolean_member("runtime_enabled");
            bool connected = runtime.has_member("connected") && runtime.get_boolean_member("connected");
            bool omemo_ready = runtime.has_member("omemo_ready") && runtime.get_boolean_member("omemo_ready");
            string omemo_status = runtime.has_member("omemo_status") ? runtime.get_string_member("omemo_status") : "";
            string label = !runtime_enabled ? _("Runtime disabled") : (connected ? _("Runtime connected") : _("Runtime disconnected"));
            if (runtime_enabled && connected) {
                label = "%s · %s".printf(label, omemo_ready ? _("OMEMO ready") : _("OMEMO %s").printf(get_cloud_omemo_status_label(omemo_status)));
            }
            status_row.subtitle = "%s · %s".printf(status_row.subtitle, label);
        } catch (Error e) {
            debug("CloudBot runtime status failed: %s", e.message);
        }
    }

    private async void cloud_update_usage(string token, Adw.ActionRow usage_row) {
        usage_row.subtitle = _("Loading usage...");
        try {
            var msg = create_cloud_api_message("GET", "/api/v1/bot/usage", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                usage_row.subtitle = _("Usage unavailable.");
                return;
            }

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("usage") || root.get_member("usage").get_node_type() != Json.NodeType.OBJECT) {
                usage_row.subtitle = _("Usage unavailable.");
                return;
            }

            var usage = root.get_object_member("usage");
            string month = usage.has_member("month_key") ? usage.get_string_member("month_key") : "";
            int64 used = usage.has_member("ai_tokens_used") ? usage.get_int_member("ai_tokens_used") : 0;
            int64 budget = usage.has_member("monthly_token_budget") ? usage.get_int_member("monthly_token_budget") : 0;
            string label = month != "" ? _("AI tokens this month (%s)").printf(month) : _("AI tokens this month");
            usage_row.subtitle = budget > 0
                ? "%s: %s / %s".printf(label, used.to_string(), budget.to_string())
                : "%s: %s / %s".printf(label, used.to_string(), _("unlimited"));
        } catch (Error e) {
            debug("CloudBot usage failed: %s", e.message);
            usage_row.subtitle = _("Usage unavailable.");
        }
    }

    private async void cloud_update_diagnostics(string token, Adw.ActionRow diagnostics_row) {
        diagnostics_row.subtitle = _("Loading diagnostics...");
        try {
            var msg = create_cloud_api_message("GET", "/api/v1/bot/audit?limit=1", token);
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                diagnostics_row.subtitle = _("Diagnostics unavailable.");
                return;
            }

            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("entries") || root.get_member("entries").get_node_type() != Json.NodeType.ARRAY) {
                diagnostics_row.subtitle = _("Diagnostics unavailable.");
                return;
            }

            Json.Array entries = root.get_array_member("entries");
            if (entries.get_length() == 0) {
                diagnostics_row.subtitle = _("No diagnostic events yet.");
                return;
            }

            var entry = entries.get_object_element(0);
            string action = entry.has_member("action") ? entry.get_string_member("action") : _("event");
            string metadata = entry.has_member("metadata") ? entry.get_string_member("metadata") : "";
            diagnostics_row.subtitle = metadata != "" ? "%s · %s".printf(action, metadata) : action;
        } catch (Error e) {
            debug("CloudBot diagnostics failed: %s", e.message);
            diagnostics_row.subtitle = _("Diagnostics unavailable.");
        }
    }

    private string get_cloud_omemo_status_label(string status) {
        switch (status.strip().ascii_down()) {
            case "ready":
                return _("ready");
            case "not_configured":
                return _("not configured");
            case "publish_failed":
                return _("publish failed");
            case "disconnected":
                return _("disconnected");
            default:
                return status.strip() != "" ? status.strip() : _("unknown");
        }
    }

    private Soup.Message create_cloud_api_message(string method, string path, string token) {
        var msg = new Soup.Message(method, "%s%s".printf(CLOUD_BOT_BASE_URL, path));
        msg.request_headers.append("Authorization", "Bearer %s".printf(token));
        return msg;
    }

    private CloudBotMetadata parse_cloud_bot_metadata(Bytes response) throws Error {
        var parser = new Json.Parser();
        Util.load_json_response(parser, response);
        var root = parser.get_root().get_object();
        if (!root.has_member("bot") || root.get_member("bot").get_node_type() != Json.NodeType.OBJECT) {
            throw new IOError.INVALID_DATA("CloudBot response does not contain bot metadata");
        }
        var bot = root.get_object_member("bot");
        string bot_jid = bot.has_member("bot_jid") ? bot.get_string_member("bot_jid") : "";
        string owner_jid = bot.has_member("owner_jid") ? bot.get_string_member("owner_jid") : "";
        string display_name = bot.has_member("display_name") ? bot.get_string_member("display_name") : "";
        string status = bot.has_member("status") ? bot.get_string_member("status") : "";
        if (bot_jid == "" || owner_jid == "") {
            throw new IOError.INVALID_DATA("CloudBot response is missing bot_jid or owner_jid");
        }
        return new CloudBotMetadata(bot_jid, owner_jid, display_name, status);
    }

    private bool cloud_metadata_matches_account(CloudBotMetadata metadata, Adw.ActionRow status_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        if (account_jid != "" && metadata.owner_jid != account_jid) {
            status_row.subtitle = _("This CloudBot belongs to %s, not to %s.").printf(metadata.owner_jid, account_jid);
            set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, "");
            return false;
        }
        return true;
    }

    private void update_cloud_status(CloudBotMetadata metadata, Adw.ActionRow status_row, Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn) {
        status_row.subtitle = _("Bot %s · owner %s · %s").printf(metadata.bot_jid, metadata.owner_jid, get_bot_status_label(metadata.status));
        set_cloud_status_buttons(activate_btn, pause_btn, rotate_token_btn, event_token_btn, delete_btn, metadata.status);
    }

    private void prepare_cloud_bot_contact(CloudBotMetadata metadata) {
        if (account_jid == "" || metadata.bot_jid == "") return;

        var app = Dino.Application.get_default();
        if (app == null) return;

        Account? target_account = get_dialog_account();
        if (target_account == null) return;

        try {
            Xmpp.Jid bot_jid = new Xmpp.Jid(metadata.bot_jid);
            bool changed = false;

            var presence_mgr = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            presence_mgr.suppress_subscription_notification(target_account, bot_jid);

            if (presence_mgr.exists_subscription_request(target_account, bot_jid)) {
                presence_mgr.approve_subscription(target_account, bot_jid);
                changed = true;
            }

            string label = metadata.display_name != "" ? metadata.display_name : metadata.bot_jid;
            var roster_mgr = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            var item = roster_mgr.get_roster_item(target_account, bot_jid);
            if (item == null) {
                roster_mgr.add_jid(target_account, bot_jid, label);
                presence_mgr.request_subscription(target_account, bot_jid);
                changed = true;
            } else if (item.name == null || item.name == "" || item.name == metadata.bot_jid) {
                roster_mgr.set_jid_handle(target_account, bot_jid, label);
                changed = true;
            }

            if (item != null &&
                    item.subscription != Roster.Item.SUBSCRIPTION_TO &&
                    item.subscription != Roster.Item.SUBSCRIPTION_BOTH &&
                    !item.subscription_requested) {
                presence_mgr.request_subscription(target_account, bot_jid);
                changed = true;
            }

            if (changed) {
                message("BotManager: Prepared CloudBot contact %s for owner %s", metadata.bot_jid, account_jid);
            } else {
                debug("BotManager: CloudBot contact %s already prepared for owner %s", metadata.bot_jid, account_jid);
            }
        } catch (Error e) {
            warning("BotManager: Could not prepare CloudBot contact %s: %s", metadata.bot_jid, e.message);
        }
    }

    private async void add_cloud_token_from_create(string token) {
        string trimmed = token.strip();
        if (trimmed == "") return;
        if (!cloud_management_tokens.contains(trimmed)) {
            cloud_management_tokens.add(trimmed);
        }
        if (!(yield save_cloud_token(trimmed))) {
            present_action_error(_("CloudBot loaded for this session, but the token could not be saved locally."));
        }
        yield load_bots();
    }

    private void set_cloud_buttons_busy(Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn, bool busy) {
        if (busy) {
            activate_btn.sensitive = false;
            pause_btn.sensitive = false;
            rotate_token_btn.sensitive = false;
            event_token_btn.sensitive = false;
            delete_btn.sensitive = false;
        }
    }

    private void set_cloud_status_buttons(Gtk.Button activate_btn, Gtk.Button pause_btn, Gtk.Button rotate_token_btn, Gtk.Button event_token_btn, Gtk.Button delete_btn, string status) {
        activate_btn.sensitive = status != "" && status != "active";
        pause_btn.sensitive = status == "active";
        rotate_token_btn.sensitive = status != "";
        event_token_btn.sensitive = status != "";
        delete_btn.sensitive = status != "";
    }

    private string format_cloud_api_failure(string action, uint status_code, Bytes response) {
        string detail = parse_api_message(response);
        if (detail != "") return action_error_message(action, detail);
        return _("%s failed with status %u").printf(action, status_code);
    }

    private void append_permissions_row(Gtk.ListBox list, int64 bot_id, string permissions) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("API Permissions");
        expander.subtitle = format_permissions_summary(permissions);

        var switches = new Gee.HashMap<string, Adw.SwitchRow>();
        foreach (string key in PERMISSION_KEYS) {
            var perm_row = new Adw.SwitchRow();
            perm_row.title = permission_title(key);
            perm_row.subtitle = permission_description(key);
            perm_row.active = permission_string_has(permissions, key);
            switches[key] = perm_row;
            expander.add_row(perm_row);
        }

        bool updating_permissions = false;
        foreach (string key in PERMISSION_KEYS) {
            Adw.SwitchRow row = switches[key];
            row.notify["active"].connect(() => {
                if (updating_permissions) return;

                updating_permissions = true;
                if (key == "all" && row.active) {
                    foreach (string other_key in PERMISSION_KEYS) {
                        if (other_key != "all") switches[other_key].active = false;
                    }
                } else if (key != "all" && row.active) {
                    switches["all"].active = false;
                } else if (!switches["all"].active && !has_selected_specific_permission(switches)) {
                    switches["all"].active = true;
                }
                string updated = collect_permissions(switches);
                expander.subtitle = format_permissions_summary(updated);
                updating_permissions = false;
                start_save_permissions(bot_id, updated);
            });
        }

        list.append(expander);
    }

    private void append_avatar_row(Gtk.ListBox list, int64 bot_id, bool configured, string avatar_type) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Avatar");
        expander.subtitle = configured ? _("Configured") : _("Not set");

        var status_row = new Adw.ActionRow();
        status_row.title = _("Bot avatar");
        status_row.subtitle = configured && avatar_type != "" ? avatar_type : _("Choose a square image. DinoX scales it before upload.");
        status_row.activatable = false;
        status_row.selectable = false;

        var choose_btn = new Gtk.Button.with_label(configured ? _("Change") : _("Choose"));
        choose_btn.valign = Gtk.Align.CENTER;
        choose_btn.add_css_class("suggested-action");
        status_row.add_suffix(choose_btn);

        var remove_btn = new Gtk.Button.with_label(_("Remove"));
        remove_btn.valign = Gtk.Align.CENTER;
        remove_btn.add_css_class("destructive-action");
        remove_btn.sensitive = configured;
        status_row.add_suffix(remove_btn);

        expander.add_row(status_row);

        choose_btn.clicked.connect(() => {
            start_choose_bot_avatar(bot_id, expander, status_row, remove_btn);
        });
        remove_btn.clicked.connect(() => {
            start_remove_bot_avatar(bot_id, expander, status_row, remove_btn);
        });

        list.append(expander);
    }

    private void append_targets_row(Gtk.ListBox list, int64 bot_id, string target_mode, string target_list) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Target restrictions");
        expander.subtitle = format_targets_summary(target_mode, target_list);

        var mode_model = new Gtk.StringList(null);
        mode_model.append(_("Allow all targets"));
        mode_model.append(_("Allow only listed targets"));
        mode_model.append(_("Block listed targets"));

        var mode_row = new Adw.ComboRow();
        mode_row.title = _("Target mode");
        mode_row.model = mode_model;
        mode_row.selected = target_mode_to_index(target_mode);
        expander.add_row(mode_row);

        var add_target_row = new Adw.ActionRow();
        add_target_row.title = _("Add contact or group chat");
        add_target_row.subtitle = target_mode == "all" ? _("Choose allow or block mode first.") : _("Pick from this account's contacts and open chats.");
        add_target_row.activatable = false;
        add_target_row.selectable = false;

        var add_target_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
        add_target_btn.valign = Gtk.Align.CENTER;
        add_target_btn.tooltip_text = _("Add target");
        add_target_btn.add_css_class("flat");
        add_target_btn.sensitive = target_mode != "all";
        add_target_row.add_suffix(add_target_btn);
        expander.add_row(add_target_row);

        var targets_row = new Adw.EntryRow();
        targets_row.title = target_mode == "block" ? _("Blocked targets") : _("Allowed targets");
        targets_row.text = target_list;
        targets_row.show_apply_button = true;
        targets_row.input_purpose = Gtk.InputPurpose.EMAIL;
        targets_row.sensitive = target_mode != "all";
        expander.add_row(targets_row);

        var hint_row = new Adw.ActionRow();
        hint_row.title = _("Use comma-separated JIDs, @domain or domain:example.org");
        hint_row.subtitle = target_hint(target_mode);
        hint_row.activatable = false;
        hint_row.selectable = false;
        expander.add_row(hint_row);

        mode_row.notify["selected"].connect(() => {
            string updated_mode = target_mode_from_index(mode_row.selected);
            targets_row.sensitive = updated_mode != "all";
            targets_row.title = updated_mode == "block" ? _("Blocked targets") : _("Allowed targets");
            hint_row.subtitle = target_hint(updated_mode);
            add_target_btn.sensitive = updated_mode != "all";
            add_target_row.subtitle = updated_mode == "all" ? _("Choose allow or block mode first.") : _("Pick from this account's contacts and open chats.");
            expander.subtitle = format_targets_summary(updated_mode, targets_row.text);
            start_save_targets(bot_id, updated_mode, targets_row.text.strip());
        });

        targets_row.apply.connect(() => {
            string updated = targets_row.text.strip();
            string updated_mode = target_mode_from_index(mode_row.selected);
            expander.subtitle = format_targets_summary(updated_mode, updated);
            start_save_targets(bot_id, updated_mode, updated);
        });

        add_target_btn.clicked.connect(() => {
            present_target_picker(bot_id, mode_row, targets_row, expander);
        });

        list.append(expander);
    }

    private void append_ai_row(Gtk.ListBox list, int64 bot_id, bool configured, bool enabled, string provider, string model,
                               string system_prompt, string muc_owner_notify, string muc_ai_mode) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("AI Assistant");
        expander.subtitle = ai_summary(configured, enabled, provider, model);

        var provider_model = new Gtk.StringList(null);
        foreach (string key in BotProviderSelection.KEYS) {
            provider_model.append(ai_provider_label(key));
        }

        var provider_row = new Adw.ComboRow();
        provider_row.title = _("AI provider");
        provider_row.model = provider_model;
        provider_row.selected = ai_provider_to_index(provider);
        expander.add_row(provider_row);

        var key_row = new Adw.PasswordEntryRow();
        key_row.title = configured ? _("New API key") : _("API key");
        key_row.show_apply_button = false;
        expander.add_row(key_row);

        var model_preset_model = new Gtk.StringList(null);
        foreach (string label in ai_model_preset_labels()) {
            model_preset_model.append(label);
        }

        var model_preset_row = new Adw.ComboRow();
        model_preset_row.title = _("Model preset");
        model_preset_row.subtitle = _("Choose a known model or keep the manual field.");
        model_preset_row.model = model_preset_model;
        model_preset_row.selected = ai_model_preset_to_index(model);
        expander.add_row(model_preset_row);

        var model_row = new Adw.EntryRow();
        model_row.title = _("AI model (manual)");
        model_row.text = model;
        model_row.show_apply_button = false;
        expander.add_row(model_row);

        var system_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        system_box.margin_top = 12;
        system_box.margin_bottom = 12;
        system_box.margin_start = 12;
        system_box.margin_end = 12;

        var system_title = new Gtk.Label(_("System prompt"));
        system_title.halign = Gtk.Align.START;
        system_title.add_css_class("heading");
        system_box.append(system_title);

        var system_scrolled = new Gtk.ScrolledWindow();
        system_scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
        system_scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
        system_scrolled.min_content_height = 120;
        system_scrolled.max_content_height = 220;
        system_scrolled.add_css_class("card");

        var system_view = new Gtk.TextView();
        system_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
        system_view.accepts_tab = false;
        system_view.left_margin = 10;
        system_view.right_margin = 10;
        system_view.top_margin = 8;
        system_view.bottom_margin = 8;
        system_view.buffer.text = system_prompt;
        system_scrolled.child = system_view;
        system_box.append(system_scrolled);

        var system_actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        system_actions.halign = Gtk.Align.END;
        var save_behavior_btn = new Gtk.Button.with_label(_("Save"));
        save_behavior_btn.add_css_class("suggested-action");
        system_actions.append(save_behavior_btn);
        system_box.append(system_actions);

        expander.add_row(system_box);

        var actions_row = new Adw.ActionRow();
        actions_row.title = _("AI actions");
        actions_row.subtitle = configured ?
            _("Leave the key empty to keep the existing key.") :
            _("Ollama works without an API key.");
        actions_row.activatable = false;
        actions_row.selectable = false;

        var save_btn = new Gtk.Button.with_label(configured ? _("Update") : _("Set"));
        save_btn.valign = Gtk.Align.CENTER;
        save_btn.add_css_class("suggested-action");
        actions_row.add_suffix(save_btn);
        expander.add_row(actions_row);

        var active_row = new Adw.SwitchRow();
        active_row.title = _("AI active");
        active_row.subtitle = configured ?
            _("Forward incoming bot messages to the configured AI.") :
            _("Save provider and model first.");
        active_row.active = enabled;
        active_row.sensitive = configured;
        expander.add_row(active_row);

        save_btn.clicked.connect(() => {
            start_save_ai_setup(bot_id, ai_provider_from_index(provider_row.selected),
                key_row.text.strip(), model_row.text.strip(),
                expander, active_row, actions_row, save_btn);
        });

        model_preset_row.notify["selected"].connect(() => {
            string preset = ai_model_preset_from_index(model_preset_row.selected);
            if (preset != "") {
                model_row.text = preset;
            }
        });

        provider_row.notify["selected"].connect(() => {
            if (ai_provider_from_index(provider_row.selected) == "gemini" &&
                    (model_row.text.strip() == "" || ai_model_preset_to_index(model_row.text) > 0)) {
                model_row.text = "gemini-2.5-flash-lite";
                model_preset_row.selected = ai_model_preset_to_index(model_row.text);
            }
        });

        active_row.notify["active"].connect(() => {
            start_save_ai_enabled(bot_id, active_row.active, expander, active_row);
        });

        save_behavior_btn.clicked.connect(() => {
            start_save_ai_behavior(bot_id, get_text_view_text(system_view).strip(), null, null, actions_row);
        });

        list.append(expander);
    }

    private void append_ai_group_behavior_row(Gtk.ListBox list, int64 bot_id, string muc_owner_notify, string muc_ai_mode) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Group chat behavior");
        expander.subtitle = _("Controls notifications and when the bot may answer in rooms.");

        var muc_notify_model = new Gtk.StringList(null);
        muc_notify_model.append(_("Off"));
        muc_notify_model.append(_("Notify owner on mentions"));
        muc_notify_model.append(_("Notify owner when absent"));

        var muc_notify_row = new Adw.ComboRow();
        muc_notify_row.title = _("Owner notifications");
        muc_notify_row.subtitle = _("Send a direct message to the owner when the owner is mentioned in a group chat.");
        muc_notify_row.model = muc_notify_model;
        muc_notify_row.selected = muc_owner_notify_to_index(muc_owner_notify);
        expander.add_row(muc_notify_row);

        var muc_ai_model = new Gtk.StringList(null);
        muc_ai_model.append(_("Only when mentioned"));
        muc_ai_model.append(_("Support questions"));
        muc_ai_model.append(_("Active, but reserved"));

        var muc_ai_row = new Adw.ComboRow();
        muc_ai_row.title = _("Group chat replies");
        muc_ai_row.subtitle = _("Controls when this bot may answer in group chats.");
        muc_ai_row.model = muc_ai_model;
        muc_ai_row.selected = muc_ai_mode_to_index(muc_ai_mode);
        expander.add_row(muc_ai_row);

        var status_row = new Adw.ActionRow();
        status_row.title = _("Behavior status");
        status_row.subtitle = _("Changes are saved immediately.");
        status_row.activatable = false;
        status_row.selectable = false;
        expander.add_row(status_row);

        muc_notify_row.notify["selected"].connect(() => {
            start_save_ai_behavior(bot_id, null, muc_owner_notify_from_index(muc_notify_row.selected),
                muc_ai_mode_from_index(muc_ai_row.selected), status_row);
        });

        muc_ai_row.notify["selected"].connect(() => {
            start_save_ai_behavior(bot_id, null, muc_owner_notify_from_index(muc_notify_row.selected),
                muc_ai_mode_from_index(muc_ai_row.selected), status_row);
        });

        list.append(expander);
    }

    private void append_ai_console_row(Gtk.ListBox list, int64 bot_id, bool configured, bool enabled) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("AI test question");
        expander.subtitle = configured && enabled ?
            _("Ask the configured AI without sending anything to XMPP.") :
            _("Configure and enable AI first.");

        var question_row = new Adw.EntryRow();
        question_row.title = _("Question");
        question_row.show_apply_button = false;
        question_row.sensitive = configured && enabled;
        expander.add_row(question_row);

        var answer_row = new Adw.ActionRow();
        answer_row.title = _("AI response");
        answer_row.subtitle = _("No response yet.");
        answer_row.activatable = false;
        answer_row.selectable = true;
        expander.add_row(answer_row);

        var ask_row = new Adw.ActionRow();
        ask_row.title = _("Run test question");
        ask_row.subtitle = _("Local check for provider, key, model, and system prompt.");
        ask_row.activatable = false;
        ask_row.selectable = false;

        var ask_btn = new Gtk.Button.with_label(_("Ask"));
        ask_btn.valign = Gtk.Align.CENTER;
        ask_btn.add_css_class("suggested-action");
        ask_btn.sensitive = configured && enabled;
        ask_row.add_suffix(ask_btn);
        expander.add_row(ask_row);

        ask_btn.clicked.connect(() => {
            string question = question_row.text.strip();
            if (question == "") {
                answer_row.subtitle = _("Question is required.");
                return;
            }
            start_ask_ai_console(bot_id, question, answer_row, ask_btn);
        });

        question_row.apply.connect(() => {
            string question = question_row.text.strip();
            if (question == "") {
                answer_row.subtitle = _("Question is required.");
                return;
            }
            start_ask_ai_console(bot_id, question, answer_row, ask_btn);
        });

        list.append(expander);
    }

    private void append_telegram_row(Gtk.ListBox list, int64 bot_id, bool configured, bool enabled, string chat_id, string mode) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Telegram bridge");
        expander.subtitle = telegram_summary(configured, enabled, mode);

        var token_row = new Adw.PasswordEntryRow();
        token_row.title = configured ? _("New Telegram bot token") : _("Telegram bot token");
        token_row.show_apply_button = false;
        expander.add_row(token_row);

        var chat_id_row = new Adw.EntryRow();
        chat_id_row.title = _("Telegram chat ID");
        chat_id_row.text = chat_id;
        chat_id_row.show_apply_button = false;
        expander.add_row(chat_id_row);

        var mode_model = new Gtk.StringList(null);
        mode_model.append(_("Bridge"));
        mode_model.append(_("Forward only"));

        var mode_row = new Adw.ComboRow();
        mode_row.title = _("Telegram mode");
        mode_row.model = mode_model;
        mode_row.selected = telegram_mode_to_index(mode);
        expander.add_row(mode_row);

        var active_row = new Adw.SwitchRow();
        active_row.title = _("Telegram active");
        active_row.subtitle = configured ?
            _("Receive Telegram updates for this bot.") :
            _("Save a token and chat ID first.");
        active_row.active = enabled;
        active_row.sensitive = configured;
        expander.add_row(active_row);

        var actions_row = new Adw.ActionRow();
        actions_row.title = _("Telegram actions");
        actions_row.subtitle = configured ?
            _("Leave the token empty to keep the existing token.") :
            _("The token is stored securely and is never shown again.");
        actions_row.activatable = false;
        actions_row.selectable = false;

        var save_btn = new Gtk.Button.with_label(configured ? _("Update") : _("Set"));
        save_btn.valign = Gtk.Align.CENTER;
        save_btn.add_css_class("suggested-action");
        actions_row.add_suffix(save_btn);
        expander.add_row(actions_row);

        save_btn.clicked.connect(() => {
            start_save_telegram_setup(bot_id, token_row.text.strip(), chat_id_row.text.strip(),
                telegram_mode_from_index(mode_row.selected), configured, expander, active_row, actions_row, save_btn);
        });

        active_row.notify["active"].connect(() => {
            start_save_telegram_enabled(bot_id, active_row.active, expander, active_row);
        });

        list.append(expander);
    }

    private void append_webhook_row(Gtk.ListBox list, int64 bot_id, bool enabled, string webhook_url) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Local webhook integration");
        expander.subtitle = enabled ? _("Enabled") : _("Disabled");

        var url_row = new Adw.EntryRow();
        url_row.title = _("Local webhook URL");
        url_row.text = webhook_url;
        url_row.show_apply_button = true;
        url_row.input_purpose = Gtk.InputPurpose.URL;
        expander.add_row(url_row);

        var secret_row = new Adw.ActionRow();
        secret_row.title = _("Local webhook secret");
        secret_row.subtitle = enabled ?
            _("A secret is stored. Set the URL again to generate a new one.") :
            _("Set a URL to generate a webhook secret.");
        secret_row.activatable = false;
        secret_row.selectable = false;
        expander.add_row(secret_row);

        var actions_row = new Adw.ActionRow();
        actions_row.title = _("Webhook actions");
        actions_row.activatable = false;
        actions_row.selectable = false;

        var save_btn = new Gtk.Button.with_label(enabled ? _("Update") : _("Set"));
        save_btn.valign = Gtk.Align.CENTER;
        save_btn.add_css_class("suggested-action");
        actions_row.add_suffix(save_btn);

        var disable_btn = new Gtk.Button.with_label(_("Disable"));
        disable_btn.valign = Gtk.Align.CENTER;
        disable_btn.add_css_class("destructive-action");
        disable_btn.sensitive = enabled;
        actions_row.add_suffix(disable_btn);
        expander.add_row(actions_row);

        url_row.apply.connect(() => {
            start_save_webhook(bot_id, url_row.text.strip(), expander, secret_row, save_btn, disable_btn);
        });
        save_btn.clicked.connect(() => {
            start_save_webhook(bot_id, url_row.text.strip(), expander, secret_row, save_btn, disable_btn);
        });
        disable_btn.clicked.connect(() => {
            start_disable_webhook(bot_id, url_row, expander, secret_row, save_btn, disable_btn);
        });

        list.append(expander);
    }

    private void present_target_picker(int64 bot_id, Adw.ComboRow mode_row, Adw.EntryRow targets_row, Adw.ExpanderRow expander) {
        string mode = target_mode_from_index(mode_row.selected);
        if (mode == "all") return;

        var candidates = collect_target_candidates();
        var row_jids = new Gee.HashMap<Gtk.ListBoxRow, string>();

        var dialog = new Adw.Dialog();
        dialog.content_width = 460;
        dialog.content_height = 560;

        var toolbar_view = new Adw.ToolbarView();
        dialog.child = toolbar_view;

        var header = new Adw.HeaderBar();
        header.decoration_layout = ":";
        var title = new Adw.WindowTitle(_("Add target"), "");
        header.title_widget = title;

        var cancel_btn = new Gtk.Button.with_label(_("Cancel"));
        var add_btn = new Gtk.Button.with_label(_("Add"));
        add_btn.add_css_class("suggested-action");
        add_btn.sensitive = false;
        header.pack_start(cancel_btn);
        header.pack_end(add_btn);
        toolbar_view.add_top_bar(header);

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        var search = new Gtk.SearchEntry();
        search.placeholder_text = _("Search contacts and open chats");
        box.append(search);

        var scrolled = new Gtk.ScrolledWindow();
        scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scrolled.vexpand = true;

        var list = new Gtk.ListBox();
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        scrolled.child = list;
        box.append(scrolled);

        toolbar_view.content = box;

        populate_target_picker_list(list, row_jids, candidates, "");

        list.row_selected.connect((row) => {
            add_btn.sensitive = row != null && row_jids.has_key(row);
        });

        list.row_activated.connect((row) => {
            add_selected_target_from_picker(dialog, list, row_jids, targets_row, expander, bot_id, mode);
        });
        add_btn.clicked.connect(() => {
            add_selected_target_from_picker(dialog, list, row_jids, targets_row, expander, bot_id, mode);
        });
        cancel_btn.clicked.connect(() => {
            dialog.close();
        });
        search.search_changed.connect(() => {
            populate_target_picker_list(list, row_jids, candidates, search.text.strip());
            add_btn.sensitive = false;
        });

        dialog.present(this);
    }

    private void add_selected_target_from_picker(Adw.Dialog dialog, Gtk.ListBox list,
                                                 Gee.HashMap<Gtk.ListBoxRow, string> row_jids,
                                                 Adw.EntryRow targets_row, Adw.ExpanderRow expander,
                                                 int64 bot_id, string mode) {
        Gtk.ListBoxRow? row = list.get_selected_row();
        if (row == null || !row_jids.has_key(row)) return;
        string updated = add_target_to_list(targets_row.text, row_jids[row]);
        targets_row.text = updated;
        expander.subtitle = format_targets_summary(mode, updated);
        start_save_targets(bot_id, mode, updated);
        dialog.close();
    }

    private Gee.ArrayList<BotTargetCandidate> collect_target_candidates() {
        var candidates = new Gee.ArrayList<BotTargetCandidate>();
        var seen = new Gee.HashSet<string>();

        var app = Dino.Application.get_default();
        Account? account = get_dialog_account();
        if (app == null || account == null) return candidates;

        var conversation_manager = app.stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (conversation_manager != null) {
            foreach (Conversation conversation in conversation_manager.get_active_conversations(account)) {
                if (conversation.type_ != Conversation.Type.CHAT && conversation.type_ != Conversation.Type.GROUPCHAT) continue;
                string jid = conversation.counterpart.bare_jid.to_string();
                if (seen.contains(jid)) continue;
                seen.add(jid);
                string title = Util.get_conversation_display_name(app.stream_interactor, conversation);
                string kind = conversation.type_ == Conversation.Type.GROUPCHAT ? _("Group chat") : _("Direct chat");
                string message_type = conversation.type_ == Conversation.Type.GROUPCHAT ? "groupchat" : "chat";
                candidates.add(new BotTargetCandidate(jid, title, "%s - %s".printf(kind, jid), message_type));
            }
        }

        var roster_manager = app.stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        if (roster_manager != null) {
            foreach (Roster.Item item in roster_manager.get_roster(account)) {
                if (item.jid == null) continue;
                string jid = item.jid.bare_jid.to_string();
                if (seen.contains(jid)) continue;
                seen.add(jid);
                string title = item.name != null && item.name != "" ? item.name : jid;
                candidates.add(new BotTargetCandidate(jid, title, "%s - %s".printf(_("Contact"), jid)));
            }
        }

        return candidates;
    }

    private Account? get_dialog_account() {
        var app = Dino.Application.get_default();
        if (app == null) return null;
        foreach (Account account in app.stream_interactor.get_accounts()) {
            if (account.bare_jid.to_string() == account_jid) return account;
        }
        return null;
    }

    private void populate_target_picker_list(Gtk.ListBox list, Gee.HashMap<Gtk.ListBoxRow, string> row_jids,
                                             Gee.ArrayList<BotTargetCandidate> candidates, string filter) {
        Gtk.ListBoxRow? old_row;
        while ((old_row = list.get_row_at_index(0)) != null) {
            list.remove(old_row);
        }
        row_jids.clear();

        string needle = filter.down();
        foreach (BotTargetCandidate candidate in candidates) {
            if (needle != "" &&
                    !candidate.title.down().contains(needle) &&
                    !candidate.jid.down().contains(needle) &&
                    !candidate.subtitle.down().contains(needle)) {
                continue;
            }

            var action = new Adw.ActionRow();
            action.title = candidate.title;
            action.subtitle = candidate.subtitle;
            action.activatable = false;
            action.selectable = false;

            var row = new Gtk.ListBoxRow();
            row.child = action;
            row_jids[row] = candidate.jid;
            list.append(row);
        }

        if (row_jids.size == 0) {
            var empty = new Adw.ActionRow();
            empty.title = candidates.size == 0 ? _("No contacts or open chats found") : _("No matching target found");
            empty.activatable = false;
            empty.selectable = false;
            var row = new Gtk.ListBoxRow();
            row.selectable = false;
            row.child = empty;
            list.append(row);
        }
    }

    private string add_target_to_list(string current, string target) {
        string trimmed_target = target.strip();
        if (trimmed_target == "") return current.strip();

        var values = new Gee.ArrayList<string>();
        var seen = new Gee.HashSet<string>();
        foreach (string raw_part in current.replace("\n", ",").replace(";", ",").split(",")) {
            string part = raw_part.strip();
            if (part == "" || seen.contains(part)) continue;
            seen.add(part);
            values.add(part);
        }

        if (!seen.contains(trimmed_target)) {
            values.add(trimmed_target);
        }
        return Dino.Ui.Util.join_strings(",", values);
    }

    private void append_muc_room_row(Gtk.ListBox list, int64 bot_id, string bot_name, string muc_rooms, Json.Array? muc_rooms_list) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("Group chat rooms");
        expander.subtitle = muc_rooms.strip() != "" ? muc_rooms : _("Join or leave a MUC with this bot account.");

        if (muc_rooms_list != null && muc_rooms_list.get_length() > 0) {
            for (uint i = 0; i < muc_rooms_list.get_length(); i++) {
                var room_obj = muc_rooms_list.get_object_element(i);
                string room = room_obj.has_member("room") ? room_obj.get_string_member("room") : "";
                string nick = room_obj.has_member("nick") ? room_obj.get_string_member("nick") : "";
                if (room == "") continue;

                append_saved_muc_room(expander, bot_id, room, nick);
            }
        }

        var room_row = new Adw.EntryRow();
        room_row.title = _("Room JID");
        room_row.input_purpose = Gtk.InputPurpose.EMAIL;
        room_row.show_apply_button = false;
        expander.add_row(room_row);

        var nick_row = new Adw.EntryRow();
        nick_row.title = _("Nickname");
        nick_row.text = bot_name;
        nick_row.show_apply_button = false;
        expander.add_row(nick_row);

        var action_row = new Adw.ActionRow();
        action_row.title = _("Room actions");
        action_row.subtitle = muc_rooms.strip() != "" ?
            _("Saved rooms are rejoined automatically when the bot starts.") :
            _("Uses the bot's muc_join permission and target restrictions.");
        action_row.activatable = false;
        action_row.selectable = false;

        var join_btn = new Gtk.Button.with_label(_("Join"));
        join_btn.valign = Gtk.Align.CENTER;
        join_btn.add_css_class("suggested-action");
        action_row.add_suffix(join_btn);

        var leave_btn = new Gtk.Button.with_label(_("Leave"));
        leave_btn.valign = Gtk.Align.CENTER;
        action_row.add_suffix(leave_btn);

        expander.add_row(action_row);

        join_btn.clicked.connect(() => {
            string room = room_row.text.strip();
            if (room == "") {
                action_row.subtitle = _("Room JID is required.");
                return;
            }
            start_join_bot_room(bot_id, room, nick_row.text.strip(), action_row, join_btn);
        });

        leave_btn.clicked.connect(() => {
            string room = room_row.text.strip();
            if (room == "") {
                action_row.subtitle = _("Room JID is required.");
                return;
            }
            start_leave_bot_room(bot_id, room, action_row, leave_btn);
        });

        list.append(expander);
    }

    private void append_saved_muc_room(Adw.ExpanderRow expander, int64 bot_id, string room, string nick) {
        var saved_row = new Adw.ActionRow();
        saved_row.title = room;
        saved_row.subtitle = nick != "" ?
            _("Rejoins automatically as %s.").printf(nick) :
            _("Rejoins automatically.");
        saved_row.activatable = false;
        saved_row.selectable = false;

        var leave_saved_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
        leave_saved_btn.valign = Gtk.Align.CENTER;
        leave_saved_btn.tooltip_text = _("Leave");
        leave_saved_btn.add_css_class("flat");
        saved_row.add_suffix(leave_saved_btn);

        leave_saved_btn.clicked.connect(() => {
            start_leave_bot_room(bot_id, room, saved_row, leave_saved_btn);
        });

        expander.add_row(saved_row);
    }

    private void append_console_row(Gtk.ListBox list, int64 bot_id) {
        var expander = new Adw.ExpanderRow();
        expander.title = _("API test console");
        expander.subtitle = _("Developer tool for testing this bot's local API routing.");

        var target_row = new Adw.EntryRow();
        target_row.title = _("Target JID");
        target_row.input_purpose = Gtk.InputPurpose.EMAIL;
        target_row.show_apply_button = false;

        var choose_target_row = new Adw.ActionRow();
        choose_target_row.title = _("Choose target");
        choose_target_row.subtitle = _("Pick a contact or group chat for this test message.");
        choose_target_row.activatable = false;
        choose_target_row.selectable = false;

        var choose_target_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
        choose_target_btn.valign = Gtk.Align.CENTER;
        choose_target_btn.tooltip_text = _("Choose target");
        choose_target_btn.add_css_class("flat");
        choose_target_row.add_suffix(choose_target_btn);
        expander.add_row(choose_target_row);

        expander.add_row(target_row);

        var message_row = new Adw.EntryRow();
        message_row.title = _("Message");
        message_row.show_apply_button = false;
        expander.add_row(message_row);

        var type_model = new Gtk.StringList(null);
        type_model.append(_("Direct chat"));
        type_model.append(_("Group chat"));

        var type_row = new Adw.ComboRow();
        type_row.title = _("Message type");
        type_row.model = type_model;
        type_row.selected = 0;
        expander.add_row(type_row);

        var send_row = new Adw.ActionRow();
        send_row.title = _("Send test message");
        send_row.subtitle = _("Uses this bot's permissions and target restrictions.");
        send_row.activatable = false;
        send_row.selectable = false;

        var send_btn = new Gtk.Button.with_label(_("Send"));
        send_btn.valign = Gtk.Align.CENTER;
        send_btn.add_css_class("suggested-action");
        send_row.add_suffix(send_btn);
        expander.add_row(send_row);

        choose_target_btn.clicked.connect(() => {
            present_console_target_picker(target_row, type_row);
        });

        send_btn.clicked.connect(() => {
            string target = target_row.text.strip();
            string text = message_row.text.strip();
            if (target == "" || text == "") {
                send_row.subtitle = _("Target JID and message are required.");
                return;
            }

            string msg_type = type_row.selected == 1 ? "groupchat" : "chat";
            start_send_bot_console_message(bot_id, target, text, msg_type, send_row, send_btn);
        });

        list.append(expander);
    }

    private void present_console_target_picker(Adw.EntryRow target_row, Adw.ComboRow type_row) {
        var candidates = collect_target_candidates();
        var row_jids = new Gee.HashMap<Gtk.ListBoxRow, string>();

        var dialog = new Adw.Dialog();
        dialog.content_width = 460;
        dialog.content_height = 560;

        var toolbar_view = new Adw.ToolbarView();
        dialog.child = toolbar_view;

        var header = new Adw.HeaderBar();
        header.decoration_layout = ":";
        var title = new Adw.WindowTitle(_("Choose target"), "");
        header.title_widget = title;

        var cancel_btn = new Gtk.Button.with_label(_("Cancel"));
        var add_btn = new Gtk.Button.with_label(_("Add"));
        add_btn.add_css_class("suggested-action");
        add_btn.sensitive = false;
        header.pack_start(cancel_btn);
        header.pack_end(add_btn);
        toolbar_view.add_top_bar(header);

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        var search = new Gtk.SearchEntry();
        search.placeholder_text = _("Search contacts and open chats");
        box.append(search);

        var scrolled = new Gtk.ScrolledWindow();
        scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scrolled.vexpand = true;

        var list = new Gtk.ListBox();
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        scrolled.child = list;
        box.append(scrolled);

        toolbar_view.content = box;

        populate_target_picker_list(list, row_jids, candidates, "");

        list.row_selected.connect((row) => {
            add_btn.sensitive = row != null && row_jids.has_key(row);
        });

        list.row_activated.connect((row) => {
            apply_console_target_from_picker(dialog, list, row_jids, candidates, target_row, type_row);
        });
        add_btn.clicked.connect(() => {
            apply_console_target_from_picker(dialog, list, row_jids, candidates, target_row, type_row);
        });
        cancel_btn.clicked.connect(() => {
            dialog.close();
        });
        search.search_changed.connect(() => {
            populate_target_picker_list(list, row_jids, candidates, search.text.strip());
            add_btn.sensitive = false;
        });

        dialog.present(this);
    }

    private void apply_console_target_from_picker(Adw.Dialog dialog, Gtk.ListBox list,
                                                  Gee.HashMap<Gtk.ListBoxRow, string> row_jids,
                                                  Gee.ArrayList<BotTargetCandidate> candidates,
                                                  Adw.EntryRow target_row, Adw.ComboRow type_row) {
        Gtk.ListBoxRow? row = list.get_selected_row();
        if (row == null || !row_jids.has_key(row)) return;

        string jid = row_jids[row];
        target_row.text = jid;
        foreach (BotTargetCandidate candidate in candidates) {
            if (candidate.jid == jid) {
                type_row.selected = candidate.message_type == "groupchat" ? 1 : 0;
                break;
            }
        }
        dialog.close();
    }

    private uint target_mode_to_index(string target_mode) {
        switch (target_mode) {
            case "allow": return 1;
            case "block": return 2;
            default: return 0;
        }
    }

    private string target_mode_from_index(uint index) {
        switch (index) {
            case 1: return "allow";
            case 2: return "block";
            default: return "all";
        }
    }

    private string target_hint(string target_mode) {
        switch (target_mode) {
            case "allow": return _("Only listed targets are allowed. All others are blocked.");
            case "block": return _("Listed targets are blocked. All others are allowed.");
            default: return _("No target restriction is active.");
        }
    }

    private string format_targets_summary(string target_mode, string target_list) {
        string normalized = target_list.strip();
        if (target_mode == "all") return _("All targets allowed");

        int count = 0;
        foreach (string part in normalized.split(",")) {
            if (part.strip() != "") count++;
        }
        if (target_mode == "block") {
            return ngettext("%d target blocked", "%d targets blocked", count).printf(count);
        }
        return ngettext("%d target allowed", "%d targets allowed", count).printf(count);
    }

    private uint telegram_mode_to_index(string mode) {
        return mode == "forward" ? 1 : 0;
    }

    private string telegram_mode_from_index(uint index) {
        return index == 1 ? "forward" : "bridge";
    }

    private string telegram_summary(bool configured, bool enabled, string mode) {
        if (!configured) return _("Not configured");
        string mode_label = mode == "forward" ? _("Forward only") : _("Bridge");
        return enabled ? _("Enabled - %s").printf(mode_label) : _("Disabled - %s").printf(mode_label);
    }

    private uint ai_provider_to_index(string provider) {
        return BotProviderSelection.index_of(provider);
    }

    private string ai_provider_from_index(uint index) {
        return BotProviderSelection.key_at(index);
    }

    private string ai_provider_label(string provider) {
        switch (provider) {
            case "ollama": return _("Ollama");
            case "openai": return _("OpenAI");
            case "claude": return _("Claude");
            case "gemini": return _("Gemini");
            case "groq": return _("Groq");
            case "mistral": return _("Mistral");
            case "deepseek": return _("DeepSeek");
            case "perplexity": return _("Perplexity");
            case "xai": return _("xAI / Grok");
            case "openclaw": return _("OpenClaw");
            default: return provider;
        }
    }

    private string[] ai_model_preset_labels() {
        return new string[] {
            _("Custom model"),
            _("Gemini 2.5 Flash-Lite - cheapest"),
            _("Gemini 2.5 Flash - balanced"),
            _("Gemini 2.5 Pro - stronger"),
            _("Grok 4.20 Reasoning"),
            _("Grok 4.3"),
            _("Groq Llama 3.3 70B"),
            _("OpenAI GPT-4o mini")
        };
    }

    private uint ai_model_preset_to_index(string model) {
        string normalized = model.strip();
        for (int i = 0; i < AI_MODEL_PRESET_VALUES.length; i++) {
            if (AI_MODEL_PRESET_VALUES[i] == normalized) return (uint) i;
        }
        return 0;
    }

    private string ai_model_preset_from_index(uint index) {
        if (index >= AI_MODEL_PRESET_VALUES.length) return "";
        return AI_MODEL_PRESET_VALUES[index];
    }

    private string ai_summary(bool configured, bool enabled, string provider, string model) {
        if (!configured) return _("Not configured");
        string label = model.strip() != "" ? "%s / %s".printf(ai_provider_label(provider), model) : ai_provider_label(provider);
        return enabled ? _("Enabled - %s").printf(label) : _("Disabled - %s").printf(label);
    }

    private uint muc_owner_notify_to_index(string mode) {
        switch (mode) {
            case "mentions": return 1;
            case "mentions_when_owner_absent": return 2;
            default: return 0;
        }
    }

    private string muc_owner_notify_from_index(uint index) {
        switch (index) {
            case 1: return "mentions";
            case 2: return "mentions_when_owner_absent";
            default: return "off";
        }
    }

    private uint muc_ai_mode_to_index(string mode) {
        switch (mode) {
            case "support_questions": return 1;
            case "active_support": return 2;
            default: return 0;
        }
    }

    private string muc_ai_mode_from_index(uint index) {
        switch (index) {
            case 1: return "support_questions";
            case 2: return "active_support";
            default: return "mention_only";
        }
    }

    private string get_text_view_text(Gtk.TextView view) {
        Gtk.TextIter start;
        Gtk.TextIter end;
        view.buffer.get_bounds(out start, out end);
        return view.buffer.get_text(start, end, false);
    }

    private bool permission_string_has(string permissions, string key) {
        foreach (string part in permissions.split(",")) {
            string normalized = part.strip();
            if (normalized == key) return true;
            if (normalized == "all" && key == "all") return true;
        }
        return permissions.strip() == "" && key == "all";
    }

    private string collect_permissions(Gee.HashMap<string, Adw.SwitchRow> switches) {
        if (switches["all"].active) return "all";

        var selected = new Gee.ArrayList<string>();
        foreach (string key in PERMISSION_KEYS) {
            if (key == "all") continue;
            if (switches[key].active) selected.add(key);
        }

        if (selected.size == 0) return "all";
        return Dino.Ui.Util.join_strings(",", selected);
    }

    private bool has_selected_specific_permission(Gee.HashMap<string, Adw.SwitchRow> switches) {
        foreach (string key in PERMISSION_KEYS) {
            if (key != "all" && switches[key].active) return true;
        }
        return false;
    }

    private string format_permissions_summary(string permissions) {
        if (permission_string_has(permissions, "all")) return _("All permissions");

        int count = 0;
        foreach (string key in PERMISSION_KEYS) {
            if (key != "all" && permission_string_has(permissions, key)) count++;
        }

        if (count == 0) return _("All permissions");
        return ngettext("%d permission", "%d permissions", count).printf(count);
    }

    private string permission_title(string key) {
        switch (key) {
            case "all": return _("All permissions");
            case "send_message": return _("Send messages");
            case "receive_updates": return _("Receive updates");
            case "webhook": return _("Manage webhooks");
            case "file_send": return _("Send files");
            case "muc_join": return _("Join group chats");
            case "muc_send": return _("Send to group chats");
            case "admin": return _("Administration");
            default: return key;
        }
    }

    private string permission_description(string key) {
        switch (key) {
            case "all": return _("Compatibility mode for existing bots");
            case "send_message": return _("Allow sending direct chat messages and reactions");
            case "receive_updates": return _("Allow reading incoming updates and webhook delivery");
            case "webhook": return _("Allow setting and deleting webhook URLs");
            case "file_send": return _("Allow sending file URLs");
            case "muc_join": return _("Allow joining and leaving group chats");
            case "muc_send": return _("Allow sending messages to group chats");
            case "admin": return _("Allow changing bot commands and integrations");
            default: return "";
        }
    }

    private async void save_permissions(int64 bot_id, string permissions) {
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("permissions");
            builder.add_string_value(permissions);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/permissions", json_body, out response);
            if (msg.status_code != 200) {
                string detail = format_api_failure(_("Saving permissions"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_bots();
            }
        } catch (Error e) {
            warning("BotManager: Permission update error: %s", e.message);
            present_action_error(action_error_message(_("Saving permissions"), e.message));
            start_load_bots();
        }
    }

    private async void save_targets(int64 bot_id, string target_mode, string target_list) {
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("target_mode");
            builder.add_string_value(target_mode);
            builder.set_member_name("target_list");
            builder.add_string_value(target_list);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/targets", json_body, out response);
            if (msg.status_code != 200) {
                string detail = format_api_failure(_("Saving target restrictions"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_bots();
            }
        } catch (Error e) {
            warning("BotManager: Target update error: %s", e.message);
            present_action_error(action_error_message(_("Saving target restrictions"), e.message));
            start_load_bots();
        }
    }

    private async void choose_bot_avatar(int64 bot_id, Adw.ExpanderRow expander,
                                         Adw.ActionRow status_row, Gtk.Button remove_btn) {
        var dialog = new Gtk.FileDialog();
        dialog.title = _("Choose Bot Avatar");

        var filter = new Gtk.FileFilter();
        filter.name = _("Images");
        filter.add_mime_type("image/png");
        filter.add_mime_type("image/jpeg");
        filter.add_mime_type("image/gif");
        filter.add_mime_type("image/webp");
        var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
        filters.append(filter);
        dialog.filters = filters;

        try {
            var file = yield dialog.open(this.get_root() as Gtk.Window, null);
            if (file == null) return;

            string avatar_base64;
            string avatar_mime;
            yield load_bot_avatar_file(file, out avatar_base64, out avatar_mime);
            yield save_bot_avatar(bot_id, avatar_base64, avatar_mime, expander, status_row, remove_btn);
        } catch (Error e) {
            if (!(e is IOError.CANCELLED)) {
                warning("BotManager: Avatar selection error: %s", e.message);
                present_action_error(action_error_message(_("Changing avatar"), e.message));
            }
        }
    }

    private async void load_bot_avatar_file(GLib.File file, out string avatar_base64, out string avatar_mime) throws Error {
        avatar_base64 = "";
        avatar_mime = "image/png";
        FileInputStream? stream = null;
        try {
            stream = yield file.read_async();
            Pixbuf pixbuf = yield new Pixbuf.from_stream_async(stream);
            if (pixbuf.width >= pixbuf.height && pixbuf.width > MAX_BOT_AVATAR_PIXEL) {
                int dest_height = int.max(1, (int) ((float) MAX_BOT_AVATAR_PIXEL / pixbuf.width * pixbuf.height));
                pixbuf = pixbuf.scale_simple(MAX_BOT_AVATAR_PIXEL, dest_height, InterpType.BILINEAR);
            } else if (pixbuf.height > pixbuf.width && pixbuf.height > MAX_BOT_AVATAR_PIXEL) {
                int dest_width = int.max(1, (int) ((float) MAX_BOT_AVATAR_PIXEL / pixbuf.height * pixbuf.width));
                pixbuf = pixbuf.scale_simple(dest_width, MAX_BOT_AVATAR_PIXEL, InterpType.BILINEAR);
            }

            uint8[] data;
            data = Dino.Ui.Util.pixbuf_to_png_bytes(pixbuf);
            avatar_base64 = GLib.Base64.encode(data);
        } finally {
            try {
                if (stream != null) stream.close();
            } catch (Error e) {
                // Ignore close errors.
            }
        }
    }

    private async void save_bot_avatar(int64 bot_id, string avatar_base64, string avatar_mime,
                                       Adw.ExpanderRow expander, Adw.ActionRow status_row,
                                       Gtk.Button remove_btn) {
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("avatar");
            builder.add_string_value(avatar_base64);
            builder.set_member_name("avatar_type");
            builder.add_string_value(avatar_mime);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/avatar", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = _("Configured");
                status_row.subtitle = avatar_mime;
                remove_btn.sensitive = true;
            } else {
                string detail = format_api_failure(_("Changing avatar"), msg.status_code, response);
                warning("BotManager: %s", detail);
                status_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Avatar update error: %s", e.message);
            status_row.subtitle = e.message;
            present_action_error(action_error_message(_("Changing avatar"), e.message));
        }
    }

    private async void remove_bot_avatar(int64 bot_id, Adw.ExpanderRow expander,
                                         Adw.ActionRow status_row, Gtk.Button remove_btn) {
        remove_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("remove");
            builder.add_boolean_value(true);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/avatar", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = _("Not set");
                status_row.subtitle = _("Choose a square image. DinoX scales it before upload.");
            } else {
                string detail = format_api_failure(_("Removing avatar"), msg.status_code, response);
                warning("BotManager: %s", detail);
                status_row.subtitle = detail;
                present_action_error(detail);
                remove_btn.sensitive = true;
            }
        } catch (Error e) {
            warning("BotManager: Avatar remove error: %s", e.message);
            status_row.subtitle = e.message;
            present_action_error(action_error_message(_("Removing avatar"), e.message));
            remove_btn.sensitive = true;
        }
    }

    private async void save_telegram_setup(int64 bot_id, string token, string chat_id, string mode,
                                           bool already_configured, Adw.ExpanderRow expander,
                                           Adw.SwitchRow active_row, Adw.ActionRow actions_row,
                                           Gtk.Button save_btn) {
        if (!already_configured && token == "") {
            actions_row.subtitle = _("Telegram bot token is required.");
            return;
        }
        if (chat_id == "") {
            actions_row.subtitle = _("Telegram chat ID is required.");
            return;
        }

        save_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            if (token != "") {
                builder.set_member_name("token");
                builder.add_string_value(token);
            }
            builder.set_member_name("chat_id");
            builder.add_string_value(chat_id);
            builder.set_member_name("mode");
            builder.add_string_value(mode);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/telegram/manage", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = telegram_summary(true, active_row.active, mode);
                active_row.sensitive = true;
                active_row.subtitle = _("Receive Telegram updates for this bot.");
                actions_row.subtitle = _("Telegram settings saved. The token will not be shown again.");
                start_load_bots();
            } else {
                string detail = format_api_failure(_("Saving Telegram settings"), msg.status_code, response);
                warning("BotManager: %s", detail);
                actions_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Telegram setup error: %s", e.message);
            actions_row.subtitle = e.message;
            present_action_error(action_error_message(_("Saving Telegram settings"), e.message));
        }
        save_btn.sensitive = true;
    }

    private async void save_ai_setup(int64 bot_id, string provider, string api_key, string model,
                                     Adw.ExpanderRow expander,
                                     Adw.SwitchRow active_row, Adw.ActionRow actions_row,
                                     Gtk.Button save_btn) {
        if (model == "") {
            actions_row.subtitle = _("AI model is required.");
            return;
        }

        save_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("provider");
            builder.add_string_value(provider);
            if (api_key != "") {
                builder.set_member_name("api_key");
                builder.add_string_value(api_key);
            }
            builder.set_member_name("model");
            builder.add_string_value(model);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/ai/manage", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = ai_summary(true, active_row.active, provider, model);
                active_row.sensitive = true;
                active_row.subtitle = _("Forward incoming bot messages to the configured AI.");
                actions_row.subtitle = _("AI settings saved. The key will not be shown again.");
                start_load_bots();
            } else {
                string detail = format_api_failure(_("Saving AI settings"), msg.status_code, response);
                warning("BotManager: %s", detail);
                actions_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: AI setup error: %s", e.message);
            actions_row.subtitle = e.message;
            present_action_error(action_error_message(_("Saving AI settings"), e.message));
        }
        save_btn.sensitive = true;
    }

    private async void save_ai_enabled(int64 bot_id, bool enabled,
                                       Adw.ExpanderRow expander,
                                       Adw.SwitchRow active_row) {
        active_row.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("enabled");
            builder.add_boolean_value(enabled);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/ai/manage", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = enabled ? _("Enabled") : _("Disabled");
            } else {
                string detail = format_api_failure(_("Changing AI status"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_bots();
            }
        } catch (Error e) {
            warning("BotManager: AI status error: %s", e.message);
            present_action_error(action_error_message(_("Changing AI status"), e.message));
            start_load_bots();
        }
        active_row.sensitive = true;
    }

    private async void save_ai_behavior(int64 bot_id, string? system_prompt, string? muc_owner_notify, string? muc_ai_mode,
                                        Adw.ActionRow status_row) {
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            if (system_prompt != null) {
                builder.set_member_name("system_prompt");
                builder.add_string_value(system_prompt);
            }
            if (muc_owner_notify != null) {
                builder.set_member_name("muc_owner_notify");
                builder.add_string_value(muc_owner_notify);
            }
            if (muc_ai_mode != null) {
                builder.set_member_name("muc_ai_mode");
                builder.add_string_value(muc_ai_mode);
            }
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/ai/manage", json_body, out response);
            if (msg.status_code == 200) {
                status_row.subtitle = _("AI behavior saved.");
            } else {
                string detail = format_api_failure(_("Saving AI behavior"), msg.status_code, response);
                warning("BotManager: %s", detail);
                status_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: AI behavior error: %s", e.message);
            status_row.subtitle = e.message;
            present_action_error(action_error_message(_("Saving AI behavior"), e.message));
        }
    }

    private async void join_bot_room(int64 bot_id, string room_jid, string nick,
                                     Adw.ActionRow status_row, Gtk.Button join_btn) {
        join_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("room");
            builder.add_string_value(room_jid);
            if (nick != "") {
                builder.set_member_name("nick");
                builder.add_string_value(nick);
            }
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/testJoinRoom", json_body, out response);
            if (msg.status_code == 200) {
                status_row.subtitle = _("Bot joined the group chat and will rejoin it automatically.");
            } else {
                string detail = format_api_failure(_("Joining group chat"), msg.status_code, response);
                warning("BotManager: %s", detail);
                status_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Join room error: %s", e.message);
            status_row.subtitle = e.message;
            present_action_error(action_error_message(_("Joining group chat"), e.message));
        }
        join_btn.sensitive = true;
    }

    private async void leave_bot_room(int64 bot_id, string room_jid,
                                      Adw.ActionRow status_row, Gtk.Button leave_btn) {
        leave_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("room");
            builder.add_string_value(room_jid);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/testLeaveRoom", json_body, out response);
            if (msg.status_code == 200) {
                status_row.subtitle = _("Bot left the group chat and removed it from saved rooms.");
            } else {
                string detail = format_api_failure(_("Leaving group chat"), msg.status_code, response);
                warning("BotManager: %s", detail);
                status_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Leave room error: %s", e.message);
            status_row.subtitle = e.message;
            present_action_error(action_error_message(_("Leaving group chat"), e.message));
        }
        leave_btn.sensitive = true;
    }

    private async void save_telegram_enabled(int64 bot_id, bool enabled,
                                             Adw.ExpanderRow expander,
                                             Adw.SwitchRow active_row) {
        active_row.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("enabled");
            builder.add_boolean_value(enabled);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/telegram/manage", json_body, out response);
            if (msg.status_code == 200) {
                expander.subtitle = enabled ? _("Enabled") : _("Disabled");
            } else {
                string detail = format_api_failure(_("Changing Telegram status"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_bots();
            }
        } catch (Error e) {
            warning("BotManager: Telegram status error: %s", e.message);
            present_action_error(action_error_message(_("Changing Telegram status"), e.message));
            start_load_bots();
        }
        active_row.sensitive = true;
    }

    private async void save_webhook(int64 bot_id, string webhook_url, Adw.ExpanderRow expander,
                                    Adw.ActionRow secret_row, Gtk.Button save_btn, Gtk.Button disable_btn) {
        if (webhook_url == "") {
            secret_row.subtitle = _("Webhook URL is required.");
            return;
        }
        if (is_cloudbot_api_url(webhook_url)) {
            secret_row.subtitle = _("CloudBot API URLs belong in CloudBot controls, not in local webhooks.");
            return;
        }

        save_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("url");
            builder.add_string_value(webhook_url);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/webhook", json_body, out response);
            if (msg.status_code == 200) {
                string secret = parse_api_result_string(response, "secret");
                expander.subtitle = _("Enabled");
                secret_row.subtitle = _("New secret generated. Save it now; it will not be shown again.");
                save_btn.label = _("Update");
                disable_btn.sensitive = true;
                if (secret != "") {
                    copy_to_clipboard(secret);
                    present_webhook_secret_dialog(secret);
                }
            } else {
                string detail = format_api_failure(_("Saving webhook"), msg.status_code, response);
                warning("BotManager: %s", detail);
                secret_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Webhook update error: %s", e.message);
            secret_row.subtitle = e.message;
            present_action_error(action_error_message(_("Saving webhook"), e.message));
        }
        save_btn.sensitive = true;
    }

    private bool is_cloudbot_api_url(string url) {
        try {
            var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
            string? host = uri.get_host();
            string path = uri.get_path();
            return host != null
                && host.ascii_down() == "cloud.dinox.im"
                && path.has_prefix("/api/v1/bot");
        } catch (Error e) {
            return false;
        }
    }

    private async void disable_webhook(int64 bot_id, Adw.EntryRow url_row, Adw.ExpanderRow expander,
                                       Adw.ActionRow secret_row, Gtk.Button save_btn, Gtk.Button disable_btn) {
        disable_btn.sensitive = false;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("enabled");
            builder.add_boolean_value(false);
            builder.end_object();
            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/webhook", json_body, out response);
            if (msg.status_code == 200) {
                url_row.text = "";
                expander.subtitle = _("Disabled");
                secret_row.subtitle = _("Set a URL to generate a webhook secret.");
                save_btn.label = _("Set");
            } else {
                string detail = format_api_failure(_("Disabling webhook"), msg.status_code, response);
                warning("BotManager: %s", detail);
                secret_row.subtitle = detail;
                present_action_error(detail);
                disable_btn.sensitive = true;
            }
        } catch (Error e) {
            warning("BotManager: Webhook disable error: %s", e.message);
            secret_row.subtitle = e.message;
            present_action_error(action_error_message(_("Disabling webhook"), e.message));
            disable_btn.sensitive = true;
        }
    }

    private async void show_webhook_secret_dialog(string secret) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        var secret_label = new Gtk.Label(secret);
        secret_label.wrap = true;
        secret_label.wrap_mode = Pango.WrapMode.CHAR;
        secret_label.selectable = true;
        secret_label.xalign = 0;
        secret_label.add_css_class("monospace");
        box.append(secret_label);

        var hint_label = new Gtk.Label(_("The secret has been copied to the clipboard. Save it now; it will not be shown again."));
        hint_label.wrap = true;
        hint_label.xalign = 0;
        hint_label.add_css_class("dim-label");
        box.append(hint_label);

        var alert = new Adw.AlertDialog(
            _("New Webhook Secret"),
            _("This secret is shown only once.")
        );
        alert.extra_child = box;
        alert.add_response("close", _("Close"));
        alert.add_response("copy", _("Copy"));
        alert.default_response = "close";
        alert.set_response_appearance("copy", Adw.ResponseAppearance.SUGGESTED);

        string response = yield alert.choose(this, null);
        if (response == "copy") {
            copy_to_clipboard(secret);
        }
    }

    private async void send_bot_console_message(int64 bot_id, string target, string text,
                                                string msg_type, Adw.ActionRow status_row,
                                                Gtk.Button send_btn) {
        send_btn.sensitive = false;
        status_row.subtitle = _("Sending...");
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("to");
            builder.add_string_value(target);
            builder.set_member_name("text");
            builder.add_string_value(text);
            builder.set_member_name("type");
            builder.add_string_value(msg_type);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/testSend", json_body, out response);
            string details = parse_api_message(response);
            if (msg.status_code == 200) {
                status_row.subtitle = details != "" ? _("Sent: %s").printf(details) : _("Sent");
            } else {
                status_row.subtitle = details != "" ? _("Failed: %s").printf(details) : _("Failed with status %u").printf(msg.status_code);
            }
        } catch (Error e) {
            status_row.subtitle = _("Error: %s").printf(e.message);
        }
        send_btn.sensitive = true;
    }

    private async void ask_ai_console(int64 bot_id, string question,
                                      Adw.ActionRow answer_row,
                                      Gtk.Button ask_btn) {
        ask_btn.sensitive = false;
        answer_row.subtitle = _("Asking...");
        var cancellable = new Cancellable();
        uint timeout_id = 0;
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("id");
            builder.add_int_value(bot_id);
            builder.set_member_name("message");
            builder.add_string_value(question);
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string json_body = gen.to_data(null);

            if (!(yield check_api_reachable(true))) {
                throw new IOError.FAILED("Botmother API is not available on port %u".printf(get_api_port()));
            }

            timeout_id = Timeout.add_seconds(AI_CONSOLE_TIMEOUT_SECONDS, () => {
                timeout_id = 0;
                cancellable.cancel();
                return false;
            });

            var request = create_api_message("POST", "/bot/ai/testAsk");
            request.set_request_body_from_bytes("application/json", new Bytes(json_body.data));

            Bytes response;
            response = yield http.send_and_read_async(request, GLib.Priority.DEFAULT, cancellable);
            if (request.status_code == 200) {
                string answer = parse_api_result_string(response, "response");
                answer_row.subtitle = answer != "" ? answer : _("AI returned an empty response.");
            } else {
                string detail = format_api_failure(_("Asking AI"), request.status_code, response);
                answer_row.subtitle = detail;
                present_action_error(detail);
            }
        } catch (Error e) {
            if (cancellable.is_cancelled()) {
                answer_row.subtitle = _("AI request timed out after %u seconds.").printf(AI_CONSOLE_TIMEOUT_SECONDS);
            } else {
                answer_row.subtitle = _("Error: %s").printf(e.message);
                present_action_error(action_error_message(_("Asking AI"), e.message));
            }
        }
        if (timeout_id != 0) {
            Source.remove(timeout_id);
        }
        ask_btn.sensitive = true;
    }

    private string parse_api_message(Bytes response) {
        try {
            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            Json.Object data = root;
            if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                data = root.get_object_member("result");
            }
            if (data.has_member("message_id")) return data.get_string_member("message_id");
            if (root.has_member("description")) return root.get_string_member("description");
            if (root.has_member("error")) return root.get_string_member("error");
        } catch (Error e) {
            return "";
        }
        return "";
    }

    private string parse_api_result_string(Bytes response, string key) {
        try {
            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (!root.has_member("result") || root.get_member("result").get_node_type() != Json.NodeType.OBJECT) return "";
            var result = root.get_object_member("result");
            if (result.has_member(key)) return result.get_string_member(key);
        } catch (Error e) {
            return "";
        }
        return "";
    }

    private void on_create_clicked() {
        var dialog = new BotCreateDialog();
        dialog.account_jid = this.account_jid;
        dialog.cloud_bot_added.connect((token) => {
            start_add_cloud_token_from_create(token);
        });
        dialog.bot_created.connect(() => {
            start_load_bots();
        });
        dialog.present(this);
    }

    private async void confirm_delete(int64 bot_id, string bot_name) {
        var alert = new Adw.AlertDialog(
            _("Delete Botmother?"),
            _("Are you sure you want to delete \"%s\"? This cannot be undone.").printf(bot_name)
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("delete", _("Delete"));
        alert.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response == "delete") {
            yield delete_bot(bot_id);
        }
    }

    private async void delete_bot(int64 bot_id) {
        try {
            if (!(yield check_api_reachable(true))) {
                string detail = _("Botmother API is not available on port %u").printf(get_api_port());
                warning("BotManager: Delete error: %s", detail);
                present_action_error(action_error_message(_("Deleting Botmother"), detail));
                return;
            }
            var msg = create_api_message("DELETE", "/bot/delete?id=%lld".printf(bot_id));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            if (msg.status_code == 200) {
                main_stack.visible_child_name = "loading";
                yield load_bots();
            } else {
                string detail = format_api_failure(_("Deleting Botmother"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Delete error: %s", e.message);
            present_action_error(action_error_message(_("Deleting Botmother"), e.message));
        }
    }

    private async void regenerate_token(int64 bot_id) {
        try {
            string json_body = "{\"id\":%lld}".printf(bot_id);
            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/token", json_body, out response);

            if (msg.status_code == 200) {
                // Parse the new token and copy it to clipboard
                var parser = new Json.Parser();
                Util.load_json_response(parser, response);
                var root = parser.get_root().get_object();
                if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                    var result = root.get_object_member("result");
                    if (result.has_member("token")) {
                        string new_token = result.get_string_member("token");
                        copy_to_clipboard(new_token);
                        present_new_token_dialog(new_token);
                    }
                }
                yield load_bots();
            } else {
                string detail = format_api_failure(_("Generating token"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Token regeneration error: %s", e.message);
            present_action_error(action_error_message(_("Generating token"), e.message));
        }
    }

    private async void show_new_token_dialog(string token) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);

        var token_label = new Gtk.Label(token);
        token_label.wrap = true;
        token_label.wrap_mode = Pango.WrapMode.CHAR;
        token_label.selectable = true;
        token_label.xalign = 0;
        token_label.add_css_class("monospace");
        box.append(token_label);

        var hint_label = new Gtk.Label(_("The token has been copied to the clipboard. Save it now; it will not be shown again."));
        hint_label.wrap = true;
        hint_label.xalign = 0;
        hint_label.add_css_class("dim-label");
        box.append(hint_label);

        var alert = new Adw.AlertDialog(
            _("New API Token"),
            _("This token is shown only once.")
        );
        alert.set_extra_child(box);
        alert.add_response("copy", _("Copy Token"));
        alert.add_response("done", _("Done"));
        alert.default_response = "done";
        alert.close_response = "done";

        string response = yield alert.choose(this, null);
        if (response == "copy") {
            copy_to_clipboard(token);
        }
    }

    private async void show_new_cloud_token_dialog(string token) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);

        var token_label = new Gtk.Label(token);
        token_label.wrap = true;
        token_label.wrap_mode = Pango.WrapMode.CHAR;
        token_label.selectable = true;
        token_label.xalign = 0;
        token_label.add_css_class("monospace");
        box.append(token_label);

        var hint_label = new Gtk.Label(_("The token has been copied to the clipboard and placed in the management token field. Save it now; it will not be shown again."));
        hint_label.wrap = true;
        hint_label.xalign = 0;
        hint_label.add_css_class("dim-label");
        box.append(hint_label);

        var alert = new Adw.AlertDialog(
            _("New CloudBot Token"),
            _("This token is shown only once.")
        );
        alert.set_extra_child(box);
        alert.add_response("copy", _("Copy Token"));
        alert.add_response("done", _("Done"));
        alert.default_response = "done";
        alert.close_response = "done";

        string response = yield alert.choose(this, null);
        if (response == "copy") {
            copy_to_clipboard(token);
        }
    }

    private async void show_new_cloud_event_token_dialog(string token) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);

        var token_label = new Gtk.Label(token);
        token_label.wrap = true;
        token_label.wrap_mode = Pango.WrapMode.CHAR;
        token_label.selectable = true;
        token_label.xalign = 0;
        token_label.add_css_class("monospace");
        box.append(token_label);

        var hint_label = new Gtk.Label(_("The event token has been copied to the clipboard. It can call /api/v1/bot/events, but it cannot manage the cloud bot. Save it now; it will not be shown again."));
        hint_label.wrap = true;
        hint_label.xalign = 0;
        hint_label.add_css_class("dim-label");
        box.append(hint_label);

        var alert = new Adw.AlertDialog(
            _("New CloudBot Event Token"),
            _("This token is shown only once.")
        );
        alert.set_extra_child(box);
        alert.add_response("copy", _("Copy Token"));
        alert.add_response("done", _("Done"));
        alert.default_response = "done";
        alert.close_response = "done";

        string response = yield alert.choose(this, null);
        if (response == "copy") {
            copy_to_clipboard(token);
        }
    }

    private async void confirm_revoke(int64 bot_id, string bot_name) {
        var alert = new Adw.AlertDialog(
            _("Revoke Token?"),
            _("Revoke the API token for \"%s\"? The bot will be disabled and all API access will stop.").printf(bot_name)
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("revoke", _("Revoke"));
        alert.set_response_appearance("revoke", Adw.ResponseAppearance.DESTRUCTIVE);
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response == "revoke") {
            yield revoke_token(bot_id);
        }
    }

    private async void revoke_token(int64 bot_id) {
        try {
            string json_body = "{\"id\":%lld}".printf(bot_id);
            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/revoke", json_body, out response);

            if (msg.status_code == 200) {
                yield load_bots();
            } else {
                string detail = format_api_failure(_("Revoking token"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
            }
        } catch (Error e) {
            warning("BotManager: Token revoke error: %s", e.message);
            present_action_error(action_error_message(_("Revoking token"), e.message));
        }
    }

    private string get_bot_status_icon(string status) {
        switch (status) {
            case "active":
                return "\xf0\x9f\x9f\xa2";
            case "paused":
                return "\xf0\x9f\x9f\xa1";
            default:
                return "\xf0\x9f\x94\xb4";
        }
    }

    private string get_bot_status_label(string status) {
        switch (status) {
            case "active":
                return _("Active");
            case "paused":
                return _("Paused");
            case "disabled":
                return _("Disabled");
            default:
                return status;
        }
    }

    private string purpose_label(string purpose) {
        switch (purpose) {
            case "ai":
                return _("AI Bot");
            case "telegram":
                return _("Telegram Bridge");
            case "webhook":
                return _("Webhook / API Bot");
            case "advanced":
                return _("Advanced / Mixed");
            default:
                return purpose;
        }
    }

    private async void set_bot_status(int64 bot_id, string status) {
        try {
            string json_body = "{\"id\":%lld,\"status\":\"%s\"}".printf(bot_id, status);
            Bytes response;
            var msg = yield post_bot_api_with_response("/bot/activate", json_body, out response);

            if (msg.status_code == 200) {
                yield load_bots();
            } else {
                string detail = format_api_failure(_("Changing Botmother status"), msg.status_code, response);
                warning("BotManager: %s", detail);
                present_action_error(detail);
                start_load_bots();
            }
        } catch (Error e) {
            warning("BotManager: Status change error: %s", e.message);
            present_action_error(action_error_message(_("Changing Botmother status"), e.message));
            start_load_bots();
        }
    }

    private string action_error_message(string action, string detail) {
        return _("%s failed: %s").printf(action, detail);
    }

    private string format_api_failure(string action, uint status_code, Bytes response) {
        string detail = parse_api_message(response);
        if (detail != "") return action_error_message(action, detail);
        return _("%s failed with status %u").printf(action, status_code);
    }

    private async void show_action_error(string detail) {
        var alert = new Adw.AlertDialog(_("Botmother Action Failed"), detail);
        alert.add_response("ok", _("OK"));
        alert.default_response = "ok";
        alert.close_response = "ok";
        yield alert.choose(this, null);
    }

    private void show_error(string detail) {
        warning("BotManager: %s", detail);
        error_page.description = detail;
        main_stack.visible_child_name = "error";
    }

    // Cross-platform clipboard copy using GTK4 API
    private void copy_to_clipboard(string text) {
        var display = Gdk.Display.get_default();
        if (display != null) {
            display.get_clipboard().set_text(text);
        } else {
            warning("Clipboard copy failed: no display available");
        }
    }

    private uint16 get_api_port() {
        var app = Dino.Application.get_default();
        int port = app.settings.api_port;
        if (port < 1 || port > 65535) return 7842;
        return (uint16) port;
    }

    private string get_api_base_url() {
        var app = Dino.Application.get_default();
        string scheme = app.settings.api_mode == "network" ? "https" : "http";
        return "%s://127.0.0.1:%u".printf(scheme, get_api_port());
    }

    private Soup.Message create_api_message(string method, string path) {
        var msg = new Soup.Message(method, "%s%s".printf(get_api_base_url(), path));
        if (Dino.Application.get_default().settings.api_mode == "network") {
            msg.accept_certificate.connect((cert, errors) => {
                return true;
            });
        }
        return msg;
    }
}

}
