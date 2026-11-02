using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;
using Gdk;

[GtkTemplate (ui = "/im/dinox/dinox/preferences_window/account_preferences_subpage.ui")]
public class Dino.Ui.AccountPreferencesSubpage : Adw.NavigationPage {

    [GtkChild] public unowned Adw.HeaderBar headerbar;
    [GtkChild] public unowned AvatarPicture avatar;
    [GtkChild] public unowned Adw.ActionRow xmpp_address;
    [GtkChild] public unowned Adw.EntryRow local_alias;
    [GtkChild] public unowned Adw.ActionRow password_change;
    [GtkChild] public unowned Adw.ComboRow timezone_row;
    [GtkChild] public unowned Adw.ActionRow connection_status;
    [GtkChild] public unowned Button enter_password_button;
    [GtkChild] public unowned Button trust_certificate_button;
    [GtkChild] public unowned Box avatar_menu_box;
    [GtkChild] public unowned Button edit_avatar_button;
    [GtkChild] public unowned Button remove_avatar_button;
    [GtkChild] public unowned Widget button_container;
    [GtkChild] public unowned Button remove_account_button;
    [GtkChild] public unowned Button disable_account_button;
    [GtkChild] public unowned Adw.EntryRow custom_host_entry;
    [GtkChild] public unowned Adw.EntryRow custom_port_entry;
    [GtkChild] public unowned Adw.SwitchRow proxy_enable_row;
    [GtkChild] public unowned Adw.EntryRow proxy_host_entry;
    [GtkChild] public unowned Adw.EntryRow proxy_port_entry;
    [GtkChild] public unowned Adw.EntryRow proxy_user_entry;
    [GtkChild] public unowned Adw.PasswordEntryRow proxy_pass_entry;
    [GtkChild] public unowned Adw.ActionRow proxy_status_row;
    [GtkChild] public unowned Adw.PreferencesGroup proxy_group;
    [GtkChild] private unowned Adw.ComboRow login_protection_mode;
    [GtkChild] private unowned Adw.ActionRow login_protection_server;
    [GtkChild] private unowned Gtk.Image login_protection_icon;
    [GtkChild] private unowned Gtk.Spinner login_protection_spinner;
    [GtkChild] private unowned Adw.ActionRow login_protection_feedback;
    [GtkChild] private unowned Gtk.Button login_protection_check;
    [GtkChild] private unowned Adw.ActionRow login_protection_reset_row;
    [GtkChild] private unowned Gtk.Button login_protection_reset;
    [GtkChild] private unowned Adw.ActionRow login_protection_status;
    [GtkChild] private unowned Adw.SwitchRow allow_plain_switch;
    [GtkChild] public unowned Adw.PreferencesGroup dns_security_group;
    [GtkChild] public unowned Adw.ComboRow dns_security_mode;
    [GtkChild] public unowned Adw.EntryRow dns_security_resolver;
    [GtkChild] public unowned Adw.ActionRow dns_security_status;
    [GtkChild] public unowned Adw.ActionRow dns_security_help;
    [GtkChild] public unowned Button dns_security_apply;

    [GtkChild] public unowned Adw.EntryRow vcard_fn;
    [GtkChild] public unowned Adw.EntryRow vcard_nickname;
    [GtkChild] public unowned Adw.ComboRow vcard_gender;
    [GtkChild] public unowned Adw.EntryRow vcard_bday;
    [GtkChild] public unowned Adw.EntryRow vcard_adr_street;
    [GtkChild] public unowned Adw.EntryRow vcard_adr_pcode;
    [GtkChild] public unowned Adw.EntryRow vcard_adr_city;
    [GtkChild] public unowned Adw.EntryRow vcard_adr_region;
    [GtkChild] public unowned Adw.EntryRow vcard_adr_country;
    [GtkChild] public unowned Adw.EntryRow vcard_email;
    [GtkChild] public unowned Adw.EntryRow vcard_impp;
    [GtkChild] public unowned Adw.SwitchRow vcard_public_access;
    [GtkChild] public unowned Adw.SwitchRow vcard_share_with_contacts;
    [GtkChild] public unowned Adw.EntryRow vcard_phone;
    [GtkChild] public unowned Adw.EntryRow vcard_title;
    [GtkChild] public unowned Adw.EntryRow vcard_role;
    [GtkChild] public unowned Adw.EntryRow vcard_org;
    [GtkChild] public unowned Adw.EntryRow vcard_tz;
    [GtkChild] public unowned Adw.EntryRow vcard_url;
    [GtkChild] public unowned Adw.EntryRow vcard_desc;
    [GtkChild] public unowned Button save_vcard_button;
    [GtkChild] public unowned Adw.ActionRow profile_status_row;
    [GtkChild] public unowned Adw.PreferencesGroup profile_group;

    // Server Certificate section
    [GtkChild] public unowned Adw.PreferencesGroup cert_group;
    [GtkChild] public unowned Adw.ActionRow cert_status_row;
    [GtkChild] public unowned Adw.ActionRow cert_issuer_row;
    [GtkChild] public unowned Adw.ActionRow cert_validity_row;
    [GtkChild] public unowned Adw.ActionRow cert_fingerprint_row;
    [GtkChild] public unowned Button unpin_certificate_button;
    [GtkChild] public unowned Adw.ActionRow manage_botmothers_row;
    [GtkChild] public unowned Adw.ActionRow manage_mqtt_bot_row;

    public Account account { get { return model.selected_account.account; } }
    public ViewModel.PreferencesDialog model { get; set; }

    private Binding[] bindings = new Binding[0];
    private ulong alias_entry_changed = 0;
    private ulong custom_host_entry_changed = 0;
    private ulong custom_port_entry_changed = 0;
    private ulong proxy_enable_row_changed = 0;
    private ulong proxy_host_entry_changed = 0;
    private ulong proxy_port_entry_changed = 0;
    private ulong proxy_user_entry_changed = 0;
    private ulong proxy_pass_entry_changed = 0;
    private ulong timezone_row_changed = 0;
    private ulong login_protection_mode_changed = 0;
    private bool updating_login_protection = false;
    private bool login_check_disconnecting = false;
    private bool login_check_pending = false;
    private uint login_check_generation = 0;
    private uint login_check_start_idle = 0;
    private ulong allow_plain_changed = 0;
    private Cancellable? proxy_check_cancel = null;
    private bool ignore_proxy_toggle = false;
    private ulong selected_account_model_connection = 0;
    private ulong selected_account_connection_error = 0;
    private ulong selected_account_connection_state = 0;
    private ulong selected_account_avatar_image_bytes = 0;
    private ViewModel.AvatarPictureTileModel? selected_account_avatar_model = null;
    private ViewModel.PreferencesDialog? selected_account_model_owner = null;
    private ViewModel.AccountDetails? selected_account_connection_owner = null;
    private uint profile_generation = 0;
    private Cancellable? profile_cancel = null;
    private bool profile_saving = false;

