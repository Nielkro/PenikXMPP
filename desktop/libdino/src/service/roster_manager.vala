using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public enum RosterRemoveResult {
    SUCCESS,
    SERVER_REJECTED,
    UNAVAILABLE
}

public class RosterManager : StreamInteractionModule, Object {
    public static ModuleIdentity<RosterManager> IDENTITY = new ModuleIdentity<RosterManager>("roster_manager");
    public string id { get { return IDENTITY.id; } }

    public signal void removed_roster_item(Account account, Jid jid, Roster.Item roster_item);
    public signal void updated_roster_item(Account account, Jid jid, Roster.Item roster_item);
    public signal void mutual_subscription(Account account, Jid jid);

    private StreamInteractor stream_interactor;
    private Database db;
    private Gee.Map<Account, RosterStoreImpl> roster_stores = new HashMap<Account, RosterStoreImpl>(Account.hash_func, Account.equals_func);

    public static void start(StreamInteractor stream_interactor, Database db) {
        RosterManager m = new RosterManager(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    public RosterManager(StreamInteractor stream_interactor, Database db) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.module_manager.initialize_account_modules.connect((account, modules) => {
            modules.add(new Roster.VersioningModule(get_or_create_roster_store(account)));
        });
    }

    public Collection<Roster.Item> get_roster(Account account) {
        if (roster_stores[account] == null) return new ArrayList<Roster.Item>();
        return roster_stores[account].get_roster();
    }

    public Roster.Item? get_roster_item(Account account, Jid jid) {
        if (roster_stores[account] == null) return null;
        return roster_stores[account].get_item(jid);
    }

    public void remove_jid(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) stream.get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY).remove_jid(stream, jid.bare_jid);
    }

    public async RosterRemoveResult remove_jid_async(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return RosterRemoveResult.UNAVAILABLE;

        try {
            bool removed = yield stream.get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY).remove_jid_async(stream, jid.bare_jid);
            return removed ? RosterRemoveResult.SUCCESS : RosterRemoveResult.SERVER_REJECTED;
        } catch (IOError e) {
            warning("Failed to remove roster item %s for %s: %s", jid.bare_jid.to_string(), account.bare_jid.to_string(), e.message);
            return RosterRemoveResult.UNAVAILABLE;
        }
    }

    public void remove_jid_locally(Account account, Jid jid) {
        if (roster_stores.has_key(account)) {
            Roster.Item? item = roster_stores[account].get_item(jid.bare_jid);
            if (item != null) {
                roster_stores[account].remove_item(item);
                removed_roster_item(account, jid.bare_jid, item);
                return;
            }
        }
        db.roster.delete()
            .with(db.roster.account_id, "=", account.id)
            .with(db.roster.jid, "=", jid.bare_jid.to_string())
            .perform();
    }

    public void add_jid(Account account, Jid jid, string? handle) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) stream.get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY).add_jid(stream, jid.bare_jid, handle);
    }

    public async bool add_jid_async(Account account, Jid jid,
            string? handle) throws IOError {
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("The account is not connected");
        Xmpp.Roster.Module? module = ((!) stream).get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_CONNECTED("The roster module is unavailable");
        bool added = yield ((!) module).add_jid_async((!) stream, jid.bare_jid, handle);
        if (stream_interactor.get_connected_stream_for_action(account) != stream) {
            throw new IOError.NOT_CONNECTED("The account connection changed while adding the contact");
        }
        return added;
    }

    public void set_jid_handle(Account account, Jid jid, string? handle) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            Roster.Item? existing_item = roster_stores.has_key(account) ? roster_stores[account].get_item(jid.bare_jid) : null;
            stream.get_module<Xmpp.Roster.Module>(Xmpp.Roster.Module.IDENTITY).set_jid_handle(
                stream,
                jid.bare_jid,
                handle,
                existing_item != null ? existing_item.groups : null
            );
        }
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).received_roster.connect_after( (stream, roster) => {
            foreach (Roster.Item roster_item in roster) {
                on_roster_item_updated(account, roster_item);
            }
        });
        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).item_removed.connect_after( (stream, roster_item) => {
            removed_roster_item(account, roster_item.jid, roster_item);
        });
        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).item_updated.connect_after( (stream, roster_item) => {
            on_roster_item_updated(account, roster_item);
        });

        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).mutual_subscription.connect_after( (stream, jid) => {
            mutual_subscription(account, jid);
        });
    }

    private void on_roster_item_updated(Account account, Roster.Item roster_item) {
        updated_roster_item(account, roster_item.jid, roster_item);
    }

    private void on_snapshot_item_removed(Account account, Roster.Item roster_item) {
        removed_roster_item(account, roster_item.jid, roster_item);
    }

    private void on_account_removed(Account account) {
        roster_stores.unset(account);
    }

    internal RosterStoreImpl get_or_create_roster_store(Account account) {
        RosterStoreImpl? existing = roster_stores[account];
        if (existing != null) return (!) existing;

        var store = new RosterStoreImpl(account, db);
        store.snapshot_item_removed.connect(on_snapshot_item_removed);
        roster_stores[account] = store;
        return store;
    }
}

