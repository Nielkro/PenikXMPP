using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

/** Contact-only selection UI backed by a virtual Gtk.ListView. */
internal class ContactSelectionView : Box {
    public signal void choice_changed();
    public signal void choice_activated();
    public signal void add_contact_requested();
    public signal void remove_contact_requested(Account account, Jid jid);
    public signal void directory_search_requested(string query, Account? account);

    public Account? selected_account { get; private set; default = null; }
    public Jid? selected_jid { get; private set; default = null; }
    public bool selected_is_roster_contact { get; private set; default = false; }
    public bool done { get { return selected_account != null && selected_jid != null; } }
    public Account? preferred_account {
        owned get {
            if (projection.account_filter != null &&
                    account_is_active_managed((!) projection.account_filter)) {
                return projection.account_filter;
            }
            Account? only_account = null;
            foreach (Account account in accounts) {
                if (!account_is_active_managed(account)) continue;
                if (only_account != null) return null;
                only_account = account;
            }
            return only_account;
        }
    }

    private StreamInteractor stream_interactor;
    private ArrayList<Account> accounts = new ArrayList<Account>();
    private ViewModel.ContactListSelectionModel projection;
    private Entry entry;
    private Box account_selector_box;
    private DropDown account_dropdown;
    private ArrayList<Account?> dropdown_accounts = new ArrayList<Account?>();
    private ListView list_view;
    private ListBox direct_list;
    private Frame direct_frame;
    private Button directory_button;
    private Button remove_button;
    private SignalListItemFactory factory;
    private HashMap<Widget, ContactListViewRow> factory_rows = new HashMap<Widget, ContactListViewRow>();
    private HashMap<Account, ulong> account_enabled_handler_ids = new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    private CallbackBridge callbacks;
    private ulong selection_handler_id = 0;
    private ulong entry_handler_id = 0;
    private ulong dropdown_handler_id = 0;
    private ulong direct_selection_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    private bool changing_choice = false;
    private bool suppress_dropdown_change = false;
    private bool suppress_entry_change = false;
    private bool deactivated = false;
    private bool timing_enabled = false;
    private HashSet<Widget> timing_bound_widgets = new HashSet<Widget>();
    private uint timing_setup_count = 0;
    private uint timing_bind_count = 0;
    private uint timing_unbind_count = 0;
    private uint timing_teardown_count = 0;
    private uint timing_filter_count = 0;
    private int timing_max_pool_size = 0;
    private int timing_max_bound_rows = 0;
    private int64 timing_setup_total_us = 0;
    private int64 timing_bind_total_us = 0;
    private int64 timing_unbind_total_us = 0;
    private int64 timing_teardown_total_us = 0;
    private int64 timing_filter_total_us = 0;
    private int64 timing_filter_max_us = 0;

    private class DirectContactRow : Adw.ActionRow {
        public Account account { get; private set; }
        public Jid jid { get; private set; }

        public DirectContactRow(Account account, Jid jid, bool show_account) {
            this.account = account;
            this.jid = jid.bare_jid;
            title = this.jid.to_string().make_valid();
            subtitle = show_account ? account.display_name.make_valid() : "";
            activatable = true;
            add_prefix(new Image.from_icon_name("list-add-symbolic"));
        }
    }

    private class CallbackBridge : Object {
        private WeakRef owner_ref;

        public CallbackBridge(ContactSelectionView owner) {
            owner_ref = WeakRef(owner);
        }

        public void factory_setup(Object object) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_factory_setup(object);
        }

