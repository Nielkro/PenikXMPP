using Dino.Entities;
using Dino.Plugins.Omemo;
using Omemo;
using Qlite;
using Xmpp;

namespace Omemo.Test {

class TrustLifecycleTest : Gee.TestCase {
    public TrustLifecycleTest() {
        base("TrustLifecycle");
        add_test("message_owned_tags_survive_edits_and_release_aborted_messages", test_tag_lifetime);
        add_test("account_epoch_removal_never_revives_old_message_tags", test_tag_epoch);
        add_test("stale_displayed_key_cannot_accept_verify_reset_or_remove", test_stale_key);
        add_test("account_and_identity_recreation_invalidate_device_actions", test_identity_scope);
        add_test("exact_key_action_failure_preserves_metadata_and_native_session", test_failed_remove);
        add_test("verification_clears_warning_and_reveals_unknown_messages_live", () => test_reveal(TrustLevel.VERIFIED));
        add_test("acceptance_clears_warning_and_reveals_unknown_messages_live", () => test_reveal(TrustLevel.TRUSTED));
        add_test("visibility_changes_are_not_new_messages_and_cannot_cross_accounts", test_visibility_scope);
        add_test("history_clear_prevents_trust_reveal", test_cleared_history);
        add_test("verified_badge_uses_the_message_account", test_badge_scope);
        add_test("reused_device_key_does_not_reveal_or_verify_old_messages", test_historical_key);
        add_test("legacy_hidden_messages_without_fingerprint_remain_unassigned", test_legacy_provenance);
        add_test("exact_fingerprint_reveals_hidden_previously_trusted_messages", test_hidden_previously_trusted);
        add_test("v10_upgrade_preserves_metadata_without_inventing_fingerprints", test_metadata_migration);
        add_test("checked_contact_reset_is_scoped_and_signals_only_after_commit", test_contact_reset);
        add_test("failed_contact_reset_preserves_native_and_persistent_sessions", test_contact_reset_rollback);
        add_test("authenticated_room_peer_is_ephemeral_without_privacy_authority", test_ephemeral_room_peer);
        add_test("explicit_device_reset_with_confirmed_absence_is_successful", test_absent_device_reset);
        add_test("stale_native_backing_identity_cannot_reset_or_remove_sessions", test_stale_backing_store);
        add_test("device_trust_display_signals_only_durable_manual_actions", test_trust_display_signal);
        add_test("conversation_summary_requires_all_active_current_keys", test_summary_active_keys);
        add_test("conversation_summary_is_account_and_identity_scoped", test_summary_scope);
        add_test("conversation_summary_never_borrows_replaced_key_trust", test_summary_changed_key);
        add_test("conversation_summary_includes_other_own_devices", test_summary_own_devices);
        add_test("conversation_summary_is_read_only_without_application", test_summary_read_only);
        add_test("conversation_summary_requires_a_group_recipient_snapshot", test_summary_group_without_snapshot);
    }

    internal static void restore_pre_v11_content_meta(Dino.Plugins.Omemo.Database db) throws Error {
        db.exec("ALTER TABLE content_item_meta RENAME TO content_item_meta_v11");
        db.exec("CREATE TABLE content_item_meta (message_id INTEGER PRIMARY KEY, identity_id INTEGER NOT NULL, " +
            "address_name TEXT NOT NULL, device_id INTEGER NOT NULL, trusted_when_received INTEGER NOT NULL DEFAULT 1)");
        db.exec("INSERT INTO content_item_meta SELECT message_id, identity_id, address_name, device_id, " +
            "trusted_when_received FROM content_item_meta_v11");
        db.exec("DROP TABLE content_item_meta_v11");
    }

    private class Collection : Object, Dino.ContentItemCollection {
        public void insert_item(Dino.ContentItem item) { }
        public void remove_item(Dino.ContentItem item) { }
    }

    private class Fixture : Object {
        internal string directory;
        internal Dino.Database app_db;
        internal Dino.Plugins.Omemo.Database db;
        internal Dino.StreamInteractor interactor;
        internal TrustManager trust;
        internal Dino.ContentItemStore items;
        internal Account account;
        internal Account other;
        internal Conversation conversation;
        internal Conversation other_conversation;
        internal Jid peer;
        internal int identity_id;
        internal int other_identity_id;
        internal string key_a;
        internal string key_b;
        internal Store store;