    construct {
        title = _("Account");
        headerbar.show_title = false;
        button_container.layout_manager = new NaturalDirectionBoxLayout((BoxLayout)button_container.layout_manager);

        // Clear focus when page is unmapped to prevent GTK
        // "GtkText - did not receive a focus-out event" warnings
        this.unmap.connect(() => {
            var root = this.get_root() as Gtk.Root;
            if (root != null) root.set_focus(null);
        });

        edit_avatar_button.clicked.connect(() => {
            show_select_avatar();
        });
        remove_avatar_button.clicked.connect(() => {
            model.remove_avatar(account);
        });
        disable_account_button.clicked.connect(() => {
            model.enable_disable_account(account);
        });
        remove_account_button.clicked.connect(() => {
            show_remove_account_dialog();
        });
        manage_botmothers_row.activatable_widget = new Label("");
        manage_botmothers_row.activated.connect(() => {
            var dialog = new BotManagerDialog();
            dialog.account_jid = account.bare_jid.to_string();
            present_in_context(dialog);
        });
        manage_mqtt_bot_row.activatable_widget = new Label("");
        manage_mqtt_bot_row.activated.connect(() => {
            var app = Dino.Application.get_default();
            var win = get_parent_window();
            if (app == null || win == null) return;
            app.open_account_mqtt_manager(account, win);
        });
        password_change.activatable_widget = new Label("");
        password_change.activated.connect(() => {
            var dialog = new ChangePasswordDialog(model.get_change_password_dialog_model());
            present_in_context(dialog);
        });

        // Timezone Setup (Model Initialization)
        string[] tz_labels = { _("System Timezone"), _("Disabled (Privacy)"), _("UTC") };
        var tz_model = new Gtk.StringList(null);
        foreach (string l in tz_labels) tz_model.append(l);
        timezone_row.model = tz_model;

        enter_password_button.clicked.connect(() => {
            var dialog = new Adw.AlertDialog(_("Enter password"), account.bare_jid.to_string());
            var password = new PasswordEntry() { show_peek_icon=true };
            dialog.response.connect((response) => {
                if (response == "connect") {
                    account.password = password.text;
                    model.reconnect_account(account);
                }
            });
            dialog.default_response = "connect";
            dialog.extra_child = password;
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("connect", _("Connect"));

            present_in_context(dialog);
        });
        
        trust_certificate_button.clicked.connect(() => {
            show_certificate_dialog();
        });

        unpin_certificate_button.clicked.connect(() => {
            var dialog = new Adw.AlertDialog(
                _("Remove pinned certificate for %s?").printf(account.domainpart),
                _("The server will need to present a valid CA-signed certificate, or you will be asked to trust it again.")
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("remove", _("Remove"));
            dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.response.connect((response) => {
                if (response == "remove") {
                    model.stream_interactor.connection_manager.unpin_certificate(account.domainpart);
                    model.reconnect_account(account);
                    update_certificate_info();
                }
            });
            present_in_context(dialog);
        });

        save_vcard_button.clicked.connect(() => {
            save_account_vcard();
        });

        var dns_choices = new Gtk.StringList(null);
        dns_choices.append(_("Off"));
        dns_choices.append(_("Check supporting domains"));
        dns_choices.append(_("Require DNSSEC and DANE"));
        dns_security_mode.model = dns_choices;
        dns_security_mode.notify["selected"].connect(update_dns_security_help);
        update_dns_security_help();
        dns_security_apply.clicked.connect(() => {
            if (model == null || model.selected_account == null) return;
            Account selected = account;
            try {
                model.stream_interactor.connection_manager.apply_dns_security(selected,
                    (DnsSecurity.Mode) dns_security_mode.selected, dns_security_resolver.text);
                update_dns_security_status();
            } catch (Error error) {
                dns_security_status.subtitle = dns_security_error_text(error);
            }
        });
        login_protection_check.clicked.connect(() => {
            if (model == null || model.selected_account == null || !account.enabled || login_check_pending) return;
            queue_login_protection_check();
        });
        login_protection_reset.clicked.connect(() => {
            if (model == null || model.selected_account == null || !account.enabled || login_check_pending) return;
            // Explicit recovery for a previously required policy whose server
            // stopped supporting it. Never weaken that policy automatically.
            account.require_channel_binding = false;
            queue_login_protection_check();
        });

        vcard_public_access.notify["active"].connect(() => {
            vcard_share_with_contacts.sensitive = !vcard_public_access.active;
            if (vcard_public_access.active) {
                vcard_share_with_contacts.active = true;
            }
        });

        this.notify["model"].connect(() => {
            if (selected_account_model_connection != 0 && selected_account_model_owner != null) {
                if (SignalHandler.is_connected(selected_account_model_owner, selected_account_model_connection)) {
                    SignalHandler.disconnect(selected_account_model_owner, selected_account_model_connection);
                }
            }
            selected_account_model_connection = 0;
            selected_account_model_owner = null;

            if (model == null) {
                clear_selected_account_handlers();
                return;
            }

            selected_account_model_connection = model.notify["selected-account"].connect(() => {
                refresh_selected_account();
            });
            selected_account_model_owner = model;
            refresh_selected_account();
        });

        this.destroy.connect(() => {
            clear_selected_account_handlers();
            if (selected_account_model_connection != 0 && selected_account_model_owner != null) {
                if (SignalHandler.is_connected(selected_account_model_owner, selected_account_model_connection)) {
                    SignalHandler.disconnect(selected_account_model_owner, selected_account_model_connection);
                }
            }
            selected_account_model_connection = 0;
            selected_account_model_owner = null;
        });
    }

    private void refresh_selected_account() {
        clear_selected_account_handlers();

        if (model == null || model.selected_account == null) return;

        selected_account_connection_owner = model.selected_account;
        dns_security_group.visible = DnsSecurity.Configuration.supported();
        try {
            dns_security_mode.selected = (uint) model.stream_interactor.connection_manager.get_dns_security_mode(account);
            if (dns_security_mode.selected != 0) dns_security_group.visible = true;
        } catch (Error error) {
            // Do not display an invalid persisted policy as an applied "Off".
            dns_security_mode.selected = Gtk.INVALID_LIST_POSITION;
            dns_security_group.visible = true;
        }
        dns_security_resolver.text = model.stream_interactor.connection_manager.get_dns_security_resolver(account);
        update_dns_security_status();
        remove_account_button.sensitive = true;

        avatar.model = model.selected_account.avatar_model;
        xmpp_address.subtitle = account.bare_jid.to_string();

        local_alias.text = account.alias ?? "";
        alias_entry_changed = local_alias.changed.connect(() => {
            account.alias = local_alias.text;
        });

        // Populate and bind custom host/port fields
        custom_host_entry.text = account.custom_host ?? "";
        custom_port_entry.text = account.custom_port > 0 ? account.custom_port.to_string() : "";

        custom_host_entry_changed = custom_host_entry.changed.connect(() => {
            account.custom_host = custom_host_entry.text.length > 0 ? custom_host_entry.text : null;
        });

        custom_port_entry_changed = custom_port_entry.changed.connect(() => {
            int port = parse_port_or_zero(custom_port_entry.text);
            account.custom_port = (port > 0 && port <= 65535) ? port : 0;
        });

        // Populate and bind proxy fields
        string[] tz_values = { "system", "disabled", "UTC" };
        string saved_tz = model.db.account_settings.get_value(account.id, "timezone") ?? "system";
        int tz_index = 0;
        for (int i = 0; i < tz_values.length; i++) {
            if (tz_values[i] == saved_tz) tz_index = i;
        }
        timezone_row.selected = (uint) tz_index;

        timezone_row_changed = timezone_row.notify["selected"].connect(() => {
            int idx = (int) timezone_row.selected;
            model.db.account_settings.upsert()
                .value(model.db.account_settings.account_id, account.id, true)
                .value(model.db.account_settings.key, "timezone", true)
                .value(model.db.account_settings.value, tz_values[idx])
                .perform();
        });

        bool is_tor_managed = (account.proxy_type == "tor");
        // SOCKS5 switch only reflects standalone SOCKS5, NOT Tor
        proxy_enable_row.active = (account.proxy_type == "socks5");

        // Fields ALWAYS show saved SOCKS5 config and are ALWAYS editable.
        // Switch only controls whether the proxy is USED.
        string? saved_host = model.db.account_settings.get_value(account.id, "socks5_host");
        string? saved_port = model.db.account_settings.get_value(account.id, "socks5_port");
        string? saved_user = model.db.account_settings.get_value(account.id, "socks5_user");
        string? saved_pass = model.db.account_settings.get_value(account.id, "socks5_pass");
        // If currently active as socks5, also sync from live account data
        if (account.proxy_type == "socks5") {
            if (saved_host == null && account.proxy_host != null) saved_host = account.proxy_host;
            if (saved_port == null && account.proxy_port > 0) saved_port = account.proxy_port.to_string();
            if (saved_user == null && account.proxy_user != null) saved_user = account.proxy_user;
            if (saved_pass == null && account.proxy_pass != null) saved_pass = account.proxy_pass;
        }
        proxy_host_entry.text = saved_host ?? "";
        proxy_port_entry.text = saved_port ?? "";
        proxy_user_entry.text = saved_user ?? "";
        proxy_pass_entry.text = saved_pass ?? "";
        proxy_host_entry.sensitive = true;
        proxy_port_entry.sensitive = true;
        proxy_user_entry.visible = true;
        proxy_pass_entry.visible = true;
        proxy_user_entry.sensitive = true;
        proxy_pass_entry.sensitive = true;
        if (is_tor_managed) {
            proxy_enable_row.subtitle = _("Tor proxy active (global setting)");
        } else {
            proxy_enable_row.subtitle = "";
        }

        Account proxy_account = account;
        ViewModel.PreferencesDialog proxy_model = model;
        proxy_enable_row_changed = proxy_enable_row.notify["active"].connect(() => {
            // AdwSwitchRow can deliver the rollback notification after this
            // handler returns. Consume it instead of treating it as a user action.
            if (ignore_proxy_toggle) {
                ignore_proxy_toggle = false;
                return;
            }
            if (model != proxy_model || proxy_model.selected_account == null ||
                    proxy_model.selected_account.account != proxy_account) return;

            if (proxy_enable_row.active) {
                if (!apply_socks5_config_to_account(proxy_account)) {
                    ignore_proxy_toggle = true;
                    proxy_enable_row.active = false;
                    return;
                }
                proxy_enable_row.subtitle = "";
            } else {
                var provider = proxy_model.stream_interactor.get_module<Dino.Plugins.AccountProxyProvider>(
                    new SimpleIdentity("tor-manager"));
                if (provider != null && provider.proxy_enabled) {
                    if (!apply_runtime_proxy_if_ready("tor-manager", proxy_account, proxy_model)) {
                        // Global Tor is requested but unavailable. Keep the
                        // existing SOCKS5 override instead of reconnecting direct.
                        ignore_proxy_toggle = true;
                        proxy_enable_row.active = true;
                        proxy_enable_row.subtitle = _("Tor is not connected yet. Wait until Tor is connected before disabling SOCKS5.");
                        return;
                    }
                    proxy_enable_row.subtitle = _("Tor proxy active (global setting)");
                } else {
                    proxy_account.proxy_type = "none";
                    proxy_account.proxy_host = null;
                    proxy_account.proxy_port = 0;
                    proxy_enable_row.subtitle = "";
                }
            }
            check_proxy_status();
            if (proxy_account.enabled) {
                proxy_model.reconnect_account(proxy_account);
            }
        });

        proxy_host_entry_changed = proxy_host_entry.changed.connect(() => {
            model.db.account_settings.upsert()
                .value(model.db.account_settings.account_id, account.id, true)
                .value(model.db.account_settings.key, "socks5_host", true)
                .value(model.db.account_settings.value, proxy_host_entry.text)
                .perform();
            if (account.proxy_type == "socks5") {
                apply_socks5_config_to_account();
            }
            check_proxy_status();
        });

        proxy_port_entry_changed = proxy_port_entry.changed.connect(() => {
            model.db.account_settings.upsert()
                .value(model.db.account_settings.account_id, account.id, true)
                .value(model.db.account_settings.key, "socks5_port", true)
                .value(model.db.account_settings.value, proxy_port_entry.text)
                .perform();
            if (account.proxy_type == "socks5") {
                apply_socks5_config_to_account();
            }
            check_proxy_status();
        });

        proxy_user_entry_changed = proxy_user_entry.changed.connect(() => {
            model.db.account_settings.upsert()
                .value(model.db.account_settings.account_id, account.id, true)
                .value(model.db.account_settings.key, "socks5_user", true)
                .value(model.db.account_settings.value, proxy_user_entry.text)
                .perform();
            if (account.proxy_type == "socks5") {
                account.proxy_user = proxy_user_entry.text.length > 0 ? proxy_user_entry.text : null;
            }
        });

        proxy_pass_entry_changed = proxy_pass_entry.changed.connect(() => {
            model.db.account_settings.upsert()
                .value(model.db.account_settings.account_id, account.id, true)
                .value(model.db.account_settings.key, "socks5_pass", true)
                .value(model.db.account_settings.value, proxy_pass_entry.text)
                .perform();
            if (account.proxy_type == "socks5") {
                account.proxy_pass = proxy_pass_entry.text.length > 0 ? proxy_pass_entry.text : null;
            }
        });

        allow_plain_switch.active = account.allow_plain;
        Account login_account = account;
        var login_model = model;
        allow_plain_changed = allow_plain_switch.notify["active"].connect(() => {
            if (login_account.scram_seen || login_account.require_channel_binding ||
                login_account.allow_plain == allow_plain_switch.active) return;
            login_account.allow_plain = allow_plain_switch.active;
            if (login_account.enabled) login_model.reconnect_account(login_account);
        });
        bindings += account.bind_property("scram-seen", allow_plain_switch, "active", BindingFlags.SYNC_CREATE,
            (binding, from, ref to) => { to = !(bool) from && account.allow_plain; return true; });
        bindings += account.bind_property("scram-seen", allow_plain_switch, "sensitive", BindingFlags.SYNC_CREATE,
            (binding, from, ref to) => { to = !(bool) from && !account.require_channel_binding; return true; });
        bindings += account.bind_property("require-channel-binding", allow_plain_switch, "sensitive", BindingFlags.SYNC_CREATE,
            (binding, from, ref to) => { to = !(bool) from && !account.scram_seen; return true; });
        bindings += account.bind_property("scram-seen", allow_plain_switch, "subtitle", BindingFlags.SYNC_CREATE,
            (binding, from, ref to) => {
                to = (bool) from
                    ? _("SCRAM has been confirmed for this account. PLAIN remains blocked, even if it was previously allowed.")
                    : _("Only for servers without SCRAM. Sends your password inside the TLS connection. Disabled by default.");
                return true;
            });

        // Preserve the existing per-account policy, with explicit choices
        // instead of an off switch which still permits automatic protection.
        login_protection_mode_changed = login_protection_mode.notify["selected"].connect(() => {
            if (updating_login_protection || login_check_pending || login_check_start_idle != 0 || account != login_account) return;
            uint selected = login_protection_mode.selected;
            var manager = login_model.stream_interactor.connection_manager;
            var stream = manager.get_stream(login_account) as TlsXmppStream;
            bool accepted = Util.apply_verified_login_protection_mode(login_account, selected,
                manager.get_state(login_account), stream != null && stream.has_tls_transport(),
                stream != null ? stream.get_flag(Sasl.Flag.IDENTITY) : null, manager.get_error(login_account));
            update_login_protection_status();
            if (accepted) {
                queue_login_protection_check();
            } else {
                show_login_protection_feedback(false, _("Not applied. Extra login protection has not been confirmed for this account."));
            }
        });

        load_account_vcard();
        check_proxy_status();

        bindings += account.bind_property("enabled", disable_account_button, "label", BindingFlags.SYNC_CREATE, (binding, from, ref to) => {
            bool enabled_bool = (bool) from;
            update_login_protection_status();
            to = enabled_bool ? _("Disable account") : _("Enable account");
            return true;
        });
        bindings += account.bind_property("enabled", avatar_menu_box, "visible", BindingFlags.SYNC_CREATE);
        bindings += account.bind_property("enabled", password_change, "visible", BindingFlags.SYNC_CREATE);
        bindings += account.bind_property("enabled", connection_status, "visible", BindingFlags.SYNC_CREATE);
        bindings += account.bind_property("enabled", proxy_group, "sensitive", BindingFlags.SYNC_CREATE);
        bindings += model.selected_account.bind_property("connection-state", connection_status, "subtitle", BindingFlags.SYNC_CREATE, (binding, from, ref to) => {
            update_dns_security_status();
            update_login_protection_status();
            to = get_status_label();
            update_connection_status_style();
            update_certificate_info();
            return true;
        });
        bindings += model.selected_account.bind_property("connection-error", connection_status, "subtitle", BindingFlags.SYNC_CREATE, (binding, from, ref to) => {
            update_dns_security_status();
            update_login_protection_status();
            to = get_status_label();
            update_connection_status_style();
            return true;
        });
        bindings += model.selected_account.bind_property("connection-error", enter_password_button, "visible", BindingFlags.SYNC_CREATE, (binding, from, ref to) => {
            var error = (ConnectionManager.ConnectionError) from;
            to = error != null && error.source == ConnectionManager.ConnectionError.Source.SASL
                 && error.identifier == null;
            return true;
        });

        // Only show avatar removal button if an avatar is set
        var avatar_model = model.selected_account.avatar_model.tiles.get_item(0) as ViewModel.AvatarPictureTileModel;
        if (avatar_model != null) {
            selected_account_avatar_model = avatar_model;
            selected_account_avatar_image_bytes = avatar_model.notify["image-bytes"].connect(() => {
                remove_avatar_button.visible = avatar_model.image_bytes != null;
            });
            remove_avatar_button.visible = avatar_model.image_bytes != null;
        } else {
            remove_avatar_button.visible = false;
        }

        selected_account_connection_error = model.selected_account.notify["connection-error"].connect(() => {
            update_connection_error_ui();
            update_certificate_info();
        });
        selected_account_connection_state = model.selected_account.notify["connection-state"].connect(() => {
            // Update proxy status when connection state changes (e.g. after reconnect)
            update_connection_status_style();
            check_proxy_status();
        });
        update_connection_error_ui();
        update_connection_status_style();
        update_certificate_info();
        update_login_protection_status();
    }

    private void clear_selected_account_handlers() {
        login_check_generation++;
        if (login_check_start_idle != 0) {
            Source.remove(login_check_start_idle);
            login_check_start_idle = 0;
        }
        login_check_disconnecting = false;
        login_check_pending = false;
        login_protection_feedback.visible = false;
        invalidate_profile_operation();
        ignore_proxy_toggle = false;
        if (selected_account_connection_error != 0 && selected_account_connection_owner != null) {
            if (SignalHandler.is_connected(selected_account_connection_owner, selected_account_connection_error)) {
                SignalHandler.disconnect(selected_account_connection_owner, selected_account_connection_error);
            }
        }
        selected_account_connection_error = 0;
        if (selected_account_connection_state != 0 && selected_account_connection_owner != null) {
            if (SignalHandler.is_connected(selected_account_connection_owner, selected_account_connection_state)) {
                SignalHandler.disconnect(selected_account_connection_owner, selected_account_connection_state);
            }
        }
        selected_account_connection_state = 0;
        selected_account_connection_owner = null;

        if (selected_account_avatar_image_bytes != 0 && selected_account_avatar_model != null) {
            if (SignalHandler.is_connected(selected_account_avatar_model, selected_account_avatar_image_bytes)) {
                SignalHandler.disconnect(selected_account_avatar_model, selected_account_avatar_image_bytes);
            }
        }
        selected_account_avatar_image_bytes = 0;
        selected_account_avatar_model = null;

        foreach (var binding in bindings) {
            binding.unbind();
        }
        bindings = new Binding[0];

        if (alias_entry_changed != 0 && SignalHandler.is_connected(local_alias, alias_entry_changed)) local_alias.disconnect(alias_entry_changed);
        alias_entry_changed = 0;
        if (custom_host_entry_changed != 0 && SignalHandler.is_connected(custom_host_entry, custom_host_entry_changed)) custom_host_entry.disconnect(custom_host_entry_changed);
        if (custom_port_entry_changed != 0 && SignalHandler.is_connected(custom_port_entry, custom_port_entry_changed)) custom_port_entry.disconnect(custom_port_entry_changed);
        custom_host_entry_changed = 0;
        custom_port_entry_changed = 0;
        if (proxy_enable_row_changed != 0 && SignalHandler.is_connected(proxy_enable_row, proxy_enable_row_changed)) proxy_enable_row.disconnect(proxy_enable_row_changed);
        if (proxy_host_entry_changed != 0 && SignalHandler.is_connected(proxy_host_entry, proxy_host_entry_changed)) proxy_host_entry.disconnect(proxy_host_entry_changed);
        if (proxy_port_entry_changed != 0 && SignalHandler.is_connected(proxy_port_entry, proxy_port_entry_changed)) proxy_port_entry.disconnect(proxy_port_entry_changed);
        if (proxy_user_entry_changed != 0 && SignalHandler.is_connected(proxy_user_entry, proxy_user_entry_changed)) proxy_user_entry.disconnect(proxy_user_entry_changed);
        if (proxy_pass_entry_changed != 0 && SignalHandler.is_connected(proxy_pass_entry, proxy_pass_entry_changed)) proxy_pass_entry.disconnect(proxy_pass_entry_changed);
        if (timezone_row_changed != 0 && SignalHandler.is_connected(timezone_row, timezone_row_changed)) timezone_row.disconnect(timezone_row_changed);
        proxy_enable_row_changed = 0;
        proxy_host_entry_changed = 0;
        proxy_port_entry_changed = 0;
        proxy_user_entry_changed = 0;
        proxy_pass_entry_changed = 0;
        timezone_row_changed = 0;
        if (login_protection_mode_changed != 0 && SignalHandler.is_connected(login_protection_mode, login_protection_mode_changed)) login_protection_mode.disconnect(login_protection_mode_changed);
        if (allow_plain_changed != 0 && SignalHandler.is_connected(allow_plain_switch, allow_plain_changed)) allow_plain_switch.disconnect(allow_plain_changed);
        allow_plain_changed = 0;
        login_protection_mode_changed = 0;

        if (proxy_check_cancel != null) {
            proxy_check_cancel.cancel();
            proxy_check_cancel = null;
        }
    }

    private Window? get_parent_window() {
        var root = this.get_root();
        if (root is Window) {
            return root as Window;
        }

        Widget? current = this;
        while (current != null) {
            if (current is Window) {
                return current as Window;
            }
            current = current.get_parent();
        }

        var app = GLib.Application.get_default() as Gtk.Application;
        return app != null ? app.get_active_window() : null;
    }

    private void present_in_context(Object dialog) {
        var parent_window = get_parent_window();
        if (parent_window == null) return;
        if (dialog is Adw.Dialog) {
            ((Adw.Dialog) dialog).present(parent_window);
            return;
        }
        if (dialog is CertificateWarningDialog) {
            ((CertificateWarningDialog) dialog).present(parent_window);
            return;
        }

        warning("present_in_context: unsupported dialog type %s", dialog.get_type().name());
    }

    private void check_proxy_status() {
        check_proxy_availability.begin((obj, res) => {
            check_proxy_availability.end(res);
        });
    }

    private int parse_port_or_zero(string text) {
        int port = 0;
        if (!int.try_parse(text.strip(), out port)) return 0;
        return (port > 0 && port <= 65535) ? port : 0;
    }

    private bool has_valid_socks5_config() {
        return proxy_host_entry.text.strip() != "" && parse_port_or_zero(proxy_port_entry.text) > 0;
    }

    private void show_proxy_config_error() {
        proxy_enable_row.subtitle = "";
        proxy_status_row.subtitle = _("Enter a valid SOCKS5 host and port first.");
        proxy_status_row.remove_css_class("success");
        proxy_status_row.add_css_class("error");
    }

    private bool apply_socks5_config_to_account(Account? target_account = null) {
        Account proxy_account = target_account ?? account;
        if (!has_valid_socks5_config()) {
            show_proxy_config_error();
            return false;
        }

        string host = proxy_host_entry.text.strip();
        int port = parse_port_or_zero(proxy_port_entry.text);
        string? user = proxy_user_entry.text.length > 0 ? proxy_user_entry.text : null;
        string? pass = proxy_pass_entry.text.length > 0 ? proxy_pass_entry.text : null;
        proxy_account.proxy_type = "socks5";
        proxy_account.proxy_host = host;
        proxy_account.proxy_port = port;
        proxy_account.proxy_user = user;
        proxy_account.proxy_pass = pass;
        return true;
    }

    private bool apply_runtime_proxy_if_ready(string provider_id, Account target_account,
            ViewModel.PreferencesDialog target_model) {
        var provider = target_model.stream_interactor.get_module<Dino.Plugins.AccountProxyProvider>(new SimpleIdentity(provider_id));
        if (provider == null || !provider.proxy_enabled || !provider.proxy_ready || provider.proxy_port <= 0) {
            return false;
        }

        target_account.proxy_type = provider.proxy_type;
        target_account.proxy_host = provider.proxy_host;
        target_account.proxy_port = provider.proxy_port;
        return true;
    }

    private void load_account_vcard() {
        load_vcard.begin((obj, res) => {
            load_vcard.end(res);
        });
    }

    private void save_account_vcard() {
        save_vcard.begin((obj, res) => {
            save_vcard.end(res);
        });
    }

    private async void check_proxy_availability() {
        // Cancel any pending check to avoid race conditions
        if (proxy_check_cancel != null) {
            proxy_check_cancel.cancel();
        }
        proxy_check_cancel = new Cancellable();
        var cancel = proxy_check_cancel;

        // Account disabled — show disabled status, don't check connectivity
        if (!account.enabled) {
            proxy_status_row.subtitle = _("%s (account disabled)").printf(
                proxy_enable_row.active ? _("Configured") : _("Disabled"));
            proxy_status_row.remove_css_class("success");
            proxy_status_row.remove_css_class("error");
            return;
        }

        bool enabled = proxy_enable_row.active;
        // For status display, use field values (always show saved SOCKS5 config)
        string field_host = proxy_host_entry.text.strip();
        int field_port = parse_port_or_zero(proxy_port_entry.text);

        // SOCKS5 toggle OFF — show disabled/Tor status, no TCP check
        if (!enabled) {
            if (account.proxy_type == "tor") {
                // Tor manages this account — show Tor connection state
                var conn_state = model.stream_interactor.connection_manager.get_state(account);
                if (conn_state == ConnectionManager.ConnectionState.CONNECTED) {
                    proxy_status_row.subtitle = _("Connected via Tor");
                    proxy_status_row.add_css_class("success");
                    proxy_status_row.remove_css_class("error");
                } else if (conn_state == ConnectionManager.ConnectionState.CONNECTING) {
                    proxy_status_row.subtitle = _("Connecting via Tor...");
                    proxy_status_row.remove_css_class("success");
                    proxy_status_row.remove_css_class("error");
                } else {
                    proxy_status_row.subtitle = _("Tor proxy (not connected)");
                    proxy_status_row.remove_css_class("success");
                    proxy_status_row.remove_css_class("error");
                }
            } else {
                if (field_host == "" || field_port <= 0) {
                    proxy_status_row.subtitle = _("Disabled");
                } else {
                    proxy_status_row.subtitle = _("Disabled (configured)");
                }
                proxy_status_row.remove_css_class("success");
                proxy_status_row.remove_css_class("error");
            }
            return;
        }

        // Switch on but no host/port
        if (field_host == "" || field_port <= 0) {
            proxy_status_row.subtitle = _("Not configured");
            proxy_status_row.remove_css_class("success");
            proxy_status_row.add_css_class("error");
            return;
        }

        proxy_status_row.subtitle = _("Checking...");
        proxy_status_row.remove_css_class("success");
        proxy_status_row.remove_css_class("error");

        // Check XMPP connection state FIRST — if already connected through
        // the proxy, show Active immediately without TCP check
        var conn_state = model.stream_interactor.connection_manager.get_state(account);
        if (conn_state == ConnectionManager.ConnectionState.CONNECTED) {
            proxy_status_row.subtitle = _("Active");
            proxy_status_row.add_css_class("success");
            proxy_status_row.remove_css_class("error");
            return;
        } else if (conn_state == ConnectionManager.ConnectionState.CONNECTING) {
            proxy_status_row.subtitle = _("Connecting...");
            proxy_status_row.remove_css_class("success");
            proxy_status_row.remove_css_class("error");
            return;
        }

        // XMPP not connected — do TCP reachability check
        bool reachable = false;
        try {
            SocketClient client = new SocketClient();
            client.timeout = 2;
            SocketConnection conn = yield client.connect_to_host_async(field_host, (uint16)field_port, cancel);
            if (cancel.is_cancelled()) return;
            reachable = true;
            conn.close(null);
        } catch (IOError.CANCELLED e) {
            return;
        } catch (Error e) {
            if (cancel.is_cancelled()) return;
        }

        // Re-check connection state after TCP check (XMPP may have connected in the meantime)
        conn_state = model.stream_interactor.connection_manager.get_state(account);
        if (conn_state == ConnectionManager.ConnectionState.CONNECTED) {
            proxy_status_row.subtitle = _("Active");
            proxy_status_row.add_css_class("success");
            proxy_status_row.remove_css_class("error");
            return;
        } else if (conn_state == ConnectionManager.ConnectionState.CONNECTING) {
            proxy_status_row.subtitle = _("Connecting...");
            proxy_status_row.remove_css_class("success");
            proxy_status_row.remove_css_class("error");
            return;
        }

        if (!reachable) {
            proxy_status_row.subtitle = _("Connection failed");
            proxy_status_row.add_css_class("error");
            proxy_status_row.remove_css_class("success");
            return;
        }

        proxy_status_row.subtitle = _("Reachable (not connected)");
        proxy_status_row.add_css_class("success");
        proxy_status_row.remove_css_class("error");
    }

    private void update_connection_error_ui() {
        var selected_account = model.selected_account;
        if (selected_account == null) {
            trust_certificate_button.visible = false;
            return;
        }
        var error = selected_account.connection_error;
        if (error != null) {
            // Show trust certificate button for TLS errors with certificate info
            if (error.source == ConnectionManager.ConnectionError.Source.TLS && 
                error.tls_certificate != null) {
                trust_certificate_button.visible = true;
            } else {
                trust_certificate_button.visible = false;
            }
        } else {
            trust_certificate_button.visible = false;
        }
        update_connection_status_style();
    }

    private void update_connection_status_style() {
        var selected_account = model.selected_account;
        if (selected_account == null) {
            connection_status.remove_css_class("success");
            connection_status.remove_css_class("warning");
            connection_status.remove_css_class("error");
            return;
        }
        connection_status.remove_css_class("success");
        connection_status.remove_css_class("warning");
        connection_status.remove_css_class("error");

        if (selected_account.connection_error != null) {
            connection_status.add_css_class("error");
            return;
        }

        switch (selected_account.connection_state) {
            case ConnectionManager.ConnectionState.CONNECTED:
                connection_status.add_css_class("success");
                break;
            case ConnectionManager.ConnectionState.CONNECTING:
                connection_status.add_css_class("warning");
                break;
            case ConnectionManager.ConnectionState.DISCONNECTED:
                connection_status.add_css_class("error");
                break;
        }
    }

    private void show_certificate_dialog() {
        var selected_account = model.selected_account;
        if (selected_account == null) {
            return;
        }
        var error = selected_account.connection_error;
        if (error == null || error.tls_certificate == null) return;

        var dialog = new CertificateWarningDialog(
            account,
            error.tls_certificate,
            error.tls_flags,
            error.tls_domain ?? account.domainpart,
            model.stream_interactor
        );
        present_in_context(dialog);
    }

    private void update_certificate_info() {
        string domain = account.domainpart;
        var cm = model.stream_interactor.connection_manager;
        cert_status_row.remove_css_class("success");
        cert_status_row.remove_css_class("warning");
        
        // Try to get the live certificate from active connection
        TlsCertificate? live_cert = cm.get_peer_certificate(account);
        bool is_pinned = cm.is_certificate_pinned(domain);
        CertificateInfo? pinned_info = cm.get_pinned_certificate_info(domain);

        if (live_cert != null) {
            // Connected — show the live certificate
            string fingerprint = CertificateManager.get_certificate_fingerprint(live_cert);
            string? issuer = CertificateManager.get_certificate_issuer(live_cert);
            DateTime? not_before = CertificateManager.get_certificate_not_before(live_cert);
            DateTime? not_after = CertificateManager.get_certificate_not_after(live_cert);

            cert_group.visible = true;

            var tls_stream = model.stream_interactor.get_stream(account) as TlsXmppStream;
            if (tls_stream != null && tls_stream.dns_security != null && tls_stream.dns_security.verified) {
                cert_status_row.subtitle = _("Verified through DNSSEC and DANE");
                cert_status_row.add_css_class("success");
            } else if (is_pinned) {
                cert_status_row.subtitle = _("Pinned (self-signed / manually trusted)");
                cert_status_row.add_css_class("warning");
            } else {
                cert_status_row.subtitle = _("Valid (CA-signed)");
                cert_status_row.remove_css_class("warning");
            }

            if (issuer != null) {
                cert_issuer_row.subtitle = issuer;
                cert_issuer_row.visible = true;
            } else {
                cert_issuer_row.visible = false;
            }

            if (not_before != null || not_after != null) {
                string validity = "";
                if (not_before != null) validity += _("From:") + " " + not_before.format("%Y-%m-%d");
                if (not_after != null) {
                    if (validity.length > 0) validity += "  —  ";
                    validity += _("Until:") + " " + not_after.format("%Y-%m-%d");
                    if (not_after.compare(new DateTime.now_utc()) < 0) {
                        validity += " (" + _("expired") + ")";
                    }
                }
                cert_validity_row.subtitle = validity;
                cert_validity_row.visible = true;
            } else {
                cert_validity_row.visible = false;
            }

            cert_fingerprint_row.subtitle = fingerprint;
            cert_fingerprint_row.visible = true;
            unpin_certificate_button.visible = is_pinned;

        } else if (pinned_info != null) {
            // Not connected but have a pinned cert — show the stored info
            cert_group.visible = true;
            cert_status_row.subtitle = _("Pinned (not connected)");
            cert_status_row.add_css_class("warning");

            if (pinned_info.issuer != null) {
                cert_issuer_row.subtitle = pinned_info.issuer;
                cert_issuer_row.visible = true;
            } else {
                cert_issuer_row.visible = false;
            }

            cert_validity_row.subtitle = pinned_info.get_validity_string();
            cert_validity_row.visible = true;

            cert_fingerprint_row.subtitle = pinned_info.fingerprint_sha256;
            cert_fingerprint_row.visible = true;
            unpin_certificate_button.visible = true;
        } else {
            // Not connected and no pinned cert
            var conn_state = cm.get_state(account);
            var connection_failure = cm.get_error(account);
            if (connection_failure != null && connection_failure.source == ConnectionManager.ConnectionError.Source.DNS_SECURITY) {
                cert_group.visible = false;
                return;
            }
            if (conn_state == ConnectionManager.ConnectionState.CONNECTING) {
                // During reconnect: keep cert_group visible to avoid UI jumping
                cert_group.visible = true;
                cert_status_row.subtitle = _("Connecting…");
                cert_issuer_row.visible = false;
                cert_validity_row.visible = false;
                cert_fingerprint_row.visible = false;
                unpin_certificate_button.visible = false;
            } else if (conn_state == ConnectionManager.ConnectionState.DISCONNECTED && cert_group.visible) {
                // Transitional disconnect (e.g. reconnect in progress): keep visible briefly
                cert_status_row.subtitle = _("Reconnecting…");
                cert_issuer_row.visible = false;
                cert_validity_row.visible = false;
                cert_fingerprint_row.visible = false;
                unpin_certificate_button.visible = false;
            } else {
                cert_group.visible = false;
            }
        }
    }

    private void show_select_avatar() {
        var chooser = new Gtk.FileDialog();
        chooser.title = _("Select avatar");
        chooser.accept_label = _("Select");

        var filters = new GLib.ListStore(typeof(Gtk.FileFilter));

        var image_filter = new Gtk.FileFilter();
        foreach (PixbufFormat pixbuf_format in Pixbuf.get_formats()) {
            foreach (string mime_type in pixbuf_format.get_mime_types()) {
                image_filter.add_mime_type(mime_type);
            }
        }
        image_filter.name = _("Images");
        filters.append(image_filter);

        var all_filter = new Gtk.FileFilter();
        all_filter.name = _("All files");
        all_filter.add_pattern("*");
        filters.append(all_filter);

        chooser.filters = filters;
        chooser.default_filter = image_filter;

        var root = get_parent_window();
        if (root == null) {
            return;
        }
        chooser.open.begin(root, null, (obj, res) => {
            try {
                File file = chooser.open.end(res);
                model.set_avatar_file(account, file);
            } catch (Error e) {
            }
        });
    }

    private void show_remove_account_dialog() {
        Adw.AlertDialog dialog = new Adw.AlertDialog (
                _("Remove account %s?".printf(account.bare_jid.to_string())),
                _("You won't be able to access your conversation history anymore.")
        );

        var options_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        options_box.margin_start = 12;
        options_box.margin_end = 12;
        options_box.margin_top = 6;

        // Checkbox: also delete from server
        var server_check = new Gtk.CheckButton.with_label(_("Also delete account from server"));
        options_box.append(server_check);

        var bot_impact = model.get_account_removal_impact(account);
        var delete_managed_bots_check = new Gtk.CheckButton.with_label(_("Also delete managed Botmother bots"));
        delete_managed_bots_check.sensitive = false;
        if (bot_impact.has_any()) {
            var bot_warning = new Gtk.Label(null);
            bot_warning.wrap = true;
            bot_warning.xalign = 0;
            bot_warning.add_css_class("dim-label");
            bot_warning.label = _("This account has Botmother data: %d local bot(s), %d server-managed dedicated bot(s), %d manual dedicated bot(s), %d CloudBot management token(s). Local Botmother data will be removed from this device. Select “Also delete managed Botmother bots” to also delete DinoX-managed dedicated bot accounts and CloudBots loaded with a management token from their servers.").printf(
                bot_impact.local_bots,
                bot_impact.server_managed_bots,
                bot_impact.manual_dedicated_bots,
                bot_impact.cloudbot_tokens
            );
            options_box.append(bot_warning);

            delete_managed_bots_check.sensitive = bot_impact.server_managed_bots > 0 || bot_impact.cloudbot_tokens > 0;
            if (!delete_managed_bots_check.sensitive) {
                delete_managed_bots_check.tooltip_text = _("Only DinoX-managed dedicated bot accounts and CloudBots with a management token can be deleted from the server here.");
            }
            options_box.append(delete_managed_bots_check);
            server_check.notify["active"].connect(() => {
                if (server_check.active && delete_managed_bots_check.sensitive) {
                    delete_managed_bots_check.active = true;
                } else if (!server_check.active) {
                    delete_managed_bots_check.active = false;
                }
            });
        }
        dialog.set_extra_child(options_box);

        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("remove", _("Remove"));
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.response.connect((response) => {
            if (response == "remove") {
                Account account_to_remove = account;
                bool delete_from_server = server_check.active;
                bool delete_managed_bots = delete_managed_bots_check.active;
                remove_account_button.sensitive = false;
                model.remove_account.begin(account_to_remove, delete_from_server, delete_managed_bots, (source, res) => {
                    string? error = model.remove_account.end(res);
                    remove_account_button.sensitive = true;
                    if (error != null) {
                        if (get_root() == null) {
                            warning("Account removal failed after preferences closed: %s", (!) error);
                            return;
                        }
                        var error_dialog = new Adw.AlertDialog(
                            _("Account deletion failed"),
                            _("The account remains configured locally. Server deletion failed: %s").printf(
                                describe_account_removal_error((!) error)
                            )
                        );
                        error_dialog.add_response("ok", _("OK"));
                        present_in_context(error_dialog);
                        return;
                    }

                    if (get_root() == null) return;
                    Widget parent = this.parent;
                    for (int i = 0; parent != null && i < 20; i++) {
                        if (parent.get_type() == typeof(Dino.Ui.PreferencesDialog)) {
                            ((Dino.Ui.PreferencesDialog) parent).pop_subpage();
                        }
                        parent = parent.parent;
                    }
                });
            }
            dialog.close();
        });
        present_in_context(dialog);
    }

    private string describe_account_removal_error(string error) {
        switch (error) {
            case "profile-operation-in-progress":
                return _("Please wait until the current data operation has finished before removing an account.");
            case "account-not-connected":
                return _("The account must be connected before it can be deleted from the server.");
            case "xep-0077-unavailable":
                return _("This server connection does not support XEP-0077 account deletion.");
            default:
                return error;
        }
    }

    private void invalidate_profile_operation() {
        profile_generation++;
        if (profile_cancel != null) profile_cancel.cancel();
        profile_cancel = null;
        profile_saving = false;
        profile_group.sensitive = true;
    }

    private bool profile_context_is_current(uint generation,
            ViewModel.PreferencesDialog owner, Account target,
            XmppStream stream, Cancellable cancel) {
        return !cancel.is_cancelled() && generation == profile_generation &&
            model == owner && owner.selected_account != null &&
            owner.selected_account.account == target &&
            owner.stream_interactor.get_connected_stream_for_action(target) == stream;
    }

    private void show_profile_status(string title, string? subtitle = null) {
        profile_status_row.title = title;
        profile_status_row.subtitle = subtitle ?? "";
        profile_status_row.visible = true;
    }

    private void reset_profile_fields() {
        vcard_fn.text = "";
        vcard_nickname.text = "";
        vcard_gender.selected = 0;
        vcard_bday.text = "";
        vcard_adr_street.text = "";
        vcard_adr_pcode.text = "";
        vcard_adr_city.text = "";
        vcard_adr_region.text = "";
        vcard_adr_country.text = "";
        vcard_email.text = "";
        vcard_impp.text = "";
        vcard_phone.text = "";
        vcard_title.text = "";
        vcard_role.text = "";
        vcard_org.text = "";
        vcard_tz.text = "";
        vcard_url.text = "";
        vcard_desc.text = "";
        vcard_public_access.active = false;
        vcard_share_with_contacts.active = false;
        vcard_share_with_contacts.sensitive = true;
        save_vcard_button.sensitive = false;
    }

    private void display_profile(Xmpp.Xep.VCard4.VCard4 card) {
        vcard_fn.text = card.full_name ?? "";
        vcard_nickname.text = card.nickname ?? "";
        switch (card.gender) {
            case "M": vcard_gender.selected = 1; break;
            case "F": vcard_gender.selected = 2; break;
            case "O": vcard_gender.selected = 3; break;
            case "N": vcard_gender.selected = 4; break;
            default: vcard_gender.selected = 0; break;
        }
        vcard_bday.text = card.bday ?? "";
        vcard_email.text = card.email ?? "";
        vcard_phone.text = card.tel ?? "";
        vcard_title.text = card.title ?? "";
        vcard_role.text = card.role ?? "";
        vcard_org.text = card.org ?? "";
        vcard_tz.text = card.tz ?? "";
        vcard_url.text = card.url ?? "";
        vcard_desc.text = card.note ?? "";
        vcard_impp.text = card.impp ?? "";
        vcard_adr_street.text = card.adr_street ?? "";
        vcard_adr_city.text = card.adr_locality ?? "";
        vcard_adr_region.text = card.adr_region ?? "";
        vcard_adr_pcode.text = card.adr_pcode ?? "";
        vcard_adr_country.text = card.adr_country ?? "";
    }

    private async void load_vcard() {
        invalidate_profile_operation();
        reset_profile_fields();
        if (model == null || model.selected_account == null) return;
        var owner = model;
        var target = owner.selected_account.account;
        var stream = owner.stream_interactor.get_connected_stream_for_action(target);
        if (stream == null) {
            show_profile_status(_("Connect the account to load its profile."));
            return;
        }
        uint generation = profile_generation;
        var cancel = new Cancellable();
        profile_cancel = cancel;
        show_profile_status(_("Loading profile…"));
        profile_group.sensitive = false;
        try {
            var pubsub = stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY);
            Xmpp.Xep.VCard4.VCard4? card = null;
            string? source_node = null;
            if (pubsub != null) {
                // Keep the source node so its access model is not confused with
                // that of the other compatibility node. Failed reads are not absence.
                foreach (string node_id in new string[] {Xmpp.Xep.VCard4.NS_URI, Xmpp.Xep.VCard4.NODE_URI_LEGACY}) {
                    var result = yield pubsub.request_all_with_result_cancellable(
                        stream, target.bare_jid, node_id, 1,
                        Xmpp.Xep.Pubsub.RequestPurpose.OPPORTUNISTIC_METADATA, cancel);
                    if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
                    if (result.items == null) {
                        if (result.is_item_not_found() ||
                                result.error_condition == ErrorStanza.CONDITION_FEATURE_NOT_IMPLEMENTED ||
                                result.error_condition == ErrorStanza.CONDITION_SERVICE_UNAVAILABLE) continue;
                        throw new IOError.FAILED("Profile node could not be read");
                    }
                    if (result.items.size == 0) continue;
                    var node = result.items[0].get_subnode("vcard", Xmpp.Xep.VCard4.NS_URI);
                    if (node == null) node = result.items[0].get_subnode("vcard", Xmpp.Xep.VCard4.NODE_URI_LEGACY);
                    if (node == null) throw new IOError.INVALID_DATA("Profile item has no vCard");
                    card = new Xmpp.Xep.VCard4.VCard4(node);
                    source_node = node_id;
                    break;
                }
            }
            string? access_model = null;
            if (card != null && pubsub != null) {
                var config = yield pubsub.request_node_config_with_cancellable(
                    stream, null, source_node, cancel);
                if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
                if (config != null) {
                    foreach (var field in config.fields) {
                        if (field.var == "pubsub#access_model") {
                            access_model = field.get_value_string();
                            break;
                        }
                    }
                }
                display_profile(card);
            } else {
                var legacy = yield Xmpp.Xep.VCard.fetch_vcard_checked_with_cancellable(stream, null, cancel);
                if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
                if (legacy != null) {
                    vcard_fn.text = legacy.full_name ?? "";
                    vcard_nickname.text = legacy.nickname ?? "";
                    vcard_email.text = legacy.email ?? "";
                    vcard_phone.text = legacy.phone ?? "";
                    vcard_title.text = legacy.title ?? "";
                    vcard_role.text = legacy.role ?? "";
                    vcard_org.text = legacy.organization ?? "";
                    vcard_url.text = legacy.url ?? "";
                    vcard_desc.text = legacy.description ?? "";
                    vcard_bday.text = legacy.birthday ?? "";
                    vcard_adr_street.text = legacy.adr_street ?? "";
                    vcard_adr_city.text = legacy.adr_locality ?? "";
                    vcard_adr_region.text = legacy.adr_region ?? "";
                    vcard_adr_pcode.text = legacy.adr_pcode ?? "";
                    vcard_adr_country.text = legacy.adr_country ?? "";
                }
            }
            vcard_public_access.active = access_model == Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN;
            vcard_share_with_contacts.active = vcard_public_access.active || access_model == Xmpp.Xep.Pubsub.ACCESS_MODEL_PRESENCE;
            vcard_share_with_contacts.sensitive = !vcard_public_access.active;
            // Whitelist alone does not prove that no other JIDs have membership.
            show_profile_status(_("Visibility settings apply when you save."),
                _("Saving updates both profile formats and the published nickname. Until then, previously published details may still be visible."));
            if (access_model != Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN &&
                    access_model != Xmpp.Xep.Pubsub.ACCESS_MODEL_PRESENCE) {
                show_profile_status(_("Current profile visibility could not be verified."),
                    _("Choose who can see your profile before saving. Saving applies the visibility settings below."));
            }
            save_vcard_button.sensitive = true;
        } catch (Error e) {
            if (profile_context_is_current(generation, owner, target, stream, cancel)) {
                show_profile_status(_("The profile could not be loaded."), _("Reconnect the account and reopen this page to try again."));
            }
        } finally {
            if (generation == profile_generation) {
                profile_cancel = null;
                profile_group.sensitive = true;
                if (model == owner && owner.selected_account != null &&
                        owner.selected_account.account == target &&
                        owner.stream_interactor.get_connected_stream_for_action(target) != stream) {
                    show_profile_status(_("Reconnect the account and reopen this page to try again."));
                }
            }
        }
    }

