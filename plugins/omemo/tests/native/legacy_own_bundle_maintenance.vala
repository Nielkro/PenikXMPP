using Dino.Entities;
using Dino.Plugins.Omemo;
using Gee;
using Omemo;
using Qlite;
using Xmpp;

namespace Omemo.Test {

// Exercise the production OmemoDecryptor commit hook, not a manually invoked
// maintenance notification. Fake PEP responses are held at real IQ boundaries.
class LegacyOwnBundleMaintenanceTest : Gee.TestCase {
    private const string OMEMO_NS = "eu.siacs.conversations.axolotl";
    private const string PUBSUB_NS = "http://jabber.org/protocol/pubsub";
    private const string OWNER_NS = "http://jabber.org/protocol/pubsub#owner";
    private const string FORM_NS = "jabber:x:data";
    private const string OWN_NODE = "eu.siacs.conversations.axolotl.bundles:22";
    private enum Gate { NONE, GET, PUBLISH, CONFIG_GET, CONFIG_SET }
    private delegate bool Condition();

    public LegacyOwnBundleMaintenanceTest() {
        base("LegacyOwnBundleMaintenance");
        add_test("real_decrypt_burst_and_held_iqs_publish_only_current_keys", test_burst_and_gates);
        add_test("failed_publish_retry_reconciles_consumed_highest_key", test_retry);
        add_test("metadata_failure_after_native_consume_rolls_back_without_own_pubsub", test_rollback);
        add_test("late_old_reply_preserves_replacement_request_and_dirty_refresh", test_stream_replacement);
        add_test("startup_reconciles_preexisting_missing_key_without_identity_reset", test_startup_missing_key);
    }

    private class FakePep : XmppStream {
        internal Bundle accepted;
        internal Bundle? sent;
        internal ArrayList<Bundle> snapshots = new ArrayList<Bundle>();
        internal int own_fetches = 0;
        internal int own_devicelist_fetches = 0;
        internal int publishes = 0;
        internal int own_devicelist_publishes = 0;
        internal int messages = 0;
        internal Gate gate = Gate.NONE;
        internal bool fail_next_publish = false;
        internal bool conflict_next_publish = false;
        internal StanzaNode? held;
        private Bundle? held_bundle;
        private bool gate_used = false;
        private bool stopped = false;
        private Jid own_jid;

        internal FakePep(Jid own_jid, Bundle initial) throws Error {
            base(new Jid("example.test"));
            this.own_jid = own_jid;
            accepted = initial;
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated maintenance test stream");
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
            if (publish != null && ((!) publish).get_attribute("node") == OMEMO_NS + ".devicelist") {
                own_devicelist_publishes++;
            }
            if (items != null && ((!) items).get_attribute("node") == OWN_NODE) {
                own_fetches++;
                if (hold_once(Gate.GET, node, null)) return;
            }
            if (items != null && ((!) items).get_attribute("node") == OMEMO_NS + ".devicelist" &&
                    node.get_attribute("to") == own_jid.bare_jid.to_string()) {
                own_devicelist_fetches++;
            }
            if (publish != null && ((!) publish).get_attribute("node") == OWN_NODE) {
                StanzaNode? item = ((!) publish).get_subnode("item", PUBSUB_NS);
                StanzaNode? bundle = item != null ? ((!) item).get_subnode("bundle", OMEMO_NS) : null;
                if (bundle == null) throw new IOError.INVALID_DATA("Own publication has no legacy bundle");
                sent = new Bundle((!) bundle);
                snapshots.add((!) sent);
                publishes++;
                if (conflict_next_publish) {
                    conflict_next_publish = false;
                    queue_error(node, ErrorStanza.CONDITION_CONFLICT);
                    return;
                }
                if (fail_next_publish) {
                    fail_next_publish = false;
                    queue_error(node, ErrorStanza.CONDITION_SERVICE_UNAVAILABLE);
                    return;
                }
                if (hold_once(Gate.PUBLISH, node, sent)) return;
                Bundle snapshot = (!) sent;
                Idle.add(() => {
                    if (!stopped) { accepted = snapshot; respond(node, null); }
                    return Source.REMOVE;
                });
                return;
            }
            if (config != null && ((!) config).get_attribute("node") == OWN_NODE &&
                    hold_once(node.get_attribute("type") == Iq.Stanza.TYPE_GET
                            ? Gate.CONFIG_GET : Gate.CONFIG_SET, node, null)) return;
            Idle.add(() => {
                if (!stopped) respond_request(node);
                return Source.REMOVE;
            });
        }