        internal Fixture() throws Error {
            directory = DirUtils.make_tmp("dinox-trust-lifecycle-XXXXXX");
            app_db = new Dino.Database(Path.build_filename(directory, "app.db"), "test-only");
            db = new Dino.Plugins.Omemo.Database(Path.build_filename(directory, "omemo.db"));
            interactor = new Dino.StreamInteractor.for_tests(app_db);
            Dino.MessageProcessor.start(interactor, app_db);
            Dino.MessageStorage.start(interactor, app_db);
            items = new Dino.ContentItemStore.for_tests(interactor, app_db);
            interactor.add_module(items);
            account = new Account(new Jid("first@example.test"), "test-only");
            other = new Account(new Jid("second@example.test"), "test-only");
            account.persist(app_db);
            other.persist(app_db);
            peer = new Jid("peer@example.test");
            conversation = new Conversation(peer, account, Conversation.Type.CHAT);
            other_conversation = new Conversation(peer, other, Conversation.Type.CHAT);
            conversation.persist(app_db);
            other_conversation.persist(app_db);
            items.init(conversation, new Collection());
            items.init(other_conversation, new Collection());
            var own = Plugin.get_context().generate_key_pair();
            key_a = Base64.encode(Plugin.get_context().generate_key_pair().public.serialize());
            key_b = Base64.encode(Plugin.get_context().generate_key_pair().public.serialize());
            identity_id = create_identity(account, own);
            other_identity_id = create_identity(other, own);
            insert_device(identity_id, key_a, TrustLevel.UNKNOWN);
            insert_device(other_identity_id, key_a, TrustLevel.UNTRUSTED);
            trust = new TrustManager(interactor, db, app_db);
            store = setup_test_store_context(Plugin.get_context());
            store.identity_key_store.identity_key_public = new Bytes(own.public.serialize());
            store.identity_key_store.identity_key_private = new Bytes(own.private.serialize());
            store.identity_key_store.local_registration_id = (uint32) (1000 + account.id);
            store.session_store = new BackedSessionStore(db, identity_id);
            interactor.module_manager.initialize_account_modules.connect((acc, modules) => {
                modules.add(new StreamModule(store));
            });
            interactor.module_manager.initialize(account);
        }

        private int create_identity(Account account, ECKeyPair own) throws Error {
            return (int) db.identity.upsert().value(db.identity.account_id, account.id, true)
                .value(db.identity.device_id, 1000 + account.id)
                .value(db.identity.identity_key_public_base64, Base64.encode(own.public.serialize()))
                .value(db.identity.identity_key_private_base64, Base64.encode(own.private.serialize())).perform_checked();
        }

        internal void insert_device(int identity, string key, TrustLevel level) throws Error {
            db.identity_meta.upsert().value(db.identity_meta.identity_id, identity, true)
                .value(db.identity_meta.address_name, peer.to_string(), true)
                .value(db.identity_meta.device_id, 123, true)
                .value(db.identity_meta.identity_key_public_base64, key)
                .value(db.identity_meta.trust_level, level)
                .value(db.identity_meta.identity_key_changed, true)
                .value(db.identity_meta.last_message_untrusted, 1700000000L).perform_checked();
        }

        internal Row device() throws Error {
            Row? row = db.identity_meta.get_device_checked(identity_id, peer.to_string(), 123);
            if (row == null) throw new IOError.FAILED("Test device is missing");
            return (!) row;
        }

        internal Message message(Conversation? use_conversation = null) throws Error {
            Conversation conv = use_conversation ?? conversation;
            var message = new Message("isolated trust message") {
                account = conv.account, counterpart = peer, ourpart = conv.account.bare_jid,
                real_jid = peer, type_ = Message.Type.CHAT, direction = Message.DIRECTION_RECEIVED,
                time = new DateTime.from_unix_utc(1700000001), local_time = new DateTime.from_unix_utc(1700000001),
                encryption = Encryption.OMEMO
            };
            interactor.get_module<Dino.MessageStorage>(Dino.MessageStorage.IDENTITY).add_message(message, conv);
            app_db.add_content_item(conv, message.time, message.local_time, 1, message.id, false);
            return message;
        }

        internal Dino.ContentItem item(Message message, Conversation? conv = null) throws Error {
            Dino.ContentItem? item = items.get_item_by_foreign(conv ?? conversation, 1, message.id);
            if (item == null) throw new IOError.FAILED("Test content item is missing");
            return (!) item;
        }

        internal bool hidden(Dino.ContentItem item) {
            return app_db.content_item.select().with(app_db.content_item.id, "=", item.id).single().row()[app_db.content_item.hide];
        }

        internal void close() {
            interactor.module_manager.remove(account);
            items.uninit(conversation, new Collection());
            items.uninit(other_conversation, new Collection());
            db.close(); app_db.close();
            foreach (string name in new string[]{"omemo.db", "app.db"}) {
                FileUtils.remove(Path.build_filename(directory, name));
                FileUtils.remove(Path.build_filename(directory, name + "-wal"));
                FileUtils.remove(Path.build_filename(directory, name + "-shm"));
            }
            DirUtils.remove(directory);
        }
    }

