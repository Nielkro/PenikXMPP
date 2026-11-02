using Dino.Entities;
using Dino.Plugins.Omemo;
using Gee;
using Omemo;
using Qlite;
using Xmpp;

namespace Omemo.Test {

// Isolated real native v4 key exchange plus the production SQL commit hook.
// These tests do not activate OMEMO 2 outside the test executable, nor bypass
// the transaction by manually emitting a key-consumption notification.
class OwnBundleV2MaintenanceTest : Gee.TestCase {
    private const string OMEMO_NS = "urn:xmpp:omemo:2";
    private const string PUBSUB_NS = "http://jabber.org/protocol/pubsub";
    private const string OWNER_NS = "http://jabber.org/protocol/pubsub#owner";
    private const string FORM_NS = "jabber:x:data";
    private const string OWN_NODE = "urn:xmpp:omemo:2:bundles";
    private enum Gate { NONE, GET, PUBLISH, CONFIG_GET }
    private delegate bool Condition();

    public OwnBundleV2MaintenanceTest() {
        base("OwnBundleV2Maintenance");
        add_test("persistent_highest_deleted_id_is_not_reused_after_reopen", test_id_no_reuse);
        add_test("real_v4_commit_burst_coalesces_and_preserves_peer_session", test_commit_burst);
        add_test("metadata_failure_rolls_back_without_own_pubsub", test_rollback);
        add_test("failed_publish_retry_rebuilds_after_consumption", test_retry);
        add_test("held_iq_rejects_in_place_identity_change", test_identity_context);
        add_test("late_old_reply_and_detach_preserve_replacement_request", test_stream_context);
        add_test("pending_xml_is_not_replayed_for_other_store_or_device", test_pending_owner);
        add_test("explicit_publish_works_with_automatic_maintenance_disabled", test_explicit_publish);
    }

    private class FakePep : XmppStream {
        internal Bundle2 accepted;
        internal Bundle2? sent;
        internal ArrayList<Bundle2> snapshots = new ArrayList<Bundle2>();
        internal ArrayList<string> published_items = new ArrayList<string>();
        internal int own_fetches = 0;
        internal int publishes = 0;
        internal int config_gets = 0;
        internal int config_sets = 0;
        internal int devicelist_publishes = 0;
        internal int messages = 0;
        internal Gate gate = Gate.NONE;
        internal bool fail_next_publish = false;
        internal StanzaNode? held;
        private Bundle2? held_bundle;
        private Bundle2? held_lookup;
        private bool gate_used = false;
        private bool stopped = false;
        private Jid own_jid;

        internal FakePep(Jid own_jid, Bundle2 initial) throws Error {
            base(new Jid("example.test"));
            this.own_jid = own_jid;
            accepted = initial;
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated v2 maintenance stream");
        }

        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            if (node.name == "message") { messages++; return; }
            if (node.name != "iq") return;
            StanzaNode? pubsub = node.get_subnode("pubsub", PUBSUB_NS);
            StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", PUBSUB_NS) : null;
            StanzaNode? publish = pubsub != null ? ((!) pubsub).get_subnode("publish", PUBSUB_NS) : null;
            StanzaNode? owner = node.get_subnode("pubsub", OWNER_NS);
            StanzaNode? config = owner != null ? ((!) owner).get_subnode("configure", OWNER_NS) : null;
            if (items != null && ((!) items).get_attribute("node") == OWN_NODE) {
                own_fetches++;
                if (hold_once(Gate.GET, node, null)) {
                    held_lookup = accepted;
                    return;
                }
            }
            if (publish != null && ((!) publish).get_attribute("node") == OMEMO_NS + ":devices") {
                devicelist_publishes++;
            }
            if (publish != null && ((!) publish).get_attribute("node") == OWN_NODE) {
                StanzaNode? item = ((!) publish).get_subnode("item", PUBSUB_NS);
                StanzaNode? bundle = item != null ? ((!) item).get_subnode("bundle", OMEMO_NS) : null;
                if (bundle == null) throw new IOError.INVALID_DATA("Own v2 publication has no bundle");
                sent = new Bundle2((!) bundle);
                snapshots.add((!) sent);
                published_items.add(((!) item).get_attribute("id") ?? "");
                publishes++;
                if (fail_next_publish) {
                    fail_next_publish = false;
                    Idle.add(() => {
                        if (!stopped) respond_error(node);
                        return Source.REMOVE;
                    });
                    return;
                }
                if (hold_once(Gate.PUBLISH, node, sent)) return;
                Bundle2 snapshot = (!) sent;
                Idle.add(() => {
                    if (!stopped) { accepted = snapshot; respond(node, null); }
                    return Source.REMOVE;
                });
                return;
            }
            if (config != null && ((!) config).get_attribute("node") == OWN_NODE) {
                if (node.get_attribute("type") == Iq.Stanza.TYPE_GET) {
                    config_gets++;
                    if (hold_once(Gate.CONFIG_GET, node, null)) return;
                } else config_sets++;
            }
            Idle.add(() => {
                if (!stopped) respond_request(node, null);
                return Source.REMOVE;
            });
        }

