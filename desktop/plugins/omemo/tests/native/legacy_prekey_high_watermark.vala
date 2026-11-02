using Dino.Plugins.Omemo;
using Omemo;
using Qlite;

namespace Omemo.Test {

// These tests use isolated persistent stores. Reservations themselves must
// survive failed key creation and deletion; surviving key rows are not the
// authority for which one-time key IDs have already been issued.
class LegacyPreKeyHighWatermarkTest : Gee.TestCase {
    private string? temp_dir;
    private string? db_path;
    private Dino.Plugins.Omemo.Database? db;
    private ECKeyPair? identity_key;

    public LegacyPreKeyHighWatermarkTest() {
        base("LegacyPreKeyHighWatermark");
        add_test("deleted_highest_and_empty_store_do_not_reuse_ids_after_restart", test_deleted_keys_restart);
        add_test("failed_key_insert_keeps_reserved_id_gap_after_restart", test_failed_insert);
        add_test("failed_high_watermark_write_allocates_no_key_records", test_failed_watermark_write);
        add_test("accounts_with_identical_key_ids_reserve_independently", test_account_scope);
        add_test("v9_upgrade_preserves_identity_sessions_and_keys_and_seeds_watermark", test_migration);
        add_test("reserved_range_skips_last_resort_key_id", test_last_resort);
        add_test("maximum_id_exhaustion_never_wraps_or_allocates_records", test_exhaustion);
        add_test("zero_count_reservation_is_rejected_without_allocation", test_zero_count);
    }