    private delegate void FixtureAction(Fixture f) throws Error;
    private void run_fixture(FixtureAction action) {
        Fixture? f = null;
        try { f = new Fixture(); action((!) f); }
        catch (Error e) { fail_if_reached(e.message); }
        finally { if (f != null) ((!) f).close(); }
    }

    private void tag(Fixture f, Message message, Conversation? conversation = null) {
        var loop = new MainLoop();
        bool done = false;
        f.trust.tag_message_for_tests.begin(message, new MessageStanza(), conversation ?? f.conversation, (obj, res) => {
            f.trust.tag_message_for_tests.end(res); done = true; if (loop.is_running()) loop.quit();
        });
        if (!done) loop.run();
    }

    private EncryptionListEntry summary_entry(Fixture f) {
        // No application/stream manager: a 1:1 summary must use only the DB.
        var plugin = new Plugin();
        plugin.db = f.db;
        return new EncryptionListEntry(plugin);
    }

    private void set_summary_device(Fixture f, Account account, Jid jid, int device_id,
            string? key, TrustLevel trust, bool active = true, bool changed = false) throws Error {
        int identity = f.db.identity.get_id_checked(account.id);
        var insert = f.db.identity_meta.upsert()
            .value(f.db.identity_meta.identity_id, identity, true)
            .value(f.db.identity_meta.address_name, jid.bare_jid.to_string(), true)
            .value(f.db.identity_meta.device_id, device_id, true)
            .value(f.db.identity_meta.trust_level, trust)
            .value(f.db.identity_meta.now_active, active)
            .value(f.db.identity_meta.identity_key_changed, changed);
        if (key == null) insert.value_null(f.db.identity_meta.identity_key_public_base64);
        else insert.value(f.db.identity_meta.identity_key_public_base64, (!) key);
        insert.perform_checked();
    }

    private void expect_summary(EncryptionListEntry entry, Conversation conversation,
            Dino.Plugins.ConversationEncryptionTrust expected) {
        fail_if_not_eq_int((int) entry.get_conversation_trust(conversation), (int) expected);
    }

