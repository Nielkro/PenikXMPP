using Dino.Plugins.Omemo;
using Xmpp;

namespace Omemo.Test {

class LegacyRegistrationPubSubTest : Gee.TestCase {
    private const string NS_OMEMO = "eu.siacs.conversations.axolotl";
    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_PUBSUB_OWNER = "http://jabber.org/protocol/pubsub#owner";

    public LegacyRegistrationPubSubTest() {
        base("LegacyRegistrationPubSub");
        add_test("collision_is_checked_before_any_publish_and_uses_new_id", test_collision);
        add_test("confirmed_missing_bundle_preserves_other_list_entry", test_missing);
        add_test("interrupted_same_identity_publication_preserves_id", test_same_identity);
        add_test("bundle_lookup_error_does_not_publish_or_rotate", test_lookup_error);
        add_test("registration_stays_pending_until_bundle_acknowledgement", test_pending_ack);
        add_test("fresh_empty_list_publishes_after_candidate_check_and_waits_for_ack", test_fresh_empty_list);
        add_test("replacement_id_with_orphan_bundle_is_checked_again", test_orphan_replacement);
        add_test("pending_probe_preserves_latest_list_and_device_labels", test_latest_list);
        add_test("candidate_listed_during_probe_is_not_claimed", test_candidate_listed_during_probe);
        add_test("due_watchdog_allows_acknowledged_iq_followups_but_stops_without_reply", test_due_watchdog);
        add_test("metadata_bundle_lookup_does_not_request_session", test_metadata_demand);
        add_test("outgoing_bundle_lookup_requests_session", test_outgoing_demand);
        add_test("outgoing_send_upgrades_inflight_metadata_lookup", test_upgraded_demand);
        add_test("actual_jingle_send_waits_for_its_first_native_session", test_awaited_send);
        add_test("cancelled_jingle_send_leaves_late_response_metadata_only", test_cancelled_send);
        add_test("first_contact_metadata_wait_does_not_create_a_session", test_metadata_wait);
        add_test("device_list_error_is_distinct_from_empty_and_can_be_retried", () => test_device_list_result(0));
        add_test("confirmed_missing_device_list_is_loaded_not_failed", () => test_device_list_result(1));
        add_test("detached_device_list_error_does_not_fail_current_sends", () => test_device_list_result(2));
    }

