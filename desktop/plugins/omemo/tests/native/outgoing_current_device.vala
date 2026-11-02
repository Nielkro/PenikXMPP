using Dino.Entities;
using Gee;
using Omemo;
using Xmpp;

namespace Omemo.Test {

// Real ratchets and actual MessageProcessor writes for direct chats, including
// current-device metadata installed by normal account initialization. Group
// readiness cases exercise the encryptor plus MessageState, not MUC discovery
// or a group wire send. No self-session is created for the sending device.
class OutgoingCurrentDeviceTest : Gee.TestCase {
    private const string LEGACY = "eu.siacs.conversations.axolotl";
    private const string V2 = "urn:xmpp:omemo:2";
    private const string BODY = "Current sender device must not block encrypted delivery.";

    internal OutgoingCurrentDeviceTest() {
        base("OutgoingCurrentDevice");
        add_test("legacy_current_only_sends_and_peer_decrypts", () => test_delivery(false, false, false));
        add_test("v2_current_only_sends_and_peer_decrypts", () => test_delivery(true, false, false));
        add_test("legacy_peer_with_same_numeric_id_is_not_skipped", () => test_delivery(false, true, false));
        add_test("v2_peer_with_same_numeric_id_is_not_skipped", () => test_delivery(true, true, false));
        add_test("legacy_other_own_device_receives_and_decrypts", () => test_delivery(false, false, true));
        add_test("v2_other_own_device_receives_and_decrypts", () => test_delivery(true, false, true));
        add_test("legacy_missing_other_own_session_still_blocks", () => test_missing_secondary(false));
        add_test("v2_missing_other_own_session_still_blocks", () => test_missing_secondary(true));
        add_test("legacy_self_chat_current_only_does_not_write_keyless_payload", () => test_self_chat(false));
        add_test("v2_self_chat_current_only_does_not_write_keyless_payload", () => test_self_chat(true));
        add_test("legacy_group_unknown_peer_waits_then_both_decrypt", () => test_group_session_readiness(false, false));
        add_test("v2_group_unknown_peer_waits_then_both_decrypt", () => test_group_session_readiness(true, false));
        add_test("legacy_group_classified_lost_peer_keeps_partial_delivery", () => test_group_session_readiness(false, true));
        add_test("v2_group_classified_lost_peer_keeps_partial_delivery", () => test_group_session_readiness(true, true));
    }

    private class WireStream : XmppStream {
        internal ArrayList<StanzaNode> messages = new ArrayList<StanzaNode>();

