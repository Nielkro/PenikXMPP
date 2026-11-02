using Gee;
using Xmpp;

namespace Dino.Test {

class AvatarAudit : Gee.TestCase {
    private const string HASH_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string HASH_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private const string HASH_C = "cccccccccccccccccccccccccccccccccccccccc";
    private const string NS_VCARD_UPDATE = "vcard-temp:x:update";
    private const string NS_PUBSUB = "http://jabber.org/protocol/pubsub";
    private const string NS_AVATAR_METADATA = "urn:xmpp:avatar:metadata";
    private const string NS_VCARD = "vcard-temp";

    public AvatarAudit() {
        base("AvatarAudit");
        add_test("SHA1_hash_normalization_rejects_unsafe_cache_keys", test_hash_normalization);
        add_test("Hash_store_is_account_scoped_and_preserves_source_priority", test_hash_store_account_scope);
        add_test("Hash_store_snapshots_and_waiters_are_deduplicated", test_snapshot_and_waiter_deduplication);
        add_test("Memory_cache_is_LRU_and_bounded_by_entries_and_bytes", test_memory_cache_limits);
        add_test("Cache_worker_roundtrip_runs_off_main_thread", test_cache_worker_roundtrip_sync);
        add_test("Manager_deduplicates_shared_hash_cache_load", test_manager_shared_hash_cache_load);
        add_test("MUC_hash_burst_waits_for_explicit_avatar_demand", test_muc_hash_burst_is_demand_driven);
        add_test("MUC_stable_snapshot_starts_bounded_avatar_prefetch", test_muc_stable_snapshot_prefetch);
        add_test("MUC_live_delta_prevents_stale_snapshot_avatar_rollback", test_muc_live_delta_prevents_stale_snapshot_avatar_rollback);
        add_test("MUC_avatar_state_survives_resume_and_resets_on_fresh_stream",
            test_muc_avatar_reconnect_lifecycle);
        add_test("Participant_avatar_identity_preserves_chat_and_public_MUC_semantics", test_participant_avatar_identity);
        add_test("Manager_preload_keeps_same_contact_isolated_per_account", test_manager_preload_account_scope);
        add_test("Manager_does_not_seed_unverified_own_vCard_hash",
            test_manager_does_not_seed_own_vcard_presence);
        add_test("Manager_fences_superseded_own_avatar_operations",
            test_manager_fences_superseded_own_avatar_operations);
        add_test("Manager_reverifies_interrupted_own_avatar_after_recovery",
            test_manager_reverifies_interrupted_own_avatar_after_recovery);
        add_test("Manager_classifies_partial_own_avatar_results",
            test_manager_classifies_partial_own_avatar_results);
        add_test("Manager_starts_vCard_without_waiting_for_PEP",
            test_manager_starts_vcard_without_waiting_for_pep);
        add_test("Manager_emits_only_preferred_hash_transitions", test_manager_hash_transition_signals);
        add_test("Manager_routes_keyed_observers_by_account_and_JID", test_manager_keyed_observer_routing);
        add_test("MUC_room_avatar_cache_load_stays_on_bounded_worker",
            test_muc_room_avatar_cache_load);
    }

    private void test_muc_room_avatar_cache_load() {
        MainLoop loop = new MainLoop();
        bool timed_out = false;
        test_muc_room_avatar_cache_load_async.begin((_, result) => {
            test_muc_room_avatar_cache_load_async.end(result);
            loop.quit();
        });
        uint timeout_id = Timeout.add_seconds(10, () => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (!timed_out) Source.remove(timeout_id);
        fail_if(timed_out,
            "Timed out waiting for the room-avatar cache worker audit");
    }

    private async void test_muc_room_avatar_cache_load_async() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-room-avatar-cache-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        string? hash = null;
        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "room-avatar-cache-audit");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            var encryption = new Security.FileEncryption(
                "room-avatar-cache-audit");
            AvatarManager.start(stream_interactor, (!) db,
                encryption);
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);
            var account = new Entities.Account(
                new Jid("owner@example.test"), "secret");
            account.persist((!) db);
            Jid room = new Jid("room@conference.example.test");
            Bytes bytes = new Bytes("room-avatar-cache".data);
            hash = Checksum.compute_for_bytes(ChecksumType.SHA1, bytes);
            FileUtils.remove(Path.build_filename(Dino.get_cache_dir(),
                "avatars", (!) hash));

            AvatarCacheWorkerResult stored = yield AvatarCacheWorker.store(
                Path.build_filename(Dino.get_cache_dir(), "avatars",
                    (!) hash), encryption, bytes);
            fail_if(!stored.committed,
                "A verified room avatar must be stored by the bounded cache worker");
            manager.purge_in_memory_caches();
            int loads_before = AvatarCacheWorker.get_executed_load_jobs();
            MucRoomAvatarCacheProbe loaded = yield manager
                .probe_muc_room_avatar_image((!) hash);
            fail_if(loaded != MucRoomAvatarCacheProbe.HIT ||
                    AvatarCacheWorker.get_executed_load_jobs() <=
                    loads_before,
                "Pre-join cache reuse must decrypt through AvatarCacheWorker, not synchronous UI I/O");