    private void test_device_list_result(int mode) {
        StreamModule? module = null;
        RegistrationTestStream? stream = null;
        uint timeout = 0;
        try {
            var own = new Jid("alice@example.test/dinox");
            var peer = new Jid("bob@example.test");
            Store store = setup_test_store_context(Plugin.get_context());
            var test_stream = new RegistrationTestStream(new Jid("example.test"));
            stream = test_stream;
            var bind = new Bind.Flag();
            bind.my_jid = own;
            test_stream.add_flag(bind);
            test_stream.negotiation_complete = true;
            test_stream.add_module(new Iq.Module());
            test_stream.add_module(new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Device List Test"));
            test_stream.add_module(new MessageModule());
            test_stream.add_module(new Xmpp.Xep.Pubsub.Module());
            var test_module = new StreamModule(store);
            module = test_module;
            test_module.auto_publish_own_device_list = false;
            test_stream.add_module(test_module);
            int requests = 0;
            int failures = 0;
            int loaded = 0;
            test_module.device_list_fetch_failed.connect((jid, result) => {
                fail_if_not(jid.equals_bare(peer));
                fail_if_not(result.is_access_denied());
                fail_if_not(result.presence_subscription_required);
                failures++;
            });
            test_module.device_list_loaded.connect((jid, devices) => {
                fail_if_not(jid.equals_bare(peer));
                loaded++;
            });
            test_stream.wrote_node.connect((outgoing) => {
                if (get_child_node(outgoing, "items") != NS_OMEMO + ".devicelist") return;
                int attempt = ++requests;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    Iq.Stanza result;
                    if (attempt == 1) {
                        var error = mode == 1 ? new ErrorStanza.item_not_found()
                            : new ErrorStanza.build(ErrorStanza.TYPE_AUTH,
                                ErrorStanza.CONDITION_NOT_AUTHORIZED, null,
                                new StanzaNode.build("presence-subscription-required",
                                    "http://jabber.org/protocol/pubsub#errors"));
                        // Exercise servers that put diagnostic text before
                        // the standardized condition (RFC 6120).
                        if (mode != 1) error.error_node.sub_nodes.insert(0,
                            new StanzaNode.build("text", "urn:ietf:params:xml:ns:xmpp-stanzas")
                                .put_node(new StanzaNode.text("Access requires authorization")));
                        result = new Iq.Stanza.error(request, error);
                    } else {
                        var list = new StanzaNode.build("list", NS_OMEMO)
                            .put_node(new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "4242"));
                        var items = new StanzaNode.build("items", NS_PUBSUB)
                            .put_attribute("node", NS_OMEMO + ".devicelist")
                            .put_node(new StanzaNode.build("item", NS_PUBSUB)
                                .put_attribute("id", "current").put_node(list));
                        result = new Iq.Stanza.result(request,
                            new StanzaNode.build("pubsub", NS_PUBSUB).put_node(items));
                    }
                    result.from = peer;
                    result.to = own;
                    if (mode == 2) test_module.detach(test_stream);
                    test_stream.emit_iq_result(result.stanza);
                    return Source.REMOVE;
                });
            });
            var loop = new MainLoop();
            timeout = Timeout.add(3000, () => {
                timeout = 0;
                fail_if_reached("device-list query did not finish");
                loop.quit();
                return Source.REMOVE;
            });
            if (mode != 1) {
                GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Failed to request pubsub items*not-authorized*");
                if (mode == 0) GLib.Test.expect_message("OMEMO", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*device-list request failed*not-authorized*");
            }
            bool completed = false;
            test_module.request_user_devicelist.begin(test_stream, peer, (obj, res) => {
                var devices = test_module.request_user_devicelist.end(res);
                fail_if_not_eq_int(devices.size, 0);
                completed = true;
                loop.quit();
            });
            if (!completed) loop.run();
            if (mode != 1) GLib.Test.assert_expected_messages();
            fail_if_not(completed);
            fail_if_not_eq_int(failures, mode == 0 ? 1 : 0);
            fail_if_not_eq_int(loaded, mode == 1 ? 1 : 0,
                "failed or detached queries must not announce an empty device list");
            drain_ready_callbacks();
            if (mode == 0) {
                completed = false;
                test_module.request_user_devicelist.begin(test_stream, peer, (obj, res) => {
                    var devices = test_module.request_user_devicelist.end(res);
                    fail_if_not_eq_int(devices.size, 1);
                    fail_if_not_eq_int(devices[0], 4242);
                    completed = true;
                    loop.quit();
                });
                if (!completed) loop.run();
                fail_if_not(completed);
                fail_if_not_eq_int(requests, 2, "a failed query must release its coalesced future for a new request");
                fail_if_not_eq_int(loaded, 1);
                fail_if_not_eq_int(failures, 1);
            }
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (timeout != 0) Source.remove(timeout);
            if (module != null && stream != null) {
                drain_ready_callbacks();
                module.detach(stream);
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
                drain_ready_callbacks();
            }
        }
    }

    private enum LookupMode { OTHER_IDENTITY, MISSING, SAME_IDENTITY, ERROR }

    private void test_collision() { run_registration(LookupMode.OTHER_IDENTITY); }
    private void test_missing() { run_registration(LookupMode.MISSING); }
    private void test_same_identity() { run_registration(LookupMode.SAME_IDENTITY); }
    private void test_metadata_demand() { run_bundle_demand(false, false); }
    private void test_outgoing_demand() { run_bundle_demand(true, false); }
    private void test_upgraded_demand() { run_bundle_demand(false, true); }
    private void test_awaited_send() { run_bundle_demand(false, false, true, false); }
    private void test_cancelled_send() { run_bundle_demand(false, false, true, true); }
    private void test_metadata_wait() { run_bundle_demand(false, false, true, false, true); }