        private bool hold_once(Gate requested, StanzaNode node, Bundle2? bundle) {
            if (gate != requested || gate_used) return false;
            gate_used = true;
            held = node;
            held_bundle = bundle;
            return true;
        }

        internal void release() {
            if (held == null) return;
            StanzaNode node = (!) held;
            held = null;
            if (held_bundle != null) {
                accepted = (!) held_bundle;
                held_bundle = null;
                respond(node, null);
            } else {
                Bundle2? lookup = held_lookup;
                held_lookup = null;
                respond_request(node, lookup);
            }
        }

        private void respond_error(StanzaNode outgoing) {
            var request = new Iq.Stanza.from_stanza(outgoing, own_jid);
            var error = new ErrorStanza.build(ErrorStanza.TYPE_CANCEL,
                ErrorStanza.CONDITION_SERVICE_UNAVAILABLE, null, null);
            var response = new Iq.Stanza.error(request, error);
            response.from = request.to ?? remote_name;
            response.to = own_jid;
            received_iq_stanza(this, response.stanza);
        }

        private void respond_request(StanzaNode node, Bundle2? lookup) {
            StanzaNode? pubsub = node.get_subnode("pubsub", PUBSUB_NS);
            StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", PUBSUB_NS) : null;
            if (items != null) {
                string node_id = ((!) items).get_attribute("node") ?? "";
                var reply_items = new StanzaNode.build("items", PUBSUB_NS).put_attribute("node", node_id);
                if (node_id == OWN_NODE) {
                    StanzaNode? requested = ((!) items).get_subnode("item", PUBSUB_NS);
                    reply_items.put_node(new StanzaNode.build("item", PUBSUB_NS)
                        .put_attribute("id", requested != null ? ((!) requested).get_attribute("id") ?? "22" : "22")
                        .put_node((!) (lookup ?? accepted).node));
                }
                respond(node, new StanzaNode.build("pubsub", PUBSUB_NS).add_self_xmlns().put_node(reply_items));
                return;
            }
            StanzaNode? owner = node.get_subnode("pubsub", OWNER_NS);
            StanzaNode? config = owner != null ? ((!) owner).get_subnode("configure", OWNER_NS) : null;
            if (config != null && node.get_attribute("type") == Iq.Stanza.TYPE_GET) {
                // Non-public configuration forces a submit when context is
                // valid, making the held-config invalidation observable.
                var form = new StanzaNode.build("x", FORM_NS).add_self_xmlns().put_attribute("type", "form")
                    .put_node(field("FORM_TYPE", PUBSUB_NS + "#node_config", "hidden"))
                    .put_node(field("pubsub#access_model", "whitelist"))
                    .put_node(field("pubsub#persist_items", "true"))
                    .put_node(field("pubsub#max_items", "max"));
                respond(node, new StanzaNode.build("pubsub", OWNER_NS).add_self_xmlns()
                    .put_node(new StanzaNode.build("configure", OWNER_NS).put_attribute("node", OWN_NODE).put_node(form)));
                return;
            }
            respond(node, null);
        }