    public override void set_up() {
        try {
            temp_dir = DirUtils.make_tmp("dinox-prekey-high-watermark-XXXXXX");
            db_path = Path.build_filename((!) temp_dir, "omemo.db");
            db = new Dino.Plugins.Omemo.Database((!) db_path);
            identity_key = Plugin.get_context().generate_key_pair();
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    public override void tear_down() {
        if (db != null) ((!) db).close();
        db = null;
        identity_key = null;
        if (db_path != null) {
            FileUtils.remove((!) db_path);
            FileUtils.remove((!) db_path + "-wal");
            FileUtils.remove((!) db_path + "-shm");
        }
        if (temp_dir != null) DirUtils.remove((!) temp_dir);
    }

    private int create_identity(int account_id = 1, int device_id = 1001,
            bool pending = false) throws Error {
        var database = (!) db;
        var key = (!) identity_key;
        return (int) database.identity.upsert()
                .value(database.identity.account_id, account_id, true)
                .value(database.identity.device_id, device_id)
                .value(database.identity.identity_key_private_base64,
                        Base64.encode(key.private.serialize()))
                .value(database.identity.identity_key_public_base64,
                        Base64.encode(key.public.serialize()))
                .value(database.identity.registration_pending, pending)
                .perform_checked();
    }

    private void reopen() throws Error {
        ((!) db).close();
        db = new Dino.Plugins.Omemo.Database((!) db_path);
    }

    private int watermark(int identity_id) throws Error {
        var database = (!) db;
        Row? row = database.identity.select()
                .with(database.identity.id, "=", identity_id)
                .single().iterator().get_next_checked();
        if (row == null) throw new IOError.FAILED("Test identity is missing");
        return ((!) row)[database.identity.pre_key_high_watermark];
    }

    private int key_count(int identity_id) throws Error {
        Row? row = ((!) db).query_sql("SELECT COUNT(*) AS records FROM pre_key WHERE identity_id = %d"
                .printf(identity_id)).get_next_checked();
        if (row == null) throw new IOError.FAILED("Test key count is unavailable");
        return (int) ((!) row).get_integer("records");
    }

    private uint8[] key_record(uint32 key_id) throws Error {
        PreKeyRecord record;
        throw_by_code(PreKeyRecord.create(out record, key_id,
                Plugin.get_context().generate_key_pair()));
        // Store's native helper uses the correct C serializer; the legacy
        // PreKeyRecord VAPI method itself contains an unrelated name typo.
        Store temporary_store = setup_test_store_context(Plugin.get_context());
        temporary_store.store_pre_key(record);
        uint8[]? stored = temporary_store.pre_key_store.load_pre_key(key_id);
        if (stored == null) throw new IOError.FAILED("Test prekey serialization failed");
        uint8[] serialized = (!) stored;
        uint8[] copy = new uint8[serialized.length];
        Memory.copy(copy, serialized, serialized.length);
        return copy;
    }

    private void insert_old_key(int identity_id, uint32 key_id,
            uint8[] record) throws Error {
        var database = (!) db;
        database.pre_key.upsert()
                .value(database.pre_key.identity_id, identity_id, true)
                .value(database.pre_key.pre_key_id, (int) key_id, true)
                .value(database.pre_key.record_base64, Base64.encode(record))
                .perform_checked();
    }

    private void test_deleted_keys_restart() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            store.store_pre_key(3, key_record(3));
            store.store_pre_key(41, key_record(41));
            store.delete_pre_key(41);
            fail_if_not_eq_int(watermark(id), 41, "deletion must preserve the highest issued ID");
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            fail_if_not(store.contains_pre_key(3));
            fail_if(store.contains_pre_key(41));
            fail_if_not_eq_int((int) store.reserve_key_ids(2, 0), 42,
                    "restart must reserve above the deleted highest ID");
            fail_if_not_eq_int(watermark(id), 43, "the whole range must be durable before key creation");
            store.delete_pre_key(3);
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            fail_if_not_eq_int(key_count(id), 0);
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), 44,
                    "an empty reopened store must not reuse any previously reserved ID");
            fail_if_not_eq_int(key_count(id), 0, "reserving IDs must not create key records");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_failed_insert() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            uint32 first = store.reserve_key_ids(3, 0);
            store.store_pre_key(first, key_record(first));
            ((!) db).exec("CREATE TRIGGER reject_pre_key_insert BEFORE INSERT ON pre_key " +
                    "BEGIN SELECT RAISE(ABORT, 'injected prekey insert failure'); END");
            bool rejected = false;
            try { store.store_pre_key(first + 1, key_record(first + 1)); }
            catch (Error e) { rejected = true; }
            fail_if_not(rejected, "a rejected SQL insert must propagate an error");
            fail_if(store.contains_pre_key(first + 1), "failed SQL insert must not expose a memory-only key");
            fail_if_not_eq_int(key_count(id), 1);
            fail_if_not_eq_int(watermark(id), 3, "failed key creation must keep the allocated gap reserved");
            ((!) db).exec("DROP TRIGGER reject_pre_key_insert");
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), 4,
                    "reserved but uncreated IDs must remain unavailable after restart");
            fail_if_not_eq_int(key_count(id), 1);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_failed_watermark_write() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            ((!) db).exec("CREATE TRIGGER reject_pre_key_watermark BEFORE UPDATE OF pre_key_high_watermark ON identity " +
                    "BEGIN SELECT RAISE(ABORT, 'injected prekey watermark failure'); END");
            bool reservation_rejected = false;
            try { store.reserve_key_ids(3, 0); }
            catch (Error e) { reservation_rejected = true; }
            fail_if_not(reservation_rejected, "failed range persistence must not return an allocation");
            bool insert_rejected = false;
            try { store.store_pre_key(77, key_record(77)); }
            catch (Error e) { insert_rejected = true; }
            fail_if_not(insert_rejected, "observing an ID must succeed before storing its record");
            fail_if(store.contains_pre_key(77));
            fail_if_not_eq_int(key_count(id), 0, "failed watermark writes must allocate no key records");
            fail_if_not_eq_int(watermark(id), 0);
            ((!) db).exec("DROP TRIGGER reject_pre_key_watermark");
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            fail_if_not_eq_int((int) store.reserve_key_ids(3, 0), 1,
                    "a failed reservation must not corrupt a later valid range");
            fail_if_not_eq_int(watermark(id), 3);
            fail_if_not_eq_int(key_count(id), 0);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_account_scope() {
        try {
            int first_id = create_identity(1, 1001);
            int second_id = create_identity(2, 2002);
            var first_store = new BackedPreKeyStore((!) db, first_id);
            var second_store = new BackedPreKeyStore((!) db, second_id);
            first_store.store_pre_key(7, key_record(7));
            uint8[] second_record = key_record(7);
            second_store.store_pre_key(7, second_record);
            first_store.delete_pre_key(7);
            fail_if_not_eq_int((int) first_store.reserve_key_ids(3, 0), 8);
            fail_if_not_eq_int(watermark(first_id), 10);
            fail_if_not_eq_int(watermark(second_id), 7,
                    "one account must not move the other's high-water mark");
            fail_if_not(second_store.contains_pre_key(7));
            fail_if_not(Base64.encode((!) second_store.load_pre_key(7)) == Base64.encode(second_record),
                    "another account's overlapping key must retain its record");
            reopen();
            first_store = new BackedPreKeyStore((!) db, first_id);
            second_store = new BackedPreKeyStore((!) db, second_id);
            fail_if_not_eq_int((int) second_store.reserve_key_ids(1, 0), 8);
            fail_if_not_eq_int((int) first_store.reserve_key_ids(1, 0), 11);
            fail_if_not_eq_int(key_count(first_id), 0);
            fail_if_not_eq_int(key_count(second_id), 1);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_migration() {
        try {
            int id = create_identity(1, 1001, false);
            int second_id = create_identity(2, 2002, true);
            uint8[] record = key_record(73);
            insert_old_key(id, 73, record);
            insert_old_key(second_id, (uint32) int.MAX, key_record((uint32) int.MAX));
            var database = (!) db;
            database.session.upsert()
                    .value(database.session.identity_id, id, true)
                    .value(database.session.address_name, "peer@example.test", true)
                    .value(database.session.device_id, 42, true)
                    .value(database.session.record_base64, "migration-session-sentinel")
                    .perform_checked();
            database.signed_pre_key.upsert()
                    .value(database.signed_pre_key.identity_id, id, true)
                    .value(database.signed_pre_key.signed_pre_key_id, 5, true)
                    .value(database.signed_pre_key.record_base64, "migration-signed-key-sentinel")
                    .perform_checked();
            // Recreate v9's exact identity columns. All key/session tables
            // remain intact and production Qlite performs the v9 -> v10 step.
            database.exec("ALTER TABLE identity RENAME TO identity_v10");
            database.exec("CREATE TABLE identity (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "account_id INTEGER NOT NULL UNIQUE, device_id INTEGER NOT NULL, " +
                    "identity_key_private_base64 TEXT NOT NULL, identity_key_public_base64 TEXT NOT NULL, " +
                    "registration_pending INTEGER NOT NULL DEFAULT 0)");
            database.exec("INSERT INTO identity SELECT id, account_id, device_id, " +
                    "identity_key_private_base64, identity_key_public_base64, registration_pending FROM identity_v10");
            database.exec("DROP TABLE identity_v10");
            TrustLifecycleTest.restore_pre_v11_content_meta(database);
            database.exec("UPDATE _meta SET int_val = 9 WHERE name = 'version'");
            reopen();
            database = (!) db;
            var store = new BackedPreKeyStore(database, id);
            var second_store = new BackedPreKeyStore(database, second_id);
            fail_if_not(store.is_ready && second_store.is_ready, "migration must leave both persistent key stores ready");
            fail_if_not_eq_int(watermark(id), 73, "existing keys must seed the upgraded watermark");
            fail_if_not_eq_int(watermark(second_id), int.MAX,
                    "initial seeding must include the maximum permitted stored ID");
            fail_if_not(Base64.encode((!) store.load_pre_key(73)) == Base64.encode(record),
                    "migration must preserve existing key bytes");
            Row? identity = database.identity.select().with(database.identity.id, "=", id)
                    .single().iterator().get_next_checked();
            if (fail_if(identity == null)) return;
            fail_if_not_eq_int(((!) identity)[database.identity.device_id], 1001);
            fail_if(((!) identity)[database.identity.registration_pending]);
            fail_if_not(((!) identity)[database.identity.identity_key_public_base64] ==
                    Base64.encode(((!) identity_key).public.serialize()), "migration must preserve the public identity");
            fail_if_not(((!) identity)[database.identity.identity_key_private_base64] ==
                    Base64.encode(((!) identity_key).private.serialize()), "migration must preserve the private identity");
            Row? second_identity = database.identity.select().with(database.identity.id, "=", second_id)
                    .single().iterator().get_next_checked();
            if (fail_if(second_identity == null)) return;
            fail_if_not(((!) second_identity)[database.identity.registration_pending],
                    "migration must preserve an interrupted registration");
            Row? session = database.session.select().with(database.session.identity_id, "=", id)
                    .single().iterator().get_next_checked();
            if (fail_if(session == null)) return;
            fail_if_not_eq_str(((!) session)[database.session.record_base64], "migration-session-sentinel");
            Row? signed_key = database.signed_pre_key.select().with(database.signed_pre_key.identity_id, "=", id)
                    .single().iterator().get_next_checked();
            if (fail_if(signed_key == null)) return;
            fail_if_not_eq_str(((!) signed_key)[database.signed_pre_key.record_base64], "migration-signed-key-sentinel");
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), 74);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_last_resort() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            store.observe_high_watermark(0xFFFFFD);
            uint32 first = store.reserve_key_ids(3, 0);
            fail_if_not_eq_int((int) first, 0x1000000,
                    "a crossing range must start above the reusable last-resort sentinel");
            fail_if_not_eq_int(watermark(id), 0x1000002);
            fail_if(first <= 0xFFFFFF && first + 2 >= 0xFFFFFF);
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), 0x1000003);
            fail_if_not_eq_int(key_count(id), 0);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_exhaustion() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            store.observe_high_watermark((uint32) int.MAX - 1);
            bool oversized_rejected = false;
            try { store.reserve_key_ids(2, 0); }
            catch (Error e) { oversized_rejected = true; }
            fail_if_not(oversized_rejected, "a range extending beyond int.MAX must fail");
            fail_if_not_eq_int(watermark(id), int.MAX - 1);
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), int.MAX,
                    "the final permitted ID must remain usable");
            reopen();
            store = new BackedPreKeyStore((!) db, id);
            bool exhausted = false;
            try { store.reserve_key_ids(1, 0); }
            catch (Error e) { exhausted = true; }
            fail_if_not(exhausted, "exhaustion must not wrap to zero or restart at one");
            bool invalid_observation = false;
            try { store.observe_high_watermark((uint32) int.MAX + 1); }
            catch (Error e) { invalid_observation = true; }
            fail_if_not(invalid_observation);
            fail_if_not_eq_int(watermark(id), int.MAX);
            fail_if_not_eq_int(key_count(id), 0);
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_zero_count() {
        try {
            int id = create_identity();
            var store = new BackedPreKeyStore((!) db, id);
            store.observe_high_watermark(41);
            bool rejected = false;
            try { store.reserve_key_ids(0, 0); }
            catch (Error e) { rejected = true; }
            fail_if_not(rejected, "an empty reservation must not return an issued ID");
            fail_if_not_eq_int(watermark(id), 41);
            fail_if_not_eq_int(key_count(id), 0);
            fail_if_not_eq_int((int) store.reserve_key_ids(1, 0), 42,
                    "an empty request must not consume the next usable ID");
        } catch (Error e) { fail_if_reached(e.message); }
    }
}

}
