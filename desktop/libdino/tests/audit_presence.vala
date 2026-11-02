using Gee;
using Xmpp;

namespace Dino.Test {

class PresenceAudit : Gee.TestCase {

    public PresenceAudit() {
        base("PresenceAudit");
        add_test("Subscription_request_from_full_jid_is_pending_for_bare_jid", test_full_jid_subscription_request_is_bare_pending);
        add_test("Keyed_observers_route_only_matching_account_and_JID", test_keyed_observer_routing);
        add_test("Mutual_presence_preapproval_requires_advertised_feature", () => run_subscription_case(0));
        add_test("Mutual_presence_without_preapproval_requires_later_manual_grant", () => run_subscription_case(1));
        add_test("Mutual_presence_never_grants_without_explicit_consent", () => run_subscription_case(2));
        add_test("Mutual_presence_approves_only_matching_pending_account_and_bare_jid", () => run_subscription_case(3));
        add_test("Mutual_presence_respects_to_from_both_and_pending_out", () => run_subscription_case(4));
        add_test("Subscription_actions_reject_offline_disabled_recreated_and_wrong_binding", () => run_subscription_case(5));
        add_test("Subscription_write_failure_and_stream_replacement_preserve_pending", () => run_subscription_case(6));
        add_test("Pending_subscription_changes_follow_withdrawal_and_confirmed_roster_grants", () => run_subscription_case(7));
        add_test("Roster_add_waits_for_IQ_result_and_never_sets_subscription_locally", () => run_subscription_case(8));
        add_test("Subscription_denial_waits_for_write_and_preserves_preauth", () => run_subscription_case(9));
    }

    private void test_keyed_observer_routing() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-presence-observer-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;

        try {
            cleanup_presence_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "presence-observer-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.PresenceManager.start(stream_interactor);

            var first_account = new Dino.Entities.Account(new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Dino.Entities.Account(new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            stream_interactor.module_manager.initialize(first_account);
            stream_interactor.account_added(first_account);

            PresenceManager manager = (!) stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            Jid contact = new Jid("contact@example.test");
            Jid room = new Jid("room@conference.example.test");
            int contact_events = 0;
            int room_events = 0;
            int other_account_events = 0;
            int one_shot_events = 0;
            PresenceObserver contact_observer = manager.observe_presence(first_account, contact, (jid, account, available) => {
                contact_events++;
                return true;
            });
            PresenceObserver room_observer = manager.observe_presence(first_account, room, (jid, account, available) => {
                room_events++;
                return true;
            });
            PresenceObserver other_observer = manager.observe_presence(second_account, contact, (jid, account, available) => {
                other_account_events++;
                return true;
            });
            manager.observe_presence(first_account, new Jid("one-shot@example.test"), (jid, account, available) => {
                one_shot_events++;
                return false;
            });

            var presence_module = (!) stream_interactor.module_manager.get_module<Presence.Module>(first_account, Presence.Module.IDENTITY);
            var stream = new PresenceAuditStream(new Jid("example.test"));
            var occupant_presence = new Presence.Stanza() { from=room.with_resource("nick") };
            presence_module.received_available(stream, occupant_presence);
            fail_if(room_events != 1 || contact_events != 0 || other_account_events != 0,
                "A MUC occupant presence must reach only the matching account/room observer");

            var contact_presence = new Presence.Stanza() { from=contact.with_resource("device") };
            presence_module.received_available(stream, contact_presence);
            fail_if(contact_events != 1 || room_events != 1 || other_account_events != 0,
                "A contact resource presence must reach only its matching account/contact observer");

            var one_shot_presence = new Presence.Stanza() { from=new Jid("one-shot@example.test/device") };
            presence_module.received_available(stream, one_shot_presence);
            presence_module.received_available(stream, one_shot_presence);
            fail_if(one_shot_events != 1, "An observer returning false must remove itself after one dispatch");

            contact_observer.unsubscribe();
            presence_module.received_unavailable(stream, contact_presence);
            fail_if(contact_events != 1, "Unsubscribed presence observers must receive no later events");

            room_observer.unsubscribe();
            other_observer.unsubscribe();
        } catch (Error e) {
            fail_if_reached(@"Unexpected keyed presence observer error: $(e.message)");
        } finally {
            cleanup_presence_test_dir(temp_dir, db_path);
        }
    }

    private void test_full_jid_subscription_request_is_bare_pending() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-presence-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;

        try {
            cleanup_presence_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "presence-subscription-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.PresenceManager.start(stream_interactor);

            var account = new Dino.Entities.Account(new Jid("alice@example.test"), "secret") { enabled = true };
            account.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            PresenceManager presence_manager = (!) stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            Jid? emitted_jid = null;
            presence_manager.received_subscription_request.connect((jid, received_account) => {
                if (received_account.equals(account)) {
                    emitted_jid = jid;
                }
            });

            var presence_module = (!) stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY);
            var stream = create_subscription_stream(stream_interactor, account);
            presence_module.received_subscription_request(stream, new Jid("bob@example.test/DinoX"));

            fail_if(emitted_jid == null, "PresenceManager must emit received_subscription_request");
            fail_if(((!) emitted_jid).is_full(), "PresenceManager must emit a bare JID for subscription requests");
            fail_if_not(((!) emitted_jid).equals_bare(new Jid("bob@example.test")), "PresenceManager must preserve the contact bare JID");
            fail_if_not(presence_manager.exists_subscription_request(account, new Jid("bob@example.test")),
                "Full-JID subscribe must be visible as a pending request for the bare conversation");
            fail_if_not(presence_manager.exists_subscription_request(account, new Jid("bob@example.test/Other")),
                "Pending lookup must normalize the queried contact JID to bare JID");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in presence subscription audit: $(e.message)");
        } finally {
            cleanup_presence_test_dir(temp_dir, db_path);
        }
    }

