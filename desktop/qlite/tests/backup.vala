namespace Qlite.BackupTest {

private const string KEY = "isolated-online-backup-key";

private void require(bool condition, string message) throws Error {
    if (!condition) throw new Error(-1, 0, message);
}

private class Fixture : Object {
    internal string directory;
    internal string source_path;
    internal string snapshot_path;
    internal Database source;

    internal Fixture(string? key = KEY) throws Error {
        directory = DirUtils.make_tmp("dinox-qlite-backup-XXXXXX");
        source_path = Path.build_filename(directory, "source.db");
        snapshot_path = Path.build_filename(directory, "snapshot.db");
        source = new Database(source_path, 1);
        source.init({}, key, false);
        source.exec("PRAGMA wal_autocheckpoint = 0");
        source.exec("CREATE TABLE proof(value INTEGER NOT NULL)");
        source.exec("INSERT INTO proof VALUES(123)");
    }

    internal void cleanup() {
        source.close();
        try {
            Dir dir = Dir.open(directory);
            string? name;
            while ((name = dir.read_name()) != null) {
                FileUtils.remove(Path.build_filename(directory, name));
            }
        } catch (FileError e) {
            GLib.Test.fail();
        }
        DirUtils.remove(directory);
    }
}

private long count_rows(Database database) throws Error {
    Row? row = database.query_sql("SELECT count(*) AS total FROM proof").get_next_checked();
    require(row != null, "snapshot did not contain proof rows");
    return row.get_integer("total");
}

private void require_no_temporary_files(Fixture fixture) throws Error {
    Dir directory = Dir.open(fixture.directory);
    string? name;
    while ((name = directory.read_name()) != null) {
        require(!name.contains(".backup-"), "failed backup left a temporary database or journal behind");
    }
}

private void assert_snapshot(Fixture fixture, string? key, long expected_rows) throws Error {
    require(FileUtils.test(fixture.snapshot_path, FileTest.IS_REGULAR), "snapshot was not published");
    require(!FileUtils.test(fixture.snapshot_path + "-wal", FileTest.EXISTS), "snapshot requires a WAL sidecar");
    require(!FileUtils.test(fixture.snapshot_path + "-shm", FileTest.EXISTS), "snapshot requires an SHM sidecar");
    require_no_temporary_files(fixture);
    var snapshot = new Database(fixture.snapshot_path, 1);
    try {
        snapshot.init({}, key, false);
        require(count_rows(snapshot) == expected_rows, "snapshot contains an incorrect committed row count");
    } finally {
        snapshot.close();
    }
}

private void test_encrypted_wal() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        require(FileUtils.test(fixture.source_path + "-wal", FileTest.EXISTS), "fixture needs live WAL pages");
        fixture.source.backup_to(fixture.snapshot_path);
        // Later source commits must not change the completed snapshot.
        fixture.source.exec("INSERT INTO proof VALUES(456)");
        assert_snapshot(fixture, KEY, 1);
        uint8[] bytes;
        FileUtils.get_data(fixture.snapshot_path, out bytes);
        require(bytes.length > 16, "encrypted snapshot is empty");
        require(new Bytes(bytes[0:15]).compare(new Bytes("SQLite format 3".data)) != 0,
            "encrypted snapshot must not have a plaintext SQLite header");
        require(count_rows(fixture.source) == 2, "source did not remain writable after backup");
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_rekeyed_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        const string replacement = "isolated-rekeyed-backup-key";
        fixture.source.rekey(replacement);
        fixture.source.backup_to(fixture.snapshot_path);
        assert_snapshot(fixture, replacement, 1);
        var old_key_attempt = new Database(fixture.snapshot_path, 1);
        bool failed = false;
        try { old_key_attempt.init({}, KEY, false); }
        catch (Error e) { failed = true; }
        finally { old_key_attempt.close(); }
        require(failed, "snapshot still opens with the password from before rekey");
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_plaintext_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture(null);
        fixture.source.backup_to(fixture.snapshot_path);
        assert_snapshot(fixture, null, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_busy_cleanup() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        fixture.source.exec("BEGIN IMMEDIATE");
        fixture.source.exec("INSERT INTO proof VALUES(999)");
        bool failed = false;
        int64 start = GLib.get_monotonic_time();
        try { fixture.source.backup_to(fixture.snapshot_path); }
        catch (Error e) { failed = true; }
        int64 elapsed = GLib.get_monotonic_time() - start;
        require(failed, "snapshot must not publish an uncommitted source transaction");
        require(elapsed < 15 * TimeSpan.SECOND, "busy backup wait was not bounded");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "failed busy backup published a destination");
        require_no_temporary_files(fixture);
        fixture.source.exec("ROLLBACK");
        fixture.source.backup_to(fixture.snapshot_path);
        assert_snapshot(fixture, KEY, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_existing_destination_untouched() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        FileUtils.set_contents(fixture.snapshot_path, "existing destination marker");
        bool failed = false;
        try { fixture.source.backup_to(fixture.snapshot_path); }
        catch (Error e) { failed = true; }
        require(failed, "backup must refuse an existing destination");
        string preserved;
        FileUtils.get_contents(fixture.snapshot_path, out preserved);
        require(preserved == "existing destination marker", "existing destination was modified");
        require_no_temporary_files(fixture);
        require(count_rows(fixture.source) == 1, "source changed after rejected backup");
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_busy_transaction_commits() {
    Fixture? fixture = null;
    Thread<string?>? writer = null;
    try {
        fixture = new Fixture();
        fixture.source.exec("BEGIN IMMEDIATE");
        fixture.source.exec("INSERT INTO proof VALUES(456)");
        Database source = fixture.source;
        writer = new Thread<string?>("backup-transaction-commit", () => {
            Thread.usleep(100000);
            try { source.exec("COMMIT"); }
            catch (Error e) { return e.message; }
            return null;
        });
        fixture.source.backup_to(fixture.snapshot_path);
        string? writer_error = writer.join();
        writer = null;
        require(writer_error == null, "concurrent transaction could not commit during backup");
        assert_snapshot(fixture, KEY, 2);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally {
        if (writer != null) writer.join();
        if (fixture != null) fixture.cleanup();
    }
}

private void test_closed_source() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        fixture.source.close();
        bool failed = false;
        try { fixture.source.backup_to(fixture.snapshot_path); }
        catch (Error e) { failed = true; }
        require(failed, "closed source must refuse backup");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "closed-source backup published a destination");
        require_no_temporary_files(fixture);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_cancel_busy_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        fixture.source.exec("BEGIN IMMEDIATE");
        fixture.source.exec("INSERT INTO proof VALUES (999)");
        int calls = 0;
        bool failed = false;
        int64 started = GLib.get_monotonic_time();
        try { fixture.source.backup_to(fixture.snapshot_path, () => ++calls >= 4); }
        catch (Error expected) { failed = true; }
        require(failed && calls >= 4, "cancellation must interrupt an active busy backup");
        require(GLib.get_monotonic_time() - started < 2 * TimeSpan.SECOND, "cancellation waited for the busy deadline");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "cancelled backup published a destination");
        require_no_temporary_files(fixture);
        fixture.source.exec("ROLLBACK");
        fixture.source.backup_to(fixture.snapshot_path);
        assert_snapshot(fixture, KEY, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_uninitialized_encrypted_wal_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        require(FileUtils.test(fixture.source_path + "-wal", FileTest.EXISTS),
            "uninitialized plugin fixture needs committed WAL pages");
        uint8[] original_main, original_wal;
        FileUtils.get_data(fixture.source_path, out original_main);
        FileUtils.get_data(fixture.source_path + "-wal", out original_wal);
        // No plugin Database subclass or schema initialization is involved.
        Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path);
        uint8[] after_main, after_wal;
        FileUtils.get_data(fixture.source_path, out after_main);
        FileUtils.get_data(fixture.source_path + "-wal", out after_wal);
        require(new Bytes(original_main).compare(new Bytes(after_main)) == 0, "backup changed the source database");
        require(new Bytes(original_wal).compare(new Bytes(after_wal)) == 0, "backup changed committed source WAL pages");
        fixture.source.exec("INSERT INTO proof VALUES(456)");
        assert_snapshot(fixture, KEY, 1);
        fixture.source.close();
        string renamed = fixture.source_path + ".renamed";
        require(FileUtils.rename(fixture.source_path, renamed) == 0,
            "backup left a source handle open after completion");
        require(FileUtils.rename(renamed, fixture.source_path) == 0,
            "could not restore source filename after handle check");
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_uninitialized_closed_database_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        fixture.source.close();
        Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path);
        assert_snapshot(fixture, KEY, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_uninitialized_invalid_source() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        foreach (string? key in new string?[] { null, "", "wrong-isolated-key" }) {
            foreach (bool allow_plaintext in new bool[] { false, true }) {
                bool failed = false;
                try { Database.backup_existing(fixture.source_path, key, fixture.snapshot_path, allow_plaintext); }
                catch (Error expected) { failed = true; }
                require(failed, "invalid encrypted source key must be reported even with plaintext compatibility");
                require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS),
                    "invalid source key published a destination");
                require_no_temporary_files(fixture);
            }
        }
        fixture.source.close();
        string missing = Path.build_filename(fixture.directory, "missing.db");
        bool failed = false;
        try { Database.backup_existing(missing, KEY, fixture.snapshot_path); }
        catch (Error expected) { failed = true; }
        require(failed && !FileUtils.test(missing, FileTest.EXISTS), "backup must not create a missing source");
        FileUtils.set_contents(fixture.source_path, "not a database");
        failed = false;
        try { Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path, true); }
        catch (Error expected) { failed = true; }
        require(failed, "malformed database must be reported to the caller");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "malformed source published a destination");
        string unchanged;
        FileUtils.get_contents(fixture.source_path, out unchanged);
        require(unchanged == "not a database", "backup modified the malformed source");
        require_no_temporary_files(fixture);
        require(FileUtils.remove(fixture.source_path) == 0,
            "backup left a source handle open after validation failure");
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_uninitialized_cancelled_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        bool failed = false;
        int calls = 0;
        try { Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path, false, () => ++calls >= 3); }
        catch (Error expected) { failed = true; }
        require(failed && calls >= 3, "cancellation must interrupt the uninitialized backup");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "cancelled backup published a destination");
        require_no_temporary_files(fixture);
        Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path);
        assert_snapshot(fixture, KEY, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

private void test_uninitialized_legacy_plaintext_snapshot() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture(null);
        uint8[] original_main, original_wal;
        FileUtils.get_data(fixture.source_path, out original_main);
        FileUtils.get_data(fixture.source_path + "-wal", out original_wal);
        bool failed = false;
        try { Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path); }
        catch (Error expected) { failed = true; }
        require(failed, "plaintext sources must require an explicit compatibility opt-in");
        require(!FileUtils.test(fixture.snapshot_path, FileTest.EXISTS), "strict backup accepted a plaintext source");
        Database.backup_existing(fixture.source_path, KEY, fixture.snapshot_path, true);
        assert_snapshot(fixture, null, 1);
        uint8[] after_main, after_wal;
        FileUtils.get_data(fixture.source_path, out after_main);
        FileUtils.get_data(fixture.source_path + "-wal", out after_wal);
        require(new Bytes(original_main).compare(new Bytes(after_main)) == 0, "backup migrated the historical plaintext source");
        require(new Bytes(original_wal).compare(new Bytes(after_wal)) == 0, "backup changed historical plaintext WAL pages");
        require(FileUtils.remove(fixture.snapshot_path) == 0, "snapshot handle stayed open after checking it");
        Database.backup_existing(fixture.source_path, null, fixture.snapshot_path, true);
        assert_snapshot(fixture, null, 1);
    } catch (Error e) { GLib.Test.message("%s", e.message); GLib.Test.fail(); }
    finally { if (fixture != null) fixture.cleanup(); }
}

