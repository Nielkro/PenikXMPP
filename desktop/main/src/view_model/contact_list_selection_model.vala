using Dino.Entities;
using Gee;
using Gtk;

namespace Dino.Ui.ViewModel {

/**
 * Filtered, sorted and selectable projection of ContactListModel.
 *
 * This is the contact-only backend for the later Gtk.ListView. The existing
 * group/MUC ListBox path does not use or depend on this class.
 */
public class ContactListSelectionModel : Object {
    public ContactListModel contacts { get; private set; }
    public GLib.ListModel items { get { return sorted; } }
    public Gtk.SingleSelection selection { get; private set; }
    public string query { get { return query_; } }
    public Account? account_filter { get { return account_filter_; } }
    public ContactListItem? selected_item {
        owned get { return selection.get_selected_item() as ContactListItem; }
    }

    private Gtk.CustomFilter filter;
    private Gtk.FilterListModel filtered;
    private Gtk.CustomSorter sorter;
    private Gtk.SortListModel sorted;
    private CallbackBridge callbacks;
    private string query_ = "";
    private string[] query_tokens = new string[0];
    private Account? account_filter_ = null;
    private HashMap<Account, ulong> account_enabled_handler_ids = new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    private HashMap<Account, int> account_item_counts = new HashMap<Account, int>(Account.hash_func, Account.equals_func);
    private ulong item_added_handler_id = 0;
    private ulong item_removing_handler_id = 0;
    private ulong item_updated_handler_id = 0;
    private ulong selection_changed_handler_id = 0;

    // GTK's C callback takes gpointer. Keep the item typed as Object in Vala
    // while matching the C ABI and retaining the owned delegate's cleanup.
    private delegate bool ContactFilterFunc([CCode (type = "gpointer")] GLib.Object item);
    [CCode (cname = "gtk_custom_filter_new", cheader_filename = "gtk/gtk.h")]
    private static extern Gtk.CustomFilter create_contact_filter(owned ContactFilterFunc match_func);

    private class CallbackBridge : Object {
        private WeakRef owner_ref;

        public CallbackBridge(ContactListSelectionModel owner) {
            owner_ref = WeakRef(owner);
        }

        public bool filter_item(GLib.Object object) {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            return owner != null && ((!) owner).matches(object);
        }

        public void item_updated(ContactListItem item, ContactListItemChange changes) {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            if (owner != null) ((!) owner).on_item_updated(changes);
        }

        public void selection_changed() {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            if (owner != null) ((!) owner).notify_property("selected-item");
        }

        public void item_added(ContactListItem item) {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            if (owner != null) ((!) owner).on_item_added(item);
        }

        public void item_removing(ContactListItem item) {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            if (owner != null) ((!) owner).on_item_removing(item);
        }

        public void account_enabled_changed() {
            ContactListSelectionModel? owner = (ContactListSelectionModel?) owner_ref.get();
            if (owner != null) ((!) owner).on_account_state_changed();
        }

        public void clear() {
            owner_ref.set(null);
        }
    }

    public ContactListSelectionModel(ContactListModel contacts) {
        this.contacts = contacts;
        callbacks = new CallbackBridge(this);

        filter = create_contact_filter(callbacks.filter_item);
        filtered = new Gtk.FilterListModel(null, null);
        filtered.set_model(contacts.items);
        filtered.set_filter(filter);

        sorter = new Gtk.CustomSorter(compare_items);
        sorted = new Gtk.SortListModel(null, null);
        sorted.set_model(filtered);
        sorted.set_sorter(sorter);

        // Configure selection policy before attaching the populated model so
        // Gtk never creates a transient row-0 selection.
        selection = new Gtk.SingleSelection(null) {
            autoselect = false,
            can_unselect = true
        };
        selection.set_model(sorted);

        item_updated_handler_id = contacts.item_updated.connect(callbacks.item_updated);
        item_added_handler_id = contacts.item_added.connect(callbacks.item_added);
        item_removing_handler_id = contacts.item_removing.connect(callbacks.item_removing);
        selection_changed_handler_id = selection.notify["selected-item"].connect(callbacks.selection_changed);
        for (uint index = 0; index < contacts.items.get_n_items(); index++) {
            ContactListItem? item = contacts.items.get_item(index) as ContactListItem;
            if (item != null) on_item_added((!) item);
        }
    }

    public void update_query(string query) {
        string safe_query = query.make_valid();
        if (query_ == safe_query) return;

        ContactListItem? selected = selected_item;
        string normalized_query = ContactListItem.normalize_search_value(safe_query).strip();
        query_ = safe_query;
        query_tokens = normalized_query == "" ? new string[0] : normalized_query.split_set(" \t\r\n");
        filter.changed(Gtk.FilterChange.DIFFERENT);
        restore_selection(selected);
        notify_property("query");
    }

    public void update_account_filter(Account? account) {
        Account? next_account = account != null && ((!) account).enabled ? account : null;
        if (account_filter_ == next_account) return;

        ContactListItem? selected = selected_item;
        Account? previous_account = account_filter_;
        account_filter_ = next_account;
        if (next_account != null) ensure_account_handler((!) next_account);
        filter.changed(Gtk.FilterChange.DIFFERENT);
        restore_selection(selected);
        if (previous_account != null && previous_account != next_account) {
            disconnect_unused_account_handler((!) previous_account);
        }
        notify_property("account-filter");
    }

