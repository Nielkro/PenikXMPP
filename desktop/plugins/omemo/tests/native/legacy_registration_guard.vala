using Dino.Plugins.Omemo;
using Qlite;

namespace Omemo.Test {

class LegacyRegistrationGuardTest : Gee.TestCase {
    private string? temp_dir;
    private string? db_path;
    private Dino.Plugins.Omemo.Database? db;
    private ECKeyPair? local_key;

    public LegacyRegistrationGuardTest() {
        base("LegacyRegistrationGuard");
        add_test("new_collision_changes_id_before_publication_and_survives_restart", test_collision_restart);
        add_test("failed_publication_keeps_pending_until_matching_ack", test_pending_ack);
        add_test("matching_identity_keeps_interrupted_registration_id", test_matching_identity);
        add_test("established_identity_is_never_rotated", test_established);
        add_test("existing_session_prevents_provisional_id_rotation", test_session_guard);
        add_test("failed_device_id_write_preserves_original_identity", test_failed_write);
        add_test("v8_migration_preserves_existing_identity_and_keys", test_migration);
        add_test("provisional_identity_allows_bundle_keys_but_blocks_ratchets", test_native_registration_gate);
    }

    public override void set_up() {
        try {
            temp_dir = DirUtils.make_tmp("dinox-registration-test-XXXXXX");
            db_path = Path.build_filename((!) temp_dir, "omemo.db");
            db = new Dino.Plugins.Omemo.Database((!) db_path);
            local_key = Plugin.get_context().generate_key_pair();
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    public override void tear_down() {
        if (db != null) ((!) db).close();
        db = null;
        local_key = null;
        if (db_path != null) {
            FileUtils.remove((!) db_path);
            FileUtils.remove((!) db_path + "-wal");
            FileUtils.remove((!) db_path + "-shm");
        }
        if (temp_dir != null) DirUtils.remove((!) temp_dir);
    }

    private int create_identity(bool pending = true, int account_id = 1, int device_id = 1001) throws Error {
        var database = (!) db;
        var key = (!) local_key;
        return (int) database.identity.upsert()
                .value(database.identity.account_id, account_id, true)
                .value(database.identity.device_id, device_id)
                .value(database.identity.identity_key_private_base64, Base64.encode(key.private.serialize()))
                .value(database.identity.identity_key_public_base64, Base64.encode(key.public.serialize()))
                .value(database.identity.registration_pending, pending)
                .perform_checked();
    }

    private Gee.ArrayList<int32> advertised() {
        var ids = new Gee.ArrayList<int32>();
        ids.add(1001);
        ids.add(2002);
        return ids;
    }

    private void reopen() throws Error {
        ((!) db).close();
        db = new Dino.Plugins.Omemo.Database((!) db_path);
    }

    private void test_collision_restart() {
        try {
            create_identity();
            create_identity(false, 2, 2002);
            var guard = new LegacyRegistrationGuard((!) db, 1);
            int32 candidate = guard.resolve_candidate_checked(advertised(), false);
            fail_if(candidate <= 0 || advertised().contains(candidate), "replacement must be a free positive ID");
            fail_if_not(guard.read_pending_checked(), "choosing an ID is not a publication acknowledgement");
            fail_if_not(guard.matches_identity_key_checked(((!) local_key).public), "collision handling must preserve identity key");
            reopen();
            guard = new LegacyRegistrationGuard((!) db, 1);
            fail_if_not_eq_int(guard.read_device_id_checked(), candidate, "replacement must survive restart before publication");
            fail_if_not(guard.read_pending_checked(), "restart must not erase pending publication");
            fail_if_not_eq_int(new LegacyRegistrationGuard((!) db, 2).read_device_id_checked(), 2002,
                    "another account's identity must remain untouched");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_pending_ack() {
        try {
            create_identity();
            var guard = new LegacyRegistrationGuard((!) db, 1);
            var empty = new Gee.ArrayList<int32>();
            fail_if_not_eq_int(guard.resolve_candidate_checked(empty, false), 1001,
                    "an unused candidate must be retained");
            reopen(); // No acknowledgement: e.g. server error or process interruption.
            guard = new LegacyRegistrationGuard((!) db, 1);
            fail_if_not(guard.read_pending_checked(), "unsuccessful publication must remain pending");
            bool rejected = false;
            try { guard.mark_published_checked(2002); } catch (Error e) { rejected = true; }
            fail_if_not(rejected, "acknowledgement for a different device must be rejected");
            fail_if_not(guard.read_pending_checked(), "wrong acknowledgement must preserve pending state");
            guard.mark_published_checked(1001);
            reopen();
            guard = new LegacyRegistrationGuard((!) db, 1);
            fail_if(guard.read_pending_checked(), "successful publication must survive restart");
            fail_if_not_eq_int(guard.resolve_candidate_checked(advertised(), false), 1001,
                    "a deployed ID must not rotate after publication");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_matching_identity() {
        try {
            create_identity();
            var guard = new LegacyRegistrationGuard((!) db, 1);
            var other_key = Plugin.get_context().generate_key_pair();
            fail_if(guard.matches_identity_key_checked(other_key.public), "another device's key must not match");
            fail_if(guard.matches_identity_key_checked(null), "missing key is not proof of our previous publication");
            bool matches = guard.matches_identity_key_checked(((!) local_key).public);
            fail_if_not(matches, "published local identity key must be recognized");
            fail_if_not_eq_int(guard.resolve_candidate_checked(advertised(), matches), 1001,
                    "interrupted publication of the same identity must keep the ID");
            fail_if_not(guard.read_pending_checked(), "matching a bundle alone is not full publication acknowledgement");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_established() {
        try {
            create_identity(false);
            var guard = new LegacyRegistrationGuard((!) db, 1);
            fail_if_not_eq_int(guard.resolve_candidate_checked(advertised(), false), 1001,
                    "existing deployed devices are outside first-publication replacement");
            fail_if_not(guard.matches_identity_key_checked(((!) local_key).public), "existing key must not change");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_session_guard() {
        try {
            int identity_id = create_identity();
            var database = (!) db;
            database.session.upsert()
                    .value(database.session.identity_id, identity_id, true)
                    .value(database.session.address_name, "peer@example.test", true)
                    .value(database.session.device_id, 42, true)
                    .value(database.session.record_base64, "persisted-session-sentinel")
                    .perform_checked();
            var guard = new LegacyRegistrationGuard(database, 1);
            bool rejected = false;
            try { guard.resolve_candidate_checked(advertised(), false); } catch (Error e) { rejected = true; }
            fail_if_not(rejected, "an identity with existing sessions must not rotate silently");
            fail_if_not_eq_int(guard.read_device_id_checked(), 1001, "session guard must leave the ID intact");
            fail_if_not(guard.read_pending_checked(), "session guard must not mark publication successful");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_failed_write() {
        try {
            create_identity();
            ((!) db).exec("CREATE TRIGGER reject_registration_id BEFORE UPDATE OF device_id ON identity " +
                    "BEGIN SELECT RAISE(ABORT, 'injected registration failure'); END");
            var guard = new LegacyRegistrationGuard((!) db, 1);
            bool rejected = false;
            try { guard.resolve_candidate_checked(advertised(), false); } catch (Error e) { rejected = true; }
            fail_if_not(rejected, "failed persistence must not return a replacement ID");
            fail_if_not_eq_int(guard.read_device_id_checked(), 1001, "failed write must preserve the old ID");
            fail_if_not(guard.read_pending_checked(), "failed write must preserve pending state");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_migration() {
        try {
            create_identity(false);
            // Recreate the exact v8 identity columns, retaining the other v8
            // tables unchanged, then let production Qlite perform migration.
            ((!) db).exec("ALTER TABLE identity RENAME TO identity_v9");
            ((!) db).exec("CREATE TABLE identity (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "account_id INTEGER NOT NULL UNIQUE, device_id INTEGER NOT NULL, " +
                    "identity_key_private_base64 TEXT NOT NULL, identity_key_public_base64 TEXT NOT NULL)");
            ((!) db).exec("INSERT INTO identity SELECT id, account_id, device_id, " +
                    "identity_key_private_base64, identity_key_public_base64 FROM identity_v9");
            ((!) db).exec("DROP TABLE identity_v9");
            TrustLifecycleTest.restore_pre_v11_content_meta((!) db);
            ((!) db).exec("UPDATE _meta SET int_val = 8 WHERE name = 'version'");
            reopen();
            var guard = new LegacyRegistrationGuard((!) db, 1);
            fail_if(guard.read_pending_checked(), "upgraded identities must default to established");
            fail_if_not_eq_int(guard.resolve_candidate_checked(advertised(), false), 1001,
                    "migration must preserve the deployed ID even if listed");
            fail_if_not(guard.matches_identity_key_checked(((!) local_key).public), "migration must preserve the identity key");
            Row? row = ((!) db).identity.select().single().iterator().get_next_checked();
            fail_if_not_eq_str(((!) row)[((!) db).identity.identity_key_private_base64],
                    Base64.encode(((!) local_key).private.serialize()), "migration must preserve the private key");
        } catch (Error e) { fail_if_reached(e.message); }
    }

    private void test_native_registration_gate() {
        try {
            Context context = Plugin.get_context();
            Store store = setup_test_store_context(context);
            store.registration_pending = true;
            var address = new Address("peer@example.test", 42);
            bool builder_rejected = false;
            bool cipher_rejected = false;
            try { store.create_session_builder(address); } catch (Error e) { builder_rejected = true; }
            try { store.create_session_cipher(address); } catch (Error e) { cipher_rejected = true; }
            fail_if_not(builder_rejected, "pending registration must block session creation");
            fail_if_not(cipher_rejected, "pending registration must block ratchet use");
            fail_if_not(store.is_persistence_ready, "registration must not block persistence or initial bundle generation");
            SignedPreKeyRecord record = context.generate_signed_pre_key(store.identity_key_pair, 1);
            store.store_signed_pre_key(record);
            fail_if_not(store.contains_signed_pre_key(1), "registration must permit durable bundle keys");
            store.registration_pending = false;
            store.create_session_builder(address);
            store.create_session_cipher(address);
            address.device_id = 0;
        } catch (Error e) { fail_if_reached(e.message); }
    }
}

}
