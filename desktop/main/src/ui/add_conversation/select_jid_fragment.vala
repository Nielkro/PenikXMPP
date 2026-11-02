using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/add_conversation/select_jid_fragment.ui")]
public class SelectJidFragment : Gtk.Box {

    public signal void add_jid();
    public signal void remove_jid(ListRow row);
    public signal void browser_jid_chosen(Account account, Jid jid);
    public bool done {
        get {
            ListBoxRow? selected_row = list.get_selected_row();
            ListRow? row = selected_row != null ? selected_row.child as ListRow : null;
            return row != null && account_is_active_managed(row.account) &&
                    (filter_account == null || row.account == filter_account);
        }
        private set {}
    }

    public bool show_button_labels {
        get { return _show_button_labels; }
        set {
            _show_button_labels = value;
            update_button_labels_visibility();
        }
    }
    private bool _show_button_labels = false;
    
    public enum ButtonMode {
        CONTACT,
        GROUP
    }
    
    public ButtonMode button_mode {
        get { return _button_mode; }
        set {
            _button_mode = value;
            update_button_texts();
        }
    }
    private ButtonMode _button_mode = ButtonMode.CONTACT;
    
    public string placeholder_text {
        get { return entry.placeholder_text; }
        set { entry.placeholder_text = value; }
    }

    [GtkChild] private unowned Entry entry;
    [GtkChild] private unowned Box box;
    [GtkChild] private unowned Button add_button;
    [GtkChild] private unowned Button remove_button;
    [GtkChild] private unowned Label add_button_label;
    [GtkChild] private unowned Label remove_button_label;
    [GtkChild] private unowned Box account_selector_box;
    [GtkChild] private unowned DropDown account_dropdown;

    private StreamInteractor stream_interactor;
    private Gee.List<Account> accounts;
    private ArrayList<Widget> added_rows = new ArrayList<Widget>();

    private ListBox list;
    private string[]? filter_values;
    private HashMap<Account, Gee.List<ServiceDiscovery.Item>> cached_public_rooms = new HashMap<Account, Gee.List<ServiceDiscovery.Item>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, ulong> account_enabled_handler_ids = new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    private ulong account_added_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    private bool discovery_started = false;
    private ArrayList<Account?> dropdown_accounts = new ArrayList<Account?>();
    private uint filter_refresh_timeout_id = 0;
    private bool deactivated = false;
    private bool sorting_enabled = false;
    private bool suppress_entry_changed_filter = false;
    private const uint FILTER_REFRESH_DELAY_MS = 25;

    public bool enable_muc_search {
        get { return _enable_muc_search; }
        set {
            _enable_muc_search = value;
            update_search_icon();
        }
    }
    private bool _enable_muc_search = false;
    
    public bool enable_contact_browse {
        get { return _enable_contact_browse; }
        set {
            _enable_contact_browse = value;
            update_search_icon();
        }
    }
    private bool _enable_contact_browse = false;
    
    public Account? filter_account { 
        get { return _filter_account; }
        set {
            _filter_account = value;
            list.invalidate_filter();
            
            // Sync dropdown if changed externally
            uint selected = account_dropdown.selected;
            if (account_dropdown != null && dropdown_accounts.size > 0 && selected < dropdown_accounts.size &&
                ((_filter_account == null && dropdown_accounts[(int) selected] != null) ||
                 (_filter_account != null && dropdown_accounts[(int) selected] != _filter_account))) {
                 
                for (int i=0; i < dropdown_accounts.size; i++) {
                     if (dropdown_accounts[i] == _filter_account) {
                         // Cast simple int to avoid type issues if needed, though GObject usually accepts int
                         // but direct property set on Vala binding is uint
                         account_dropdown.selected = (uint) i;
                         break;
                     }
                }
            }
            
            // Re-run set_filter to update "added_rows" (e.g. Add Contact via...) which are not in the list model but added manually
            string current_text = entry.text;
            if (current_text != "") set_filter(current_text);
        }
    }
    private Account? _filter_account;
    public string text { get { return entry.text; } }

    public signal void browse_contacts_clicked();
    public signal void search_directory_clicked(string query);

    private void ensure_public_room_discovery_started() {
        if (deactivated || !enable_muc_search || discovery_started) return;
        discovery_started = true;
        fetch_public_rooms.begin((obj, res) => {
            fetch_public_rooms.end(res);
        });
    }