    private void cleanup_presence_test_dir(string temp_dir, string db_path) {
        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-shm");
        FileUtils.remove(db_path + "-wal");
        DirUtils.remove(temp_dir);
    }

    private class SubscriptionFixture : Object {
        internal string directory;
        internal Dino.Database db;
        internal StreamInteractor interactor;
        internal Dino.Entities.Account first;
        internal Dino.Entities.Account second;
        internal PresenceAuditStream stream;
        internal PresenceAuditStream other_stream;
        internal PresenceManager manager;
        internal RosterManager roster;
        internal Jid contact;

        internal SubscriptionFixture() throws Error {
            directory = DirUtils.make_tmp("dinox-subscription-actions-XXXXXX");
            db = new Dino.Database(Path.build_filename(directory, "dino.db"), "subscription-action-test");
            interactor = new StreamInteractor.for_tests(db);
            RosterManager.start(interactor, db);
            PresenceManager.start(interactor);
            first = new Dino.Entities.Account(new Jid("first@example.test"), "secret") { enabled = true };
            second = new Dino.Entities.Account(new Jid("second@example.test"), "secret") { enabled = true };
            first.persist(db);
            second.persist(db);
            interactor.module_manager.initialize(first);
            interactor.module_manager.initialize(second);
            interactor.account_added(first);
            interactor.account_added(second);
            stream = create_subscription_stream(interactor, first);
            other_stream = create_subscription_stream(interactor, second);
            manager = interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            roster = interactor.get_module<RosterManager>(RosterManager.IDENTITY);
            contact = new Jid("contact@example.test/phone");
        }

        internal void incoming(Dino.Entities.Account account, PresenceAuditStream source) {
            source.get_module<Presence.Module>(Presence.Module.IDENTITY)
                .received_subscription_request(source, contact);
        }

        internal void close() {
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            other_stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(other_stream);
            db.close();
            FileUtils.remove(Path.build_filename(directory, "dino.db"));
            FileUtils.remove(Path.build_filename(directory, "dino.db-wal"));
            FileUtils.remove(Path.build_filename(directory, "dino.db-shm"));
            DirUtils.remove(directory);
        }
    }

