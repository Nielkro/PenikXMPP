using Gee;

namespace Xmpp.Test {

class PresenceAudit : Gee.TestCase {

    private const string ROOM = "room@conference.example.test";

    public PresenceAudit() {
        base("PresenceAudit");

        add_test("Resources_keep_latest_presence_without_duplicates", test_resources_keep_latest_presence_without_duplicates);
        add_test("Full_and_bare_removal_preserve_resource_isolation", test_full_and_bare_removal_preserve_resource_isolation);
        add_test("Large_room_resource_burst_remains_complete", test_large_room_resource_burst_remains_complete);
        add_test("RFC6121_preapproval_uses_only_the_advertised_stream_feature", test_preapproval_feature);
        add_async_test("Presence_async_write_waits_and_propagates_transport_errors", (cb) => {
            test_presence_async_write.begin(cb);
        });
    }

    private void test_resources_keep_latest_presence_without_duplicates() {
        try {
            var flag = new Presence.Flag();
            var phone = build_presence("alice@example.test/phone", Presence.Stanza.SHOW_ONLINE);
            var laptop = build_presence("alice@example.test/laptop", Presence.Stanza.SHOW_CHAT);
            flag.add_presence(phone);
            flag.add_presence(laptop);

            var updated_phone = build_presence("alice@example.test/phone", Presence.Stanza.SHOW_AWAY);
            flag.add_presence(updated_phone);

            Gee.List<Jid>? resources = flag.get_resources(new Jid("alice@example.test"));
            fail_if(resources == null, "Presence resources must exist for the contact bare JID");
            fail_if_not_eq_int(((!) resources).size, 2, "Repeated presence must not duplicate a full JID resource");

            Presence.Stanza? stored_phone = flag.get_presence(new Jid("alice@example.test/phone"));
            fail_if(stored_phone == null, "Latest full-JID presence must remain available");
            fail_if_not_eq_str(((!) stored_phone).show, Presence.Stanza.SHOW_AWAY,
                "Repeated presence must replace the stored stanza for its full JID");

            Set<Jid> available = flag.get_available_jids();
            fail_if_not_eq_int(available.size, 1, "One contact bare JID must create one available-JID bucket");
            foreach (Jid available_jid in available) {
                fail_if(available_jid.is_full(), "Available resource buckets must be keyed by bare JID");
            }

            resources.clear();
            Gee.List<Jid>? resources_after_external_clear = flag.get_resources(new Jid("alice@example.test"));
            fail_if(resources_after_external_clear == null,
                "Mutating a resource snapshot must not change flag-owned resource state");
            fail_if_not_eq_int(((!) resources_after_external_clear).size, 2,
                "Resource snapshots must be defensive copies");

            available.clear();
            fail_if_not_eq_int(flag.get_available_jids().size, 1,
                "Mutating an available-JID snapshot must not change flag-owned map state");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in presence resource replacement test: $(e.message)");
        }
    }

    private void test_full_and_bare_removal_preserve_resource_isolation() {
        try {
            var flag = new Presence.Flag();
            Jid alice_phone = new Jid("alice@example.test/phone");
            Jid alice_laptop = new Jid("alice@example.test/laptop");
            Jid bob_desktop = new Jid("bob@example.test/desktop");
            flag.add_presence(build_presence(alice_phone.to_string(), Presence.Stanza.SHOW_ONLINE));
            flag.add_presence(build_presence(alice_laptop.to_string(), Presence.Stanza.SHOW_AWAY));
            flag.add_presence(build_presence(bob_desktop.to_string(), Presence.Stanza.SHOW_CHAT));

            flag.remove_presence(alice_phone);

            Gee.List<Jid>? alice_resources = flag.get_resources(alice_phone.bare_jid);
            fail_if(alice_resources == null, "Removing one full JID must keep sibling resources");
            fail_if_not_eq_int(((!) alice_resources).size, 1, "Only the selected full JID resource may be removed");
            fail_if(((!) alice_resources)[0].equals(alice_phone), "Removed resource must not remain in the bare-JID bucket");
            fail_if(flag.get_presence(alice_phone) != null, "Removed full-JID presence must be cleared");
            fail_if(flag.get_presence(alice_laptop) == null, "Sibling full-JID presence must remain available");
            fail_if(flag.get_presence(bob_desktop) == null, "A different bare JID must remain isolated");

            flag.remove_presence(alice_laptop.bare_jid);

            fail_if(flag.get_resources(alice_laptop.bare_jid) != null, "Bare-JID removal must clear its resource bucket");
            fail_if(flag.get_presence(alice_laptop) != null, "Bare-JID removal must clear all stored child presences");
            Gee.List<Jid>? bob_resources = flag.get_resources(bob_desktop.bare_jid);
            fail_if(bob_resources == null, "Bare-JID removal must not affect another contact");
            fail_if_not_eq_int(((!) bob_resources).size, 1, "Unrelated resource bucket must remain unchanged");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in presence resource removal test: $(e.message)");
        }
    }