public class RosterStoreImpl : Roster.Storage, Object {
    /** Emitted after an authoritative full snapshot removed an old item. */
    internal signal void snapshot_item_removed(Account account, Roster.Item roster_item);

    private Account account;
    private Database db;

    private HashMap<Jid, Roster.Item> items = new HashMap<Jid, Roster.Item>(Jid.hash_bare_func, Jid.equals_bare_func);

    public RosterStoreImpl(Account account, Database db) {
        this.account = account;
        this.db = db;

        foreach (Qlite.Row row in db.roster.select().with(db.roster.account_id, "=", account.id)) {
            try {
                Roster.Item item = new Roster.Item();
                item.jid = new Jid(row[db.roster.jid]);
                item.name = row[db.roster.handle];
                item.subscription = row[db.roster.subscription];
                string? ask_val = row[db.roster.ask];
                if (ask_val != null) {
                    item.stanza_node.set_attribute("ask", ask_val);
                }
                item.replace_groups(decode_roster_groups(row[db.roster.groups]));
                items[item.jid] = item;
            } catch (InvalidJidError e) {
                warning("Ignoring roster entry with invalid Jid: %s", e.message);
            }
        }
    }

    public string? get_roster_version() {
        return account.roster_version;
    }

    public Collection<Roster.Item> get_roster() {
        return items.values;
    }

    public Roster.Item? get_item(Jid jid) {
        return items.has_key(jid) ? items[jid] : null;
    }

    public void set_roster_version(string version) {
        account.roster_version = version;
    }

    public void set_roster(Collection<Roster.Item> replacement_items) {
        // Copy both sides before mutating. Versioning callers may pass the
        // store's own values collection, and observers must see the complete
        // replacement state when removal signals run.
        var replacements = new ArrayList<Roster.Item>();
        replacements.add_all(replacement_items);
        var previous_items = new ArrayList<Roster.Item>();
        previous_items.add_all(this.items.values);

        db.roster.delete().with(db.roster.account_id, "=", account.id).perform();
        this.items.clear();
        foreach (Roster.Item item in replacements) {
            set_item(item);
        }
        foreach (Roster.Item previous_item in previous_items) {
            if (!this.items.has_key(previous_item.jid)) {
                snapshot_item_removed(account, previous_item);
            }
        }
    }

    public void set_item(Roster.Item item) {
        items[item.jid] = item;
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, item.jid.to_string(), true)
            .value(db.roster.handle, item.name)
            .value(db.roster.subscription, item.subscription)
            .value(db.roster.ask, item.ask)
            .value(db.roster.groups, encode_roster_groups(item.groups))
            .perform();
    }

    public void remove_item(Roster.Item item) {
        items.unset(item.jid);
        db.roster.delete()
            .with(db.roster.account_id, "=", account.id)
            .with(db.roster.jid, "=", item.jid.to_string()).perform();
    }

    private static string? encode_roster_groups(Collection<string> groups) {
        StringBuilder builder = new StringBuilder();
        bool first = true;

        foreach (string group in groups) {
            if (group == "") continue;

            if (!first) builder.append_c('\n');
            builder.append(Uri.escape_string(group, null, false));
            first = false;
        }

        return first ? null : builder.str;
    }

    private static ArrayList<string> decode_roster_groups(string? encoded_groups) {
        var groups = new ArrayList<string>();
        if (encoded_groups == null || encoded_groups == "") return groups;

        foreach (string encoded_group in encoded_groups.split("\n")) {
            if (encoded_group == "") continue;

            string? group = Uri.unescape_string(encoded_group);
            if (group != null && group != "") {
                groups.add(group);
            } else {
                warning("Ignoring invalid cached roster group");
            }
        }

        return groups;
    }
}

}
