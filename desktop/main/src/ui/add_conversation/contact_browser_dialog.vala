using Gee;
using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class ContactBrowserDialog : Adw.Dialog {

    private Button cancel_button;
    private Button start_button;
    private SearchEntry search_entry;
    private ListBox contact_list;
    private Label status_label;

    private StreamInteractor stream_interactor;
    private Gee.List<Account> accounts;
    private Gee.List<ContactRow> all_contacts = new Gee.ArrayList<ContactRow>();
    private HashMap<Account, ulong> account_enabled_handler_ids = new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    private ulong account_added_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    
    public signal void contact_selected(Account account, Jid jid);

    public ContactBrowserDialog(StreamInteractor stream_interactor, Gee.List<Account> accounts) {
        this.stream_interactor = stream_interactor;
        this.accounts = accounts;
        
        this.title = _("Browse Contacts");
        this.content_width = 460;
        this.content_height = 550;

        setup_ui();
        setup_account_signals();
        load_contacts();
        this.closed.connect(() => {
            disconnect_account_signals();
        });
    }

    private void setup_account_signals() {
        account_added_handler_id = stream_interactor.account_added.connect((account) => {
            connect_account_enabled_signal(account);
            accounts = stream_interactor.get_accounts();
            load_contacts();
        });
        account_removed_handler_id = stream_interactor.account_removed.connect((account) => {
            disconnect_account_enabled_signal(account);
            accounts = stream_interactor.get_accounts();
            load_contacts();
        });
        foreach (Account account in accounts) {
            connect_account_enabled_signal(account);
        }
    }

    private void connect_account_enabled_signal(Account account) {
        if (account_enabled_handler_ids.has_key(account)) return;
        account_enabled_handler_ids[account] = account.notify["enabled"].connect(() => {
            load_contacts();
        });
    }

    private void disconnect_account_enabled_signal(Account account) {
        if (!account_enabled_handler_ids.has_key(account)) return;
        ulong handler_id = account_enabled_handler_ids[account];
        if (SignalHandler.is_connected(account, handler_id)) {
            account.disconnect(handler_id);
        }
        account_enabled_handler_ids.unset(account);
    }

    private void disconnect_account_signals() {
        if (account_added_handler_id != 0 && SignalHandler.is_connected(stream_interactor, account_added_handler_id)) {
            stream_interactor.disconnect(account_added_handler_id);
        }
        if (account_removed_handler_id != 0 && SignalHandler.is_connected(stream_interactor, account_removed_handler_id)) {
            stream_interactor.disconnect(account_removed_handler_id);
        }
        account_added_handler_id = 0;
        account_removed_handler_id = 0;

        var connected_accounts = new ArrayList<Account>();
        foreach (Account account in account_enabled_handler_ids.keys) {
            connected_accounts.add(account);
        }
        foreach (Account account in connected_accounts) {
            disconnect_account_enabled_signal(account);
        }
    }

    private void clear_contact_list() {
        Gtk.ListBoxRow? row;
        while ((row = contact_list.get_row_at_index(0)) != null) {
            contact_list.remove(row);
        }
        start_button.sensitive = false;
    }

    private void setup_ui() {
        var toolbar_view = new Adw.ToolbarView();
        var main_box = new Box(Orientation.VERTICAL, 0);
        
        // Header
        var header_bar = new Adw.HeaderBar();
        header_bar.decoration_layout = ":";
        
        cancel_button = new Button.with_label(_("Cancel"));
        start_button = new Button.with_label(_("Start"));
        start_button.add_css_class("suggested-action");
        start_button.sensitive = false;
        
        header_bar.pack_start(cancel_button);
        header_bar.pack_end(start_button);
        toolbar_view.add_top_bar(header_bar);
        
        cancel_button.clicked.connect(() => { close(); });
        start_button.clicked.connect(on_start_clicked);
        
        // Search box
        var search_box = new Box(Orientation.VERTICAL, 0);
        search_box.margin_start = 12;
        search_box.margin_end = 12;
        search_box.margin_top = 12;
        search_box.margin_bottom = 12;
        
        search_entry = new SearchEntry();
        search_entry.placeholder_text = _("Search contacts...");
        search_entry.hexpand = true;
        search_entry.search_changed.connect(on_search_changed);
        search_box.append(search_entry);
        
        main_box.append(search_box);
        
        // Contact list
        var scrolled = new ScrolledWindow();
        scrolled.hscrollbar_policy = PolicyType.NEVER;
        scrolled.vexpand = true;
        
        contact_list = new ListBox();
        contact_list.selection_mode = SelectionMode.SINGLE;
        contact_list.row_selected.connect(on_row_selected);
        contact_list.row_activated.connect(on_row_activated);
        
        scrolled.child = contact_list;
        main_box.append(scrolled);
        
        // Status label
        status_label = new Label("");
        status_label.visible = false;
        status_label.margin_top = 12;
        status_label.margin_bottom = 12;
        main_box.append(status_label);
        
        toolbar_view.content = main_box;
        this.child = toolbar_view;
    }

    private void load_contacts() {
        all_contacts.clear();
        clear_contact_list();
        
        foreach (Account account in accounts) {
            if (!account_is_active_managed(account)) continue;
            
            foreach (Roster.Item roster_item in stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).get_roster(account)) {
                all_contacts.add(new ContactRow(stream_interactor, roster_item.jid, account));
            }
        }
        
        if (all_contacts.size == 0) {
            show_status(_("No contacts found"));
        } else {
            populate_list(search_entry.text);
        }
    }

    private void show_status(string message) {
        status_label.label = message;
        status_label.visible = true;
        contact_list.visible = false;
    }

    private void populate_list(string filter) {
        // Clear list
        clear_contact_list();

        string normalized_filter = ViewModel.ContactListItem.normalize_search_value(filter);
        int count = 0;

        foreach (var contact_row in all_contacts) {
            if (!account_is_active_managed(contact_row.account)) continue;
            string name = contact_row.display_name ?? contact_row.jid.to_string();
            string jid_str = contact_row.jid.to_string();
            
            if (filter == "" || ViewModel.ContactListItem.normalize_search_value(name).contains(normalized_filter) ||
                    ViewModel.ContactListItem.normalize_search_value(jid_str).contains(normalized_filter)) {
                contact_list.append(contact_row);
                count++;
            }
        }
        
        if (count == 0 && filter != "") {
            show_status(_("No contacts match your search"));
        } else {
            status_label.visible = false;
            contact_list.visible = true;
        }
    }

    private void on_search_changed() {
        populate_list(search_entry.text);
    }

    private void on_row_selected(ListBoxRow? row) {
        ContactRow? contact_row = row as ContactRow;
        start_button.sensitive = contact_row != null && account_is_active_managed(((!) contact_row).account);
    }

    private void on_row_activated(ListBoxRow row) {
        on_start_clicked();
    }

    private void on_start_clicked() {
        var row = contact_list.get_selected_row() as ContactRow;
        if (row != null && account_is_active_managed(((!) row).account)) {
            contact_selected(row.account, row.jid);
            close();
        }
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }

    private class ContactRow : ListBoxRow {
        public Jid jid { get; private set; }
        public Account account { get; private set; }
        public string? display_name { get; private set; }

        public ContactRow(StreamInteractor stream_interactor, Jid jid, Account account) {
            this.jid = jid;
            this.account = account;

            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 10;
            box.margin_end = 10;

            // Avatar (square for contacts, not round like MUCs)
            var picture = new Adw.Avatar(40, "", false);
            box.append(picture);

            // Name and JID
            var text_box = new Box(Orientation.VERTICAL, 2);
            
            // Get display name
            Roster.Item? roster_item = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).get_roster_item(account, jid);
            this.display_name = roster_item != null && roster_item.name != null && roster_item.name != "" 
                ? roster_item.name 
                : jid.localpart ?? jid.to_string();
            
            var name_label = new Label(display_name);
            name_label.xalign = 0;
            name_label.add_css_class("heading");
            name_label.ellipsize = Pango.EllipsizeMode.END;
            
            var jid_label = new Label(jid.to_string());
            jid_label.xalign = 0;
            jid_label.add_css_class("dim-label");
            jid_label.ellipsize = Pango.EllipsizeMode.END;
            
            text_box.append(name_label);
            text_box.append(jid_label);
            text_box.hexpand = true;
            
            box.append(text_box);

            this.child = box;
        }
    }
}

}
