using Dino.Entities;
using Dino.Ui.ViewModel;
using Gee;
using Xmpp;

namespace Dino.Ui.Test {

class ContactRosterModelSourceTest : Gee.TestCase {
    public ContactRosterModelSourceTest() {
        base("ContactRosterModelSource");
        add_test("snapshot_live_scope_and_deactivate", test_snapshot_live_scope_and_deactivate);
    }

    private void test_snapshot_live_scope_and_deactivate() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-contact-source-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "contact-source-test");
            Account first = make_account((!) db, "first@example.test");
            Account second = make_account((!) db, "second@example.test");
            Account unscoped = make_account((!) db, "unscoped@example.test");
            seed_roster((!) db, first, "shared@example.test", "First shared");
            seed_roster((!) db, second, "shared@example.test", "Second shared");
            seed_roster((!) db, unscoped, "hidden@example.test", "Hidden");

            // This is a model-only test. The production constructor also
            // initializes host integrations such as the login1 system-bus
            // proxy, which must not leak into the headless unit-test process.
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            RosterManager.start(stream_interactor, (!) db);
            stream_interactor.module_manager.initialize(first);
            stream_interactor.module_manager.initialize(second);
            stream_interactor.module_manager.initialize(unscoped);
            RosterManager manager = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            var scope = new ArrayList<Account>();
            scope.add(first);
            scope.add(second);
            var source = new ContactRosterModelSource(stream_interactor, scope);
            Jid shared = new Jid("shared@example.test");

            fail_if_not_eq_int(2, (int) source.model.size);
            assert_true(source.model.lookup(first, shared) != null);
            assert_true(source.model.lookup(second, shared) != null);
            assert_true(source.model.lookup(unscoped, new Jid("hidden@example.test")) == null);

            ContactListItem first_item = (!) source.model.lookup(first, shared);
            Roster.Item renamed = make_roster_item("shared@example.test", "Renamed");
            manager.updated_roster_item(first, shared, renamed);
            assert_true(source.model.lookup(first, shared) == first_item,
                "live upsert must preserve stable item identity");
            fail_if_not_eq_str("Renamed", first_item.display_name);

            manager.removed_roster_item(first, shared, renamed);
            assert_true(source.model.lookup(first, shared) == null);
            assert_true(source.model.lookup(second, shared) != null,
                "same bare JID on another account must remain");

            stream_interactor.account_removed(second);
            fail_if_not_eq_int(0, (int) source.model.size);
            manager.updated_roster_item(second, shared, renamed);
            fail_if_not_eq_int(0, (int) source.model.size);

            source.deactivate();
            manager.updated_roster_item(first, shared, renamed);
            fail_if_not_eq_int(0, (int) source.model.size);
        } catch (Error error) {
            GLib.Test.message("Unexpected contact source error: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-shm");
            FileUtils.remove(db_path + "-wal");
            DirUtils.remove(temp_dir);
        }
    }

    private Account make_account(Database db, string jid) throws InvalidJidError {
        var account = new Account(new Jid(jid), "secret") { enabled = true };
        account.persist(db);
        return account;
    }

    private void seed_roster(Database db, Account account, string jid, string name) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid, true)
            .value(db.roster.handle, name)
            .value(db.roster.subscription, Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private Roster.Item make_roster_item(string jid, string name) throws InvalidJidError {
        var item = new Roster.Item();
        item.jid = new Jid(jid);
        item.name = name;
        item.subscription = Roster.Item.SUBSCRIPTION_BOTH;
        return item;
    }
}

}