    private Xmpp.Xep.VCard4.VCard4 snapshot_profile() {
        var card = new Xmpp.Xep.VCard4.VCard4.create();
        card.full_name = vcard_fn.text;
        card.nickname = vcard_nickname.text;
        switch (vcard_gender.selected) {
            case 1: card.gender = "M"; break;
            case 2: card.gender = "F"; break;
            case 3: card.gender = "O"; break;
            case 4: card.gender = "N"; break;
            default: card.gender = null; break;
        }
        card.bday = vcard_bday.text;
        card.email = vcard_email.text;
        card.tel = vcard_phone.text;
        card.title = vcard_title.text;
        card.role = vcard_role.text;
        card.org = vcard_org.text;
        card.tz = vcard_tz.text;
        card.url = vcard_url.text;
        card.note = vcard_desc.text;
        if (vcard_impp.text != "") card.impp = vcard_impp.text;
        if (vcard_adr_street.text != "" || vcard_adr_city.text != "" || vcard_adr_region.text != "" || vcard_adr_pcode.text != "" || vcard_adr_country.text != "") {
            card.adr_street = vcard_adr_street.text;
            card.adr_locality = vcard_adr_city.text;
            card.adr_region = vcard_adr_region.text;
            card.adr_pcode = vcard_adr_pcode.text;
            card.adr_country = vcard_adr_country.text;
        }
        return card;
    }

