using Dino.Entities;
using Dino.Ui.ViewModel;
using Gee;
using Xmpp;

namespace Dino.Ui.Test {

class ContactSubscriptionModelTest : Gee.TestCase {
    public ContactSubscriptionModelTest() {
        base("ContactSubscriptionModel");
        add_test("live_roster_pending_and_mutual_permissions", () => run_case(0));
        add_test("incoming_withdrawal_and_account_scope", () => run_case(1));
        add_test("offline_disabled_and_removed_account", () => run_case(2));
        add_test("recreated_account_cannot_update_old_contact", () => run_case(3));
        add_test("deactivation_and_weak_callback_lifetime", () => run_case(4));
        add_test("cyrillic_jid_and_alias_remain_utf8", () => run_case(5));
    }

    private void run_case(int scenario) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            exercise((!) fixture, scenario);
        } catch (Error error) {
            GLib.Test.message("Unexpected contact permission test error: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void exercise(Fixture f, int scenario) throws Error {
        var model = new ContactSubscriptionModel(f.interactor, f.first, f.contact.with_resource("phone"));
        assert_true(model.connected);
        assert_false(model.in_roster);
        assert_false(model.receives_presence);
        assert_false(model.shares_presence);
        switch (scenario) {
            case 0:
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_NONE, "subscribe");
                assert_true(model.in_roster && model.outgoing_pending);
                assert_false(model.receives_presence || model.shares_presence,
                    "A pending request must not grant either direction locally");
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_NONE, "subscribe", null, true);
                assert_true(model.preapproved && !model.shares_presence && !model.receives_presence,
                    "Server-confirmed preapproval is not an active mutual subscription");
                f.update(f.second, f.contact, Roster.Item.SUBSCRIPTION_BOTH);
                assert_false(model.receives_presence || model.shares_presence,
                    "Another account's permissions must not affect this contact");
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_TO);
                assert_true(model.receives_presence && !model.shares_presence && !model.outgoing_pending);
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_BOTH);
                assert_true(model.receives_presence && model.shares_presence);
                f.remove(f.first, f.contact);
                assert_false(model.in_roster || model.receives_presence || model.shares_presence);
                break;
            case 1:
                f.incoming(f.second, f.other_stream, f.contact);
                assert_false(model.incoming_pending);
                f.incoming(f.first, f.stream, f.contact.with_resource("tablet"));
                assert_true(model.incoming_pending);
                assert_false(model.receives_presence || model.shares_presence);
                f.stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unsubscription(f.stream, f.contact);
                assert_false(model.incoming_pending);
                f.incoming(f.first, f.stream, f.contact);
                assert_true(model.incoming_pending);
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_FROM);
                assert_true(model.shares_presence && !model.incoming_pending,
                    "Server-confirmed approval on another device must clear the incoming request");
                break;
            case 2:
                f.interactor.connection_manager.set_connection_state_for_tests(f.first, ConnectionManager.ConnectionState.DISCONNECTED);
                assert_false(model.connected);
                f.interactor.connection_manager.set_connected_stream_for_tests(f.first, f.stream);
                assert_true(model.connected);
                f.first.enabled = false;
                assert_false(model.connected);
                f.first.enabled = true;
                assert_true(model.connected);
                f.interactor.account_removed(f.first);
                assert_false(model.connected || model.in_roster || model.incoming_pending);
                break;
            case 3:
                f.interactor.account_removed(f.first);
                f.first.remove();
                var replacement = new Account(f.first.bare_jid, "new-secret") { enabled = true };
                replacement.persist(f.db);
                assert_false(ContactSubscriptionModel.same_account(f.first, replacement));
                f.update(replacement, f.contact, Roster.Item.SUBSCRIPTION_BOTH);
                assert_false(model.in_roster || model.receives_presence || model.connected);
                break;
            case 4:
                int changes = 0;
                model.changed.connect(() => { changes++; });
                model.deactivate();
                f.update(f.first, f.contact, Roster.Item.SUBSCRIPTION_BOTH);
                f.incoming(f.first, f.stream, f.contact);
                assert_true(changes == 0 && !model.in_roster && !model.incoming_pending);
                var weak_model = WeakRef(null);
                {
                    var temporary = new ContactSubscriptionModel(f.interactor, f.first, f.contact);
                    weak_model.set(temporary);
                }
                assert_true(weak_model.get() == null,
                    "Long-lived service signals must not retain a closed contact model");
                break;
            case 5:
                var cyrillic = new Jid("борис@example.test");
                var unicode_model = new ContactSubscriptionModel(f.interactor, f.first, cyrillic.with_resource("Планшет"));
                f.update(f.first, cyrillic, Roster.Item.SUBSCRIPTION_NONE, null, "Борис");
                assert_true(unicode_model.in_roster);
                fail_if_not_eq_str("борис@example.test", unicode_model.jid.to_string());
                var item = f.roster.get_roster_item(f.first, cyrillic);
                assert_true(item != null);
                if (item != null) fail_if_not_eq_str("Борис", item.name);
                f.incoming(f.first, f.stream, cyrillic.with_resource("Телефон"));
                assert_true(unicode_model.incoming_pending);
                unicode_model.deactivate();
                break;
        }
        model.deactivate();
    }

    private class Fixture {
        public string directory;
        public Database db;
        public StreamInteractor interactor;
        public RosterManager roster;
        public Account first;
        public Account second;
        public Jid contact;
        public ModelStream stream;
        public ModelStream other_stream;

        public Fixture() throws Error {
            directory = Path.build_filename(Environment.get_tmp_dir(), "dinox-contact-permissions-" + Uuid.string_random());
            DirUtils.create_with_parents(directory, 0700);
            db = new Database(Path.build_filename(directory, "dino.db"), "contact-permissions-test");
            interactor = new StreamInteractor.for_tests(db);
            RosterManager.start(interactor, db);
            PresenceManager.start(interactor);
            roster = interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            first = new Account(new Jid("first@example.test"), "secret") { enabled = true };
            second = new Account(new Jid("second@example.test"), "secret") { enabled = true };
            first.persist(db);
            second.persist(db);
            contact = new Jid("contact@example.test");
            interactor.module_manager.initialize(first);
            interactor.module_manager.initialize(second);
            interactor.account_added(first);
            interactor.account_added(second);
            stream = connect_model_stream(first);
            other_stream = connect_model_stream(second);
        }

        private ModelStream connect_model_stream(Account account) throws Error {
            var result = new ModelStream(new Jid("example.test"));
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid.with_resource("desktop");
            bind.finished = true;
            result.add_flag(bind);
            var presence = interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY);
            result.add_module(presence);
            presence.attach(result);
            result.negotiation_complete = true;
            interactor.connection_manager.set_connected_stream_for_tests(account, result);
            return result;
        }

        public void update(Account account, Jid jid, string subscription, string? ask = null, string? name = null, bool preapproved = false) {
            var item = new Roster.Item() { jid = jid, subscription = subscription, name = name };
            if (ask != null) item.stanza_node.set_attribute("ask", ask);
            if (preapproved) item.stanza_node.set_attribute("approved", "true");
            var store = roster.get_or_create_roster_store(account);
            var items = new ArrayList<Roster.Item>();
            foreach (Roster.Item existing in store.get_roster()) {
                if (!existing.jid.equals_bare(jid)) items.add(existing);
            }
            items.add(item);
            store.set_roster(items);
            roster.updated_roster_item(account, jid, item);
        }

        public void remove(Account account, Jid jid) {
            var store = roster.get_or_create_roster_store(account);
            store.set_roster(new ArrayList<Roster.Item>());
        }

        public void incoming(Account account, ModelStream source, Jid jid) {
            source.get_module<Presence.Module>(Presence.Module.IDENTITY).received_subscription_request(source, jid);
        }

        public void close() {
            db.close();
            string path = Path.build_filename(directory, "dino.db");
            FileUtils.remove(path);
            FileUtils.remove(path + "-wal");
            FileUtils.remove(path + "-shm");
            DirUtils.remove(directory);
        }
    }
}

private class ModelStream : XmppStream {
    public ModelStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }
    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError { }
}

}
