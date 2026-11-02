using Dino.Entities;
using Dino.Plugins.Omemo;
using Gee;
using Xmpp;

namespace Omemo.Test {

class MucHistoricalReceiveTest : Gee.TestCase {
    private const string OMEMO_NS = "eu.siacs.conversations.axolotl";
    private const string PUBSUB_NS = "http://jabber.org/protocol/pubsub";

    internal MucHistoricalReceiveTest() {
        base("MucHistoricalReceive");
        add_test("private_MAM_preserves_native_historical_sender_after_nick_reuse", () => test_identity(0));
        add_test("public_plaintext_MAM_uses_authorized_original_sender", () => test_identity(1));
        add_test("MAM_without_original_JID_never_uses_live_nickname", () => test_identity(2));
        add_test("wrong_archive_authority_never_discloses_original_sender", () => test_identity(3));
        add_test("wrong_account_never_discloses_original_sender", () => test_identity(4));
        add_test("anonymous_room_never_discloses_original_sender", () => test_identity(5));
        add_test("live_forged_item_cannot_override_live_sender", () => test_identity(6));
        add_test("delayed_history_never_uses_live_nickname", () => test_identity(7));
        add_test("invalid_archived_JID_does_not_become_a_sender", () => test_identity(8));
        add_test("MAM_without_query_identity_never_discloses_original_sender", () => test_identity(9));
        add_test("room_leave_revokes_historical_real_JID_disclosure", () => test_identity(10));
        add_test("direct_CHAT_is_not_rewritten_by_MUC_listener", () => test_identity(11));
        add_test("native_anonymous_history_does_not_republish_sender_identity", () => test_identity(12));
        add_test("native_pending_room_refresh_does_not_republish_sender_identity", () => test_identity(13));
        add_test("native_failed_room_refresh_does_not_republish_sender_identity", () => test_identity(14));
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
        internal bool hold_room_info = false;
        private StanzaNode? held_room_request;
        private StanzaNode? held_room_result;

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
            if (node.name == "message") messages.add(node);
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
                if (hold_room_info) {
                    held_room_request = node;
                    held_room_result = result;
                } else Idle.add(() => { reply_iq(node, result); return Source.REMOVE; });
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

        internal void release_room_info(bool failed = false) {
            var request = held_room_request;
            var result = held_room_result;
            held_room_request = null;
            held_room_result = null;
            hold_room_info = false;
            if (request == null || result == null) return;
            if (failed) {
                received_iq_stanza(this, new StanzaNode.build("iq", "jabber:client")
                    .put_attribute("type", "error").put_attribute("id", ((!) request).get_attribute("id"))
                    .put_attribute("from", ((!) request).get_attribute("to"))
                    .put_node(new StanzaNode.build("error", "jabber:client").put_attribute("type", "cancel")
                        .put_node(new StanzaNode.build("service-unavailable", "urn:ietf:params:xml:ns:xmpp-stanzas"))));
            } else reply_iq((!) request, (!) result);
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

        internal MessageStanza stanza(uint8[] packet, bool payload = true) {
            var data = new Xmpp.Xep.Omemo.EncryptionData(11);
            data.iv = new uint8[12];
            if (payload) data.ciphertext = new uint8[1];
            data.add_device_key(22, packet, true);
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

        internal MessageStanza encrypted_muc_payload(string cleartext) throws Error {
            // Use the production payload encoder instead of directly calling
            // the inline native VAPI wrapper from this test compilation unit.
            var encryptor = new OmemoEncryptor(new Account(alice_jid, "isolated-sender"), trust, alice);
            var data = encryptor.encrypt_plaintext(cleartext);
            CiphertextMessage packet = alice.create_session_cipher(bob_address).encrypt(data.keytag);
            data.add_device_key(22, packet.serialized, packet.type == CiphertextType.PREKEY);
            var result = new MessageStanza();
            result.from = occupant;
            result.to = account.bare_jid;
            result.type_ = MessageStanza.TYPE_GROUPCHAT;
            result.stanza.put_node(data.get_encrypted_node());
            return result;
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

    private class CaptureAfterMuc : Dino.MessageListener {
        private string[] after = { "MUC" };
        internal bool seen = false;
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return after; } }
        public override async bool run(Dino.Entities.Message message,
                MessageStanza stanza, Conversation conversation) {
            seen = true;
            return true;
        }
    }

    private void test_identity(int variant) {
        Fixture? f = null;
        try {
            f = new Fixture();
            f.enable_muc(variant != 1 && variant != 12, variant != 5 && variant != 12);
            f.establish();
            bool native_history = variant == 0 || variant >= 12;
            var wire = native_history ? f.encrypted_muc_payload("Historical Alice text")
                : f.muc_stanza(new uint8[] {1}, false);
            if (!native_history) {
                var encrypted = wire.stanza.get_subnode("encrypted", OMEMO_NS);
                if (encrypted != null) wire.stanza.sub_nodes.remove(encrypted);
                wire.body = "Plaintext room message";
            }
            for (int i = wire.stanza.attributes.size - 1; i >= 0; i--) {
                if (wire.stanza.attributes[i].name == Stanza.ATTRIBUTE_TO)
                    wire.stanza.attributes.remove_at(i);
            }
            var stanza = new MessageStanza.from_stanza(wire.stanza,
                f.account.bare_jid.with_resource("isolated-receiver"));
            if (variant != 6 && variant != 7 && variant != 11) {
                stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(
                    variant == 3 ? new Jid("wrong@conference.example.test") : f.room,
                    new DateTime.now_utc().add_hours(-1), "archived-alice",
                    variant == 9 ? null : "isolated-mam-query"));
            }
            if (variant == 7) {
                stanza.add_flag(new Xep.DelayedDelivery.MessageFlag(
                    new DateTime.now_utc().add_hours(-1)));
            }
            if (variant != 2) {
                stanza.stanza.put_node(new StanzaNode.build("x",
                        "http://jabber.org/protocol/muc#user")
                    .put_node(new StanzaNode.build("item",
                        "http://jabber.org/protocol/muc#user")
                        .put_attribute("jid", variant == 8 ? "invalid jid" :
                            f.alice_jid.with_resource("old-resource").to_string())
                        .put_attribute("affiliation", "member")
                        .put_attribute("role", "participant")));
            }
            var new_owner = new Jid("charlie@example.test");
            f.stream.emit_occupant(f.occupant, new_owner);
            drain();
            if (variant == 10) {
                f.muc_manager.part(f.account, f.room);
                drain();
            }
            var message = f.muc_message();
            message.body = stanza.body;
            message.real_jid = null;
            if (variant == 4) {
                var other = new Account(new Jid("other@example.test"), "isolated-password");
                other.persist(f.app_db);
                message.account = other;
            }
            var conversation = f.room_conversation;
            if (variant == 11) {
                message = f.message();
                message.real_jid = f.alice_jid;
                stanza.type_ = MessageStanza.TYPE_CHAT;
                stanza.from = f.alice_jid;
                conversation = f.conversation();
            }
            var capture = new CaptureAfterMuc();
            var pipeline = f.interactor.get_module<Dino.MessageProcessor>(
                Dino.MessageProcessor.IDENTITY).received_pipeline;
            pipeline.connect(capture);
            bool done = false;
            pipeline.run.begin(message, stanza, conversation, null, (obj, res) => {
                pipeline.run.end(res);
                done = true;
            });
            for (int i = 0; i < 1024 && !done; i++) MainContext.default().iteration(false);
            fail_if_not(done && capture.seen,
                "Actual MUC receive listener must execute before decryption");
            if (variant == 0 || variant == 1 || variant == 11 || variant == 13 || variant == 14) {
                fail_if(message.real_jid == null || !message.real_jid.equals_bare(f.alice_jid),
                    "Authorized history must preserve its original sender, direct CHAT must stay unchanged");
            } else if (variant == 6) {
                fail_if(message.real_jid == null || !message.real_jid.equals_bare(new_owner),
                    "Forged live MUC item must not override current occupant identity");
            } else {
                fail_if(message.real_jid != null,
                    "Unresolved/unauthorized historical input must never take today's nickname identity");
            }
            if (native_history) {
                bool refresh_done = false;
                if (variant == 13 || variant == 14) {
                    f.stream.hold_room_info = true;
                    var muc_module = f.stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                    muc_module.query_room_info.begin(f.stream, f.room, (_, result) => {
                        muc_module.query_room_info.end(result);
                        refresh_done = true;
                    });
                    drain();
                    if (variant == 14) { f.stream.release_room_info(true); drain(); }
                    fail_if(f.muc_manager.may_retain_authenticated_message_real_jid(f.account, f.room),
                        "Cached ANYONE visibility must not authorize pending/failed fresh room info");
                }
                bool decrypted = f.decryptor.decrypt_message(message, stanza, conversation);
                fail_if_not(decrypted && message.body == "Historical Alice text",
                    "Original native historical ratchet must decrypt after nickname reuse");
                if (variant >= 12) fail_if(message.real_jid != null,
                    "Native authentication must not restore a sender mapping without current room privacy authority");
                if (variant == 13) { f.stream.release_room_info(); drain(); }
                if (variant == 13 || variant == 14) fail_if_not(refresh_done, "Held native room query must be completed before fixture teardown");
            }
        } catch (Error error) { fail_if_reached(error.message); }
        finally { if (f != null) f.close(); }
    }
}
}
