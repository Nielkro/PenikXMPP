using Dino.Security;

namespace Dino.Test {

class KeyManagerRecoveryTest : Gee.TestCase {
    private const string EXISTING_KEY = "key-manager-isolated-existing-database-key";

    public KeyManagerRecoveryTest() {
        base("KeyManagerRecovery");
        add_test("missing_legacy_key_preserves_existing_database", test_missing_key);
        add_test("empty_legacy_key_preserves_existing_database", test_empty_key);
        add_test("unavailable_legacy_service_preserves_existing_database", test_unavailable_service);
        add_test("no_legacy_lookup_preserves_existing_database", test_no_lookup);
        add_test("existing_file_key_bypasses_legacy_service", test_existing_file_key);
        add_test("existing_legacy_key_is_recovered_without_rotation", test_legacy_recovery);
        add_test("fresh_profile_generates_one_file_key_without_legacy_lookup", test_fresh_profile);
    }

    private class Fixture : Object {
        internal string directory;
        internal string database_path;
        internal string key_path;
        internal uint8[] database_before = {};

        internal Fixture(bool existing_database = true) throws Error {
            directory = DirUtils.make_tmp("dinox-key-recovery-XXXXXX");
            database_path = Path.build_filename(directory, "omemo.db");
            key_path = Path.build_filename(directory, "omemo.key");
            if (existing_database) {
                // A real SQLCipher file, without touching the user's profile,
                // plugin state or secrets service.
                var database = new Qlite.Database(database_path, 1);
                database.init({}, EXISTING_KEY, false);
                database.close();
                FileUtils.get_data(database_path, out database_before);
            }
        }

        internal void cleanup() {
            FileUtils.remove(key_path);
            FileUtils.remove(database_path);
            FileUtils.remove(database_path + "-wal");
            FileUtils.remove(database_path + "-shm");
            DirUtils.remove(directory);
        }
    }

    private void assert_database_unchanged(Fixture fixture) throws Error {
        uint8[] after;
        FileUtils.get_data(fixture.database_path, out after);
        fail_if(new Bytes(after).compare(new Bytes(fixture.database_before)) != 0,
            "key recovery must not modify the existing encrypted database");
        // The original key must still unlock the unchanged file.
        var database = new Qlite.Database(fixture.database_path, 1);
        database.init({}, EXISTING_KEY, false);
        database.close();
    }

    private void assert_failed_recovery(LegacyKeyLookup? lookup) {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            bool failed = false;
            try {
                KeyManager.get_or_create_db_key_for_directory(fixture.directory, lookup);
            } catch (Error e) {
                failed = true;
                fail_if(!(e is IOError.FAILED), "missing key must report failed recovery");
            }
            fail_if(!failed, "an existing database must not receive a generated replacement key");
            fail_if(FileUtils.test(fixture.key_path, FileTest.EXISTS),
                "failed recovery must not create an omemo.key file");
            assert_database_unchanged(fixture);
        } catch (Error e) {
            fail_if_reached("Unexpected recovery fixture error: " + e.message);
        } finally {
            if (fixture != null) fixture.cleanup();
        }
    }

    private void test_missing_key() {
        int lookups = 0;
        assert_failed_recovery(() => { lookups++; return null; });
        fail_if(lookups != 1, "existing database must attempt exactly one legacy lookup");
    }

    private void test_empty_key() {
        assert_failed_recovery(() => { return " \n"; });
    }

    private void test_unavailable_service() {
        assert_failed_recovery(() => {
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Legacy secrets-service key recovery failed:*isolated unavailable service*");
            throw new IOError.NOT_CONNECTED("isolated unavailable service");
        });
        GLib.Test.assert_expected_messages();
    }

    private void test_no_lookup() {
        // The production Windows path passes no legacy lookup.
        assert_failed_recovery(null);
    }

    private void test_existing_file_key() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            FileUtils.set_contents(fixture.key_path, EXISTING_KEY);
            int lookups = 0;
            string key = KeyManager.get_or_create_db_key_for_directory(fixture.directory,
                () => { lookups++; return null; });
            fail_if_not_eq_str(EXISTING_KEY, key);
            fail_if(lookups != 0, "a valid file key must bypass the legacy service");
            string saved;
            FileUtils.get_contents(fixture.key_path, out saved);
            fail_if_not_eq_str(EXISTING_KEY, saved);
            assert_database_unchanged(fixture);
        } catch (Error e) {
            fail_if_reached("Unexpected file-key recovery error: " + e.message);
        } finally {
            if (fixture != null) fixture.cleanup();
        }
    }

    private void test_legacy_recovery() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture();
            int lookups = 0;
            string key = KeyManager.get_or_create_db_key_for_directory(fixture.directory,
                () => { lookups++; return EXISTING_KEY; });
            fail_if_not_eq_str(EXISTING_KEY, key);
            fail_if(lookups != 1);
            string saved;
            FileUtils.get_contents(fixture.key_path, out saved);
            fail_if_not_eq_str(EXISTING_KEY, saved,
                "recovery must preserve the original key rather than generate a new one");
            string reopened = KeyManager.get_or_create_db_key_for_directory(fixture.directory,
                () => { lookups++; return null; });
            fail_if_not_eq_str(EXISTING_KEY, reopened);
            fail_if(lookups != 1, "the recovered file key must survive an unavailable keyring");
            assert_database_unchanged(fixture);
        } catch (Error e) {
            fail_if_reached("Unexpected legacy-key recovery error: " + e.message);
        } finally {
            if (fixture != null) fixture.cleanup();
        }
    }

    private void test_fresh_profile() {
        Fixture? fixture = null;
        try {
            fixture = new Fixture(false);
            int lookups = 0;
            string key = KeyManager.get_or_create_db_key_for_directory(fixture.directory,
                () => { lookups++; return EXISTING_KEY; });
            fail_if(key.length != 64, "a fresh profile needs a 32-byte random hexadecimal key");
            fail_if(!Regex.match_simple("^[0-9a-f]{64}$", key));
            fail_if(lookups != 0, "fresh profiles must not contact the legacy keyring");
            string saved;
            FileUtils.get_contents(fixture.key_path, out saved);
            fail_if_not_eq_str(key, saved);
            string reopened = KeyManager.get_or_create_db_key_for_directory(fixture.directory, null);
            fail_if_not_eq_str(key, reopened, "reopening must retain the generated file key");
            fail_if(FileUtils.test(fixture.database_path, FileTest.EXISTS),
                "key creation must not create a database itself");
        } catch (Error e) {
            fail_if_reached("Unexpected fresh-profile key error: " + e.message);
        } finally {
            if (fixture != null) fixture.cleanup();
        }
    }
}

}