    private void run_bundle_demand(bool initial_send, bool upgrade,
            bool await_send = false, bool cancel_send = false, bool metadata_only = false) {
        StreamModule? module = null;
        RegistrationTestStream? stream = null;
        uint timeout = 0;
        try {
            var own = new Jid("alice@example.test/dinox");
            var peer = new Jid("bob@example.test");
            Context context = Plugin.get_context();
            Store store = setup_test_store_context(context);
            stream = new RegistrationTestStream(new Jid("example.test"));
            var bind = new Bind.Flag();
            bind.my_jid = own;
            stream.add_flag(bind);
            stream.negotiation_complete = true;
            stream.add_module(new Iq.Module());
            stream.add_module(new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                    Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                    Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Bundle Demand Test"));
            stream.add_module(new MessageModule());
            stream.add_module(new Xmpp.Xep.Pubsub.Module());
            module = new StreamModule(store);
            stream.add_module(module);
            var loop = new MainLoop();
            int requests = 0;
            int callbacks = 0;
            bool received_demand = false;
            bool preparation_completed = false;
            bool preparation_ready = false;
            var cancellable = new Cancellable();
            StanzaNode payload = valid_peer_bundle(context);
            RegistrationTestStream test_stream = stream;
            ulong wrote = stream.wrote_node.connect((outgoing) => {
                if (get_child_node(outgoing, "items") != NS_OMEMO + ".bundles:4242") return;
                requests++;
                Idle.add(() => {
                    var request = new Iq.Stanza.from_stanza(outgoing, own);
                    var items = new StanzaNode.build("items", NS_PUBSUB)
                            .put_attribute("node", NS_OMEMO + ".bundles:4242")
                            .put_node(new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "current").put_node(payload));
                    var result = new Iq.Stanza.result(request,
                            new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns().put_node(items));
                    result.from = peer;
                    result.to = own;
                    test_stream.emit_iq_result(result.stanza);
                    return Source.REMOVE;
                });
            });
            ulong ready = module.bundle_ready.connect((jid, device_id, bundle, build_session) => {
                if (!jid.equals_bare(peer) || device_id != 4242) return;
                callbacks++;
                received_demand = build_session;
                if (await_send && build_session) {
                    fail_if_not(module.start_session(test_stream, jid, device_id, bundle),
                            "the send demand must build its first native session from the valid bundle");
                }
                if (!await_send || preparation_completed) loop.quit();
            });
            timeout = Timeout.add(3000, () => {
                timeout = 0;
                fail_if_reached("bundle demand fixture timed out");
                loop.quit();
                return Source.REMOVE;
            }, Priority.LOW);
            if (initial_send) module.fetch_bundle(stream, peer, 4242);
            else module.fetch_bundle_info(stream, peer, 4242);
            if (upgrade) module.fetch_bundle(stream, peer, 4242);
            if (await_send) {
                module.await_legacy_bundle_for_send.begin(stream, peer, 4242, cancellable, !metadata_only, (obj, res) => {
                    preparation_ready = module.await_legacy_bundle_for_send.end(res);
                    preparation_completed = true;
                    if (callbacks > 0) loop.quit();
                });
                if (cancel_send) cancellable.cancel();
            }
            loop.run();
            fail_if_not_eq_int(requests, 1, "metadata and send demand must coalesce into one in-flight lookup");
            fail_if_not_eq_int(callbacks, 1, "a valid bundle must be delivered once");
            fail_if(received_demand != (initial_send || upgrade || (await_send && !cancel_send && !metadata_only)),
                    "bundle callback must retain active send demands and discard cancelled ones");
            var address = new Address(peer.to_string(), 4242);
            if (await_send) {
                fail_if_not(preparation_completed, "the actual send must deterministically complete its preparation");
                fail_if(preparation_ready == cancel_send, "only an uncancelled actual send may become ready");
            }
            fail_if(store.contains_session(address) != (await_send && !cancel_send && !metadata_only),
                    "only an active actual-send waiter may create a native ratchet");
            address.device_id = 0;
            SignalHandler.disconnect(stream, wrote);
            SignalHandler.disconnect(module, ready);
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (timeout != 0) Source.remove(timeout);
            if (module != null && stream != null) {
                drain_ready_callbacks();
                module.detach(stream);
                stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
                drain_ready_callbacks();
            }
        }
    }

