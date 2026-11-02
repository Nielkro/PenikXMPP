using Dino.Entities;
using Gee;
using Omemo;
using Xmpp;

namespace Omemo.Test {

// These tests use real Signal ratchets, the normal Manager bundle callback,
// and the public IQ send/receive pipeline. They do not open capture devices or
// claim to exercise a native media call or an external client.
class CallFingerprintTest : Gee.TestCase {
    private const string LEGACY = "eu.siacs.conversations.axolotl";
    private const string VERIFY = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification";
    private const string JINGLE = "urn:xmpp:jingle:1";
    private const string ICE = "urn:xmpp:jingle:transports:ice-udp:1";
    private const string DTLS = "urn:xmpp:jingle:apps:dtls:0";
    private const string MUJI = "urn:xmpp:jingle:muji:0";
    private const string AUDIO_FP = "01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF";
    private const string VIDEO_FP = "FE:DC:BA:98:76:54:32:10:FE:DC:BA:98:76:54:32:10:FE:DC:BA:98:76:54:32:10:FE:DC:BA:98:76:54:32:10";

    internal CallFingerprintTest() {
        base("CallFingerprint");
        add_test("warm_direct_audio_fingerprint_native_decrypts", () => test_delivery(false, false, false));
        add_test("warm_direct_audio_video_fingerprints_native_decrypt", () => test_delivery(false, true, false));
        add_test("cold_direct_audio_waits_for_real_bundle", () => test_delivery(true, false, false));
        add_test("cold_direct_audio_video_wait_for_real_bundle", () => test_delivery(true, true, false));
        add_test("cold_muji_peer_waits_for_real_bundle", () => test_delivery(true, true, true));
        add_test("attribute_muji_device_selects_native_verification", () => test_muji_device_dialect(false));
        add_test("matching_dual_muji_devices_keep_waiting_offer", () => test_muji_device_dialect(true));
        add_test("muji_presence_advertises_both_device_dialects_once", test_muji_device_publication);
        add_test("invalid_muji_device_cannot_fall_back_to_plain_dtls", test_invalid_muji_device);
        add_test("conflicting_muji_devices_cannot_select_either_key", test_conflicting_muji_devices);
        add_test("duplicate_muji_device_children_are_rejected", test_duplicate_muji_devices);
        add_test("duplicate_muji_elements_are_rejected", test_duplicate_muji_elements);
        add_test("malformed_nested_muji_device_cannot_use_attribute_fallback", test_malformed_nested_muji_device);
        add_test("invalid_muji_update_cancels_pending_and_new_offers", test_invalid_muji_update);
        add_test("muji_without_device_retains_optional_plain_dtls", test_muji_without_device);
        add_test("fresh_outgoing_peer_discovers_and_decrypts_under_blind_trust", () => test_outgoing_fresh(true));
        add_test("fresh_outgoing_peer_without_blind_trust_fails_closed", () => test_outgoing_fresh(false));
        add_test("ordinary_dtls_peer_remains_plain_fingerprint", test_plain_peer);
        add_test("denied_bundle_has_local_error_and_no_wire_offer", test_denied);
        add_test("cancelled_bundle_wait_never_writes_late_offer", test_cancelled);
        add_test("detached_stream_never_writes_late_offer", test_detached);
        add_test("discarded_account_store_fails_before_accessing_removed_keys", test_discarded_store);
        add_test("late_old_stream_detach_preserves_reused_module_filters", test_late_detach);
        add_test("late_old_stream_detach_preserves_new_cold_session_demand", test_late_detach_cold);
        add_test("changed_advertised_device_never_writes_obsolete_offer", test_changed_device);
        add_test("same_sid_other_peer_does_not_select_device", test_same_sid_other_peer);
        add_test("muji_full_resources_keep_distinct_device_bindings", test_muji_resources);
        add_test("transport_info_fingerprint_is_also_encrypted", test_transport_info);
        add_test("second_content_failure_cannot_write_partial_offer", test_atomic_contents);
        add_test("muji_unavailable_cancels_waiting_offer", test_muji_unavailable);
        add_test("departed_muji_member_cannot_downgrade_pinned_sid", test_departed_muji_pin);
        add_test("terminated_call_cannot_send_late_offer", test_terminated);
        add_test("adopted_direct_leg_keeps_its_device_binding", test_adopted_leg);
        add_test("rejected_key_while_waiting_fails_closed", test_rejected_key);
        add_test("unknown_key_without_acceptance_fails_closed", test_unknown_key);
        add_test("changed_identity_while_waiting_fails_closed", test_changed_identity);
        add_test("own_identity_changed_while_waiting_fails_closed", test_changed_own_identity);
        add_test("native_and_metadata_identity_mismatch_fails_closed", test_metadata_mismatch);
        add_test("incoming_first_plain_offer_remains_optional", test_incoming_plain_first);
        add_test("incoming_encrypted_pin_rejects_later_plain", test_incoming_downgrade);
        add_test("incoming_encrypted_pin_rejects_other_device", test_incoming_other_device);
        add_test("fresh_incoming_sender_uses_blind_trust_after_authentication", () => test_incoming_fresh(true, false));
        add_test("fresh_incoming_sender_without_blind_trust_is_rejected", () => test_incoming_fresh(false, false));
        add_test("list_only_incoming_sender_uses_blind_trust_after_authentication", () => test_incoming_fresh(true, true));
        add_test("list_only_incoming_sender_without_blind_trust_is_rejected", () => test_incoming_fresh(false, true));
        add_test("unknown_session_timeout_never_sends_plain_offer", test_timeout);
    }

    private class Result : Object {
        internal bool done = false;
        internal bool error = false;
        internal bool local = false;
        internal int completions = 0;
    }

    private class WireStream : XmppStream {
        internal ArrayList<StanzaNode> written = new ArrayList<StanzaNode>();
        internal ArrayList<StanzaNode> bundles = new ArrayList<StanzaNode>();
        internal HashMap<string, ArrayList<int>> device_lists = new HashMap<string, ArrayList<int>>();

        internal WireStream() throws InvalidJidError {
            base(new Jid("example.test"));
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated call fingerprint proof has no network reader");
        }

        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            written.add(node);
            if (node.name != "iq" || node.get_attribute("type") != Iq.Stanza.TYPE_GET &&
                    node.get_attribute("type") != Iq.Stanza.TYPE_SET) return;
            StanzaNode? pubsub = node.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
            StanzaNode? items = pubsub != null
                ? ((!) pubsub).get_subnode("items", Xmpp.Xep.Pubsub.NS_URI) : null;
            string? requested = items != null ? ((!) items).get_attribute("node") : null;
            if (requested != null && ((!) requested).has_prefix(LEGACY + ".bundles:")) {
                bundles.add(node);
                return;
            }
            // A peer ACK is not evidence of decryptability; each positive test
            // separately decrypts the actual encrypted wire fingerprint.
            StanzaNode response = iq_result(node);
            if (pubsub != null && requested != null) {
                StanzaNode response_items = new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                    .put_attribute("node", (!) requested);
                if (requested == LEGACY + ".devicelist") {
                    StanzaNode list = new StanzaNode.build("list", LEGACY);
                    ArrayList<int>? devices = device_lists[node.get_attribute("to") ?? ""];
                    if (devices != null) foreach (int id in (!) devices) {
                        list.put_node(new StanzaNode.build("device", LEGACY).put_attribute("id", id.to_string()));
                    }
                    response_items.put_node(new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                        .put_attribute("id", "current").put_node(list));
                }
                response.put_node(new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI)
                    .put_node(response_items));
            }
            Idle.add(() => { received_iq_stanza(this, response); return Source.REMOVE; });
        }

