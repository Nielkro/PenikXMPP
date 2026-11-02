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

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/bot_create_dialog.ui")]
public class BotCreateDialog : Adw.Dialog {

    private const string CLOUD_BOT_URL = "https://cloud.dinox.im";

    [GtkChild] private unowned Gtk.Stack content_stack;
    [GtkChild] private unowned Gtk.Button cancel_button;
    [GtkChild] private unowned Gtk.Button create_button;
    [GtkChild] private unowned Gtk.Box avatar_row;
    [GtkChild] private unowned Adw.EntryRow name_entry;
    [GtkChild] private unowned Adw.ComboRow mode_combo;
    [GtkChild] private unowned Adw.ComboRow purpose_combo;
    [GtkChild] private unowned Adw.ComboRow dedicated_provisioning_combo;
    [GtkChild] private unowned Adw.ExpanderRow ejabberd_settings_row;
    [GtkChild] private unowned Adw.EntryRow ejabberd_url_entry;
    [GtkChild] private unowned Adw.EntryRow ejabberd_host_entry;
    [GtkChild] private unowned Adw.EntryRow ejabberd_admin_entry;
    [GtkChild] private unowned Adw.PasswordEntryRow ejabberd_password_entry;
    [GtkChild] private unowned Adw.ActionRow ejabberd_actions_row;
    [GtkChild] private unowned Gtk.Button ejabberd_clear_button;
    [GtkChild] private unowned Gtk.Button ejabberd_test_button;
    [GtkChild] private unowned Gtk.Button ejabberd_save_button;
    [GtkChild] private unowned Adw.EntryRow bot_jid_entry;
    [GtkChild] private unowned Adw.PasswordEntryRow bot_password_entry;
    [GtkChild] private unowned Adw.PasswordEntryRow cloud_token_entry;
    [GtkChild] private unowned Adw.EntryRow webhook_entry;
    [GtkChild] private unowned Gtk.Label token_label;
    [GtkChild] private unowned Gtk.Button copy_token_button;
    [GtkChild] private unowned Gtk.Label mode_description;
    [GtkChild] private unowned Gtk.Label error_label;
    [GtkChild] private unowned Gtk.Label jid_label;
    [GtkChild] private unowned Gtk.Label jid_heading_label;
    [GtkChild] private unowned Gtk.Image avatar_preview;
    [GtkChild] private unowned Gtk.Button avatar_button;
    [GtkChild] private unowned Gtk.Button avatar_remove_button;
    [GtkChild] private unowned Gtk.ListBox permissions_list;

    public signal void bot_created();
    public signal void cloud_bot_added(string token);

    private Soup.Session http;
    private string? created_token = null;
    private string? avatar_base64 = null;
    private string? avatar_mime = null;
    private Gee.HashMap<string, Adw.SwitchRow> permission_switches = new Gee.HashMap<string, Adw.SwitchRow>();
    private Adw.ExpanderRow? permission_expander = null;
    private bool updating_permissions = false;
    private bool ejabberd_settings_loaded = false;
    private const int MAX_BOT_AVATAR_PIXEL = 256;

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

    // Mode values sent to API
    private const string[] MODE_KEYS = { "personal", "dedicated", "cloud" };
    private const string[] PURPOSE_KEYS = { "ai", "telegram", "webhook", "advanced" };
    private const string[] DEDICATED_PROVISIONING_KEYS = { "manual", "ejabberd" };
    private static string[] get_mode_labels() {
        return {
            _("Personal Bot"),
            _("Dedicated Bot Account"),
            _("DinoX-Client CloudBot")
        };
    }
    private static string[] get_mode_descriptions() {
        return {
            _("The Botmother will use your XMPP account to send and receive messages via the local API."),
            _("Uses a separate XMPP account for the bot."),
            _("Paste a management token from cloud.dinox.im. The CloudBot is hosted on the DinoX server; this client only loads and controls it.")
        };
    }
    private static string[] get_purpose_labels() {
        return {
            _("AI Bot"),
            _("Telegram Bridge"),
            _("Webhook / API Bot"),
            _("Advanced / Mixed")
        };
    }
    private static string[] get_purpose_descriptions() {
        return {
            _("Configure AI provider, system prompt, group chat behavior, and optional AI-related webhooks."),
            _("Connect this bot with Telegram and configure bridge or forwarding behavior."),
            _("Expose this bot through API tokens, webhooks, permissions, targets, and local API tests."),
            _("Show all integrations for bots that combine AI, Telegram, webhooks, and API automation.")
        };
    }
    private static string[] get_dedicated_provisioning_labels() {
        return {
            _("Use existing bot account"),
            _("Create account with ejabberd")
        };
    }
    private static string[] get_dedicated_provisioning_descriptions() {
        return {
            _("Use an already registered XMPP account as the bot. No server admin access is required."),
            _("Create a dedicated XMPP account on your server. Requires configured ejabberd admin access.")
        };
    }