public int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    GLib.Test.add_func("/QliteBackup/encrypted_live_wal_snapshot", test_encrypted_wal);
    GLib.Test.add_func("/QliteBackup/rekeyed_snapshot_uses_current_key", test_rekeyed_snapshot);
    GLib.Test.add_func("/QliteBackup/plaintext_snapshot", test_plaintext_snapshot);
    GLib.Test.add_func("/QliteBackup/busy_transaction_cleans_up_and_recovers", test_busy_cleanup);
    GLib.Test.add_func("/QliteBackup/existing_destination_is_preserved", test_existing_destination_untouched);
    GLib.Test.add_func("/QliteBackup/concurrent_commit_releases_busy_snapshot", test_busy_transaction_commits);
    GLib.Test.add_func("/QliteBackup/closed_source_is_rejected", test_closed_source);
    GLib.Test.add_func("/QliteBackup/cancel_busy_snapshot_and_retry", test_cancel_busy_snapshot);
    GLib.Test.add_func("/QliteBackup/uninitialized_encrypted_wal_snapshot_preserves_source", test_uninitialized_encrypted_wal_snapshot);
    GLib.Test.add_func("/QliteBackup/uninitialized_closed_database_snapshot", test_uninitialized_closed_database_snapshot);
    GLib.Test.add_func("/QliteBackup/uninitialized_invalid_source_is_reported", test_uninitialized_invalid_source);
    GLib.Test.add_func("/QliteBackup/uninitialized_cancelled_snapshot_and_retry", test_uninitialized_cancelled_snapshot);
    GLib.Test.add_func("/QliteBackup/uninitialized_legacy_plaintext_snapshot_requires_opt_in", test_uninitialized_legacy_plaintext_snapshot);
    return GLib.Test.run();
}

}