        internal void publish_device(Device device) {
            string jid = device.account.bare_jid.to_string();
            if (!device_lists.has_key(jid)) device_lists[jid] = new ArrayList<int>();
            device_lists[jid].add((int) device.store.local_registration_id);
        }

        internal ArrayList<StanzaNode> offers() {
            var result = new ArrayList<StanzaNode>();
            foreach (StanzaNode node in written) {
                if (node.get_attribute("type") == Iq.Stanza.TYPE_SET &&
                        node.get_subnode("jingle", JINGLE) != null) result.add(node);
            }
            return result;
        }

        internal void answer_bundle(Device device, bool denied = false) throws Error {
            StanzaNode? request = null;
            foreach (StanzaNode node in bundles) {
                if (node.get_attribute("to") == device.account.bare_jid.to_string()) request = node;
            }
            if (request == null) throw new IOError.FAILED("the real send hook did not request the native peer bundle");
            StanzaNode response;
            if (denied) {
                response = new StanzaNode.build("iq", "jabber:client")
                    .put_attribute("type", Xmpp.Stanza.TYPE_ERROR)
                    .put_attribute("id", ((!) request).get_attribute("id"))
                    .put_attribute("from", device.account.bare_jid.to_string())
                    .put_attribute("to", ((!) request).get_attribute("from") ?? "alice@example.test")
                    .put_node(new ErrorStanza.build(ErrorStanza.TYPE_AUTH,
                        ErrorStanza.CONDITION_FORBIDDEN, null, null).error_node);
            } else {
                response = iq_result((!) request);
                response.put_node(new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI)
                    .put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                        .put_attribute("node", LEGACY + ".bundles:" + device.store.local_registration_id.to_string())
                        .put_node(new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                            .put_attribute("id", "current").put_node(device.bundle))));
            }
            received_iq_stanza(this, response);
            drain();
        }
    }

    private class CaptureHandler : Object, Iq.Handler {
        internal ArrayList<Iq.Stanza> accepted = new ArrayList<Iq.Stanza>();
        public async void on_iq_get(XmppStream stream, Iq.Stanza iq) { accepted.add(iq); }
        public async void on_iq_set(XmppStream stream, Iq.Stanza iq) { accepted.add(iq); }
    }

    private class Device : Object {
        internal string directory;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Dino.StreamInteractor interactor;
        internal Account account;
        internal Store store;
        internal Dino.Plugins.Omemo.TrustManager trust;
        internal Context context;
        internal int identity_id;
        internal StanzaNode bundle;

        internal Device(string parent, string name, string bare_jid,
                int device_id, Context context) throws Error {
            this.context = context;
            directory = Path.build_filename(parent, name);
            DirUtils.create_with_parents(directory, 0700);
            app_db = new Dino.Database(Path.build_filename(directory, "app.db"), "call-fingerprint-test-only");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(directory, "omemo.db"));
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            account = new Account(new Jid(bare_jid), "test-only");
            account.persist(app_db);
            store = setup_test_store_context(context);
            store.identity_key_store.local_registration_id = (uint32) device_id;
            identity_id = (int) db.identity.insert()
                .value(db.identity.account_id, account.id)
                .value(db.identity.device_id, device_id)
                .value(db.identity.identity_key_private_base64,
                    Base64.encode(store.identity_key_store.identity_key_private.get_data()))
                .value(db.identity.identity_key_public_base64,
                    Base64.encode(store.identity_key_store.identity_key_public.get_data()))
                .perform();
            trust = new Dino.Plugins.Omemo.TrustManager(interactor, db);
            remember(this);
            bundle = make_bundle(context, store, device_id + 1000, device_id + 2000);
        }

        internal void remember(Device other) {
            db.identity_meta.upsert()
                .value(db.identity_meta.identity_id, identity_id, true)
                .value(db.identity_meta.address_name, other.account.bare_jid.to_string(), true)
                .value(db.identity_meta.device_id, (int) other.store.local_registration_id, true)
                .value(db.identity_meta.identity_key_public_base64,
                    Base64.encode(other.store.identity_key_store.identity_key_public.get_data()))
                .value(db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.TRUSTED)
                .value(db.identity_meta.now_active, true)
                .value(db.identity_meta.supports_omemo1, true)
                .value(db.identity_meta.supports_omemo2, false)
                .perform();
        }

        internal void close() {
            db.close();
            app_db.close();
            remove_directory(directory);
        }
    }

    private class Fixture : Object {
        internal string directory;
        internal Context context;
        internal Device alice;
        internal Device bob;
        internal Device carol;
        internal WireStream stream;
        internal Iq.Module iq;
        internal Dino.Plugins.Omemo.StreamModule omemo;
        internal Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule verification;
        internal Dino.Plugins.Omemo.Manager manager;
        internal CaptureHandler received = new CaptureHandler();
        internal bool attached = true;
        internal Jid peer;
        internal Jid room;

        internal Fixture() throws Error {
            directory = DirUtils.make_tmp("dinox-call-fingerprint-XXXXXX");
            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) throw new IOError.FAILED("native OMEMO unavailable");
            context = Dino.Plugins.Omemo.Plugin.get_context();
            alice = new Device(directory, "alice", "alice@example.test", 101, context);
            bob = new Device(directory, "bob", "bob@example.test", 202, context);
            carol = new Device(directory, "carol", "carol@example.test", 303, context);
            alice.remember(bob);
            alice.remember(carol);
            bob.remember(alice);
            carol.remember(alice);
            peer = bob.account.bare_jid.with_resource("phone");
            room = new Jid("private-room@conference.example.test");

            // Normal account initialization connects Manager.bundle_ready and
            // installs persistent stores. Only the controlled network is fake.
            _force_class_init(typeof(Dino.MessageStorage));
            _force_class_init(typeof(Dino.FileTransferStorage));
            _force_class_init(typeof(Dino.EntityInfo));
            _force_class_init(typeof(Dino.RosterManager));
            _force_class_init(typeof(Dino.Calls));
            _force_class_init(typeof(Dino.ConversationManager));
            _force_class_init(typeof(Dino.PresenceManager));
            _force_class_init(typeof(Dino.MucManager));
            Dino.MessageStorage.start(alice.interactor, alice.app_db);
            Dino.FileTransferStorage.start(alice.interactor, alice.app_db);
            Dino.EntityInfo.start(alice.interactor, alice.app_db);
            Dino.RosterManager.start(alice.interactor, alice.app_db);
            Dino.Calls.start(alice.interactor, alice.app_db);
            Dino.ConversationManager.start(alice.interactor, alice.app_db);
            Dino.PresenceManager.start(alice.interactor, alice.app_db);
            Dino.MucManager.start(alice.interactor);
            var encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(Account.hash_func, Account.equals_func);
            var encryptor = new Dino.Plugins.Omemo.OmemoEncryptor(alice.account, alice.trust, alice.store);
            encryptors[alice.account] = encryptor;
            manager = Dino.Plugins.Omemo.Manager.start(alice.interactor, alice.db, alice.trust, encryptors);
            manager.auto_publish_own_device_lists = false;
            omemo = new Dino.Plugins.Omemo.StreamModule(alice.store);
            omemo.auto_publish_own_device_list = false;
            ulong initialize = alice.interactor.module_manager.initialize_account_modules.connect((account, modules) => {
                if (account.equals(alice.account)) modules.add(omemo);
            });
            alice.interactor.module_manager.initialize(alice.account);
            SignalHandler.disconnect(alice.interactor.module_manager, initialize);
            alice.interactor.account_added(alice.account);
            // Account initialization replaces the temporary pre-key stores.
            // Incoming tests must target a key in the actual backed store.
            alice.bundle = make_bundle(context, alice.store, 5101, 6101);

            stream = new WireStream();
            stream.publish_device(alice);
            stream.publish_device(bob);
            stream.publish_device(carol);
            iq = new Iq.Module();
            var messages = new MessageModule();
            var presence = new Presence.Module();
            var discovery = new Xmpp.Xep.ServiceDiscovery.Module();
            var pubsub = new Xmpp.Xep.Pubsub.Module();
            verification = new Dino.Plugins.Omemo.DtlsSrtpVerificationDraft.StreamModule(alice.account, alice.db);
            stream.add_module(iq);
            stream.add_module(messages);
            stream.add_module(presence);
            stream.add_module(discovery);
            stream.add_module(pubsub);
            stream.add_module(omemo);
            stream.add_module(encryptor);
            stream.add_module(new Dino.Plugins.Omemo.OmemoDecryptor(alice.account, alice.interactor, alice.trust, alice.db, alice.store));
            stream.add_module(new Xmpp.Xep.Jingle.Module());
            stream.add_module(verification);
            var bind = new Bind.Flag();
            bind.my_jid = alice.account.full_jid;
            bind.finished = true;
            stream.add_flag(bind);
            stream.add_flag(new Xmpp.Xep.ServiceDiscovery.Flag());
            stream.add_flag(new Xmpp.Xep.Jingle.Flag());
            iq.attach(stream);
            messages.attach(stream);
            presence.attach(stream);
            omemo.attach(stream);
            verification.attach(stream);
            iq.register_for_namespace(JINGLE, received);
            alice.interactor.connection_manager.set_connected_stream_for_tests(alice.account, stream);
        }

        internal void advertise(string sid, Jid? from = null, int device_id = 202) {
            var message = new MessageStanza(Uuid.string_random());
            message.from = from ?? peer;
            message.to = alice.account.full_jid;
            message.type_ = MessageStanza.TYPE_CHAT;
            message.stanza.put_node(new StanzaNode.build("proceed", Xmpp.Xep.JingleMessageInitiation.NS_URI)
                .put_attribute("id", sid)
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", device_id.to_string())));
            stream.received_message_stanza(stream, message.stanza);
            drain();
        }

        internal void muji_presence(Jid real_jid, string nick, int device_id, bool unavailable = false) throws InvalidJidError {
            muji_advertisement(real_jid, nick, unavailable ? null : new StanzaNode.build("muji", MUJI)
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", device_id.to_string())), unavailable);
        }

        internal void muji_advertisement(Jid real_jid, string nick, StanzaNode? muji,
                bool unavailable = false, StanzaNode? extra_muji = null) throws InvalidJidError {
            StanzaNode node = new StanzaNode.build("presence", "jabber:client")
                .put_attribute("from", room.with_resource(nick).to_string())
                .put_attribute("to", alice.account.full_jid.to_string());
            if (unavailable) node.put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE);
            if (muji != null) node.put_node((!) muji);
            if (extra_muji != null) node.put_node((!) extra_muji);
            node.put_node(new StanzaNode.build("x", "http://jabber.org/protocol/muc#user")
                .put_node(new StanzaNode.build("item", "http://jabber.org/protocol/muc#user")
                    .put_attribute("jid", real_jid.to_string())
                    .put_attribute("affiliation", "member").put_attribute("role", "participant")));
            stream.received_presence_stanza(stream, node);
            drain();
        }

        internal void warm(Device recipient, Jid? address_jid = null) throws Error {
            var address = new Address((address_jid ?? recipient.account.bare_jid).bare_jid.to_string(), (int) recipient.store.local_registration_id);
            var bundle = new Dino.Plugins.Omemo.Bundle(recipient.bundle);
            var prekey = bundle.pre_keys[0];
            var native_bundle = create_pre_key_bundle(recipient.store.local_registration_id,
                (int) recipient.store.local_registration_id, (uint32) prekey.key_id,
                (!) prekey.key, bundle.signed_pre_key_id, (!) bundle.signed_pre_key,
                (!) bundle.signed_pre_key_signature, (!) bundle.identity_key);
            try {
                alice.store.create_session_builder(address).process_pre_key_bundle(native_bundle);
            } finally {
                address.device_id = 0;
            }
        }

        internal Result send(StanzaNode jingle, Jid? to = null) {
            var result = new Result();
            var request = new Iq.Stanza.set(jingle) { to = to ?? peer, from = alice.account.full_jid };
            iq.send_iq(stream, request, (_, response) => {
                result.completions++;
                result.done = true;
                result.error = response.is_error();
                result.local = response.locally_failed;
            });
            drain();
            return result;
        }

        internal void detach() {
            if (!attached) return;
            verification.detach(stream);
            omemo.detach(stream);
            iq.detach(stream);
            attached = false;
            drain();
        }

        internal void replace_stream_then_late_detach() throws Error {
            WireStream previous = stream;
            var replacement = new WireStream();
            replacement.device_lists = previous.device_lists;
            foreach (XmppStreamModule module in previous.modules) replacement.add_module(module);
            var bind = new Bind.Flag();
            bind.my_jid = alice.account.full_jid;
            bind.finished = true;
            replacement.add_flag(bind);
            replacement.add_flag(new Xmpp.Xep.ServiceDiscovery.Flag());
            replacement.add_flag(new Xmpp.Xep.Jingle.Flag());
            iq.attach(replacement);
            replacement.get_module<MessageModule>(MessageModule.IDENTITY).attach(replacement);
            replacement.get_module<Presence.Module>(Presence.Module.IDENTITY).attach(replacement);
            omemo.attach(replacement);
            verification.attach(replacement);
            // ModuleManager reuses the exact same module objects across the
            // two stream objects. Old teardown must not remove new filters.
            verification.detach(previous);
            stream = replacement;
            alice.interactor.connection_manager.set_connected_stream_for_tests(alice.account, replacement);
        }

        internal void close() {
            detach();
            manager.forget_pending_messages_for_account(alice.account);
            carol.close();
            bob.close();
            alice.close();
            remove_directory(directory);
        }
    }

    private delegate void FixtureAction(Fixture fixture) throws Error;

    private void run(owned FixtureAction action) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            action((!) fixture);
        } catch (Error error) {
            fail_if_reached("real call fingerprint pipeline proof failed: " + error.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_delivery(bool cold, bool video, bool muji) {
        run((f) => {
            string sid = Uuid.string_random();
            if (muji) f.muji_presence(f.peer, "bob", 202);
            else f.advertise(sid);
            if (!cold) f.warm(f.bob);
            fail_if(cold && f.omemo.has_legacy_session_for_send(f.peer, 202), "cold peer must not already have a session");
            Result result = f.send(offer(sid, video, muji ? f.room : null));
            if (cold) {
                fail_if(result.done, "a cold peer must wait for the actual bundle response");
                fail_if_not_eq_int(f.stream.offers().size, 0, "no plaintext offer while the peer's session is unknown");
                fail_if_not_eq_int(f.stream.bundles.size, 1, "one peer session must require exactly one coalesced bundle IQ");
                f.stream.answer_bundle(f.bob);
            }
            wait_result(result);
            fail_if(result.error, "valid native session preparation must not fail the IQ send");
            fail_if_not_eq_int(f.stream.offers().size, 1, "exactly one original IQ must reach the wire");
            if (f.stream.offers().size != 1) return;
            assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, video);
        });
    }

    private void test_plain_peer() {
        run((f) => {
            Result result = f.send(offer(Uuid.string_random(), true));
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.bundles.size, 0, "ordinary DTLS must not discover OMEMO keys");
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) {
                StanzaNode? jingle = f.stream.offers()[0].get_subnode("jingle", JINGLE);
                if (jingle == null) throw new IOError.FAILED("missing ordinary Jingle offer");
                foreach (StanzaNode content in ((!) jingle).get_subnodes("content", JINGLE)) {
                    StanzaNode? transport = content.get_subnode("transport", ICE);
                    fail_if(transport == null || ((!) transport).get_subnode("fingerprint", DTLS) == null,
                        "ordinary DTLS peer must retain its fingerprint");
                }
            }
        });
    }

    private void test_muji_device_dialect(bool both) {
        run((f) => {
            StanzaNode muji = new StanzaNode.build("muji", MUJI).put_attribute("device", "202");
            if (both) muji.put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202"));
            f.muji_advertisement(f.peer, "bob", muji);
            Result result = f.send(offer(Uuid.string_random(), true, f.room));
            fail_if(result.done, "a supported MUJI device must wait for its real session, never send ordinary DTLS");
            fail_if_not_eq_int(f.stream.offers().size, 0);
            fail_if_not_eq_int(f.stream.bundles.size, 1);
            // A subsequent compatible advertisement must keep the same
            // full-JID binding and outstanding native session request alive.
            f.muji_presence(f.peer, "bob", 202);
            f.stream.answer_bundle(f.bob);
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, true);
        });
    }

    private void test_muji_device_publication() {
        run((f) => {
            var stanza = new Presence.Stanza();
            var muji = new StanzaNode.build("muji", MUJI).put_node(new StanzaNode.build("preparing", MUJI));
            stanza.stanza.put_node(muji);
            Presence.Module presence = f.stream.get_module<Presence.Module>(Presence.Module.IDENTITY);
            presence.pre_send_presence_stanza(f.stream, stanza);
            presence.pre_send_presence_stanza(f.stream, stanza);
            fail_if_not_eq_str(muji.get_attribute("device"), "101");
            fail_if_not_eq_int(muji.get_subnodes("device", VERIFY).size, 1,
                "repeated presence preparation must not duplicate a device advertisement");
            if (muji.get_subnodes("device", VERIFY).size == 1)
                fail_if_not_eq_str(muji.get_subnodes("device", VERIFY)[0].get_attribute("id"), "101");
            fail_if(muji.get_subnode("preparing", MUJI) == null);
            fail_if_not_eq_int(muji.get_attributes_by_ns_uri(MUJI).size, 1);
        });
    }

    private void test_invalid_muji_device() {
        string[] invalid = { "", "0", "-1", "+202", "202junk", " 202", "202 ", "2147483648", "9999999999999999999999999" };
        foreach (string value in invalid) {
            run((f) => {
                f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", value));
                assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
                fail_if_not_eq_int(f.stream.bundles.size, 0, "malformed advertisement must fail before key lookup");
                f.stream.received_iq_stanza(f.stream, incoming(f, offer(Uuid.string_random(), false, f.room)));
                drain();
                fail_if_not_eq_int(f.received.accepted.size, 0, "malformed advertisement must not admit an ordinary fingerprint");
                assert_incoming_error(f);
            });
        }
    }

    private void test_conflicting_muji_devices() {
        run((f) => {
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", "303")
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202")));
            assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
            fail_if_not_eq_int(f.stream.bundles.size, 0);
        });
    }

    private void test_duplicate_muji_devices() {
        run((f) => {
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", "202")
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202"))
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202")));
            assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
            fail_if_not_eq_int(f.stream.bundles.size, 0);
        });
    }

    private void test_duplicate_muji_elements() {
        run((f) => {
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", "202"),
                false, new StanzaNode.build("muji", MUJI).put_attribute("device", "202"));
            assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
            fail_if_not_eq_int(f.stream.bundles.size, 0);
        });
    }

    private void test_malformed_nested_muji_device() {
        foreach (bool both in new bool[] { false, true }) {
            run((f) => {
                var muji = new StanzaNode.build("muji", MUJI)
                    .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202junk"));
                if (both) muji.put_attribute("device", "202");
                f.muji_advertisement(f.peer, "bob", muji);
                assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
                fail_if_not_eq_int(f.stream.bundles.size, 0);
            });
        }
    }

    private void test_invalid_muji_update() {
        run((f) => {
            f.muji_presence(f.peer, "bob", 202);
            Result pending = f.send(offer(Uuid.string_random(), true, f.room));
            fail_if(pending.done);
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", "invalid")
                .put_node(new StanzaNode.build("device", VERIFY).put_attribute("id", "202")));
            f.stream.answer_bundle(f.bob);
            assert_blocked(f, pending);
            assert_blocked(f, f.send(offer(Uuid.string_random(), false, f.room)));
            // A later unambiguous update is eligible again, without changing
            // the peer's trust or accepting an obsolete pending offer.
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI).put_attribute("device", "202"));
            Result current = f.send(offer(Uuid.string_random(), false, f.room));
            // A cancelled waiter does not build a usable session from the old
            // reply; the fresh request must receive its own bundle response.
            if (!current.done) f.stream.answer_bundle(f.bob);
            wait_result(current);
            fail_if(current.error);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, false);
        });
    }

    private void test_muji_without_device() {
        run((f) => {
            // No OMEMO draft advertisement is different from a malformed one.
            f.muji_advertisement(f.peer, "bob", new StanzaNode.build("muji", MUJI));
            Result result = f.send(offer(Uuid.string_random(), false, f.room));
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.bundles.size, 0);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) {
                StanzaNode? transport = f.stream.offers()[0].get_deep_subnode(JINGLE + ":jingle", JINGLE + ":content", ICE + ":transport");
                fail_if(transport == null || ((!) transport).get_subnode("fingerprint", DTLS) == null);
            }
        });
    }

    private void test_outgoing_fresh(bool blind_trust) {
        run((f) => {
            f.alice.db.identity_meta.delete()
                .with(f.alice.db.identity_meta.identity_id, "=", f.alice.identity_id)
                .with(f.alice.db.identity_meta.address_name, "=", f.peer.bare_jid.to_string()).perform();
            f.alice.db.trust.upsert()
                .value(f.alice.db.trust.identity_id, f.alice.identity_id, true)
                .value(f.alice.db.trust.address_name, f.peer.bare_jid.to_string(), true)
                .value(f.alice.db.trust.blind_trust, blind_trust).perform();
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            fail_if_not_eq_int(f.stream.offers().size, 0);
            f.stream.answer_bundle(f.bob);
            if (!blind_trust) {
                assert_blocked(f, result);
                return;
            }
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, true);
        });
    }

    private void test_denied() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to request pubsub items*forbidden*");
            f.stream.answer_bundle(f.bob, true);
            GLib.Test.assert_expected_messages();
            assert_blocked(f, result);
        });
    }

    private void test_cancelled() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            var cancellation = new Cancellable();
            var result = new Result();
            var request = new Iq.Stanza.set(offer(sid, true)) { to = f.peer, from = f.alice.account.full_jid };
            f.iq.send_iq_async.begin(f.stream, request, Priority.DEFAULT, cancellation, (_, response) => {
                result.completions++;
                result.done = true;
                try { f.iq.send_iq_async.end(response); }
                catch (IOError error) { result.error = true; result.local = true; }
            });
            drain();
            fail_if_not_eq_int(f.stream.bundles.size, 1);
            cancellation.cancel();
            assert_blocked(f, result);
            f.stream.answer_bundle(f.bob);
            fail_if_not_eq_int(f.stream.offers().size, 0, "a late bundle must not revive the cancelled offer");
            fail_if(f.omemo.has_legacy_session_for_send(f.peer, 202),
                "cancelled call must release its late ratchet demand");
        });
    }

    private void test_detached() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, false));
            fail_if_not_eq_int(f.stream.bundles.size, 1);
            f.detach();
            assert_blocked(f, result);
            f.stream.answer_bundle(f.bob);
            fail_if_not_eq_int(f.stream.offers().size, 0, "detach cannot revive an old stream offer");
        });
    }

    private void test_discarded_store() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            // This is the real removal operation, including replacement of
            // the identity store by a keyless SimpleIdentityKeyStore. Late
            // call preparation must fail before reading those removed bytes.
            f.alice.store.discard_sensitive_state();
            fail_if(f.alice.store.is_persistence_ready);
            Result result = f.send(offer(sid, true));
            assert_blocked(f, result);
            fail_if_not_eq_int(f.stream.bundles.size, 0,
                "a discarded account must not start remote key discovery");
        });
    }

    private void test_changed_device() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            f.advertise(sid, f.peer, 303);
            f.stream.answer_bundle(f.bob);
            assert_blocked(f, result);
        });
    }

    private void test_late_detach() {
        run((f) => {
            f.replace_stream_then_late_detach();
            string sid = Uuid.string_random();
            f.advertise(sid);
            f.warm(f.bob);
            Result result = f.send(offer(sid, true));
            wait_result(result);
            fail_if(result.error, "late old teardown must not disable current call preparation");
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, true);
        });
    }

    private void test_late_detach_cold() {
        run((f) => {
            WireStream previous = f.stream;
            f.replace_stream_then_late_detach();
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            fail_if(result.done);
            fail_if_not_eq_int(f.stream.bundles.size, 1);
            // Both account-owned modules are shared between old/new streams.
            // Late teardown must preserve the new filter and awaited demand.
            f.verification.detach(previous);
            f.omemo.detach(previous);
            f.stream.answer_bundle(f.bob);
            wait_result(result);
            fail_if(result.error, "late old teardown must not erase the new call's pending native session demand");
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, true);
        });
    }

    private void test_same_sid_other_peer() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid, f.carol.account.bare_jid.with_resource("phone"), 303);
            Result result = f.send(offer(sid, false));
            wait_result(result);
            fail_if(result.error, "another peer's same SID must not impose its device on Bob");
            fail_if_not_eq_int(f.stream.bundles.size, 0);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) {
                StanzaNode? content = f.stream.offers()[0].get_deep_subnode(JINGLE + ":jingle", JINGLE + ":content");
                StanzaNode? transport = content != null ? ((!) content).get_subnode("transport", ICE) : null;
                fail_if(transport == null || ((!) transport).get_subnode("fingerprint", DTLS) == null,
                    "a foreign SID binding must not change ordinary Bob DTLS");
            }
        });
    }

    private void test_muji_resources() {
        run((f) => {
            // A second installation of the same bare account owns its own
            // genuine keys and a different native registration ID.
            var tablet = new Device(f.directory, "tablet", "bob@example.test", 404, f.context);
            try {
                f.alice.remember(tablet);
                tablet.remember(f.alice);
                f.stream.publish_device(tablet);
                Jid tablet_jid = tablet.account.bare_jid.with_resource("tablet");
                f.muji_presence(f.peer, "bob-phone", 202);
                f.muji_presence(tablet_jid, "bob-tablet", 404);
                f.warm(f.bob);
                f.warm(tablet);
                Result phone = f.send(offer(Uuid.string_random(), false, f.room));
                Result other = f.send(offer(Uuid.string_random(), false, f.room), tablet_jid);
                wait_result(phone);
                wait_result(other);
                fail_if(phone.error || other.error);
                fail_if_not_eq_int(f.stream.offers().size, 2);
                foreach (StanzaNode wire in f.stream.offers()) {
                    bool is_phone = wire.get_attribute("to") == f.peer.to_string();
                    assert_fingerprints(wire, f.alice, is_phone ? f.bob : tablet, false);
                }
            } finally { tablet.close(); }
        });
    }

    private void test_transport_info() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            f.warm(f.bob);
            StanzaNode node = offer(sid, true);
            node.put_attribute("action", "transport-info");
            Result result = f.send(node);
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, true);
        });
    }

    private void test_atomic_contents() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            f.warm(f.bob);
            StanzaNode node = offer(sid, true);
            StanzaNode video = node.get_subnodes("content", JINGLE)[1];
            StanzaNode transport = (!) video.get_subnode("transport", ICE);
            StanzaNode original = (!) transport.get_subnode("fingerprint", DTLS);
            transport.sub_nodes.remove(original);
            // This malformed already-prepared second content must fail after
            // the genuine first ratchet encrypt, without exposing either one.
            transport.put_node(new StanzaNode.build("fingerprint", VERIFY));
            Result result = f.send(node);
            assert_blocked(f, result);
            StanzaNode first_transport = (!) node.get_subnodes("content", JINGLE)[0].get_subnode("transport", ICE);
            fail_if(first_transport.get_subnode("fingerprint", VERIFY) != null,
                "a later content failure must not partially rewrite the original IQ");
            fail_if(first_transport.get_subnode("fingerprint", DTLS) == null);
        });
    }

    private void test_muji_unavailable() {
        run((f) => {
            f.muji_presence(f.peer, "bob", 202);
            Result result = f.send(offer(Uuid.string_random(), true, f.room));
            f.muji_presence(f.peer, "bob", 202, true);
            f.stream.answer_bundle(f.bob);
            assert_blocked(f, result);
        });
    }

    private void test_departed_muji_pin() {
        run((f) => {
            string sid = Uuid.string_random();
            f.muji_presence(f.peer, "bob", 202);
            f.warm(f.bob);
            Result result = f.send(offer(sid, false, f.room));
            wait_result(result);
            fail_if(result.error);
            fail_if_not_eq_int(f.stream.offers().size, 1);
            if (f.stream.offers().size == 1) assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, false);
            f.muji_presence(f.peer, "bob", 202, true);
            StanzaNode plain = offer(sid, false, f.room);
            plain.put_attribute("action", "transport-info");
            f.stream.received_iq_stanza(f.stream, incoming(f, plain));
            drain();
            fail_if_not_eq_int(f.received.accepted.size, 0,
                "a departed member must not revive a previously pinned call SID with plain DTLS");
            assert_incoming_error(f);
        });
    }

    private void test_terminated() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result pending = f.send(offer(sid, false));
            Result terminate = f.send(new StanzaNode.build("jingle", JINGLE)
                .put_attribute("sid", sid).put_attribute("action", "session-terminate"));
            wait_result(terminate);
            wait_result(pending);
            fail_if_not(pending.error && pending.local, "ending a call must fail its waiting offer locally");
            f.stream.answer_bundle(f.bob);
            fail_if_not_eq_int(f.stream.offers().size, 1, "only the termination IQ may reach the wire");
            foreach (StanzaNode node in f.stream.offers()) {
                StanzaNode jingle = (!) node.get_subnode("jingle", JINGLE);
                fail_if_not_eq_str(jingle.get_attribute("action"), "session-terminate");
            }
        });
    }

    private void test_adopted_leg() {
        run((f) => {
            string direct_sid = Uuid.string_random();
            f.advertise(direct_sid);
            f.warm(f.bob);
            Result direct = f.send(offer(direct_sid, false));
            wait_result(direct);
            // MUJI adoption preserves the original direct leg/SID, even when
            // the room has no separate advertisement for that original peer.
            StanzaNode adopted = offer(direct_sid, true, f.room);
            adopted.put_attribute("action", "transport-info");
            Result continued = f.send(adopted);
            wait_result(continued);
            fail_if(direct.error || continued.error);
            f.muji_presence(f.carol.account.bare_jid.with_resource("laptop"), "carol", 303);
            Result new_peer = f.send(offer(Uuid.string_random(), true, f.room),
                f.carol.account.bare_jid.with_resource("laptop"));
            fail_if_not_eq_int(f.stream.offers().size, 2,
                "the adopted direct leg is live while only the new peer awaits preparation");
            f.stream.answer_bundle(f.carol);
            wait_result(new_peer);
            fail_if(new_peer.error);
            fail_if_not_eq_int(f.stream.offers().size, 3);
            if (f.stream.offers().size == 3) {
                assert_fingerprints(f.stream.offers()[0], f.alice, f.bob, false);
                assert_fingerprints(f.stream.offers()[1], f.alice, f.bob, true);
                assert_fingerprints(f.stream.offers()[2], f.alice, f.carol, true);
            }
        });
    }

    private void test_rejected_key() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            f.alice.db.identity_meta.update()
                .with(f.alice.db.identity_meta.identity_id, "=", f.alice.identity_id)
                .with(f.alice.db.identity_meta.address_name, "=", f.peer.bare_jid.to_string())
                .with(f.alice.db.identity_meta.device_id, "=", 202)
                .set(f.alice.db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.UNTRUSTED).perform();
            f.stream.answer_bundle(f.bob);
            assert_blocked(f, result);
        });
    }

    private void test_changed_identity() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            var replacement = new Device(f.directory, "replacement", "bob@example.test", 202, f.context);
            try {
                GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                    "*Identity key changed for device 202 of bob@example.test*");
                f.stream.answer_bundle(replacement);
                GLib.Test.assert_expected_messages();
                assert_blocked(f, result);
            } finally { replacement.close(); }
        });
    }

    private void test_unknown_key() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            f.warm(f.bob);
            // A valid native session does not override the application's
            // explicit absence of trust in this exact stored identity key.
            f.alice.db.trust.upsert()
                .value(f.alice.db.trust.identity_id, f.alice.identity_id, true)
                .value(f.alice.db.trust.address_name, f.peer.bare_jid.to_string(), true)
                .value(f.alice.db.trust.blind_trust, false).perform();
            f.alice.db.identity_meta.update()
                .with(f.alice.db.identity_meta.identity_id, "=", f.alice.identity_id)
                .with(f.alice.db.identity_meta.address_name, "=", f.peer.bare_jid.to_string())
                .with(f.alice.db.identity_meta.device_id, "=", 202)
                .set(f.alice.db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.UNKNOWN).perform();
            Result result = f.send(offer(sid, true));
            assert_blocked(f, result);
        });
    }

    private void test_changed_own_identity() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            // Keep the registration ID to prove that an ID-only check cannot
            // authorize a replacement local identity during key discovery.
            f.alice.store.identity_key_store.identity_key_public =
                new Bytes(f.context.generate_key_pair().public.serialize());
            f.stream.answer_bundle(f.bob);
            assert_blocked(f, result);
        });
    }

    private void test_metadata_mismatch() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            f.warm(f.bob);
            f.alice.db.identity_meta.update()
                .with(f.alice.db.identity_meta.identity_id, "=", f.alice.identity_id)
                .with(f.alice.db.identity_meta.address_name, "=", f.peer.bare_jid.to_string())
                .with(f.alice.db.identity_meta.device_id, "=", 202)
                .set(f.alice.db.identity_meta.identity_key_public_base64,
                    Base64.encode(f.carol.store.identity_key_store.identity_key_public.get_data())).perform();
            Result result = f.send(offer(sid, true));
            assert_blocked(f, result);
        });
    }

    private void test_incoming_plain_first() {
        run((f) => {
            string sid = Uuid.string_random();
            f.muji_presence(f.peer, "bob", 202);
            var wire = incoming(f, offer(sid, true, f.room));
            f.stream.received_iq_stanza(f.stream, wire);
            drain();
            fail_if_not_eq_int(f.received.accepted.size, 1,
                "an ordinary first incoming offer is allowed by the optional verification draft");
        });
    }

    private void test_incoming_downgrade() {
        run((f) => {
            string sid = Uuid.string_random();
            f.stream.received_iq_stanza(f.stream, incoming_encrypted(f, f.bob, sid));
            drain();
            fail_if_not_eq_int(f.received.accepted.size, 1, "valid native encrypted first offer must be admitted");
            StanzaNode plain = offer(sid, false);
            plain.put_attribute("action", "transport-info");
            f.stream.received_iq_stanza(f.stream, incoming(f, plain));
            drain();
            fail_if_not_eq_int(f.received.accepted.size, 1,
                "a pinned OMEMO call must not accept a later plaintext fingerprint");
            assert_incoming_error(f);
        });
    }

    private void test_incoming_other_device() {
        run((f) => {
            string sid = Uuid.string_random();
            f.stream.received_iq_stanza(f.stream, incoming_encrypted(f, f.bob, sid));
            drain();
            fail_if_not_eq_int(f.received.accepted.size, 1);
            var replacement = new Device(f.directory, "other-device", "bob@example.test", 404, f.context);
            try {
                f.alice.remember(replacement);
                replacement.remember(f.alice);
                f.stream.received_iq_stanza(f.stream, incoming_encrypted(f, replacement, sid));
                drain();
                fail_if_not_eq_int(f.received.accepted.size, 1, "another OMEMO device may not take over the existing call SID");
                assert_incoming_error(f);
            } finally { replacement.close(); }
        });
    }

    private void test_timeout() {
        run((f) => {
            string sid = Uuid.string_random();
            f.advertise(sid);
            Result result = f.send(offer(sid, true));
            wait_result(result, 18000);
            assert_blocked(f, result);
            fail_if(f.omemo.has_legacy_session_for_send(f.peer, 202));
        });
    }

    private void test_incoming_fresh(bool blind_trust, bool list_only) {
        run((f) => {
            f.alice.db.identity_meta.delete()
                .with(f.alice.db.identity_meta.identity_id, "=", f.alice.identity_id)
                .with(f.alice.db.identity_meta.address_name, "=", f.peer.bare_jid.to_string()).perform();
            if (list_only) {
                f.alice.db.identity_meta.upsert()
                    .value(f.alice.db.identity_meta.identity_id, f.alice.identity_id, true)
                    .value(f.alice.db.identity_meta.address_name, f.peer.bare_jid.to_string(), true)
                    .value(f.alice.db.identity_meta.device_id, 202, true)
                    .value(f.alice.db.identity_meta.trust_level, Dino.Plugins.Omemo.TrustLevel.UNKNOWN)
                    .value(f.alice.db.identity_meta.now_active, true)
                    .value(f.alice.db.identity_meta.supports_omemo1, true).perform();
            }
            f.alice.db.trust.upsert()
                .value(f.alice.db.trust.identity_id, f.alice.identity_id, true)
                .value(f.alice.db.trust.address_name, f.peer.bare_jid.to_string(), true)
                .value(f.alice.db.trust.blind_trust, blind_trust).perform();
            fail_if(f.omemo.has_legacy_session_for_send(f.peer, 202),
                "the first incoming call must not require a prior sender session");
            f.stream.received_iq_stanza(f.stream, incoming_encrypted(f, f.bob, Uuid.string_random()));
            drain();
            fail_if_not_eq_int(f.received.accepted.size, blind_trust ? 1 : 0,
                "only the configured trust policy after genuine authenticated prekey decryption can admit a fresh caller");
            if (blind_trust && f.received.accepted.size == 1) {
                StanzaNode? cleartext = f.received.accepted[0].stanza.get_deep_subnode(
                    JINGLE + ":jingle", JINGLE + ":content", ICE + ":transport", DTLS + ":fingerprint");
                fail_if(cleartext == null, "the admitted first call must expose the decrypted DTLS fingerprint to the media engine");
                if (cleartext != null) fail_if_not_eq_str(((!) cleartext).get_deep_string_content(), AUDIO_FP);
            } else if (!blind_trust) assert_incoming_error(f);
        });
    }

    private static StanzaNode incoming(Fixture f, StanzaNode jingle) {
        return new StanzaNode.build("iq", "jabber:client")
            .put_attribute("id", Uuid.string_random()).put_attribute("type", Iq.Stanza.TYPE_SET)
            .put_attribute("from", f.peer.to_string())
            .put_attribute("to", f.alice.account.full_jid.to_string()).put_node(jingle);
    }

    private static StanzaNode incoming_encrypted(Fixture f, Device from, string sid) throws Error {
        var bundle = new Dino.Plugins.Omemo.Bundle(f.alice.bundle);
        var prekey = bundle.pre_keys[0];
        var address = new Address(f.alice.account.bare_jid.to_string(), 101);
        try {
            from.store.create_session_builder(address).process_pre_key_bundle(create_pre_key_bundle(101,
                101, (uint32) prekey.key_id, (!) prekey.key, bundle.signed_pre_key_id,
                (!) bundle.signed_pre_key, (!) bundle.signed_pre_key_signature, (!) bundle.identity_key));
        } finally { address.device_id = 0; }
        var encryptor = new Dino.Plugins.Omemo.OmemoEncryptor(from.account, from.trust, from.store);
        var encrypted = encryptor.encrypt_plaintext(AUDIO_FP);
        encryptor.encrypt_key(encrypted, f.alice.account.bare_jid, 101);
        StanzaNode node = offer(sid, false);
        StanzaNode content = node.get_subnodes("content", JINGLE)[0];
        StanzaNode transport = (!) content.get_subnode("transport", ICE);
        StanzaNode old = (!) transport.get_subnode("fingerprint", DTLS);
        transport.sub_nodes.remove(old);
        transport.put_node(new StanzaNode.build("fingerprint", VERIFY)
            .put_attribute("hash", "sha-256").put_attribute("setup", "actpass")
            .put_node(encrypted.get_encrypted_node()));
        return incoming(f, node);
    }

    private static void assert_incoming_error(Fixture f) {
        bool found = false;
        foreach (StanzaNode node in f.stream.written) {
            if (node.name == "iq" && node.get_attribute("type") == Xmpp.Stanza.TYPE_ERROR) found = true;
        }
        fail_if_not(found, "rejected incoming verification must receive an IQ error");
    }

    private static void assert_blocked(Fixture f, Result result) {
        wait_result(result);
        fail_if_not(result.done && result.error && result.local,
            "the original send callback must receive a local error exactly when verification fails");
        fail_if_not_eq_int(f.stream.offers().size, 0,
            "failed OMEMO fingerprint preparation must never send a plain or partial offer");
    }

    private static void assert_fingerprints(StanzaNode wire, Device sender,
            Device recipient, bool video) throws Error {
        StanzaNode? jingle = wire.get_subnode("jingle", JINGLE);
        if (jingle == null) throw new IOError.FAILED("wire IQ lost its Jingle payload");
        Gee.List<StanzaNode> contents = ((!) jingle).get_subnodes("content", JINGLE);
        fail_if_not_eq_int(contents.size, video ? 2 : 1);
        foreach (StanzaNode content in contents) {
            StanzaNode? transport = content.get_subnode("transport", ICE);
            if (transport == null) throw new IOError.FAILED("wire content lost ICE transport");
            fail_if(((!) transport).get_subnode("fingerprint", DTLS) != null,
                "selected OMEMO call must never retain a plaintext fingerprint");
            StanzaNode? fingerprint = ((!) transport).get_subnode("fingerprint", VERIFY);
            StanzaNode? encrypted = fingerprint != null ? ((!) fingerprint).get_subnode("encrypted", LEGACY) : null;
            if (encrypted == null) throw new IOError.FAILED("wire fingerprint has no genuine OMEMO payload");
            fail_if_not_eq_str(((!) fingerprint).get_attribute("hash"), "sha-256");
            fail_if_not_eq_str(((!) fingerprint).get_attribute("setup"), "actpass");
            var decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(recipient.account,
                recipient.interactor, recipient.trust, recipient.db, recipient.store);
            Xmpp.Xep.Omemo.ParsedData? data = decryptor.parse_node((!) encrypted);
            if (data == null || ((!) data).our_potential_encrypted_keys.size != 1)
                throw new IOError.FAILED("native recipient must have exactly one wrapped fingerprint key");
            string? cleartext = null;
            foreach (Bytes candidate in ((!) data).our_potential_encrypted_keys.keys) {
                ((!) data).is_prekey = ((!) data).our_potential_encrypted_keys[candidate];
                ((!) data).encrypted_key = candidate.get_data();
                uint8[] key = decryptor.decrypt_key((!) data, sender.account.bare_jid);
                cleartext = decryptor.decrypt(((!) data).ciphertext, key, ((!) data).iv);
            }
            fail_if_not_eq_str(cleartext ?? "", content.get_attribute("name") == "video" ? VIDEO_FP : AUDIO_FP,
                "the real recipient must decrypt the precise original DTLS fingerprint");
        }
    }

    private static StanzaNode offer(string sid, bool video, Jid? room = null) {
        StanzaNode node = new StanzaNode.build("jingle", JINGLE)
            .put_attribute("action", "session-initiate").put_attribute("sid", sid);
        node.put_node(content("audio", AUDIO_FP));
        if (video) node.put_node(content("video", VIDEO_FP));
        if (room != null) node.put_node(new StanzaNode.build("muji", MUJI).put_attribute("room", ((!) room).to_string()));
        return node;
    }

    private static StanzaNode content(string media, string fingerprint) {
        return new StanzaNode.build("content", JINGLE)
            .put_attribute("name", media).put_attribute("creator", "initiator")
            .put_node(new StanzaNode.build("description", "urn:xmpp:jingle:apps:rtp:1").put_attribute("media", media))
            .put_node(new StanzaNode.build("transport", ICE)
                .put_node(new StanzaNode.build("fingerprint", DTLS)
                    .put_attribute("hash", "sha-256").put_attribute("setup", "actpass")
                    .put_node(new StanzaNode.text(fingerprint))));
    }

    private static StanzaNode make_bundle(Context context, Store store,
            int prekey_id, int signed_id) throws Error {
        PreKeyRecord prekey;
        throw_by_code(PreKeyRecord.create(out prekey, prekey_id, context.generate_key_pair()));
        store.store_pre_key(prekey);
        SignedPreKeyRecord signed_key = context.generate_signed_pre_key(store.identity_key_pair, signed_id);
        store.store_signed_pre_key(signed_key);
        return new StanzaNode.build("bundle", LEGACY)
            .put_node(new StanzaNode.build("identityKey", LEGACY)
                .put_node(new StanzaNode.text(Base64.encode(store.identity_key_pair.public.serialize()))))
            .put_node(new StanzaNode.build("signedPreKeyPublic", LEGACY).put_attribute("signedPreKeyId", signed_id.to_string())
                .put_node(new StanzaNode.text(Base64.encode(signed_key.key_pair.public.serialize()))))
            .put_node(new StanzaNode.build("signedPreKeySignature", LEGACY)
                .put_node(new StanzaNode.text(Base64.encode(signed_key.signature))))
            .put_node(new StanzaNode.build("prekeys", LEGACY)
                .put_node(new StanzaNode.build("preKeyPublic", LEGACY).put_attribute("preKeyId", prekey_id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(prekey.key_pair.public.serialize())))));
    }

    private static StanzaNode iq_result(StanzaNode request) {
        return new StanzaNode.build("iq", "jabber:client")
            .put_attribute("type", Iq.Stanza.TYPE_RESULT)
            .put_attribute("id", request.get_attribute("id"))
            .put_attribute("from", request.get_attribute("to") ?? "example.test")
            .put_attribute("to", request.get_attribute("from") ?? "alice@example.test");
    }

    private static void drain() {
        int count = 0;
        while (MainContext.default().pending() && count++ < 10000) MainContext.default().iteration(false);
    }

    private static void wait_result(Result result, int milliseconds = 3000) {
        int64 until = get_monotonic_time() + milliseconds * 1000;
        while (!result.done && get_monotonic_time() < until) {
            drain();
            if (!result.done) Thread.usleep(1000);
        }
        drain();
        fail_if_not(result.done, "bounded call fingerprint operation must complete");
        if (result.done) fail_if_not_eq_int(result.completions, 1,
            "the original IQ completion callback must run exactly once");
    }

    private static void remove_directory(string directory) {
        try {
            Dir entries = Dir.open(directory);
            string? entry;
            while ((entry = entries.read_name()) != null) {
                string path = Path.build_filename(directory, (!) entry);
                if (FileUtils.test(path, FileTest.IS_DIR)) remove_directory(path);
                else FileUtils.remove(path);
            }
            DirUtils.remove(directory);
        } catch (FileError error) { }
    }
}

}