    public void refresh_account_state() {
        if (account_filter_ != null && !((!) account_filter_).enabled) {
            update_account_filter(null);
            return;
        }
        ContactListItem? selected = selected_item;
        filter.changed(Gtk.FilterChange.DIFFERENT);
        restore_selection(selected);
    }

    public bool select(ContactListItem? item) {
        if (item == null) {
            selection.set_selected(Gtk.INVALID_LIST_POSITION);
            return true;
        }

        for (uint index = 0; index < sorted.get_n_items(); index++) {
            if (sorted.get_item(index) == item) {
                selection.set_selected(index);
                return true;
            }
        }
        selection.set_selected(Gtk.INVALID_LIST_POSITION);
        return false;
    }

    /** Select and return the exact item activated by Gtk.ListView. */
    public ContactListItem? activate_position(uint position) {
        if (position >= sorted.get_n_items()) return null;
        ContactListItem? item = sorted.get_item(position) as ContactListItem;
        if (item == null) return null;
        selection.set_selected(position);
        return item;
    }

    private bool matches(GLib.Object object) {
        ContactListItem? item = object as ContactListItem;
        if (item == null || !((!) item).account.enabled) return false;
        if (account_filter_ != null && ((!) item).account != account_filter_) return false;
        return ((!) item).matches_tokens(query_tokens);
    }

    private static int compare_items(void* left_object, void* right_object) {
        unowned ContactListItem? left = left_object as ContactListItem;
        unowned ContactListItem? right = right_object as ContactListItem;
        if (left == null || right == null) return 0;
        return ContactListItem.compare((!) left, (!) right);
    }

    private void on_item_updated(ContactListItemChange changes) {
        ContactListItem? selected = selected_item;
        if ((changes & ContactListItemChange.SEARCH_TEXT) != 0) {
            filter.changed(Gtk.FilterChange.DIFFERENT);
        }
        if ((changes & ContactListItemChange.SORT_KEY) != 0) {
            sorter.changed(Gtk.SorterChange.DIFFERENT);
        }
        restore_selection(selected);
    }

    private void restore_selection(ContactListItem? previous) {
        if (previous != null) select(previous);
    }

    private void on_account_state_changed() {
        refresh_account_state();
    }

    private void on_item_added(ContactListItem item) {
        Account account = item.account;
        int count = account_item_counts.has_key(account) ? account_item_counts[account] : 0;
        account_item_counts[account] = count + 1;
        ensure_account_handler(account);
    }

    private void on_item_removing(ContactListItem item) {
        Account account = item.account;
        int count = account_item_counts.has_key(account) ? account_item_counts[account] : 0;
        if (count <= 1) {
            account_item_counts.unset(account);
            disconnect_unused_account_handler(account);
        } else {
            account_item_counts[account] = count - 1;
        }
    }

    private void ensure_account_handler(Account account) {
        if (account_enabled_handler_ids.has_key(account)) return;
        account_enabled_handler_ids[account] = account.notify["enabled"].connect(callbacks.account_enabled_changed);
    }

    private void disconnect_unused_account_handler(Account account) {
        if (account_item_counts.has_key(account) || account_filter_ == account) return;
        disconnect_account_handler(account);
    }

    private void disconnect_account_handler(Account account) {
        if (!account_enabled_handler_ids.has_key(account)) return;
        ulong handler_id = account_enabled_handler_ids[account];
        if (SignalHandler.is_connected(account, handler_id)) SignalHandler.disconnect(account, handler_id);
        account_enabled_handler_ids.unset(account);
    }

    public override void dispose() {
        if (contacts != null && item_updated_handler_id != 0 &&
                SignalHandler.is_connected(contacts, item_updated_handler_id)) {
            SignalHandler.disconnect(contacts, item_updated_handler_id);
        }
        item_updated_handler_id = 0;

        if (contacts != null && item_added_handler_id != 0 &&
                SignalHandler.is_connected(contacts, item_added_handler_id)) {
            SignalHandler.disconnect(contacts, item_added_handler_id);
        }
        item_added_handler_id = 0;

        if (contacts != null && item_removing_handler_id != 0 &&
                SignalHandler.is_connected(contacts, item_removing_handler_id)) {
            SignalHandler.disconnect(contacts, item_removing_handler_id);
        }
        item_removing_handler_id = 0;

        var connected_accounts = new ArrayList<Account>();
        foreach (Account account in account_enabled_handler_ids.keys) connected_accounts.add(account);
        foreach (Account account in connected_accounts) disconnect_account_handler(account);
        account_item_counts.clear();

        if (selection != null && selection_changed_handler_id != 0 &&
                SignalHandler.is_connected(selection, selection_changed_handler_id)) {
            SignalHandler.disconnect(selection, selection_changed_handler_id);
        }
        selection_changed_handler_id = 0;
        if (filter != null) filter.set_filter_func(null);
        if (sorter != null) sorter.set_sort_func(null);
        if (callbacks != null) callbacks.clear();
        base.dispose();
    }
}

}
