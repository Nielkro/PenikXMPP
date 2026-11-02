using Dino.Entities;
using Dino.Plugins.Omemo;
using Gee;
using Xmpp;

namespace Omemo.Test {

class MultiAccountMessageStateTest : Gee.TestCase {
    internal MultiAccountMessageStateTest() {
        base("MultiAccountMessageState");
        add_test("received_device_tags_do_not_collide_between_accounts", test_device_tags);
        add_test("delayed_send_states_do_not_collide_between_accounts", test_send_states);
        add_test("changed_body_keeps_the_original_pipeline_state", test_body_change);
        add_test("account_removal_preserves_other_and_recreated_accounts", test_account_removal);
        add_test("confirmed_peer_device_removal_retries_encrypted_send_once", () => test_device_removal(false));
        add_test("confirmed_own_device_removal_retries_encrypted_send_once", () => test_device_removal(true));
        add_test("device_list_failure_is_terminal_only_for_its_waiting_direct_messages", test_device_list_failure);
        add_test("peer_bundle_access_denial_fails_only_relevant_missing_session_waits", () => test_bundle_access_denial(false));
        add_test("own_bundle_access_denial_keeps_account_and_device_scope", () => test_bundle_access_denial(true));
    }

    private delegate void FixtureTest(Fixture fixture) throws Error;

    private class Fixture : Object {
        internal string directory;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Dino.StreamInteractor interactor;
        internal TrustManager trust;
        internal Manager manager;
        internal Account first;
        internal Account second;
        internal HashMap<Account, OmemoEncryptor> encryptors;
        internal ListUpdateTestStream? stream;
        internal StreamModule? module;

        internal Fixture() throws Error {
            directory = DirUtils.make_tmp("dinox-omemo-message-accounts-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(directory, "app.db"), "test-only");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(directory, "omemo.db"));
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            trust = new TrustManager(interactor, db);
            encryptors = new HashMap<Account, OmemoEncryptor>(Account.hash_func, Account.equals_func);
            manager = Manager.create_for_tests(interactor, db, trust, encryptors);
            first = new Account(new Jid("first@example.test"), "test-password");
            second = new Account(new Jid("second@example.test"), "test-password");
            first.persist(app_db);
            second.persist(app_db);
        }

        internal Message make_message(Account account) throws Error {
            // The same sender's stanza, e.g. a room message delivered to both
            // accounts. Neither its sender-chosen ID nor text is account-unique.
            return new Message("same text on both accounts") {
                account = account,
                counterpart = new Jid("same-contact@example.test"),
                ourpart = account.bare_jid,
                stanza_id = "same-sender-chosen-stanza-id",
                type_ = Message.Type.CHAT,
                encryption = Encryption.OMEMO
            };
        }

        internal void close() {
            if (stream != null && module != null) {
                ((!) module).detach((!) stream);
                ((!) stream).get_module<Iq.Module>(Iq.Module.IDENTITY).detach((!) stream);
                drain_ready_callbacks();
            }
            Dino.MucManager? muc = interactor.get_module<Dino.MucManager>(Dino.MucManager.IDENTITY);
            if (muc != null) ((!) muc).shutdown();
            db.close();
            app_db.close();
            try {
                var children = File.new_for_path(directory).enumerate_children(
                    FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = children.next_file()) != null) {
                    File.new_for_path(Path.build_filename(directory, ((!) info).get_name())).delete();
                }
                children.close();
                File.new_for_path(directory).delete();
            } catch (Error e) {
                fail_if_reached("Could not remove isolated message-state fixture: " + e.message);
            }
        }
    }

    private void with_fixture(owned FixtureTest test) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            test((!) fixture);
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private static void drain_ready_callbacks() {
        bool drained = false;
        uint barrier = Idle.add(() => {
            drained = true;
            return Source.REMOVE;
        }, Priority.LOW);
        MainContext context = MainContext.default();
        for (int i = 0; i < 128 && !drained; i++) context.iteration(false);
        if (!drained) Source.remove(barrier);
        fail_if_not(drained, "in-memory send continuations must quiesce before teardown");
    }

