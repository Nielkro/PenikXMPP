/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gtk;
using Pango;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.ManageAccounts {

[GtkTemplate (ui = "/im/dinox/dinox/preferences_window/add_account_dialog.ui")]
public class AddAccountDialog : Adw.Dialog {

    public signal void added(Account account);

    private static AddAccountDialog? active_regular_dialog = null;

    enum Page {
        SIGN_IN,
        SIGN_IN_TLS_ERROR,
        CREATE_ACCOUNT_SELECT_SERVER,
        CREATE_ACCOUNT_REGISTER_FORM,
        SUCCESS
    }

    [GtkChild] private unowned Stack stack;

    [GtkChild] private unowned Revealer notification_revealer;
    [GtkChild] private unowned Label notification_label;

    // Sign in - JID
    [GtkChild] private unowned Label sign_in_error_label;
    [GtkChild] private unowned Adw.EntryRow jid_entry;
    [GtkChild] private unowned Adw.PreferencesGroup password_group;
    [GtkChild] private unowned Adw.PasswordEntryRow password_entry;
    [GtkChild] private unowned Adw.ExpanderRow advanced_expander;
    [GtkChild] private unowned Adw.EntryRow custom_host_entry;
    [GtkChild] private unowned Adw.EntryRow custom_port_entry;
    [GtkChild] private unowned Adw.SwitchRow sign_in_proxy_enable_row;
    [GtkChild] private unowned Adw.SwitchRow sign_in_allow_plain_row;
    [GtkChild] private unowned Adw.EntryRow sign_in_proxy_host_entry;
    [GtkChild] private unowned Adw.EntryRow sign_in_proxy_port_entry;
    [GtkChild] private unowned Adw.EntryRow sign_in_proxy_user_entry;
    [GtkChild] private unowned Adw.PasswordEntryRow sign_in_proxy_pass_entry;
    [GtkChild] private unowned Button sign_in_continue_button;
    [GtkChild] private unowned Spinner sign_in_continue_spinner;
    [GtkChild] private unowned Button sign_in_serverlist_button;

    // Sign in - TLS error
    [GtkChild] private unowned Box sign_in_tls_box;
    [GtkChild] private unowned Label sign_in_tls_label;
    [GtkChild] private unowned Button sign_in_tls_back_button;
    [GtkChild] private unowned Button sign_in_tls_trust_button;

    // Select Server
    [GtkChild] private unowned Button login_button;
    [GtkChild] private unowned Spinner select_server_continue_spinner;
    [GtkChild] private unowned Button select_server_continue;
    [GtkChild] private unowned Label register_form_continue_label;
    [GtkChild] private unowned ListBox server_list_box;
    [GtkChild] private unowned Label provider_directory_status_label;
    [GtkChild] private unowned Button provider_directory_refresh_button;
    [GtkChild] private unowned Stack provider_directory_refresh_indicator_stack;
    [GtkChild] private unowned Spinner provider_directory_refresh_spinner;
    [GtkChild] private unowned Entry server_entry;

    // Register Form
    [GtkChild] private unowned Button back_button;
    [GtkChild] private unowned Box form_box;
    [GtkChild] private unowned Spinner register_form_continue_spinner;
    [GtkChild] private unowned Button register_form_continue;

    // Success
    [GtkChild] private unowned Label success_description;
    [GtkChild] private unowned Button success_continue_button;

    private StreamInteractor stream_interactor;
    private Database db;
    private ProviderDirectoryStore provider_directory_store = new ProviderDirectoryStore();
    private uint provider_directory_load_source_id = 0;
    private bool provider_directory_load_started = false;
    private bool provider_directory_loading = false;
    private bool provider_directory_refreshing = false;
    private Cancellable? provider_directory_refresh_cancellable = null;
    private ArrayList<ProviderDirectoryProvider> provider_directory_providers = new ArrayList<ProviderDirectoryProvider>();
    private HashMap<ListBoxRow, ProviderDirectoryProvider> list_box_providers = new HashMap<ListBoxRow, ProviderDirectoryProvider>();
    private string provider_directory_status_message = "";
    private ProviderDirectoryProvider? selected_provider = null;
    private Jid? server_jid = null;
    private Jid? login_jid = null;
    private Xep.InBandRegistration.Form? form = null;
    private string? registration_web_page_url = null;
    private string? pending_external_registration_url = null;
    private bool pending_external_return_to_sign_in = false;
    private uint external_registration_return_source_id = 0;
    private uint notification_timeout_id = 0;
    private ulong server_list_row_activated_handler_id = 0;
    private TlsCertificate? pending_tls_certificate = null;
    private TlsCertificateFlags pending_tls_flags;
    private string? invite_preauth_token = null;
    private string? invite_username = null;
    private bool sign_in_in_progress = false;
    private bool select_server_in_progress = false;
    private bool registration_submit_in_progress = false;
    private bool account_setup_completed = false;
    private bool dialog_closed = false;
    private bool dialog_disposed = false;
    private Page current_page = Page.SIGN_IN;

    public static AddAccountDialog present_regular(StreamInteractor stream_interactor, Database db, Gtk.Widget? parent, bool start_registration, out bool created) {
        created = false;
        if (active_regular_dialog != null) {
            AddAccountDialog dialog = (!) active_regular_dialog;
            if (start_registration && dialog.current_page == Page.SIGN_IN) {
                dialog.show_select_server();
            } else if (!start_registration && dialog.current_page == Page.CREATE_ACCOUNT_SELECT_SERVER) {
                dialog.show_sign_in();
            }
            dialog.present(parent);
            return dialog;
        }

        AddAccountDialog dialog = new AddAccountDialog(stream_interactor, db, start_registration);
        active_regular_dialog = dialog;
        created = true;
        dialog.closed.connect(() => {
            if (active_regular_dialog == dialog) {
                active_regular_dialog = null;
            }
        });
        dialog.present(parent);
        return dialog;
    }

    public AddAccountDialog(StreamInteractor stream_interactor, Database db, bool start_registration = false, string? invite_jid = null, string? invite_preauth_token = null) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.title = _("Add Account");
        this.invite_preauth_token = invite_preauth_token;

#if WINDOWS
        // GDK-Win32 has issues with Adw.Dialog sheet overlays: mouse events
        // don't reach overlaid widgets reliably. Force floating (separate
        // window) mode to avoid the cursor-behind-dialog problem.
        this.presentation_mode = Adw.DialogPresentationMode.FLOATING;
#endif

        // Sign in - Jid
        jid_entry.changed.connect(on_jid_entry_changed);
        password_entry.changed.connect(update_sign_in_button_state);
        custom_host_entry.changed.connect(on_sign_in_connection_settings_changed);
        custom_port_entry.changed.connect(on_sign_in_connection_settings_changed);
        sign_in_proxy_enable_row.notify["active"].connect(() => {
            on_sign_in_connection_settings_changed();
        });
        sign_in_proxy_host_entry.changed.connect(on_sign_in_connection_settings_changed);
        sign_in_proxy_port_entry.changed.connect(on_sign_in_connection_settings_changed);
        sign_in_proxy_user_entry.changed.connect(on_sign_in_connection_settings_changed);
        sign_in_proxy_pass_entry.changed.connect(on_sign_in_connection_settings_changed);
        sign_in_continue_button.clicked.connect(continue_sign_in);
        sign_in_serverlist_button.clicked.connect(show_select_server);

        // Sign in - TLS error
        sign_in_tls_back_button.clicked.connect(() => show_sign_in(true) );
        sign_in_tls_trust_button.clicked.connect(trust_tls_certificate);

        // Select Server
        server_entry.placeholder_text = _("Search providers or enter a server domain");
        server_entry.changed.connect(on_server_entry_changed);
        select_server_continue.clicked.connect(on_select_server_continue);
        login_button.clicked.connect(() => show_sign_in() );
        server_list_box.selection_mode = SelectionMode.NONE;
        server_list_row_activated_handler_id = server_list_box.row_activated.connect(on_server_list_row_activated);
        provider_directory_status_label.label = _("Loading provider list…");
        provider_directory_refresh_button.clicked.connect(start_provider_directory_refresh);
        provider_directory_refresh_indicator_stack.visible_child_name = "refresh";
        provider_directory_refresh_spinner.stop();

        // Register Form
        register_form_continue.clicked.connect(continue_registration_form);
        back_button.clicked.connect(() => {
            show_select_server();
            back_button.visible = false;
        });

        // Success
        success_continue_button.clicked.connect(() => close());

        if (invite_jid != null && invite_preauth_token != null && invite_preauth_token != "") {
            show_invite_registration((!) invite_jid);
        } else if (start_registration) {
            show_select_server();
        } else {
            show_sign_in();
        }

        this.closed.connect(() => {
            dialog_closed = true;
            cancel_pending_sources();
        });
    }

    public override void dispose() {
        dialog_disposed = true;
        if (active_regular_dialog == this) {
            active_regular_dialog = null;
        }
        cancel_pending_sources();
        pending_external_registration_url = null;
        pending_external_return_to_sign_in = false;
        if (server_list_row_activated_handler_id != 0 && SignalHandler.is_connected(server_list_box, server_list_row_activated_handler_id)) {
            SignalHandler.disconnect(server_list_box, server_list_row_activated_handler_id);
        }
        server_list_row_activated_handler_id = 0;
        base.dispose();
    }

    private bool is_inactive() {
        return dialog_closed || dialog_disposed;
    }

    private void cancel_pending_sources() {
        if (external_registration_return_source_id != 0) {
            Source.remove(external_registration_return_source_id);
            external_registration_return_source_id = 0;
        }
        if (notification_timeout_id != 0) {
            Source.remove(notification_timeout_id);
            notification_timeout_id = 0;
        }
        if (provider_directory_load_source_id != 0) {
            Source.remove(provider_directory_load_source_id);
            provider_directory_load_source_id = 0;
        }
        if (provider_directory_refresh_cancellable != null) {
            ((!) provider_directory_refresh_cancellable).cancel();
            provider_directory_refresh_cancellable = null;
        }
        provider_directory_refreshing = false;
        provider_directory_refresh_spinner.stop();
    }

    private void ensure_provider_directory_loaded() {
        if (provider_directory_load_started) return;
        provider_directory_load_started = true;
        provider_directory_loading = true;
        provider_directory_status_message = _("Loading provider list…");
        populate_provider_list();

        provider_directory_load_source_id = Idle.add(() => {
            provider_directory_load_source_id = 0;
            if (is_inactive()) return false;

            load_provider_directory_initial();
            provider_directory_loading = false;
            provider_directory_refresh_button.sensitive = true;
            return false;
        });
    }

    private void load_provider_directory_initial() {
        if (is_inactive()) return;
        try {
            ProviderDirectoryLoadSource source;
            Gee.List<ProviderDirectoryProvider> providers = provider_directory_store.load_initial_with_source(out source);
            set_provider_directory_providers(providers);
            provider_directory_status_message = source == ProviderDirectoryLoadSource.CACHE
                    ? saved_provider_directory_status(false)
                    : _("Showing bundled provider list.");
            populate_provider_list();
        } catch (ProviderDirectoryError error) {
            warning("Provider directory initial load failed: %s", error.message);
            provider_directory_providers.clear();
            provider_directory_status_message = _("Provider list unavailable. Enter a server domain manually.");
            populate_provider_list();
        }
    }

    private void start_provider_directory_refresh() {
        if (provider_directory_refreshing || provider_directory_loading || is_inactive()) return;

        set_provider_directory_refreshing(true);
        provider_directory_status_message = _("Updating provider list…");
        update_provider_directory_status(provider_directory_providers.size);
        provider_directory_refresh_cancellable = new Cancellable();
        refresh_provider_directory_from_mirror.begin((obj, res) => {
            refresh_provider_directory_from_mirror.end(res);
        });
    }

    private async void refresh_provider_directory_from_mirror() {
        Cancellable? cancellable = provider_directory_refresh_cancellable;
        try {
            Dino.Plugins.AccountProxyProvider? proxy_provider =
                    stream_interactor.get_module<Dino.Plugins.AccountProxyProvider>(new SimpleIdentity("tor-manager"));
            Gee.List<ProviderDirectoryProvider> providers = yield provider_directory_store.refresh_from_mirror(cancellable, proxy_provider);
            if (is_inactive() || cancellable == null || ((!) cancellable).is_cancelled()) return;

            set_provider_directory_providers(providers);
            provider_directory_status_message = saved_provider_directory_status(true);
            populate_provider_list();
        } catch (Error error) {
            if (cancellable == null || !((!) cancellable).is_cancelled()) {
                warning("Provider directory mirror refresh failed: %s", error.message);
                if (!is_inactive()) {
                    provider_directory_status_message = _("Provider list could not be updated. Showing the last available list. Use refresh to try again.");
                    populate_provider_list();
                }
            }
        } finally {
            if (provider_directory_refresh_cancellable == cancellable) {
                provider_directory_refresh_cancellable = null;
            }
            if (!is_inactive()) {
                set_provider_directory_refreshing(false);
            }
        }
    }

    private void set_provider_directory_refreshing(bool refreshing) {
        provider_directory_refreshing = refreshing;
        provider_directory_refresh_button.sensitive = !refreshing && !provider_directory_loading;
        provider_directory_refresh_indicator_stack.visible_child_name = refreshing ? "loading" : "refresh";
        if (refreshing) {
            provider_directory_refresh_spinner.start();
        } else {
            // A hidden spinning spinner still consumes resources.
            provider_directory_refresh_spinner.stop();
        }
    }

    private string saved_provider_directory_status(bool just_updated) {
        DateTime? modified = provider_directory_store.get_cache_modified_time();
        if (modified == null) {
            return just_updated ? _("Provider list updated.") : _("Showing saved provider list.");
        }

        DateTime local_modified = ((!) modified).to_local();
        string timestamp = local_modified.format("%x %H:%M");
        return just_updated
                ? _("Provider list updated: %s").printf(timestamp)
                : _("Showing saved provider list. Updated: %s").printf(timestamp);
    }

    private void set_provider_directory_providers(Gee.List<ProviderDirectoryProvider> providers) {
        provider_directory_providers.clear();
        foreach (ProviderDirectoryProvider provider in providers) {
            provider_directory_providers.add(provider);
        }
        provider_directory_providers.sort(compare_provider_directory_providers);
    }

    private int compare_provider_directory_providers(ProviderDirectoryProvider left, ProviderDirectoryProvider right) {
        int category_compare = provider_category_rank(left.category) - provider_category_rank(right.category);
        if (category_compare != 0) return category_compare;
        return left.jid.collate(right.jid);
    }

    private int provider_category_rank(string category) {
        if (category == "A") return 0;
        if (category == "B") return 1;
        return 2;
    }

    private void on_server_entry_changed() {
        select_server_continue.sensitive = !select_server_in_progress && is_valid_manual_server_domain(server_entry.text);
        populate_provider_list();
    }

    private bool is_valid_manual_server_domain(string value) {
        try {
            Jid jid = new Jid(value.strip());
            return jid.localpart == null && jid.resourcepart == null;
        } catch (InvalidJidError e) {
            return false;
        }
    }

    private void populate_provider_list() {
        if (is_inactive()) return;
        clear_provider_list_box();

        int shown = 0;
        foreach (ProviderDirectoryProvider provider in provider_directory_providers) {
            if (!provider_matches_filter(provider)) continue;

            ListBoxRow row = build_provider_row(provider);
            list_box_providers[row] = provider;
            server_list_box.append(row);
            shown++;
        }

        if (provider_directory_providers.is_empty) {
            var empty_row = new Adw.ActionRow() {
                title = provider_directory_loading ? _("Loading provider list…") : _("No providers available"),
                subtitle = _("Enter a server domain manually below.")
            };
            empty_row.sensitive = false;
            server_list_box.append(empty_row);
        } else if (shown == 0) {
            var empty_row = new Adw.ActionRow() {
                title = _("No matching providers"),
                subtitle = _("Enter a server domain manually below.")
            };
            empty_row.sensitive = false;
            server_list_box.append(empty_row);
        }

        update_provider_directory_status(shown);
    }

    private void clear_provider_list_box() {
        Widget? child = server_list_box.get_first_child();
        while (child != null) {
            server_list_box.remove(child);
            child = server_list_box.get_first_child();
        }
        list_box_providers.clear();
    }

    private ListBoxRow build_provider_row(ProviderDirectoryProvider provider) {
        var row = new Adw.ActionRow() {
            title = Markup.escape_text(provider.jid),
            subtitle = provider_summary_markup(provider),
            use_markup = true
        };
        row.title_lines = 1;
        row.subtitle_lines = 3;
        row.activatable = true;
        row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
        return row;
    }

    private string provider_summary_markup(ProviderDirectoryProvider provider) {
        string summary = Markup.escape_text(provider_summary(provider));
        string? website = select_localized_url(provider.websites);
        if (website == null) return summary;

        string website_link = "<a href=\"%s\">%s</a>".printf(
                Markup.escape_text((!) website),
                Markup.escape_text(_("Website")));
        if (summary == "") return website_link;
        return "%s\n%s".printf(website_link, summary);
    }

    private string provider_summary(ProviderDirectoryProvider provider) {
        var parts = new ArrayList<string>();
        parts.add(_("Category %s").printf(provider.category));
        parts.add(provider_registration_mode(provider));
        if (provider.server_locations.size > 0) {
            parts.add(_("Locations: %s").printf(join_strings(provider.server_locations, ", ")));
        }
        if (provider.in_band_registration_email_address_required) {
            parts.add(_("Email required"));
        }
        if (provider.in_band_registration_captcha_required) {
            parts.add(_("CAPTCHA required"));
        }
        if (provider.free_of_charge) {
            parts.add(_("Free account"));
        }
        return join_strings(parts, " · ");
    }

    private string provider_registration_mode(ProviderDirectoryProvider provider) {
        return provider.in_band_registration ? _("Register in DinoX") : _("Register on provider website");
    }

    private bool provider_matches_filter(ProviderDirectoryProvider provider) {
        string query = server_entry.text.strip().down();
        if (query == "") return true;
        if (provider.jid.down().index_of(query) >= 0) return true;
        if (provider.category.down().index_of(query) >= 0) return true;
        if (provider_registration_mode(provider).down().index_of(query) >= 0) return true;
        foreach (string location in provider.server_locations) {
            if (location.down().index_of(query) >= 0) return true;
        }
        return false;
    }

    private string? select_localized_url(Gee.Map<string, string> urls) {
        if (urls.size == 0) return null;

        string? language = get_current_language_code();
        if (language != null && language.length >= 2) {
            string short_language = ((!) language).substring(0, 2);
            if (urls.has_key(short_language)) return urls[short_language];
        }
        if (urls.has_key("en")) return urls["en"];

        foreach (var entry in urls.entries) {
            return entry.value;
        }
        return null;
    }

    private string? get_current_language_code() {
        string? language_env = Environment.get_variable("LANGUAGE");
        if (language_env != null && ((!) language_env).strip() != "") {
            foreach (string language in ((!) language_env).split(":")) {
                string? normalized = normalize_locale_language(language);
                if (normalized != null) return normalized;
            }
        }

        return normalize_locale_language(Intl.setlocale(LocaleCategory.MESSAGES, null));
    }

    private string? normalize_locale_language(string? locale) {
        if (locale == null) return null;

        string normalized = ((!) locale).strip().replace("-", "_");
        if (normalized == "" || normalized == "C" || normalized == "POSIX") return null;

        int end = normalized.length;
        int underscore = normalized.index_of("_");
        if (underscore > 0 && underscore < end) end = underscore;
        int dot = normalized.index_of(".");
        if (dot > 0 && dot < end) end = dot;
        int modifier = normalized.index_of("@");
        if (modifier > 0 && modifier < end) end = modifier;
        if (end < 2) return null;

        return normalized.substring(0, end).ascii_down();
    }

    private string join_strings(Gee.Collection<string> values, string separator) {
        StringBuilder builder = new StringBuilder();
        bool first = true;
        foreach (string value in values) {
            if (!first) builder.append(separator);
            builder.append(value);
            first = false;
        }
        return builder.str;
    }

    private void update_provider_directory_status(int visible_count) {
        if (provider_directory_refreshing) {
            provider_directory_status_label.label = provider_directory_status_message;
            return;
        }
        if (!provider_directory_providers.is_empty && visible_count == 0 && server_entry.text.strip() != "") {
            provider_directory_status_label.label = _("No matching provider. You can still enter the server domain manually.");
            return;
        }
        provider_directory_status_label.label = provider_directory_status_message;
    }

    private void show_invite_registration(string invited_jid) {
        try {
            Jid jid = new Jid(invited_jid);
            server_jid = jid.domain_jid;
            invite_username = jid.localpart;
            show_invite_registration_loading();
            show_registration_form_for_server(server_jid);
        } catch (InvalidJidError e) {
            warning("Invalid registration invite JID: %s", e.message);
            show_select_server();
            display_notification(_("Invalid invitation address"));
        }
    }

    private void continue_sign_in() {
        on_sign_in_continue_button_clicked.begin((obj, res) => {
            on_sign_in_continue_button_clicked.end(res);
        });
    }

    private void trust_tls_certificate() {
        on_tls_trust_button_clicked.begin((obj, res) => {
            on_tls_trust_button_clicked.end(res);
        });
    }

    private void show_registration_form_for_server(Jid server_jid) {
        request_show_register_form.begin(server_jid, (obj, res) => {
            request_show_register_form.end(res);
        });
    }

    private void continue_registration_form() {
        on_register_form_continue_clicked.begin((obj, res) => {
            on_register_form_continue_clicked.end(res);
        });
    }

    private void show_sign_in(bool keep_credentials = false) {
        switch_stack_page(Page.SIGN_IN);

        this.title = _("Sign in");
        registration_web_page_url = null;
        selected_provider = null;

        set_default_widget(sign_in_continue_button);
        sign_in_error_label.visible = false;
        set_sign_in_busy(false);
        if (!keep_credentials) {
            jid_entry.text = "";
            password_entry.text = "";
            custom_host_entry.text = "";
            custom_port_entry.text = "";
            sign_in_proxy_enable_row.active = false;
            sign_in_proxy_host_entry.text = "";
            sign_in_proxy_port_entry.text = "";
            sign_in_proxy_user_entry.text = "";
            sign_in_proxy_pass_entry.text = "";
        }
        update_sign_in_proxy_fields_state();
        password_group.visible = true;
        sign_in_serverlist_button.visible = true;
        update_sign_in_button_state();
        if (keep_credentials) {
            password_entry.grab_focus();
        } else {
            jid_entry.grab_focus();
        }
    }

    private void show_tls_error(string domain, TlsCertificateFlags error_flags, TlsCertificate? cert = null) {
        switch_stack_page(Page.SIGN_IN_TLS_ERROR);

        // Store certificate for potential pinning
        pending_tls_certificate = cert;
        pending_tls_flags = error_flags;
        sign_in_tls_trust_button.visible = (cert != null);

        string error_desc = _("The server could not prove that it is %s.").printf("<b>" + domain + "</b>");
        if (TlsCertificateFlags.UNKNOWN_CA in error_flags) {
            error_desc += " " + _("Its security certificate is not trusted by your operating system.");
        } else if (TlsCertificateFlags.BAD_IDENTITY in error_flags) {
            error_desc += " " + _("Its security certificate is issued to another domain.");
        } else if (TlsCertificateFlags.NOT_ACTIVATED in error_flags) {
            error_desc += " " + _("Its security certificate will only become valid in the future.");
        } else if (TlsCertificateFlags.EXPIRED in error_flags) {
            error_desc += " " + _("Its security certificate is expired.");
        }
        sign_in_tls_label.label = error_desc;

        // Add certificate details if available
        if (cert != null) {
            // Remove any previously added cert details
            Widget? child = sign_in_tls_box.get_first_child();
            var to_remove = new Gee.ArrayList<Widget>();
            while (child != null) {
                if (child.name == "cert_details_frame") {
                    to_remove.add(child);
                }
                child = child.get_next_sibling();
            }
            foreach (var w in to_remove) {
                sign_in_tls_box.remove(w);
            }

            var details_frame = build_certificate_details_widget(cert);
            details_frame.name = "cert_details_frame";
            // Insert before the last child (button box)
            sign_in_tls_box.append(details_frame);
            // Reorder: move buttons to end
            Widget? last = sign_in_tls_box.get_last_child();
            if (last != null && last != details_frame) {
                sign_in_tls_box.reorder_child_after(details_frame, sign_in_tls_label);
            }
        }
    }

    private Gtk.Frame build_certificate_details_widget(TlsCertificate cert) {
        string fingerprint = CertificateManager.get_certificate_fingerprint(cert);
        string? issuer = CertificateManager.get_certificate_issuer(cert);
        DateTime? not_before = CertificateManager.get_certificate_not_before(cert);
        DateTime? not_after = CertificateManager.get_certificate_not_after(cert);

        var details_frame = new Frame(null);
        details_frame.add_css_class("view");
        var details_box = new Box(Orientation.VERTICAL, 4);
        details_box.margin_start = 10;
        details_box.margin_end = 10;
        details_box.margin_top = 8;
        details_box.margin_bottom = 8;

        if (issuer != null) {
            var issuer_label = new Label(null);
            issuer_label.set_markup("<small><b>" + _("Issuer:") + "</b> " + Markup.escape_text(issuer) + "</small>");
            issuer_label.xalign = 0;
            issuer_label.wrap = true;
            details_box.append(issuer_label);
        }

        if (not_before != null || not_after != null) {
            string validity = "";
            if (not_before != null) validity += _("From:") + " " + not_before.format("%Y-%m-%d");
            if (not_after != null) {
                if (validity.length > 0) validity += "  ";
                validity += _("Until:") + " " + not_after.format("%Y-%m-%d");
                if (not_after.compare(new DateTime.now_utc()) < 0) {
                    validity += " <span foreground='red'>(" + _("expired") + ")</span>";
                }
            }
            var validity_label = new Label(null);
            validity_label.set_markup("<small><b>" + _("Valid:") + "</b> " + validity + "</small>");
            validity_label.xalign = 0;
            validity_label.wrap = true;
            details_box.append(validity_label);
        }

        var fp_header = new Label(null);
        fp_header.set_markup("<small><b>" + _("SHA-256 Fingerprint:") + "</b></small>");
        fp_header.xalign = 0;
        details_box.append(fp_header);

        var fp_label = new Label(fingerprint);
        fp_label.add_css_class("monospace");
        fp_label.wrap = true;
        fp_label.wrap_mode = Pango.WrapMode.CHAR;
        fp_label.xalign = 0;
        fp_label.selectable = true;
        fp_label.add_css_class("dim-label");
        var fp_attrs = new Pango.AttrList();
        fp_attrs.insert(Pango.attr_scale_new(0.75));
        fp_label.attributes = fp_attrs;
        details_box.append(fp_label);

        details_frame.child = details_box;
        return details_frame;
    }

    private async void on_tls_trust_button_clicked() {
        if (pending_tls_certificate == null || login_jid == null) return;
        if (is_inactive()) return;

        // Pin the certificate
        stream_interactor.connection_manager.pin_certificate(
            login_jid.domainpart, pending_tls_certificate, pending_tls_flags);

        // Clear pending state
        pending_tls_certificate = null;

        // Go back and retry with the now-pinned certificate
        show_sign_in(true);

        // Auto-retry the sign-in
        yield on_sign_in_continue_button_clicked();
    }

    private void show_select_server() {
        switch_stack_page(Page.CREATE_ACCOUNT_SELECT_SERVER);

        this.title = _("Create account");
        registration_web_page_url = null;
        selected_provider = null;
        set_select_server_busy(false);
        server_entry.text = "";
        server_entry.sensitive = true;
        select_server_continue.sensitive = false;
        server_entry.grab_focus();
        set_default_widget(select_server_continue);

        server_list_box.unselect_all();
        ensure_provider_directory_loaded();
    }

    private void show_register_form() {
        switch_stack_page(Page.CREATE_ACCOUNT_REGISTER_FORM);

        set_default_widget(register_form_continue);
    }

    private void show_provider_web_registration(ProviderDirectoryProvider provider, string message) {
        string? registration_url = select_localized_url(provider.registration_web_pages);
        if (registration_url == null) {
            display_notification(_("No registration website is available for this provider."));
            return;
        }

        try {
            server_jid = new Jid(provider.jid);
        } catch (InvalidJidError e) {
            warning("Invalid address from provider directory: %s", e.message);
            display_notification(_("Invalid address"));
            return;
        }

        form = null;
        registration_web_page_url = registration_url;
        switch_stack_page(Page.CREATE_ACCOUNT_REGISTER_FORM);
        this.title = _("Register on %s").printf(provider.jid);
        clear_form_box();

        form_box.append(new Label(message) { xalign=0, wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });
        form_box.append(new Label(_("After creating the account, return here and sign in with your new XMPP address.")) { xalign=0,
            wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });

        register_form_continue.visible = true;
        register_form_continue.sensitive = true;
        register_form_continue_spinner.visible = false;
        register_form_continue_label.label = _("Open website");
        register_form_continue.grab_focus();
        set_default_widget(register_form_continue);
    }

    private void open_external_url_after_current_event(string url, bool return_to_sign_in) {
        if (external_registration_return_source_id != 0) {
            Source.remove(external_registration_return_source_id);
        }

        pending_external_registration_url = url;
        pending_external_return_to_sign_in = return_to_sign_in;
        external_registration_return_source_id = Idle.add(() => {
            external_registration_return_source_id = 0;
            if (is_inactive()) return false;
            string? url_to_open = pending_external_registration_url;
            bool should_return_to_sign_in = pending_external_return_to_sign_in;
            pending_external_registration_url = null;
            pending_external_return_to_sign_in = false;
            if (url_to_open != null) {
                try {
                    AppInfo.launch_default_for_uri((!) url_to_open, null);
                } catch (Error e) {
                    warning("AddAccountDialog: Failed to launch registration URI %s: %s", (!) url_to_open, e.message);
                }
            }
            if (should_return_to_sign_in) {
                show_sign_in();
            }
            return false;
        });
    }

    private void show_invite_registration_loading() {
        stack.transition_type = StackTransitionType.NONE;
        switch_stack_page(Page.CREATE_ACCOUNT_REGISTER_FORM);

        this.title = _("Account Invitation");
        clear_form_box();
        form_box.append(new Label(_("Loading the registration form for %s...").printf(server_jid.to_string())) { xalign=0,
            wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });
        register_form_continue.visible = false;
        register_form_continue.sensitive = false;
        register_form_continue_spinner.visible = true;
    }

    private void show_success(Account account) {
        account_setup_completed = true;
        registration_submit_in_progress = false;
        sign_in_continue_spinner.visible = false;
        register_form_continue_spinner.visible = false;
        select_server_continue_spinner.visible = false;
        sign_in_continue_button.sensitive = false;
        register_form_continue.sensitive = false;
        select_server_continue.sensitive = false;
        notification_revealer.set_reveal_child(false);
        notification_label.label = "";
        switch_stack_page(Page.SUCCESS);

        success_description.label = _("You can now use the account %s.").printf("<b>" + Markup.escape_text(account.bare_jid.to_string()) + "</b>");

        set_default_widget(success_continue_button);
    }

    private void on_jid_entry_changed() {
        // Consent applies to this address, not the next account entered here.
        sign_in_allow_plain_row.active = false;
        pending_tls_certificate = null;
        sign_in_error_label.visible = false;
        update_sign_in_button_state();
    }

    private void on_sign_in_connection_settings_changed() {
        pending_tls_certificate = null;
        sign_in_error_label.visible = false;
        update_sign_in_proxy_fields_state();
        update_sign_in_button_state();
    }

    private AccountConnectionInput get_sign_in_connection_input() {
        return new AccountConnectionInput(
                custom_host_entry.text,
                custom_port_entry.text,
                sign_in_proxy_enable_row.active,
                sign_in_proxy_host_entry.text,
                sign_in_proxy_port_entry.text,
                sign_in_proxy_user_entry.text,
                sign_in_proxy_pass_entry.text);
    }

    private void update_sign_in_proxy_fields_state() {
        bool enabled = sign_in_proxy_enable_row.active;
        sign_in_proxy_host_entry.visible = enabled;
        sign_in_proxy_port_entry.visible = enabled;
        sign_in_proxy_user_entry.visible = enabled;
        sign_in_proxy_pass_entry.visible = enabled;

        AccountConnectionInputIssue issue = get_sign_in_connection_input().validate();
        advanced_expander.subtitle = issue == AccountConnectionInputIssue.CUSTOM_SERVER
                ? _("Enter a valid server hostname and port.")
                : _("Optional: Custom server or per-account SOCKS5 proxy");
        switch (issue) {
            case AccountConnectionInputIssue.PROXY_ENDPOINT:
                sign_in_proxy_enable_row.subtitle = _("Enter a valid proxy or I2P router address and port.");
                break;
            case AccountConnectionInputIssue.PROXY_CREDENTIALS:
                sign_in_proxy_enable_row.subtitle = _("Enter a proxy username when using a proxy password.");
                break;
            default:
                sign_in_proxy_enable_row.subtitle = _("Also use this for an I2P router's SOCKS5 endpoint");
                break;
        }
    }

    private string connection_input_issue_message(AccountConnectionInputIssue issue) {
        switch (issue) {
            case AccountConnectionInputIssue.CUSTOM_SERVER:
                return _("Enter a valid server hostname and port.");
            case AccountConnectionInputIssue.PROXY_ENDPOINT:
                return _("Enter a valid proxy or I2P router address and port.");
            case AccountConnectionInputIssue.PROXY_CREDENTIALS:
                return _("Enter a proxy username when using a proxy password.");
            case AccountConnectionInputIssue.RUNTIME_PROXY_UNAVAILABLE:
                return _("Tor is enabled but not ready. Wait until Tor is connected before signing in.");
            default:
                return _("Something went wrong");
        }
    }

    private AccountConnectionInputIssue apply_enabled_runtime_proxy(Account account) {
        if (sign_in_proxy_enable_row.active) return AccountConnectionInputIssue.NONE;

        Dino.Plugins.AccountProxyProvider? provider =
                stream_interactor.get_module<Dino.Plugins.AccountProxyProvider>(new SimpleIdentity("tor-manager"));
        if (provider == null || !provider.proxy_enabled) return AccountConnectionInputIssue.NONE;

        return AccountConnectionInput.apply_runtime_proxy_to(account,
                provider.proxy_enabled,
                provider.proxy_ready,
                provider.proxy_type,
                provider.proxy_host,
                provider.proxy_port);
    }

    private void update_sign_in_button_state() {
        bool valid_jid = false;
        try {
            login_jid = new Jid(jid_entry.text);
            valid_jid = login_jid.localpart != null && login_jid.resourcepart == null;
        } catch (InvalidJidError e) {
            login_jid = null;
        }
        bool valid_connection = get_sign_in_connection_input().validate() == AccountConnectionInputIssue.NONE;
        sign_in_continue_button.sensitive = !sign_in_in_progress && valid_jid &&
                password_entry.text.length > 0 && valid_connection;
    }

    private void set_sign_in_busy(bool busy) {
        sign_in_in_progress = busy;
        sign_in_continue_spinner.visible = busy;
        jid_entry.sensitive = !busy;
        password_entry.sensitive = !busy;
        custom_host_entry.sensitive = !busy;
        custom_port_entry.sensitive = !busy;
        sign_in_allow_plain_row.sensitive = !busy;
        sign_in_proxy_enable_row.sensitive = !busy;
        sign_in_proxy_host_entry.sensitive = !busy;
        sign_in_proxy_port_entry.sensitive = !busy;
        sign_in_proxy_user_entry.sensitive = !busy;
        sign_in_proxy_pass_entry.sensitive = !busy;
        sign_in_serverlist_button.sensitive = !busy;
        update_sign_in_button_state();
    }

    private async void on_sign_in_continue_button_clicked() {
        if (sign_in_in_progress) return;
        if (is_inactive()) return;
        try {
            login_jid = new Jid(jid_entry.text);
            if (login_jid.localpart == null || login_jid.resourcepart != null || password_entry.text.length == 0) {
                update_sign_in_button_state();
                return;
            }
            sign_in_tls_label.label = "";
            sign_in_error_label.visible = false;

            AccountConnectionInput connection_input = get_sign_in_connection_input();
            AccountConnectionInputIssue input_issue = connection_input.validate();
            if (input_issue != AccountConnectionInputIssue.NONE) {
                sign_in_error_label.label = connection_input_issue_message(input_issue);
                sign_in_error_label.visible = true;
                return;
            }
            Account account = new Account(login_jid, password_entry.text);
            account.allow_plain = sign_in_allow_plain_row.active;
            if (connection_input.apply_to(account) != AccountConnectionInputIssue.NONE) {
                sign_in_error_label.label = _("Invalid connection settings");
                sign_in_error_label.visible = true;
                return;
            }

            AccountConnectionInputIssue runtime_proxy_issue = apply_enabled_runtime_proxy(account);
            if (runtime_proxy_issue != AccountConnectionInputIssue.NONE) {
                sign_in_error_label.label = connection_input_issue_message(runtime_proxy_issue);
                sign_in_error_label.visible = true;
                return;
            }
            set_sign_in_busy(true);

            Register.AccountCheckReturn result = yield stream_interactor.get_module<Register>(Register.IDENTITY).check_account(account);
            if (is_inactive()) return;
            set_sign_in_busy(false);

            if (result.error_source != null) {
                if (result.error_source == ConnectionManager.ConnectionError.Source.TLS && result.error_flags != null) {
                    show_tls_error(login_jid.domainpart, (!) result.error_flags, result.tls_certificate);
                    return;
                }
                sign_in_error_label.visible = true;
                switch (result.error_source) {
                    case ConnectionManager.ConnectionError.Source.SASL:
                        sign_in_error_label.label = Util.sasl_error_message(result.error_identifier, account.domainpart);
                        break;
                    default:
                        sign_in_error_label.label = account.proxy_type == "socks5" || account.proxy_type == "tor"
                                ? _("Could not connect through the SOCKS5 proxy or reach the XMPP server.")
                                : _("Something went wrong");
                        break;
                }
            } else {
                add_activate_account(account);
                show_success(account);
            }
        } catch (InvalidJidError e) {
            set_sign_in_busy(false);
            warning("Invalid address from interface allowed login: %s", e.message);
            sign_in_error_label.visible = true;
            sign_in_error_label.label = _("Invalid address");
        }
    }

    private void on_select_server_continue() {
        if (select_server_in_progress) return;

        try {
            selected_provider = null;
            registration_web_page_url = null;
            server_jid = new Jid(server_entry.text.strip());
            show_registration_form_for_server(server_jid);
        } catch (InvalidJidError e) {
            warning("Invalid address from interface allowed server: %s", e.message);
            display_notification(_("Invalid address"));
        }
    }

    private void on_server_list_row_activated(ListBox box, ListBoxRow row) {
        if (select_server_in_progress) return;
        if (!list_box_providers.has_key(row)) return;

        activate_provider_for_registration(list_box_providers[row]);
    }

    private void activate_provider_for_registration(ProviderDirectoryProvider provider) {
        if (select_server_in_progress) return;
        try {
            selected_provider = provider;
            server_jid = new Jid(provider.jid);
            if (selected_provider != null && !((!) selected_provider).in_band_registration) {
                string? registration_url = select_localized_url(((!) selected_provider).registration_web_pages);
                if (registration_url == null) {
                    display_notification(_("No registration website is available for this provider."));
                    return;
                }
                open_external_url_after_current_event((!) registration_url, true);
                return;
            }
            registration_web_page_url = null;
            show_registration_form_for_server(server_jid);
        } catch (InvalidJidError e) {
            warning("Invalid address from provider directory: %s", e.message);
            display_notification(_("Invalid address"));
        }
    }

    private async void request_show_register_form(Jid server_jid) {
        if (is_inactive()) return;
        bool invite_flow = invite_preauth_token != null && invite_preauth_token != "";
        if (invite_flow) {
            register_form_continue_spinner.visible = true;
        } else {
            set_select_server_busy(true);
        }
        Register.RegistrationFormReturn form_return = yield Register.get_registration_form(server_jid, invite_preauth_token);
        if (is_inactive()) return;
        if (select_server_continue_spinner == null || register_form_continue_spinner == null) {
            return;
        }
        if (invite_flow) {
            register_form_continue_spinner.visible = false;
        } else {
            set_select_server_busy(false);
        }
        if (form_return.form != null) {
            form = form_return.form;
            set_register_form(server_jid, form);
            show_register_form();
        } else if (form_return.error_flags != null) {
            show_tls_error(server_jid.domainpart, form_return.error_flags);
        } else if (form_return.error != null) {
            if (!invite_flow && form_return.registration_unavailable && selected_provider != null &&
                    ((!) selected_provider).in_band_registration && ((!) selected_provider).has_web_registration) {
                show_provider_web_registration((!) selected_provider, _("Provider data may be outdated. This server did not offer in-app registration."));
                return;
            }
            display_notification(registration_error_to_user_message((!) form_return.error));
        } else {
            display_notification(_("No response from server"));
        }
    }

    private void set_register_form(Jid server, Xep.InBandRegistration.Form form) {
        clear_form_box();
        registration_web_page_url = null;

        this.title = _("Register on %s").printf(server.to_string());
        register_form_continue.sensitive = true;
        register_form_continue_spinner.visible = false;

        if (form.oob != null) {
            form_box.append(new Label(_("The server requires to sign up through a website")));
            form_box.append(new Label(@"<a href=\"$(form.oob)\">$(form.oob)</a>") { use_markup=true });
            register_form_continue_label.label = _("Open website");
            register_form_continue.visible = true;
            register_form_continue.grab_focus();
        } else if (form.fields.size > 0) {
            if (invite_username != null && invite_username != "") {
                set_form_field_value(form, "username", (!) invite_username);
                form_box.append(new Label(_("This invitation is reserved for the account name %s.").printf("<b>" + Markup.escape_text((!) invite_username) + "</b>")) { use_markup=true, xalign=0,
                    wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });
            }
            if (form.instructions != null && form.instructions != "") {
                string markup_instructions = Util.parse_add_markup(Util.unbreak_space_around_non_spacing_mark(form.instructions), null, true, false);
                form_box.append(new Label(markup_instructions) { use_markup=true, xalign=0, margin_top=7,
                    wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });
            }
            var form_preference_group = Util.rows_to_preference_group(Util.get_data_form_view_model(form), "");
            form_box.append(form_preference_group);
            register_form_continue.visible = true;
            register_form_continue_label.label = _("Register");
        } else {
            if (form.instructions != null && form.instructions != "") {
                string markup_instructions = Util.parse_add_markup(Util.unbreak_space_around_non_spacing_mark(form.instructions), null, true, false);
                form_box.append(new Label(markup_instructions) { use_markup=true, xalign=0,
                    wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR });
            }
            form_box.append(new Label(_("Check %s for information on how to sign up").printf(@"<a href=\"http://$(server)\">$(server)</a>")) { use_markup=true });
            register_form_continue.visible = false;
        }
    }

    private void clear_form_box() {
        Widget widget = form_box.get_first_child();
        while (widget != null) {
            form_box.remove(widget);
            widget = form_box.get_first_child();
        }
    }

    private void set_form_field_value(Xep.InBandRegistration.Form form, string field_var, string value) {
        foreach (Xep.DataForms.DataForm.Field field in form.fields) {
            if (field.var == field_var) {
                field.set_value_string(value);
                return;
            }
        }
    }

    private async void on_register_form_continue_clicked() {
        if (registration_submit_in_progress || account_setup_completed) return;
        if (is_inactive()) return;
        notification_revealer.set_reveal_child(false);

        if (registration_web_page_url != null) {
            open_external_url_after_current_event((!) registration_web_page_url, true);
            return;
        }

        if (form == null) return;

        // Button is opening a registration website
        if (form.oob != null) {
            open_external_url_after_current_event((!) form.oob, true);
            return;
        }

        if (invite_username != null && invite_username != "") {
            string? username = null;
            foreach (Xep.DataForms.DataForm.Field field in form.fields) {
                if (field.var == "username") {
                    username = field.get_value_string();
                    break;
                }
            }
            if (username != invite_username) {
                display_notification(_("This invitation is reserved for %s.").printf((!) invite_username));
                set_form_field_value(form, "username", (!) invite_username);
                return;
            }
        }

        registration_submit_in_progress = true;
        register_form_continue.sensitive = false;
        register_form_continue_spinner.visible = true;
        string? error = yield Register.submit_form(server_jid, form, invite_preauth_token);
        if (is_inactive()) return;
        if (register_form_continue_spinner == null) {
            return;
        }
        if (account_setup_completed) {
            return;
        }
        register_form_continue_spinner.visible = false;
        registration_submit_in_progress = false;
        if (error == null) {
            Account? account = get_registration_account_from_form();
            if (account != null) {
                add_activate_account(account);
                show_success(account);
            } else {
                register_form_continue.sensitive = true;
                display_notification(_("Invalid address"));
            }
        } else {
            if (yield try_finish_created_invite_account_after_error((!) error)) {
                return;
            }
            register_form_continue.sensitive = true;
            display_notification(registration_error_to_user_message((!) error));
        }
    }

    private Account? get_registration_account_from_form() {
        string? username = null, password = null;
        foreach (Xep.DataForms.DataForm.Field field in form.fields) {
            switch (field.var) {
                case "username": username = field.get_value_string(); break;
                case "password": password = field.get_value_string(); break;
            }
        }
        if (username == null || username == "" || password == null) return null;
        try {
            return new Account(new Jid.components(username, server_jid.domainpart, null), password);
        } catch (InvalidJidError e) {
            warning("Invalid address from components of registration: %s", e.message);
            return null;
        }
    }

    private async bool try_finish_created_invite_account_after_error(string error) {
        if (!is_invite_registration_policy_error(error)) return false;
        if (is_inactive()) return false;

        Account? account = get_registration_account_from_form();
        if (account == null) return false;

        ConnectionManager.ConnectionError.Source? login_error = yield stream_interactor.get_module<Register>(Register.IDENTITY).add_check_account(account);
        if (is_inactive()) return false;
        if (login_error != null) return false;

        add_activate_account(account);
        show_success(account);
        return true;
    }

    private bool is_invite_registration_policy_error(string error) {
        if (invite_preauth_token == null || invite_preauth_token == "") return false;
        if (error == Register.ERROR_INVITE_REGISTRATION_UNSUPPORTED) return false;

        string normalized = error.down();
        return normalized.contains("access denied by service policy") ||
                normalized.contains("service policy") ||
                normalized.contains("forbidden") ||
                normalized.contains("expired") ||
                normalized.contains("invalid token") ||
                normalized.contains("bad token");
    }

    private string registration_error_to_user_message(string error) {
        if (error == Register.ERROR_INVITE_REGISTRATION_UNSUPPORTED) {
            return _("This server does not advertise invite-based account registration.");
        }
        if (error == Register.ERROR_CONNECTION_FAILED) {
            return _("Could not connect to %s").printf(server_jid.domainpart);
        }
        if (error == Register.ERROR_NO_RESPONSE) {
            return _("No response from server");
        }
        if (error == Xep.InBandRegistration.ERROR_INVALID_RESPONSE) {
            return _("Something went wrong");
        }
        if (error == ErrorStanza.CONDITION_SERVICE_UNAVAILABLE ||
                error == ErrorStanza.CONDITION_FEATURE_NOT_IMPLEMENTED ||
                error == ErrorStanza.CONDITION_NOT_ALLOWED) {
            return _("The server does not allow account registration.");
        }
        string normalized = error.down();
        if (error == ErrorStanza.CONDITION_RESOURCE_CONSTRAINT || normalized.contains("so schnell") ||
                normalized.contains("too quickly") || normalized.contains("not so fast")) {
            return _("Registrations are temporarily rate-limited. Please wait a moment and try again.");
        }
        if (normalized.contains("access denied by service policy") || normalized.contains("service policy") || normalized.contains("forbidden")) {
            return invite_preauth_token != null && invite_preauth_token != ""
                    ? _("The server rejected this invitation. It may have expired or already been used.")
                    : _("The server does not allow account registration.");
        }
        if (normalized.contains("already") && (normalized.contains("exist") || normalized.contains("registered"))) {
            return _("This account name is already registered.");
        }
        if (normalized.contains("conflict")) {
            return _("This account name is already registered.");
        }
        if (normalized.contains("expired") || normalized.contains("invalid token") || normalized.contains("bad token")) {
            return _("This invitation is no longer valid. Please request a new invitation.");
        }
        if (normalized.contains("not acceptable") || normalized.contains("not-acceptable")) {
            return _("The server rejected one of the registration fields. Please check the entered information.");
        }
        if (normalized.contains("captcha")) {
            return _("The server requires an additional verification step that DinoX cannot complete here.");
        }
        return error;
    }

    private void set_select_server_busy(bool busy) {
        select_server_in_progress = busy;
        select_server_continue_spinner.visible = busy;
        server_entry.sensitive = !busy;
        server_list_box.sensitive = !busy;
        login_button.sensitive = !busy;
        select_server_continue.sensitive = !busy && is_valid_manual_server_domain(server_entry.text);
    }

    private void display_notification(string text) {
        if (is_inactive()) return;
        notification_label.label = text;
        notification_revealer.set_reveal_child(true);
        if (notification_timeout_id != 0) {
            Source.remove(notification_timeout_id);
            notification_timeout_id = 0;
        }
        notification_timeout_id = Timeout.add_seconds(5, () => {
            notification_timeout_id = 0;
            if (is_inactive()) return false;
            notification_revealer.set_reveal_child(false);
            return false;
        });
    }

    private void add_activate_account(Account account) {
        account.enabled = true;
        account.persist(db);
        get_sign_in_connection_input().persist_socks5_preferences(db, account);
        stream_interactor.connect_account(account);
        added(account);
    }

    private void switch_stack_page(Page page) {
        current_page = page;
        stack.visible_child_name = get_visible_stack_child_name(page);

        back_button.visible = page == CREATE_ACCOUNT_REGISTER_FORM && invite_preauth_token == null;
    }

    private string get_visible_stack_child_name(Page page) {
        switch (page) {
            case SIGN_IN: return "login_jid";
            case SIGN_IN_TLS_ERROR: return "tls_error";
            case CREATE_ACCOUNT_SELECT_SERVER: return "server";
            case CREATE_ACCOUNT_REGISTER_FORM: return "form";
            case SUCCESS: return "success";
        }
        warning("Unknown Page: %d", page);
        return "login_jid";
    }
}

}
