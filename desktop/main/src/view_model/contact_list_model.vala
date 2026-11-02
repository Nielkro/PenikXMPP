using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Ui.ViewModel {

[Flags]
public enum ContactListItemChange {
    NONE = 0,
    ALIAS = 1 << 0,
    DISPLAY_NAME = 1 << 1,
    SEARCH_TEXT = 1 << 2,
    SORT_KEY = 1 << 3
}

/**
 * Stable, widget-independent identity for one contact list entry.
 *
 * Presence observers, avatars and other view lifetimes deliberately do not
 * belong here. Gtk.ListView factories can add those only while a row is bound.
 */
public class ContactListItem : Object {
    public Account account { get; private set; }
    public int account_id { get; private set; }
    public Jid jid { get; private set; }
    public string key { get; private set; }
    public string? alias { get; private set; }
    public string display_name { get; private set; }
    public string search_text { get; private set; }
    public string sort_key { get; private set; }

    internal ContactListItem(Account account, Jid jid, string? alias) {
        this.account = account;
        this.account_id = account.id;
        this.jid = jid.bare_jid;
        this.key = ContactListModel.key_for(account, jid);
        this.alias = null;
        this.display_name = this.jid.to_string();
        this.search_text = normalize_search_value(this.display_name);
        this.sort_key = this.search_text.collate_key();
        update_alias(alias);
    }

    internal ContactListItemChange update_alias(string? alias) {
        string? normalized_alias = alias != null ? alias.make_valid().strip() : null;
        if (normalized_alias == "") normalized_alias = null;

        string next_display_name = normalized_alias ?? jid.to_string();
        string next_search_text = normalize_search_value("%s\n%s".printf(next_display_name, jid.to_string()));
        string next_sort_key = normalize_search_value(next_display_name).collate_key();
        ContactListItemChange changes = ContactListItemChange.NONE;
        if (this.alias != normalized_alias) changes |= ContactListItemChange.ALIAS;
        if (this.display_name != next_display_name) changes |= ContactListItemChange.DISPLAY_NAME;
        if (this.search_text != next_search_text) changes |= ContactListItemChange.SEARCH_TEXT;
        if (this.sort_key != next_sort_key) changes |= ContactListItemChange.SORT_KEY;
        if (changes == ContactListItemChange.NONE) return changes;

        freeze_notify();
        if ((changes & ContactListItemChange.ALIAS) != 0) this.alias = normalized_alias;
        if ((changes & ContactListItemChange.DISPLAY_NAME) != 0) this.display_name = next_display_name;
        if ((changes & ContactListItemChange.SEARCH_TEXT) != 0) this.search_text = next_search_text;
        if ((changes & ContactListItemChange.SORT_KEY) != 0) this.sort_key = next_sort_key;
        thaw_notify();
        return changes;
    }

    public bool matches(string query) {
        string normalized_query = normalize_search_value(query).strip();
        string[] tokens = normalized_query == "" ? new string[0] : normalized_query.split_set(" \t\r\n");
        return matches_tokens(tokens);
    }

    internal bool matches_tokens(string[] tokens) {
        foreach (string token in tokens) {
            if (token != "" && !search_text.contains(token)) return false;
        }
        return true;
    }

    internal static string normalize_search_value(string value) {
        return value.make_valid().normalize(-1, NormalizeMode.NFKC).casefold();
    }

    public static int compare(ContactListItem left, ContactListItem right) {
        int result = strcmp(left.sort_key, right.sort_key);
        if (result != 0) return result;

        result = strcmp(left.jid.to_string(), right.jid.to_string());
        if (result != 0) return result;
        if (left.account_id < right.account_id) return -1;
        if (left.account_id > right.account_id) return 1;
        return 0;
    }
}

/**
 * Keyed contact store. Upserts update an existing GObject in place so GTK
 * selection remains attached to the same item across alias and roster updates.
 */
public class ContactListModel : Object {
    public signal void item_updated(ContactListItem item, ContactListItemChange changes);
    public signal void item_added(ContactListItem item);
    public signal void item_removing(ContactListItem item);

    public GLib.ListModel items { get { return store; } }
    public uint size { get { return store.get_n_items(); } }

    private GLib.ListStore store;
    private HashMap<string, ContactListItem> items_by_key = new HashMap<string, ContactListItem>();

    construct {
        store = new GLib.ListStore(typeof(ContactListItem));
    }

    public ContactListItem upsert(Account account, Jid jid, string? alias) {
        string key = key_for(account, jid);
        ContactListItem? existing = items_by_key[key];
        if (existing != null) {
            ContactListItemChange changes = ((!) existing).update_alias(alias);
            if (changes != ContactListItemChange.NONE) item_updated((!) existing, changes);
            return (!) existing;
        }

        var item = new ContactListItem(account, jid.bare_jid, alias);
        items_by_key[key] = item;
        store.append(item);
        item_added(item);
        notify_property("size");
        return item;
    }

    public ContactListItem? lookup(Account account, Jid jid) {
        return items_by_key[key_for(account, jid)];
    }

    public bool remove(Account account, Jid jid) {
        string key = key_for(account, jid);
        ContactListItem? item = items_by_key[key];
        if (item == null) return false;

        uint found_index = uint.MAX;
        for (uint index = 0; index < store.get_n_items(); index++) {
            if (store.get_item(index) == item) {
                found_index = index;
                break;
            }
        }
        if (found_index != uint.MAX) {
            item_removing((!) item);
            items_by_key.unset(key);
            store.remove(found_index);
            notify_property("size");
        } else {
            items_by_key.unset(key);
        }
        return true;
    }

    public void clear() {
        bool had_items = store.get_n_items() > 0;
        if (had_items) {
            var removing_items = new ArrayList<ContactListItem>();
            for (uint index = 0; index < store.get_n_items(); index++) {
                ContactListItem? item = store.get_item(index) as ContactListItem;
                if (item != null) removing_items.add((!) item);
            }
            foreach (ContactListItem item in removing_items) item_removing(item);
        }
        items_by_key.clear();
        store.remove_all();
        if (had_items) notify_property("size");
    }

    public static string key_for(Account account, Jid jid) {
        // Active roster accounts are persisted before entering this model, so
        // account.id is stable for the complete lifetime of an item.
        return "%d|%s".printf(account.id, jid.bare_jid.to_string());
    }
}

}