    private static Xep.Omemo.EncryptState waiting_state(int pending_devices) {
        return new Xep.Omemo.EncryptState() {
            own_list = true,
            own_devices = 1,
            own_success = 1,
            other_devices = pending_devices,
            other_unknown = pending_devices
        };
    }

    private void test_device_tags() {
        with_fixture((fixture) => {
            Message first = fixture.make_message(fixture.first);
            Message second = fixture.make_message(fixture.second);
            fail_if_not(Message.equals_func(first, second),
                "fixture must exercise the old content-based collision");
            fixture.trust.remember_message_device(first, 101);
            fixture.trust.remember_message_device(second, 202);
            fail_if_not_eq_int(fixture.trust.get_message_device(first), 101);
            fail_if_not_eq_int(fixture.trust.get_message_device(second), 202);
            fixture.trust.clear_message_device(first);
            fail_if_not_eq_int(fixture.trust.get_message_device(second), 202,
                "tag consumption on one account must retain the other's tag");
        });
    }

    private void test_send_states() {
        with_fixture((fixture) => {
            Message first = fixture.make_message(fixture.first);
            Message second = fixture.make_message(fixture.second);
            var first_state = fixture.manager.update_send_state(first, waiting_state(1));
            var second_state = fixture.manager.update_send_state(second, waiting_state(2));
            fail_if(first_state == second_state,
                "same text/ID on different accounts must not share a send attempt");
            fail_if_not(first_state.msg == first);
            fail_if_not(second_state.msg == second);
            fail_if_not_eq_int(first_state.waiting_other_sessions, 1);
            fail_if_not_eq_int(second_state.waiting_other_sessions, 2);

            var ready = waiting_state(1);
            ready.other_unknown = 0;
            ready.other_success = 1;
            ready.encrypted = true;
            var completed = fixture.manager.update_send_state(first, ready);
            fail_if_not(completed == first_state);
            fail_if_not(completed.will_send_now);
            fail_if_not(fixture.manager.update_send_state(second, waiting_state(2)) == second_state,
                "sending the first account's message must retain the second pending state");
            fail_if(fixture.manager.update_send_state(first, waiting_state(1)) == first_state,
                "a completed send must have removed its transient state");
        });
    }

    private void test_body_change() {
        with_fixture((fixture) => {
            Message message = fixture.make_message(fixture.first);
            var state = fixture.manager.update_send_state(message, waiting_state(1));
            fixture.trust.remember_message_device(message, 303);
            message.body = "body changed by a later pipeline stage";
            message.stanza_id = "updated-stanza-id";
            fail_if_not_eq_int(fixture.trust.get_message_device(message), 303,
                "mutable message properties cannot make a received device tag unreachable");
            fail_if_not(fixture.manager.update_send_state(message, waiting_state(2)) == state,
                "body changes must update the existing delayed send attempt");
            fail_if_not_eq_int(state.waiting_other_sessions, 2);
            fail_if_not(fixture.trust.clear_message_device(message));
            fail_if_not_eq_int(fixture.trust.get_message_device(message), 0);
        });
    }

    private void test_account_removal() {
        with_fixture((fixture) => {
            Message first = fixture.make_message(fixture.first);
            Message second = fixture.make_message(fixture.second);
            // Simulate the persisted ID after removing/re-adding the same bare
            // JID. Account.equals intentionally equates these; cleanup must not.
            var recreated = new Account(fixture.first.bare_jid, "test-password") {
                id = fixture.second.id + 1
            };
            Message replacement = fixture.make_message(recreated);
            fail_if_not(fixture.first.equals(recreated));
            var first_state = fixture.manager.update_send_state(first, waiting_state(1));
            var second_state = fixture.manager.update_send_state(second, waiting_state(2));
            var replacement_state = fixture.manager.update_send_state(replacement, waiting_state(3));
            fixture.trust.remember_message_device(first, 101);
            fixture.trust.remember_message_device(second, 202);
            fixture.trust.remember_message_device(replacement, 303);

            // Pass a distinct Account instance for the removed persisted row:
            // cleanup is by account ID, not only the Account object's address.
            var removed = new Account(fixture.first.bare_jid, "test-password") {
                id = fixture.first.id
            };
            fixture.manager.forget_pending_messages_for_account(removed);
            fixture.trust.forget_account(removed);
            fail_if(fixture.trust.get_message_device(first) != 0);
            fail_if_not_eq_int(fixture.trust.get_message_device(second), 202);
            fail_if_not_eq_int(fixture.trust.get_message_device(replacement), 303);
            fail_if_not(fixture.manager.update_send_state(second, waiting_state(2)) == second_state);
            fail_if_not(fixture.manager.update_send_state(replacement, waiting_state(3)) == replacement_state);
            fail_if(fixture.manager.update_send_state(first, waiting_state(1)) == first_state,
                "removed account's old pending state must no longer be reachable");
        });
    }