    private StanzaNode valid_peer_bundle(Context context) throws Error {
        ECKeyPair identity = context.generate_key_pair();
        ECKeyPair signed_pre_key = context.generate_key_pair();
        ECKeyPair pre_key = context.generate_key_pair();
        uint8[] signature = context.calculate_signature(identity.private, signed_pre_key.public.serialize());
        return new StanzaNode.build("bundle", NS_OMEMO).add_self_xmlns()
                .put_node(new StanzaNode.build("identityKey", NS_OMEMO)
                    .put_node(new StanzaNode.text(Base64.encode(identity.public.serialize()))))
                .put_node(new StanzaNode.build("signedPreKeyPublic", NS_OMEMO).put_attribute("signedPreKeyId", "1")
                    .put_node(new StanzaNode.text(Base64.encode(signed_pre_key.public.serialize()))))
                .put_node(new StanzaNode.build("signedPreKeySignature", NS_OMEMO)
                    .put_node(new StanzaNode.text(Base64.encode(signature))))
                .put_node(new StanzaNode.build("prekeys", NS_OMEMO)
                    .put_node(new StanzaNode.build("preKeyPublic", NS_OMEMO).put_attribute("preKeyId", "1")
                        .put_node(new StanzaNode.text(Base64.encode(pre_key.public.serialize())))));
    }