            manager.commit_muc_room_vcard_hash(account, room, (!) hash, true);
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    account, room, AvatarSource.VCARD), hash,
                "A worker-verified cache hit must be committed only to the exact account and bare room");

            bool mismatch_rejected = false;
            string wrong_hash = Checksum.compute_for_bytes(ChecksumType.SHA1,
                new Bytes("different-room-avatar".data));
            try {
                yield AvatarCacheWorker.load_verified(Path.build_filename(
                    Dino.get_cache_dir(), "avatars", (!) hash), encryption,
                    wrong_hash);
            } catch (AvatarCacheWorkerError.CORRUPT error) {
                mismatch_rejected = true;
            }
            fail_if(!mismatch_rejected,
                "Content-address verification must reject mismatched cache bytes on the worker");
        } catch (Error error) {
            fail_if_reached(@"Unexpected room avatar cache test error: $(error.message)");
        } finally {
            if (hash != null) {
                FileUtils.remove(Path.build_filename(Dino.get_cache_dir(),
                    "avatars", (!) hash));
            }
            if (db != null) ((!) db).close();
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_keyed_observer_routing() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-observer-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-observer-audit");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, new Security.FileEncryption("avatar-observer-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);

            var first_account = new Entities.Account(new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Entities.Account(new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            Jid contact = new Jid("contact@example.test");
            Jid room = new Jid("room@conference.example.test");
            Jid occupant = room.with_resource("nick");
            int contact_events = 0;
            int occupant_events = 0;
            int room_events = 0;
            int other_account_events = 0;
            int one_shot_events = 0;

            AvatarObserver contact_observer = manager.observe_avatar(first_account, contact, (jid, account) => {
                contact_events++;
                return true;
            });
            AvatarObserver occupant_observer = manager.observe_avatar(first_account, occupant, (jid, account) => {
                occupant_events++;
                return true;
            });
            AvatarObserver room_observer = manager.observe_avatar(first_account, room, (jid, account) => {
                room_events++;
                return true;
            });
            AvatarObserver other_observer = manager.observe_avatar(second_account, contact, (jid, account) => {
                other_account_events++;
                return true;
            });
            Jid one_shot_contact = new Jid("one-shot@example.test");
            manager.observe_avatar(first_account, one_shot_contact, (jid, account) => {
                one_shot_events++;
                return false;
            });

            manager.handle_vcard_avatar_received(first_account, occupant, HASH_A, true);
            fail_if(occupant_events != 1 || room_events != 0 || contact_events != 0 || other_account_events != 0,
                "A MUC occupant avatar transition must reach only its exact occupant observer");

            manager.handle_vcard_avatar_received(first_account, room, HASH_A, false);
            fail_if(room_events != 1 || occupant_events != 1 || contact_events != 0 || other_account_events != 0,
                "A room avatar transition must reach only its exact room observer");

            manager.handle_vcard_avatar_received(first_account, contact, HASH_B, false);
            fail_if(contact_events != 1 || occupant_events != 1 || room_events != 1 || other_account_events != 0,
                "A contact avatar transition must stay account/JID scoped");

            manager.handle_vcard_avatar_received(second_account, contact, HASH_C, false);
            fail_if(other_account_events != 1 || contact_events != 1,
                "The same avatar JID on another account must remain isolated");

            manager.handle_vcard_avatar_received(first_account, one_shot_contact, HASH_A, false);
            manager.handle_vcard_avatar_received(first_account, one_shot_contact, HASH_B, false);
            fail_if(one_shot_events != 1, "An avatar observer returning false must remove itself after one dispatch");

            contact_observer.unsubscribe();
            manager.handle_vcard_avatar_received(first_account, contact, HASH_C, false);
            fail_if(contact_events != 1, "Unsubscribed avatar observers must receive no later events");

            occupant_observer.unsubscribe();
            room_observer.unsubscribe();
            other_observer.unsubscribe();
        } catch (Error e) {
            fail_if_reached(@"Unexpected keyed avatar observer error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_hash_normalization() {
        fail_if_not_eq_str(AvatarHashStore.normalize_hash("  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  "), HASH_A,
            "Valid SHA-1 hashes must be trimmed and normalized once");
        fail_if(AvatarHashStore.normalize_hash("abc") != null, "Short hashes must not reach avatar cache paths");
        fail_if(AvatarHashStore.normalize_hash("../../../../tmp/avatar-cache-entry") != null,
            "Path-like identifiers must not reach avatar cache paths");
        fail_if(AvatarHashStore.normalize_hash("gggggggggggggggggggggggggggggggggggggggg") != null,
            "Non-hexadecimal identifiers must be rejected");
    }

    private void test_muc_avatar_reconnect_lifecycle() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-reconnect-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-reconnect-audit");
            var first_account = new Entities.Account(
                new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Entities.Account(
                new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-reconnect-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);

            Jid room = new Jid("room@conference.example.test");
            Jid first_occupant = room.with_resource("first");
            Jid second_occupant = room.with_resource("second");
            Jid contact = new Jid("contact@example.test");
            manager.handle_vcard_avatar_received(first_account, first_occupant,
                HASH_A, true);
            manager.handle_vcard_avatar_received(first_account, contact,
                HASH_B, false);
            manager.handle_vcard_avatar_received(second_account,
                second_occupant, HASH_C, true);
            var retained_stream = new AvatarAuditStream(
                new Jid("example.test"));
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(first_account,
                    retained_stream);
            int initial_generation = manager
                .get_muc_avatar_account_generation_for_tests(first_account);

            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(first_account);
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    first_account, first_occupant, AvatarSource.VCARD), HASH_A,
                "A provisional disconnect must retain occupant Full-JID hashes");
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    first_account, contact, AvatarSource.VCARD), HASH_B,
                "A provisional disconnect must retain durable contact hashes");
            fail_if(manager.get_muc_avatar_account_generation_for_tests(
                    first_account) == initial_generation,
                "A provisional disconnect must fence active MUC avatar requests");

            // Same-stream recovery emits CONNECTED without either stream
            // signal.
            stream_interactor.connection_manager.set_connection_state_for_tests(
                first_account, ConnectionManager.ConnectionState.CONNECTED);
            fail_if(manager.is_muc_avatar_account_paused_for_tests(
                first_account),
                "Same-stream recovery must reopen interrupted avatar work immediately");
            drain_avatar_audit_context();
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    first_account, first_occupant, AvatarSource.VCARD), HASH_A,
                "Same-stream ping recovery must retain occupant Full-JID hashes");

            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(first_account);
            stream_interactor.connection_manager
                .set_stream_replacement_pending_for_tests(first_account);
            var resumed_stream = new AvatarAuditStream(
                new Jid("example.test"));
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                first_account, resumed_stream);
            fail_if_not(manager.is_muc_avatar_account_paused_for_tests(
                    first_account),
                "A replacement stream must wait for confirmed XEP-0198 resumption");
            stream_interactor.stream_resumed(first_account, resumed_stream);
            fail_if(manager.is_muc_avatar_account_paused_for_tests(
                    first_account),
                "Confirmed stream resumption must reopen avatar work immediately");
            drain_avatar_audit_context();
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    first_account, first_occupant, AvatarSource.VCARD), HASH_A,
                "A resumed stream must retain occupant Full-JID hashes");

            int resumed_generation = manager
                .get_muc_avatar_account_generation_for_tests(first_account);
            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(first_account);
            stream_interactor.connection_manager
                .set_stream_replacement_pending_for_tests(first_account);
            var fresh_stream = new AvatarAuditStream(new Jid("example.test"));
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                first_account, fresh_stream);
            fail_if_not(manager.is_muc_avatar_account_paused_for_tests(
                    first_account),
                "A fresh replacement stream must not replay retained MUC avatars before negotiation decides its lifecycle");
            stream_interactor.stream_negotiated(first_account, fresh_stream);
            fail_if(manager.is_muc_avatar_account_paused_for_tests(
                    first_account),
                "Fresh stream negotiation must end retained-session avatar recovery");
            drain_avatar_audit_context();
            fail_if(manager.get_avatar_source_hash_for_tests(first_account,
                    first_occupant, AvatarSource.VCARD) != null,
                "A fresh stream must invalidate stale occupant Full-JID hashes");
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    first_account, contact, AvatarSource.VCARD), HASH_B,
                "A fresh stream must retain durable bare-JID contact hashes");
            fail_if_not_eq_str(manager.get_avatar_source_hash_for_tests(
                    second_account, second_occupant, AvatarSource.VCARD),
                HASH_C,
                "A fresh stream reset must stay scoped to its account");
            fail_if(manager.get_muc_avatar_account_generation_for_tests(
                    first_account) == resumed_generation,
                "A fresh stream must fence the previous avatar session again");
        } catch (Error error) {
            fail_if_reached(@"Unexpected avatar reconnect lifecycle error: $(error.message)");
        } finally {
            if (db != null) ((!) db).close();
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_hash_store_account_scope() {
        try {
            var store = new AvatarHashStore();
            Jid contact = new Jid("contact@example.test");
            bool preferred_changed;

            fail_if_not(store.update_hash(1, contact, HASH_A, AvatarSource.VCARD, out preferred_changed));
            fail_if_not(preferred_changed, "First vCard hash must establish the preferred avatar");
            fail_if_not(store.update_hash(2, contact, HASH_C, AvatarSource.VCARD, out preferred_changed));
            fail_if_not_eq_str(store.get_preferred(1, contact), HASH_A, "Account 1 must retain its own hash");
            fail_if_not_eq_str(store.get_preferred(2, contact), HASH_C, "Account 2 must retain its own hash");

            fail_if_not(store.update_hash(1, contact, HASH_B, AvatarSource.USER_AVATARS, out preferred_changed));
            fail_if_not(preferred_changed, "XEP-0084 must replace vCard as the preferred source");
            fail_if_not_eq_str(store.get_preferred(1, contact), HASH_B, "XEP-0084 must have source priority");

            fail_if_not(store.update_hash(1, contact, HASH_C, AvatarSource.VCARD, out preferred_changed));
            fail_if(preferred_changed, "Changing a hidden fallback source must not trigger a display transition");
            fail_if(store.update_hash(1, contact, "  BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB ", AvatarSource.USER_AVATARS, out preferred_changed),
                "A repeated normalized source hash must be deduplicated");

            fail_if_not(store.remove(1, contact, AvatarSource.USER_AVATARS, out preferred_changed));
            fail_if_not(preferred_changed, "Removing XEP-0084 must expose the vCard fallback");
            fail_if_not_eq_str(store.get_preferred(1, contact), HASH_C, "vCard fallback must survive source removal");
            fail_if(store.remove(1, contact, AvatarSource.USER_AVATARS, out preferred_changed),
                "Removing an absent source must be a no-op");

            Jid occupant = new Jid("room@conference.example.test/nick");
            store.update_hash(1, occupant, HASH_A, AvatarSource.VCARD, out preferred_changed);
            store.update_hash(2, occupant, HASH_B, AvatarSource.VCARD, out preferred_changed);
            fail_if(store.remove_full_jids(1, AvatarSource.VCARD) != 1,
                "Stream teardown must remove exactly the account's transient full-JID avatars");
            fail_if(store.get_source(1, occupant, AvatarSource.VCARD) != null,
                "Account-1 transient occupant avatar must be cleared");
            fail_if_not_eq_str(store.get_source(2, occupant, AvatarSource.VCARD), HASH_B,
                "Transient cleanup must not affect another account");
            fail_if_not_eq_str(store.get_preferred(1, contact), HASH_C,
                "Transient cleanup must retain durable bare-JID avatar state");

            store.remove_account(1);
            fail_if(store.get_preferred(1, contact) != null,
                "Removing an account must clear its durable in-memory hashes");
            fail_if_not_eq_str(store.get_source(2, occupant, AvatarSource.VCARD), HASH_B,
                "Account removal must not clear another account's hashes");
        } catch (Error e) {
            fail_if_reached(@"Unexpected avatar hash-store error: $(e.message)");
        }
    }

    private void test_snapshot_and_waiter_deduplication() {
        try {
            var store = new AvatarHashStore();
            Jid contact = new Jid("contact@example.test");
            bool preferred_changed;
            store.update_hash(7, contact, HASH_A, AvatarSource.VCARD, out preferred_changed);

            HashMap<Jid, string> snapshot = store.snapshot(7, AvatarSource.VCARD);
            snapshot.clear();
            fail_if_not_eq_str(store.get_preferred(7, contact), HASH_A,
                "Mutating a snapshot must not alter hash-store ownership");

            var first_account = new Entities.Account(new Jid("first@example.test"), "secret");
            first_account.id = 7;
            var second_account = new Entities.Account(new Jid("second@example.test"), "secret");
            second_account.id = 8;
            var waiters = new AvatarWaiterSet();

            fail_if_not(waiters.add(first_account, contact, 1, true), "First account/JID waiter must be added");
            fail_if(waiters.add(first_account, contact, 1), "Repeated account/JID waiter must be deduplicated");
            fail_if(waiters.add(first_account, contact, 2), "A newer generation must replace, not duplicate, one waiter");
            fail_if_not(waiters.add(second_account, contact, 1), "The same JID on another account must remain distinct");
            fail_if(waiters.size != 2, "Waiter deduplication must retain exactly two account/JID identities");

            bool found_new_generation = false;
            bool preserved_network_policy = false;
            foreach (AvatarWaiter waiter in waiters.snapshot()) {
                if (waiter.account.id == first_account.id) {
                    found_new_generation = waiter.generation == 2;
                    preserved_network_policy = waiter.network_allowed;
                }
            }
            fail_if_not(found_new_generation, "Replacing a waiter must retain its newest generation");
            fail_if_not(preserved_network_policy,
                "Deduplicating a local-only waiter must not downgrade an existing network repair request");
            fail_if(waiters.remove_account(first_account.id) != 1,
                "Account teardown must remove exactly its deduplicated waiter");
            fail_if(waiters.size != 1, "Another account's waiter must survive account teardown");
            fail_if(waiters.remove(first_account, contact), "An already removed waiter must be a no-op");
        } catch (Error e) {
            fail_if_reached(@"Unexpected avatar waiter error: $(e.message)");
        }
    }

    private void test_memory_cache_limits() {
        var entry_limited = new AvatarMemoryCache(2, 100);
        fail_if_not(entry_limited.put("a", new Bytes(new uint8[4])), "First LRU entry must be cached");
        fail_if_not(entry_limited.put("b", new Bytes(new uint8[4])), "Second LRU entry must be cached");
        fail_if(entry_limited.lookup("a") == null, "Reading an entry must keep it available and mark it recent");
        fail_if_not(entry_limited.put("c", new Bytes(new uint8[4])), "Third LRU entry must be cached after eviction");
        fail_if(entry_limited.contains("b"), "The least-recently-used entry must be evicted first");
        fail_if(!entry_limited.contains("a") || !entry_limited.contains("c") || entry_limited.entry_count != 2,
            "Entry-bound eviction must retain exactly the two most recent entries");

        var byte_limited = new AvatarMemoryCache(10, 10);
        byte_limited.put("a", new Bytes(new uint8[6]));
        byte_limited.put("b", new Bytes(new uint8[4]));
        byte_limited.lookup("a");
        byte_limited.put("c", new Bytes(new uint8[5]));
        fail_if(byte_limited.contains("a") || byte_limited.contains("b") || !byte_limited.contains("c"),
            "Byte-bound eviction must continue from the LRU tail until the cache is within budget");
        fail_if(byte_limited.byte_count != 5 || byte_limited.entry_count != 1,
            "Byte accounting must match the retained immutable payload");
        fail_if(byte_limited.put("oversized", new Bytes(new uint8[11])),
            "A single entry larger than the byte budget must not evict useful cached data");
        fail_if(!byte_limited.contains("c") || byte_limited.byte_count != 5,
            "Rejecting an oversized entry must preserve the existing cache");

        var replacement = new AvatarMemoryCache(10, 10);
        replacement.put("same", new Bytes(new uint8[4]));
        replacement.put("same", new Bytes(new uint8[8]));
        fail_if(replacement.entry_count != 1 || replacement.byte_count != 8,
            "Replacing one hash must update byte accounting without duplicating its LRU node");
        replacement.clear();
        fail_if(replacement.entry_count != 0 || replacement.byte_count != 0,
            "Clearing the cache must reset entries, links, and byte accounting");
    }

    private void test_manager_hash_transition_signals() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-audit");
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, new Security.FileEncryption("avatar-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);

            var first_account = new Entities.Account(new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Entities.Account(new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            Jid contact = new Jid("contact@example.test");

            int hash_transitions = 0;
            int bytes_ready_events = 0;
            manager.received_avatar.connect((jid, account) => hash_transitions++);
            manager.fetched_avatar.connect((jid, account) => bytes_ready_events++);

            manager.handle_vcard_avatar_received(first_account, contact, HASH_A, false);
            manager.handle_vcard_avatar_received(first_account, contact, "  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ", false);
            fail_if(hash_transitions != 1, "Repeated vCard presence hashes must emit one hash transition");

            manager.on_user_avatar_received(first_account, contact, HASH_B);
            manager.handle_vcard_avatar_received(first_account, contact, HASH_C, false);
            fail_if(hash_transitions != 2,
                "Changing a non-preferred vCard fallback must not emit while XEP-0084 is preferred");

            manager.on_user_avatar_removed(first_account, contact);
            manager.on_user_avatar_removed(first_account, contact);
            fail_if(hash_transitions != 3, "Removing XEP-0084 must expose vCard exactly once");

            manager.handle_vcard_avatar_removed(first_account, contact, false);
            manager.handle_vcard_avatar_removed(first_account, contact, false);
            fail_if(hash_transitions != 4, "Removing the vCard fallback must emit one transition to no avatar");

            manager.on_user_avatar_received(second_account, contact, HASH_A);
            manager.on_user_avatar_received(second_account, contact, "../../../../tmp/not-a-hash");
            fail_if(hash_transitions != 5, "Another account must have one isolated hash transition");
            fail_if(bytes_ready_events != 0, "Hash transitions must not be duplicated as bytes-ready events");

            HashMap<Jid, string> first_vcards = manager.get_avatar_hashes(first_account, (int) AvatarSource.VCARD);
            HashMap<Jid, string> first_users = manager.get_avatar_hashes(first_account, (int) AvatarSource.USER_AVATARS);
            HashMap<Jid, string> second_users = manager.get_avatar_hashes(second_account, (int) AvatarSource.USER_AVATARS);
            fail_if(first_vcards.has_key(contact), "Removed account-1 vCard state must be deleted from the DB");
            fail_if(first_users.has_key(contact), "Removed account-1 XEP-0084 state must be deleted from the DB");
            fail_if_not_eq_str(second_users[contact], HASH_A, "Account 2 must persist an isolated XEP-0084 hash");
        } catch (Error e) {
            fail_if_reached(@"Unexpected AvatarManager transition error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_cache_worker_roundtrip_sync() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-worker-" + Uuid.string_random());
        string cache_path = Path.build_filename(temp_dir, "avatar-cache-entry");
        DirUtils.create_with_parents(temp_dir, 0700);
        int64 caller_thread_id = (int64) Thread.self<void*>();
        var loop = new MainLoop();

        test_cache_worker_roundtrip.begin(cache_path, caller_thread_id, (obj, result) => {
            test_cache_worker_roundtrip.end(result);
            loop.quit();
        });
        loop.run();

        FileUtils.remove(cache_path);
        DirUtils.remove(temp_dir);
    }

    private async void test_cache_worker_roundtrip(string cache_path, int64 caller_thread_id) {
        try {
            var encryption = new Security.FileEncryption("avatar-worker-audit");
            Bytes original = new Bytes("worker-avatar-roundtrip".data);

            AvatarCacheWorkerResult stored = yield AvatarCacheWorker.store(cache_path, encryption, original);
            fail_if(!stored.committed || !stored.ran_on_worker ||
                    stored.worker_thread_id == caller_thread_id,
                "Avatar encryption and cache writes must run outside the caller thread");
            fail_if((int64) Thread.self<void*>() != caller_thread_id,
                "Avatar worker store completion must resume on the caller context");

            AvatarCacheWorkerResult loaded = yield AvatarCacheWorker.load(cache_path, encryption);
            fail_if(!loaded.ran_on_worker || loaded.worker_thread_id == caller_thread_id,
                "Avatar reads, PBKDF, and decryption must run outside the caller thread");
            fail_if((int64) Thread.self<void*>() != caller_thread_id,
                "Avatar worker load completion must resume on the caller context");
            fail_if_not_eq_str(
                Checksum.compute_for_bytes(ChecksumType.SHA256, loaded.bytes),
                Checksum.compute_for_bytes(ChecksumType.SHA256, original),
                "Avatar cache worker must preserve plaintext bytes");
            fail_if(AvatarCacheWorker.THREAD_COUNT != 2,
                "Avatar cache work must use the fixed two-thread pool");
            fail_if(AvatarCacheWorker.MAX_OUTSTANDING_JOBS <= AvatarCacheWorker.THREAD_COUNT,
                "Avatar cache worker must expose a finite bounded queue beyond its active workers");

            FileUtils.set_data(cache_path, "not-an-encrypted-avatar".data);
            bool rejected_corrupt = false;
            try {
                yield AvatarCacheWorker.load(cache_path, encryption);
            } catch (AvatarCacheWorkerError.CORRUPT error) {
                rejected_corrupt = true;
            }
            fail_if(!rejected_corrupt, "Corrupt encrypted avatar entries must be rejected");
            fail_if(FileUtils.test(cache_path, FileTest.EXISTS),
                "Corrupt encrypted avatar entries must be removed by the worker");

            // Hold the real promotion mutex, let a worker finish encryption
            // and create its staging file, then invalidate the generation
            // before allowing that already-running worker to continue.
            int in_flight_generation = AvatarCacheWorker
                .hold_store_promotion_for_tests();
            AvatarCacheWorkerResult? fenced = null;
            Error? in_flight_error = null;
            bool in_flight_finished = false;
            AvatarCacheWorker.store_if_generation.begin(cache_path,
                encryption, original, in_flight_generation, (_, result) => {
                    try {
                        fenced = AvatarCacheWorker.store_if_generation.end(
                            result);
                    } catch (Error error) {
                        in_flight_error = error;
                    }
                    in_flight_finished = true;
                });
            bool staging_seen = run_avatar_audit_until(() => {
                return avatar_cache_staging_exists(cache_path);
            }, 1000);
            AvatarCacheWorker
                .invalidate_and_release_store_promotion_for_tests();

            fail_if(!staging_seen,
                "The in-flight store must reach staging before cache invalidation");
            fail_if(!run_avatar_audit_until(() => in_flight_finished, 1000),
                "The fenced in-flight store must complete after purge releases promotion");
            fail_if(in_flight_error != null || fenced == null ||
                    ((!) fenced).committed ||
                    FileUtils.test(cache_path, FileTest.EXISTS),
                "A store already in flight during cache purge must not recreate its avatar file");
            fail_if(avatar_cache_staging_exists(cache_path),
                "A fenced in-flight store must remove its unique staging file");

            AvatarCacheWorkerResult current = yield AvatarCacheWorker.store(
                cache_path, encryption, original);
            fail_if(!current.committed ||
                    !FileUtils.test(cache_path, FileTest.EXISTS),
                "A post-purge store must still commit in the current generation");
        } catch (Error error) {
            fail_if_reached(@"Unexpected avatar cache worker error: $(error.message)");
        }
    }

    private void test_manager_shared_hash_cache_load() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-shared-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string avatar_dir = Path.build_filename(Dino.get_cache_dir(), "avatars");
        Database? db = null;
        string? cache_path = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            DirUtils.create_with_parents(avatar_dir, 0700);
            db = new Database(db_path, "avatar-shared-cache-audit");
            var account = new Entities.Account(new Jid("first@example.test"), "secret");
            account.persist((!) db);
            Jid first_contact = new Jid("first-contact@example.test");
            Jid second_contact = new Jid("second-contact@example.test");
            Jid stale_contact = new Jid("stale-contact@example.test");
            Bytes plaintext = new Bytes("shared-avatar-cache-bytes".data);
            string hash = Checksum.compute_for_bytes(ChecksumType.SHA1, plaintext);
            cache_path = Path.build_filename(avatar_dir, hash);
            var encryption = new Security.FileEncryption("avatar-shared-cache-audit");
            uint8[] ciphertext = encryption.encrypt_data(plaintext.get_data());
            fail_if(!FileUtils.set_data((!) cache_path, ciphertext), "Test avatar cache entry must be written");

            foreach (Jid contact in new Jid[] { first_contact, second_contact, stale_contact }) {
                ((!) db).avatar.insert()
                    .value(((!) db).avatar.jid_id, ((!) db).get_jid_id(contact))
                    .value(((!) db).avatar.account_id, account.id)
                    .value(((!) db).avatar.hash, hash)
                    .value(((!) db).avatar.type_, (int) AvatarSource.USER_AVATARS)
                    .perform();
            }

            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, encryption);
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
            int ready_events = 0;
            int async_completions = 0;
            bool first_async_loaded = false;
            bool stale_async_was_null = false;
            bool stale_ready_event = false;
            bool timed_out = false;
            var loop = new MainLoop();
            manager.fetched_avatar.connect((jid, ready_account) => {
                if (ready_account.id == account.id &&
                        (jid.equals(first_contact) || jid.equals(second_contact))) {
                    ready_events++;
                    if (ready_events == 2 && async_completions == 2) loop.quit();
                } else if (ready_account.id == account.id && jid.equals(stale_contact)) {
                    stale_ready_event = true;
                }
            });

            int loads_before = AvatarCacheWorker.get_executed_load_jobs();
            fail_if(manager.get_avatar_bytes_with_policy(account, first_contact, AvatarReadPolicy.MEMORY_ONLY) != null,
                "Memory-only policy must return a placeholder before hydration");
            fail_if(AvatarCacheWorker.get_executed_load_jobs() != loads_before,
                "Memory-only policy must not schedule cache worker I/O");
            manager.get_avatar_bytes_from_local_cache_async.begin(account, first_contact, (obj, result) => {
                Bytes? bytes = manager.get_avatar_bytes_from_local_cache_async.end(result);
                first_async_loaded = bytes != null;
                async_completions++;
                if (ready_events == 2 && async_completions == 2) loop.quit();
            });
            manager.get_avatar_bytes_from_local_cache_async.begin(account, stale_contact, (obj, result) => {
                Bytes? bytes = manager.get_avatar_bytes_from_local_cache_async.end(result);
                stale_async_was_null = bytes == null;
                async_completions++;
                if (ready_events == 2 && async_completions == 2) loop.quit();
            });
            fail_if(manager.get_avatar_bytes_with_policy(account, second_contact, AvatarReadPolicy.LOCAL_CACHE_ONLY) != null,
                "Second same-hash request must join the pending load");
            manager.on_user_avatar_received(account, stale_contact, HASH_B);

            uint timeout_source = Timeout.add_seconds(20, () => {
                timed_out = true;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_source);

            fail_if(timed_out, "Shared-hash avatar cache load must complete");
            fail_if(ready_events != 2, "Every account/JID waiter must receive one bytes-ready event");
            fail_if(async_completions != 2 || !first_async_loaded || !stale_async_was_null,
                "Keyed async cache waiters must return bytes only while account/JID/hash state is current");
            fail_if(stale_ready_event,
                "A cache result must not be applied after that contact changed to another hash");
            fail_if(AvatarCacheWorker.get_executed_load_jobs() - loads_before != 1,
                "Many waiters for one normalized hash must perform exactly one cache read/decrypt job");
            Bytes? first_bytes = manager.get_avatar_bytes_with_policy(account, first_contact, AvatarReadPolicy.MEMORY_ONLY);
            Bytes? second_bytes = manager.get_avatar_bytes_with_policy(account, second_contact, AvatarReadPolicy.MEMORY_ONLY);
            fail_if(first_bytes == null || second_bytes == null,
                "Successful async cache load must populate shared in-memory bytes");
        } catch (Error error) {
            fail_if_reached(@"Unexpected shared avatar cache-load error: $(error.message)");
        } finally {
            if (cache_path != null) FileUtils.remove((!) cache_path);
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_muc_hash_burst_is_demand_driven() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-demand-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string avatar_dir = Path.build_filename(Dino.get_cache_dir(), "avatars");
        Bytes demand_bytes = new Bytes("demand-driven-avatar".data);
        string demand_hash = Checksum.compute_for_bytes(ChecksumType.SHA1,
            demand_bytes);
        string cache_path = Path.build_filename(avatar_dir, demand_hash);
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            DirUtils.create_with_parents(avatar_dir, 0700);
            db = new Database(db_path, "avatar-demand-audit");
            var account = new Entities.Account(new Jid("demand@example.test"), "secret");
            account.persist((!) db);
            var encryption = new Security.FileEncryption("avatar-demand-audit");
            uint8[] ciphertext = encryption.encrypt_data(
                demand_bytes.get_data());
            fail_if(!FileUtils.set_data(cache_path, ciphertext), "Demand test cache entry must be written");

            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, encryption);
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
            int loads_before = AvatarCacheWorker.get_executed_load_jobs();
            int hash_transitions = 0;
            manager.received_avatar.connect((jid, ready_account) => {
                if (ready_account.id == account.id) hash_transitions++;
            });

            for (int i = 0; i < 5000; i++) {
                Jid occupant = new Jid("room@conference.example.test/occupant-%d".printf(i));
                manager.handle_vcard_avatar_received(account, occupant,
                    demand_hash, true);
            }
            fail_if(hash_transitions != 5000, "MUC hash state must still be recorded for every occupant");

            var idle_window = new MainLoop();
            Timeout.add(500, () => {
                idle_window.quit();
                return Source.REMOVE;
            });
            idle_window.run();
            fail_if(AvatarCacheWorker.get_executed_load_jobs() != loads_before,
                "A hidden 5000-occupant hash burst must schedule zero avatar decrypt jobs");

            Jid visible_contact = new Jid("visible@example.test");
            manager.handle_vcard_avatar_received(account, visible_contact,
                demand_hash, false);
            bool visible_ready = false;
            bool timed_out = false;
            var demand_loop = new MainLoop();
            manager.fetched_avatar.connect((jid, ready_account) => {
                if (ready_account.id == account.id && jid.equals(visible_contact)) {
                    visible_ready = true;
                    demand_loop.quit();
                }
            });
            fail_if(manager.get_avatar_bytes_with_policy(account, visible_contact, AvatarReadPolicy.LOCAL_CACHE_ONLY) != null,
                "First visible demand must return a placeholder while the worker loads");
            uint timeout_source = Timeout.add_seconds(20, () => {
                timed_out = true;
                demand_loop.quit();
                return Source.REMOVE;
            });
            demand_loop.run();
            if (!timed_out) Source.remove(timeout_source);

            fail_if(timed_out || !visible_ready, "Explicit visible avatar demand must complete");
            fail_if(AvatarCacheWorker.get_executed_load_jobs() - loads_before != 1,
                "Only explicit demand, not hidden MUC hashes, may consume one cache worker job");
        } catch (Error error) {
            fail_if_reached(@"Unexpected demand-driven avatar error: $(error.message)");
        } finally {
            FileUtils.remove(cache_path);
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_muc_stable_snapshot_prefetch() {
        const string SNAPSHOT_HASH = "dddddddddddddddddddddddddddddddddddddddd";
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-snapshot-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string cache_path = Path.build_filename(Dino.get_cache_dir(),
            "avatars", SNAPSHOT_HASH);
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            FileUtils.remove(cache_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-snapshot-audit");
            var account = new Entities.Account(
                new Jid("snapshot@example.test"), "secret");
            account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-snapshot-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);
            Jid room = new Jid("room@conference.example.test");
            Jid occupant = room.with_resource("snapshot-user");
            var key = new MucRoomKey(account.id,
                account.bare_jid.to_string(), room.to_string(), 1, 1);
            var snapshot = new MucOccupantSnapshot(occupant.to_string(),
                room.to_string(), "snapshot-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.PARTICIPANT, true, null, null,
                SNAPSHOT_HASH, true, GLib.get_monotonic_time());
            MucOccupantSnapshot[] changed = { snapshot };
            int[] flags = { (int) (MucOccupantChange.MEMBERSHIP |
                MucOccupantChange.AVATAR) };
            var delta = new MucRoomDelta(key, 1, true, true, true, false,
                true, 1, changed, null, flags);
            var role_snapshot = new MucOccupantSnapshot(occupant.to_string(),
                room.to_string(), "snapshot-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.MODERATOR, true, null, null,
                SNAPSHOT_HASH, true, GLib.get_monotonic_time());
            MucOccupantSnapshot[] role_changed = { role_snapshot };
            int[] role_flags = { (int) MucOccupantChange.ROLE };
            var role_delta = new MucRoomDelta(key, 2, true, true, true,
                false, false, 1, role_changed, null, role_flags);
            int jobs_before = AvatarCacheWorker.get_executed_load_jobs();

            manager.queue_muc_avatar_delta_hints(account, room, delta, true);
            manager.queue_muc_avatar_delta_hints(account, room, role_delta,
                false);
            fail_if(AvatarCacheWorker.get_executed_load_jobs() != jobs_before,
                "A full MUC snapshot must yield before starting avatar cache work");

            bool completed = false;
            var loop = new MainLoop();
            int checks = 0;
            Timeout.add(10, () => {
                completed = AvatarCacheWorker.get_executed_load_jobs() >
                    jobs_before;
                if (completed || ++checks >= 200) {
                    loop.quit();
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
            loop.run();

            fail_if(!completed,
                "A role-only live delta must not suppress the still-current snapshot avatar prefetch");
            stream_interactor.account_removed(account);
        } catch (Error error) {
            fail_if_reached(@"Unexpected MUC snapshot avatar error: $(error.message)");
        } finally {
            FileUtils.remove(cache_path);
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_muc_live_delta_prevents_stale_snapshot_avatar_rollback() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-snapshot-revision-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-snapshot-revision-audit");
            var account = new Entities.Account(
                new Jid("snapshot-revision@example.test"), "secret");
            account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-snapshot-revision-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);
            Jid room = new Jid("room@conference.example.test");
            Jid occupant = room.with_resource("revision-user");
            var key = new MucRoomKey(account.id,
                account.bare_jid.to_string(), room.to_string(), 1, 1);
            var old_snapshot = new MucOccupantSnapshot(occupant.to_string(),
                room.to_string(), "revision-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.PARTICIPANT, true, null, null,
                HASH_A, true, GLib.get_monotonic_time());
            var new_snapshot = new MucOccupantSnapshot(occupant.to_string(),
                room.to_string(), "revision-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.PARTICIPANT, true, null, null,
                HASH_B, true, GLib.get_monotonic_time());
            MucOccupantSnapshot[] old_changed = { old_snapshot };
            MucOccupantSnapshot[] new_changed = { new_snapshot };
            int[] flags = { (int) MucOccupantChange.AVATAR };
            var full_delta = new MucRoomDelta(key, 1, true, true, true,
                false, true, 1, old_changed, null, flags);
            var live_delta = new MucRoomDelta(key, 2, true, true, true,
                false, false, 1, new_changed, null, flags);
            int hash_transitions = 0;
            manager.received_avatar.connect((jid, ready_account) => {
                if (ready_account.id == account.id && jid.equals(occupant)) {
                    hash_transitions++;
                }
            });

            manager.queue_muc_avatar_delta_hints(account, room, full_delta,
                true);
            manager.queue_muc_avatar_delta_hints(account, room, live_delta,
                false);
            fail_if(hash_transitions != 1,
                "The live delta must establish exactly one newer MUC avatar hash transition");

            var loop = new MainLoop();
            Timeout.add(50, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();

            fail_if(hash_transitions != 1,
                "A sliced older full snapshot must not restore its stale avatar hash");

            var current_snapshot = new MucOccupantSnapshot(
                occupant.to_string(), room.to_string(), "revision-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.PARTICIPANT, true, null, null,
                HASH_B, true, GLib.get_monotonic_time());
            var removed_snapshot = new MucOccupantSnapshot(
                occupant.to_string(), room.to_string(), "revision-user", null,
                MucWorkerAffiliationState.NONE, true,
                MucWorkerRoleState.PARTICIPANT, true, null, null,
                "", true, GLib.get_monotonic_time());
            MucOccupantSnapshot[] current_changed = { current_snapshot };
            MucOccupantSnapshot[] removed_changed = { removed_snapshot };
            var current_full_delta = new MucRoomDelta(key, 3, true, true,
                true, false, true, 1, current_changed, null, flags);
            var removal_delta = new MucRoomDelta(key, 4, true, true, true,
                false, false, 1, removed_changed, null, flags);

            manager.queue_muc_avatar_delta_hints(account, room,
                current_full_delta, true);
            manager.handle_vcard_avatar_removed(account, occupant, true);
            fail_if(hash_transitions != 2,
                "An explicit XEP-0153 removal must clear the current MUC avatar once");

            // Reproduce the real ordering: the direct presence callback
            // removes the hash, then an already sliced older full snapshot
            // runs, and only afterwards the live worker delta is delivered.
            var removal_loop = new MainLoop();
            Timeout.add(50, () => {
                removal_loop.quit();
                return Source.REMOVE;
            });
            removal_loop.run();
            fail_if(hash_transitions != 3,
                "The audit setup must reproduce the older sliced snapshot restoring its hash");

            manager.queue_muc_avatar_delta_hints(account, room, removal_delta,
                false);
            fail_if(hash_transitions != 4,
                "The delayed empty-hash worker delta must remove a stale restored avatar");

            var settled_loop = new MainLoop();
            Timeout.add(50, () => {
                settled_loop.quit();
                return Source.REMOVE;
            });
            settled_loop.run();
            fail_if(hash_transitions != 4,
                "The explicit removal must remain stable after queued avatar work settles");
            stream_interactor.account_removed(account);
        } catch (Error error) {
            fail_if_reached(@"Unexpected MUC avatar revision error: $(error.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_participant_avatar_identity() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-identity-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-identity-audit");
            var account = new Entities.Account(new Jid("identity@example.test"), "secret");
            account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, new Security.FileEncryption("avatar-identity-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);

            Jid contact = new Jid("contact@example.test/device");
            var chat = new Entities.Conversation(contact.bare_jid, account, Entities.Conversation.Type.CHAT);
            Jid primary_jid;
            Jid? secondary_jid;
            string color_id;
            manager.resolve_participant_avatar_identity(chat, contact,
                out primary_jid, out secondary_jid, out color_id);
            fail_if(!primary_jid.equals(contact.bare_jid) || secondary_jid != null,
                "A direct chat must resolve one bare-JID avatar identity");
            fail_if_not_eq_str(color_id, contact.bare_jid.to_string(),
                "Direct-chat placeholder color identity must remain the bare JID");

            Jid room = new Jid("room@conference.example.test");
            Jid occupant = room.with_resource("Public Nick");
            var groupchat = new Entities.Conversation(room, account, Entities.Conversation.Type.GROUPCHAT);
            manager.resolve_participant_avatar_identity(groupchat, occupant,
                out primary_jid, out secondary_jid, out color_id);
            fail_if(!primary_jid.equals(occupant) || secondary_jid != null,
                "A public MUC participant must retain its full occupant JID");
            fail_if_not_eq_str(color_id, "Public Nick",
                "Public-MUC placeholder color identity must remain the occupant nick");
        } catch (Error error) {
            fail_if_reached(@"Unexpected participant avatar identity error: $(error.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_preload_account_scope() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-avatar-preload-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-preload-audit");
            var first_account = new Entities.Account(new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Entities.Account(new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            Jid contact = new Jid("contact@example.test");

            ((!) db).avatar.insert()
                .value(((!) db).avatar.jid_id, ((!) db).get_jid_id(contact))
                .value(((!) db).avatar.account_id, first_account.id)
                .value(((!) db).avatar.hash, HASH_A)
                .value(((!) db).avatar.type_, (int) AvatarSource.VCARD)
                .perform();
            ((!) db).avatar.insert()
                .value(((!) db).avatar.jid_id, ((!) db).get_jid_id(contact))
                .value(((!) db).avatar.account_id, second_account.id)
                .value(((!) db).avatar.hash, HASH_C)
                .value(((!) db).avatar.type_, (int) AvatarSource.VCARD)
                .perform();

            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db, new Security.FileEncryption("avatar-preload-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
            int transitions = 0;
            manager.received_avatar.connect((jid, account) => transitions++);

            manager.handle_vcard_avatar_received(first_account, contact, HASH_A, false);
            manager.handle_vcard_avatar_received(second_account, contact, HASH_C, false);
            fail_if(transitions != 0,
                "Repeating each preloaded account hash must not reveal cross-account in-memory overwrites");

            manager.handle_vcard_avatar_received(first_account, contact, HASH_B, false);
            fail_if(transitions != 1, "A real account-1 hash transition must still be emitted");
            HashMap<Jid, string> second_vcards = manager.get_avatar_hashes(second_account, (int) AvatarSource.VCARD);
            fail_if_not_eq_str(second_vcards[contact], HASH_C, "Updating account 1 must not overwrite account 2 in the DB");
        } catch (Error e) {
            fail_if_reached(@"Unexpected avatar preload account-scope error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_does_not_seed_own_vcard_presence() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-own-presence-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-own-presence-audit");
            var account = new Entities.Account(new Jid("self@example.test"),
                "secret");
            account.persist((!) db);
            ((!) db).avatar.insert()
                .value(((!) db).avatar.jid_id,
                    ((!) db).get_jid_id(account.bare_jid))
                .value(((!) db).avatar.account_id, account.id)
                .value(((!) db).avatar.hash, HASH_A)
                .value(((!) db).avatar.type_, (int) AvatarSource.VCARD)
                .perform();

            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-own-presence-audit"));
            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            Xmpp.Presence.Module presence = stream_interactor.module_manager
                .get_module<Xmpp.Presence.Module>(account,
                    Xmpp.Presence.Module.IDENTITY);
            Xmpp.Xep.VCard.Module vcard = stream_interactor.module_manager
                .get_module<Xmpp.Xep.VCard.Module>(account,
                    Xmpp.Xep.VCard.Module.IDENTITY);
            var stream = new AvatarAuditStream(new Jid("example.test"));
            stream.add_module(presence);
            presence.attach(stream);
            stream.add_module(vcard);
            vcard.attach(stream);

            var outgoing = new Xmpp.Presence.Stanza();
            presence.pre_send_presence_stanza(stream, outgoing);
            StanzaNode? update = outgoing.stanza.get_subnode("x",
                NS_VCARD_UPDATE);
            StanzaNode? photo = update != null
                ? ((!) update).get_subnode("photo", NS_VCARD_UPDATE) : null;
            fail_if(update == null || photo != null,
                "A persisted hash must not be announced before the fresh stream verifies the current vCard");

            vcard.detach(stream);
            presence.detach(stream);
        } catch (Error e) {
            fail_if_reached(@"Unexpected own-avatar presence seed error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_fences_superseded_own_avatar_operations() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-operation-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-operation-audit");
            var first_account = new Entities.Account(
                new Jid("first@example.test"), "secret");
            first_account.persist((!) db);
            var second_account = new Entities.Account(
                new Jid("second@example.test"), "secret");
            second_account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-operation-audit"));
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);
            var first_stream = new AvatarAuditStream(
                new Jid("example.test"));
            var second_stream = new AvatarAuditStream(
                new Jid("example.test"));
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                first_account, first_stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                second_account, second_stream);

            OwnAvatarOperation first = manager
                .begin_own_avatar_operation_for_tests(first_account,
                    first_stream);
            OwnAvatarOperation other_account = manager
                .begin_own_avatar_operation_for_tests(second_account,
                    second_stream);
            fail_if(!manager.own_avatar_operation_is_current_for_tests(
                    first_account, first),
                "A different account must not supersede the first account operation");

            OwnAvatarOperation replacement = manager
                .begin_own_avatar_operation_for_tests(first_account,
                    first_stream);
            fail_if(!first.cancellable.is_cancelled() || !first.superseded,
                "A newer operation must cancel and mark the older account operation as superseded");
            fail_if(!manager.own_avatar_resync_required_for_tests(
                    first_account),
                "Superseding an in-flight vCard operation must require server reverification");
            fail_if(manager.own_avatar_operation_is_current_for_tests(
                    first_account, first) ||
                    !manager.own_avatar_operation_is_current_for_tests(
                        first_account, replacement),
                "Only the newest operation for an account may apply local avatar state");
            fail_if(!manager.own_avatar_operation_is_current_for_tests(
                    second_account, other_account),
                "Superseding account one must not invalidate account two");

            manager.finish_own_avatar_operation_for_tests(first_account,
                replacement);
            manager.finish_own_avatar_operation_for_tests(second_account,
                other_account);
        } catch (Error e) {
            fail_if_reached(@"Unexpected own-avatar operation audit error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_reverifies_interrupted_own_avatar_after_recovery() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-resync-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-resync-audit");
            var account = new Entities.Account(
                new Jid("resync@example.test"), "secret");
            account.persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-resync-audit"));
            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);
            AvatarManager manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);

            var stream = new ParallelAvatarAuditStream(
                new Jid("example.test"));
            var iq = new Iq.Module();
            stream.add_module(iq);
            iq.attach(stream);
            stream.add_module(new Xep.Pubsub.Module());
            stream.release_pep();
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            stream.fail_next_vcard_get_with_timeout = true;
            stream_interactor.stream_negotiated(account, stream);
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count > 0 &&
                        manager.own_avatar_resync_required_for_tests(account);
                }, 1000),
                "A failed initial vCard readback must retain its same-session retry marker");
            int before_initial_resume = stream.vcard_get_count;
            stream_interactor.stream_resumed(account, stream);
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count > before_initial_resume &&
                        !manager.own_avatar_resync_required_for_tests(account);
                }, 1000),
                "XEP-0198 resume must retry and verify a failed initial vCard readback");

            OwnAvatarOperation interrupted = manager
                .begin_own_avatar_operation_for_tests(account, stream);
            stream_interactor.connection_manager
                .set_provisional_disconnected_for_tests(account);
            fail_if(!interrupted.cancellable.is_cancelled() ||
                    !manager.own_avatar_resync_required_for_tests(account),
                "Disconnect must invalidate an interrupted own-avatar operation");
            stream_interactor.module_manager.get_module<
                Xep.UserAvatars.Module>(account,
                    Xep.UserAvatars.Module.IDENTITY).received_avatar_hash(
                        stream, account.bare_jid, "not-a-sha1");
            fail_if(!manager.own_avatar_pep_resync_required_for_tests(account),
                "Malformed own PEP events must not terminate required server reverification");

            stream_interactor.connection_manager.set_connection_state_for_tests(
                account, ConnectionManager.ConnectionState.CONNECTED);
            fail_if(!run_avatar_audit_until(() => {
                    return !manager.own_avatar_resync_required_for_tests(
                            account) &&
                        !manager.own_avatar_pep_resync_required_for_tests(
                            account);
                }, 1000),
                "Same-stream recovery must fetch and verify the current server vCard");

            int before_supersede_resync = stream.vcard_get_count;
            manager.begin_own_avatar_operation_for_tests(account, stream);
            OwnAvatarOperation replacement = manager
                .begin_own_avatar_operation_for_tests(account, stream);
            manager.finish_own_avatar_mutation_for_tests(account,
                replacement, new OwnAvatarOperationResult());
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count > before_supersede_resync &&
                        !manager.own_avatar_resync_required_for_tests(account) &&
                        !manager.own_avatar_pep_resync_required_for_tests(
                            account);
                }, 1000),
                "A failed superseding mutation must reverify vCard on the live stream");

            int before_purge_resync = stream.vcard_get_count;
            OwnAvatarOperation purged = manager
                .begin_own_avatar_operation_for_tests(account, stream);
            manager.purge_in_memory_caches();
            fail_if(!purged.cancellable.is_cancelled(),
                "Cache purge must cancel the in-flight own-avatar operation");
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count > before_purge_resync &&
                        !manager.own_avatar_resync_required_for_tests(account) &&
                        !manager.own_avatar_pep_resync_required_for_tests(
                            account);
                }, 1000),
                "Cache purge must reverify an ambiguous vCard operation");

            int before_normal_vcard_resync = stream.vcard_get_count;
            int before_normal_pep_resync = stream.pep_metadata_get_count;
            manager.purge_in_memory_caches();
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count >
                            before_normal_vcard_resync &&
                        stream.pep_metadata_get_count >
                            before_normal_pep_resync &&
                        !manager.own_avatar_resync_required_for_tests(account) &&
                        !manager.own_avatar_pep_resync_required_for_tests(
                            account);
                }, 1000),
                "A normal cache purge must restore both own avatar server states");

            manager.begin_cache_clear();
            manager.begin_cache_clear();
            fail_if(!manager.avatar_cache_writes_paused_for_tests(),
                "Overlapping cache clears must pause avatar stores");
            manager.finish_cache_clear();
            fail_if(!manager.avatar_cache_writes_paused_for_tests(),
                "The first overlapping cache-clear completion must keep stores paused");
            manager.finish_cache_clear();
            fail_if(manager.avatar_cache_writes_paused_for_tests(),
                "Only the final cache-clear completion may resume avatar stores");
            fail_if(!run_avatar_audit_until(() => {
                    return !manager.own_avatar_resync_required_for_tests(
                            account) &&
                        !manager.own_avatar_pep_resync_required_for_tests(
                            account);
                }, 1000),
                "Overlapping cache-clear completion must leave own state verified");
        } catch (Error e) {
            fail_if_reached(@"Unexpected own-avatar resync audit error: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private void test_manager_classifies_partial_own_avatar_results() {
        var pep_only = new OwnAvatarOperationResult() {
            pep_succeeded = true,
            vcard_succeeded = false
        };
        var vcard_only = new OwnAvatarOperationResult() {
            pep_succeeded = false,
            vcard_succeeded = true
        };
        var complete = new OwnAvatarOperationResult() {
            pep_succeeded = true,
            vcard_succeeded = true
        };
        var ambiguous = new OwnAvatarOperationResult() {
            vcard_ambiguous = true
        };
        fail_if(!pep_only.partially_succeeded() ||
                !vcard_only.partially_succeeded(),
            "Either one-path success must be classified as partial");
        fail_if(complete.partially_succeeded() ||
                !complete.fully_succeeded(),
            "Two successful server paths must be classified as complete");
        fail_if(ambiguous.any_succeeded() ||
                !ambiguous.vcard_ambiguous,
            "An ambiguous vCard write must not be classified as success");
    }

    private void test_manager_starts_vcard_without_waiting_for_pep() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-avatar-parallel-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        Entities.Account? account = null;
        AvatarManager? manager = null;
        OwnAvatarOperation? operation = null;

        try {
            cleanup_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Database(db_path, "avatar-parallel-audit");
            account = new Entities.Account(
                new Jid("parallel@example.test"), "secret");
            ((!) account).persist((!) db);
            var stream_interactor = new StreamInteractor.for_tests((!) db);
            AvatarManager.start(stream_interactor, (!) db,
                new Security.FileEncryption("avatar-parallel-audit"));
            stream_interactor.module_manager.initialize((!) account);
            stream_interactor.account_added((!) account);
            manager = (!) stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);

            var stream = new ParallelAvatarAuditStream(
                new Jid("example.test"));
            var iq = new Iq.Module();
            stream.add_module(iq);
            iq.attach(stream);
            stream.add_module(new Xep.Pubsub.Module());
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                (!) account, stream);
            operation = ((!) manager).begin_own_avatar_operation_for_tests(
                (!) account, stream);

            uint8[] image = { 1, 2, 3, 4 };
            Bytes image_bytes = new Bytes(image);
            string image_hash = Checksum.compute_for_data(ChecksumType.SHA1,
                image);
            bool completed = false;
            OwnAvatarOperationResult? result = null;
            ((!) manager).publish_own_avatar_paths_for_tests.begin((!) account,
                (!) operation, image, 2, 2, image_bytes, image_hash, (_, res) => {
                    result = ((!) manager)
                        .publish_own_avatar_paths_for_tests.end(res);
                    completed = true;
                });

            bool vcard_finished_before_pep = run_avatar_audit_until(() => {
                return stream.vcard_set_seen;
            }, 1000);
            fail_if(!vcard_finished_before_pep || stream.pep_released,
                "The complete vCard path must run while the first PEP IQ is still unanswered");
            fail_if(completed,
                "The combined result must still wait for the bounded PEP path");

            stream.release_pep();
            fail_if(!run_avatar_audit_until(() => completed, 1000),
                "The combined avatar publish must finish after releasing PEP");
            fail_if(result == null || !((!) result).fully_succeeded(),
                "Both independently completed server paths must report full success");

            ((!) manager).finish_own_avatar_operation_for_tests((!) account,
                (!) operation);
            operation = null;
            stream.fail_vcard_set_with_timeout = true;
            int before_timeout_resync = stream.vcard_get_count;
            operation = ((!) manager).begin_own_avatar_operation_for_tests(
                (!) account, stream);
            completed = false;
            result = null;
            GLib.Test.expect_message("libdino",
                GLib.LogLevelFlags.LEVEL_WARNING,
                "*synthetic vCard SET timeout*");
            ((!) manager).publish_own_avatar_paths_for_tests.begin((!) account,
                (!) operation, image, 2, 2, image_bytes, image_hash, (_, res) => {
                    result = ((!) manager)
                        .publish_own_avatar_paths_for_tests.end(res);
                    completed = true;
                });
            fail_if(!run_avatar_audit_until(() => completed, 1000) ||
                    result == null || !((!) result).pep_succeeded ||
                    ((!) result).vcard_succeeded ||
                    !((!) result).vcard_ambiguous,
                "A vCard SET timeout must remain distinct from a definite server rejection");
            GLib.Test.assert_expected_messages();

            ((!) manager).finish_own_avatar_mutation_for_tests((!) account,
                (!) operation, (!) result);
            operation = null;
            fail_if(!run_avatar_audit_until(() => {
                    return stream.vcard_get_count > before_timeout_resync &&
                        !((!) manager).own_avatar_resync_required_for_tests(
                            (!) account);
                }, 1000),
                "An ambiguous vCard SET must trigger one live-stream reverification");

            stream.fail_vcard_set_with_timeout = false;
            stream.fail_pep_metadata_set_with_timeout = true;
            int before_pep_resync = stream.pep_metadata_get_count;
            operation = ((!) manager).begin_own_avatar_operation_for_tests(
                (!) account, stream);
            completed = false;
            result = null;
            GLib.Test.expect_message("xmpp-vala",
                GLib.LogLevelFlags.LEVEL_WARNING,
                "*synthetic PEP metadata timeout*");
            ((!) manager).publish_own_avatar_paths_for_tests.begin((!) account,
                (!) operation, image, 2, 2, image_bytes, image_hash, (_, res) => {
                    result = ((!) manager)
                        .publish_own_avatar_paths_for_tests.end(res);
                    completed = true;
                });
            fail_if(!run_avatar_audit_until(() => completed, 1000) ||
                    result == null || !((!) result).vcard_succeeded ||
                    ((!) result).pep_succeeded ||
                    !((!) result).pep_ambiguous,
                "A PEP metadata timeout must remain distinct from a definite rejection");
            GLib.Test.assert_expected_messages();

            ((!) manager).finish_own_avatar_mutation_for_tests((!) account,
                (!) operation, (!) result);
            operation = null;
            fail_if(!run_avatar_audit_until(() => {
                    return stream.pep_metadata_get_count > before_pep_resync &&
                        !((!) manager)
                            .own_avatar_pep_resync_required_for_tests(
                                (!) account);
                }, 1000),
                "An ambiguous PEP metadata write must query the live server state");
            HashMap<Jid, string> pep_hashes = ((!) manager)
                .get_avatar_hashes((!) account, AvatarSource.USER_AVATARS);
            fail_if(!pep_hashes.has_key(((!) account).bare_jid) ||
                    pep_hashes[((!) account).bare_jid] != image_hash,
                "PEP reverification must apply the server-confirmed avatar hash");
        } catch (Error e) {
            fail_if_reached(@"Unexpected parallel avatar publication error: $(e.message)");
        } finally {
            if (operation != null && manager != null && account != null) {
                ((!) manager).finish_own_avatar_operation_for_tests(
                    (!) account, (!) operation);
            }
            cleanup_test_dir(temp_dir, db_path);
        }
    }

    private delegate bool AvatarAuditCondition();

    private bool run_avatar_audit_until(AvatarAuditCondition condition,
            uint timeout_ms) {
        if (condition()) return true;
        var loop = new MainLoop();
        bool matched = false;
        uint poll_source = 0;
        uint timeout_source = 0;
        poll_source = Timeout.add(1, () => {
            if (!condition()) return Source.CONTINUE;
            matched = true;
            poll_source = 0;
            loop.quit();
            return Source.REMOVE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return matched || condition();
    }

    private void cleanup_test_dir(string temp_dir, string db_path) {
        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-shm");
        FileUtils.remove(db_path + "-wal");
        DirUtils.remove(temp_dir);
    }

    private static void drain_avatar_audit_context() {
        MainContext context = MainContext.@default();
        while (context.pending()) context.iteration(false);
    }

    private static bool avatar_cache_staging_exists(string cache_path) {
        string directory = Path.get_dirname(cache_path);
        string prefix = Path.get_basename(cache_path) + ".pending-";
        try {
            Dir dir = Dir.open(directory);
            string? name;
            while ((name = dir.read_name()) != null) {
                if (((!) name).has_prefix(prefix)) return true;
            }
        } catch (FileError error) {
            return false;
        }
        return false;
    }

    private class ParallelAvatarAuditStream : XmppStream {
        public bool vcard_set_seen { get; private set; default = false; }
        public bool pep_released { get; private set; default = false; }
        public bool fail_vcard_set_with_timeout { get; set;
            default = false; }
        public bool fail_pep_metadata_set_with_timeout { get; set;
            default = false; }
        public bool fail_next_vcard_get_with_timeout { get; set;
            default = false; }
        public int vcard_get_count { get; private set; default = 0; }
        public int pep_metadata_get_count { get; private set; default = 0; }
        private string? current_pep_hash = null;

        private ArrayList<StanzaNode> held_pep_requests =
            new ArrayList<StanzaNode>();

        public ParallelAvatarAuditStream(Jid remote_name) {
            base(remote_name);
        }

        public void release_pep() {
            pep_released = true;
            foreach (StanzaNode request in held_pep_requests) {
                schedule_success(request);
            }
            held_pep_requests.clear();
        }

        public override async void connect() throws IOError {
        }

        public override async void disconnect() throws IOError {
        }

        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED(
                "parallel avatar test stream has no reader");
        }

        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            StanzaNode? pubsub = node.get_subnode("pubsub", NS_PUBSUB);
            if (pubsub != null) {
                StanzaNode? publish = ((!) pubsub).get_subnode("publish",
                    NS_PUBSUB);
                StanzaNode? items = ((!) pubsub).get_subnode("items",
                    NS_PUBSUB);
                if (items != null && node.get_attribute("type") == "get" &&
                        ((!) items).get_attribute("node") ==
                            NS_AVATAR_METADATA) {
                    pep_metadata_get_count++;
                    schedule_pep_metadata_success(node);
                    return;
                }
                if (publish != null &&
                        ((!) publish).get_attribute("node") ==
                            NS_AVATAR_METADATA) {
                    StanzaNode? item = ((!) publish).get_subnode("item",
                        NS_PUBSUB);
                    current_pep_hash = item != null
                        ? ((!) item).get_attribute("id") : null;
                    if (fail_pep_metadata_set_with_timeout) {
                        throw new IOError.TIMED_OUT(
                            "synthetic PEP metadata timeout");
                    }
                }
                if (!pep_released) {
                    held_pep_requests.add(node);
                } else {
                    schedule_success(node);
                }
                return;
            }

            if (node.get_subnode("vCard", NS_VCARD) != null) {
                if (node.get_attribute("type") == "set") {
                    vcard_set_seen = true;
                    if (fail_vcard_set_with_timeout) {
                        throw new IOError.TIMED_OUT(
                            "synthetic vCard SET timeout");
                    }
                } else if (node.get_attribute("type") == "get") {
                    vcard_get_count++;
                    if (fail_next_vcard_get_with_timeout) {
                        fail_next_vcard_get_with_timeout = false;
                        throw new IOError.TIMED_OUT(
                            "synthetic initial vCard GET timeout");
                    }
                }
                schedule_success(node);
            }
        }

        public override async void setup() throws IOError {
        }

        private void schedule_success(StanzaNode request) {
            string? id = request.get_attribute("id");
            bool empty_vcard = request.get_attribute("type") == "get" &&
                request.get_subnode("vCard", NS_VCARD) != null;
            Idle.add(() => {
                var response = new StanzaNode.build("iq")
                    .put_attribute("type", "result");
                if (id != null) response.put_attribute("id", (!) id);
                // XEP-0054 represents an absent vCard with an explicit empty
                // vCard payload. A bare result is only valid for the SET ACK.
                if (empty_vcard) response.put_node(new StanzaNode.build(
                    "vCard", NS_VCARD).add_self_xmlns());
                received_iq_stanza(this, response);
                return Source.REMOVE;
            });
        }

        private void schedule_pep_metadata_success(StanzaNode request) {
            string? id = request.get_attribute("id");
            string? hash = current_pep_hash;
            Idle.add(() => {
                var response = new StanzaNode.build("iq")
                    .put_attribute("type", "result");
                if (id != null) response.put_attribute("id", (!) id);
                var pubsub = new StanzaNode.build("pubsub", NS_PUBSUB)
                    .add_self_xmlns();
                var items = new StanzaNode.build("items", NS_PUBSUB)
                    .put_attribute("node", NS_AVATAR_METADATA);
                var item = new StanzaNode.build("item", NS_PUBSUB);
                var metadata = new StanzaNode.build("metadata",
                    NS_AVATAR_METADATA).add_self_xmlns();
                if (hash != null) {
                    item.put_attribute("id", (!) hash);
                    metadata.put_node(new StanzaNode.build("info",
                        NS_AVATAR_METADATA)
                        .put_attribute("id", (!) hash)
                        .put_attribute("type", "image/png"));
                }
                item.put_node(metadata);
                items.put_node(item);
                pubsub.put_node(items);
                response.put_node(pubsub);
                received_iq_stanza(this, response);
                return Source.REMOVE;
            });
        }
    }

    private class AvatarAuditStream : XmppStream {
        public AvatarAuditStream(Jid remote_name) {
            base(remote_name);
        }

        public override async void connect() throws IOError {
        }

        public override async void disconnect() throws IOError {
        }

        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("test stream has no reader");
        }

        public override async void write_async(StanzaNode node,
                int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
        }

        public override async void setup() throws IOError {
        }
    }
}

}