    private Xmpp.Xep.VCard.VCardInfo legacy_profile_for_visibility(
            Xmpp.Xep.VCard4.VCard4 card, bool public_access) {
        var legacy = new Xmpp.Xep.VCard.VCardInfo();
        // XEP-0054 cannot enforce contact-only/private access. A full replacement
        // without personal fields also removes previously public legacy details.
        if (public_access) {
            legacy.full_name = card.full_name;
            legacy.nickname = card.nickname;
            legacy.email = card.email;
            legacy.phone = card.tel;
            legacy.title = card.title;
            legacy.role = card.role;
            legacy.organization = card.org;
            legacy.url = card.url;
            legacy.description = card.note;
            legacy.birthday = card.bday;
            legacy.adr_street = card.adr_street;
            legacy.adr_locality = card.adr_locality;
            legacy.adr_region = card.adr_region;
            legacy.adr_pcode = card.adr_pcode;
            legacy.adr_country = card.adr_country;
        }
        return legacy;
    }

    private async void save_vcard() {
        if (profile_saving || model == null || model.selected_account == null) return;
        var owner = model;
        var target = owner.selected_account.account;
        var stream = owner.stream_interactor.get_connected_stream_for_action(target);
        if (stream == null) {
            show_profile_status(_("Connect the account before saving its profile."));
            return;
        }
        // All form values and access rules belong to this operation, captured
        // before any async work. Never read a replacement account's form later.
        var card = snapshot_profile();
        bool public_access = vcard_public_access.active;
        string access_model = public_access ? Xmpp.Xep.Pubsub.ACCESS_MODEL_OPEN :
            (vcard_share_with_contacts.active ? Xmpp.Xep.Pubsub.ACCESS_MODEL_PRESENCE : Xmpp.Xep.Pubsub.ACCESS_MODEL_WHITELIST);
        var legacy = legacy_profile_for_visibility(card, public_access);
        string nickname = card.nickname ?? "";
        var options = new Xmpp.Xep.Pubsub.PublishOptions();
        options.set_access_model(access_model);
        invalidate_profile_operation();
        uint generation = profile_generation;
        var cancel = new Cancellable();
        profile_cancel = cancel;
        profile_saving = true;
        save_vcard_button.sensitive = false;
        show_profile_status(_("Saving profile…"));
        profile_group.sensitive = false;
        try {
            var pubsub = stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY);
            if (pubsub == null) throw new IOError.NOT_SUPPORTED("Profile publication is unavailable");
            var previous = yield Xmpp.Xep.VCard.fetch_vcard_checked_with_cancellable(stream, null, cancel);
            if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
            if (previous != null) {
                legacy.photo = previous.photo;
                legacy.photo_type = previous.photo_type;
            }
            yield Xmpp.Xep.VCard.publish_vcard_with_cancellable(stream, legacy, null, cancel);
            if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
            foreach (string node_id in new string[] {Xmpp.Xep.VCard4.NS_URI, Xmpp.Xep.VCard4.NODE_URI_LEGACY, "http://jabber.org/protocol/nick"}) {
                if (!public_access) {
                    yield pubsub.ensure_node_owner_only(stream, target.bare_jid, node_id, cancel);
                    if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
                }
                var content = card.node;
                if (node_id == "http://jabber.org/protocol/nick") {
                    content = new StanzaNode.build("nick", node_id).add_self_xmlns();
                    // Publish an empty nick as well, so clearing the field does
                    // not leave the previous published nickname behind.
                    if (nickname != "") content.put_node(new StanzaNode.text(nickname));
                }
                var result = yield pubsub.publish_with_result_cancellable(
                    stream, null, node_id, "current", content, options, true, false, cancel);
                if (!profile_context_is_current(generation, owner, target, stream, cancel)) return;
                if (!result.ok) throw new IOError.FAILED("Profile publication was not confirmed");
            }
            show_profile_status(_("Profile saved."));
        } catch (Error e) {
            if (profile_context_is_current(generation, owner, target, stream, cancel)) {
                show_profile_status(_("The profile could not be fully saved."),
                    _("Some server changes may already have been applied. The visibility settings have not been confirmed. Try saving again."));
            }
        } finally {
            if (generation == profile_generation) {
                profile_cancel = null;
                profile_saving = false;
                profile_group.sensitive = true;
                // Reconnects may have replaced the stream, but must not leave
                // this account's editor permanently disabled.
                if (model == owner && owner.selected_account != null &&
                        owner.selected_account.account == target) {
                    save_vcard_button.sensitive = owner.stream_interactor.get_connected_stream_for_action(target) != null;
                    if (owner.stream_interactor.get_connected_stream_for_action(target) != stream) {
                        show_profile_status(_("The profile could not be fully saved."),
                            _("Some server changes may already have been applied. The visibility settings have not been confirmed. Try saving again."));
                    }
                }
            }
        }
    }

    private string get_status_label() {
        if (model.selected_account == null) {
            return _("Unknown Status");
        }
        string? error_label = get_connection_error_description();
        if (error_label != null) return error_label;

        ConnectionManager.ConnectionState state = model.selected_account.connection_state;
        switch (state) {
            case ConnectionManager.ConnectionState.CONNECTING:
                return _("Connecting…");
            case ConnectionManager.ConnectionState.CONNECTED:
                return _("Connected");
            case ConnectionManager.ConnectionState.DISCONNECTED:
                return _("Disconnected");
        }
        return _("Unknown Status");
    }

    private void update_dns_security_help() {
        switch (dns_security_mode.selected) {
            case 0:
                dns_security_help.subtitle = _("Only normal TLS certificate checks are used.");
                break;
            case 1:
                dns_security_help.subtitle = _("Unsigned domains are allowed. Invalid signatures and DNS lookup failures stop the connection; the protection stays enabled.");
                break;
            case 2:
                dns_security_help.subtitle = _("The server must provide valid DNSSEC and DANE records. Missing records or lookup failures stop the connection.");
                break;
            default:
                dns_security_help.subtitle = _("Check the selected mode and HTTPS resolver URL. Proxy connections also need a numeric proxy address.");
                break;
        }
        dns_security_resolver.sensitive = dns_security_mode.selected == 1 || dns_security_mode.selected == 2;
    }

    private static string dns_security_error_text(Error error) {
        if (error is DnsSecurity.SecurityError.BOGUS) return _("Invalid DNSSEC signature. The connection was stopped.");
        if (error is DnsSecurity.SecurityError.TLSA_MISMATCH) return _("The server certificate does not match its protected DNS records. The connection was stopped.");
        if (error is DnsSecurity.SecurityError.REQUIRED) return _("This server address cannot currently meet the required DNSSEC and DANE checks.");
        if (error is DnsSecurity.SecurityError.EXPIRED) return _("The DNS verification expired. Apply the settings again to retry.");
        if (error is DnsSecurity.SecurityError.UNAVAILABLE) return _("This build does not include DNSSEC and DANE support.");
        if (error is DnsSecurity.SecurityError.INVALID_CONFIGURATION || error is UriError || error is DnsSecurity.ConfigurationError) {
            return _("Check the selected mode and HTTPS resolver URL. Proxy connections also need a numeric proxy address.");
        }
        return _("DNSSEC or DANE verification failed. Your selected protection remains enabled; apply again to retry.");
    }

    private void show_login_protection_feedback(bool success, string text) {
        login_protection_feedback.visible = true;
        login_protection_feedback.title = success ? _("Check successful") : _("Check failed");
        login_protection_feedback.subtitle = text;
        login_protection_feedback.remove_css_class("success");
        login_protection_feedback.remove_css_class("error");
        login_protection_feedback.add_css_class(success ? "success" : "error");
    }

    private void queue_login_protection_check() {
        if (login_check_start_idle != 0) return;
        // Let the native ComboRow finish closing its selection popover before
        // disabling it and replacing its model with the checking placeholder.
        login_check_start_idle = Idle.add(() => {
            login_check_start_idle = 0;
            if (model != null && model.selected_account != null && account.enabled) check_login_protection.begin();
            return Source.REMOVE;
        });
    }

    private async void check_login_protection() {
        Account selected = account;
        var selected_model = model;
        var manager = selected_model.stream_interactor.connection_manager;
        uint generation = ++login_check_generation;
        login_check_disconnecting = true;
        login_check_pending = true;
        login_protection_feedback.visible = false;
        update_login_protection_status();
        // Normal account reconnect: retains keys, proxy/Tor routing, DNSSEC,
        // certificate validation and the account's current authentication policy.
        yield manager.disconnect_account(selected);
        bool still_present = selected.enabled && selected_model.account_details.has_key(selected) &&
            selected_model.account_details[selected].account == selected;
        if (still_present) manager.connect_account(selected);
        if (generation != login_check_generation || model != selected_model ||
                model.selected_account == null || account != selected) return;
        login_check_disconnecting = false;
        update_login_protection_status();
    }

    private void update_login_protection_status() {
        if (model == null || model.selected_account == null) return;
        var manager = model.stream_interactor.connection_manager;
        var stream = manager.get_stream(account) as TlsXmppStream;
        var state = manager.get_state(account);
        var error = manager.get_error(account);
        var flag = stream != null ? stream.get_flag(Sasl.Flag.IDENTITY) : null;
        bool tls = stream != null && stream.has_tls_transport();
        var availability = login_check_disconnecting ? Util.LoginProtectionAvailability.CHECKING :
            Util.login_protection_availability(account.enabled, state, tls, flag, error);
        updating_login_protection = true;
        Util.render_login_protection_controls(login_protection_mode, login_protection_server,
            login_protection_icon, login_protection_spinner, availability, account.require_channel_binding);
        updating_login_protection = false;
        login_protection_check.sensitive = account.enabled && !login_check_pending &&
            availability != Util.LoginProtectionAvailability.CHECKING;
        login_protection_reset_row.visible = account.require_channel_binding &&
            availability != Util.LoginProtectionAvailability.AVAILABLE && availability != Util.LoginProtectionAvailability.CHECKING;
        login_protection_reset.sensitive = account.enabled && !login_check_pending;
        login_protection_status.subtitle = Util.login_protection_status_text(
            account.enabled, login_check_disconnecting ? ConnectionManager.ConnectionState.CONNECTING : state,
            error, account.domainpart, tls, flag);
        if (login_check_pending && !login_check_disconnecting && state != ConnectionManager.ConnectionState.CONNECTING) {
            login_check_pending = false;
            bool success = availability == Util.LoginProtectionAvailability.AVAILABLE;
            show_login_protection_feedback(success, success
                ? _("Reconnected. Extra login protection is active for this account.")
                : error != null ? get_status_label() : _("Extra login protection could not be confirmed. Check this account's connection status."));
            login_protection_check.sensitive = account.enabled;
            login_protection_reset.sensitive = account.enabled;
        } else if (!login_check_pending && ((availability != Util.LoginProtectionAvailability.AVAILABLE &&
                login_protection_feedback.has_css_class("success")) ||
                (availability == Util.LoginProtectionAvailability.AVAILABLE && login_protection_feedback.has_css_class("error")))) {
            login_protection_feedback.visible = false;
        }
    }

    private void update_dns_security_status() {
        if (model == null || model.selected_account == null) return;
        var manager = model.stream_interactor.connection_manager;
        var failure = manager.get_error(account);
        if (failure != null && failure.dns_security_error != null) {
            dns_security_status.subtitle = dns_security_error_text(failure.dns_security_error);
            return;
        }
        try {
            if (manager.get_dns_security_mode(account) == DnsSecurity.Mode.OFF) {
                dns_security_status.subtitle = _("Disabled for this account. Normal TLS certificate checks remain active.");
                return;
            }
        } catch (Error error) {
            dns_security_status.subtitle = dns_security_error_text(error);
            return;
        }
        if (!DnsSecurity.Configuration.supported()) {
            dns_security_status.subtitle = _("This build does not include DNSSEC and DANE support.");
            return;
        }
        if (manager.get_state(account) == ConnectionManager.ConnectionState.CONNECTING) {
            dns_security_status.subtitle = _("Checking the server connection…");
        } else if (manager.get_state(account) == ConnectionManager.ConnectionState.CONNECTED) {
            var stream = model.stream_interactor.get_stream(account) as TlsXmppStream;
            dns_security_status.subtitle = stream != null && stream.dns_security != null && stream.dns_security.verified ?
                _("DNSSEC and DANE verified for this connection.") :
                _("Connected using normal TLS checks; DANE is not available for this connection.");
        } else {
            dns_security_status.subtitle = _("Verification will run when this account connects.");
        }
    }

    private string? get_connection_error_description() {
        if (model.selected_account == null) {
            return null;
        }
        ConnectionManager.ConnectionError? error = model.selected_account.connection_error;
        if (error == null) return null;

        switch (error.source) {
            case ConnectionManager.ConnectionError.Source.SASL:
                return Util.sasl_error_message(error.identifier, account.domainpart);
            case ConnectionManager.ConnectionError.Source.TLS:
                return _("Invalid TLS certificate");
            case ConnectionManager.ConnectionError.Source.DNS_SECURITY:
                return error.dns_security_error != null ? dns_security_error_text(error.dns_security_error) : _("DNSSEC or DANE verification failed. Your selected protection remains enabled; apply again to retry.");
            case ConnectionManager.ConnectionError.Source.CONNECTION:
            case ConnectionManager.ConnectionError.Source.STREAM_ERROR:
                // Fall through to default error handling
                break;
        }
        if (error.identifier != null) {
            return _("Error") + ": " + error.identifier;
        } else {
            return _("Error");
        }
    }
}