        public void factory_bind(Object object) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_factory_bind(object);
        }

        public void factory_unbind(Object object) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_factory_unbind(object);
        }

        public void factory_teardown(Object object) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_factory_teardown(object);
        }

        public void entry_changed() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_entry_changed();
        }

        public void projection_selection_changed() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_projection_selection_changed();
        }

        public void direct_selection_changed(ListBoxRow? row) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_direct_selection_changed(row);
        }

        public void dropdown_changed() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_dropdown_changed();
        }

        public void account_enabled_changed() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).rebuild_account_selector();
        }

        public void account_removed(Account account) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_account_removed(account);
        }

        public void list_activated(uint position) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).on_list_activated(position);
        }

        public void direct_row_activated(ListBoxRow row) {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner == null) return;
            ((!) owner).direct_list.select_row(row);
            if (((!) owner).done) ((!) owner).choice_activated();
        }

        public void add_clicked() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).add_contact_requested();
        }

        public void remove_clicked() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).request_remove_selected();
        }

        public void directory_clicked() {
            ContactSelectionView? owner = (ContactSelectionView?) owner_ref.get();
            if (owner != null) ((!) owner).request_directory_search();
        }

        public void clear() {
            owner_ref.set(null);
        }
    }

    public ContactSelectionView(StreamInteractor stream_interactor, Gee.List<Account> accounts,
            ViewModel.ContactListModel contacts) {
        Object(orientation: Orientation.VERTICAL);
        this.stream_interactor = stream_interactor;
        this.accounts.add_all(accounts);
        timing_enabled = UiTiming.enabled();
        projection = new ViewModel.ContactListSelectionModel(contacts);
        callbacks = new CallbackBridge(this);
        build_view();
        connect_account_handlers();
        account_removed_handler_id = stream_interactor.account_removed.connect(callbacks.account_removed);
        rebuild_account_selector();
        update_direct_actions();
    }

    public void set_filter(string text) {
        string safe_text = Util.sanitize_utf8(text);
        if (entry.text == safe_text) return;
        suppress_entry_change = true;
        entry.text = safe_text;
        suppress_entry_change = false;
        apply_query(safe_text);
    }

    public void deactivate() {
        if (deactivated) return;
        deactivated = true;
        disconnect_account_handlers();
        if (account_removed_handler_id != 0 &&
                SignalHandler.is_connected(stream_interactor, account_removed_handler_id)) {
            SignalHandler.disconnect(stream_interactor, account_removed_handler_id);
        }
        account_removed_handler_id = 0;
        if (selection_handler_id != 0 && SignalHandler.is_connected(projection, selection_handler_id)) {
            SignalHandler.disconnect(projection, selection_handler_id);
        }
        selection_handler_id = 0;
        if (entry_handler_id != 0 && SignalHandler.is_connected(entry, entry_handler_id)) {
            SignalHandler.disconnect(entry, entry_handler_id);
        }
        entry_handler_id = 0;
        if (dropdown_handler_id != 0 && SignalHandler.is_connected(account_dropdown, dropdown_handler_id)) {
            SignalHandler.disconnect(account_dropdown, dropdown_handler_id);
        }
        dropdown_handler_id = 0;
        if (direct_selection_handler_id != 0 && SignalHandler.is_connected(direct_list, direct_selection_handler_id)) {
            SignalHandler.disconnect(direct_list, direct_selection_handler_id);
        }
        direct_selection_handler_id = 0;
        list_view.factory = null;
        foreach (ContactListViewRow row in factory_rows.values) row.cleanup();
        factory_rows.clear();
        if (timing_enabled) log_timing_summary();
        timing_bound_widgets.clear();
        callbacks.clear();
    }

    public override void dispose() {
        deactivate();
        base.dispose();
    }

    private void build_view() {
        var clamp = new Adw.Clamp() {
            maximum_size = 400,
            tightening_threshold = 320,
            hexpand = true,
            vexpand = true
        };
        append(clamp);

        var content = new Box(Orientation.VERTICAL, 12) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 24,
            margin_bottom = 24,
            hexpand = true,
            vexpand = true
        };
        clamp.child = content;

        account_selector_box = new Box(Orientation.HORIZONTAL, 12) { visible = false };
        account_selector_box.append(new Label(_("Use account:")));
        account_dropdown = new DropDown(null, null) { hexpand = true };
        account_selector_box.append(account_dropdown);
        content.append(account_selector_box);

        entry = new Entry() {
            placeholder_text = _("Search or enter contact address..."),
            activates_default = true,
            hexpand = true
        };
        content.append(entry);

        direct_list = new ListBox() {
            selection_mode = SelectionMode.SINGLE,
            activate_on_single_click = false
        };
        direct_list.add_css_class("boxed-list");
        direct_frame = new Frame(null) { visible = false, child = direct_list };
        content.append(direct_frame);

        factory = new SignalListItemFactory();
        factory.setup.connect(callbacks.factory_setup);
        factory.bind.connect(callbacks.factory_bind);
        factory.unbind.connect(callbacks.factory_unbind);
        factory.teardown.connect(callbacks.factory_teardown);
        list_view = new ListView(projection.selection, factory) {
            single_click_activate = false,
            hexpand = true,
            vexpand = true
        };
        var scroller = new ScrolledWindow() {
            hscrollbar_policy = PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = list_view
        };
        var list_frame = new Frame(null) { child = scroller, hexpand = true, vexpand = true };
        content.append(list_frame);

        directory_button = new Button() {
            visible = false,
            hexpand = true
        };
        directory_button.add_css_class("flat");
        content.append(directory_button);

        var toolbar = new Box(Orientation.HORIZONTAL, 0) { homogeneous = true };
        toolbar.add_css_class("toolbar");
        toolbar.add_css_class("inline-toolbar");
        var add_button = make_labeled_button("list-add-symbolic", _("Add Contact"));
        remove_button = make_labeled_button("list-remove-symbolic", _("Delete Contact"));
        remove_button.sensitive = false;
        toolbar.append(add_button);
        toolbar.append(remove_button);
        content.append(toolbar);

        selection_handler_id = projection.notify["selected-item"].connect(callbacks.projection_selection_changed);
        entry_handler_id = entry.changed.connect(callbacks.entry_changed);
        dropdown_handler_id = account_dropdown.notify["selected"].connect(callbacks.dropdown_changed);
        direct_selection_handler_id = direct_list.row_selected.connect(callbacks.direct_selection_changed);
        direct_list.row_activated.connect(callbacks.direct_row_activated);
        list_view.activate.connect(callbacks.list_activated);
        add_button.clicked.connect(callbacks.add_clicked);
        remove_button.clicked.connect(callbacks.remove_clicked);
        directory_button.clicked.connect(callbacks.directory_clicked);
    }

    private Button make_labeled_button(string icon_name, string label_text) {
        var button = new Button() { hexpand = true, tooltip_text = label_text };
        var box = new Box(Orientation.HORIZONTAL, 6) { halign = Align.CENTER };
        box.append(new Image.from_icon_name(icon_name));
        box.append(new Label(label_text) { ellipsize = Pango.EllipsizeMode.END });
        button.child = box;
        return button;
    }

    private void on_factory_setup(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        ListItem? list_item = object as ListItem;
        if (list_item == null) return;
        var row = new ContactListViewRow();
        Widget widget = row.get_widget();
        factory_rows[widget] = row;
        ((!) list_item).child = widget;
        if (timing_enabled) {
            timing_setup_count++;
            timing_setup_total_us += UiTiming.now_us() - started_us;
            timing_max_pool_size = int.max(timing_max_pool_size, factory_rows.size);
        }
    }

    private void on_factory_bind(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        ContactListViewRow? row = factory_rows[((!) list_item).child];
        ViewModel.ContactListItem? item = ((!) list_item).get_item() as ViewModel.ContactListItem;
        if (row == null || item == null) return;
        ((!) row).bind(stream_interactor, (!) item, enabled_account_count() > 1);
        if (timing_enabled) {
            timing_bind_count++;
            timing_bind_total_us += UiTiming.now_us() - started_us;
            timing_bound_widgets.add((!) list_item.child);
            timing_max_bound_rows = int.max(timing_max_bound_rows, timing_bound_widgets.size);
        }
    }

    private void on_factory_unbind(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        ContactListViewRow? row = factory_rows[((!) list_item).child];
        if (row != null) ((!) row).unbind();
        if (timing_enabled) {
            timing_unbind_count++;
            timing_unbind_total_us += UiTiming.now_us() - started_us;
            timing_bound_widgets.remove((!) list_item.child);
        }
    }

    private void on_factory_teardown(Object object) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        ListItem? list_item = object as ListItem;
        if (list_item == null || ((!) list_item).child == null) return;
        Widget widget = ((!) list_item).child;
        ContactListViewRow? row = factory_rows[widget];
        if (row != null) ((!) row).cleanup();
        if (timing_enabled) timing_bound_widgets.remove(widget);
        factory_rows.unset(widget);
        if (timing_enabled) {
            timing_teardown_count++;
            timing_teardown_total_us += UiTiming.now_us() - started_us;
        }
    }

    private void on_entry_changed() {
        if (suppress_entry_change || deactivated) return;
        apply_query(entry.text);
    }

    private void apply_query(string query) {
        int64 started_us = timing_enabled ? UiTiming.now_us() : 0;
        projection.update_query(Util.sanitize_utf8(query));
        update_direct_actions();
        refresh_choice_from_controls();
        if (timing_enabled) {
            int64 duration_us = UiTiming.now_us() - started_us;
            timing_filter_count++;
            timing_filter_total_us += duration_us;
            timing_filter_max_us = int64.max(timing_filter_max_us, duration_us);
        }
    }

    private void log_timing_summary() {
        GLib.message(
            "UI-TIMING ContactSelectionView.summary: model_rows=%u projected_rows=%u " +
            "pool_max=%d bound_max=%d setup=%u/%.2fms bind=%u/%.2fms " +
            "unbind=%u/%.2fms teardown=%u/%.2fms filters=%u/%.2fms filter_max=%.2fms",
            projection.contacts.size,
            projection.items.get_n_items(),
            timing_max_pool_size,
            timing_max_bound_rows,
            timing_setup_count,
            timing_setup_total_us / 1000.0,
            timing_bind_count,
            timing_bind_total_us / 1000.0,
            timing_unbind_count,
            timing_unbind_total_us / 1000.0,
            timing_teardown_count,
            timing_teardown_total_us / 1000.0,
            timing_filter_count,
            timing_filter_total_us / 1000.0,
            timing_filter_max_us / 1000.0);
    }

    private void on_projection_selection_changed() {
        if (changing_choice || deactivated) return;
        changing_choice = true;
        if (projection.selected_item != null) direct_list.unselect_all();
        changing_choice = false;
        refresh_choice_from_controls();
    }

    private void on_list_activated(uint position) {
        if (deactivated) return;
        ViewModel.ContactListItem? item = projection.activate_position(position);
        if (item == null) return;

        changing_choice = true;
        direct_list.unselect_all();
        changing_choice = false;
        set_choice(((!) item).account, ((!) item).jid, true);
        choice_activated();
    }

    private void on_direct_selection_changed(ListBoxRow? row) {
        if (changing_choice || deactivated) return;
        changing_choice = true;
        if (row is DirectContactRow) projection.select(null);
        changing_choice = false;
        refresh_choice_from_controls();
    }

    private void refresh_choice_from_controls() {
        ViewModel.ContactListItem? selected_item = projection.selected_item;
        if (selected_item != null) {
            set_choice(((!) selected_item).account, ((!) selected_item).jid, true);
            return;
        }
        DirectContactRow? direct_row = direct_list.get_selected_row() as DirectContactRow;
        if (direct_row != null) {
            set_choice(((!) direct_row).account, ((!) direct_row).jid, false);
            return;
        }
        set_choice(null, null, false);
    }

    private void set_choice(Account? account, Jid? jid, bool roster_contact) {
        bool same_jid = selected_jid == null ? jid == null :
            (jid != null && ((!) selected_jid).equals_bare((!) jid));
        if (selected_account == account && same_jid &&
                selected_is_roster_contact == roster_contact) return;
        selected_account = account;
        selected_jid = jid != null ? ((!) jid).bare_jid : null;
        selected_is_roster_contact = roster_contact;
        remove_button.sensitive = roster_contact && account != null && jid != null;
        choice_changed();
    }

    private void on_dropdown_changed() {
        if (suppress_dropdown_change || deactivated) return;
        uint selected = account_dropdown.selected;
        Account? account = selected < dropdown_accounts.size
            ? dropdown_accounts[(int) selected]
            : null;
        projection.update_account_filter(account);
        update_direct_actions();
        refresh_choice_from_controls();
    }

    private void rebuild_account_selector() {
        if (deactivated) return;
        Account? previous = projection.account_filter;
        if (previous != null && !((!) previous).enabled) previous = null;
        dropdown_accounts.clear();
        var labels = new StringList(null);
        uint selected_index = 0;

        if (accounts.size > 1) {
            labels.append(_("All Accounts"));
            dropdown_accounts.add(null);
            foreach (Account account in accounts) {
                if (!account.enabled || !account_is_active_managed(account)) continue;
                labels.append(Util.sanitize_utf8(account.display_name));
                dropdown_accounts.add(account);
                if (account == previous) selected_index = (uint) dropdown_accounts.size - 1;
            }
        } else if (accounts.size == 1 && accounts[0].enabled && account_is_active_managed(accounts[0])) {
            labels.append(Util.sanitize_utf8(accounts[0].display_name));
            dropdown_accounts.add(accounts[0]);
        }

        suppress_dropdown_change = true;
        account_dropdown.model = labels;
        account_dropdown.selected = selected_index;
        suppress_dropdown_change = false;
        account_selector_box.visible = accounts.size > 1 && dropdown_accounts.size > 1;
        Account? next_filter = accounts.size > 1 && selected_index < dropdown_accounts.size
            ? dropdown_accounts[(int) selected_index]
            : null;
        projection.update_account_filter(next_filter);
        bool show_account_hint = enabled_account_count() > 1;
        foreach (ContactListViewRow row in factory_rows.values) {
            row.set_show_account_hint(show_account_hint);
        }
        update_direct_actions();
        refresh_choice_from_controls();
    }

    private void update_direct_actions() {
        changing_choice = true;
        direct_list.unselect_all();
        Widget? child = direct_list.get_first_child();
        while (child != null) {
            Widget? next = child.get_next_sibling();
            direct_list.remove(child);
            child = next;
        }
        changing_choice = false;

        string query = Util.sanitize_utf8(entry.text).strip();
        if (query != "") {
            try {
                Jid jid = new Jid(query);
                if (jid.localpart != null) {
                    foreach (Account account in accounts) {
                        if (!account.enabled || !account_is_active_managed(account)) continue;
                        if (projection.account_filter != null && projection.account_filter != account) continue;
                        direct_list.append(new DirectContactRow(account, jid, enabled_account_count() > 1));
                    }
                }
            } catch (InvalidJidError ignored) {
            }
        }
        direct_frame.visible = direct_list.get_first_child() != null;
        directory_button.visible = query != "";
        if (query != "") {
            string directory_label = _("Search server directory for '%s'").printf(query);
            directory_button.label = directory_label;
            directory_button.tooltip_text = directory_label;
            directory_button.update_property(AccessibleProperty.LABEL, directory_label, -1);
            // A complete address must not become the dialog's minimum width.
            // The full query remains available to accessibility and the tooltip.
            Label? label = directory_button.get_child() as Label;
            if (label != null) ((!) label).ellipsize = Pango.EllipsizeMode.END;
        }
    }

    private void request_remove_selected() {
        if (!selected_is_roster_contact || selected_account == null || selected_jid == null) return;
        remove_contact_requested((!) selected_account, (!) selected_jid);
    }

    private void request_directory_search() {
        string query = Util.sanitize_utf8(entry.text).strip();
        if (query == "") return;
        directory_search_requested(query, projection.account_filter);
    }

    private void connect_account_handlers() {
        foreach (Account account in accounts) {
            account_enabled_handler_ids[account] = account.notify["enabled"].connect(callbacks.account_enabled_changed);
        }
    }

    private void disconnect_account_handlers() {
        var connected_accounts = new ArrayList<Account>();
        foreach (Account account in account_enabled_handler_ids.keys) connected_accounts.add(account);
        foreach (Account account in connected_accounts) {
            ulong handler_id = account_enabled_handler_ids[account];
            if (SignalHandler.is_connected(account, handler_id)) SignalHandler.disconnect(account, handler_id);
            account_enabled_handler_ids.unset(account);
        }
    }

    private void on_account_removed(Account account) {
        if (deactivated) return;
        if (account_enabled_handler_ids.has_key(account)) {
            ulong handler_id = account_enabled_handler_ids[account];
            if (SignalHandler.is_connected(account, handler_id)) SignalHandler.disconnect(account, handler_id);
            account_enabled_handler_ids.unset(account);
        }
        for (int index = accounts.size - 1; index >= 0; index--) {
            if (accounts[index] == account) accounts.remove_at(index);
        }
        if (projection.account_filter == account) projection.update_account_filter(null);
        rebuild_account_selector();
    }

    private int enabled_account_count() {
        int count = 0;
        foreach (Account account in accounts) {
            if (account.enabled && account_is_active_managed(account)) count++;
        }
        return count;
    }

    private bool account_is_active_managed(Account account) {
        if (!account.enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == account && managed_account.enabled) return true;
        }
        return false;
    }
}

}