    private void test_large_room_resource_burst_remains_complete() {
        try {
            var flag = new Presence.Flag();
            const int OCCUPANT_COUNT = 4096;

            for (int i = 0; i < OCCUPANT_COUNT; i++) {
                flag.add_presence(build_presence("%s/occupant-%d".printf(ROOM, i), Presence.Stanza.SHOW_ONLINE));
            }

            Gee.List<Jid>? occupants = flag.get_resources(new Jid(ROOM));
            fail_if(occupants == null, "Large MUC resource bucket must be available");
            fail_if_not_eq_int(((!) occupants).size, OCCUPANT_COUNT,
                "Large MUC presence burst must retain every unique occupant exactly once");

            var unique_occupants = new Gee.HashSet<Jid>(Jid.hash_func, Jid.equals_func);
            unique_occupants.add_all((!) occupants);
            fail_if_not_eq_int(unique_occupants.size, OCCUPANT_COUNT,
                "Large MUC resource snapshot must not contain duplicate full JIDs");

            Jid updated_occupant = new Jid("%s/occupant-2048".printf(ROOM));
            flag.add_presence(build_presence(updated_occupant.to_string(), Presence.Stanza.SHOW_DND));
            Gee.List<Jid>? occupants_after_update = flag.get_resources(new Jid(ROOM));
            fail_if(occupants_after_update == null, "Large MUC resource bucket must survive an occupant update");
            fail_if_not_eq_int(((!) occupants_after_update).size, OCCUPANT_COUNT,
                "Updating one large-MUC occupant must not change the resource count");
            Presence.Stanza? stored_update = flag.get_presence(updated_occupant);
            fail_if(stored_update == null, "Updated large-MUC occupant presence must remain stored");
            fail_if_not_eq_str(((!) stored_update).show, Presence.Stanza.SHOW_DND,
                "Large-MUC occupant update must replace the stored presence stanza");
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in large MUC presence resource test: $(e.message)");
        }
    }

    private Presence.Stanza build_presence(string from, string show) throws Error {
        var presence = new Presence.Stanza();
        presence.from = new Jid(from);
        presence.show = show;
        return presence;
    }

    private void test_preapproval_feature() {
        try {
            var stream = new SubscriptionPresenceTestStream(new Jid("example.test"));
            var module = new Presence.Module();
            fail_if(module.supports_subscription_preapproval(stream));
            stream.features.put_node(new StanzaNode.build("sub", "wrong:namespace"));
            fail_if(module.supports_subscription_preapproval(stream));
            stream.features.put_node(new StanzaNode.build("sub", "urn:xmpp:features:pre-approval"));
            fail_if_not(module.supports_subscription_preapproval(stream));
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private async void test_presence_async_write(Gee.TestFinishedCallback cb) {
        try {
            var stream = new SubscriptionPresenceTestStream(new Jid("example.test"));
            var module = new Presence.Module();
            int hooks = 0;
            module.pre_send_presence_stanza.connect((source, stanza) => hooks++);
            var request = new Presence.Stanza() {
                to = new Jid("contact@example.test"), type_ = Presence.Stanza.TYPE_SUBSCRIBE
            };
            bool completed = false;
            string? error = null;
            stream.hold_write = true;
            module.send_presence_async.begin(stream, request, (_, res) => {
                try { module.send_presence_async.end(res); }
                catch (Error e) { error = e.message; }
                completed = true;
            });
            fail_if(completed, "An awaited presence send must not finish before its transport write");
            fail_if(hooks != 1, "The existing pre-send hook must also run for awaited writes");
            stream.release_write();
            for (int i = 0; i < 4 && !completed; i++) {
                Idle.add(test_presence_async_write.callback);
                yield;
            }
            fail_if_not(completed, "Releasing the transport write must finish the awaited send");
            fail_if(error != null, error ?? "");
            stream.hold_write = false;
            stream.fail_write = true;
            bool failed = false;
            try { yield module.send_presence_async(stream, request); }
            catch (IOError.FAILED e) { failed = true; }
            fail_if_not(failed, "Awaited presence actions must propagate a failed transport write");
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }
}

private class SubscriptionPresenceTestStream : XmppStream {
    internal bool hold_write = false;
    internal bool fail_write = false;
    private SourceFunc? held_write;

    internal SubscriptionPresenceTestStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated subscription presence stream");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (fail_write) throw new IOError.FAILED("isolated transport write failed");
        if (hold_write) {
            held_write = write_async.callback;
            yield;
        }
    }
    internal void release_write() {
        if (held_write != null) Idle.add((owned) held_write);
    }
}

}