        private bool hold_once(Gate requested, StanzaNode node, Bundle? bundle) {
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
                respond_request(node);
            }
        }

        private void queue_error(StanzaNode node, string condition) {
            Idle.add(() => {
                if (!stopped) {
                    var request = new Iq.Stanza.from_stanza(node, own_jid);
                    var error = new ErrorStanza.build(ErrorStanza.TYPE_CANCEL, condition, null,
                            condition == ErrorStanza.CONDITION_CONFLICT
                            ? new StanzaNode.build("precondition-not-met", PUBSUB_NS + "#errors") : null);
                    var response = new Iq.Stanza.error(request, error);
                    response.from = remote_name;
                    response.to = own_jid;
                    received_iq_stanza(this, response.stanza);
                }
                return Source.REMOVE;
            });
        }

        private void respond_request(StanzaNode node) {
            StanzaNode? pubsub = node.get_subnode("pubsub", PUBSUB_NS);
            StanzaNode? items = pubsub != null ? ((!) pubsub).get_subnode("items", PUBSUB_NS) : null;
            if (items != null) {
                string node_id = ((!) items).get_attribute("node") ?? "";
                var reply_items = new StanzaNode.build("items", PUBSUB_NS).put_attribute("node", node_id);
                if (node_id == OWN_NODE) {
                    reply_items.put_node(new StanzaNode.build("item", PUBSUB_NS)
                            .put_attribute("id", "current").put_node(accepted.node));
                } else if (node_id == OMEMO_NS + ".devicelist") {
                    reply_items.put_node(new StanzaNode.build("item", PUBSUB_NS)
                            .put_attribute("id", "current")
                            .put_node(new StanzaNode.build("list", OMEMO_NS)
                                    .put_node(new StanzaNode.build("device", OMEMO_NS).put_attribute("id",
                                        node.get_attribute("to") == own_jid.bare_jid.to_string() ? "22" : "11"))));
                }
                respond(node, new StanzaNode.build("pubsub", PUBSUB_NS).add_self_xmlns().put_node(reply_items));
                return;
            }
            StanzaNode? owner = node.get_subnode("pubsub", OWNER_NS);
            StanzaNode? config = owner != null ? ((!) owner).get_subnode("configure", OWNER_NS) : null;
            if (config != null && node.get_attribute("type") == Iq.Stanza.TYPE_GET) {
                var form = new StanzaNode.build("x", FORM_NS).add_self_xmlns().put_attribute("type", "form")
                        .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "FORM_TYPE")
                                .put_attribute("type", "hidden").put_node(new StanzaNode.build("value", FORM_NS)
                                        .put_node(new StanzaNode.text(PUBSUB_NS + "#node_config"))))
                        .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "pubsub#access_model")
                                .put_node(new StanzaNode.build("value", FORM_NS).put_node(new StanzaNode.text("open"))))
                        .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "pubsub#persist_items")
                                .put_node(new StanzaNode.build("value", FORM_NS).put_node(new StanzaNode.text("true"))))
                        .put_node(new StanzaNode.build("field", FORM_NS).put_attribute("var", "pubsub#max_items")
                                .put_node(new StanzaNode.build("value", FORM_NS).put_node(new StanzaNode.text("1"))));
                respond(node, new StanzaNode.build("pubsub", OWNER_NS).add_self_xmlns()
                        .put_node(new StanzaNode.build("configure", OWNER_NS)
                                .put_attribute("node", OWN_NODE).put_node(form)));
                return;
            }
            respond(node, null);
        }

        private void respond(StanzaNode outgoing, StanzaNode? payload) {
            var request = new Iq.Stanza.from_stanza(outgoing, own_jid);
            var response = new Iq.Stanza.result(request, payload);
            response.from = request.to ?? remote_name;
            response.to = own_jid;
            received_iq_stanza(this, response.stanza);
        }

        internal void stop() { stopped = true; held = null; held_bundle = null; }
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
        internal StreamModule module;
        internal OmemoDecryptor decryptor;
        internal HashSet<int> consumed = new HashSet<int>();
        private Dino.StreamInteractor interactor;
        private string own_public;
        private string own_private;
        private string signed_public;
        private string signed_signature;
        private int other_identity_id;
        private string other_key_record;
        private string other_identity_public;

        internal Fixture(bool known_sender = true, uint32 first_prekey = 101) throws Error {
            temp_dir = DirUtils.make_tmp("dinox-own-bundle-maintenance-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(temp_dir, "app.db"), "bundle-maintenance-test");
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
            // An overlapping key ID in the same database must not be touched
            // by the receiving account's maintenance.
            Store other = setup_test_store_context(context);
            other_identity_public = Base64.encode(other.identity_key_pair.public.serialize());
            other_identity_id = (int) db.identity.upsert()
                    .value(db.identity.account_id, 777, true)
                    .value(db.identity.device_id, 33)
                    .value(db.identity.identity_key_private_base64, Base64.encode(other.identity_key_pair.private.serialize()))
                    .value(db.identity.identity_key_public_base64, other_identity_public)
                    .perform_checked();
            other.pre_key_store = new BackedPreKeyStore(db, other_identity_id);
            PreKeyRecord overlapping;
            throw_by_code(PreKeyRecord.create(out overlapping, 200, context.generate_key_pair()));
            other.store_pre_key(overlapping);
            other_key_record = Base64.encode((!) other.pre_key_store.load_pre_key(200));
            if (known_sender) {
                db.identity_meta.upsert()
                        .value(db.identity_meta.identity_id, identity_id, true)
                        .value(db.identity_meta.address_name, alice_jid.to_string(), true)
                        .value(db.identity_meta.device_id, 11, true)
                        .value(db.identity_meta.identity_key_public_base64, Base64.encode(alice.identity_key_pair.public.serialize()))
                        .value(db.identity_meta.trust_level, TrustLevel.TRUSTED)
                        .value(db.identity_meta.now_active, true)
                        .value(db.identity_meta.supports_omemo1, true)
                        .perform_checked();
            }
            alice_address = new Address(alice_jid.to_string(), 11);
            bob_address = new Address(account.bare_jid.to_string(), 22);
            SignedPreKeyRecord signed = context.generate_signed_pre_key(bob.identity_key_pair, 7);
            bob.store_signed_pre_key(signed);
            var records = context.generate_pre_keys(first_prekey, 100);
            foreach (PreKeyRecord record in records) bob.store_pre_key(record);
            Bundle initial = bundle(signed, records);
            own_public = Base64.encode(bob.identity_key_pair.public.serialize());
            own_private = Base64.encode(bob.identity_key_pair.private.serialize());
            signed_public = Base64.encode(signed.key_pair.public.serialize());
            signed_signature = Base64.encode(signed.signature);
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            var trust = new TrustManager(interactor, db);
            decryptor = new OmemoDecryptor(account, interactor, trust, db, bob);
            stream = new FakePep(account.bare_jid, initial);
            prepare_stream(stream);
            module = new StreamModule(bob);
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
                    Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Maintenance Test");
            target.add_module(iq); target.add_module(messages);
            target.add_module(pubsub); target.add_module(disco);
            disco.attach(target); iq.attach(target); messages.attach(target); pubsub.attach(target);
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid;
            bind.finished = true;
            target.add_flag(bind);
        }

        internal FakePep replace_stream(Gate gate) throws Error {
            FakePep old = stream;
            module.detach(old);
            stream = new FakePep(account.bare_jid, old.accepted);
            stream.gate = gate;
            prepare_stream(stream);
            stream.add_module(module);
            module.attach(stream);
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            return old;
        }

        private Bundle bundle(SignedPreKeyRecord signed, Set<PreKeyRecord> records) {
            var node = new StanzaNode.build("bundle", OMEMO_NS)
                    .put_node(new StanzaNode.build("identityKey", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(bob.identity_key_pair.public.serialize()))))
                    .put_node(new StanzaNode.build("signedPreKeyPublic", OMEMO_NS).put_attribute("signedPreKeyId", signed.id.to_string())
                            .put_node(new StanzaNode.text(Base64.encode(signed.key_pair.public.serialize()))))
                    .put_node(new StanzaNode.build("signedPreKeySignature", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(signed.signature))));
            var prekeys = new StanzaNode.build("prekeys", OMEMO_NS);
            foreach (PreKeyRecord record in records) {
                prekeys.put_node(new StanzaNode.build("preKeyPublic", OMEMO_NS).put_attribute("preKeyId", record.id.to_string())
                        .put_node(new StanzaNode.text(Base64.encode(record.key_pair.public.serialize()))));
            }
            return new Bundle(node.put_node(prekeys));
        }

        internal CiphertextMessage fresh_packet(Bundle advertised, int key_id) throws Error {
            Bundle.PreKey? selected = null;
            foreach (Bundle.PreKey key in advertised.pre_keys) if (key.key_id == key_id) selected = key;
            if (selected == null) throw new IOError.NOT_FOUND("Requested test key is not advertised");
            alice.create_session_builder(bob_address).process_pre_key_bundle(create_pre_key_bundle(22, 22,
                    ((!) selected).key_id, ((!) selected).key, advertised.signed_pre_key_id,
                    advertised.signed_pre_key, advertised.signed_pre_key_signature, advertised.identity_key));
            return next_packet();
        }

        internal CiphertextMessage next_packet() throws Error {
            uint8[] key = new uint8[32];
            context.randomize(key);
            return alice.create_session_cipher(bob_address).encrypt(key);
        }

        internal bool receive(CiphertextMessage packet, bool archived = false) {
            var data = new Xmpp.Xep.Omemo.EncryptionData(11);
            data.iv = new uint8[12];
            data.add_device_key(22, packet.serialized, packet.type == CiphertextType.PREKEY);
            var stanza = new MessageStanza();
            stanza.from = alice_jid;
            stanza.to = account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.stanza.put_node(data.get_encrypted_node());
            if (archived) stanza.add_flag(new MessageArchiveManagement.MessageFlag(account.bare_jid, null, "archived-test", null));
            var message = new Dino.Entities.Message("encrypted") {
                account = account, counterpart = alice_jid, ourpart = account.bare_jid,
                direction = Dino.Entities.Message.DIRECTION_RECEIVED,
                type_ = Dino.Entities.Message.Type.CHAT, time = new DateTime.now_utc()
            };
            return decryptor.decrypt_message(message, stanza, new Conversation(alice_jid, account, Conversation.Type.CHAT));
        }

        internal void consume(Bundle advertised, int key_id, bool archived = false) throws Error {
            fail_if_not(bob.contains_pre_key(key_id), "test consumption must start with a locally available key");
            CiphertextMessage packet = fresh_packet(advertised, key_id);
            fail_if_not(packet.type == CiphertextType.PREKEY);
            fail_if_not(receive(packet, archived), "a genuine PREKEY must decrypt through the application commit hook");
            fail_if(bob.contains_pre_key(key_id), "successful native receive must consume the one-time key");
            consumed.add(key_id);
        }

        internal bool current_bundle_ready() {
            if (stream.accepted.pre_keys.size != 100) return false;
            foreach (Bundle.PreKey key in stream.accepted.pre_keys) if (consumed.contains(key.key_id)) return false;
            return stream.held == null;
        }

        internal void verify_bundle() throws Error {
            Bundle published = stream.accepted;
            fail_if_not_eq_int(published.pre_keys.size, 100);
            var ids = new HashSet<int>();
            foreach (Bundle.PreKey key in published.pre_keys) {
                fail_if_not(ids.add(key.key_id), "published IDs must be unique");
                fail_if(consumed.contains(key.key_id), "a consumed key must not remain advertised");
                fail_if_not(bob.contains_pre_key(key.key_id), "every advertised key must still exist locally");
                fail_if(key.key == null || bob.load_pre_key(key.key_id).key_pair.public.compare(key.key) != 0,
                        "advertised public key bytes must match the native store");
            }
            fail_if_not_eq_int(published.signed_pre_key_id, 7);
            fail_if(published.identity_key == null || Base64.encode(published.identity_key.serialize()) != own_public,
                    "maintenance must preserve the public identity");
            fail_if_not(Base64.encode(bob.identity_key_pair.private.serialize()) == own_private,
                    "maintenance must preserve the private identity");
            fail_if(published.signed_pre_key == null || Base64.encode(published.signed_pre_key.serialize()) != signed_public,
                    "maintenance must preserve the existing valid signed prekey");
            fail_if(published.signed_pre_key_signature == null || Base64.encode(published.signed_pre_key_signature) != signed_signature);
            fail_if_not_eq_int((int) bob.local_registration_id, 22);
            fail_if_not_eq_int(stream.own_devicelist_publishes, 0);
            fail_if_not_eq_int(stream.messages, 0, "own maintenance must not send peer repair transports");
            Row? other_key = db.pre_key.select().with(db.pre_key.identity_id, "=", other_identity_id)
                    .with(db.pre_key.pre_key_id, "=", 200).single().iterator().get_next_checked();
            fail_if(other_key == null || ((!) other_key)[db.pre_key.record_base64] != other_key_record,
                    "maintenance must preserve another account's overlapping prekey");
            Row? other_identity = db.identity.select().with(db.identity.id, "=", other_identity_id)
                    .single().iterator().get_next_checked();
            fail_if(other_identity == null || ((!) other_identity)[db.identity.identity_key_public_base64] != other_identity_public ||
                    ((!) other_identity)[db.identity.device_id] != 33 || ((!) other_identity)[db.identity.pre_key_high_watermark] != 200,
                    "maintenance must preserve another account's identity, device ID and watermark");
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

    private static int highest(Bundle bundle) {
        int value = 0;
        foreach (Bundle.PreKey key in bundle.pre_keys) value = int.max(value, key.key_id);
        return value;
    }

    private void test_burst_and_gates() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            Bundle original = f.stream.accepted;
            f.consume(original, 200);
            f.consume(original, 199, true);
            f.consume(original, 198, true);
            string session_after_burst = Base64.encode((!) f.bob.session_store.load_session(f.alice_address));
            if (!wait_until(() => f.current_bundle_ready(), "real PREKEY burst must refresh fake PEP")) return;
            fail_if_not_eq_int(f.stream.own_fetches, 1, "the burst must coalesce into one own bundle fetch");
            fail_if_not_eq_int(f.stream.publishes, 1, "the burst must coalesce into one own publication");
            f.verify_bundle();
            fail_if_not(session_after_burst == Base64.encode((!) f.bob.session_store.load_session(f.alice_address)),
                    "own bundle maintenance must not reset the authenticated peer session");
            int publications = f.stream.publishes;
            CiphertextMessage repeated = f.next_packet();
            fail_if_not(repeated.type == CiphertextType.PREKEY, "the same unacknowledged session must send another PREKEY envelope");
            fail_if_not(f.receive(repeated));
            settle();
            fail_if_not_eq_int(f.stream.publishes, publications, "a matching-session repeat must not report another consumption");
            int replacement = highest(f.stream.accepted);
            fail_if(replacement <= 200, "the updated bundle must contain replacement keys");
            f.consume(f.stream.accepted, replacement);
            if (!wait_until(() => f.current_bundle_ready(), "a replacement key from fake PEP must support real receive")) return;
            f.verify_bundle();
            f.close(); fixture = null;

            foreach (Gate gate in new Gate[]{Gate.GET, Gate.PUBLISH, Gate.CONFIG_GET, Gate.CONFIG_SET}) {
                fixture = new Fixture(); f = (!) fixture;
                original = f.stream.accepted;
                f.stream.gate = gate;
                f.stream.conflict_next_publish = gate == Gate.CONFIG_GET || gate == Gate.CONFIG_SET;
                f.consume(original, 200);
                if (!wait_until(() => f.stream.held != null, "configured fake PEP IQ boundary must be held")) return;
                int before = f.stream.publishes;
                f.consume(original, 199, true);
                settle();
                if (gate == Gate.GET || gate == Gate.PUBLISH) {
                    fail_if_not_eq_int(f.stream.publishes, before,
                            "a newer publication must not overtake a held GET or publish acknowledgement");
                }
                f.stream.release();
                if (!wait_until(() => f.current_bundle_ready(), "consumption during a held IQ must finish with a current bundle")) return;
                for (int i = before; i < f.stream.snapshots.size; i++) {
                    foreach (Bundle.PreKey key in f.stream.snapshots[i].pre_keys) {
                        fail_if(key.key_id == 199 || key.key_id == 200,
                                "a newer publication must never resend the keys consumed before its write");
                    }
                }
                f.verify_bundle();
                f.close(); fixture = null;
            }

        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_retry() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.stream.fail_next_publish = true;
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                    "*own bundle PubSub publish failed*service-unavailable*retrying in 30 seconds*");
            f.consume(f.stream.accepted, 200);
            if (!wait_until(() => f.stream.sent != null, "failed publication must retain a prepared bundle")) return;
            settle(50);
            GLib.Test.assert_expected_messages();
            Bundle failed = (!) f.stream.sent;
            int spent_highest = highest(failed);
            fail_if(spent_highest <= 200);
            f.consume(failed, spent_highest);
            int requests = f.stream.own_fetches;
            settle();
            fail_if_not_eq_int(f.stream.own_fetches, requests, "consumption must not bypass the existing error backoff");
            f.module.retry_pending_own_bundle_publish.begin(f.stream, f.account.bare_jid, f.module.attachment_generation);
            if (!wait_until(() => f.current_bundle_ready(), "the real retry callback must reconcile its stale snapshot")) return;
            fail_if(f.stream.own_fetches <= requests, "stale retry must fetch and rebuild instead of resending saved XML");
            fail_if(highest(f.stream.accepted) <= spent_highest,
                    "retry must issue a new ID above the consumed highest reserved ID");
            f.verify_bundle();
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_rollback() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(false);
            var f = (!) fixture;
            uint8[]? before_key = f.bob.pre_key_store.load_pre_key(200);
            uint8[]? before_session = f.bob.session_store.load_session(f.alice_address);
            int native_deletions = 0;
            f.bob.pre_key_store.pre_key_deleted.connect((key) => native_deletions++);
            f.db.exec("CREATE TRIGGER reject_authenticated_device BEFORE INSERT ON identity_meta " +
                    "BEGIN SELECT RAISE(ABORT, 'injected authenticated metadata failure'); END");
            CiphertextMessage packet = f.fresh_packet(f.stream.accepted, 200);
            fail_if(f.receive(packet), "metadata persistence failure must fail the PREKEY transaction");
            fail_if_not_eq_int(native_deletions, 1, "the injected failure must occur after native one-time-key consumption");
            fail_if_not(f.bob.is_persistence_ready, "successful rollback must preserve store readiness");
            fail_if_not(before_key != null && f.bob.pre_key_store.load_pre_key(200) != null &&
                    Base64.encode((!) before_key) == Base64.encode((!) f.bob.pre_key_store.load_pre_key(200)),
                    "SQL rollback must restore the consumed key in RAM");
            var reopened_keys = new BackedPreKeyStore(f.db, f.identity_id);
            fail_if_not(reopened_keys.contains_pre_key(200), "SQL rollback must preserve the key for a reopened store");
            fail_if_not(Base64.encode((!) reopened_keys.load_pre_key(200)) == Base64.encode((!) before_key),
                    "reopened key bytes must match the pre-transaction state");
            fail_if(before_session != null || f.bob.session_store.load_session(f.alice_address) != null,
                    "a failed first session must not survive in RAM");
            var reopened_sessions = new BackedSessionStore(f.db, f.identity_id);
            fail_if(reopened_sessions.load_session(f.alice_address) != null,
                    "a failed first session must not survive in SQL");
            fail_if(f.bob.identity_key_store.load_identity(f.alice_address) != null,
                    "failed metadata persistence must restore the previously unknown peer identity");
            fail_if(f.db.identity_meta.get_device_checked(f.identity_id, f.alice_jid.to_string(), 11) != null);
            f.db.exec("DROP TRIGGER reject_authenticated_device");
            settle(500);
            fail_if_not_eq_int(f.stream.own_fetches, 0, "rolled-back native deletion must not schedule own bundle fetch");
            fail_if_not_eq_int(f.stream.publishes, 0, "rolled-back native deletion must not publish own bundle");
            fail_if_not_eq_int(f.stream.own_devicelist_publishes, 0);
            fail_if_not_eq_int(f.stream.messages, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }

    private void test_stream_replacement() {
        Fixture? fixture = null;
        FakePep? old = null;
        try {
            fixture = new Fixture();
            var f = (!) fixture;
            f.stream.gate = Gate.GET;
            f.consume(f.stream.accepted, 200);
            if (!wait_until(() => f.stream.held != null, "old stream must hold a genuine maintenance query")) return;
            old = f.replace_stream(Gate.GET);
            if (!wait_until(() => f.stream.held != null, "dirty consumption must survive detach and query the replacement stream")) return;
            string request_key = f.account.bare_jid.to_string() + ":22";
            fail_if_not(f.module.active_bundle_requests.contains(request_key));
            ((!) old).release();
            settle();
            fail_if_not_eq_int(((!) old).publishes, 0, "the old reply must not publish on the old stream");
            fail_if_not(f.module.active_bundle_requests.contains(request_key),
                    "late old cleanup must not remove the replacement stream's identical request key");
            fail_if_not_eq_int(f.stream.publishes, 0, "the replacement query must remain held until its own reply");
            f.stream.release();
            if (!wait_until(() => f.current_bundle_ready(), "replacement reply must finish the preserved dirty reconciliation")) return;
            f.verify_bundle();
            fail_if_not_eq_int(((!) old).own_devicelist_publishes, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (old != null) {
                ((!) old).get_module<Iq.Module>(Iq.Module.IDENTITY).detach((!) old);
                ((!) old).stop();
            }
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_startup_missing_key() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(true, 1);
            var f = (!) fixture;
            // Reproduce an old profile whose published bundle still advertises
            // a key deleted before the new consume-to-publish hook existed.
            f.bob.pre_key_store.delete_pre_key(50);
            f.consumed.add(50);
            f.bob.pre_key_store = new BackedPreKeyStore(f.db, f.identity_id);
            fail_if(f.bob.contains_pre_key(50));
            settle();
            fail_if_not_eq_int(f.stream.own_fetches, 0,
                    "preexisting missing state must not need a new successful decrypt trigger");

            bool loaded = false;
            ArrayList<int32>? devices = null;
            // This is the production post-negotiation entry used by Manager.
            f.module.request_user_devicelist.begin(f.stream, f.account.bare_jid, (obj, res) => {
                devices = f.module.request_user_devicelist.end(res);
                loaded = true;
            });
            if (!wait_until(() => loaded && f.current_bundle_ready(),
                    "startup must replace an advertised missing key before releasing readiness")) return;
            fail_if(devices == null || !((!) devices).contains(22));
            fail_if_not_eq_int(f.stream.own_devicelist_fetches, 1);
            fail_if_not_eq_int(f.stream.own_fetches, 1);
            fail_if_not_eq_int(f.stream.publishes, 1);
            fail_if_not_eq_int(highest(f.stream.accepted), 101,
                    "startup repair must allocate above the old bundle's maximum, not recreate key 50");
            f.verify_bundle();

            loaded = false;
            f.module.request_user_devicelist.begin(f.stream, f.account.bare_jid, (obj, res) => {
                f.module.request_user_devicelist.end(res);
                loaded = true;
            });
            if (!wait_until(() => loaded, "a reconciled own device list should become ready again")) return;
            settle();
            fail_if_not_eq_int(f.stream.publishes, 1,
                    "an unchanged corrected bundle must not cause a republish loop");
            f.verify_bundle();
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (fixture != null) ((!) fixture).close(); }
    }
}

}