    private async void fetch_public_rooms() {
        foreach (Account account in accounts) {
            if (deactivated) return;
            if (!account.enabled) continue;
            try {
                if (!cached_public_rooms.has_key(account)) {
                    cached_public_rooms[account] = new Gee.ArrayList<ServiceDiscovery.Item>();
                }
                var seen_jids = new Gee.HashSet<string>();
                foreach (var existing_item in cached_public_rooms[account]) {
                    seen_jids.add(existing_item.jid.bare_jid.to_string());
                }

                Jid? muc_server = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).default_muc_server.get(account);
                if (muc_server == null) {
                    muc_server = new Jid("conference." + account.domainpart);
                }
                
                var stream = stream_interactor.get_stream(account);
                if (stream != null) {
                    var disco_module = stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY);
                    var result = yield disco_module.request_items(stream, muc_server);
                    if (deactivated) return;
                    if (result != null) {
                        foreach (var item in result.items) {
                            if (deactivated) return;
                            string jid_str = item.jid.bare_jid.to_string();
                            // Only add if we haven't seen this JID before
                            if (!seen_jids.contains(jid_str)) {
                                cached_public_rooms[account].add(item);
                                seen_jids.add(jid_str);
                            }
                        }
                    }
                    // Refresh filter if user has typed something
                    if (!deactivated && entry.text != "") {
                        bool timing = UiTiming.enabled();
                        int64 t0_us = timing ? UiTiming.now_us() : 0;
                        string text = entry.text;
                        set_filter(text);
                        if (timing) {
                            UiTiming.log_ms("SelectJidFragment.discovery_filter: text_len=%d".printf(text.length), t0_us);
                        }
                    }
                }
            } catch (Error e) {
                // Ignore discovery errors
            }
        }
    }

    public SelectJidFragment(StreamInteractor stream_interactor, ListBox list, Gee.List<Account> accounts) {
        bool timing = UiTiming.enabled();
        int64 t0_us = timing ? UiTiming.now_us() : 0;
        this.stream_interactor = stream_interactor;
        this.list = list;
        this.accounts = accounts;

        // Hide search icon by default
        entry.secondary_icon_name = null;

        list.activate_on_single_click = false;
        list.vexpand = true;
        box.append(list);

        list.set_filter_func(filter);
        list.set_header_func(header);
        list.row_selected.connect(check_buttons_active);
        list.row_selected.connect(update_button_label);
        list.row_selected.connect(() => { done = true; }); // just for notifying
        entry.changed.connect(() => {
            if (suppress_entry_changed_filter) return;
            bool filter_timing = UiTiming.enabled();
            int64 filter_t0_us = filter_timing ? UiTiming.now_us() : 0;
            string text = entry.text;
            apply_filter(text);
            if (filter_timing) {
                UiTiming.log_ms("SelectJidFragment.entry_changed_filter: text_len=%d".printf(text.length), filter_t0_us);
            }
        });
        entry.icon_press.connect(on_icon_press);

        account_dropdown.notify["selected"].connect(() => {
            int idx = (int) account_dropdown.selected;
            if (idx >= 0 && idx < dropdown_accounts.size) {
                this.filter_account = dropdown_accounts[idx];
            }
        });
        
        add_button.clicked.connect(() => { add_jid(); });
        remove_button.clicked.connect(() => {
            var list_row = list.get_selected_row();
            if (list_row == null) return;
            remove_jid(list_row.child as ListRow);
        });

        setup_account_signals();
        rebuild_account_selector();
        if (timing) {
            UiTiming.log_ms("SelectJidFragment.constructor: accounts=%d".printf(accounts.size), t0_us);
        }
    }

    public void enable_sorting() {
        if (sorting_enabled) return;
        sorting_enabled = true;
        list.set_sort_func(sort);
        list.invalidate_sort();
    }

    public override void dispose() {
        deactivate();
        base.dispose();
    }

    public void deactivate() {
        if (deactivated) return;
        deactivated = true;
        cancel_filter_refresh();
        disconnect_account_signals();
    }

    public void cancel_filter_refresh() {
        if (filter_refresh_timeout_id != 0) {
            Source.remove(filter_refresh_timeout_id);
            filter_refresh_timeout_id = 0;
        }
    }

    public void schedule_filter_refresh() {
        if (deactivated) return;
        if (filter_refresh_timeout_id != 0) return;
        filter_refresh_timeout_id = Timeout.add(FILTER_REFRESH_DELAY_MS, () => {
            filter_refresh_timeout_id = 0;
            if (deactivated) return false;
            bool timing = UiTiming.enabled();
            int64 t0_us = timing ? UiTiming.now_us() : 0;
            string text = entry.text;
            set_filter(text, false);
            if (timing) {
                UiTiming.log_ms("SelectJidFragment.deferred_filter_refresh: text_len=%d".printf(text.length), t0_us);
            }
            return false;
        });
    }

    public void refresh_button_state() {
        update_buttons_active(false);
        update_button_label();
        notify_property("done");
    }
    
    private void setup_account_signals() {
        account_added_handler_id = stream_interactor.account_added.connect((account) => {
            connect_account_enabled_signal(account);
            accounts = stream_interactor.get_accounts();
            rebuild_account_selector();
        });
        account_removed_handler_id = stream_interactor.account_removed.connect((account) => {
            disconnect_account_enabled_signal(account);
            accounts = stream_interactor.get_accounts();
            rebuild_account_selector();
        });
        foreach (Account account in accounts) {
            connect_account_enabled_signal(account);
        }
    }

    private void connect_account_enabled_signal(Account account) {
        if (account_enabled_handler_ids.has_key(account)) return;
        account_enabled_handler_ids[account] = account.notify["enabled"].connect(() => {
            rebuild_account_selector();
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

    private void rebuild_account_selector() {
        Account? previous_filter = filter_account;
        if (previous_filter != null && !((!) previous_filter).enabled) previous_filter = null;

        dropdown_accounts.clear();
        var model = new StringList(null);

        if (accounts.size <= 1) {
            account_selector_box.visible = false;
            account_dropdown.model = model;
            filter_account = null;
            set_filter(entry.text);
            update_buttons_active(false);
            notify_property("done");
            return;
        }

        model.append(_("All Accounts"));
        dropdown_accounts.add(null);

        bool has_active = false;
        uint selected_index = 0;
        foreach (var account in accounts) {
            if (account.enabled) {
                model.append(Util.sanitize_utf8(account.display_name));
                dropdown_accounts.add(account);
                has_active = true;
                if (previous_filter != null && account.equals((!) previous_filter)) {
                    selected_index = (uint) dropdown_accounts.size - 1;
                }
            }
        }
        
        account_dropdown.model = model;
        if (!has_active) {
             account_selector_box.visible = false;
             filter_account = null;
             set_filter(entry.text);
             update_buttons_active(false);
             notify_property("done");
             return;
        }

        account_dropdown.selected = selected_index;
        filter_account = dropdown_accounts[(int) selected_index];
        account_selector_box.visible = true;
        update_buttons_active(false);
        notify_property("done");
    }

    private void update_search_icon() {
        if (enable_muc_search) {
            entry.secondary_icon_name = "system-search-symbolic";
            entry.secondary_icon_tooltip_text = _("Browse Rooms");
        } else {
            // Disable the confusing "Browse Contacts" icon since we now have inline search
            entry.secondary_icon_name = null;
            entry.secondary_icon_tooltip_text = null;
        }
    }
    
    private void on_icon_press(EntryIconPosition pos) {
        if (pos == EntryIconPosition.SECONDARY) {
            if (enable_muc_search) {
                open_room_browser();
            } else if (enable_contact_browse) {
                browse_contacts_clicked();
            }
        }
    }

    private void open_room_browser() {
        Account? account = null;
        if (filter_account != null && filter_account.enabled) {
            account = filter_account;
        } else {
            foreach(var acc in accounts) {
                if (acc.enabled) {
                    account = acc;
                    break;
                }
            }
        }
        
        if (account != null) {
            var dialog = new RoomBrowserDialog(stream_interactor, account);
            var root = this.get_root() as Gtk.Window;
            
            dialog.room_selected.connect((jid) => {
                browser_jid_chosen(account, jid.bare_jid);
            });
            dialog.present(root);
        }
    }
    
    private void update_button_labels_visibility() {
        add_button_label.visible = _show_button_labels;
        remove_button_label.visible = _show_button_labels;
    }
    
    private void update_button_texts() {
        if (_button_mode == ButtonMode.CONTACT) {
            add_button_label.label = _("Add Contact");
            remove_button_label.label = _("Delete Contact");
        } else {
            add_button_label.label = _("Add Group");
            remove_button_label.label = _("Leave Group");
        }
    }
    
    private void update_button_label() {
        if (!_show_button_labels) return;
        
        if (_button_mode != ButtonMode.GROUP) return;

        ListBoxRow? selected_row = list.get_selected_row();
        ConferenceListRow? conference_row = selected_row != null ? selected_row.child as ConferenceListRow : null;
        if (conference_row != null && conference_row.open_existing) {
            remove_button_label.label = _("Leave Group");
        } else if (conference_row != null && conference_row.bookmark != null) {
            remove_button_label.label = _("Remove Bookmark");
        } else {
            remove_button_label.label = _("Leave Group");
        }
    }

    public void set_filter(string str, bool allow_discovery = true) {
        string safe_str = Util.sanitize_utf8(str);
        if (entry.text != safe_str) {
            suppress_entry_changed_filter = true;
            entry.text = safe_str;
            suppress_entry_changed_filter = false;
        }

        apply_filter(safe_str, allow_discovery);
    }

    private void apply_filter(string str, bool allow_discovery = true) {
        foreach (Widget row in added_rows) list.remove(row);
        added_rows.clear();
        var added_room_keys = new Gee.HashSet<string>();

        string safe_filter = Util.sanitize_utf8(str);
        string normalized_filter = ViewModel.ContactListItem.normalize_search_value(safe_filter);
        filter_values = safe_filter == "" ? null : safe_filter.split(" ");
        list.invalidate_filter();

        // 1. Try to parse as JID (Direct entry)
        try {
            Jid parsed_jid = new Jid(safe_filter);
            if (parsed_jid != null && parsed_jid.localpart != null) {
                foreach (Account account in accounts) {
                    if (!account.enabled) continue;
                    if (filter_account != null && account != filter_account) continue;
                    if (enable_muc_search && public_room_cache_contains(account, parsed_jid)) continue;
                    if (!should_add_room_candidate(account, parsed_jid, added_room_keys)) continue;
                    var list_row = new Gtk.ListBoxRow();
                    list_row.set_child(new AddListRow(stream_interactor, parsed_jid.bare_jid, account));
                    list.append(list_row);
                    added_rows.add(list_row);
                }
            }
        } catch (InvalidJidError ignored) {
            // Ignore
        }

        // 2. If MUC search enabled, search in cached public rooms
        if (enable_muc_search && safe_filter != "") {
            if (allow_discovery) ensure_public_room_discovery_started();
            // Search in discovered rooms
            foreach (Account account in accounts) {
                if (!account.enabled) continue;
                if (filter_account != null && account != filter_account) continue;
                if (!cached_public_rooms.has_key(account)) continue;
                foreach (var item in cached_public_rooms[account]) {
                    string safe_item_name = Util.sanitize_utf8(item.name);
                    if ((safe_item_name != "" && ViewModel.ContactListItem.normalize_search_value(safe_item_name).contains(normalized_filter)) ||
                        ViewModel.ContactListItem.normalize_search_value(item.jid.to_string()).contains(normalized_filter)) {
                        if (!should_add_room_candidate(account, item.jid, added_room_keys)) continue;

                        var list_row = new Gtk.ListBoxRow();
                        list_row.set_child(new AddListRow(stream_interactor, item.jid.bare_jid, account, safe_item_name));
                        list.append(list_row);
                        added_rows.add(list_row);
                    }
                }
            }
        }
        // 3. Add "Search Directory" option if not empty
        if (str != "" && !enable_muc_search) {
            var list_row = new Gtk.ListBoxRow();
            var search_row = new SearchDirectoryRow(str);
            list_row.set_child(search_row);
            list.append(list_row);
            added_rows.add(list_row);
        }
    }

    private bool should_add_room_candidate(Account account, Jid jid, Gee.HashSet<string> added_room_keys) {
        string key = get_room_key(account, jid);
        if (added_room_keys.contains(key)) return false;
        if (has_existing_room_identity(account, jid)) return false;
        added_room_keys.add(key);
        return true;
    }

    private bool public_room_cache_contains(Account account, Jid jid) {
        if (!cached_public_rooms.has_key(account)) return false;
        foreach (var item in cached_public_rooms[account]) {
            if (item.jid.equals_bare(jid)) return true;
        }
        return false;
    }

    private bool has_existing_room_identity(Account account, Jid jid) {
        if (has_existing_room_row(account, jid)) return true;

        if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_joined_or_joining(jid.bare_jid, account)) return true;

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
        return conversation != null && conversation.active;
    }

    private bool has_existing_room_row(Account account, Jid jid) {
        Widget? child = list.get_first_child();
        while (child != null) {
            ListBoxRow? list_box_row = child as ListBoxRow;
            ListRow? list_row = list_box_row != null ? list_box_row.child as ListRow : null;
            if (list_row != null && list_row.account != null && list_row.account.equals(account) && list_row.jid.equals_bare(jid)) {
                return true;
            }
            child = child.get_next_sibling();
        }
        return false;
    }

    private string get_room_key(Account account, Jid jid) {
        return "%s|%s".printf(account.id.to_string(), jid.bare_jid.to_string());
    }

    private void check_buttons_active() {
        update_buttons_active(true);
    }

    private void update_buttons_active(bool activate_search) {
        ListBoxRow? row = list.get_selected_row();
        ListRow? selected_list_row = row != null ? row.child as ListRow : null;
        bool selected_account_active = selected_list_row == null || selected_list_row.account == null ||
                (account_is_active_managed(selected_list_row.account) && (filter_account == null || selected_list_row.account == filter_account));
        bool active = row != null && row.child != null && !(row.child is SearchDirectoryRow) && selected_account_active;
        remove_button.sensitive = active && !(row.child is AddListRow);

        foreach (Widget w in added_rows) {
            var lb_row = w as ListBoxRow;
            if (lb_row != null) {
                var add_row = lb_row.child as AddListRow;
                if (add_row != null) add_row.set_selected(false);
            }
        }

        if (row != null) {
            var add_row = row.child as AddListRow;
            if (add_row != null) add_row.set_selected(true);
            
            var search_row = row.child as SearchDirectoryRow;
            if (search_row != null && activate_search) {
                search_directory_clicked(search_row.query);
            }
        }
    }

    private int sort(ListBoxRow row1, ListBoxRow row2) {
        // SearchDirectoryRow always at the bottom
        if (row1.child is SearchDirectoryRow) return 1;
        if (row2.child is SearchDirectoryRow) return -1;

        AddListRow al1 = (row1.child as AddListRow);
        AddListRow al2 = (row2.child as AddListRow);
        if (al1 != null && al2 == null) {
            return -1;
        } else if (al2 != null && al1 == null) {
            return 1;
        }

        ListRow? c1 = (row1.child as ListRow);
        ListRow? c2 = (row2.child as ListRow);
        if (c1 != null && c2 != null) {
            return c1.name_label.label.collate(c2.name_label.label);
        }

        return 0;
    }

    private bool filter(ListBoxRow r) {
        ListRow? row = (r.child as ListRow);
        if (row == null) return true;

        if (row.account != null && !account_is_active_managed(row.account)) return false;
        if (filter_account != null && row.account != null && row.account != filter_account) return false;

        if (filter_values != null) {
            string normalized_name = ViewModel.ContactListItem.normalize_search_value(row.name_label.label);
            string normalized_jid = ViewModel.ContactListItem.normalize_search_value(row.jid.to_string());
            foreach (string filter in filter_values) {
                string normalized_filter = ViewModel.ContactListItem.normalize_search_value(filter);
                if (!(normalized_name.contains(normalized_filter) ||
                        normalized_jid.contains(normalized_filter))) {
                    return false;
                }
            }
        }
        return true;
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }

    private void header(ListBoxRow row, ListBoxRow? before_row) {
        if (row.get_header() == null && before_row != null) {
            row.set_header(new Separator(Orientation.HORIZONTAL));
        }
    }

    private class AddListRow : ListRow {

        public AddListRow(StreamInteractor stream_interactor, Jid jid, Account account, string? name = null) {
            this.account = account;
            this.jid = jid;

            string safe_jid = Util.sanitize_utf8(jid.to_string());
            string safe_name = Util.sanitize_utf8(name);
            name_label.label = safe_name != "" ? "%s (%s)".printf(safe_name, safe_jid) : safe_jid;
            if (stream_interactor.get_accounts().size > 1) {
                via_label.label = Util.sanitize_utf8(account.bare_jid.to_string());
            } else {
                via_label.visible = false;
            }
            picture.model = new ViewModel.CompatAvatarPictureModel(null).add("+");
        }

        public void set_selected(bool selected) {
            var model = picture.model;
            if (model != null && model.tiles.get_n_items() > 0) {
                var tile = model.tiles.get_item(0) as ViewModel.AvatarPictureTileModel;
                if (tile != null) {
                    if (selected) {
                        tile.background_color = Gdk.RGBA() { red = 0.18f, green = 0.76f, blue = 0.49f, alpha = 1.0f };
                    } else {
                        tile.background_color = Gdk.RGBA() { red = 0.5f, green = 0.5f, blue = 0.5f, alpha = 1.0f };
                    }
                }
            }
            picture.queue_draw();
        }
    }

    private class SearchDirectoryRow : Box {
        public string query { get; private set; }
        
        public SearchDirectoryRow(string query) {
            this.query = query;
            this.orientation = Orientation.HORIZONTAL;
            this.spacing = 10;
            this.margin_top = 10;
            this.margin_bottom = 10;
            this.margin_start = 10;
            this.margin_end = 10;
            
            var icon = new Image.from_icon_name("system-search-symbolic");
            this.append(icon);
            
            var label = new Label(_("Search directory for '%s'").printf(Util.sanitize_utf8(query)));
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            this.append(label);
        }
    }
}

}
