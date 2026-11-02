using Dino.Entities;
using Dino.Plugins.Omemo;
using Gee;
using Xmpp;

namespace Omemo.Test {

class LegacyPreKeyRecoveryTest : Gee.TestCase {
    private const string OMEMO_NS = "eu.siacs.conversations.axolotl";
    private const string PUBSUB_NS = "http://jabber.org/protocol/pubsub";

    internal LegacyPreKeyRecoveryTest() {
        base("LegacyPreKeyRecovery");
        add_test("missing_prekey_response_repairs_peer_and_preserves_old_receive_state", test_recovery);
        add_test("known_identity_and_trust_are_required", test_trust);
        add_test("archive_delay_transport_and_non_direct_guards", test_message_guards);
        add_test("dedupe_cooldown_and_pending_bounds", test_limiter);
        add_test("changed_attachment_discards_pending_recovery", test_attachment_change);
        add_test("trust_revocation_discards_pending_recovery", test_pending_trust_revocation);
        add_test("session_write_failure_restores_old_state", test_transaction_failure);
        add_test("prekey_without_optional_one_time_id_does_not_assert", test_optional_prekey_id);
        add_test("authenticated_16_byte_key_transport_discards_outer_body", () => test_key_transport_body(16));
        add_test("authenticated_32_byte_key_transport_discards_outer_body", () => test_key_transport_body(32));
        add_test("unavailable_local_store_does_not_mark_peer_undecryptable", test_unavailable_store);
        add_test("missing_recipient_key_keeps_distinct_failure_and_historical_marker", test_missing_recipient_key);
        add_test("invalid_envelope_keeps_distinct_failure_without_native_error", test_invalid_envelope);
        add_test("live_private_muc_repairs_peer_directly_and_preserves_old_receive_state", test_private_muc_recovery);
        add_test("public_anonymous_unresolved_and_wrong_account_mucs_never_repair", test_private_muc_guards);
        add_test("private_muc_archives_delays_pm_and_key_transports_never_repair", test_private_muc_envelope_guards);
        add_test("private_muc_leave_discards_pending_recovery", () => test_private_muc_pending_change(0));
        add_test("private_muc_leave_rejoin_discards_pending_recovery", () => test_private_muc_pending_change(1));
        add_test("private_muc_reused_nick_discards_pending_recovery", () => test_private_muc_pending_change(2));
        add_test("private_muc_privacy_change_discards_pending_recovery", () => test_private_muc_pending_change(3));
        add_test("private_muc_restored_privacy_discards_pending_recovery", () => test_private_muc_pending_change(4));
        add_test("private_muc_trust_revocation_discards_pending_recovery", () => test_private_muc_pending_change(5));
        add_test("private_muc_attachment_change_discards_pending_recovery", () => test_private_muc_pending_change(6));
        add_test("private_muc_nick_change_during_send_pipeline_never_writes", test_private_muc_pipeline_change);
        add_test("private_muc_legacy_recovery_preserves_a_new_native_v4_session", test_private_muc_pending_v4_session);
        add_test("unsent_direct_repair_retries_the_same_native_packet", () => test_unsent_retry(false));
        add_test("unsent_private_muc_repair_retries_the_same_native_packet", () => test_unsent_retry(true));
        add_test("committed_delivery_retry_keeps_two_hour_confirmation_and_memory_bounds", test_delivery_limiter);
        add_test("cached_retry_rechecks_trust_identity_account_stream_and_protocol", test_cached_retry_guards);
        add_test("cached_private_muc_retry_requires_fresh_private_room_authority", test_cached_muc_guards);
        add_test("outgoing_pipeline_cannot_mutate_retained_recovery_material", test_immutable_wire);
        add_test("failed_or_ambiguous_write_never_creates_another_ratchet", test_write_errors);
        add_test("archived_receive_state_remains_valid_during_unsent_retry", test_retry_after_archive_promotion);
        add_test("authenticated_new_base_cancels_a_queued_recovery_write", test_confirmation_during_pipeline);
        add_test("approved_peer_identity_change_retires_obsolete_confirmation", test_approved_peer_change);
        add_test("persisted_own_identity_change_retires_obsolete_confirmation", test_persisted_own_change);
        add_test("successful_explicit_session_reset_retires_only_its_recovery_guard", test_explicit_reset);
        add_test("successful_contact_reset_retires_its_queued_recovery_guard", test_contact_reset);
        add_test("plain_direct_and_public_group_messages_never_trigger_recovery", test_plaintext_messages);
        add_test("cloned_identity_cannot_authorize_another_accounts_backing_store", test_backing_scope);
    }

    private class FakeStream : XmppStream {
        internal Bundle reply_bundle;
        internal bool hold = false;
        internal StanzaNode? held;
        internal int requests = 0;
        internal ArrayList<StanzaNode> messages = new ArrayList<StanzaNode>();
        internal Jid? room;
        internal Jid? room_account;
        internal bool members_only = true;
        internal bool non_anonymous = true;
        internal int message_write_failure = 0;

        internal FakeStream(Jid remote_name, Bundle bundle) {
            base(remote_name);
            reply_bundle = bundle;
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated recovery test stream");
        }
        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (node.name == "message") {
                if (message_write_failure == 1) throw new IOError.BROKEN_PIPE("isolated write rejected before delivery");
                messages.add(node);
                if (message_write_failure == 2) throw new IOError.BROKEN_PIPE("isolated ambiguous write after delivery");
            }
            if (node.name == "presence" && room != null &&
                    node.get_attribute("to") != null) {
                Jid target;
                try { target = new Jid(node.get_attribute("to")); }
                catch (InvalidJidError error) { throw new IOError.INVALID_ARGUMENT(error.message); }
                if (target.equals_bare((!) room)) {
                    bool unavailable = node.get_attribute("type") == Presence.Stanza.TYPE_UNAVAILABLE;
                    Idle.add(() => {
                        emit_occupant(target, room_account, true, unavailable);
                        return Source.REMOVE;
                    });
                }
                return;
            }
            if (node.name != "iq") return;
            StanzaNode? disco = node.get_subnode("query", "http://jabber.org/protocol/disco#info");
            if (disco != null) {
                var result = new StanzaNode.build("query", "http://jabber.org/protocol/disco#info")
                    .put_node(new StanzaNode.build("identity", "http://jabber.org/protocol/disco#info")
                        .put_attribute("category", "conference").put_attribute("type", "text"));
                result.put_node(new StanzaNode.build("feature", result.ns_uri).put_attribute("var", "http://jabber.org/protocol/muc"));
                if (members_only) result.put_node(new StanzaNode.build("feature", result.ns_uri).put_attribute("var", "muc_membersonly"));
                if (non_anonymous) result.put_node(new StanzaNode.build("feature", result.ns_uri).put_attribute("var", "muc_nonanonymous"));
                Idle.add(() => { reply_iq(node, result); return Source.REMOVE; });
                return;
            }
            StanzaNode? admin = node.get_subnode("query", "http://jabber.org/protocol/muc#admin");
            if (admin != null) {
                var result = new StanzaNode.build("query", "http://jabber.org/protocol/muc#admin");
                StanzaNode? item = admin.get_subnode("item", result.ns_uri);
                if (item != null && item.get_attribute("affiliation") == "member") {
                    foreach (string member in new string[]{"alice@example.test", "bob@example.test"}) {
                        result.put_node(new StanzaNode.build("item", result.ns_uri)
                            .put_attribute("jid", member).put_attribute("affiliation", "member"));
                    }
                }
                Idle.add(() => { reply_iq(node, result); return Source.REMOVE; });
                return;
            }
            if (node.get_subnode("pubsub", PUBSUB_NS) == null) return;
            requests++;
            held = node;
            if (!hold) Idle.add(() => { reply(); return Source.REMOVE; });
        }

        private void reply_iq(StanzaNode request, StanzaNode payload) {
            received_iq_stanza(this, new StanzaNode.build("iq", "jabber:client")
                .put_attribute("type", "result").put_attribute("id", request.get_attribute("id"))
                .put_attribute("from", request.get_attribute("to")).put_node(payload));
        }

        internal void emit_occupant(Jid occupant, Jid? real_jid,
                bool self = false, bool unavailable = false) {
            const string MUC_USER = "http://jabber.org/protocol/muc#user";
            var item = new StanzaNode.build("item", MUC_USER)
                .put_attribute("affiliation", "member")
                .put_attribute("role", unavailable ? "none" : "participant");
            if (real_jid != null) item.put_attribute("jid", real_jid.to_string());
            var muc = new StanzaNode.build("x", MUC_USER).add_self_xmlns().put_node(item);
            if (self) muc.put_node(new StanzaNode.build("status", MUC_USER).put_attribute("code", "110"));
            var presence = new StanzaNode.build("presence", "jabber:client")
                .put_attribute("from", occupant.to_string()).put_node(muc);
            if (room_account != null) presence.put_attribute("to", room_account.to_string());
            if (unavailable) presence.put_attribute("type", Presence.Stanza.TYPE_UNAVAILABLE);
            received_presence_stanza(this, presence);
        }

        internal void reply() {
            if (held == null) return;
            StanzaNode request = (!) held;
            held = null;
            var items = new StanzaNode.build("items", PUBSUB_NS)
                .put_attribute("node", request.get_subnode("pubsub", PUBSUB_NS)
                    .get_subnode("items", PUBSUB_NS).get_attribute("node"))
                .put_node(new StanzaNode.build("item", PUBSUB_NS)
                    .put_attribute("id", "current").put_node(reply_bundle.node));
            var result = new StanzaNode.build("iq", "jabber:client")
                .put_attribute("type", "result")
                .put_attribute("id", request.get_attribute("id"))
                .put_attribute("from", request.get_attribute("to"))
                .put_node(new StanzaNode.build("pubsub", PUBSUB_NS).put_node(items));
            received_iq_stanza(this, result);
        }
    }