    private static PresenceAuditStream create_subscription_stream(
            StreamInteractor interactor, Dino.Entities.Account account) throws Error {
        var stream = new PresenceAuditStream(new Jid("example.test"));
        var bind = new Bind.Flag();
        bind.my_jid = account.bare_jid.with_resource("desktop");
        bind.finished = true;
        stream.add_flag(bind);
        var iq = interactor.module_manager.get_module<Iq.Module>(account, Iq.Module.IDENTITY);
        var presence = interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY);
        var roster = interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY);
        stream.add_module(iq);
        stream.add_module(presence);
        stream.add_module(roster);
        iq.attach(stream);
        presence.attach(stream);
        roster.attach(stream);
        stream.negotiation_complete = true;
        interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        return stream;
    }

    private void run_subscription_case(int scenario) {
        SubscriptionFixture? fixture = null;
        try {
            fixture = new SubscriptionFixture();
            var loop = new MainLoop();
            bool done = false;
            string? failure = null;
            exercise_subscription.begin((!) fixture, scenario, (_, res) => {
                try { exercise_subscription.end(res); }
                catch (Error e) { failure = e.message; }
                done = true;
                loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "Subscription wire test timed out";
                loop.quit();
                return Source.REMOVE;
            }, Priority.LOW);
            if (!done) loop.run();
            if (timeout != 0) Source.remove(timeout);
            fail_if_not(done, "The subscription action must settle");
            fail_if(failure != null, failure ?? "");
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private async void exercise_subscription(SubscriptionFixture fixture,
            int scenario) throws Error {
        switch (scenario) {
            case 0:
                fixture.stream.features.put_node(new StanzaNode.build("sub", "wrong:namespace"));
                fail_if(fixture.manager.supports_subscription_preapproval(fixture.first),
                    "A same-named feature in another namespace must not enable pre-approval");
                fixture.stream.features.put_node(new StanzaNode.build("sub", "urn:xmpp:features:pre-approval"));
                fail_if_not(fixture.manager.supports_subscription_preapproval(fixture.first));
                var preapproved = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true);
                fail_if(preapproved != MutualSubscriptionResult.PREAPPROVED);
                assert_presence_types(fixture.stream, { "subscribed", "subscribe" }, fixture.contact);
                fail_if(fixture.roster.get_roster_item(fixture.first, fixture.contact) != null,
                    "Pre-approval writes must never invent a local roster subscription");
                break;
            case 1:
                var manual = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true);
                fail_if(manual != MutualSubscriptionResult.MANUAL_APPROVAL_REQUIRED);
                assert_presence_types(fixture.stream, { "subscribe" }, fixture.contact);
                break;
            case 2:
                fixture.stream.features.put_node(new StanzaNode.build("sub", "urn:xmpp:features:pre-approval"));
                fixture.incoming(fixture.first, fixture.stream);
                var requested = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, false);
                fail_if(requested != MutualSubscriptionResult.REQUESTED);
                assert_presence_types(fixture.stream, { "subscribe" }, fixture.contact);
                fail_if_not(fixture.manager.exists_subscription_request(fixture.first, fixture.contact),
                    "A request-only action must not accept the contact's incoming request");
                break;
            case 3:
                fixture.incoming(fixture.first, fixture.stream);
                fixture.incoming(fixture.second, fixture.other_stream);
                var approved = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true);
                fail_if(approved != MutualSubscriptionResult.PENDING_APPROVED);
                assert_presence_types(fixture.stream, { "subscribed", "subscribe" }, fixture.contact);
                fail_if(fixture.manager.exists_subscription_request(fixture.first, fixture.contact));
                fail_if_not(fixture.manager.exists_subscription_request(fixture.second, fixture.contact));
                fail_if(fixture.other_stream.writes.size != 0, "Another account must receive no approval/request writes");
                break;
            case 4:
                foreach (string state in new string[] { Roster.Item.SUBSCRIPTION_TO,
                        Roster.Item.SUBSCRIPTION_FROM, Roster.Item.SUBSCRIPTION_BOTH,
                        Roster.Item.SUBSCRIPTION_NONE }) {
                    fixture.stream.writes.clear();
                    var item = new Roster.Item() { jid = fixture.contact.bare_jid, subscription = state };
                    if (state == Roster.Item.SUBSCRIPTION_NONE) item.stanza_node.put_attribute("ask", "subscribe");
                    fixture.stream.get_flag<Roster.Flag>(Roster.Flag.IDENTITY).roster_items[fixture.contact.bare_jid] = item;
                    var result = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true);
                    if (state == Roster.Item.SUBSCRIPTION_FROM) {
                        fail_if(result != MutualSubscriptionResult.ALREADY_GRANTED);
                        assert_presence_types(fixture.stream, { "subscribe" }, fixture.contact);
                    } else {
                        fail_if(fixture.stream.writes.size != 0,
                            "TO/BOTH/pending-out must not blindly send another subscription request");
                        fail_if(result != (state == Roster.Item.SUBSCRIPTION_BOTH
                            ? MutualSubscriptionResult.ALREADY_GRANTED : MutualSubscriptionResult.MANUAL_APPROVAL_REQUIRED));
                    }
                }
                fixture.stream.writes.clear();
                var already_preapproved = new Roster.Item() {
                    jid = fixture.contact.bare_jid, subscription = Roster.Item.SUBSCRIPTION_NONE
                };
                already_preapproved.stanza_node.put_attribute("approved", "true");
                fixture.stream.get_flag<Roster.Flag>(Roster.Flag.IDENTITY).roster_items[fixture.contact.bare_jid] = already_preapproved;
                var existing_approval = yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true);
                fail_if(existing_approval != MutualSubscriptionResult.PREAPPROVED,
                    "A confirmed server pre-approval remains distinct from active FROM/BOTH");
                assert_presence_types(fixture.stream, { "subscribe" }, fixture.contact);
                fail_if(already_preapproved.subscription != Roster.Item.SUBSCRIPTION_NONE);
                break;
            case 5:
                var recreated = new Dino.Entities.Account(fixture.first.bare_jid, "secret") {
                    enabled = true, id = fixture.first.id + 100
                };
                yield expect_subscription_unavailable(fixture, recreated);
                fixture.first.enabled = false;
                yield expect_subscription_unavailable(fixture, fixture.first);
                fixture.first.enabled = true;
                fixture.stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY).my_jid = fixture.second.bare_jid;
                yield expect_subscription_unavailable(fixture, fixture.first);
                fixture.stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY).my_jid = fixture.first.full_jid;
                fixture.interactor.connection_manager.set_connection_state_for_tests(fixture.first, ConnectionManager.ConnectionState.DISCONNECTED);
                yield expect_subscription_unavailable(fixture, fixture.first);
                fail_if(fixture.stream.writes.size != 0, "Unavailable/stale account actions must send no stanza");
                break;
            case 6:
                fixture.incoming(fixture.first, fixture.stream);
                fixture.stream.fail_presence_write = true;
                bool failed = false;
                try { yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true); }
                catch (IOError e) { failed = true; }
                fail_if_not(failed);
                fail_if_not(fixture.manager.exists_subscription_request(fixture.first, fixture.contact),
                    "A failed approval write must retain the incoming request");
                fixture.stream.fail_presence_write = false;
                fixture.stream.before_presence_result.connect(() => {
                    fixture.interactor.connection_manager.set_connection_state_for_tests(fixture.first, ConnectionManager.ConnectionState.DISCONNECTED);
                });
                failed = false;
                try { yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, true); }
                catch (IOError.NOT_CONNECTED e) { failed = true; }
                fail_if_not(failed, "A connection loss between writes must be reported");
                fail_if_not(fixture.manager.exists_subscription_request(fixture.first, fixture.contact));
                assert_presence_types(fixture.stream, { "subscribed" }, fixture.contact);
                break;
            case 7:
                int changed = 0;
                fixture.manager.subscription_requests_changed.connect((jid, account) => {
                    if (account.id == fixture.first.id && jid.equals_bare(fixture.contact)) changed++;
                });
                fixture.incoming(fixture.first, fixture.stream);
                fixture.incoming(fixture.first, fixture.stream);
                fail_if(changed != 1, "Duplicate incoming presence must not invent another pending-state transition");
                fixture.stream.get_module<Presence.Module>(Presence.Module.IDENTITY).received_unsubscription(fixture.stream, fixture.contact);
                fail_if(changed != 2 || fixture.manager.exists_subscription_request(fixture.first, fixture.contact));
                fixture.incoming(fixture.first, fixture.stream);
                var granted = new Roster.Item() { jid = fixture.contact.bare_jid, subscription = Roster.Item.SUBSCRIPTION_FROM };
                fixture.stream.get_module<Roster.Module>(Roster.Module.IDENTITY).item_updated(fixture.stream, granted,
                    new Iq.Stanza.set(new StanzaNode.build("query", "jabber:iq:roster")));
                fail_if(changed != 4 || fixture.manager.exists_subscription_request(fixture.first, fixture.contact),
                    "A server-confirmed grant on another own client must clear pending state");
                yield fixture.manager.deny_subscription_async(fixture.first, fixture.contact);
                fail_if(fixture.stream.writes.size != 0,
                    "A stale notification denial must not revoke the confirmed grant");
                break;
            case 8:
                bool added = yield fixture.roster.add_jid_async(fixture.first, fixture.contact, "Contact");
                fail_if_not(added);
                fail_if(fixture.stream.writes.size != 1 || fixture.stream.writes[0].name != "iq");
                StanzaNode? sent_item = fixture.stream.writes[0].get_subnode("query", "jabber:iq:roster").get_subnode("item", "jabber:iq:roster");
                fail_if(sent_item == null || ((!) sent_item).get_attribute("jid") != fixture.contact.bare_jid.to_string());
                fail_if(((!) sent_item).get_attribute("subscription") != null || ((!) sent_item).get_attribute("approved") != null,
                    "Roster add must not pretend to grant subscription/pre-approval");
                fixture.stream.reject_roster_set = true;
                added = yield fixture.roster.add_jid_async(fixture.first, fixture.contact, "Contact");
                fail_if(added, "A server IQ error must be reported as rejected roster add");
                fixture.first.enabled = false;
                bool unavailable = false;
                try { yield fixture.roster.add_jid_async(fixture.first, fixture.contact, null); }
                catch (IOError.NOT_CONNECTED e) { unavailable = true; }
                fail_if_not(unavailable, "A disabled roster add must fail explicitly");
                fail_if(fixture.stream.writes.size != 2);
                break;
            case 9:
                fixture.incoming(fixture.first, fixture.stream);
                fixture.stream.fail_presence_write = true;
                bool denied = false;
                try { yield fixture.manager.deny_subscription_async(fixture.first, fixture.contact); denied = true; }
                catch (IOError e) { }
                fail_if(denied || !fixture.manager.exists_subscription_request(fixture.first, fixture.contact));
                fixture.stream.fail_presence_write = false;
                yield fixture.manager.deny_subscription_async(fixture.first, fixture.contact);
                fail_if(fixture.manager.exists_subscription_request(fixture.first, fixture.contact));
                assert_presence_types(fixture.stream, { "unsubscribed" }, fixture.contact);
                fixture.stream.writes.clear();
                yield fixture.manager.request_mutual_subscription(fixture.first, fixture.contact, false, "explicit-contact-token");
                assert_presence_types(fixture.stream, { "subscribe" }, fixture.contact);
                StanzaNode? preauth = fixture.stream.writes[0].get_subnode("preauth", Xep.InBandRegistration.NS_URI_PARS);
                fail_if(preauth == null || ((!) preauth).get_attribute("token") != "explicit-contact-token");
                break;
        }
    }

    private async void expect_subscription_unavailable(SubscriptionFixture fixture,
            Dino.Entities.Account account) throws Error {
        bool unavailable = false;
        try { yield fixture.manager.request_mutual_subscription(account, fixture.contact, true); }
        catch (IOError.NOT_CONNECTED e) { unavailable = true; }
        fail_if_not(unavailable, "Unavailable/recreated/binding-mismatched subscription actions must fail explicitly");
    }

    private void assert_presence_types(PresenceAuditStream stream,
            string[] types, Jid recipient) {
        fail_if(stream.writes.size != types.length, "The action must send only its deliberate presence stanzas");
        for (int i = 0; i < types.length && i < stream.writes.size; i++) {
            fail_if(stream.writes[i].name != "presence" || stream.writes[i].get_attribute("type") != types[i]);
            fail_if(stream.writes[i].get_attribute("to") != recipient.bare_jid.to_string(),
                "Subscription writes must address the selected account's contact bare JID");
        }
    }
}

private class PresenceAuditStream : XmppStream {
    internal ArrayList<StanzaNode> writes = new ArrayList<StanzaNode>();
    internal bool fail_presence_write = false;
    internal bool reject_roster_set = false;
    internal signal void before_presence_result();
    public PresenceAuditStream(Jid remote_name) {
        base(remote_name);
    }

    public override async void connect() throws IOError {
    }

    public override async void disconnect() throws IOError {
    }

    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("test stream has no reader");
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name == "presence" && fail_presence_write) throw new IOError.FAILED("isolated presence write failed");
        writes.add(node);
        if (node.name == "presence") before_presence_result();
        if (node.name == "iq") {
            string? request_id = node.get_attribute("id");
            var result = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("id", request_id)
                .put_attribute("type", reject_roster_set ? "error" : "result");
            if (reject_roster_set) result.put_node(new StanzaNode.build("error", "jabber:client")
                .put_attribute("type", "cancel")
                .put_node(new StanzaNode.build("forbidden", "urn:ietf:params:xml:ns:xmpp-stanzas")));
            Idle.add(() => {
                received_iq_stanza(this, result);
                return Source.REMOVE;
            });
        }
    }

    public override async void setup() throws IOError {
    }
}

}
