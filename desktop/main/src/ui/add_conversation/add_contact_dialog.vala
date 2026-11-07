using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/add_conversation/add_contact_dialog.ui")]
protected class AddContactDialog : Adw.Dialog {

    public Account? account {
        get { return account_combobox.active_account; }
        set { account_combobox.active_account = value; }
    }

    public string jid {
        get { return jid_entry.text; }
        set { jid_entry.text = value; }
    }

    public string alias {
        get { return alias_entry.text; }
        set { alias_entry.text = value; }
    }

    [GtkChild] private unowned AccountComboBox account_combobox;
    [GtkChild] private unowned Button ok_button;
    [GtkChild] private unowned Button cancel_button;
    [GtkChild] private unowned Entry jid_entry;
    [GtkChild] private unowned Entry alias_entry;
    [GtkChild] private unowned Box content_area; // Need to add this ID to the UI file or find the box programmatically

    private StreamInteractor stream_interactor;
    private string? preauth_token;
    private Button? search_button = null;
    private bool initial_account_missing = false;
    private bool lock_initial_account = false;
    private Account? locked_account = null;
    private bool normalizing_locked_account = false;
    private CheckButton grant_presence;
    private Label permission_hint;
    private Label error_label;
    private bool submitting = false;
    private Account? requested_account = null;
    private Jid? requested_jid = null;
    private ulong connection_handler = 0;
    private bool contact_dialog_closed = false;

    public static AddContactDialog for_account(StreamInteractor stream_interactor, Account account) {
        return new AddContactDialog(stream_interactor, null, account, true);
    }

    public AddContactDialog(StreamInteractor stream_interactor, string? preauth_token = null, Account? initial_account = null, bool lock_initial_account = false) {
        this.stream_interactor = stream_interactor;
        this.preauth_token = preauth_token;
        this.lock_initial_account = lock_initial_account;
        this.locked_account = lock_initial_account ? initial_account : null;
        account_combobox.allow_fallback_selection = !lock_initial_account;
        account_combobox.initialize(stream_interactor);
        if (initial_account != null) {
            initial_account_missing = !initial_account.enabled || !account_combobox.select_account(initial_account);
        }
        if (lock_initial_account) {
            account_combobox.sensitive = false;
            if (initial_account_missing) {
                account_combobox.tooltip_text = _("The selected account is no longer active");
            }
        }

        cancel_button.clicked.connect(on_cancel_clicked);
        ok_button.clicked.connect(on_ok_button_clicked);
        jid_entry.changed.connect(on_jid_entry_changed);
        account_combobox.notify["active-account"].connect(on_account_changed);

        grant_presence = new CheckButton.with_label(_("Also share my online status")) {
            margin_start = 20, margin_end = 20
        };
        permission_hint = new Label("") {
            wrap = true, xalign = 0, margin_start = 20, margin_end = 20,
            margin_top = 6, margin_bottom = 12
        };
        permission_hint.add_css_class("dim-label");
        error_label = new Label("") {
            wrap = true, xalign = 0, visible = false,
            margin_start = 20, margin_end = 20, margin_bottom = 12
        };
        error_label.add_css_class("error");
        content_area.append(grant_presence);
        content_area.append(permission_hint);
        content_area.append(error_label);
        grant_presence.toggled.connect(update_actions);
        connection_handler = stream_interactor.connection_manager.connection_state_changed.connect(on_connection_state_changed);
        closed.connect(disconnect_connection_handler);
        
        // Add Search Button
        var search_btn = new Button.with_label(_("Search server directory"));
        search_button = search_btn;
        search_btn.margin_top = 0;
        search_btn.margin_bottom = 20;
        search_btn.halign = Align.CENTER;
        search_btn.add_css_class("pill");
        search_btn.clicked.connect(on_directory_search_clicked);
        
        content_area.append(search_btn);
        update_actions();
    }

    private void on_cancel_clicked() {
        close();
    }

    private void on_account_changed() {
        normalize_locked_account();
        update_actions();
    }

    private void on_connection_state_changed(Account event_account, ConnectionManager.ConnectionState state) {
        update_actions();
    }

    private void on_directory_search_clicked() {
        Account? selected_account = account;
        if (contact_dialog_closed || initial_account_missing || selected_account == null ||
                !directory_account_is_connected(selected_account)) return;
        Account search_account = (!) selected_account;
        var search_dialog = new UserSearchDialog(stream_interactor, search_account);
        connect_directory_result(search_dialog, this, search_account);
        search_dialog.present(this);
    }

    private static void connect_directory_result(UserSearchDialog search_dialog,
            AddContactDialog owner, Account search_account) {
        var weak_parent = WeakRef(owner);
        search_dialog.contact_selected.connect((jid) => {
            var parent = weak_parent.get() as AddContactDialog;
            if (parent == null || parent.contact_dialog_closed || parent.account == null ||
                    !ViewModel.ContactSubscriptionModel.same_account((!) parent.account, search_account) ||
                    !parent.directory_account_is_connected(search_account)) return;
            parent.jid = jid.to_string();
        });
    }