    private class HeldSendListener : StanzaListener<MessageStanza> {
        internal bool entered = false;
        internal MessageStanza? captured;
        private SourceFunc? resume;
        private string[] after = {};
        public override string action_group { get { return "RECOVERY_TEST_HOLD"; } }
        public override string[] after_actions { get { return after; } }

        public override async bool run(XmppStream stream, MessageStanza message) {
            entered = true;
            captured = message;
            SourceFunc continuation = run.callback;
            resume = (owned) continuation;
            yield;
            return false;
        }

        internal void release() {
            SourceFunc? continuation = (owned) resume;
            if (continuation != null) Idle.add((owned) continuation);
        }
    }

    private class Fixture : Object {
        internal string temp_dir;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Dino.StreamInteractor interactor;
        internal TrustManager trust;
        internal Account account;
        internal Jid alice_jid;
        internal Context context;
        internal Store alice;
        internal Store bob;
        internal Address alice_address;
        internal Address bob_address;
        internal Bundle alice_bundle;
        internal Bundle bob_bundle;
        internal int identity_id;
        internal FakeStream stream;
        internal StreamModule module;
        internal OmemoDecryptor decryptor;
        internal LegacyPreKeyRecovery recovery;
        internal Dino.MucManager? muc_manager;
        internal Jid? room;
        internal Jid? occupant;
        internal Conversation? room_conversation;

        internal Fixture() throws Error {
            temp_dir = DirUtils.make_tmp("dinox-prekey-recovery-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(temp_dir, "app.db"), "recovery-test");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(temp_dir, "omemo.db"));
            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) throw new IOError.FAILED("No native context");
            context = Dino.Plugins.Omemo.Plugin.get_context();
            alice = setup_test_store_context(context);
            bob = setup_test_store_context(context);
            alice.identity_key_store.local_registration_id = 11;
            bob.identity_key_store.local_registration_id = 22;
            alice_jid = new Jid("alice@example.test");
            account = new Account(new Jid("bob@example.test"), "test-password");
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
            db.identity_meta.upsert()
                .value(db.identity_meta.identity_id, identity_id, true)
                .value(db.identity_meta.address_name, alice_jid.to_string(), true)
                .value(db.identity_meta.device_id, 11, true)
                .value(db.identity_meta.identity_key_public_base64, Base64.encode(alice.identity_key_store.identity_key_public.get_data()))
                .value(db.identity_meta.trust_level, TrustLevel.TRUSTED)
                .value(db.identity_meta.now_active, true)
                .value(db.identity_meta.supports_omemo1, true)
                .perform_checked();
            alice_address = new Address(alice_jid.to_string(), 11);
            bob_address = new Address(account.bare_jid.to_string(), 22);
            alice_bundle = make_bundle(alice, 51, 52);
            bob_bundle = make_bundle(bob, 61, 62);
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            trust = new TrustManager(interactor, db);
            recovery = new LegacyPreKeyRecovery(account, interactor, trust, db, bob);
            decryptor = new OmemoDecryptor(account, interactor, trust, db, bob);
            stream = new FakeStream(new Jid("example.test"), alice_bundle);
            var iq = new Iq.Module();
            var messages = new MessageModule();
            var pubsub = new Xmpp.Xep.Pubsub.Module();
            var disco = new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Recovery Test");
            stream.add_module(iq);
            stream.add_module(messages);
            stream.add_module(pubsub);
            stream.add_module(disco);
            disco.attach(stream);
            iq.attach(stream);
            messages.attach(stream);
            pubsub.attach(stream);
            var bind = new Bind.Flag();
            bind.my_jid = account.bare_jid;
            bind.finished = true;
            stream.add_flag(bind);
            module = new StreamModule(bob);
            stream.add_module(module);
            module.attach(stream);
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        }

        internal Bundle make_bundle(Store peer, int prekey_id, int signed_id) throws Error {
            PreKeyRecord prekey;
            throw_by_code(PreKeyRecord.create(out prekey, prekey_id, context.generate_key_pair()));
            peer.store_pre_key(prekey);
            SignedPreKeyRecord signed = context.generate_signed_pre_key(peer.identity_key_pair, signed_id);
            peer.store_signed_pre_key(signed);
            var node = new StanzaNode.build("bundle", OMEMO_NS)
                .put_node(new StanzaNode.build("identityKey", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(peer.identity_key_pair.public.serialize()))))
                .put_node(new StanzaNode.build("signedPreKeyPublic", OMEMO_NS).put_attribute("signedPreKeyId", signed_id.to_string()).put_node(new StanzaNode.text(Base64.encode(signed.key_pair.public.serialize()))))
                .put_node(new StanzaNode.build("signedPreKeySignature", OMEMO_NS).put_node(new StanzaNode.text(Base64.encode(signed.signature))))
                .put_node(new StanzaNode.build("prekeys", OMEMO_NS).put_node(new StanzaNode.build("preKeyPublic", OMEMO_NS).put_attribute("preKeyId", prekey_id.to_string()).put_node(new StanzaNode.text(Base64.encode(prekey.key_pair.public.serialize())))));
            return new Bundle(node);
        }

        internal void build_alice_session(Bundle bundle, bool with_one_time_key = true) throws Error {
            Bundle.PreKey key = bundle.pre_keys[0];
            SessionBuilder builder = alice.create_session_builder(bob_address);
            builder.process_pre_key_bundle(create_pre_key_bundle(22, 22,
                key.key_id, with_one_time_key ? key.key : null,
                bundle.signed_pre_key_id, bundle.signed_pre_key,
                bundle.signed_pre_key_signature, bundle.identity_key));
        }

        internal void establish() throws Error {
            build_alice_session(bob_bundle);
            CiphertextMessage first = alice.create_session_cipher(bob_address).encrypt("initial".data);
            bob.create_session_cipher(alice_address).decrypt_pre_key_message(context.deserialize_signal_pre_key_message(first.serialized));
            CiphertextMessage ack = bob.create_session_cipher(alice_address).encrypt("ack".data);
            alice.create_session_cipher(bob_address).decrypt_message(context.deserialize_signal_message(ack.serialized));
        }

        internal uint8[] stale_packet() throws Error {
            // The old published one-time key was consumed by establish().
            build_alice_session(bob_bundle);
            uint8[] keytag = new uint8[32];
            context.randomize(keytag);
            CiphertextMessage packet = alice.create_session_cipher(bob_address).encrypt(keytag);
            return packet.serialized;
        }

        internal LegacyInvalidPreKey failure(uint8[] packet) {
            return new LegacyInvalidPreKey(alice_jid, 11,
                Base64.encode(alice.identity_key_pair.public.serialize()), packet);
        }

        internal MessageStanza stanza(uint8[] packet, bool payload = true) {
            var data = new Xmpp.Xep.Omemo.EncryptionData(11);
            data.iv = new uint8[12];
            if (payload) data.ciphertext = new uint8[1];
            data.add_device_key((int) bob.local_registration_id, packet, true);
            var stanza = new MessageStanza();
            stanza.from = alice_jid;
            stanza.to = account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.stanza.put_node(data.get_encrypted_node());
            return stanza;
        }

        internal Dino.Entities.Message message() {
            return new Dino.Entities.Message("encrypted") {
                account = account, counterpart = alice_jid,
                ourpart = account.bare_jid,
                direction = Dino.Entities.Message.DIRECTION_RECEIVED,
                type_ = Dino.Entities.Message.Type.CHAT,
                time = new DateTime.now_utc()
            };
        }

        internal Conversation conversation() {
            return new Conversation(alice_jid, account, Conversation.Type.CHAT);
        }

        internal void register_account_module() {
            interactor.module_manager.initialize_account_modules.connect((owner, modules) => {
                if (owner.id == account.id) modules.add(module);
            });
        }