    private void test_device_removal(bool own_device) {
        with_fixture((fixture) => {
            Context context = Plugin.get_context();
            Store store = setup_test_store_context(context);
            Store peer = setup_test_store_context(context);
            store.identity_key_store.local_registration_id = 101;
            peer.identity_key_store.local_registration_id = 202;
            Dino.Calls.start(fixture.interactor, fixture.app_db);
            Dino.ConversationManager.start(fixture.interactor, fixture.app_db);
            Dino.PresenceManager.start(fixture.interactor, fixture.app_db);
            Dino.MucManager.start(fixture.interactor, fixture.app_db);
            fixture.interactor.module_manager.initialize(fixture.first);
            fixture.interactor.module_manager.initialize(fixture.second);
            fixture.interactor.account_added(fixture.first);
            fixture.interactor.account_added(fixture.second);
            Dino.ConversationManager conversations = fixture.interactor.get_module<
                Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            var counterpart = new Jid("same-contact@example.test");
            var conversation = conversations.create_conversation(counterpart,
                fixture.first, Conversation.Type.CHAT);
            conversation.encryption = Encryption.OMEMO;
            conversation.send_typing = Conversation.Setting.OFF;

            int identity_id = (int) fixture.db.identity.upsert()
                .value(fixture.db.identity.account_id, fixture.first.id, true)
                .value(fixture.db.identity.device_id, 101)
                .value(fixture.db.identity.identity_key_private_base64,
                    Base64.encode(store.identity_key_store.identity_key_private.get_data()))
                .value(fixture.db.identity.identity_key_public_base64,
                    Base64.encode(store.identity_key_store.identity_key_public.get_data()))
                .perform_checked();
            add_device(fixture, identity_id, fixture.first.bare_jid, 101, store);
            add_device(fixture, identity_id, counterpart, 202, peer);
            Jid changed_jid = own_device ? fixture.first.bare_jid : counterpart;
            add_device(fixture, identity_id, changed_jid, 303, peer);
            build_native_session(context, store, peer, counterpart, 202);

            fixture.stream = new ListUpdateTestStream(new Jid("example.test"));
            ListUpdateTestStream stream = (!) fixture.stream;
            var bind = new Bind.Flag();
            bind.my_jid = fixture.first.bare_jid.with_resource("desktop");
            bind.finished = true;
            stream.add_flag(bind);
            stream.negotiation_complete = true;
            stream.add_module(new Iq.Module());
            stream.add_module(new MessageModule());
            stream.add_module(new Xmpp.Xep.Pubsub.Module());
            var disco = new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX List Update Test");
            stream.add_module(disco);
            disco.attach(stream);
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).attach(stream);
            stream.get_module<MessageModule>(MessageModule.IDENTITY).attach(stream);
            stream.get_module<Xmpp.Xep.Pubsub.Module>(Xmpp.Xep.Pubsub.Module.IDENTITY).attach(stream);
            fixture.module = new StreamModule(store);
            ((!) fixture.module).auto_publish_own_device_list = false;
            stream.add_module((!) fixture.module);
            ((!) fixture.module).attach(stream);
            fixture.interactor.connection_manager.set_connected_stream_for_tests(fixture.first, stream);
            fixture.encryptors[fixture.first] = new OmemoEncryptor(fixture.first, fixture.trust, store);
            Dino.MessageProcessor processor = fixture.interactor.get_module<
                Dino.MessageProcessor>(Dino.MessageProcessor.IDENTITY);
            processor.pre_message_send.connect(fixture.manager.pre_message_send_for_tests);

            Message message = fixture.make_message(fixture.first);
            message.time = new DateTime.now_utc();
            message.local_time = message.time;
            var other = fixture.make_message(fixture.second);
            var other_state = fixture.manager.update_send_state(other, waiting_state(2));
            var recreated = new Account(fixture.first.bare_jid, "test-password") {
                id = fixture.second.id + 1
            };
            var replacement = fixture.make_message(recreated);
            var replacement_state = fixture.manager.update_send_state(replacement, waiting_state(3));

            processor.send_xmpp_message(message, conversation);
            fail_if(message.marked != Message.Marked.UNSENT,
                "An active device without a native session must initially block the direct send");
            fail_if_not_eq_int(stream.messages.size, 0, "A pending encrypted message must never fall back to plaintext");
            if (own_device) {
                drain_ready_callbacks();
                bool requested_secondary = false;
                foreach (StanzaNode iq in stream.iq_requests) {
                    if (iq.get_attribute("to") != fixture.first.bare_jid.to_string()) continue;
                    StanzaNode? pubsub = iq.get_subnode("pubsub", "http://jabber.org/protocol/pubsub");
                    StanzaNode? items = pubsub != null
                        ? ((!) pubsub).get_subnode("items", "http://jabber.org/protocol/pubsub") : null;
                    if (items == null) continue;
                    string? node = ((!) items).get_attribute("node");
                    fail_if(node == "eu.siacs.conversations.axolotl.bundles:101",
                        "Own-session repair must not request a receiving session to the current sender");
                    if (node == "eu.siacs.conversations.axolotl.bundles:303") requested_secondary = true;
                }
                fail_if_not(requested_secondary,
                    "The actual retry IQ must still request the missing other own device's bundle");
            }

            var still_active = new ArrayList<int32>();
            still_active.add(own_device ? 101 : 202);
            still_active.add(303);
            fixture.manager.device_list_loaded_for_tests(fixture.first,
                changed_jid.with_resource("notification"), still_active);
            fail_if(message.marked != Message.Marked.UNSENT,
                "Revalidation must still block while the unknown-session device remains active");
            fail_if_not_eq_int(stream.messages.size, 0);

            var confirmed_list = new ArrayList<int32>();
            confirmed_list.add(own_device ? 101 : 202);
            var pending_attempt = new Xep.Omemo.EncryptState() {
                own_list = true,
                own_devices = own_device ? 2 : 1,
                own_success = 1,
                own_unknown = own_device ? 1 : 0,
                other_devices = own_device ? 1 : 2,
                other_success = 1,
                other_unknown = own_device ? 0 : 1,
                encrypted = true
            };
            var active_state = fixture.manager.update_send_state(message, pending_attempt);
            active_state.active_send_attempt = true;
            fixture.manager.device_list_loaded_for_tests(fixture.first, changed_jid, confirmed_list);
            fail_if_not_eq_int(stream.messages.size, 0,
                "An already active attempt must not be entered again by a list notification");
            active_state.active_send_attempt = false;
            fixture.manager.device_list_loaded_for_tests(fixture.first,
                changed_jid.with_resource("notification"), confirmed_list);
            drain_ready_callbacks();
            fail_if_not_eq_int(stream.messages.size, 1,
                "A confirmed removed device must unblock exactly one normal encrypted send");
            fail_if(message.marked != Message.Marked.SENT,
                "The actual MessageProcessor send must complete after revalidation");
            if (stream.messages.size == 1) {
                StanzaNode sent = stream.messages[0];
                StanzaNode? encrypted = sent.get_subnode("encrypted", "eu.siacs.conversations.axolotl");
                fail_if(encrypted == null, "The actual wire stanza must contain legacy OMEMO");
                fail_if(sent.get_deep_string_content("body") == message.body,
                    "The actual wire stanza must not expose the original message body");
                if (encrypted != null) {
                    StanzaNode? header = ((!) encrypted).get_subnode("header", "eu.siacs.conversations.axolotl");
                    fail_if(header == null, "The encrypted wire stanza must contain a recipient header");
                    if (header != null) {
                        foreach (StanzaNode key in ((!) header).get_subnodes("key", "eu.siacs.conversations.axolotl")) {
                            fail_if(key.get_attribute("rid") == "303",
                                "The confirmed removed device must no longer be an encrypted recipient");
                        }
                    }
                }
            }
            fixture.manager.device_list_loaded_for_tests(fixture.first, changed_jid, confirmed_list);
            drain_ready_callbacks();
            fail_if_not_eq_int(stream.messages.size, 1, "Repeated list notifications must not resend a completed message");
            fail_if(other.marked != Message.Marked.UNSENT || other_state.waiting_other_sessions != 2,
                "Another account's pending device/session state must remain unchanged");
            fail_if(replacement.marked != Message.Marked.UNSENT || replacement_state.waiting_other_sessions != 3,
                "A recreated same-JID account with another persisted ID must remain unchanged");
            var removed_row = fixture.db.identity_meta.get_device(identity_id,
                changed_jid.to_string(), 303);
            fail_if(removed_row == null || ((!) removed_row)[fixture.db.identity_meta.now_active],
                "The server list must deactivate the removed device while preserving its metadata");
            if (removed_row != null) {
                fail_if(((!) removed_row)[fixture.db.identity_meta.trust_level] != TrustLevel.TRUSTED,
                    "List revalidation must preserve removed-device trust metadata");
            }
        });
    }