        private StanzaNode field(string name, string value, string type_ = "text-single") {
            return new StanzaNode.build("field", FORM_NS).put_attribute("var", name).put_attribute("type", type_)
                .put_node(new StanzaNode.build("value", FORM_NS).put_node(new StanzaNode.text(value)));
        }

        private void respond(StanzaNode outgoing, StanzaNode? payload) {
            var request = new Iq.Stanza.from_stanza(outgoing, own_jid);
            var response = new Iq.Stanza.result(request, payload);
            response.from = request.to ?? remote_name;
            response.to = own_jid;
            received_iq_stanza(this, response.stanza);
        }

        internal void stop() { stopped = true; held = null; held_bundle = null; held_lookup = null; }
    }

    private class Fixture : Object {
        internal string temp_dir;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Context context;
        internal Store alice;
        internal Store bob;
        internal Account account;
        internal Jid alice_jid;
        internal Address alice_address;
        internal Address bob_address;
        internal int identity_id;
        internal FakePep stream;
        internal StreamModule2 module;
        internal Omemo2Decrypt decryptor;
        internal HashSet<int> consumed = new HashSet<int>();
        private Dino.StreamInteractor interactor;
        private string own_public;
        private string own_private;
        private string signed_public;
        private string signed_signature;

        internal Fixture() throws Error {
            temp_dir = DirUtils.make_tmp("dinox-v2-bundle-maintenance-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(temp_dir, "app.db"), "v2-maintenance-test");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            if (!Plugin.ensure_context()) throw new IOError.FAILED("No native OMEMO context");
            context = Plugin.get_context();
            alice_jid = new Jid("alice@example.test");
            alice = setup_test_store_context(context);
            bob = setup_test_store_context(context);
            alice.identity_key_store.local_registration_id = 11;
            bob.identity_key_store.local_registration_id = 22;
            account = new Account(new Jid("bob@example.test"), "isolated-test-password");
            account.persist(app_db);
            db.identity.upsert()
                .value(db.identity.account_id, account.id, true)
                .value(db.identity.device_id, 22)
                .value(db.identity.identity_key_private_base64, Base64.encode(bob.identity_key_store.identity_key_private.get_data()))
                .value(db.identity.identity_key_public_base64, Base64.encode(bob.identity_key_store.identity_key_public.get_data()))
                .perform_checked();
            identity_id = db.identity.get_id_checked(account.id);
            bob.pre_key_store = new BackedPreKeyStore(db, identity_id);
            bob.signed_pre_key_store = new BackedSignedPreKeyStore(db, identity_id);
            bob.session_store = new BackedSessionStore(db, identity_id);
            alice_address = new Address(alice_jid.to_string(), 11);
            bob_address = new Address(account.bare_jid.to_string(), 22);
            SignedPreKeyRecord signed = context.generate_signed_pre_key(bob.identity_key_pair, 7);
            bob.store_signed_pre_key(signed);
            Set<PreKeyRecord> records = context.generate_pre_keys(101, 100);
            foreach (PreKeyRecord record in records) bob.store_pre_key(record);
            Bundle2 initial = bundle(signed, records);
            own_public = Base64.encode(bob.identity_key_pair.public.serialize());
            own_private = Base64.encode(bob.identity_key_pair.private.serialize());
            signed_public = Base64.encode(signed.key_pair.public.serialize());
            signed_signature = Base64.encode(signed.signature_omemo);
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            var trust = new TrustManager(interactor, db, app_db);
            decryptor = new Omemo2Decrypt(account, interactor, trust, db, bob);
            stream = new FakePep(account.bare_jid, initial);
            prepare_stream(stream);
            module = new StreamModule2(bob);
            stream.add_module(module);
            module.attach(stream);
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        }

        private void prepare_stream(FakePep target) {
            var iq = new Iq.Module();
            var messages = new MessageModule();
            var pubsub = new Xmpp.Xep.Pubsub.Module();
            var disco = new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX v2 Maintenance Test");
            target.add_module(iq); target.add_module(messages); target.add_module(pubsub); target.add_module(disco);
            disco.attach(target); iq.attach(target); messages.attach(target); pubsub.attach(target);
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid;
            bind.finished = true;
            target.add_flag(bind);
        }

        internal FakePep replace_stream(Gate gate) throws Error {
            FakePep old = stream;
            // attach itself must safely supersede an existing attachment.
            stream = new FakePep(account.bare_jid, old.accepted);
            stream.gate = gate;
            prepare_stream(stream);
            stream.add_module(module);
            module.attach(stream);
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            return old;
        }

        private Bundle2 bundle(SignedPreKeyRecord signed, Set<PreKeyRecord> records) {
            var node = new StanzaNode.build("bundle", OMEMO_NS)
                .put_node(new StanzaNode.build("ik", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(bob.identity_key_pair.public.ed.data))))
                .put_node(new StanzaNode.build("spk", OMEMO_NS).put_attribute("id", signed.id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(signed.key_pair.public.mont.data))))
                .put_node(new StanzaNode.build("spks", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(signed.signature_omemo))));
            var prekeys = new StanzaNode.build("prekeys", OMEMO_NS);
            foreach (PreKeyRecord record in records) prekeys.put_node(new StanzaNode.build("pk", OMEMO_NS)
                .put_attribute("id", record.id.to_string())
                .put_node(new StanzaNode.text(Base64.encode(record.key_pair.public.mont.data))));
            return new Bundle2(node.put_node(prekeys));
        }

        internal CiphertextMessage fresh_packet(Bundle2 advertised, int key_id) throws Error {
            Bundle2.PreKey2? selected = null;
            foreach (Bundle2.PreKey2 key in advertised.pre_keys) if (key.key_id == key_id) selected = key;
            if (selected == null) throw new IOError.NOT_FOUND("Requested v2 key is not advertised");
            // A new v4 PREKEY session is deliberate; setting builder.version
            // cannot change the native version of an existing v3 record.
            alice.delete_session(bob_address);
            SessionBuilder builder = alice.create_session_builder(bob_address);
            builder.version = 4;
            builder.process_pre_key_bundle(create_pre_key_bundle(22, 22, ((!) selected).key_id,
                ((!) selected).key, advertised.signed_pre_key_id, advertised.signed_pre_key,
                advertised.signed_pre_key_signature, advertised.identity_key));
            fail_if_not_eq_int((int) alice.load_session(bob_address).state.session_version, 4);
            return next_packet();
        }

        internal CiphertextMessage next_packet() throws Error {
            SessionCipher cipher = alice.create_session_cipher(bob_address);
            cipher.version = 4;
            // XEP-0384 empty key transports use a 32-byte all-zero secret.
            return cipher.encrypt(new uint8[32]);
        }

        internal uint8[] receive(CiphertextMessage packet) throws Error {
            return decryptor.decrypt_key_for_encrypted_key(packet.serialized,
                packet.type == CiphertextType.PREKEY, 11, alice_jid);
        }

        internal void consume(Bundle2 advertised, int key_id) throws Error {
            fail_if_not(bob.contains_pre_key(key_id));
            CiphertextMessage packet = fresh_packet(advertised, key_id);
            fail_if_not_eq_int(packet.type, CiphertextType.PREKEY);
            uint8[] secret = receive(packet);
            fail_if_not_eq_int(secret.length, 32);
            fail_if(bob.contains_pre_key(key_id), "actual native v4 receive must consume the key");
            fail_if_not_eq_int((int) bob.load_session(alice_address).state.session_version, 4);
            consumed.add(key_id);
        }

        internal bool current_bundle_ready() {
            if (stream.accepted.pre_keys.size != 100) return false;
            foreach (Bundle2.PreKey2 key in stream.accepted.pre_keys) if (consumed.contains(key.key_id)) return false;
            return stream.held == null;
        }

        internal void verify_bundle() throws Error {
            Bundle2 published = stream.accepted;
            fail_if_not_eq_int(published.pre_keys.size, 100);
            fail_if_not(StreamModule2.is_valid_omemo2_bundle(published));
            var ids = new HashSet<int>();
            foreach (Bundle2.PreKey2 key in published.pre_keys) {
                fail_if_not(ids.add(key.key_id));
                fail_if(consumed.contains(key.key_id));
                fail_if_not(bob.contains_pre_key(key.key_id));
                fail_if(key.key == null || bob.load_pre_key(key.key_id).key_pair.public.compare(key.key) != 0);
            }
            fail_if(published.identity_key == null || Base64.encode(published.identity_key.serialize()) != own_public);
            fail_if_not(Base64.encode(bob.identity_key_pair.private.serialize()) == own_private);
            fail_if_not_eq_int(published.signed_pre_key_id, 7);
            fail_if(published.signed_pre_key == null || Base64.encode(published.signed_pre_key.serialize()) != signed_public);
            fail_if(published.signed_pre_key_signature == null || Base64.encode(published.signed_pre_key_signature) != signed_signature);
            fail_if_not_eq_int((int) bob.local_registration_id, 22);
            fail_if_not_eq_int(stream.devicelist_publishes, 0);
            fail_if_not_eq_int(stream.messages, 0);
        }

        internal void close() {
            module.detach(stream);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).detach(stream);
            stream.stop();
            while (MainContext.default().pending()) MainContext.default().iteration(false);
            db.close(); app_db.close();
            foreach (string name in new string[]{"app.db", "omemo.db"}) {
                foreach (string suffix in new string[]{"", "-wal", "-shm"}) FileUtils.remove(Path.build_filename(temp_dir, name + suffix));
            }
            DirUtils.remove(temp_dir);
        }
    }

    private static bool wait_until(owned Condition condition, string reason) {
        if (condition()) return true;
        var loop = new MainLoop();
        bool completed = false;
        uint poll = Timeout.add(5, () => {
            if (!condition()) return Source.CONTINUE;
            completed = true; loop.quit(); return Source.CONTINUE;
        });
        uint deadline = Timeout.add(4000, () => { loop.quit(); return Source.CONTINUE; });
        loop.run();
        Source.remove(poll); Source.remove(deadline);
        fail_if_not(completed, reason);
        return completed;
    }

    private static void settle(uint milliseconds = 350) {
        var loop = new MainLoop();
        Timeout.add(milliseconds, () => { loop.quit(); return Source.REMOVE; });
        loop.run();
    }

    private static int highest(Bundle2 bundle) {
        int value = 0;
        foreach (Bundle2.PreKey2 key in bundle.pre_keys) value = int.max(value, key.key_id);
        return value;
    }

    private void test_id_no_reuse() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            string identity = Base64.encode(f.bob.identity_key_store.identity_key_public.get_data());
            f.bob.pre_key_store.delete_pre_key(200);
            f.bob.pre_key_store = new BackedPreKeyStore(f.db, f.identity_id);
            f.consumed.add(200);
            fail_if_not_eq_int((int) f.bob.pre_key_store.get_max_key_id(), 199);
            f.module.publish_bundles_if_needed(f.stream, f.account.bare_jid);
            if (!wait_until(() => f.current_bundle_ready(), "startup must reconcile a removed highest v2 key")) return;
            fail_if_not_eq_int(highest(f.stream.accepted), 201, "persistent watermark must prevent deleted ID reuse");
            fail_if_not(identity == Base64.encode(f.bob.identity_key_store.identity_key_public.get_data()));
            f.verify_bundle();
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_commit_burst() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            Bundle2 original = f.stream.accepted;
            f.consume(original, 200); f.consume(original, 199); f.consume(original, 198);
            string session = Base64.encode((!) f.bob.session_store.load_session(f.alice_address));
            if (!wait_until(() => f.current_bundle_ready(), "committed v4 burst must refresh own PEP")) return;
            fail_if_not_eq_int(f.stream.own_fetches, 1);
            fail_if_not_eq_int(f.stream.publishes, 1);
            f.verify_bundle();
            fail_if_not(session == Base64.encode((!) f.bob.session_store.load_session(f.alice_address)));
            int publications = f.stream.publishes;
            CiphertextMessage repeat = f.next_packet();
            fail_if_not_eq_int(repeat.type, CiphertextType.PREKEY);
            f.receive(repeat);
            settle();
            fail_if_not_eq_int(f.stream.publishes, publications, "same-session PREKEY replay consumes no additional key");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_rollback() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            uint8[]? before = f.bob.pre_key_store.load_pre_key(200);
            int deletions = 0;
            f.bob.pre_key_store.pre_key_deleted.connect((key) => deletions++);
            f.db.exec("CREATE TRIGGER reject_v2_authenticated_device BEFORE INSERT ON identity_meta " +
                "BEGIN SELECT RAISE(ABORT, 'injected v2 metadata failure'); END");
            CiphertextMessage packet = f.fresh_packet(f.stream.accepted, 200);
            bool rejected = false;
            try { f.receive(packet); } catch (Error error) { rejected = true; }
            fail_if_not(rejected, "authenticated metadata SQL failure must reject real native receive");
            fail_if_not_eq_int(deletions, 1, "failure must occur after the native consume callback");
            fail_if_not(f.bob.is_persistence_ready);
            fail_if_not(before != null && f.bob.pre_key_store.load_pre_key(200) != null &&
                Base64.encode((!) before) == Base64.encode((!) f.bob.pre_key_store.load_pre_key(200)));
            var reopened = new BackedPreKeyStore(f.db, f.identity_id);
            fail_if_not(reopened.contains_pre_key(200));
            fail_if_not(Base64.encode((!) reopened.load_pre_key(200)) == Base64.encode((!) before));
            fail_if(f.bob.session_store.load_session(f.alice_address) != null);
            var sessions = new BackedSessionStore(f.db, f.identity_id);
            fail_if(sessions.load_session(f.alice_address) != null);
            fail_if(f.bob.identity_key_store.load_identity(f.alice_address) != null);
            fail_if(f.db.identity_meta.get_device_checked(f.identity_id, f.alice_jid.to_string(), 11) != null);
            f.db.exec("DROP TRIGGER reject_v2_authenticated_device");
            settle(500);
            fail_if_not_eq_int(f.stream.own_fetches, 0);
            fail_if_not_eq_int(f.stream.publishes, 0);
            fail_if_not_eq_int(f.stream.devicelist_publishes, 0);
            fail_if_not_eq_int(f.stream.messages, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_retry() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            f.stream.fail_next_publish = true;
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                "*own bundle PubSub publish failed*service-unavailable*retrying in 30 seconds*");
            f.consume(f.stream.accepted, 200);
            if (!wait_until(() => f.stream.sent != null, "failed v2 publication must retain prepared XML")) return;
            settle(50); GLib.Test.assert_expected_messages();
            Bundle2 failed = (!) f.stream.sent;
            int spent = highest(failed);
            fail_if(spent <= 200);
            f.consume(failed, spent);
            int requests = f.stream.own_fetches;
            settle();
            fail_if_not_eq_int(f.stream.own_fetches, requests, "consumption cannot bypass publish backoff");
            f.module.retry_pending_own_bundle_publish.begin(f.stream, f.account.bare_jid, f.module.attachment_generation);
            if (!wait_until(() => f.current_bundle_ready(), "actual retry must discard stale saved v2 XML")) return;
            fail_if(f.stream.own_fetches <= requests);
            fail_if(highest(f.stream.accepted) <= spent);
            f.verify_bundle();
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_identity_context() {
        Fixture? fixture = null;
        try {
            foreach (Gate gate in new Gate[]{Gate.GET, Gate.PUBLISH, Gate.CONFIG_GET}) {
                fixture = new Fixture(); var f = (!) fixture;
                f.stream.gate = gate;
                f.consume(f.stream.accepted, 200);
                if (!wait_until(() => f.stream.held != null, "each real v2 IQ boundary must be held")) return;
                Bytes old_public = f.bob.identity_key_store.identity_key_public;
                Bytes old_private = f.bob.identity_key_store.identity_key_private;
                Store replacement = setup_test_store_context(f.context);
                // Mutate bytes without replacing the store object: an object
                // identity check alone is insufficient after this await.
                f.bob.identity_key_store.identity_key_public = replacement.identity_key_store.identity_key_public;
                f.bob.identity_key_store.identity_key_private = replacement.identity_key_store.identity_key_private;
                int writes = f.stream.publishes;
                int configs = f.stream.config_sets;
                f.stream.release(); settle();
                fail_if_not_eq_int(f.stream.publishes, writes, "stale identity continuation must not publish");
                fail_if_not_eq_int(f.stream.config_sets, configs, "stale identity continuation must not configure PEP");
                f.bob.identity_key_store.identity_key_public = old_public;
                f.bob.identity_key_store.identity_key_private = old_private;
                f.module.publish_bundles_if_needed(f.stream, f.account.bare_jid);
                if (!wait_until(() => f.current_bundle_ready(), "valid owner must remain usable after stale callback")) return;
                f.verify_bundle();
                f.close(); fixture = null;
            }
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_stream_context() {
        Fixture? fixture = null;
        FakePep? old = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            f.stream.gate = Gate.GET;
            f.consume(f.stream.accepted, 200);
            if (!wait_until(() => f.stream.held != null, "old attachment must hold a maintenance query")) return;
            old = f.replace_stream(Gate.GET);
            if (!wait_until(() => f.stream.held != null, "dirty v2 epoch must transfer to current attachment")) return;
            ((!) old).release();
            // A late lifecycle callback belonging to old stream must not
            // detach the replacement or clear its pending request slot.
            f.module.detach((!) old);
            settle();
            fail_if_not_eq_int(((!) old).publishes, 0);
            f.module.publish_bundles_if_needed(f.stream, f.account.bare_jid);
            settle(50);
            fail_if_not_eq_int(f.stream.own_fetches, 1, "old cleanup must not remove the new identical query slot");
            fail_if_not_eq_int(f.stream.publishes, 0);
            f.stream.release();
            if (!wait_until(() => f.current_bundle_ready(), "replacement query must finish dirty reconciliation")) return;
            f.verify_bundle();
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (old != null) { ((!) old).get_module<Iq.Module>(Iq.Module.IDENTITY).detach((!) old); ((!) old).stop(); }
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_pending_owner() {
        Fixture? fixture = null;
        try {
            for (int variant = 0; variant < 5; variant++) {
                fixture = new Fixture(); var f = (!) fixture;
                f.stream.fail_next_publish = true;
                GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                    "*own bundle PubSub publish failed*service-unavailable*retrying in 30 seconds*");
                f.consume(f.stream.accepted, 200);
                if (!wait_until(() => f.stream.sent != null, "failed v2 publication must be pending")) return;
                settle(50); GLib.Test.assert_expected_messages();
                int requests = f.stream.own_fetches;
                Bundle2 pending = (!) f.stream.sent;
                if (variant == 0) {
                    // Same device and identity but a replacement backing
                    // object has independently lost the reserved highest key.
                    f.bob.pre_key_store.delete_pre_key(highest(pending));
                    f.consumed.add(highest(pending));
                    f.bob.pre_key_store = new BackedPreKeyStore(f.db, f.identity_id);
                } else if (variant == 1) {
                    f.bob.identity_key_store.local_registration_id = 23;
                } else if (variant == 2) {
                    Store replacement = setup_test_store_context(f.context);
                    f.bob.identity_key_store.identity_key_public = replacement.identity_key_store.identity_key_public;
                    f.bob.identity_key_store.identity_key_private = replacement.identity_key_store.identity_key_private;
                    // A legitimate identity replacement also invalidates
                    // its old signed key; the current owner must generate a
                    // correctly signed new one instead of retrying old XML.
                    f.bob.signed_pre_key_store.delete_signed_pre_key(7);
                } else if (variant == 3) {
                    f.bob.signed_pre_key_store.delete_signed_pre_key(7);
                    f.bob.signed_pre_key_store = new BackedSignedPreKeyStore(f.db, f.identity_id);
                } else {
                    // Deletion on the same backing object emits no commit
                    // epoch. A retry must still check the private material.
                    f.bob.pre_key_store.delete_pre_key(highest(pending));
                    f.consumed.add(highest(pending));
                }
                f.module.retry_pending_own_bundle_publish.begin(f.stream, f.account.bare_jid, f.module.attachment_generation);
                if (!wait_until(() => f.stream.own_fetches > requests && f.stream.publishes >= 2,
                        "material change must fetch current state instead of replaying pending XML")) return;
                settle(50);
                if (variant == 0 || variant == 4) {
                    fail_if(highest(f.stream.accepted) <= highest(pending));
                    f.verify_bundle();
                } else if (variant == 1) {
                    fail_if_not_eq_str(f.stream.published_items[f.stream.published_items.size - 1], "23");
                    fail_if_not_eq_int(f.stream.messages, 0);
                    fail_if_not_eq_int(f.stream.devicelist_publishes, 0);
                } else {
                    ECPublicKey? published_identity = f.stream.accepted.identity_key;
                    fail_if(published_identity == null || ((!) published_identity).compare(f.bob.identity_key_pair.public) != 0,
                        "pending XML must not retain another public identity");
                    fail_if_not(StreamModule2.is_valid_omemo2_bundle(f.stream.accepted));
                    if (variant == 3) fail_if(f.stream.accepted.signed_pre_key_id == 7);
                    fail_if_not_eq_int(f.stream.messages, 0);
                    fail_if_not_eq_int(f.stream.devicelist_publishes, 0);
                }
                f.close(); fixture = null;
            }
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_explicit_publish() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(); var f = (!) fixture;
            f.module.auto_publish_own_device_list = false;
            f.consume(f.stream.accepted, 200);
            settle();
            fail_if_not_eq_int(f.stream.own_fetches, 0);
            fail_if_not_eq_int(f.stream.publishes, 0, "automatic consumption maintenance must stay disabled");
            Set<PreKeyRecord> records = new HashSet<PreKeyRecord>();
            foreach (Bundle2.PreKey2 key in f.stream.accepted.pre_keys) {
                if (f.bob.contains_pre_key(key.key_id)) records.add(f.bob.load_pre_key(key.key_id));
            }
            bool done = false;
            bool published = false;
            f.module.publish_bundle_v2.begin(f.stream, f.bob.load_signed_pre_key(7),
                f.bob.identity_key_pair, records, 22, f.module.attachment_generation, (_, response) => {
                    try { published = f.module.publish_bundle_v2.end(response); }
                    catch (Error error) { fail_if_reached(error.message); }
                    done = true;
                });
            if (!wait_until(() => done, "explicit publish must complete using actual PubSub IQs")) return;
            fail_if_not(published, "explicit API must preserve manual fixture/publication semantics");
            fail_if_not_eq_int(f.stream.publishes, 1);
            fail_if_not_eq_int(f.stream.accepted.pre_keys.size, 99);
            fail_if_not(StreamModule2.is_valid_omemo2_bundle(f.stream.accepted));
            settle();
            fail_if_not_eq_int(f.stream.own_fetches, 0, "manual publish must not enable automatic maintenance");
            fail_if(f.module.auto_publish_own_device_list);
            fail_if_not_eq_int(f.stream.devicelist_publishes, 0);
            fail_if_not_eq_int(f.stream.messages, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }
}
}