        internal void enable_muc(bool members_only = true,
                bool non_anonymous = true, bool resolved_occupant = true) throws Error {
            Dino.MessageStorage.start(interactor, app_db);
            Dino.FileTransferStorage.start(interactor, app_db);
            Dino.EntityInfo.start(interactor, app_db);
            Dino.RosterManager.start(interactor, app_db);
            Dino.Calls.start(interactor, app_db);
            Dino.ConversationManager.start(interactor, app_db);
            Dino.PresenceManager.start(interactor, app_db);
            Dino.OccupantIdStore.start(interactor, app_db);
            Dino.MucManager.start(interactor, app_db);
            register_account_module();
            interactor.module_manager.initialize(account);
            interactor.account_added(account);
            foreach (SimpleModuleIdentity identity in new SimpleModuleIdentity[]{
                    Presence.Module.IDENTITY, Xep.Muc.Module.IDENTITY,
                    Xep.OccupantIds.Module.IDENTITY, Xep.Ping.Module.IDENTITY}) {
                XmppStreamModule attached = interactor.module_manager.get_module<XmppStreamModule>(account, identity);
                stream.add_module(attached);
                attached.attach(stream);
            }
            room = new Jid("private@conference.example.test");
            occupant = room.with_resource("alice");
            stream.room = room;
            stream.room_account = account.bare_jid;
            stream.members_only = members_only;
            stream.non_anonymous = non_anonymous;
            muc_manager = interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            room_conversation = interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY)
                .create_conversation(room, account, Conversation.Type.GROUPCHAT);
            room_conversation.nickname = "bob";
            join_room();
            stream.emit_occupant((!) occupant, resolved_occupant ? alice_jid : null);
            drain();
            if (members_only && non_anonymous && resolved_occupant &&
                    muc_manager.get_verified_private_muc_participant(account, room, occupant) == null) {
                throw new IOError.FAILED("Fixture must establish a real live private-MUC occupant mapping");
            }
        }

        internal void join_room(bool manual_rejoin = false) throws Error {
            MainLoop loop = new MainLoop();
            bool finished = false;
            string? error = null;
            muc_manager.join.begin(account, room, "bob", null, true, null,
                    manual_rejoin, manual_rejoin, (obj, res) => {
                Xep.Muc.JoinResult? result = muc_manager.join.end(res);
                if (result == null || result.nick != "bob" || result.muc_error != null || result.stanza_error != null) {
                    error = "Isolated MUC fixture join did not succeed";
                }
                finished = true;
                loop.quit();
            });
            uint timeout = Timeout.add_seconds(5, () => {
                error = "Isolated MUC fixture join timed out";
                loop.quit();
                return Source.REMOVE;
            });
            if (!finished) loop.run();
            if (finished) Source.remove(timeout);
            if (error != null) throw new IOError.FAILED((!) error);
            drain();
        }

        internal void refresh_room_privacy() throws Error {
            bool finished = false;
            var muc_module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            muc_module.query_room_info.begin(stream, room, (obj, res) => {
                muc_module.query_room_info.end(res);
                finished = true;
            });
            drain();
            if (!finished) throw new IOError.FAILED("Isolated room info query did not complete");
        }

        internal Dino.Entities.Message muc_message() {
            var result = message();
            result.type_ = Dino.Entities.Message.Type.GROUPCHAT;
            result.counterpart = occupant;
            result.real_jid = alice_jid;
            return result;
        }

        internal MessageStanza muc_stanza(uint8[] packet, bool payload = true) {
            var result = stanza(packet, payload);
            result.type_ = MessageStanza.TYPE_GROUPCHAT;
            result.from = occupant;
            return result;
        }

        internal MessageStanza encrypted_payload(string cleartext, bool group = false) throws Error {
            // Use the production payload encoder instead of directly calling
            // the inline native VAPI wrapper from this test compilation unit.
            var encryptor = new OmemoEncryptor(new Account(alice_jid, "isolated-sender"), trust, alice);
            var data = encryptor.encrypt_plaintext(cleartext);
            CiphertextMessage packet = alice.create_session_cipher(bob_address).encrypt(data.keytag);
            data.add_device_key(22, packet.serialized, packet.type == CiphertextType.PREKEY);
            var result = new MessageStanza();
            result.from = group ? occupant : alice_jid;
            result.to = account.bare_jid;
            result.type_ = group ? MessageStanza.TYPE_GROUPCHAT : MessageStanza.TYPE_CHAT;
            result.stanza.put_node(data.get_encrypted_node());
            return result;
        }

        internal MessageStanza encrypted_muc_payload(string cleartext) throws Error {
            return encrypted_payload(cleartext, true);
        }

        internal void install_native_v4_session() throws Error {
            Bundle.PreKey key = alice_bundle.pre_keys[0];
            uint8[] signature = context.calculate_signature(alice.identity_key_pair.private,
                alice_bundle.signed_pre_key.serialize_omemo());
            bob.delete_session(alice_address);
            SessionBuilder builder = bob.create_session_builder(alice_address);
            builder.version = 4;
            builder.process_pre_key_bundle(create_pre_key_bundle(11, 11,
                key.key_id, key.key, alice_bundle.signed_pre_key_id,
                alice_bundle.signed_pre_key, signature, alice_bundle.identity_key));
        }

        internal void close() {
            if (muc_manager != null) {
                interactor.account_removed(account);
                muc_manager.shutdown();
                drain();
            }
            module.detach(stream);
            db.close();
            app_db.close();
            foreach (string name in new string[]{"app.db", "omemo.db"}) {
                foreach (string suffix in new string[]{"", "-wal", "-shm"}) FileUtils.remove(Path.build_filename(temp_dir, name + suffix));
            }
            DirUtils.remove(temp_dir);
        }
    }

    private static void drain() {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    }

    private void test_unavailable_store() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            f.register_account_module();
            int bad_updates = 0;
            f.trust.bad_message_state_updated.connect((owner, jid, device_id) => { bad_updates++; });
            Qlite.Row? before = f.db.identity_meta.get_device(f.identity_id, f.alice_jid.to_string(), 11);
            long old_marker = before[f.db.identity_meta.last_message_undecryptable];
            string old_session = Base64.encode(f.bob.session_store.load_session(f.alice_address));

            Store unavailable = f.context.create_store(false);
            unavailable.identity_key_store.local_registration_id = 22;
            var decryptor = new OmemoDecryptor(f.account, f.interactor, f.trust, f.db, unavailable);
            fail_if(decryptor.decrypt_message(f.message(), f.stanza(new uint8[] { 1 }), f.conversation()),
                "An unavailable local store must reject before recipient selection or native decryption");
            fail_if_not_eq_str(decryptor.last_failure_kind, "store-unavailable");
            fail_if_not_zero_int(decryptor.last_failure_code,
                "A local readiness failure must not invent a native Signal error");
            fail_if(decryptor.store_ready || decryptor.own_device_id != 0,
                "Readiness diagnostics must come from the unavailable decryptor's own store");

            unavailable.mark_persistence_ready();
            unavailable.identity_key_store.local_registration_id = 0;
            fail_if(decryptor.decrypt_message(f.message(), f.stanza(new uint8[] { 1 }), f.conversation()),
                "A local store without its own device id must not blame a peer for recipient selection");
            fail_if_not_eq_str(decryptor.last_failure_kind, "store-unavailable");
            Qlite.Row? after = f.db.identity_meta.get_device(f.identity_id, f.alice_jid.to_string(), 11);
            fail_if(bad_updates != 0 || after[f.db.identity_meta.last_message_undecryptable] != old_marker,
                "Local readiness failures must preserve the peer's historical bad-message state");
            fail_if_not_eq_str(Base64.encode(f.bob.session_store.load_session(f.alice_address)), old_session,
                "Local readiness failures must preserve the established receive session");
            fail_if(f.stream.requests != 0 || f.stream.messages.size != 0,
                "A local readiness failure must not start peer recovery or publication");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_missing_recipient_key() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.register_account_module();
            int bad_updates = 0;
            f.trust.bad_message_state_updated.connect((owner, jid, device_id) => { bad_updates++; });
            var data = new Xmpp.Xep.Omemo.EncryptionData(11);
            data.iv = new uint8[12];
            data.ciphertext = new uint8[1];
            data.add_device_key(33, new uint8[] { 1 }, false);
            var stanza = new MessageStanza();
            stanza.from = f.alice_jid;
            stanza.to = f.account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.stanza.put_node(data.get_encrypted_node());
            var message = f.message();
            fail_if(f.decryptor.decrypt_message(message, stanza, f.conversation()),
                "A payload addressed only to another device must remain undecryptable");
            fail_if_not_eq_str(f.decryptor.last_failure_kind, "recipient-key-missing");
            fail_if_not_eq_str(f.decryptor.last_failure_detail, "stage=recipient-selection");
            fail_if_not_zero_int(f.decryptor.last_failure_code,
                "Missing recipient selection has no native Signal error code");
            fail_if(!f.decryptor.store_ready || f.decryptor.own_device_id != 22,
                "Recipient diagnostics must retain the ready local decryptor's identity");
            Qlite.Row? peer = f.db.identity_meta.get_device(f.identity_id, f.alice_jid.to_string(), 11);
            fail_if(bad_updates != 1 || peer[f.db.identity_meta.last_message_undecryptable] != message.time.to_unix(),
                "A real missing recipient key must keep the existing historical marker behavior");
            fail_if(f.stream.requests != 0 || f.stream.messages.size != 0,
                "A missing recipient key must not start session recovery or publication");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_invalid_envelope() {
        Fixture? f = null;
        try {
            f = new Fixture();
            var stanza = new MessageStanza();
            stanza.from = f.alice_jid;
            stanza.to = f.account.bare_jid;
            stanza.stanza.put_node(new StanzaNode.build("encrypted", OMEMO_NS).add_self_xmlns());
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING, "*No header node*");
            fail_if(f.decryptor.decrypt_message(f.message(), stanza, f.conversation()));
            GLib.Test.assert_expected_messages();
            fail_if_not_eq_str(f.decryptor.last_failure_kind, "invalid-envelope");
            fail_if_not_eq_str(f.decryptor.last_failure_detail, "stage=envelope-parse");
            fail_if_not_zero_int(f.decryptor.last_failure_code,
                "An invalid XML envelope must not invent a native Signal error");
            Qlite.Row? peer = f.db.identity_meta.get_device(f.identity_id, f.alice_jid.to_string(), 11);
            fail_if(peer[f.db.identity_meta.last_message_undecryptable] != 0,
                "An invalid envelope must not mark the peer as omitting a recipient key");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_key_transport_body(int key_length) {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            uint8[] keytag = new uint8[key_length];
            f.context.randomize(keytag);
            CiphertextMessage packet = f.alice.create_session_cipher(f.bob_address).encrypt(keytag);
            var data = new Xmpp.Xep.Omemo.EncryptionData(11);
            data.iv = new uint8[12];
            data.add_device_key(22, packet.serialized, false);
            var stanza = new MessageStanza();
            stanza.from = f.alice_jid;
            stanza.to = f.account.bare_jid;
            stanza.type_ = MessageStanza.TYPE_CHAT;
            stanza.body = "Unauthenticated outer body";
            stanza.stanza.put_node(data.get_encrypted_node());
            var message = f.message();
            message.body = stanza.body;
            fail_if_not(f.decryptor.decrypt_message(message, stanza, f.conversation()),
                "fixture must authenticate a real legacy key transport");
            fail_if(message.body != null,
                "XEP-0384 key transport has no chat payload; its outer body must not become OMEMO content");
            fail_if(message.encryption != Encryption.OMEMO,
                "the key transport must still process the authenticated recipient key");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_recovery() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            CiphertextMessage delayed = f.alice.create_session_cipher(f.bob_address).encrypt("old delayed message".data);
            uint8[] old_wire = delayed.serialized;
            uint8[] bad = f.stale_packet();
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            fail_if(f.decryptor.decrypt_message(f.message(), f.stanza(bad), f.conversation()));
            fail_if_not_eq_int(f.decryptor.last_failure_code, ErrorCode.INVALID_KEY_ID);
            fail_if_not(f.decryptor.last_failure_detail.contains("reason=own-one-time-prekey-missing;"),
                    "actual missing one-time key must remain diagnosed after PREKEY rollback");
            fail_if_not(f.decryptor.last_failure_detail.contains("prekey_id=61;signed_prekey_id=62;missing_key_id=61"));
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)), "failed receive must preserve the old ratchet before the asynchronous bundle result");
            drain();
            fail_if_not_eq_int(f.stream.requests, 1);
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            StanzaNode response = f.stream.messages[0];
            fail_if_not_eq_str(response.get_attribute("to"), f.alice_jid.to_string());
            fail_if(response.get_subnode("body") != null);
            StanzaNode encrypted = response.get_subnode("encrypted", OMEMO_NS);
            fail_if(encrypted.get_subnode("payload", OMEMO_NS) != null);
            StanzaNode header = encrypted.get_subnode("header", OMEMO_NS);
            var keys = header.get_subnodes("key", OMEMO_NS);
            fail_if_not_eq_int(keys.size, 1);
            StanzaNode key = keys[0];
            fail_if_not_eq_int(key.get_attribute_int("rid"), 11);
            fail_if_not_eq_str(key.get_attribute("prekey"), "true");
            uint8[] transported = f.alice.create_session_cipher(f.bob_address).decrypt_pre_key_message(f.context.deserialize_signal_pre_key_message(Base64.decode(key.get_string_content())));
            fail_if_not_eq_int(transported.length, 32);
            CiphertextMessage repaired = f.alice.create_session_cipher(f.bob_address).encrypt("repaired peer".data);
            uint8[] clear = f.bob.create_session_cipher(f.alice_address).decrypt_message(f.context.deserialize_signal_message(repaired.serialized));
            fail_if_not_eq_uint8_arr(clear, "repaired peer".data);
            clear = f.bob.create_session_cipher(f.alice_address).decrypt_message(f.context.deserialize_signal_message(old_wire));
            fail_if_not_eq_uint8_arr(clear, "old delayed message".data);
            // A fresh Stanza object must not defeat packet-hash deduplication.
            f.decryptor.decrypt_message(f.message(), f.stanza(bad), f.conversation());
            drain();
            fail_if_not_eq_int(f.stream.requests, 1);
            fail_if_not_eq_int(f.stream.messages.size, 1);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_private_muc_recovery() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            f.enable_muc();
            CiphertextMessage delayed = f.alice.create_session_cipher(f.bob_address).encrypt("old delayed room message".data);
            uint8[] old_wire = delayed.serialized;
            uint8[] bad = f.stale_packet();
            string old_session = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            string own_identity = Base64.encode(f.bob.identity_key_pair.public.serialize());
            fail_if(f.decryptor.decrypt_message(f.muc_message(), f.muc_stanza(bad), f.room_conversation));
            fail_if_not_eq_int(f.decryptor.last_failure_code, ErrorCode.INVALID_KEY_ID);
            fail_if_not_eq_str(old_session, Base64.encode(f.bob.session_store.load_session(f.alice_address)),
                "failed MUC receive must preserve the old session before bundle confirmation");
            drain();
            fail_if_not_eq_int(f.stream.requests, 1, "only the trusted peer bundle may be fetched");
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            StanzaNode response = f.stream.messages[0];
            fail_if_not_eq_str(response.get_attribute("to"), f.alice_jid.to_string(),
                "a group receive repair must address the disclosed real bare peer, never the room");
            fail_if_not_eq_str(response.get_attribute("type"), MessageStanza.TYPE_CHAT);
            fail_if(response.get_subnode("body") != null);
            StanzaNode encrypted = response.get_subnode("encrypted", OMEMO_NS);
            fail_if(encrypted.get_subnode("payload", OMEMO_NS) != null);
            var keys = encrypted.get_subnode("header", OMEMO_NS).get_subnodes("key", OMEMO_NS);
            if (fail_if_not_eq_int(keys.size, 1)) return;
            fail_if_not_eq_int(keys[0].get_attribute_int("rid"), 11);
            fail_if_not_eq_str(keys[0].get_attribute("prekey"), "true");
            f.alice.create_session_cipher(f.bob_address).decrypt_pre_key_message(
                f.context.deserialize_signal_pre_key_message(Base64.decode(keys[0].get_string_content())));
            var next = f.muc_message();
            fail_if_not(f.decryptor.decrypt_message(next,
                    f.encrypted_muc_payload("future private room message"), f.room_conversation),
                "a genuine subsequent encrypted MUC payload must decrypt with the repaired peer");
            fail_if_not_eq_str(next.body, "future private room message");
            uint8[] old_clear = f.bob.create_session_cipher(f.alice_address).decrypt_message(
                f.context.deserialize_signal_message(old_wire));
            fail_if_not_eq_uint8_arr(old_clear, "old delayed room message".data,
                "repair must archive and retain old receive state");
            f.decryptor.decrypt_message(f.muc_message(), f.muc_stanza(bad), f.room_conversation);
            drain();
            fail_if_not_eq_int(f.stream.requests, 1, "repeated stale packets must not fetch another bundle");
            fail_if_not_eq_int(f.stream.messages.size, 1);
            fail_if_not_eq_int((int) f.bob.local_registration_id, 22);
            fail_if_not_eq_str(own_identity, Base64.encode(f.bob.identity_key_pair.public.serialize()),
                "automatic repair must preserve our device identity and fingerprint");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_private_muc_guards() {
        for (int variant = 0; variant < 7; variant++) {
            Fixture? f = null;
            try {
                f = new Fixture();
                f.establish();
                f.enable_muc(variant != 0, variant != 1, variant != 2);
                uint8[] bad = f.stale_packet();
                var message = f.muc_message();
                Conversation conversation = f.room_conversation;
                if (variant == 3) message.real_jid = null;
                if (variant == 4) conversation = new Conversation(f.room,
                    new Account(f.account.bare_jid, "other-row"), Conversation.Type.GROUPCHAT);
                if (variant == 5) {
                    message.account = new Account(f.account.bare_jid, "other-row");
                }
                if (variant == 6) {
                    f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                        .set(f.db.identity_meta.supports_omemo1, false).perform();
                }
                string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
                f.decryptor.decrypt_message(message, f.muc_stanza(bad), conversation);
                drain();
                fail_if_not_eq_int(f.stream.requests, 0, "an unsafe MUC context must not fetch a recovery bundle");
                fail_if_not_eq_int(f.stream.messages.size, 0);
                fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)));
            } catch (Error e) { fail_if_reached("guard %d: %s".printf(variant, e.message)); }
            finally { if (f != null) f.close(); }
        }
    }

    private void test_private_muc_envelope_guards() {
        for (int variant = 0; variant < 6; variant++) {
            Fixture? f = null;
            try {
                f = new Fixture();
                f.establish();
                f.enable_muc();
                var message = f.muc_message();
                Conversation conversation = f.room_conversation;
                MessageStanza stanza = f.muc_stanza(f.stale_packet(), variant != 2);
                if (variant == 0) stanza.add_flag(new MessageArchiveManagement.MessageFlag(f.room, null, "archive", null));
                if (variant == 1) stanza.stanza.put_node(new StanzaNode.build("delay", Xep.DelayedDelivery.NS_URI)
                    .put_attribute("stamp", "2020-01-01T00:00:00Z"));
                if (variant == 3) {
                    message.type_ = Dino.Entities.Message.Type.GROUPCHAT_PM;
                    stanza.type_ = MessageStanza.TYPE_CHAT;
                    conversation = new Conversation(f.occupant, f.account, Conversation.Type.GROUPCHAT_PM);
                }
                if (variant == 4) message.direction = Dino.Entities.Message.DIRECTION_SENT;
                if (variant == 5) {
                    var failure = new LegacyInvalidPreKey(f.account.bare_jid, 22,
                        Base64.encode(f.bob.identity_key_pair.public.serialize()), new uint8[]{1});
                    f.recovery.consider(message, stanza, conversation, failure);
                } else f.decryptor.decrypt_message(message, stanza, conversation);
                drain();
                fail_if_not_eq_int(f.stream.requests, 0, "only live received private-group payloads can request repair");
                fail_if_not_eq_int(f.stream.messages.size, 0);
            } catch (Error e) { fail_if_reached("envelope %d: %s".printf(variant, e.message)); }
            finally { if (f != null) f.close(); }
        }
    }

    private void test_private_muc_pending_change(int variant) {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            f.enable_muc();
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            f.stream.hold = true;
            f.decryptor.decrypt_message(f.muc_message(), f.muc_stanza(f.stale_packet()), f.room_conversation);
            drain();
            fail_if_not_eq_int(f.stream.requests, 1);
            if (variant == 0 || variant == 1) {
                f.muc_manager.part(f.account, f.room);
                drain();
                if (variant == 1) {
                    f.join_room(true);
                    f.stream.emit_occupant(f.occupant, f.alice_jid);
                }
            } else if (variant == 2) {
                f.stream.emit_occupant(f.occupant, f.alice_jid, false, true);
                f.stream.emit_occupant(f.occupant, new Jid("charlie@example.test"));
            } else if (variant == 3 || variant == 4) {
                f.stream.non_anonymous = false;
                f.refresh_room_privacy();
                if (variant == 4) {
                    f.stream.non_anonymous = true;
                    f.refresh_room_privacy();
                    f.stream.emit_occupant(f.occupant, f.alice_jid);
                }
            } else if (variant == 5) {
                f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                    .set(f.db.identity_meta.trust_level, TrustLevel.UNTRUSTED).perform();
            } else {
                f.module.detach(f.stream);
                f.module.attach(f.stream);
            }
            f.stream.reply();
            drain();
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "a stale pending room/device authorization must never send repair");
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)),
                "stale bundle completion must not replace the receive session");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_private_muc_pipeline_change() {
        Fixture? f = null;
        HeldSendListener? listener = null;
        try {
            f = new Fixture();
            f.establish();
            f.enable_muc();
            listener = new HeldSendListener();
            f.stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.connect(listener);
            f.decryptor.decrypt_message(f.muc_message(), f.muc_stanza(f.stale_packet()), f.room_conversation);
            drain();
            fail_if_not(listener.entered, "fixture must hold the real outgoing stanza pipeline");
            f.stream.emit_occupant(f.occupant, f.alice_jid, false, true);
            f.stream.emit_occupant(f.occupant, new Jid("charlie@example.test"));
            listener.release();
            drain();
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "identity must be checked again after the outgoing pipeline yields");
            fail_if_not(f.bob.is_persistence_ready,
                "discarding a stale transport must preserve the committed persistent ratchet");
        } catch (Error e) { fail_if_reached(e.message); }
        finally {
            if (listener != null) listener.release();
            drain();
            if (f != null) f.close();
        }
    }

    private void test_private_muc_pending_v4_session() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            f.enable_muc();
            f.stream.hold = true;
            f.decryptor.decrypt_message(f.muc_message(), f.muc_stanza(f.stale_packet()), f.room_conversation);
            drain();
            fail_if_not_eq_int(f.stream.requests, 1);
            // A legitimate OMEMO 2 session can appear while the legacy peer
            // bundle is pending. Build real native v4 state, never modify a
            // v3 record's version field to imitate that transition.
            Bundle.PreKey key = f.alice_bundle.pre_keys[0];
            uint8[] signature = f.context.calculate_signature(f.alice.identity_key_pair.private,
                f.alice_bundle.signed_pre_key.serialize_omemo());
            // The native record retains its creation version even when a
            // later builder requests version 4. Initialize a fresh v4 record
            // for this fixture's explicit protocol switch; the separate live
            // recovery roundtrip above covers preservation of old v3 state.
            f.bob.delete_session(f.alice_address);
            SessionBuilder builder = f.bob.create_session_builder(f.alice_address);
            builder.version = 4;
            builder.process_pre_key_bundle(create_pre_key_bundle(11, 11,
                key.key_id, key.key, f.alice_bundle.signed_pre_key_id,
                f.alice_bundle.signed_pre_key, signature, f.alice_bundle.identity_key));
            if (fail_if_not_eq_int((int) f.bob.create_session_cipher(f.alice_address).get_session_version(), 4,
                    "the negative fixture must contain genuine native v4 session state")) return;
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            f.stream.reply();
            drain();
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "legacy repair must never send against a current OMEMO 2 session");
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)),
                "legacy repair must not replace or archive the v4 session");
            fail_if_not_eq_int((int) f.bob.create_session_cipher(f.alice_address).get_session_version(), 4);
            fail_if_not(f.bob.is_persistence_ready);
            fail_if_not_eq_int((int) f.bob.local_registration_id, 22);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private static string session_bytes(Fixture f) throws Error {
        uint8[]? bytes = f.bob.session_store.load_session(f.alice_address);
        return bytes == null ? "missing" : Base64.encode((!) bytes);
    }

    private static string wire_identity(StanzaNode node) {
        StanzaNode header = node.get_subnode("encrypted", OMEMO_NS).get_subnode("header", OMEMO_NS);
        return node.get_attribute("id") + "|" + node.get_attribute("to") + "|" +
            node.get_attribute("type") + "|" + header.get_attribute("sid") + "|" +
            header.get_subnode("iv", OMEMO_NS).get_string_content() + "|" +
            header.get_subnode("key", OMEMO_NS).get_attribute("rid") + "|" +
            header.get_subnode("key", OMEMO_NS).get_attribute("prekey") + "|" +
            header.get_subnode("key", OMEMO_NS).get_string_content();
    }

    private static void receive_missing(Fixture f, bool group = false) throws Error {
        uint8[] packet = f.stale_packet();
        fail_if(f.decryptor.decrypt_message(group ? f.muc_message() : f.message(),
            group ? f.muc_stanza(packet) : f.stanza(packet),
            group ? f.room_conversation : f.conversation()));
        fail_if_not_eq_int(f.decryptor.last_failure_code, ErrorCode.INVALID_KEY_ID,
            "the trigger must be an actual native missing one-time-prekey receive");
        drain();
    }

    private static MessageStanza retain_unsent(Fixture f, bool group = false) throws Error {
        var listener = new HeldSendListener();
        var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
        messages.send_pipeline.connect(listener);
        try {
            receive_missing(f, group);
            if (!listener.entered || listener.captured == null) {
                throw new IOError.FAILED("Fixture must hold a committed native recovery response");
            }
            if (group) {
                f.stream.emit_occupant(f.occupant, f.alice_jid, false, true);
                f.stream.emit_occupant(f.occupant, new Jid("charlie@example.test"));
            } else {
                f.module.detach(f.stream);
                f.module.attach(f.stream);
            }
            listener.release();
            drain();
            fail_if_not_eq_int(f.stream.messages.size, 0, "the committed response must remain unsent");
            if (group) {
                f.stream.emit_occupant(f.occupant, new Jid("charlie@example.test"), false, true);
                f.stream.emit_occupant(f.occupant, f.alice_jid);
                drain();
                Jid? peer = f.muc_manager.get_verified_private_muc_participant(f.account, f.room, f.occupant);
                if (peer == null || !peer.equals_bare(f.alice_jid)) {
                    throw new IOError.FAILED("Fixture must restore authoritative private-room membership");
                }
            }
            return (!) listener.captured;
        } finally {
            listener.release();
            drain();
            messages.send_pipeline.disconnect(listener);
        }
    }

    private static void accept_transport(Fixture f, StanzaNode response) throws Error {
        var key = response.get_subnode("encrypted", OMEMO_NS).get_subnode("header", OMEMO_NS)
            .get_subnode("key", OMEMO_NS);
        uint8[] decoded = f.alice.create_session_cipher(f.bob_address).decrypt_pre_key_message(
            f.context.deserialize_signal_pre_key_message(Base64.decode(key.get_string_content())));
        fail_if_not_eq_int(decoded.length, 32);
    }

    private void test_unsent_retry(bool group) {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            if (group) f.enable_muc();
            CiphertextMessage old = f.alice.create_session_cipher(f.bob_address).encrypt("old archived receive".data);
            string own = Base64.encode(f.bob.identity_key_pair.public.serialize());
            MessageStanza original = retain_unsent(f, group);
            string wire = wire_identity(original.stanza);
            string committed = session_bytes(f);
            string base_key = Base64.encode(f.bob.load_session(f.alice_address).state.alice_base_key.serialize());
            receive_missing(f, group);
            fail_if_not_eq_int(f.stream.requests, 1, "retry must not fetch another bundle");
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            fail_if_not_eq_str(wire_identity(f.stream.messages[0]), wire,
                "fresh authorization must redeliver the exact ID, IV and native PREKEY ciphertext");
            fail_if_not_eq_str(session_bytes(f), committed, "delivery must neither encrypt nor archive another native state");
            fail_if_not_eq_str(Base64.encode(f.bob.load_session(f.alice_address).state.alice_base_key.serialize()), base_key);
            // A successful write retains protection until authentication, even
            // when another genuine stale packet arrives.
            receive_missing(f, group);
            fail_if_not_eq_int(f.stream.messages.size, 1);
            fail_if_not_eq_int(f.stream.requests, 1);
            accept_transport(f, f.stream.messages[0]);
            var next = group ? f.muc_message() : f.message();
            fail_if_not(f.decryptor.decrypt_message(next, f.encrypted_payload("future authenticated payload", group),
                group ? f.room_conversation : f.conversation()));
            fail_if_not_eq_str(next.body, "future authenticated payload");
            fail_if(next.encryption != Encryption.OMEMO);
            uint8[] clear = f.bob.create_session_cipher(f.alice_address).decrypt_message(
                f.context.deserialize_signal_message(old.serialized));
            fail_if_not_eq_uint8_arr(clear, "old archived receive".data);
            fail_if_not_eq_str(Base64.encode(f.bob.identity_key_pair.public.serialize()), own);
            fail_if_not_eq_int((int) f.bob.local_registration_id, 22);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_delivery_limiter() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            var failure = f.failure(f.stale_packet());
            string base_key;
            MessageStanza response = f.recovery.build_response(failure, f.alice_bundle, out base_key);
            var transport = new LegacyRecoveryTransport(failure, response, base_key,
                f.identity_id, f.bob.local_registration_id,
                Base64.encode(f.bob.identity_key_store.identity_key_public.get_data()));
            var limiter = new LegacyRecoveryLimiter();
            int64 now = 100 * TimeSpan.SECOND;
            var first = limiter.reserve(failure, now);
            limiter.committed(first, base_key, transport);
            limiter.complete(first);
            fail_if(limiter.reserve(failure, now + TimeSpan.SECOND) != null,
                "an exact stale-packet replay must retain its bounded deduplication window");
            var fresh = f.failure(f.stale_packet());
            LegacyRecoveryAttempt? retry = limiter.reserve(fresh, now + 2 * TimeSpan.HOUR);
            if (fail_if(retry == null, "an unsent packet must remain redeliverable after two hours")) return;
            fail_if(retry.transport != transport, "retry must reuse the immutable original packet object");
            fail_if_not_eq_str(wire_identity(retry.transport.create_stanza().stanza), wire_identity(response.stanza));
            limiter.write_started(retry, now + 2 * TimeSpan.HOUR);
            limiter.complete(retry);
            fail_if(limiter.reserve(fresh, now + 2 * TimeSpan.HOUR + TimeSpan.SECOND) != null,
                "an uncertain write retains the existing cooldown");
            retry = limiter.reserve(fresh, now + 4 * TimeSpan.HOUR);
            if (fail_if(retry == null)) return;
            limiter.authenticated_from(f.alice_jid, 11, "old archived base");
            fail_if_not(limiter.is_pending(retry));
            limiter.delivered(retry);
            limiter.complete(retry);
            fail_if(limiter.reserve(fresh, now + 6 * TimeSpan.HOUR) != null,
                "successful delivery must retain confirmation protection beyond cooldown");
            limiter.authenticated_from(f.alice_jid, 11, base_key);
            retry = limiter.reserve(fresh, now + 6 * TimeSpan.HOUR);
            fail_if(retry == null, "a matching authenticated new base confirms the repair");
            if (retry != null) limiter.complete(retry);
            var bounded = new LegacyRecoveryLimiter();
            for (int i = 0; i < LegacyRecoveryLimiter.MAX_RECENT; i++) {
                var target = new LegacyInvalidPreKey(f.alice_jid, 100 + i, failure.identity_key, new uint8[]{1});
                var entry = bounded.reserve(target, now);
                if (fail_if(entry == null)) return;
                bounded.committed(entry, "base-" + i.to_string());
                bounded.complete(entry);
            }
            fail_if(bounded.reserve(new LegacyInvalidPreKey(f.alice_jid, 999, failure.identity_key,
                new uint8[]{2}), now + 2 * TimeSpan.HOUR) != null,
                "confirmation state must stay bounded even after replay entries expire");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_cached_retry_guards() {
        for (int variant = 0; variant < 9; variant++) {
            Fixture? f = null;
            HeldSendListener? listener = null;
            try {
                f = new Fixture(); f.establish();
                retain_unsent(f);
                listener = new HeldSendListener();
                var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
                messages.send_pipeline.connect(listener);
                receive_missing(f);
                if (fail_if_not(listener.entered, "fixture must hold an authorized cached delivery retry")) return;
                if (variant == 0) {
                    f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                        .set(f.db.identity_meta.trust_level, TrustLevel.UNTRUSTED).perform_checked();
                } else if (variant == 1) {
                    f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                        .set(f.db.identity_meta.identity_key_changed, true)
                        .set(f.db.identity_meta.identity_key_public_base64,
                            Base64.encode(f.context.generate_key_pair().public.serialize())).perform_checked();
                } else if (variant == 2) f.bob.identity_key_store.local_registration_id = 23;
                else if (variant == 3) {
                    f.bob.identity_key_store.identity_key_public = new Bytes(f.context.generate_key_pair().public.serialize());
                } else if (variant == 4) {
                    f.db.identity.update().with(f.db.identity.id, "=", f.identity_id)
                        .set(f.db.identity.account_id, f.account.id + 1000).perform_checked();
                } else if (variant == 5) {
                    f.module.detach(f.stream); f.module.attach(f.stream);
                } else if (variant == 6) f.install_native_v4_session();
                else if (variant == 7) f.bob.delete_session(f.alice_address);
                else f.bob.identity_key_store.identity_key_private = new Bytes(f.context.generate_key_pair().private.serialize());
                string preserved = session_bytes(f);
                listener.release(); drain(); messages.send_pipeline.disconnect(listener);
                fail_if_not_eq_int(f.stream.messages.size, 0, "cached transport must recheck all cryptographic and attachment authority after yield");
                fail_if_not_eq_int(f.stream.requests, 1);
                fail_if_not_eq_str(session_bytes(f), preserved, "rejected cached delivery must not mutate native state");
                if (variant == 6) fail_if_not_eq_int((int) f.bob.create_session_cipher(f.alice_address).get_session_version(), 4);
                if (variant == 0 || variant == 5) {
                    if (variant == 0) f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                        .set(f.db.identity_meta.trust_level, TrustLevel.TRUSTED).perform_checked();
                    receive_missing(f);
                    fail_if_not_eq_int(f.stream.messages.size, 1, "restored authorization may resend the same cached packet");
                    fail_if_not_eq_int(f.stream.requests, 1);
                    fail_if_not_eq_str(session_bytes(f), preserved);
                }
            } catch (Error e) { fail_if_reached(e.message); }
            finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
        }
    }

    private void test_cached_muc_guards() {
        for (int variant = 0; variant < 6; variant++) {
            Fixture? f = null;
            HeldSendListener? listener = null;
            try {
                f = new Fixture(); f.establish(); f.enable_muc();
                retain_unsent(f, true);
                listener = new HeldSendListener();
                var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
                messages.send_pipeline.connect(listener);
                receive_missing(f, true);
                if (fail_if_not(listener.entered)) return;
                string preserved = session_bytes(f);
                if (variant == 0 || variant == 1) {
                    f.muc_manager.part(f.account, f.room); drain();
                    if (variant == 1) { f.join_room(true); f.stream.emit_occupant(f.occupant, f.alice_jid); }
                } else if (variant == 2 || variant == 3) {
                    f.stream.emit_occupant(f.occupant, f.alice_jid, false, true);
                    f.stream.emit_occupant(f.occupant, variant == 2 ? new Jid("charlie@example.test") : null);
                } else {
                    if (variant == 4) f.stream.members_only = false;
                    else f.stream.non_anonymous = false;
                    f.refresh_room_privacy();
                }
                listener.release(); drain(); messages.send_pipeline.disconnect(listener);
                fail_if_not_eq_int(f.stream.messages.size, 0, "cached direct reply still requires fresh private-room participant authority");
                fail_if_not_eq_str(session_bytes(f), preserved);
                fail_if_not_eq_int(f.stream.requests, 1);
            } catch (Error e) { fail_if_reached(e.message); }
            finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
        }
    }

    private void test_immutable_wire() {
        Fixture? f = null; HeldSendListener? listener = null;
        try {
            f = new Fixture(); f.establish();
            listener = new HeldSendListener();
            var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
            messages.send_pipeline.connect(listener);
            receive_missing(f);
            if (fail_if(listener.captured == null)) return;
            string original = wire_identity(listener.captured.stanza);
            string preserved = session_bytes(f);
            listener.captured.to = new Jid("attacker@example.test");
            listener.captured.body = "injected outer body";
            listener.captured.stanza.get_subnode("encrypted", OMEMO_NS).get_subnode("header", OMEMO_NS)
                .get_subnode("iv", OMEMO_NS).put_node(new StanzaNode.text("changed"));
            listener.release(); drain(); messages.send_pipeline.disconnect(listener);
            fail_if_not_eq_int(f.stream.messages.size, 0);
            receive_missing(f);
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            fail_if_not_eq_str(wire_identity(f.stream.messages[0]), original,
                "pipeline mutation must not poison the retained immutable snapshot");
            fail_if(f.stream.messages[0].get_subnode("body") != null);
            fail_if_not_eq_str(session_bytes(f), preserved);
            fail_if_not_eq_int(f.stream.requests, 1);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
    }

    private void test_write_errors() {
        for (int mode = 1; mode <= 2; mode++) {
            Fixture? f = null;
            try {
                f = new Fixture(); f.establish();
                f.stream.message_write_failure = mode;
                receive_missing(f);
                string preserved = session_bytes(f);
                fail_if_not_eq_int(f.stream.messages.size, mode == 1 ? 0 : 1);
                f.stream.message_write_failure = 0;
                receive_missing(f);
                fail_if_not_eq_int(f.stream.messages.size, mode == 1 ? 0 : 1,
                    "failed and ambiguous writes are rate-limited, never a fresh immediate rekey");
                fail_if_not_eq_int(f.stream.requests, 1);
                fail_if_not_eq_str(session_bytes(f), preserved);
                if (mode == 2) {
                    accept_transport(f, f.stream.messages[0]);
                    var next = f.message();
                    fail_if_not(f.decryptor.decrypt_message(next, f.encrypted_payload("ambiguous delivery authenticated"), f.conversation()));
                    fail_if_not_eq_str(next.body, "ambiguous delivery authenticated");
                    receive_missing(f);
                    fail_if_not_eq_int(f.stream.messages.size, 1,
                        "authenticated confirmation and ordinary cooldown prevent duplicate writes");
                }
            } catch (Error e) { fail_if_reached(e.message); }
            finally { if (f != null) f.close(); }
        }
    }

    private void test_retry_after_archive_promotion() {
        Fixture? f = null;
        try {
            f = new Fixture(); f.establish();
            CiphertextMessage delayed = f.alice.create_session_cipher(f.bob_address).encrypt("archived authenticated state".data);
            MessageStanza first = retain_unsent(f);
            uint8[] clear = f.bob.create_session_cipher(f.alice_address).decrypt_message(
                f.context.deserialize_signal_message(delayed.serialized));
            fail_if_not_eq_uint8_arr(clear, "archived authenticated state".data);
            string preserved = session_bytes(f);
            receive_missing(f);
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            fail_if_not_eq_str(wire_identity(f.stream.messages[0]), wire_identity(first.stanza));
            fail_if_not_eq_int(f.stream.requests, 1, "old archive promotion cannot enable a second builder");
            fail_if_not_eq_str(session_bytes(f), preserved,
                "native archived-base membership permits same-wire delivery without mutation");
            accept_transport(f, f.stream.messages[0]);
            var next = f.message();
            fail_if_not(f.decryptor.decrypt_message(next, f.encrypted_payload("future after archived promotion"), f.conversation()));
            fail_if_not_eq_str(next.body, "future after archived promotion");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_confirmation_during_pipeline() {
        Fixture? f = null; HeldSendListener? listener = null;
        try {
            f = new Fixture(); f.establish();
            listener = new HeldSendListener();
            var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
            messages.send_pipeline.connect(listener);
            receive_missing(f);
            if (fail_if(listener.captured == null)) return;
            // Another successful message can already have established this
            // committed session. Model that with real native peer receipt.
            accept_transport(f, listener.captured.stanza);
            var next = f.message();
            fail_if_not(f.decryptor.decrypt_message(next, f.encrypted_payload("confirmed before queued write"), f.conversation()));
            string preserved = session_bytes(f);
            listener.release(); drain(); messages.send_pipeline.disconnect(listener);
            fail_if_not_eq_int(f.stream.messages.size, 0, "authenticated confirmation cancels the redundant queued transport");
            fail_if_not_eq_str(session_bytes(f), preserved);
            fail_if_not_eq_int(f.stream.requests, 1);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
    }

    private void test_approved_peer_change() {
        Fixture? f = null;
        try {
            f = new Fixture(); f.establish();
            receive_missing(f);
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            // A key is not approved merely because an incoming packet claims it.
            Store replacement = setup_test_store_context(f.context);
            replacement.identity_key_store.local_registration_id = 11;
            f.alice = replacement;
            f.alice_bundle = f.make_bundle(replacement, 81, 82);
            f.stream.reply_bundle = f.alice_bundle;
            f.bob.identity_key_store.delete_identity(f.alice_address);
            f.bob.identity_key_store.save_identity(f.alice_address, f.alice.identity_key_pair.public.serialize());
            f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                .set(f.db.identity_meta.identity_key_public_base64, Base64.encode(f.alice.identity_key_pair.public.serialize()))
                .set(f.db.identity_meta.identity_key_changed, true).set(f.db.identity_meta.trust_level, TrustLevel.UNTRUSTED).perform_checked();
            // This packet really references the already missing local key,
            // but until explicit approval it cannot retire the old guard.
            receive_missing(f);
            fail_if_not_eq_int(f.stream.requests, 1);
            fail_if_not_eq_int(f.stream.messages.size, 1);
            f.trust.set_device_trust(f.account, f.alice_jid, 11, TrustLevel.VERIFIED);
            receive_missing(f);
            fail_if_not_eq_int(f.stream.requests, 2, "an explicitly approved replacement identity has a new recovery scope");
            if (fail_if_not_eq_int(f.stream.messages.size, 2)) return;
            accept_transport(f, f.stream.messages[1]);
            var next = f.message();
            fail_if_not(f.decryptor.decrypt_message(next, f.encrypted_payload("approved replacement peer"), f.conversation()));
            fail_if_not_eq_str(next.body, "approved replacement peer");
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_persisted_own_change() {
        Fixture? f = null;
        try {
            f = new Fixture(); f.establish();
            receive_missing(f);
            if (fail_if_not_eq_int(f.stream.messages.size, 1)) return;
            ECKeyPair own = f.context.generate_key_pair();
            f.bob.identity_key_store.identity_key_private = new Bytes(own.private.serialize());
            f.bob.identity_key_store.identity_key_public = new Bytes(own.public.serialize());
            f.bob.identity_key_store.local_registration_id = 23;
            string protected_state = session_bytes(f);
            uint8[] intermediate = f.stale_packet();
            fail_if(f.decryptor.decrypt_message(f.message(), f.stanza(intermediate), f.conversation()));
            drain();
            fail_if_not_zero_int(f.decryptor.last_failure_code,
                "an unmatched runtime/persisted own identity must be rejected before native decryption");
            fail_if_not_eq_str(session_bytes(f), protected_state,
                "the rejected unpersisted own identity must not mutate the native session");
            fail_if_not_eq_int(f.stream.requests, 1, "runtime-only identity mutation must not clear protection");
            fail_if_not_eq_int(f.stream.messages.size, 1);
            f.db.identity.update().with(f.db.identity.id, "=", f.identity_id)
                .set(f.db.identity.device_id, 23)
                .set(f.db.identity.identity_key_private_base64, Base64.encode(own.private.serialize()))
                .set(f.db.identity.identity_key_public_base64, Base64.encode(own.public.serialize())).perform_checked();
            receive_missing(f);
            fail_if_not_eq_int(f.stream.requests, 2, "a durably replaced own identity retires its obsolete guard");
            fail_if_not_eq_int(f.stream.messages.size, 2);
            fail_if_not_eq_int((int) f.bob.local_registration_id, 23);
            fail_if_not_eq_str(Base64.encode(f.bob.identity_key_pair.public.serialize()), Base64.encode(own.public.serialize()));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_explicit_reset() {
        Fixture? f = null; HeldSendListener? listener = null;
        try {
            f = new Fixture(); f.establish();
            f.register_account_module(); f.interactor.module_manager.initialize(f.account);
            listener = new HeldSendListener();
            var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
            messages.send_pipeline.connect(listener);
            receive_missing(f);
            if (fail_if(listener.captured == null)) return;
            var row = f.db.identity_meta.get_device_checked(f.identity_id, f.alice_jid.to_string(), 11);
            var target = new DeviceKeyTarget(f.account, row, f.db);
            // A failed explicit operation emits no reset and preserves both
            // native state and the in-flight guard.
            f.db.exec("CREATE TRIGGER reject_explicit_reset BEFORE UPDATE ON identity_meta BEGIN SELECT RAISE(ABORT, 'isolated reset failure'); END");
            string preserved = session_bytes(f);
            bool rejected = false;
            try { f.trust.perform_key_action(f.account, f.alice_jid, target, -2); }
            catch (Error e) { rejected = true; }
            f.db.exec("DROP TRIGGER reject_explicit_reset");
            fail_if_not(rejected);
            fail_if_not_eq_str(session_bytes(f), preserved);
            // A same-JID reset belonging to another account object must not
            // cancel this account's pending delivery.
            var other = new Account(new Jid("other@example.test"), "isolated");
            other.id = f.account.id;
            f.trust.session_reset(other, f.alice_jid, 11);
            f.trust.perform_key_action(f.account, f.alice_jid, target, -2);
            fail_if(f.bob.contains_session(f.alice_address));
            listener.release(); drain(); messages.send_pipeline.disconnect(listener);
            fail_if_not_eq_int(f.stream.messages.size, 0, "successful explicit reset cancels the old queued wire packet");
            // The action may refresh metadata by IQ; exclude it from recovery
            // accounting and allow the user-requested fresh native state.
            int requests = f.stream.requests;
            receive_missing(f);
            fail_if_not_eq_int(f.stream.requests, requests + 1);
            fail_if_not_eq_int(f.stream.messages.size, 1,
                "successful manual reset must not leave an obsolete confirmation guard");
            fail_if_not(f.bob.contains_session(f.alice_address));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
    }

    private void test_contact_reset() {
        Fixture? f = null; HeldSendListener? listener = null;
        try {
            f = new Fixture(); f.establish();
            f.register_account_module(); f.interactor.module_manager.initialize(f.account);
            listener = new HeldSendListener();
            var messages = f.stream.get_module<MessageModule>(MessageModule.IDENTITY);
            messages.send_pipeline.connect(listener);
            receive_missing(f);
            if (fail_if(listener.captured == null)) return;
            string preserved = session_bytes(f);
            var scope = new AccountKeyScope(f.account, f.db);
            f.db.exec("CREATE TRIGGER reject_contact_reset BEFORE UPDATE ON identity BEGIN SELECT RAISE(ABORT, 'isolated contact reset failure'); END");
            bool rejected = false;
            try { f.trust.reset_all_sessions_checked(f.account, f.alice_jid, scope); }
            catch (Error e) { rejected = true; }
            f.db.exec("DROP TRIGGER reject_contact_reset");
            fail_if_not(rejected);
            fail_if_not_eq_str(session_bytes(f), preserved);
            var other = new Account(new Jid("other@example.test"), "isolated");
            other.id = f.account.id;
            // Even a replacement account with the same database number is
            // not this live account object's cryptographic lifecycle.
            f.trust.contact_sessions_reset(other, f.alice_jid);
            listener.release(); drain(); messages.send_pipeline.disconnect(listener);
            fail_if_not_eq_int(f.stream.messages.size, 1,
                "a failed reset and another account's reset must leave this valid delivery pending");
            fail_if_not_eq_str(session_bytes(f), preserved);
            f.trust.reset_all_sessions_checked(f.account, f.alice_jid, scope);
            fail_if(f.bob.contains_session(f.alice_address));
            receive_missing(f);
            fail_if_not_eq_int(f.stream.requests, 2,
                "a successful contact reset permits a user-requested fresh native repair");
            fail_if_not_eq_int(f.stream.messages.size, 2);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
    }

    private void test_plaintext_messages() {
        for (int group = 0; group < 2; group++) {
            Fixture? f = null;
            try {
                f = new Fixture(); f.establish();
                if (group == 1) f.enable_muc(false, true);
                var stanza = new MessageStanza();
                stanza.from = group == 1 ? f.occupant : f.alice_jid;
                stanza.to = f.account.bare_jid;
                stanza.type_ = group == 1 ? MessageStanza.TYPE_GROUPCHAT : MessageStanza.TYPE_CHAT;
                stanza.body = "ordinary plaintext remains ordinary plaintext";
                var message = group == 1 ? f.muc_message() : f.message();
                message.body = stanza.body;
                string preserved = session_bytes(f);
                fail_if(f.decryptor.decrypt_message(message, stanza, group == 1 ? f.room_conversation : f.conversation()));
                drain();
                fail_if_not_eq_str(message.body, stanza.body);
                fail_if(message.encryption != Encryption.NONE);
                fail_if_not_eq_int(f.stream.requests, 0);
                fail_if_not_eq_int(f.stream.messages.size, 0);
                fail_if_not_eq_str(session_bytes(f), preserved);
            } catch (Error e) { fail_if_reached(e.message); }
            finally { if (f != null) f.close(); }
        }
    }

    private void test_backing_scope() {
        for (int variant = 0; variant < 2; variant++) {
            Fixture? f = null; HeldSendListener? listener = null;
            try {
                f = new Fixture(); f.establish();
                LegacyInvalidPreKey failure = f.failure(f.stale_packet());
                if (variant == 1) {
                    retain_unsent(f);
                    listener = new HeldSendListener();
                    f.stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.connect(listener);
                    receive_missing(f);
                    if (fail_if_not(listener.entered)) return;
                }
                BackedSessionStore original = (BackedSessionStore) f.bob.session_store;
                string preserved = session_bytes(f);
                var other = new Account(new Jid("other-owner@example.test"), "isolated");
                other.persist(f.app_db);
                f.db.identity.upsert().value(f.db.identity.account_id, other.id, true)
                    .value(f.db.identity.device_id, 22)
                    .value(f.db.identity.identity_key_public_base64,
                        Base64.encode(f.bob.identity_key_store.identity_key_public.get_data()))
                    .value(f.db.identity.identity_key_private_base64,
                        Base64.encode(f.bob.identity_key_store.identity_key_private.get_data())).perform_checked();
                int other_identity = f.db.identity.get_id_checked(other.id);
                var foreign = new BackedSessionStore(f.db, other_identity);
                foreign.store_session(f.alice_address, Base64.decode(preserved));
                f.bob.session_store = foreign;
                if (variant == 0) {
                    bool denied = false;
                    string base_key;
                    try { f.recovery.build_response(failure, f.alice_bundle, out base_key); }
                    catch (Error e) { denied = true; }
                    fail_if_not(denied,
                        "matching own public/private/registration values cannot authorize a foreign native backing identity");
                } else {
                    listener.release(); drain();
                    f.stream.get_module<MessageModule>(MessageModule.IDENTITY).send_pipeline.disconnect(listener);
                    fail_if_not_eq_int(f.stream.requests, 1);
                }
                fail_if_not_eq_int(f.stream.messages.size, 0);
                fail_if_not_eq_str(session_bytes(f), preserved, "foreign persisted/native rows must remain untouched");
                fail_if_not_eq_str(Base64.encode(original.load_session(f.alice_address)), preserved,
                    "the original account's native state must remain untouched");
                var reloaded_original = new BackedSessionStore(f.db, f.identity_id);
                var reloaded_foreign = new BackedSessionStore(f.db, other_identity);
                fail_if_not_eq_str(Base64.encode(reloaded_original.load_session(f.alice_address)), preserved);
                fail_if_not_eq_str(Base64.encode(reloaded_foreign.load_session(f.alice_address)), preserved);
            } catch (Error e) { fail_if_reached(e.message); }
            finally { if (listener != null) listener.release(); drain(); if (f != null) f.close(); }
        }
    }

    private void test_trust() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            var failure = f.failure(f.stale_packet());
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            foreach (TrustLevel level in new TrustLevel[]{TrustLevel.UNKNOWN, TrustLevel.UNTRUSTED}) {
                f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id).set(f.db.identity_meta.trust_level, level).perform();
                bool denied = false;
                string base_key;
                try { f.recovery.build_response(failure, f.alice_bundle, out base_key); }
                catch (Error e) { denied = true; }
                fail_if_not(denied);
            }
            f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id).set(f.db.identity_meta.trust_level, TrustLevel.TRUSTED).perform();
            failure.identity_key = Base64.encode(f.bob.identity_key_pair.public.serialize());
            bool denied = false;
            string base_key;
            try { f.recovery.build_response(failure, f.alice_bundle, out base_key); }
            catch (Error e) { denied = true; }
            fail_if_not(denied);
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_message_guards() {
        Fixture? f = null;
        try {
            f = new Fixture();
            var failure = f.failure(new uint8[]{1, 2});
            var message = f.message();
            var conversation = f.conversation();
            fail_if_not(LegacyPreKeyRecovery.allows_message(message, f.stanza(new uint8[]{1}), conversation, failure));
            fail_if(LegacyPreKeyRecovery.allows_message(message, f.stanza(new uint8[]{1}, false), conversation, failure));
            var delayed = f.stanza(new uint8[]{1});
            delayed.stanza.put_node(new StanzaNode.build("delay", Xmpp.Xep.DelayedDelivery.NS_URI).put_attribute("stamp", "invalid"));
            fail_if(LegacyPreKeyRecovery.allows_message(message, delayed, conversation, failure));
            var archived = f.stanza(new uint8[]{1});
            archived.add_flag(new MessageArchiveManagement.MessageFlag(f.account.bare_jid, null, "old", null));
            fail_if(LegacyPreKeyRecovery.allows_message(message, archived, conversation, failure));
            message.direction = Dino.Entities.Message.DIRECTION_SENT;
            fail_if(LegacyPreKeyRecovery.allows_message(message, f.stanza(new uint8[]{1}), conversation, failure));
            message.direction = Dino.Entities.Message.DIRECTION_RECEIVED;
            conversation.type_ = Conversation.Type.GROUPCHAT;
            fail_if(LegacyPreKeyRecovery.allows_message(message, f.stanza(new uint8[]{1}), conversation, failure));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_limiter() {
        try {
            var limiter = new LegacyRecoveryLimiter();
            var jid = new Jid("alice@example.test");
            var failure = new LegacyInvalidPreKey(jid, 11, "known", new uint8[]{1});
            int64 now = 100 * TimeSpan.SECOND;
            LegacyRecoveryAttempt attempt = limiter.reserve(failure, now);
            fail_if(attempt == null);
            fail_if(limiter.reserve(failure, now) != null);
            limiter.complete(attempt);
            fail_if(limiter.reserve(failure, now + LegacyRecoveryLimiter.COOLDOWN) != null);
            var different = new LegacyInvalidPreKey(jid, 11, "known", new uint8[]{2});
            fail_if(limiter.reserve(different, now + TimeSpan.SECOND) != null);
            attempt = limiter.reserve(different, now + LegacyRecoveryLimiter.COOLDOWN);
            fail_if(attempt == null);
            limiter.committed(attempt, "new-session-base-key");
            limiter.authenticated_from(jid, 11);
            fail_if_not(limiter.is_pending(attempt), "An unrelated old receive must not cancel the committed recovery transport");
            limiter.complete(attempt);
            limiter.authenticated_from(jid, 11, "old-archived-base-key");
            var third = new LegacyInvalidPreKey(jid, 11, "known", new uint8[]{3});
            fail_if(limiter.reserve(third, now + 2 * LegacyRecoveryLimiter.REPLAY_WINDOW) != null,
                "Unconfirmed rekeys must stay blocked beyond cooldown/replay expiry");
            limiter.authenticated_from(jid, 11, "new-session-base-key");
            attempt = limiter.reserve(third, now + 2 * LegacyRecoveryLimiter.REPLAY_WINDOW);
            fail_if(attempt == null);
            limiter.complete(attempt);
            for (int i = 0; i < LegacyRecoveryLimiter.MAX_PENDING; i++) {
                fail_if(limiter.reserve(new LegacyInvalidPreKey(jid, 100 + i, "known", new uint8[]{3}), now) == null);
            }
            fail_if(limiter.reserve(new LegacyInvalidPreKey(jid, 999, "known", new uint8[]{4}), now) != null);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_attachment_change() { test_pending_change(false); }
    private void test_pending_trust_revocation() { test_pending_change(true); }

    private void test_pending_change(bool revoke_trust) {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            uint8[] bad = f.stale_packet();
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            f.stream.hold = true;
            f.decryptor.decrypt_message(f.message(), f.stanza(bad), f.conversation());
            drain();
            fail_if_not_eq_int(f.stream.requests, 1);
            if (revoke_trust) {
                f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id).set(f.db.identity_meta.trust_level, TrustLevel.UNTRUSTED).perform();
            } else {
                f.module.detach(f.stream);
                f.module.attach(f.stream);
            }
            f.stream.reply();
            drain();
            fail_if_not_eq_int(f.stream.messages.size, 0);
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)));
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_transaction_failure() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.establish();
            var failure = f.failure(f.stale_packet());
            string before = Base64.encode(f.bob.session_store.load_session(f.alice_address));
            f.db.exec("CREATE TRIGGER reject_recovery BEFORE INSERT ON session BEGIN SELECT RAISE(ABORT, 'injected recovery write failure'); END");
            bool rejected = false;
            string base_key;
            GLib.Test.expect_message("OMEMO", LogLevelFlags.LEVEL_WARNING,
                "*Native OMEMO store callback failed*injected recovery write failure*");
            try { f.recovery.build_response(failure, f.alice_bundle, out base_key); }
            catch (Error e) { rejected = true; }
            GLib.Test.assert_expected_messages();
            f.db.exec("DROP TRIGGER reject_recovery");
            fail_if_not(rejected);
            fail_if_not(f.bob.is_persistence_ready);
            fail_if_not_eq_str(before, Base64.encode(f.bob.session_store.load_session(f.alice_address)));
            var reopened = new BackedSessionStore(f.db, f.identity_id);
            fail_if_not_eq_str(before, Base64.encode(reopened.load_session(f.alice_address)));
            fail_if_not_eq_int(f.stream.messages.size, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }

    private void test_optional_prekey_id() {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.build_alice_session(f.bob_bundle, false);
            uint8[] keytag = new uint8[32];
            CiphertextMessage packet = f.alice.create_session_cipher(f.bob_address).encrypt(keytag);
            var native = f.context.deserialize_signal_pre_key_message(packet.serialized);
            fail_if(native.has_pre_key_id());
            var data = new Xmpp.Xep.Omemo.ParsedData();
            data.sid = 11;
            data.is_prekey = true;
            data.encrypted_key = packet.serialized;
            data.ciphertext = new uint8[0];
            data.iv = new uint8[12];
            uint8[] decoded = f.decryptor.decrypt_key(data, f.alice_jid);
            fail_if_not_eq_int(decoded.length, 16);
            // Successful PREKEY receipt may refresh our own bundle. It must
            // not send a recovery key transport for the optional missing ID.
            fail_if_not_eq_int(f.stream.messages.size, 0);
        } catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) f.close(); }
    }
}

}