    private void add_device(Fixture fixture, int identity_id, Jid jid,
            int32 device_id, Store device_store) throws Error {
        fixture.db.identity_meta.upsert()
            .value(fixture.db.identity_meta.identity_id, identity_id, true)
            .value(fixture.db.identity_meta.address_name, jid.to_string(), true)
            .value(fixture.db.identity_meta.device_id, device_id, true)
            .value(fixture.db.identity_meta.identity_key_public_base64,
                Base64.encode(device_store.identity_key_store.identity_key_public.get_data()))
            .value(fixture.db.identity_meta.trust_level, TrustLevel.TRUSTED)
            .value(fixture.db.identity_meta.now_active, true)
            .value(fixture.db.identity_meta.supports_omemo1, true)
            .perform_checked();
    }

    private void build_native_session(Context context, Store local_store,
            Store remote_store, Jid jid, int32 device_id) throws Error {
        ECKeyPair prekey = context.generate_key_pair();
        SignedPreKeyRecord signed_prekey = context.generate_signed_pre_key(remote_store.identity_key_pair, 1);
        var address = new Address(jid.to_string(), device_id);
        local_store.create_session_builder(address).process_pre_key_bundle(
            create_pre_key_bundle(remote_store.local_registration_id, device_id,
                1, prekey.public, 1, signed_prekey.key_pair.public,
                signed_prekey.signature, remote_store.identity_key_pair.public));
        address.device_id = 0;
    }