    private void normalize_locked_account() {
        if (normalizing_locked_account) return;
        if (!lock_initial_account) {
            initial_account_missing = false;
            return;
        }

        Account? target_account = locked_account;
        if (target_account == null || !((!) target_account).enabled) {
            initial_account_missing = true;
            return;
        }

        Account? selected_account = account;
        if (selected_account != null && ViewModel.ContactSubscriptionModel.same_account(selected_account, (!) target_account)) {
            initial_account_missing = false;
            return;
        }

        normalizing_locked_account = true;
        bool selected = account_combobox.select_account((!) target_account);
        normalizing_locked_account = false;
        initial_account_missing = !selected || account == null ||
            !ViewModel.ContactSubscriptionModel.same_account((!) account, (!) target_account);
    }

    private void on_ok_button_clicked() {
        add_contact.begin();
    }

    private async void add_contact() {
        if (submitting) return;
        Account? selected_account = account;
        try {
            Jid jid = new Jid(jid_entry.text);
            if (!is_addable_contact(selected_account, jid)) {
                ok_button.sensitive = false;
                return;
            }

            string? alias = alias_entry.text == "" ? null : alias_entry.text;
            var roster_manager = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            if (roster_manager == null || presence_manager == null) return;

            submitting = true;
            can_close = false;
            cancel_button.sensitive = false;
            jid_entry.sensitive = false;
            alias_entry.sensitive = false;
            account_combobox.sensitive = false;
            grant_presence.sensitive = false;
            error_label.visible = false;
            update_actions();

            if (roster_manager.get_roster_item((!) selected_account, jid) == null) {
                // The server can accept the roster write before a disconnect
                // prevents its reply from reaching us. Allow this dialog to
                // finish the same permission request after reconnecting.
                requested_account = selected_account;
                requested_jid = jid;
                bool added = yield roster_manager.add_jid_async((!) selected_account, jid, alias);
                if (!added) throw new IOError.FAILED("The server rejected adding the contact");
            }
            yield presence_manager.request_mutual_subscription((!) selected_account, jid, grant_presence.active, preauth_token);
            can_close = true;
            close();
        } catch (Error e) {
            warning("Could not add contact or request presence permission: %s", e.message);
            error_label.label = _("Could not complete the contact request. Check your connection and try again.");
            error_label.visible = true;
        } finally {
            submitting = false;
            can_close = true;
            cancel_button.sensitive = true;
            jid_entry.sensitive = true;
            alias_entry.sensitive = true;
            account_combobox.sensitive = !lock_initial_account;
            grant_presence.sensitive = true;
            update_actions();
        }
    }

    private void on_jid_entry_changed() {
        Account? selected_account = account;
        try {
            Jid parsed_jid = new Jid(jid_entry.text);
            ok_button.sensitive = is_addable_contact(selected_account, parsed_jid);
        } catch (InvalidJidError e) {
            ok_button.sensitive = false;
        }
    }

    private void update_actions() {
        normalize_locked_account();
        on_jid_entry_changed();

        if (account == null || !is_connected_account((!) account)) {
            permission_hint.label = _("Connect this account before adding a contact or requesting permissions.");
        } else if (grant_presence.active) {
            var presence = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            bool pending = false;
            try {
                pending = presence.exists_subscription_request((!) account, new Jid(jid));
            } catch (InvalidJidError error) {
                // An unfinished JID has no pending request to approve.
            }
            if (pending) {
                permission_hint.label = _("Accept this contact's pending request to see your online status.");
            } else if (presence.supports_subscription_preapproval((!) account)) {
                permission_hint.label = _("Allow this contact to see your online status.");
            } else {
                permission_hint.label = _("When your contact requests your online status, you will need to accept separately.");
            }
        } else {
            permission_hint.label = _("Ask to receive this contact's online status. Your own status stays private until you approve their request.");
        }

        if (search_button != null) {
            Account? selected_account = account;
            search_button.sensitive = !contact_dialog_closed && !submitting && !initial_account_missing && selected_account != null && directory_account_is_connected((!) selected_account);
        }
    }

    private bool is_addable_contact(Account? selected_account, Jid parsed_jid) {
        if (submitting || initial_account_missing || selected_account == null || !selected_account.enabled) return false;
        if (!is_connected_account(selected_account)) return false;

        var roster_manager = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        if (roster_manager == null) return false;

        return parsed_jid.resourcepart == null &&
                (roster_manager.get_roster_item(selected_account, parsed_jid) == null ||
                    (requested_account != null && requested_jid != null && ViewModel.ContactSubscriptionModel.same_account(selected_account, (!) requested_account) && parsed_jid.equals_bare((!) requested_jid))) &&
                !selected_account.bare_jid.equals_bare(parsed_jid);
    }

    private bool is_connected_account(Account selected_account) {
        foreach (Account managed in stream_interactor.get_accounts()) {
            if (ViewModel.ContactSubscriptionModel.same_account(selected_account, managed) &&
                    managed.enabled && stream_interactor.get_stream(managed) != null) return true;
        }
        return false;
    }

    private bool directory_account_is_connected(Account selected_account) {
        if (!is_connected_account(selected_account)) return false;
        XmppStream? stream = stream_interactor.get_stream(selected_account);
        return stream != null && ((!) stream).negotiation_complete;
    }

    private void disconnect_connection_handler() {
        contact_dialog_closed = true;
        if (connection_handler == 0) return;
        stream_interactor.connection_manager.disconnect(connection_handler);
        connection_handler = 0;
    }

    public override void dispose() {
        disconnect_connection_handler();
        base.dispose();
    }
}

}