    private void run_registration(LookupMode mode) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(mode);
            fixture.start();
            fixture.wait_for_ready();
            fail_if_not(fixture.lookup_answered, "candidate bundle lookup must complete before publication");
            fail_if_not(fixture.ready, "the replacement must finish own list and bundle publication");
            fail_if(fixture.guard.read_pending_checked(), "acknowledged registration must be persisted as complete");
            fail_if(fixture.store.registration_pending, "store registration mirror must follow persisted acknowledgement");
            int32 device_id = fixture.guard.read_device_id_checked();
            if (mode == LookupMode.SAME_IDENTITY) {
                fail_if_not_eq_int(device_id, 1001, "our previously published identity must retain its ID");
            } else {
                fail_if(device_id == 1001 || device_id == 2002 || device_id <= 0,
                        "a colliding candidate must be replaced before publication");
                fail_if_not(fixture.last_published_list.contains(1001), "the other device's colliding list entry must remain");
                fail_if_not(fixture.last_published_list.contains(2002), "other own devices must remain in the list");
                fail_if_not(fixture.last_published_list.contains(device_id), "the published list must contain the persisted replacement");
                fail_if_not_eq_int(fixture.old_id_mutations, 0, "the colliding bundle node must never be overwritten or retracted");
                fail_if_not(fixture.replacement_probed_before_publish, "the replacement bundle must also be checked before publication");
            }
            fail_if_not_eq_int(fixture.published_bundle_id, device_id, "bundle and list must use the same persisted device ID");
            fail_if_not_eq_int((int) fixture.store.local_registration_id, device_id, "native store must use the persisted replacement");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_lookup_error() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(LookupMode.ERROR);
            GLib.Test.expect_message("xmpp-vala", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Failed to request pubsub items*resource-constraint*");
            fixture.start();
            fixture.wait_for_lookup_failure();
            GLib.Test.assert_expected_messages();
            fail_if_not(fixture.lookup_answered, "test must observe a bundle lookup failure");
            fail_if_not_eq_int(fixture.publications, 0, "a lookup error must never authorize publication");
            fail_if_not_eq_int(fixture.guard.read_device_id_checked(), 1001, "a lookup error must never authorize replacement");
            fail_if_not(fixture.guard.read_pending_checked(), "a failed lookup must preserve pending registration");
            fail_if_not(fixture.store.registration_pending, "a failed lookup must preserve the send gate");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_pending_ack() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(LookupMode.OTHER_IDENTITY);
            fixture.hold_bundle_ack = true;
            fixture.start();
            fixture.wait_for_held_bundle();
            fail_if_not(fixture.held_bundle != null, "test must reach bundle publication");
            fail_if_not(fixture.guard.read_pending_checked(), "sending a bundle does not mean the server accepted it");
            fail_if_not(fixture.store.registration_pending, "outgoing messages must wait for the bundle acknowledgement");
            fail_if(fixture.ready, "device-list readiness must wait for bundle acknowledgement");
            fixture.acknowledge_held_bundle();
            fixture.wait_for_ready();
            fail_if_not(fixture.ready, "a successful bundle acknowledgement must finish registration");
            fail_if(fixture.guard.read_pending_checked(), "the completion marker must be persisted after acknowledgement");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_fresh_empty_list() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(LookupMode.MISSING);
            fixture.hold_bundle_ack = true;
            fixture.start(true);
            fixture.wait_for_held_bundle();
            fail_if_not(fixture.lookup_answered, "fresh registration must first check its candidate bundle");
            fail_if_not(fixture.held_bundle != null,
                    "the ID-check readiness future must not suppress the first list and bundle publication");
            fail_if_not_eq_int(fixture.guard.read_device_id_checked(), 1001,
                    "an unlisted candidate with no bundle must retain its ID");
            fail_if_not_eq_int(fixture.last_published_list.size, 1,
                    "an empty server list must receive exactly our verified candidate");
            fail_if_not(fixture.last_published_list.contains(1001));
            fail_if_not_eq_int(fixture.published_bundle_id, 1001,
                    "the first bundle and first list must use the same verified ID");
            fail_if_not(fixture.guard.read_pending_checked(), "registration must stay pending before bundle acknowledgement");
            fail_if_not(fixture.store.registration_pending);
            fail_if(fixture.ready);
            fixture.acknowledge_held_bundle();
            fixture.wait_for_ready();
            fail_if_not(fixture.ready, "first registration must finish after the bundle acknowledgement");
            fail_if(fixture.guard.read_pending_checked());
            fail_if(fixture.store.registration_pending);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_orphan_replacement() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(LookupMode.OTHER_IDENTITY);
            fixture.orphan_on_first_replacement = true;
            fixture.start();
            fixture.wait_for_ready();
            fail_if_not(fixture.ready, "registration must continue past an occupied orphan bundle");
            fail_if(fixture.rejected_replacement_id <= 0, "test must expose an occupied first replacement");
            fail_if_not_eq_int(fixture.rejected_replacement_mutations, 0, "the orphan bundle must never be overwritten or retracted");
            fail_if(fixture.guard.read_device_id_checked() == fixture.rejected_replacement_id,
                    "the occupied first replacement must be discarded before publication");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void test_latest_list() { run_latest_list(false); }
    private void test_candidate_listed_during_probe() { run_latest_list(true); }

    private void test_due_watchdog() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(LookupMode.SAME_IDENTITY);
            fixture.hold_bundle_ack = true;
            fixture.start();
            fixture.wait_for_held_bundle();
            fail_if_not(fixture.held_bundle != null, "the test must reach the unacknowledged bundle");
            // An already due watchdog must still stop a genuinely unanswered IQ.
            fail_if(fixture.wait_for_ready(0, false), "without its reply the bundle must not become ready");
            fail_if_not(fixture.guard.read_pending_checked());
            // The reply queues the real IQ continuation at DEFAULT_IDLE. Its
            // retract/configure/readiness chain must beat an equally due watchdog.
            fixture.acknowledge_held_bundle();
            fail_if_not(fixture.wait_for_ready(0), "acknowledged IQ follow-ups must finish before the watchdog");
            fail_if(fixture.guard.read_pending_checked());
            fail_if(fixture.store.registration_pending);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private void run_latest_list(bool initially_empty) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(initially_empty ? LookupMode.MISSING : LookupMode.OTHER_IDENTITY);
            fixture.hold_initial_lookup = true;
            fixture.start(initially_empty);
            fixture.wait_for_held_lookup();
            fail_if_not(fixture.held_lookup != null, "test must hold the first candidate's bundle lookup");
            fail_if_not_eq_int(fixture.publications, 0, "registration must still be waiting for its candidate check");
            fixture.receive_updated_list();
            fixture.answer_held_lookup();
            fixture.wait_for_ready();
            fail_if_not(fixture.ready, "registration must complete from the latest own-list snapshot");
            fail_if(fixture.guard.read_device_id_checked() == 1001,
                    "a candidate listed during the lookup without our bundle must not be claimed");
            fail_if_not(fixture.last_published_list.contains(1001), "the colliding device must remain listed");
            fail_if_not(fixture.last_published_list.contains(3003), "a device added during the lookup must remain listed");
            fail_if(fixture.last_published_list.contains(2002), "the superseded snapshot must not resurrect a removed device");
            fail_if_not_eq_str(fixture.last_published_labels[3003], "New device",
                    "a label received during the lookup must remain in the published list");
            fail_if_not_eq_int(fixture.old_id_mutations, 0, "a newly listed candidate's bundle must not be overwritten");
            fail_if_not(fixture.last_published_list.contains(fixture.guard.read_device_id_checked()),
                    "the latest list must also contain our verified replacement");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) fixture.cleanup(); }
    }

    private class Fixture : Object {
        internal Store store;
        internal LegacyRegistrationGuard guard;
        internal bool lookup_answered = false;
        internal bool ready = false;
        internal bool hold_bundle_ack = false;
        internal bool hold_initial_lookup = false;
        internal bool replacement_probed_before_publish = false;
        internal bool orphan_on_first_replacement = false;
        internal int32 rejected_replacement_id = 0;
        internal int rejected_replacement_mutations = 0;
        internal StanzaNode? held_bundle;
        internal StanzaNode? held_lookup;
        private StanzaNode? held_lookup_payload;
        internal int publications = 0;
        internal int old_id_mutations = 0;
        internal int32 published_bundle_id = 0;
        internal Gee.ArrayList<int32> last_published_list = new Gee.ArrayList<int32>();
        internal Gee.HashMap<int32, string> last_published_labels = new Gee.HashMap<int32, string>();

        private LookupMode mode;
        private string temp_dir;
        private string db_path;
        private Dino.Plugins.Omemo.Database db;
        private RegistrationTestStream stream;
        private StreamModule module;
        private Jid own_jid;
        private ECPublicKey lookup_key;
        private MainLoop loop = new MainLoop();
        private ulong wrote_handler;
        private ulong ready_handler;

        internal Fixture(LookupMode mode) throws Error {
            this.mode = mode;
            temp_dir = DirUtils.make_tmp("dinox-registration-pubsub-XXXXXX");
            db_path = Path.build_filename(temp_dir, "omemo.db");
            db = new Dino.Plugins.Omemo.Database(db_path);
            Context context = Plugin.get_context();
            store = setup_test_store_context(context);
            store.identity_key_store.local_registration_id = 1001;
            int identity_id = (int) db.identity.upsert()
                    .value(db.identity.account_id, 1, true)
                    .value(db.identity.device_id, 1001)
                    .value(db.identity.identity_key_private_base64, Base64.encode(store.identity_key_store.identity_key_private.get_data()))
                    .value(db.identity.identity_key_public_base64, Base64.encode(store.identity_key_store.identity_key_public.get_data()))
                    .value(db.identity.registration_pending, true)
                    .perform_checked();
            store.signed_pre_key_store = new BackedSignedPreKeyStore(db, identity_id);
            store.pre_key_store = new BackedPreKeyStore(db, identity_id);
            store.session_store = new BackedSessionStore(db, identity_id);
            store.registration_pending = true;
            guard = new LegacyRegistrationGuard(db, 1);
            if (mode == LookupMode.SAME_IDENTITY) {
                IdentityKeyPair own_identity = store.identity_key_pair;
                lookup_key = own_identity.public;
            } else {
                ECKeyPair other_identity = context.generate_key_pair();
                lookup_key = other_identity.public;
            }

            own_jid = new Jid("alice@example.test/dinox");
            stream = new RegistrationTestStream(new Jid("example.test"));
            var bind = new Bind.Flag();
            bind.my_jid = own_jid;
            stream.add_flag(bind);
            stream.negotiation_complete = true;
            stream.add_module(new Iq.Module());
            stream.add_module(new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                    Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                    Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Registration Test"));
            stream.add_module(new MessageModule());
            stream.add_module(new Xmpp.Xep.Pubsub.Module());
            module = new StreamModule(store);
            module.registration_guard = guard;
            stream.add_module(module);
            wrote_handler = stream.wrote_node.connect(on_write);
            ready_handler = module.device_list_loaded.connect((jid, devices) => {
                if (!jid.equals_bare(own_jid)) return;
                ready = !store.registration_pending;
                if (ready) loop.quit();
            });
        }

        internal void start(bool empty_list = false) {
            var list = new StanzaNode.build("list", NS_OMEMO).add_self_xmlns();
            if (!empty_list) {
                list.put_node(new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "1001"))
                    .put_node(new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "2002"));
            }
            module.parse_device_list(stream, own_jid.bare_jid, "current", list);
        }

        internal void receive_updated_list() {
            var list = new StanzaNode.build("list", NS_OMEMO).add_self_xmlns()
                    .put_node(new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "1001"))
                    .put_node(new StanzaNode.build("device", NS_OMEMO).put_attribute("id", "3003")
                        .put_attribute("label", "New device"));
            module.parse_device_list(stream, own_jid.bare_jid, "newer", list);
        }

        private void run_until_timeout(uint duration_ms, bool expected_completion) {
            uint timer = 0;
            // Synchronous key generation/SQLCipher commits can overrun the
            // deadline while an answered IQ already has a DEFAULT_IDLE resume.
            // Let that finite reply chain finish before declaring a stall.
            timer = Timeout.add(duration_ms, () => {
                timer = 0;
                if (expected_completion) fail_if_reached("registration fake-IQ sequence timed out");
                loop.quit();
                return Source.REMOVE;
            }, Priority.LOW);
            loop.run();
            if (timer != 0) Source.remove(timer);
        }

        internal bool wait_for_ready(uint duration_ms = 3000, bool expected_completion = true) {
            if (!ready) run_until_timeout(duration_ms, expected_completion);
            return ready;
        }
        internal void wait_for_held_bundle() { if (held_bundle == null) run_until_timeout(3000, true); }
        internal void wait_for_held_lookup() { if (held_lookup == null) run_until_timeout(3000, true); }

        internal void wait_for_lookup_failure() {
            bool completed = false;
            // start() installed the own-list readiness future before its IQ.
            // This joins that operation; a rejected probe resolves it empty.
            module.request_user_devicelist.begin(stream, own_jid.bare_jid, (obj, res) => {
                var devices = module.request_user_devicelist.end(res);
                fail_if_not_eq_int(devices.size, 0, "a failed probe must not report registration readiness");
                completed = true;
                loop.quit();
            });
            if (!completed) run_until_timeout(3000, true);
            fail_if_not(completed, "the rejected lookup must finish before teardown");
        }

        internal void answer_held_lookup() {
            if (held_lookup == null) return;
            StanzaNode request = (!) held_lookup;
            StanzaNode? payload = held_lookup_payload;
            held_lookup = null;
            held_lookup_payload = null;
            hold_initial_lookup = false;
            respond(request, payload);
        }

        internal void acknowledge_held_bundle() {
            if (held_bundle == null) return;
            respond((!) held_bundle, null);
            held_bundle = null;
        }

        private void on_write(StanzaNode outgoing) {
            string? items_node = get_child_node(outgoing, "items");
            if (items_node != null) {
                bool candidate_lookup = items_node == NS_OMEMO + ".bundles:1001";
                if (candidate_lookup) {
                    if (!lookup_answered) fail_if_not_eq_int(publications, 0,
                            "first-publication collision lookup must precede every publish");
                    lookup_answered = true;
                    if (mode == LookupMode.ERROR) {
                        var request = new Iq.Stanza.from_stanza(outgoing, own_jid);
                        var error_iq = new Iq.Stanza.error(request,
                                new ErrorStanza.resource_constraint("injected registration lookup failure"));
                        error_iq.from = stream.remote_name;
                        error_iq.to = own_jid;
                        stream.emit_iq_result(error_iq.stanza);
                        return;
                    }
                }
                var items = new StanzaNode.build("items", NS_PUBSUB).put_attribute("node", (!) items_node);
                bool orphan_replacement = false;
                if (!candidate_lookup && ((!) items_node).has_prefix(NS_OMEMO + ".bundles:")) {
                    replacement_probed_before_publish = replacement_probed_before_publish || publications == 0;
                    if (orphan_on_first_replacement && rejected_replacement_id == 0) {
                        orphan_replacement = true;
                        rejected_replacement_id = int.parse(((!) items_node).substring((NS_OMEMO + ".bundles:").length));
                    }
                }
                if ((candidate_lookup && mode != LookupMode.MISSING) || orphan_replacement) {
                    items.put_node(new StanzaNode.build("item", NS_PUBSUB).put_attribute("id", "current")
                            .put_node(new StanzaNode.build("bundle", NS_OMEMO).add_self_xmlns()
                                .put_node(new StanzaNode.build("identityKey", NS_OMEMO)
                                    .put_node(new StanzaNode.text(Base64.encode(lookup_key.serialize()))))));
                }
                var payload = new StanzaNode.build("pubsub", NS_PUBSUB).add_self_xmlns().put_node(items);
                if (candidate_lookup && hold_initial_lookup) {
                    held_lookup = outgoing;
                    held_lookup_payload = payload;
                    loop.quit();
                    return;
                }
                respond(outgoing, payload);
                return;
            }
            string? publish_node = get_child_node(outgoing, "publish");
            string? retract_node = get_child_node(outgoing, "retract");
            if (publish_node == NS_OMEMO + ".bundles:1001" || retract_node == NS_OMEMO + ".bundles:1001") old_id_mutations++;
            string rejected_node = NS_OMEMO + ".bundles:" + rejected_replacement_id.to_string();
            if (rejected_replacement_id > 0 && (publish_node == rejected_node || retract_node == rejected_node)) rejected_replacement_mutations++;
            if (publish_node != null) {
                publications++;
                fail_if_not(lookup_answered, "no publication is allowed before collision lookup finishes");
                if (publish_node == NS_OMEMO + ".devicelist") {
                    StanzaNode? pubsub = outgoing.get_subnode("pubsub", NS_PUBSUB);
                    StanzaNode? publish = ((!) pubsub).get_subnode("publish", NS_PUBSUB);
                    StanzaNode? item = ((!) publish).get_subnode("item", NS_PUBSUB);
                    StanzaNode? list = ((!) item).get_subnode("list", NS_OMEMO);
                    last_published_list.clear();
                    last_published_labels.clear();
                    foreach (StanzaNode device in ((!) list).get_subnodes("device")) {
                        int32 device_id = device.get_attribute_int("id");
                        last_published_list.add(device_id);
                        string? label = device.get_attribute("label");
                        if (label != null) last_published_labels[device_id] = (!) label;
                    }
                } else if (((!) publish_node).has_prefix(NS_OMEMO + ".bundles:")) {
                    published_bundle_id = int.parse(((!) publish_node).substring((NS_OMEMO + ".bundles:").length));
                    if (hold_bundle_ack) {
                        held_bundle = outgoing;
                        loop.quit();
                        return;
                    }
                }
            }
            StanzaNode? owner = outgoing.get_subnode("pubsub", NS_PUBSUB_OWNER);
            if (owner != null && outgoing.get_attribute("type") == "get") {
                StanzaNode? request_configure = ((!) owner).get_subnode("configure", NS_PUBSUB_OWNER);
                var configure = new StanzaNode.build("configure", NS_PUBSUB_OWNER);
                string? node_id = request_configure != null ? ((!) request_configure).get_attribute("node") : null;
                if (node_id != null) configure.put_attribute("node", (!) node_id);
                configure.put_node(new StanzaNode.build("x", "jabber:x:data").add_self_xmlns().put_attribute("type", "form"));
                respond(outgoing, new StanzaNode.build("pubsub", NS_PUBSUB_OWNER).add_self_xmlns().put_node(configure));
                return;
            }
            if (outgoing.name == "iq") respond(outgoing, null);
        }

        private void respond(StanzaNode outgoing, StanzaNode? payload) {
            var request = new Iq.Stanza.from_stanza(outgoing, own_jid);
            var result = new Iq.Stanza.result(request, payload);
            result.from = stream.remote_name;
            result.to = own_jid;
            stream.emit_iq_result(result.stanza);
        }

        internal void cleanup() {
            // Keep the responder and DB alive for replies already delivered,
            // then cancel held IQs and consume their cancellation continuations.
            drain_ready_callbacks();
            module.detach(stream);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            drain_ready_callbacks();
            SignalHandler.disconnect(stream, wrote_handler);
            SignalHandler.disconnect(module, ready_handler);
            db.close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private static void drain_ready_callbacks() {
        bool drained = false;
        uint barrier = Idle.add(() => {
            drained = true;
            return Source.REMOVE;
        }, Priority.LOW);
        MainContext context = MainContext.default();
        // Finite in-memory IQ chains only: never wait for network or retry timers.
        for (int i = 0; i < 128 && !drained; i++) context.iteration(false);
        if (!drained) Source.remove(barrier);
        fail_if_not(drained, "fake-IQ continuations must quiesce before teardown");
    }

    private static string? get_child_node(StanzaNode iq, string child) {
        StanzaNode? pubsub = iq.get_subnode("pubsub", NS_PUBSUB);
        StanzaNode? child_node = pubsub != null ? ((!) pubsub).get_subnode(child, NS_PUBSUB) : null;
        return child_node != null ? ((!) child_node).get_attribute("node") : null;
    }

    private class RegistrationTestStream : Xmpp.XmppStream {
        internal signal void wrote_node(StanzaNode node);
        internal RegistrationTestStream(Jid remote) { base(remote); }
        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError { throw new IOError.NOT_CONNECTED("test has no network"); }
        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            wrote_node(node);
        }
        internal void emit_iq_result(StanzaNode node) { received_iq_stanza(this, node); }
    }
}

}