    public string account_jid { get; set; default = ""; }

    construct {
        http = new Soup.Session();

        // Setup mode combo. Cloud bots are created by the persistent server runtime, not by the local API.
        var mode_labels = get_mode_labels();
        var mode_model = new Gtk.StringList(null);
        for (int i = 0; i < mode_labels.length; i++) {
            mode_model.append(mode_labels[i]);
        }
        mode_combo.model = mode_model;
        mode_combo.selected = 0;

        var purpose_labels = get_purpose_labels();
        var purpose_model = new Gtk.StringList(null);
        for (int i = 0; i < purpose_labels.length; i++) {
            purpose_model.append(purpose_labels[i]);
        }
        purpose_combo.model = purpose_model;
        purpose_combo.selected = 0;

        var provisioning_labels = get_dedicated_provisioning_labels();
        var provisioning_model = new Gtk.StringList(null);
        for (int i = 0; i < provisioning_labels.length; i++) {
            provisioning_model.append(provisioning_labels[i]);
        }
        dedicated_provisioning_combo.model = provisioning_model;
        dedicated_provisioning_combo.selected = 0;

        // Update description when mode changes
        mode_combo.notify["selected"].connect(() => {
            update_dedicated_fields();
        });
        purpose_combo.notify["selected"].connect(() => {
            update_dedicated_fields();
            apply_purpose_permission_defaults();
        });
        dedicated_provisioning_combo.notify["selected"].connect(update_dedicated_fields);

        // Enable create button when name is not empty
        name_entry.changed.connect(() => {
            update_create_button();
            error_label.visible = false;
        });
        bot_jid_entry.changed.connect(() => {
            update_create_button();
            error_label.visible = false;
        });
        bot_password_entry.changed.connect(() => {
            update_create_button();
            error_label.visible = false;
        });
        cloud_token_entry.changed.connect(() => {
            update_create_button();
            error_label.visible = false;
        });

        cancel_button.clicked.connect(() => {
            if (created_token != null) {
                bot_created();
            }
            close();
        });

        create_button.clicked.connect(() => {
            run_create();
        });

        copy_token_button.clicked.connect(() => {
            if (created_token != null) {
                var clipboard = copy_token_button.get_clipboard();
                clipboard.set_text(created_token);
                copy_token_button.label = _("Copied!");
                GLib.Timeout.add(2000, () => {
                    copy_token_button.label = _("Copy Token");
                    return false;
                });
            }
        });

        avatar_button.clicked.connect(() => {
            choose_avatar();
        });

        avatar_remove_button.clicked.connect(() => {
            avatar_base64 = null;
            avatar_mime = null;
            avatar_preview.icon_name = "avatar-default-symbolic";
            avatar_preview.paintable = null;
            avatar_remove_button.visible = false;
        });

        ejabberd_clear_button.clicked.connect(() => {
            clear_saved_ejabberd_settings();
        });
        ejabberd_test_button.clicked.connect(() => {
            test_saved_ejabberd_connection();
        });
        ejabberd_save_button.clicked.connect(() => {
            save_saved_ejabberd_settings();
        });

        setup_permissions();
        apply_purpose_permission_defaults();
        update_dedicated_fields();
    }

