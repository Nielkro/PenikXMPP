using Gee;
using Xmpp;

namespace Dino.Test {

class RosterManagerTest : Gee.TestCase {
    public RosterManagerTest() {
        base("RosterManager");
        add_test("full_snapshot_replaces_memory_database_and_emits_removals",
            test_full_snapshot_replaces_memory_database_and_emits_removals);
        add_test("account_recreation_gets_fresh_scoped_store",
            test_account_recreation_gets_fresh_scoped_store);
    }

    private void test_full_snapshot_replaces_memory_database_and_emits_removals() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-roster-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "roster-manager-test");
            var account = new Entities.Account(new Jid("alice@example.test"), "secret");
            account.enabled = true;
            account.persist((!) db);
            var store = new RosterStoreImpl(account, (!) db);

            Roster.Item keep = make_item("keep@example.test", "Old name");
            Roster.Item stale = make_item("stale@example.test", "Stale");
            var initial = new ArrayList<Roster.Item>();
            initial.add(keep);
            initial.add(stale);
            store.set_roster(initial);

            var removed_jids = new ArrayList<string>();
            Jid added_jid = new Jid("added@example.test");
            store.snapshot_item_removed.connect((removed_account, item) => {
                fail_if(removed_account != account, "snapshot removal must retain account scope");
                fail_if(store.get_item(item.jid) != null,
                    "removed item must already be absent when the signal runs");
                if (item.jid.bare_jid.to_string() == "stale@example.test") {
                    fail_if(store.get_item(added_jid) == null,
                        "replacement items must already be visible when the signal runs");
                }
                removed_jids.add(item.jid.bare_jid.to_string());
            });

            Roster.Item renamed_keep = make_item("keep@example.test", "New name");
            Roster.Item added = make_item("added@example.test", "Added");
            var replacement = new ArrayList<Roster.Item>();
            replacement.add(renamed_keep);
            replacement.add(added);
            store.set_roster(replacement);

            fail_if(store.get_roster().size != 2, "full snapshot must replace the in-memory roster");
            fail_if(store.get_item(new Jid("stale@example.test")) != null,
                "contact absent from full snapshot must leave memory");
            Roster.Item? updated = store.get_item(new Jid("keep@example.test"));
            fail_if(updated == null, "retained contact must remain available");
            if (updated != null) fail_if_not_eq_str("New name", ((!) updated).name);
            fail_if(removed_jids.size != 1, "exactly one stale item must emit removal");
            if (removed_jids.size == 1) fail_if_not_eq_str("stale@example.test", removed_jids[0]);

            // Replacing from the store's own live values collection must not
            // clear it while it is being iterated.
            store.set_roster(store.get_roster());
            fail_if(store.get_roster().size != 2, "self-backed snapshot replacement must be safe");
            fail_if(removed_jids.size != 1, "unchanged replacement must not emit removals");

            var reopened = new RosterStoreImpl(account, (!) db);
            fail_if(reopened.get_roster().size != 2, "database snapshot must match memory");
            fail_if(reopened.get_item(new Jid("stale@example.test")) != null,
                "stale contact must also be absent after reopening storage");

            store.set_roster(new ArrayList<Roster.Item>());
            fail_if(store.get_roster().size != 0, "empty full snapshot must clear memory");
            fail_if(removed_jids.size != 3, "empty snapshot must remove both remaining contacts");
            fail_if(!removed_jids.contains("keep@example.test"),
                "empty snapshot must report the retained contact");
            fail_if(!removed_jids.contains("added@example.test"),
                "empty snapshot must report the added contact");
        } catch (Error error) {
            fail_if_reached("Unexpected roster replacement error: " + error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private Roster.Item make_item(string jid, string name) throws InvalidJidError {
        var item = new Roster.Item();
        item.jid = new Jid(jid);
        item.name = name;
        item.subscription = Roster.Item.SUBSCRIPTION_BOTH;
        return item;
    }

    private void test_account_recreation_gets_fresh_scoped_store() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-roster-recreate-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "roster-recreate-test");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            var manager = new RosterManager(stream_interactor, (!) db);

            var old_account = new Entities.Account(new Jid("same@example.test"), "old-secret");
            old_account.persist((!) db);
            RosterStoreImpl old_store = manager.get_or_create_roster_store(old_account);
            var old_items = new ArrayList<Roster.Item>();
            old_items.add(make_item("old-contact@example.test", "Old"));
            old_store.set_roster(old_items);

            // This is the real account lifecycle signal. It must evict the
            // bare-JID-keyed store before an account with the same JID exists.
            stream_interactor.account_removed(old_account);
            old_account.remove();
            var new_account = new Entities.Account(new Jid("same@example.test"), "new-secret");
            new_account.persist((!) db);
            RosterStoreImpl new_store = manager.get_or_create_roster_store(new_account);

            fail_if(old_store == new_store, "recreated account must not reuse the removed account's store");
            fail_if(new_store.get_roster().size != 0,
                "recreated account must start from its own empty persisted roster");

            Entities.Account? signalled_account = null;
            manager.removed_roster_item.connect((account, jid, item) => {
                signalled_account = account;
            });
            var replacement = new ArrayList<Roster.Item>();
            replacement.add(make_item("temporary@example.test", "Temporary"));
            new_store.set_roster(replacement);
            new_store.set_roster(new ArrayList<Roster.Item>());
            fail_if(signalled_account != new_account,
                "snapshot removal must be scoped to the recreated account object");
        } catch (Error error) {
            fail_if_reached("Unexpected account recreation error: " + error.message);
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }
}

}