        internal WireStream() throws InvalidJidError {
            base(new Jid("example.test"));
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }

        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated outgoing regression has no network reader");
        }

        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            if (node.name == "message") messages.add(node);
        }
    }

    // Each receiving device has a separate application/OMEMO database. This
    // also models a second device of the same bare JID without replacing the
    // sending device's identity row while checking real PREKEY decryption.
    private class Device : Object {
        internal string directory;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Dino.StreamInteractor interactor;
        internal Account account;
        internal Store store;
        internal Dino.Plugins.Omemo.TrustManager trust;
        internal int identity_id;
        internal bool v2;

        internal Device(string parent, string name, string bare_jid,
                int device_id, Context context, bool v2) throws Error {
            this.v2 = v2;
            directory = Path.build_filename(parent, name);
            DirUtils.create_with_parents(directory, 0700);
            app_db = new Dino.Database(Path.build_filename(directory, "app.db"),
                "outgoing-current-device-test-only");
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
                .value(db.identity_meta.supports_omemo1, !v2)
                .value(db.identity_meta.supports_omemo2, v2)
                .perform();
        }

        internal bool has_session(Jid jid, int device_id) throws Error {
            var address = new Address(jid.bare_jid.to_string(), device_id);
            try {
                return store.contains_session(address);
            } finally {
                address.device_id = 0;
            }
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
        internal bool v2;
        internal Device sender;
        internal Device peer;
        internal Device? secondary = null;
        internal Device? group_peer = null;
        internal WireStream stream;
        internal Dino.MessageProcessor processor;
        internal Dino.Plugins.Omemo.Manager manager;
        private ulong pre_send_handler;

        internal Fixture(bool v2, bool same_id = false) throws Error {
            this.v2 = v2;
            directory = DirUtils.make_tmp("dinox-outgoing-current-device-XXXXXX");
            if (!Dino.Plugins.Omemo.Plugin.ensure_context()) {
                throw new IOError.FAILED("native OMEMO context is unavailable");
            }
            context = Dino.Plugins.Omemo.Plugin.get_context();
            sender = new Device(directory, "sender", "alice@example.test", 101, context, v2);
            peer = new Device(directory, "peer", "bob@example.test", same_id ? 101 : 202, context, v2);
            sender.remember(peer);
            peer.remember(sender);

            var encryptors = new HashMap<Account, Dino.Plugins.Omemo.OmemoEncryptor>(Account.hash_func, Account.equals_func);
            var encryptors_v2 = new HashMap<Account, Dino.Plugins.Omemo.Omemo2Encrypt>(Account.hash_func, Account.equals_func);
            encryptors[sender.account] = new Dino.Plugins.Omemo.OmemoEncryptor(sender.account, sender.trust, sender.store);
            encryptors_v2[sender.account] = new Dino.Plugins.Omemo.Omemo2Encrypt(sender.account, sender.trust, sender.store);
            manager = Dino.Plugins.Omemo.Manager.create_for_tests(sender.interactor,
                sender.db, sender.trust, encryptors, encryptors_v2);
            processor = sender.interactor.get_module<Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            pre_send_handler = processor.pre_message_send.connect((message, stanza, conversation) => {
                manager.pre_message_send_for_tests(message, stanza, conversation);
            });

            stream = new WireStream();
            stream.add_module(new Xmpp.MessageModule());
            stream.add_module(new Dino.Plugins.Omemo.StreamModule(sender.store));
            stream.add_module(new Dino.Plugins.Omemo.StreamModule2(sender.store));
            var bind = new Xmpp.Bind.Flag();
            bind.my_jid = sender.account.full_jid;
            bind.finished = true;
            stream.add_flag(bind);
            sender.interactor.connection_manager.set_connected_stream_for_tests(sender.account, stream);
        }

        internal void add_secondary(bool ready) throws Error {
            secondary = new Device(directory, "secondary", "alice@example.test", 303, context, v2);
            sender.remember((!) secondary);
            ((!) secondary).remember(sender);
            if (ready) establish(sender, (!) secondary, 31002, 32002);
        }

        internal Device add_group_peer() throws Error {
            group_peer = new Device(directory, "group-peer", "carol@example.test", 404, context, v2);
            sender.remember((!) group_peer);
            ((!) group_peer).remember(sender);
            return (!) group_peer;
        }

        internal Xmpp.Xep.Omemo.EncryptState encrypt_group(Gee.List<Jid> recipients,
                out MessageStanza stanza) throws Error {
            stanza = new MessageStanza(Uuid.string_random());
            stanza.to = new Jid("private-room@conference.example.test");
            stanza.type_ = MessageStanza.TYPE_GROUPCHAT;
            stanza.body = BODY;
            if (v2) {
                var encryptor = new Dino.Plugins.Omemo.Omemo2Encrypt(sender.account,
                    sender.trust, sender.store);
                return encryptor.encrypt(stanza, sender.account.bare_jid, recipients, stream);
            }
            var encryptor = new Dino.Plugins.Omemo.OmemoEncryptor(sender.account,
                sender.trust, sender.store);
            return encryptor.encrypt(stanza, sender.account.bare_jid, recipients, stream);
        }

        internal void establish(Device from, Device to, uint32 pre_key_id,
                int signed_key_id) throws Error {
            ECKeyPair pre_key = context.generate_key_pair();
            ECKeyPair signed_key = context.generate_key_pair();
            IdentityKeyPair identity = to.store.identity_key_pair;
            uint8[] signed_public = v2 ? signed_key.public.serialize_omemo() : signed_key.public.serialize();
            uint8[] signature = context.calculate_signature(identity.private, signed_public);
            PreKeyBundle bundle = create_pre_key_bundle(to.store.local_registration_id,
                (int) to.store.local_registration_id, pre_key_id, pre_key.public,
                signed_key_id, signed_key.public, signature, identity.public);
            var address = new Address(to.account.bare_jid.to_string(), (int) to.store.local_registration_id);
            SessionBuilder builder = from.store.create_session_builder(address);
            if (v2) builder.version = 4;
            builder.process_pre_key_bundle(bundle);
            address.device_id = 0;

            PreKeyRecord pre_key_record;
            throw_by_code(PreKeyRecord.create(out pre_key_record, pre_key_id, pre_key));
            to.store.store_pre_key(pre_key_record);
            SignedPreKeyRecord signed_key_record;
            if (v2) {
                throw_by_code(SignedPreKeyRecord.create(out signed_key_record,
                    signed_key_id, new DateTime.now_utc().to_unix(), signed_key,
                    new uint8[1], signature));
            } else {
                throw_by_code(SignedPreKeyRecord.create(out signed_key_record,
                    signed_key_id, new DateTime.now_utc().to_unix(), signed_key,
                    signature, null));
            }
            to.store.store_signed_pre_key(signed_key_record);
        }

        internal Message send(bool self_chat = false) {
            Jid target = self_chat ? sender.account.bare_jid : peer.account.bare_jid;
            var conversation = new Conversation(target, sender.account, Conversation.Type.CHAT) {
                encryption = Encryption.OMEMO,
                send_typing = Conversation.Setting.OFF
            };
            var message = new Message(BODY) {
                account = sender.account,
                counterpart = target,
                ourpart = sender.account.full_jid,
                stanza_id = Uuid.string_random(),
                direction = Message.DIRECTION_SENT,
                type_ = Message.Type.CHAT,
                encryption = Encryption.OMEMO,
                marked = Message.Marked.UNSENT
            };
            processor.send_xmpp_message(message, conversation);
            int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
            while (message.marked == Message.Marked.SENDING && get_monotonic_time() < deadline) {
                while (MainContext.default().pending()) MainContext.default().iteration(false);
                if (message.marked == Message.Marked.SENDING) Thread.usleep(1000);
            }
            return message;
        }

        internal string decrypt(Device recipient, StanzaNode encrypted) throws Error {
            if (!v2) {
                var decryptor = new Dino.Plugins.Omemo.OmemoDecryptor(recipient.account,
                    recipient.interactor, recipient.trust, recipient.db, recipient.store);
                Xmpp.Xep.Omemo.ParsedData? parsed = decryptor.parse_node(encrypted);
                if (parsed == null) throw new IOError.FAILED("native recipient could not parse legacy envelope");
                foreach (Bytes candidate in ((!) parsed).our_potential_encrypted_keys.keys) {
                    ((!) parsed).is_prekey = ((!) parsed).our_potential_encrypted_keys[candidate];
                    ((!) parsed).encrypted_key = candidate.get_data();
                    uint8[] key = decryptor.decrypt_key((!) parsed, sender.account.bare_jid);
                    return decryptor.decrypt(((!) parsed).ciphertext, key, ((!) parsed).iv);
                }
                throw new IOError.FAILED("legacy envelope lacks the native recipient's key");
            }

            var decryptor = new Dino.Plugins.Omemo.Omemo2Decrypt(recipient.account,
                recipient.interactor, recipient.trust, recipient.db, recipient.store);
            Xmpp.Xep.Omemo.Omemo2ParsedData? parsed = decryptor.parse_node(encrypted, recipient.account.bare_jid);
            if (parsed == null || ((!) parsed).ciphertext == null) {
                throw new IOError.FAILED("native recipient could not parse OMEMO2 payload");
            }
            uint8[] key = decryptor.decrypt_key((!) parsed, sender.account.bare_jid);
            string body = "";
            Error? failure = null;
            bool complete = false;
            decryptor.decrypt.begin(((!) parsed).ciphertext, key, (obj, result) => {
                try {
                    body = decryptor.decrypt.end(result);
                } catch (Error error) {
                    failure = error;
                }
                complete = true;
            });
            int64 deadline = get_monotonic_time() + 2 * TimeSpan.SECOND;
            while (!complete && get_monotonic_time() < deadline) {
                while (MainContext.default().pending()) MainContext.default().iteration(false);
                if (!complete) Thread.usleep(1000);
            }
            if (!complete) throw new IOError.TIMED_OUT("native OMEMO2 decrypt exceeded its fixture deadline");
            if (failure != null) throw (!) failure;
            return body;
        }

        internal void assert_no_self_session() throws Error {
            fail_if(sender.has_session(sender.account.bare_jid, (int) sender.store.local_registration_id),
                "current sending device must not acquire a session to itself");
        }

        internal void close() {
            processor.disconnect(pre_send_handler);
            manager.forget_pending_messages_for_account(sender.account);
            if (group_peer != null) ((!) group_peer).close();
            if (secondary != null) ((!) secondary).close();
            peer.close();
            sender.close();
            remove_directory(directory);
        }
    }

    private delegate void FixtureTest(Fixture fixture) throws Error;

    private void with_fixture(bool v2, bool same_id, owned FixtureTest test) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(v2, same_id);
            ((!) fixture).assert_no_self_session();
            test((!) fixture);
            ((!) fixture).assert_no_self_session();
        } catch (Error error) {
            fail_if_reached("outgoing current-device regression failed: " + error.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void test_delivery(bool v2, bool same_id, bool secondary) {
        with_fixture(v2, same_id, (f) => {
            f.establish(f.sender, f.peer, 31001, 32001);
            if (secondary) f.add_secondary(true);
            Message message = f.send();
            if (fail_if(message.marked != Message.Marked.SENT,
                    "ready peer and current own metadata must reach the real MessageProcessor wire write")) return;
            if (fail_if_not_eq_int(f.stream.messages.size, 1,
                    "the encrypted send must write exactly one message stanza")) return;
            StanzaNode wire = f.stream.messages[0];
            StanzaNode? encrypted = wire.get_subnode("encrypted", v2 ? V2 : LEGACY);
            if (fail_if(encrypted == null, "wire stanza must contain the selected encrypted payload")) return;
            fail_if(wire.to_string().contains(BODY), "original text must not appear outside the encrypted payload");
            fail_if_not_eq_int(key_count((!) encrypted, v2), secondary ? 2 : 1,
                "only the peer and any other own device may receive wrapped keys");
            fail_if_not(has_key((!) encrypted, v2, f.peer.account.bare_jid, (int) f.peer.store.local_registration_id),
                "the foreign peer must receive a key even when its numeric ID equals our current device ID");
            // Legacy keys have no JID attribute. With a cross-account ID
            // collision, the peer key legitimately has the sender's numeric
            // ID; its unique key count and successful decryption disambiguate it.
            if (v2 || !same_id) {
                fail_if(has_key((!) encrypted, v2, f.sender.account.bare_jid, (int) f.sender.store.local_registration_id),
                    "wire payload must not include the current sending device as an own recipient");
            }
            fail_if_not_eq_str(f.decrypt(f.peer, (!) encrypted), BODY,
                "the foreign peer must decrypt the actual written payload");
            if (secondary) {
                fail_if_not(has_key((!) encrypted, v2, f.sender.account.bare_jid,
                        (int) ((!) f.secondary).store.local_registration_id),
                    "another own device must retain its wrapped key");
                fail_if_not_eq_str(f.decrypt((!) f.secondary, (!) encrypted), BODY,
                    "the other own device must decrypt the actual written payload");
            }
        });
    }

    private void test_missing_secondary(bool v2) {
        with_fixture(v2, false, (f) => {
            f.establish(f.sender, f.peer, 31001, 32001);
            f.add_secondary(false);
            Message message = f.send();
            fail_if(message.marked != Message.Marked.UNSENT,
                "skipping the current device must not bypass a missing session for another own device");
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "pending other own devices must prevent a partial direct-message wire send");
            fail_if(f.sender.has_session(f.sender.account.bare_jid, 303),
                "the blocked fixture must not manufacture a missing other-own session");
        });
    }

    private void test_self_chat(bool v2) {
        with_fixture(v2, false, (f) => {
            Message message = f.send(true);
            fail_if(message.marked != Message.Marked.WONTSEND && message.marked != Message.Marked.ERROR,
                "self-chat with only the current device must fail closed without a keyless send or an endless self-session wait");
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "self-chat must not write an encrypted payload containing no recipient keys");
        });
    }

    private void test_group_session_readiness(bool v2, bool classify_lost) {
        with_fixture(v2, false, (f) => {
            f.establish(f.sender, f.peer, 31001, 32001);
            Device carol = f.add_group_peer();
            var recipients = new ArrayList<Jid>(Jid.equals_bare_func);
            recipients.add(f.peer.account.bare_jid);
            recipients.add(carol.account.bare_jid);
            fail_if(f.sender.has_session(carol.account.bare_jid, 404),
                "Carol must begin with a known active identity but no sender session");

            MessageStanza initial;
            var pending = f.encrypt_group(recipients, out initial);
            fail_if_not_eq_int(pending.other_success, 1,
                "the warm Bob ratchet must already wrap a recipient key");
            fail_if_not_eq_int(pending.other_unknown, 1,
                "the cold Carol ratchet must remain unknown until session setup");
            fail_if_not_eq_int(pending.other_lost, 0,
                "a session that has not been built is not a lost device");
            var message = new Message(BODY) {
                account = f.sender.account,
                counterpart = initial.to,
                type_ = Message.Type.GROUPCHAT,
                marked = Message.Marked.UNSENT
            };
            var state = new Dino.Plugins.Omemo.Manager.MessageState(message, pending);
            fail_if(state.will_send_now,
                "a warm group recipient must not bypass another active recipient's missing session");
            fail_if(message.marked != Message.Marked.UNSENT,
                "unknown group sessions must retain a pending message for bundle repair");

            if (classify_lost) {
                // Model an explicit stream-module decision after bundle
                // failure, without deleting or distrusting Carol's identity.
                f.stream.get_module<Dino.Plugins.Omemo.StreamModule>(
                    Dino.Plugins.Omemo.StreamModule.IDENTITY).ignore_device(carol.account.bare_jid, 404);
                f.stream.get_module<Dino.Plugins.Omemo.StreamModule2>(
                    Dino.Plugins.Omemo.StreamModule2.IDENTITY).ignore_device(carol.account.bare_jid, 404);
            } else {
                f.establish(f.sender, carol, 31004, 32004);
            }

            MessageStanza completed;
            var ready = f.encrypt_group(recipients, out completed);
            fail_if_not_eq_int(ready.other_unknown, 0,
                "every group recipient must have a session or an explicit loss decision");
            fail_if_not_eq_int(ready.other_success, classify_lost ? 1 : 2);
            fail_if_not_eq_int(ready.other_lost, classify_lost ? 1 : 0);
            state.update_from_encrypt_status(message, ready);
            fail_if_not(state.will_send_now,
                "resolved group sessions must permit delivery, including an explicitly lost peer");
            Gee.List<int32> trusted = v2
                ? f.sender.trust.get_trusted_devices_omemo2(f.sender.account, carol.account.bare_jid)
                : f.sender.trust.get_trusted_devices_omemo1(f.sender.account, carol.account.bare_jid);
            fail_if_not(trusted.contains(404),
                "session readiness must not remove Carol from the active trusted-device list");

            StanzaNode? encrypted = completed.stanza.get_subnode("encrypted", v2 ? V2 : LEGACY);
            if (fail_if(encrypted == null, "real group encryption must produce an encrypted payload")) return;
            fail_if_not_eq_int(key_count((!) encrypted, v2), classify_lost ? 1 : 2,
                "the group envelope must cover every successful peer and exclude the current sender");
            fail_if_not(has_key((!) encrypted, v2, f.peer.account.bare_jid, 202));
            fail_if_not_eq_str(f.decrypt(f.peer, (!) encrypted), BODY,
                "Bob must decrypt the actual encrypted group payload");
            if (classify_lost) {
                fail_if(has_key((!) encrypted, v2, carol.account.bare_jid, 404),
                    "only an explicitly lost peer may be excluded from this partial payload");
                fail_if(f.sender.has_session(carol.account.bare_jid, 404),
                    "classifying loss must not manufacture a Carol session");
            } else {
                fail_if_not(has_key((!) encrypted, v2, carol.account.bare_jid, 404));
                fail_if_not_eq_str(f.decrypt(carol, (!) encrypted), BODY,
                    "Carol must decrypt without first sending a group message herself");
            }
            fail_if_not_eq_int(f.stream.messages.size, 0,
                "this fixture covers encryptor readiness and does not claim a MUC wire send");
        });
    }

    private static bool has_key(StanzaNode encrypted, bool v2, Jid jid, int id) {
        string ns_uri = v2 ? V2 : LEGACY;
        StanzaNode? header = encrypted.get_subnode("header", ns_uri);
        if (header == null) return false;
        if (!v2) {
            foreach (StanzaNode key in ((!) header).get_subnodes("key", ns_uri)) {
                if (key.get_attribute_int("rid") == id) return true;
            }
        } else {
            foreach (StanzaNode keys in ((!) header).get_subnodes("keys", ns_uri)) {
                if (keys.get_attribute("jid") != jid.bare_jid.to_string()) continue;
                foreach (StanzaNode key in keys.get_subnodes("key", ns_uri)) {
                    if (key.get_attribute_int("rid") == id) return true;
                }
            }
        }
        return false;
    }

    private static int key_count(StanzaNode encrypted, bool v2) {
        string ns_uri = v2 ? V2 : LEGACY;
        StanzaNode? header = encrypted.get_subnode("header", ns_uri);
        if (header == null) return 0;
        if (!v2) return ((!) header).get_subnodes("key", ns_uri).size;
        int count = 0;
        foreach (StanzaNode keys in ((!) header).get_subnodes("keys", ns_uri)) {
            count += keys.get_subnodes("key", ns_uri).size;
        }
        return count;
    }

    private static void remove_directory(string path) {
        try {
            var children = File.new_for_path(path).enumerate_children(
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file()) != null) {
                File.new_for_path(Path.build_filename(path, ((!) info).get_name())).delete();
            }
            children.close();
            File.new_for_path(path).delete();
        } catch (Error error) {
            fail_if_reached("could not remove isolated outgoing fixture: " + error.message);
        }
    }
}

}