    private void test_device_list_failure() {
        with_fixture((fixture) => {
            var own_message = fixture.make_message(fixture.first);
            var own_wait = waiting_state(0);
            own_wait.own_list = false;
            var own_state = fixture.manager.update_send_state(own_message, own_wait);
            var peer_message = fixture.make_message(fixture.first);
            var peer_wait = waiting_state(0);
            peer_wait.other_waiting_lists = 1;
            var peer_state = fixture.manager.update_send_state(peer_message, peer_wait);
            var sessions_message = fixture.make_message(fixture.first);
            var sessions_state = fixture.manager.update_send_state(sessions_message, waiting_state(1));
            var other_message = fixture.make_message(fixture.second);
            var other_state = fixture.manager.update_send_state(other_message, peer_wait);
            var active_message = fixture.make_message(fixture.first);
            var active_state = fixture.manager.update_send_state(active_message, peer_wait);
            active_state.active_send_attempt = true;
            var group_message = fixture.make_message(fixture.first);
            group_message.type_ = Message.Type.GROUPCHAT;
            var group_state = fixture.manager.update_send_state(group_message, peer_wait);
            var recreated = new Account(fixture.first.bare_jid, "test-password") {
                id = fixture.second.id + 1
            };
            var recreated_message = fixture.make_message(recreated);
            var recreated_state = fixture.manager.update_send_state(recreated_message, peer_wait);

            fixture.manager.on_device_list_fetch_failed(fixture.first, new Jid("unrelated@example.test"));
            fail_if(peer_message.marked != Message.Marked.UNSENT,
                "An unrelated list failure must not terminate this direct send");
            fixture.manager.on_device_list_fetch_failed(fixture.first,
                fixture.first.bare_jid.with_resource("desktop"));
            fail_if(own_message.marked != Message.Marked.ERROR || own_message.delivery_error_text == null,
                "A rejected own list request must make its waiting direct send visibly retryable");
            fixture.manager.on_device_list_fetch_failed(fixture.first, new Jid("same-contact@example.test/resource"),
                new Xmpp.Xep.Pubsub.RequestAllResult(null, ErrorStanza.TYPE_AUTH,
                    ErrorStanza.CONDITION_FORBIDDEN, "Do not display arbitrary server text", true));
            fail_if(peer_message.marked != Message.Marked.ERROR || peer_message.delivery_error_text == null,
                "A rejected counterpart list request must make its waiting direct send visibly retryable");
            fail_if_not(((!) peer_message.delivery_error_text).contains("presence subscription"));
            fail_if(((!) peer_message.delivery_error_text).contains("arbitrary server text"));
            fail_if(own_message.encryption != Encryption.OMEMO || peer_message.encryption != Encryption.OMEMO,
                "A list request error must retain the user's encrypted sending selection");
            fail_if(sessions_message.marked != Message.Marked.UNSENT || sessions_state.waiting_other_sessions != 1,
                "A list failure must not terminate messages waiting only for sessions");
            fail_if(other_message.marked != Message.Marked.UNSENT || other_state.waiting_other_devicelists != 1);
            fail_if(active_message.marked != Message.Marked.UNSENT || !active_state.active_send_attempt);
            fail_if(group_message.marked != Message.Marked.UNSENT || group_state.waiting_other_devicelists != 1);
            fail_if(recreated_message.marked != Message.Marked.UNSENT || recreated_state.waiting_other_devicelists != 1);
            fail_if(fixture.manager.update_send_state(own_message, own_wait) == own_state,
                "A failed direct send must be removed from the transient queue for explicit retry");
            fail_if(fixture.manager.update_send_state(peer_message, peer_wait) == peer_state,
                "A failed direct send must be removed from the transient queue for explicit retry");
        });
    }