public class Dino.Ui.NaturalDirectionBoxLayout : LayoutManager {
    private BoxLayout original;
    private BoxLayout alternative;

    public NaturalDirectionBoxLayout(BoxLayout original) {
        this.original = original;
        if (original.orientation == Orientation.HORIZONTAL) {
            this.alternative = new BoxLayout(Orientation.VERTICAL);
            this.alternative.spacing = this.original.spacing / 2;
        }
    }

    public override SizeRequestMode get_request_mode(Widget widget) {
        return original.orientation == Orientation.HORIZONTAL ? SizeRequestMode.HEIGHT_FOR_WIDTH : SizeRequestMode.WIDTH_FOR_HEIGHT;
    }

    public override void allocate(Widget widget, int width, int height, int baseline) {
        int blind_minimum, blind_natural, blind_minimum_baseline, blind_natural_baseline;
        original.measure(widget, original.orientation, -1, out blind_minimum, out blind_natural, out blind_minimum_baseline, out blind_natural_baseline);
        int for_size = (original.orientation == Orientation.HORIZONTAL ? width : height);
        if (for_size >= blind_minimum) {
            original.allocate(widget, width, height, baseline);
        } else {
            alternative.allocate(widget, width, height, baseline);
        }
    }

    public override void measure(Widget widget, Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        if (for_size == -1) {
            original.measure(widget, orientation, -1, out minimum, out natural, out minimum_baseline, out natural_baseline);
            int alt_minimum, alt_natural, alt_minimum_baseline, alt_natural_baseline;
            alternative.measure(widget, orientation, -1, out alt_minimum, out alt_natural, out alt_minimum_baseline, out alt_natural_baseline);
            if (alt_minimum < minimum && alt_minimum != -1) minimum = alt_minimum;
            if (alt_minimum_baseline < minimum_baseline && alt_minimum_baseline != -1) minimum_baseline = alt_minimum_baseline;
        } else {
            Orientation other_orientation = orientation == Orientation.HORIZONTAL ? Orientation.VERTICAL : Orientation.HORIZONTAL;
            int blind_minimum, blind_natural, blind_minimum_baseline, blind_natural_baseline;
            original.measure(widget, other_orientation, -1, out blind_minimum, out blind_natural, out blind_minimum_baseline, out blind_natural_baseline);
            if (for_size >= blind_minimum) {
                original.measure(widget, orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
            } else {
                alternative.measure(widget, orientation, for_size, out minimum, out natural, out minimum_baseline, out natural_baseline);
            }
        }
        if (natural < minimum) natural = minimum;
        if (orientation == Orientation.HORIZONTAL) {
            minimum_baseline = -1;
            natural_baseline = -1;
        }
    }
}
