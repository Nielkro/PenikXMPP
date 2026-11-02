using Gee;
using Qlite;

namespace Dino.Feeds {

public class Subscription : Object {
    public int id;
    public int account_id;
    public string source;
    public string node;
    public int target_id;
    public int encryption;
    public bool enabled;
    public int interval;
    public int64 checked;
    public string etag;
    public string modified;
    public string status;
    public string subid;
    public bool is_xmpp { get { return node != ""; } }

    public Subscription.from_row(Row row, SubscriptionTable table) {
        id = row[table.id]; account_id = row[table.account_id];
        source = row[table.source]; node = row[table.node];
        target_id = row[table.target_id]; encryption = row[table.encryption];
        enabled = row[table.enabled]; interval = row[table.interval];
        checked = row[table.checked]; etag = row[table.etag];
        modified = row[table.modified]; status = row[table.status];
        subid = row[table.subid];
    }
}

public class SubscriptionTable : Table {
    public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
    public Column<int> account_id = new Column.Integer("account_id");
    public Column<string> source = new Column.Text("source");
    public Column<string> node = new Column.Text("node") { default = "''" };
    public Column<int> target_id = new Column.Integer("target_id") { default = "0" };
    public Column<int> encryption = new Column.Integer("encryption") { default = "0" };
    public Column<bool> enabled = new Column.BoolInt("enabled") { default = "1" };
    public Column<int> interval = new Column.Integer("interval") { default = "30" };
    public Column<long> checked = new Column.Long("checked") { default = "0" };
    public Column<string> etag = new Column.Text("etag") { default = "''" };
    public Column<string> modified = new Column.Text("modified") { default = "''" };
    public Column<string> status = new Column.Text("status") { default = "''" };
    public Column<string> subid = new Column.Text("subid") { default = "''" };

    public SubscriptionTable(Database db) {
        base(db, "feed_subscription");
        init({id, account_id, source, node, target_id, encryption, enabled, interval, checked, etag, modified, status, subid},
            ", FOREIGN KEY(account_id) REFERENCES account(id) ON DELETE CASCADE");
        unique({account_id, source, node, target_id});
        add_post_statement("CREATE TRIGGER IF NOT EXISTS feed_target_removed AFTER DELETE ON conversation BEGIN DELETE FROM feed_subscription WHERE target_id = OLD.id; END");
    }
}

public class SeenTable : Table {
    public Column<int> subscription = new Column.Integer("subscription");
    public Column<string> item_key = new Column.Text("item_key");
    public SeenTable(Database db) {
        base(db, "feed_seen");
        init({subscription, item_key}, ", FOREIGN KEY(subscription) REFERENCES feed_subscription(id) ON DELETE CASCADE");
        unique({subscription, item_key});
    }
}

public class Store : Object {
    private Database db;
    public Store(Database db) { this.db = db; }

    public ArrayList<Subscription> list() {
        var subscriptions = new ArrayList<Subscription>();
        foreach (Row row in db.feed_subscription.select()) subscriptions.add(new Subscription.from_row(row, db.feed_subscription));
        return subscriptions;
    }

    public new Subscription? get(int id) {
        Row? row = db.feed_subscription.row_with(db.feed_subscription.id, id).inner;
        return row != null ? new Subscription.from_row((!) row, db.feed_subscription) : null;
    }

    public int add(int account, string source, string node, int target, int encryption, int interval, Gee.List<Entry> existing, string subid = "") throws Error {
        db.exec("BEGIN IMMEDIATE");
        try {
            db.exec_prepared("INSERT INTO feed_subscription (account_id, source, node, target_id, encryption, interval, subid) VALUES (?, ?, ?, ?, ?, ?, ?)",
                {account.to_string(), source, node, target.to_string(), encryption.to_string(), interval.clamp(5, 1440).to_string(), subid});
            string[] ids = db.query_column_checked("SELECT last_insert_rowid()");
            int id = int.parse(ids[0]);
            foreach (Entry entry in existing) mark_seen(id, entry.key());
            db.exec("COMMIT");
            return id;
        } catch (Error e) {
            try { db.exec("ROLLBACK"); } catch (Error ignored) { }
            throw e;
        }
    }

    public void remove(int id) throws Error {
        db.exec_prepared("DELETE FROM feed_subscription WHERE id = ?", {id.to_string()});
    }

    public void set_enabled(int id, bool enabled, int encryption) throws Error {
        db.exec_prepared("UPDATE feed_subscription SET enabled = ?, encryption = ?, checked = 0, status = '' WHERE id = ?",
            {enabled ? "1" : "0", encryption.to_string(), id.to_string()});
    }

    public void set_interval(int id, int account_id, int minutes) throws Error {
        Subscription? subscription = get(id);
        if (subscription == null || ((!) subscription).account_id != account_id ||
                ((!) subscription).is_xmpp || minutes < 5 || minutes > 1440)
            throw new IOError.INVALID_ARGUMENT("Invalid web feed subscription or check interval");
        // Preserve the last check, seen articles, pause and encryption state.
        db.exec_prepared("UPDATE feed_subscription SET interval = ? WHERE id = ? AND account_id = ? AND node = ''",
            {minutes.to_string(), id.to_string(), account_id.to_string()});
    }

    public void checked(int id, string status, string? etag = null, string? modified = null) throws Error {
        db.exec_prepared("UPDATE feed_subscription SET checked = ?, status = ? WHERE id = ?",
            {new DateTime.now_utc().to_unix().to_string(), status, id.to_string()});
        if (etag != null && modified != null)
            db.exec_prepared("UPDATE feed_subscription SET etag = ?, modified = ? WHERE id = ?",
                {(!) etag, (!) modified, id.to_string()});
    }

    public bool seen(int id, string key) throws Error {
        return db.query_column_checked("SELECT item_key FROM feed_seen WHERE subscription = ? AND item_key = ?",
            {id.to_string(), key}).length != 0;
    }

    public void mark_seen(int id, string key) throws Error {
        db.exec_prepared("INSERT OR IGNORE INTO feed_seen (subscription, item_key) VALUES (?, ?)", {id.to_string(), key});
    }
}
}