    private void run_create() {
        do_create.begin((obj, res) => {
            do_create.end(res);
        });
    }

    private void choose_avatar() {
        pick_avatar.begin((obj, res) => {
            pick_avatar.end(res);
        });
    }

    private void load_avatar(GLib.File file) {
        load_avatar_file.begin(file, (obj, res) => {
            load_avatar_file.end(res);
        });
    }

    private void load_saved_ejabberd_settings() {
        load_ejabberd_settings.begin((obj, res) => {
            load_ejabberd_settings.end(res);
        });
    }

    private void clear_saved_ejabberd_settings() {
        clear_ejabberd_settings.begin((obj, res) => {
            clear_ejabberd_settings.end(res);
        });
    }

    private void save_saved_ejabberd_settings() {
        save_ejabberd_settings.begin((obj, res) => {
            save_ejabberd_settings.end(res);
        });
    }

    private void test_saved_ejabberd_connection() {
        test_ejabberd_connection.begin((obj, res) => {
            test_ejabberd_connection.end(res);
        });
    }

    private void update_dedicated_fields() {
        string mode = selected_mode();
        string provisioning = selected_dedicated_provisioning();
        bool dedicated = mode == "dedicated";
        bool cloud = mode == "cloud";
        bool manual = dedicated && provisioning == "manual";
        bool ejabberd = dedicated && provisioning == "ejabberd";

        avatar_row.visible = !cloud;
        name_entry.visible = !cloud;
        purpose_combo.visible = !cloud;
        dedicated_provisioning_combo.visible = dedicated;
        ejabberd_settings_row.visible = ejabberd;
        bot_jid_entry.visible = manual;
        bot_jid_entry.title = _("Bot JID");
        bot_password_entry.visible = manual;
        cloud_token_entry.visible = cloud;
        webhook_entry.visible = !cloud;
        permissions_list.visible = !cloud;
        create_button.label = cloud ? _("Add CloudBot") : _("Create");
        if (ejabberd && !ejabberd_settings_loaded) {
            load_saved_ejabberd_settings();
        }
        if (cloud) {
            var descriptions = get_mode_descriptions();
            mode_description.label = descriptions[2];
        } else if (dedicated) {
            var descriptions = get_dedicated_provisioning_descriptions();
            uint sel = dedicated_provisioning_combo.selected;
            mode_description.label = (sel < descriptions.length ? descriptions[sel] : descriptions[0]) + "\n" + purpose_description();
        } else {
            var descriptions = get_mode_descriptions();
            mode_description.label = descriptions[0] + "\n" + purpose_description();
        }
        update_create_button();
    }

    private void update_create_button() {
        bool ready = name_entry.text.strip() != "";
        if (selected_mode() == "cloud") {
            create_button.sensitive = cloud_token_entry.text.strip() != "";
            return;
        }
        if (selected_mode() == "dedicated") {
            if (selected_dedicated_provisioning() == "manual") {
                ready = ready && bot_jid_entry.text.strip() != "" && bot_password_entry.text.strip() != "";
            }
        }
        create_button.sensitive = ready;
    }

    private string selected_mode() {
        uint sel = mode_combo.selected;
        return (sel < MODE_KEYS.length) ? MODE_KEYS[sel] : "personal";
    }

    private string selected_dedicated_provisioning() {
        uint sel = dedicated_provisioning_combo.selected;
        return (sel < DEDICATED_PROVISIONING_KEYS.length) ? DEDICATED_PROVISIONING_KEYS[sel] : "manual";
    }

    private string selected_purpose() {
        uint sel = purpose_combo.selected;
        return (sel < PURPOSE_KEYS.length) ? PURPOSE_KEYS[sel] : "ai";
    }

    private string purpose_description() {
        var descriptions = get_purpose_descriptions();
        uint sel = purpose_combo.selected;
        return sel < descriptions.length ? descriptions[sel] : descriptions[0];
    }