    private void test_bundle_access_denial(bool own_keys) {
        with_fixture((fixture) => {
            Context context = Plugin.get_context();
            Store store = setup_test_store_context(context);
            Store peer = setup_test_store_context(context);
            store.identity_key_store.local_registration_id = 101;
            peer.identity_key_store.local_registration_id = 202;
            Jid jid = own_keys ? fixture.first.bare_jid : new Jid("same-contact@example.test");
            int identity_id = (int) fixture.db.identity.upsert()
                .value(fixture.db.identity.account_id, fixture.first.id, true)
                .value(fixture.db.identity.device_id, 101)
                .value(fixture.db.identity.identity_key_private_base64,
                    Base64.encode(store.identity_key_store.identity_key_private.get_data()))
                .value(fixture.db.identity.identity_key_public_base64,
                    Base64.encode(store.identity_key_store.identity_key_public.get_data()))
                .perform_checked();
            foreach (int32 device_id in new int32[] { 202, 303, 404, 505, 606 }) {
                add_device(fixture, identity_id, jid, device_id, peer);
            }
            add_device(fixture, identity_id, fixture.first.bare_jid, 101, store);
            build_native_session(context, store, peer, jid, 202);
            fixture.db.identity_meta.update()
                .with(fixture.db.identity_meta.identity_id, "=", identity_id)
                .with(fixture.db.identity_meta.device_id, "=", 404)
                .set(fixture.db.identity_meta.now_active, false).perform();
            fixture.db.identity_meta.update()
                .with(fixture.db.identity_meta.identity_id, "=", identity_id)
                .with(fixture.db.identity_meta.device_id, "=", 505)
                .set(fixture.db.identity_meta.trust_level, TrustLevel.UNTRUSTED).perform();
            fixture.stream = new ListUpdateTestStream(new Jid("example.test"));
            var stream = (!) fixture.stream;
            var bind = new Bind.Flag();
            bind.my_jid = fixture.first.bare_jid.with_resource("desktop");
            stream.add_flag(bind);
            stream.negotiation_complete = true;
            stream.add_module(new Iq.Module());
            stream.add_module(new MessageModule());
            stream.add_module(new Xmpp.Xep.ServiceDiscovery.Module.with_identity(
                Xmpp.Xep.ServiceDiscovery.Identity.CATEGORY_CLIENT,
                Xmpp.Xep.ServiceDiscovery.Identity.TYPE_PC, "DinoX Access Denial Test"));
            stream.add_module(new Xmpp.Xep.Pubsub.Module());
            fixture.module = new StreamModule(store);
            stream.add_module((!) fixture.module);
            fixture.interactor.connection_manager.set_connected_stream_for_tests(fixture.first, stream);

            var wait = waiting_state(1);
            if (own_keys) {
                wait.other_unknown = 0;
                wait.other_success = 1;
                wait.own_devices = 2;
                wait.own_unknown = 1;
            }
            Message message = fixture.make_message(fixture.first);
            var state = fixture.manager.update_send_state(message, wait);
            Message other = fixture.make_message(fixture.second);
            var other_state = fixture.manager.update_send_state(other, wait);
            var recreated = new Account(fixture.first.bare_jid, "test-password") { id = fixture.second.id + 1 };
            Message replacement = fixture.make_message(recreated);
            var replacement_state = fixture.manager.update_send_state(replacement, wait);
            Message active = fixture.make_message(fixture.first);
            var active_state = fixture.manager.update_send_state(active, wait);
            active_state.active_send_attempt = true;
            Message group = fixture.make_message(fixture.first);
            group.type_ = Message.Type.GROUPCHAT;
            var group_wait = waiting_state(1);
            group_wait.own_devices = 2;
            group_wait.own_unknown = 1;
            fixture.manager.update_send_state(group, group_wait);
            Message pm = fixture.make_message(fixture.first);
            pm.type_ = Message.Type.GROUPCHAT_PM;
            fixture.manager.update_send_state(pm, wait);
            Message list_wait = fixture.make_message(fixture.first);
            var list_status = waiting_state(0);
            list_status.other_waiting_lists = 1;
            var list_state = fixture.manager.update_send_state(list_wait, list_status);

            // These denials arrived at the real authenticated IQ boundary in
            // LegacyBundlePubSub; here exercise the manager's queue filtering
            // against persisted active/trust state and an actual native session.
            if (own_keys) {
                fixture.manager.on_bundle_access_denied(fixture.first,
                    fixture.first.bare_jid.with_resource("desktop"), 101, true);
                fail_if(message.marked != Message.Marked.UNSENT,
                    "Current-sender metadata denial must not fail a send waiting for another own device");
                fail_if(fixture.manager.update_send_state(message, wait) != state,
                    "An unrelated current-device denial must preserve the queued send");
            }
            foreach (int device_id in new int[] { 202, 404, 505, 999 }) {
                fixture.manager.on_bundle_access_denied(fixture.first, jid, device_id, true);
                fail_if(message.marked != Message.Marked.UNSENT,
                    "Existing-session, inactive, untrusted and unrelated devices must not terminate a wait");
            }
            fixture.manager.on_bundle_access_denied(fixture.first,
                new Jid("unrelated@example.test"), 303, true);
            fail_if(message.marked != Message.Marked.UNSENT);
            // The direct send is still waiting for needed device 606. A
            // metadata query for skipped 303 must retain that pending attempt.
            ((!) fixture.module).ignore_device(jid, 303);
            fail_if(((!) fixture.module).has_legacy_session_for_send(jid, 606));
            fixture.manager.on_bundle_access_denied(fixture.first, jid, 303, true);
            fail_if(message.marked != Message.Marked.UNSENT);
            fail_if(fixture.manager.update_send_state(message, wait) != state,
                "A skipped-device metadata denial must preserve the original queued attempt");
            ((!) fixture.module).unignore_device(jid, 303);
            fixture.manager.on_bundle_access_denied(fixture.first, jid.with_resource("phone"), 303, true);
            fail_if(message.marked != Message.Marked.ERROR || message.delivery_error_text == null);
            fail_if_not(((!) message.delivery_error_text).contains("presence subscription"));
            fail_if_not(((!) message.delivery_error_text).contains("retry the encrypted message"));
            fail_if(own_keys && ((!) message.delivery_error_text).contains("Ask the contact"));
            fail_if(message.encryption != Encryption.OMEMO);
            fail_if(fixture.manager.update_send_state(message, wait) == state,
                "Only explicit retry may put a denied message back in the queue");
            fail_if(fixture.manager.update_send_state(other, wait) != other_state);
            fail_if(fixture.manager.update_send_state(replacement, wait) != replacement_state);
            fail_if(!active_state.active_send_attempt || active.marked != Message.Marked.UNSENT);
            fail_if(group.marked != Message.Marked.UNSENT || pm.marked != Message.Marked.UNSENT);
            fail_if(list_wait.marked != Message.Marked.UNSENT || list_state.waiting_other_devicelists != 1);
            fail_if_not_eq_int(stream.messages.size, 0, "Denial may not trigger a plaintext or encrypted fallback send");
            var row = fixture.db.identity_meta.get_device(identity_id, jid.to_string(), 303);
            fail_if(row == null || !((!) row)[fixture.db.identity_meta.now_active]);
            fail_if(row != null && ((!) row)[fixture.db.identity_meta.trust_level] != TrustLevel.TRUSTED);
            fail_if(((!) fixture.module).is_ignored_device(jid, 303));

            // The existing encryptor only skips a legacy-ignored device if
            // both modules ignore it (or no v2 module is present). Reading
            // this flag must neither enable v2 nor change its send policy.
            var module2 = new StreamModule2(store);
            module2.auto_publish_own_device_list = false;
            stream.add_module(module2);
            ((!) fixture.module).ignore_device(jid, 303);
            Message legacy_only_ignored = fixture.make_message(fixture.first);
            fixture.manager.update_send_state(legacy_only_ignored, wait);
            fixture.manager.on_bundle_access_denied(fixture.first, jid, 303);
            fail_if(legacy_only_ignored.marked != Message.Marked.ERROR,
                "Legacy-only ignored state must not bypass the encryptor's actual still-needed recipient");
            module2.ignore_device(jid, 303);
            Message both_ignored = fixture.make_message(fixture.first);
            var both_ignored_state = fixture.manager.update_send_state(both_ignored, wait);
            fixture.manager.on_bundle_access_denied(fixture.first, jid, 303);
            fail_if(both_ignored.marked != Message.Marked.UNSENT);
            fail_if(fixture.manager.update_send_state(both_ignored, wait) != both_ignored_state);
            module2.detach(stream);
        });
    }
}

private class ListUpdateTestStream : XmppStream {
    internal ArrayList<StanzaNode> messages = new ArrayList<StanzaNode>();
    internal ArrayList<StanzaNode> iq_requests = new ArrayList<StanzaNode>();

    internal ListUpdateTestStream(Jid remote_name) { base(remote_name); }
    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_CONNECTED("isolated device-list update stream");
    }
    public override async void write_async(StanzaNode node,
            int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (node.name == "message") messages.add(node);
        if (node.name == "iq" && node.get_attribute("type") == "get") iq_requests.add(node);
        // Keep missing-device bundle IQs pending until the authoritative list
        // removes that device. No fabricated bundle failure unblocks this test.
    }
}

}