    private void test_summary_active_keys() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.TRUSTED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.TRUSTED);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);

            foreach (TrustLevel level in new TrustLevel[]{TrustLevel.UNKNOWN, TrustLevel.UNTRUSTED}) {
                set_summary_device(f, f.account, f.peer, 124, f.key_b, level);
                expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            }
            set_summary_device(f, f.account, f.peer, 124, null, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            set_summary_device(f, f.account, f.peer, 124, "", TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            set_summary_device(f, f.account, f.peer, 124, f.key_b, TrustLevel.TRUSTED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.TRUSTED);
            set_summary_device(f, f.account, f.peer, 124, f.key_b, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);

            // Old/rejected/incomplete inactive devices do not spoil current keys.
            set_summary_device(f, f.account, f.peer, 124, null, TrustLevel.UNTRUSTED, false, true);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED, false);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);
        });
    }

    private void test_summary_scope() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            expect_summary(entry, f.other_conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            var full_jid_conversation = new Conversation(f.peer.with_resource("phone"), f.account, Conversation.Type.CHAT);
            expect_summary(entry, full_jid_conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            var unrelated = new Conversation(new Jid("other-peer@example.test"), f.account, Conversation.Type.CHAT);
            expect_summary(entry, unrelated, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);

            f.db.identity.delete().with(f.db.identity.id, "=", f.identity_id).perform_checked();
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);
            var own = Plugin.get_context().generate_key_pair();
            int replacement = (int) f.db.identity.upsert()
                .value(f.db.identity.account_id, f.account.id, true)
                .value(f.db.identity.device_id, 888)
                .value(f.db.identity.identity_key_public_base64, Base64.encode(own.public.serialize()))
                .value(f.db.identity.identity_key_private_base64, Base64.encode(own.private.serialize())).perform_checked();
            fail_if(replacement == f.identity_id, "fixture must create a distinct identity scope");
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);
        });
    }

    private void test_summary_changed_key() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            f.insert_device(f.identity_id, f.key_b, TrustLevel.UNKNOWN);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            // A changed marker defeats even an inconsistent retained trust flag.
            set_summary_device(f, f.account, f.peer, 123, f.key_b, TrustLevel.VERIFIED, true, true);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            f.trust.perform_key_action(f.account, f.peer,
                new DeviceKeyTarget(f.account, f.device(), f.db), TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            fail_if_not_eq_str(f.device()[f.db.identity_meta.identity_key_public_base64], f.key_b);
        });
    }

    private void test_summary_own_devices() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            int own_id = 1000 + f.account.id;
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            set_summary_device(f, f.account, f.account.bare_jid, own_id, null, TrustLevel.UNKNOWN, true, true);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            set_summary_device(f, f.account, f.account.bare_jid, own_id + 1, f.key_b, TrustLevel.TRUSTED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.TRUSTED);
            set_summary_device(f, f.account, f.account.bare_jid, own_id + 1, f.key_b, TrustLevel.VERIFIED);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            set_summary_device(f, f.account, f.account.bare_jid, own_id + 1, f.key_b, TrustLevel.UNKNOWN);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
            set_summary_device(f, f.account, f.account.bare_jid, own_id + 1, null, TrustLevel.UNKNOWN, false);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
            // Device numbers alone do not identify our current device.
            set_summary_device(f, f.account, f.peer, own_id, null, TrustLevel.UNKNOWN);
            expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION);
        });
    }

    private void test_summary_read_only() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            f.db.exec("PRAGMA query_only = ON");
            try {
                expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
                expect_summary(entry, f.conversation, Dino.Plugins.ConversationEncryptionTrust.VERIFIED);
                fail_if_not_eq_int(f.device()[f.db.identity_meta.trust_level], TrustLevel.VERIFIED);
                fail_if_not_eq_str(f.device()[f.db.identity_meta.identity_key_public_base64], f.key_a);
            } finally {
                try {
                    f.db.exec("PRAGMA query_only = OFF");
                } catch (Error error) {
                    GLib.Test.message("Could not restore writable test database: %s", error.message);
                    GLib.Test.fail();
                }
            }
        });
    }

    private void test_summary_group_without_snapshot() {
        run_fixture((f) => {
            var entry = summary_entry(f);
            set_summary_device(f, f.account, f.peer, 123, f.key_a, TrustLevel.VERIFIED);
            var group = new Conversation(f.peer, f.account, Conversation.Type.GROUPCHAT);
            var private_message = new Conversation(f.peer.with_resource("nick"), f.account, Conversation.Type.GROUPCHAT_PM);
            // A verified key at the same address is not a room-member snapshot.
            expect_summary(entry, group, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);
            expect_summary(entry, private_message, Dino.Plugins.ConversationEncryptionTrust.UNKNOWN);
        });
    }

    private void put_metadata(Fixture f, Dino.ContentItem item, string? key, bool trusted_when_received) throws Error {
        var insert = f.db.content_item_meta.upsert()
            .value(f.db.content_item_meta.content_item_id, item.id, true)
            .value(f.db.content_item_meta.identity_id, f.identity_id)
            .value(f.db.content_item_meta.address_name, f.peer.to_string())
            .value(f.db.content_item_meta.device_id, 123)
            .value(f.db.content_item_meta.trusted_when_received, trusted_when_received);
        if (key != null) insert.value(f.db.content_item_meta.key_public, key);
        insert.perform_checked();
    }

    private void test_tag_lifetime() {
        run_fixture((f) => {
            Message? message = new Message("") { account = f.account };
            WeakRef message_ref = WeakRef(message);
            f.trust.remember_message_device((!) message, 123);
            ((!) message).body = "later pipeline edit";
            fail_if_not_eq_int(f.trust.get_message_device((!) message), 123);
            message = null;
            fail_if(message_ref.get() != null, "a filtered key transport must not be retained by its device tag");
            var stored = new Message("stored") { account = f.account };
            f.trust.remember_message_device(stored, 123);
            fail_if_not_eq_int(f.trust.take_message_device(stored), 123);
            fail_if_not_eq_int(f.trust.get_message_device(stored), 0);
        });
    }

    private void test_tag_epoch() {
        run_fixture((f) => {
            var old = new Message("old") { account = f.account };
            f.trust.remember_message_device(old, 123);
            f.trust.forget_account(f.account);
            fail_if_not_eq_int(f.trust.get_message_device(old), 0);
            var recreated = new Account(f.account.bare_jid, "test-only") { id = f.account.id };
            var current = new Message("current") { account = recreated };
            f.trust.remember_message_device(current, 456);
            fail_if_not_eq_int(f.trust.get_message_device(current), 456);
            fail_if_not_eq_int(f.trust.get_message_device(old), 0);
        });
    }

    private void test_stale_key() {
        run_fixture((f) => {
            int display_signals = 0;
            f.trust.device_trust_state_changed.connect((account, jid) => { display_signals++; });
            var target = new DeviceKeyTarget(f.account, f.device(), f.db);
            f.insert_device(f.identity_id, f.key_b, TrustLevel.UNKNOWN);
            Address address = new Address(f.peer.to_string(), 123);
            f.store.session_store.store_session(address, new uint8[]{1, 2, 3});
            foreach (int action in new int[]{TrustLevel.TRUSTED, TrustLevel.VERIFIED, TrustLevel.UNTRUSTED, -1, -2}) {
                bool refused = false;
                try { f.trust.perform_key_action(f.account, f.peer, target, action); }
                catch (DeviceKeyActionError.STALE_KEY e) { refused = true; }
                fail_if_not(refused, "old displayed fingerprint must not authorize any new-key action");
                Row row = f.device();
                fail_if_not_eq_str(row[f.db.identity_meta.identity_key_public_base64], f.key_b);
                fail_if_not_eq_int(row[f.db.identity_meta.trust_level], TrustLevel.UNKNOWN);
                fail_if_not(row[f.db.identity_meta.identity_key_changed]);
                fail_if_not_eq_uint8_arr((!) f.store.session_store.load_session(address), new uint8[]{1, 2, 3});
            }
            fail_if_not_eq_int(display_signals, 0);
            address.device_id = 0;
        });
    }

    private void test_trust_display_signal() {
        run_fixture((f) => {
            var observer = new Dino.Plugins.Omemo.Database(Path.build_filename(f.directory, "omemo.db"));
            try {
                int display_signals = 0;
                int expected_trust = TrustLevel.VERIFIED;
                f.trust.device_trust_state_changed.connect((account, jid) => {
                    display_signals++;
                    fail_if_not(account == f.account && jid.equals(f.peer));
                    try {
                        // A separate connection sees only committed metadata.
                        Row? device = observer.identity_meta.get_device_checked(f.identity_id, f.peer.to_string(), 123);
                        if (expected_trust == -1) fail_if(device != null);
                        else {
                            fail_if(device == null);
                            if (device != null) fail_if_not_eq_int(((!) device)[observer.identity_meta.trust_level], expected_trust);
                        }
                    } catch (Error e) { fail_if_reached(e.message); }
                });
                f.trust.perform_key_action(f.account, f.peer,
                    new DeviceKeyTarget(f.account, f.device(), f.db), TrustLevel.VERIFIED);
                fail_if_not_eq_int(display_signals, 1);
                f.trust.bad_message_state_updated(f.account, f.peer, 123);
                fail_if_not_eq_int(display_signals, 1, "message warnings must not become trust display events");

                f.db.exec("CREATE TEMP TRIGGER block_display_remove BEFORE DELETE ON identity_meta BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
                bool refused = false;
                try { f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), -1); }
                catch (Error e) { refused = true; }
                fail_if_not(refused);
                fail_if_not_eq_int(display_signals, 1, "rolled back removal must not notify observers");
                f.db.exec("DROP TRIGGER block_display_remove");
                expected_trust = -1;
                f.trust.perform_key_action(f.account, f.peer,
                    new DeviceKeyTarget(f.account, f.device(), f.db), -1);
                fail_if_not_eq_int(display_signals, 2);
            } finally { observer.close(); }
        });
    }

    private void test_identity_scope() {
        run_fixture((f) => {
            var target = new DeviceKeyTarget(f.account, f.device(), f.db);
            bool refused = false;
            try { f.trust.perform_key_action(f.other, f.peer, target, TrustLevel.VERIFIED); }
            catch (DeviceKeyActionError.STALE_KEY e) { refused = true; }
            fail_if_not(refused);
            f.db.identity.delete().with(f.db.identity.id, "=", f.identity_id).perform_checked();
            refused = false;
            try { f.trust.perform_key_action(f.account, f.peer, target, TrustLevel.VERIFIED); }
            catch (DeviceKeyActionError.STALE_KEY e) { refused = true; }
            fail_if_not(refused);
            fail_if_not_eq_int(f.device()[f.db.identity_meta.trust_level], TrustLevel.UNKNOWN);
        });
    }

    private void test_failed_remove() {
        run_fixture((f) => {
            var target = new DeviceKeyTarget(f.account, f.device(), f.db);
            Address address = new Address(f.peer.to_string(), 123);
            f.store.session_store.store_session(address, new uint8[]{4, 5, 6});
            f.db.exec("CREATE TEMP TRIGGER block_remove BEFORE DELETE ON identity_meta BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
            bool refused = false;
            try { f.trust.perform_key_action(f.account, f.peer, target, -1); }
            catch (Error e) { refused = true; }
            fail_if_not(refused);
            fail_if_not_eq_str(f.device()[f.db.identity_meta.identity_key_public_base64], f.key_a);
            fail_if_not_eq_uint8_arr((!) f.store.session_store.load_session(address), new uint8[]{4, 5, 6});
            Row? session = f.db.session.select().with(f.db.session.identity_id, "=", f.identity_id)
                .with(f.db.session.address_name, "=", f.peer.to_string()).single().iterator().get_next_checked();
            fail_if(session == null);
            fail_if_not_eq_str(((!) session)[f.db.session.record_base64], Base64.encode(new uint8[]{4, 5, 6}));
            address.device_id = 0;
        });
    }

    private void test_reveal(TrustLevel accepted) {
        run_fixture((f) => {
            Message message = f.message();
            f.trust.remember_message_device(message, 123, f.key_a, f.peer);
            var loop = new MainLoop();
            bool done = false;
            f.trust.tag_message_for_tests.begin(message, new MessageStanza(), f.conversation, (obj, res) => {
                f.trust.tag_message_for_tests.end(res); done = true; if (loop.is_running()) loop.quit();
            });
            if (!done) loop.run();
            var item = f.item(message);
            fail_if_not(f.hidden(item), "UNKNOWN messages must initially be hidden");
            RowOption metadata = f.db.content_item_meta.select().with(f.db.content_item_meta.content_item_id, "=", item.id).single().row();
            fail_if(metadata[f.db.content_item_meta.trusted_when_received], "UNKNOWN must remain eligible for a later trust projection");
            int reveals = 0; int new_messages = 0;
            f.items.item_visibility_changed.connect((changed, conv, hidden) => { if (changed.id == item.id && !hidden) reveals++; });
            f.items.new_item.connect((changed, conv) => { new_messages++; });
            f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), accepted);
            fail_if(f.hidden(item));
            fail_if_not_eq_int(reveals, 1);
            fail_if_not_eq_int(new_messages, 0);
            fail_if_not(f.db.identity_meta.last_message_untrusted.is_null(f.device()));
            fail_if_not_eq_int(f.trust.get_message_device(message), 0, "STORE consumes only this pipeline object's tag");
        });
    }

    private void test_visibility_scope() {
        run_fixture((f) => {
            var item = f.item(f.message());
            var other_item = f.item(f.message(f.other_conversation), f.other_conversation);
            f.items.set_item_hide_checked(item, true);
            f.items.set_item_hide_checked(other_item, true);
            int projected = 0;
            f.items.item_visibility_changed.connect((changed, conv, hidden) => { if (!hidden) projected++; });
            f.items.apply_trust_visibility(f.account, other_item.id, false);
            fail_if_not(f.hidden(other_item));
            fail_if_not_eq_int(projected, 0);
            f.items.apply_trust_visibility(f.account, item.id, false);
            fail_if(f.hidden(item));
            fail_if_not_eq_int(projected, 1);
        });
    }

    private void test_cleared_history() {
        run_fixture((f) => {
            var item = f.item(f.message());
            f.items.set_item_hide_checked(item, true);
            f.conversation.history_cleared_at = item.time.add_seconds(1);
            int reveals = 0;
            f.items.item_visibility_changed.connect((changed, conv, hidden) => { if (!hidden) reveals++; });
            f.items.apply_trust_visibility(f.account, item.id, false);
            fail_if_not(f.hidden(item));
            fail_if_not_eq_int(reveals, 0);
        });
    }

    private void test_badge_scope() {
        run_fixture((f) => {
            f.insert_device(f.identity_id, f.key_a, TrustLevel.VERIFIED);
            var other_item = f.item(f.message(f.other_conversation), f.other_conversation);
            f.db.content_item_meta.upsert().value(f.db.content_item_meta.content_item_id, other_item.id, true)
                .value(f.db.content_item_meta.identity_id, f.other_identity_id)
                .value(f.db.content_item_meta.address_name, f.peer.to_string())
                .value(f.db.content_item_meta.device_id, 123)
                .value(f.db.content_item_meta.key_public, f.key_a).perform_checked();
            var plugin = new Plugin(); plugin.db = f.db;
            var entry = new EncryptionListEntry(plugin);
            fail_if(entry.get_encryption_icon_name(f.other_conversation, other_item) != null,
                "another account's verified trust must not label an untrusted message");
            fail_if(entry.get_encryption_icon_name(f.conversation, other_item) != null,
                "a foreign content item cannot borrow the current account's trust");
        });
    }

    private void test_historical_key() {
        run_fixture((f) => {
            var message = f.message();
            // A historic ratchet authenticates A after device 123 has already
            // been replaced by B. Its trust must not be borrowed from B.
            f.insert_device(f.identity_id, f.key_b, TrustLevel.UNKNOWN);
            f.db.identity_meta.update().with(f.db.identity_meta.identity_id, "=", f.identity_id)
                .set_null(f.db.identity_meta.last_message_untrusted).perform_checked();
            f.trust.remember_message_device(message, 123, f.key_a, f.peer);
            tag(f, message);
            var item = f.item(message);
            fail_if_not(f.hidden(item));
            fail_if_not(f.db.identity_meta.last_message_untrusted.is_null(f.device()), "old A must not create a warning for current B");
            f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), TrustLevel.VERIFIED);
            fail_if_not(f.hidden(item), "approving B must not reveal a message authenticated by A");
            var plugin = new Plugin(); plugin.db = f.db;
            fail_if(new EncryptionListEntry(plugin).get_encryption_icon_name(f.conversation, item) != null,
                "B's verification must not label historical A messages");
            fail_if_not_eq_str(f.db.content_item_meta.select().with(f.db.content_item_meta.content_item_id, "=", item.id)
                .single().row()[f.db.content_item_meta.key_public], f.key_a);
        });
    }

    private void test_legacy_provenance() {
        run_fixture((f) => {
            var item = f.item(f.message());
            f.items.set_item_hide_checked(item, true);
            put_metadata(f, item, null, true);
            fail_if_not(f.trust.has_unassigned_hidden_messages(f.account, f.peer, 123));
            fail_if(f.trust.has_unassigned_hidden_messages(f.other, f.peer, 123));
            f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), TrustLevel.VERIFIED);
            fail_if_not(f.hidden(item), "legacy metadata has no safe fingerprint association");
            var plugin = new Plugin(); plugin.db = f.db;
            fail_if(new EncryptionListEntry(plugin).get_encryption_icon_name(f.conversation, item) != null);
            Row? metadata = f.db.content_item_meta.select()
                .with(f.db.content_item_meta.content_item_id, "=", item.id).single().iterator().get_next_checked();
            if (fail_if(metadata == null)) return;
            fail_if_not(f.db.content_item_meta.key_public.is_null((!) metadata));
        });
    }

    private void test_hidden_previously_trusted() {
        run_fixture((f) => {
            var item = f.item(f.message());
            f.items.set_item_hide_checked(item, true);
            put_metadata(f, item, f.key_a, true);
            f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), TrustLevel.TRUSTED);
            fail_if(f.hidden(item), "actual hide and exact fingerprint determine the projection, not an old trust flag");
        });
    }

    private void test_metadata_migration() {
        run_fixture((f) => {
            var item = f.item(f.message());
            f.items.set_item_hide_checked(item, true);
            put_metadata(f, item, f.key_a, true);
            restore_pre_v11_content_meta(f.db);
            f.db.exec("UPDATE _meta SET int_val = 10 WHERE name = 'version'");
            string filename = Path.build_filename(f.directory, "omemo.db");
            f.db.close();
            var upgraded = new Dino.Plugins.Omemo.Database(filename);
            f.db = upgraded;
            {
                Row? row = upgraded.content_item_meta.select().with(upgraded.content_item_meta.content_item_id, "=", item.id)
                    .single().iterator().get_next_checked();
                if (fail_if(row == null)) return;
                fail_if_not(upgraded.content_item_meta.key_public.is_null((!) row));
                fail_if_not(((!) row)[upgraded.content_item_meta.trusted_when_received]);
                fail_if_not_eq_int(((!) row)[upgraded.content_item_meta.identity_id], f.identity_id);
                fail_if_not(f.hidden(item), "plugin migration must not alter core message visibility");
            }
        });
    }

    private void test_contact_reset() {
        run_fixture((f) => {
            var scope = new AccountKeyScope(f.account, f.db);
            Address first = new Address(f.peer.to_string(), 123);
            Address second = new Address(f.peer.to_string(), 456);
            f.store.session_store.store_session(first, new uint8[]{1});
            f.store.session_store.store_session(second, new uint8[]{2});
            f.db.session.upsert().value(f.db.session.identity_id, f.other_identity_id, true)
                .value(f.db.session.address_name, f.peer.to_string(), true).value(f.db.session.device_id, 123, true)
                .value(f.db.session.record_base64, "other-account-session").perform_checked();
            int signals = 0;
            f.trust.contact_sessions_reset.connect((account, jid) => {
                fail_if_not(account == f.account && jid.equals(f.peer)); signals++;
            });
            bool stale_refused = false;
            try { f.trust.reset_all_sessions_checked(f.other, f.peer, scope); }
            catch (DeviceKeyActionError.STALE_KEY e) { stale_refused = true; }
            fail_if_not(stale_refused); fail_if_not_eq_int(signals, 0);
            f.trust.reset_all_sessions_checked(f.account, f.peer, scope);
            fail_if_not_eq_int(signals, 1);
            fail_if(f.store.session_store.contains_session(first) || f.store.session_store.contains_session(second));
            fail_if(f.db.session.select().with(f.db.session.identity_id, "=", f.other_identity_id).single().row().is_present() == false);
            first.device_id = 0; second.device_id = 0;
        });
    }

    private void test_contact_reset_rollback() {
        run_fixture((f) => {
            Address address = new Address(f.peer.to_string(), 123);
            f.store.session_store.store_session(address, new uint8[]{7, 8});
            int signals = 0;
            f.trust.contact_sessions_reset.connect((account, jid) => { signals++; });
            f.db.exec("CREATE TEMP TRIGGER block_reset BEFORE DELETE ON session BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
            bool refused = false;
            try { f.trust.reset_all_sessions_checked(f.account, f.peer, new AccountKeyScope(f.account, f.db)); }
            catch (Error e) { refused = true; }
            fail_if_not(refused); fail_if_not_eq_int(signals, 0);
            fail_if_not_eq_uint8_arr((!) f.store.session_store.load_session(address), new uint8[]{7, 8});
            fail_if_not_eq_str(f.db.session.select().with(f.db.session.identity_id, "=", f.identity_id)
                .single().row()[f.db.session.record_base64], Base64.encode(new uint8[]{7, 8}));
            address.device_id = 0;
        });
    }

    private void test_ephemeral_room_peer() {
        run_fixture((f) => {
            var room = new Conversation(new Jid("room@conference.example.test"), f.account, Conversation.Type.GROUPCHAT);
            room.persist(f.app_db); f.items.init(room, new Collection());
            f.insert_device(f.identity_id, f.key_a, TrustLevel.VERIFIED);
            var message = f.message(room);
            message.type_ = Message.Type.GROUPCHAT;
            message.counterpart = new Jid("room@conference.example.test/nick");
            message.real_jid = null;
            f.trust.remember_message_device(message, 123, f.key_a, f.peer);
            tag(f, message, room);
            var item = f.item(message, room);
            fail_if(f.hidden(item), "native-authenticated accepted history must not require a retained real JID");
            fail_if(f.db.content_item_meta.select().with(f.db.content_item_meta.content_item_id, "=", item.id)
                .single().row().is_present(), "plugin metadata must not persist a forbidden room identity link");
            f.items.uninit(room, new Collection());
        });
    }

    private void test_absent_device_reset() {
        run_fixture((f) => {
            int resets = 0;
            f.trust.session_reset.connect((account, jid, device) => {
                fail_if_not(account == f.account && jid.equals(f.peer) && device == 123); resets++;
            });
            f.trust.perform_key_action(f.account, f.peer, new DeviceKeyTarget(f.account, f.device(), f.db), -2);
            fail_if_not_eq_int(resets, 1);
        });
    }

    private void test_stale_backing_store() {
        run_fixture((f) => {
            Address address = new Address(f.peer.to_string(), 123);
            var other_store = new BackedSessionStore(f.db, f.other_identity_id);
            other_store.store_session(address, new uint8[]{9, 10});
            // Native public identity alone cannot identify a database scope:
            // these fixture accounts deliberately share the same public key.
            f.store.session_store = other_store;
            var target = new DeviceKeyTarget(f.account, f.device(), f.db);
            int signals = 0;
            f.trust.session_reset.connect((account, jid, device) => { signals++; });
            f.trust.contact_sessions_reset.connect((account, jid) => { signals++; });
            foreach (int action in new int[]{-1, -2}) {
                bool refused = false;
                try { f.trust.perform_key_action(f.account, f.peer, target, action); }
                catch (DeviceKeyActionError.UNAVAILABLE e) { refused = true; }
                fail_if_not(refused);
            }
            bool refused = false;
            try { f.trust.reset_all_sessions_checked(f.account, f.peer, new AccountKeyScope(f.account, f.db)); }
            catch (DeviceKeyActionError.UNAVAILABLE e) { refused = true; }
            fail_if_not(refused); fail_if_not_eq_int(signals, 0);
            fail_if_not_eq_uint8_arr((!) other_store.load_session(address), new uint8[]{9, 10});
            fail_if_not_eq_str(f.device()[f.db.identity_meta.identity_key_public_base64], f.key_a);
            fail_if_not_eq_str(f.db.session.select().with(f.db.session.identity_id, "=", f.other_identity_id)
                .single().row()[f.db.session.record_base64], Base64.encode(new uint8[]{9, 10}));
            address.device_id = 0;
        });
    }
}

}