    private async void pick_avatar() {
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
            if (file != null) {
                load_avatar(file);
            }
        } catch (Error e) {
            // User cancelled - that's fine
        }
    }

    private async void load_avatar_file(GLib.File file) {
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
            avatar_mime = "image/png";
            avatar_base64 = GLib.Base64.encode(data);

            // Show preview
            var texture = Dino.Ui.Util.texture_from_pixbuf(pixbuf);
            avatar_preview.paintable = texture;
            avatar_remove_button.visible = true;
        } catch (Error e) {
            warning("Could not load avatar file: %s", e.message);
        } finally {
            try {
                if (stream != null) stream.close();
            } catch (Error e) {
                // Ignore close errors.
            }
        }
    }

    private async void do_create() {
        string mode = selected_mode();
        string provisioning = selected_dedicated_provisioning();

        if (mode == "cloud") {
            yield setup_cloud_bot();
            return;
        }

        string name = name_entry.text.strip();
        if (name == "") return;

        content_stack.visible_child_name = "creating";
        create_button.sensitive = false;

        try {
            if (!(yield ensure_api_available())) {
                warning("Botmother: API is not available on port %u", get_api_port());
                show_error(_("Botmother API not running (port %u)").printf(get_api_port()));
                content_stack.visible_child_name = "form";
                create_button.sensitive = true;
                return;
            }

            // Build JSON body
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("name");
            builder.add_string_value(name);
            builder.set_member_name("mode");
            builder.add_string_value(mode);
            builder.set_member_name("purpose");
            builder.add_string_value(selected_purpose());
            if (mode == "dedicated") {
                builder.set_member_name("provisioning");
                builder.add_string_value(provisioning);
                if (provisioning == "manual") {
                    builder.set_member_name("bot_jid");
                    builder.add_string_value(bot_jid_entry.text.strip());
                    builder.set_member_name("bot_password");
                    builder.add_string_value(bot_password_entry.text.strip());
                }
            }
            if (account_jid != "") {
                builder.set_member_name("account");
                builder.add_string_value(account_jid);
            }
            string webhook = webhook_entry.text.strip();
            if (webhook != "") {
                builder.set_member_name("webhook_url");
                builder.add_string_value(webhook);
            }
            builder.set_member_name("permissions");
            builder.add_string_value(collect_permissions());
            if (avatar_base64 != null) {
                builder.set_member_name("avatar");
                builder.add_string_value(avatar_base64);
                builder.set_member_name("avatar_type");
                builder.add_string_value(avatar_mime ?? "image/png");
            }
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string body = gen.to_data(null);

            var msg = create_api_message("POST", "/bot/create");
            msg.set_request_body_from_bytes("application/json", new GLib.Bytes(body.data));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            if (msg.status_code == 200) {
                var parser = new Json.Parser();
                Util.load_json_response(parser, response);
                var root = parser.get_root().get_object();

                // Response wrapped by send_success: {"ok":true,"result":{...}}
                Json.Object result_obj = root;
                if (root.has_member("result")) {
                    var result_node = root.get_member("result");
                    if (result_node.get_node_type() == Json.NodeType.OBJECT) {
                        result_obj = result_node.get_object();
                    }
                }

                if (result_obj.has_member("token")) {
                    created_token = result_obj.get_string_member("token");
                    token_label.label = created_token;
                } else {
                    token_label.label = _("(token not returned)");
                }

                // Show JID for dedicated bots
                if (result_obj.has_member("jid")) {
                    string bot_jid = result_obj.get_string_member("jid");
                    if (bot_jid != null && bot_jid != "") {
                        jid_label.label = bot_jid;
                        jid_label.visible = true;
                        jid_heading_label.visible = true;
                    }
                }

                cancel_button.label = _("Done");
                create_button.visible = false;
                content_stack.visible_child_name = "success";
            } else {
                warning("Botmother: API returned %u", msg.status_code);
                show_error(_("Could not create Botmother: %s").printf(extract_api_error(response, msg.status_code)));
                content_stack.visible_child_name = "form";
                create_button.sensitive = true;
            }
        } catch (Error e) {
            warning("Botmother: Create error: %s", e.message);
            show_error(_("Could not create Botmother: %s").printf(e.message));
            content_stack.visible_child_name = "form";
            create_button.sensitive = true;
        }
    }

    private async void setup_cloud_bot() {
        string token = cloud_token_entry.text.strip();
        if (token == "") {
            show_error(_("Enter a management token."));
            return;
        }

        content_stack.visible_child_name = "creating";
        create_button.sensitive = false;

        try {
            var msg = new Soup.Message("GET", "%s/api/v1/bot/me".printf(CLOUD_BOT_URL));
            msg.request_headers.append("Authorization", "Bearer %s".printf(token));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code != 200) {
                show_error(_("Could not load CloudBot: %s").printf(extract_api_error(response, msg.status_code)));
                content_stack.visible_child_name = "form";
                create_button.sensitive = true;
                return;
            }
            string owner_jid = parse_cloud_owner_jid(response);
            if (owner_jid == "") {
                show_error(_("Invalid response from cloud bot service."));
                content_stack.visible_child_name = "form";
                create_button.sensitive = true;
                return;
            }
            if (account_jid != "" && owner_jid != account_jid) {
                show_error(_("This CloudBot belongs to %s, not to %s.").printf(owner_jid, account_jid));
                content_stack.visible_child_name = "form";
                create_button.sensitive = true;
                return;
            }
            cloud_bot_added(token);
            close();
        } catch (Error e) {
            warning("BotCreate: CloudBot setup error: %s", e.message);
            show_error(_("Could not load CloudBot: %s").printf(e.message));
            content_stack.visible_child_name = "form";
            create_button.sensitive = true;
        }
    }

    private void show_error(string message) {
        error_label.label = message;
        error_label.visible = true;
    }

    private async void clear_ejabberd_settings() {
        var alert = new Adw.AlertDialog(
            _("Clear Server Settings?"),
            _("This will remove the saved ejabberd API credentials.")
        );
        alert.add_response("cancel", _("Cancel"));
        alert.add_response("clear", _("Clear"));
        alert.set_response_appearance("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        alert.default_response = "cancel";

        string response = yield alert.choose(this, null);
        if (response != "clear") return;

        try {
            if (!(yield ensure_api_available())) {
                ejabberd_actions_row.subtitle = _("Botmother API not running (port %u)").printf(get_api_port());
                return;
            }
            string body = "{\"api_url\":\"\",\"host\":\"\",\"admin_jid\":\"\",\"admin_password\":\"\"}";
            var msg = create_api_message("POST", "/bot/ejabberd/settings");
            msg.set_request_body_from_bytes("application/json", new Bytes(body.data));
            yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            ejabberd_url_entry.text = "";
            ejabberd_host_entry.text = "";
            ejabberd_admin_entry.text = "";
            ejabberd_password_entry.text = "";
            ejabberd_actions_row.subtitle = _("Not configured");
            ejabberd_settings_loaded = true;
        } catch (Error e) {
            warning("BotCreate: Failed to clear ejabberd settings: %s", e.message);
            ejabberd_actions_row.subtitle = _("Error: %s").printf(e.message);
        }
    }

    private async void load_ejabberd_settings() {
        try {
            if (!(yield ensure_api_available(false))) return;
            var msg = create_api_message("GET", "/bot/ejabberd/settings");
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            if (msg.status_code == 200) {
                var parser = new Json.Parser();
                Util.load_json_response(parser, response);
                var root = parser.get_root().get_object();
                Json.Object data = root;
                if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                    data = root.get_object_member("result");
                }
                if (data.has_member("api_url")) ejabberd_url_entry.text = data.get_string_member("api_url");
                if (data.has_member("host")) ejabberd_host_entry.text = data.get_string_member("host");
                if (data.has_member("admin_jid")) ejabberd_admin_entry.text = data.get_string_member("admin_jid");
                if (data.has_member("admin_password")) {
                    string pw = data.get_string_member("admin_password");
                    if (pw != "********") {
                        ejabberd_password_entry.text = pw;
                    }
                }
                if (data.has_member("configured") && data.get_boolean_member("configured")) {
                    ejabberd_actions_row.subtitle = _("Configured");
                } else {
                    ejabberd_actions_row.subtitle = _("Not configured");
                }
                ejabberd_settings_loaded = true;
            }
        } catch (Error e) {
            warning("BotCreate: Failed to load ejabberd settings: %s", e.message);
        }
    }

    private async void save_ejabberd_settings() {
        try {
            if (!(yield ensure_api_available())) {
                ejabberd_actions_row.subtitle = _("Botmother API not running (port %u)").printf(get_api_port());
                return;
            }
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("api_url");
            builder.add_string_value(ejabberd_url_entry.text.strip());
            builder.set_member_name("host");
            builder.add_string_value(ejabberd_host_entry.text.strip());
            builder.set_member_name("admin_jid");
            builder.add_string_value(ejabberd_admin_entry.text.strip());
            string pw = ejabberd_password_entry.text.strip();
            if (pw != "") {
                builder.set_member_name("admin_password");
                builder.add_string_value(pw);
            }
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string body = gen.to_data(null);

            var msg = create_api_message("POST", "/bot/ejabberd/settings");
            msg.set_request_body_from_bytes("application/json", new Bytes(body.data));
            yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            if (msg.status_code == 200) {
                ejabberd_actions_row.subtitle = _("Saved");
                ejabberd_settings_loaded = false;
                Timeout.add(2000, () => {
                    load_saved_ejabberd_settings();
                    return false;
                });
            } else {
                ejabberd_actions_row.subtitle = _("Save failed");
            }
        } catch (Error e) {
            warning("BotCreate: Failed to save ejabberd settings: %s", e.message);
            ejabberd_actions_row.subtitle = _("Error: %s").printf(e.message);
        }
    }

    private async void test_ejabberd_connection() {
        ejabberd_actions_row.subtitle = _("Testing...");
        ejabberd_test_button.sensitive = false;
        try {
            if (!(yield ensure_api_available())) {
                ejabberd_actions_row.subtitle = _("Botmother API not running (port %u)").printf(get_api_port());
                ejabberd_test_button.sensitive = true;
                return;
            }

            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("api_url");
            builder.add_string_value(ejabberd_url_entry.text.strip());
            builder.set_member_name("host");
            builder.add_string_value(ejabberd_host_entry.text.strip());
            builder.set_member_name("admin_jid");
            builder.add_string_value(ejabberd_admin_entry.text.strip());
            string pw = ejabberd_password_entry.text.strip();
            if (pw != "") {
                builder.set_member_name("admin_password");
                builder.add_string_value(pw);
            }
            builder.end_object();

            var gen = new Json.Generator();
            gen.root = builder.get_root();
            string body = gen.to_data(null);

            var msg = create_api_message("POST", "/bot/ejabberd/test");
            msg.set_request_body_from_bytes("application/json", new Bytes(body.data));
            Bytes response = yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);

            if (msg.status_code == 200) {
                var parser = new Json.Parser();
                Util.load_json_response(parser, response);
                var root = parser.get_root().get_object();
                Json.Object data = root;
                if (root.has_member("result") && root.get_member("result").get_node_type() == Json.NodeType.OBJECT) {
                    data = root.get_object_member("result");
                }
                string resp = data.has_member("response") ? data.get_string_member("response") : "ok";
                ejabberd_actions_row.subtitle = _("Connected: %s").printf(resp);
            } else {
                ejabberd_actions_row.subtitle = _("Failed: %s").printf(extract_api_error(response, msg.status_code));
            }
        } catch (Error e) {
            ejabberd_actions_row.subtitle = _("Error: %s").printf(e.message);
        }
        ejabberd_test_button.sensitive = true;
    }

    private string extract_api_error(Bytes response, uint status_code) {
        try {
            var parser = new Json.Parser();
            Util.load_json_response(parser, response);
            var root = parser.get_root().get_object();
            if (root.has_member("description")) {
                string description = root.get_string_member("description");
                if (description != "") return description;
            }
            if (root.has_member("error")) {
                string error = root.get_string_member("error");
                if (error != "") return error;
            }
        } catch (Error e) {
            // Fall through to the generic status message.
        }
        return _("HTTP status %u").printf(status_code);
    }

    private string parse_cloud_owner_jid(Bytes response) throws Error {
        var parser = new Json.Parser();
        Util.load_json_response(parser, response);
        var root = parser.get_root().get_object();
        if (!root.has_member("bot") || root.get_member("bot").get_node_type() != Json.NodeType.OBJECT) {
            return "";
        }
        var bot = root.get_object_member("bot");
        return bot.has_member("owner_jid") ? bot.get_string_member("owner_jid").strip() : "";
    }

    private void setup_permissions() {
        var expander = new Adw.ExpanderRow();
        permission_expander = expander;
        expander.title = _("API Permissions");
        expander.subtitle = _("All permissions");

        foreach (string key in PERMISSION_KEYS) {
            var row = new Adw.SwitchRow();
            row.title = permission_title(key);
            row.subtitle = permission_description(key);
            row.active = key == "all";
            permission_switches[key] = row;
            expander.add_row(row);
        }

        foreach (string key in PERMISSION_KEYS) {
            Adw.SwitchRow row = permission_switches[key];
            row.notify["active"].connect(() => {
                if (updating_permissions) return;

                updating_permissions = true;
                if (key == "all" && row.active) {
                    foreach (string other_key in PERMISSION_KEYS) {
                        if (other_key != "all") permission_switches[other_key].active = false;
                    }
                } else if (key != "all" && row.active) {
                    permission_switches["all"].active = false;
                } else if (!permission_switches["all"].active && !has_selected_specific_permission()) {
                    permission_switches["all"].active = true;
                }
                expander.subtitle = format_permissions_summary();
                updating_permissions = false;
            });
        }

        permissions_list.append(expander);
    }

    private void apply_purpose_permission_defaults() {
        if (permission_switches.size == 0) return;

        updating_permissions = true;
        foreach (string key in PERMISSION_KEYS) {
            permission_switches[key].active = false;
        }

        switch (selected_purpose()) {
            case "ai":
                permission_switches["receive_updates"].active = true;
                permission_switches["send_message"].active = true;
                permission_switches["muc_join"].active = true;
                permission_switches["muc_send"].active = true;
                permission_switches["webhook"].active = true;
                break;
            case "telegram":
                permission_switches["receive_updates"].active = true;
                permission_switches["send_message"].active = true;
                permission_switches["webhook"].active = true;
                break;
            case "webhook":
                permission_switches["send_message"].active = true;
                permission_switches["receive_updates"].active = true;
                permission_switches["webhook"].active = true;
                break;
            default:
                permission_switches["all"].active = true;
                break;
        }
        updating_permissions = false;
        if (permission_expander != null) permission_expander.subtitle = format_permissions_summary();
    }

    private string collect_permissions() {
        if (permission_switches["all"].active) return "all";

        var selected = new Gee.ArrayList<string>();
        foreach (string key in PERMISSION_KEYS) {
            if (key == "all") continue;
            if (permission_switches[key].active) selected.add(key);
        }

        if (selected.size == 0) return "all";
        return Dino.Ui.Util.join_strings(",", selected);
    }

    private bool has_selected_specific_permission() {
        foreach (string key in PERMISSION_KEYS) {
            if (key != "all" && permission_switches[key].active) return true;
        }
        return false;
    }

    private string format_permissions_summary() {
        if (permission_switches["all"].active) return _("All permissions");

        int count = 0;
        foreach (string key in PERMISSION_KEYS) {
            if (key != "all" && permission_switches[key].active) count++;
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

    private async bool ensure_api_available(bool start_if_disabled = true) {
        if (!start_if_disabled) return yield probe_api();

        var app = Dino.Application.get_default();
        if (!app.settings.bot_features_enabled) {
            app.settings.bot_features_enabled = true;
        }

        for (int i = 0; i < 12; i++) {
            if (yield probe_api()) return true;
            yield wait_ms(150);
        }
        return false;
    }

    private async bool probe_api() {
        try {
            var msg = create_api_message("GET", "/health");
            yield http.send_and_read_async(msg, GLib.Priority.DEFAULT, null);
            return msg.status_code == 200;
        } catch (Error e) {
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
