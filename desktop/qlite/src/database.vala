using Sqlite;
using Posix;

namespace Qlite {

public delegate bool BackupCancelled();

public class Database {
    [CCode (cname = "g_open", cheader_filename = "glib/gstdio.h")]
    private static extern int open_private_file(string filename, int flags, int mode);
    private string file_name;
    private Sqlite.Database db;
    private long expected_version;
    private Table[]? tables;
    private string? backup_key;
    private GLib.Mutex backup_mutex = GLib.Mutex();
    public bool fts5_available { get; private set; default = false; }

    private static bool logged_plaintext_fallback = false;
    private static bool logged_plaintext_migration = false;

    private Column<string?> meta_name = new Column.Text("name") { primary_key = true };
    private Column<long> meta_int_val = new Column.Long("int_val");
    private Column<string?> meta_text_val = new Column.Text("text_val");
    private Table meta_table;

    public bool debug = false;

    public Database(string file_name, long expected_version) {
        this.file_name = file_name;
        this.expected_version = expected_version;
        meta_table = new Table(this, "_meta");
        meta_table.init({meta_name, meta_int_val, meta_text_val});
    }

    /** Open an existing encrypted file without CREATE, schema migration or
     * plaintext fallback. Intended for offline maintenance of closed profiles. */
    public static Database open_existing(string path, string key) throws Error {
        if (key.length == 0 || !FileUtils.test(path, FileTest.IS_REGULAR) ||
                FileUtils.test(path, FileTest.IS_SYMLINK))
            throw new Error(-1, 0, "Maintenance requires an existing encrypted database");
        var result = new Database(path, 0);
        try {
            int status = Sqlite.Database.open_v2(path, out result.db, OPEN_READWRITE | 0x00010000);
            if (status != Sqlite.OK)
                throw new Error(-1, status, "Could not open maintenance database (SQLite %d)", status);
            result.db.busy_timeout(5000);
            backup_exec(result.db, "PRAGMA key = '%s'".printf(escape_single_quotes(key)), "key setup");
            backup_exec(result.db, "SELECT count(*) FROM sqlite_master", "key validation");
            if (backup_pragma(result.db, "page_count") == "0")
                throw new Error(-1, 0, "Maintenance database is empty");
            result.tables = {};
            result.backup_key = key;
            return result;
        } catch (Error e) {
            // Table references can keep result alive after a failed open;
            // release the native handle before propagating the error.
            result.close();
            throw e;
        }
    }

    /** Snapshot an existing database without initializing its plugin,
     * creating a file, migrating its schema or writing to the source. The
     * normal online-backup path still includes committed WAL pages. Legacy
     * plaintext sources require an explicit opt-in and verified SQLite data. */
    public static void backup_existing(string source, string? key, string destination,
                                       bool allow_plaintext = false,
                                       BackupCancelled? cancelled = null) throws Error {
        if (cancelled != null && cancelled()) throw new Error(-1, 0, "Database snapshot cancelled");
        bool encrypted = key != null && key.length > 0;
        if (!Path.is_absolute(source) || (!encrypted && !allow_plaintext) ||
                !FileUtils.test(source, FileTest.IS_REGULAR) ||
                FileUtils.test(source, FileTest.IS_SYMLINK)) {
            throw new Error(-1, 0, "Backup requires an existing database and its encryption key");
        }
        var database = new Database(source, 0);
        try {
            int status = Sqlite.Database.open_v2(source, out database.db,
                OPEN_READONLY | 0x00010000);
            if (status != Sqlite.OK) {
                throw new Error(-1, status, "Could not open existing backup source (SQLite %d)", status);
            }
            database.db.busy_timeout(5000);
            if (encrypted) {
                backup_exec(database.db, "PRAGMA key = '%s'".printf(escape_single_quotes((!) key)), "key setup");
            }
            status = database.db.exec("SELECT count(*) FROM sqlite_master");
            if (status != Sqlite.OK && encrypted && allow_plaintext) {
                // A historical plaintext file must actually open without a
                // key. A wrong encrypted key or corruption still fails here.
                database.db = null;
                status = Sqlite.Database.open_v2(source, out database.db,
                    OPEN_READONLY | 0x00010000);
                if (status != Sqlite.OK) {
                    throw new Error(-1, status, "Could not open existing backup source (SQLite %d)", status);
                }
                database.db.busy_timeout(5000);
                status = database.db.exec("SELECT count(*) FROM sqlite_master");
                encrypted = false;
            }
            if (status != Sqlite.OK) {
                throw new Error(-1, status, "Database backup key validation failed (SQLite %d)", status);
            }
            if (backup_pragma(database.db, "page_count") == "0") {
                throw new Error(-1, 0, "Backup source database is empty");
            }
            database.tables = {};
            database.backup_key = encrypted ? key : null;
            database.backup_to(destination, cancelled);
        } finally {
            // Release the native handle even after a failed key validation.
            // Windows must be able to replace/delete a closed profile later.
            database.close();
        }
    }

    /** Create only a new encrypted database. All failures are propagated; this
     * deliberately avoids the application's fatal schema-migration path. */
    public static Database create_encrypted(string path, string key) throws Error {
        if (!Path.is_absolute(path) || key.length == 0)
            throw new Error(-1, 0, "A new encrypted database requires an absolute path and a key");
        int descriptor = open_private_file(path, Posix.O_CREAT | Posix.O_EXCL | Posix.O_RDWR, 0600);
        if (descriptor < 0) throw new Error(-1, 0, "Could not create a private encrypted database");
        Posix.close(descriptor);
        var result = new Database(path, 0);
        try {
            int status = Sqlite.Database.open_v2(path, out result.db, OPEN_READWRITE | 0x00010000);
            if (status != Sqlite.OK)
                throw new Error(-1, status, "Could not open a new encrypted database (SQLite %d)", status);
            backup_exec(result.db, "PRAGMA key = '%s'".printf(escape_single_quotes(key)), "key setup");
            backup_exec(result.db, "PRAGMA synchronous = FULL", "durability setup");
            result.tables = {};
            result.backup_key = key;
            return result;
        } catch (Error e) {
            result.db = null;
            FileUtils.remove(path);
            FileUtils.remove(path + "-journal");
            throw e;
        }
    }

    private Sqlite.Statement checked_statement(string sql, string[]? arguments) throws Error {
        if (tables == null || db == null) throw new Error(-1, 0, "Database is not open");
        Sqlite.Statement statement;
        int status = db.prepare_v2(sql, -1, out statement);
        if (status != Sqlite.OK) throw new Error(-1, status, "Database statement preparation failed (SQLite %d)", status);
        if (arguments != null) {
            for (int i = 0; i < arguments.length; i++) {
                status = statement.bind_text(i + 1, arguments[i]);
                if (status != Sqlite.OK) throw new Error(-1, status, "Database parameter binding failed (SQLite %d)", status);
            }
        }
        return (owned) statement;
    }

    /** Checked, parameterized maintenance operations never log SQL or values. */
    public void exec_prepared(string sql, string[]? arguments = null) throws Error {
        var statement = checked_statement(sql, arguments);
        int status = statement.step();
        if (status != Sqlite.DONE) throw new Error(-1, status, "Database statement failed (SQLite %d)", status);
    }

    public string[] query_column_checked(string sql, string[]? arguments = null) throws Error {
        var statement = checked_statement(sql, arguments);
        string[] values = {};
        int status;
        while ((status = statement.step()) == Sqlite.ROW) {
            string? value = statement.column_text(0);
            if (value == null) throw new Error(-1, 0, "Database query returned an unexpected null value");
            values += value;
        }
        if (status != Sqlite.DONE) throw new Error(-1, status, "Database query failed (SQLite %d)", status);
        return values;
    }

    public void init(Table[] tables, string? key = null, bool allow_plaintext_fallback = true) throws Error {
        bool encrypted = key != null && key.length > 0;
        Sqlite.config(Config.SERIALIZED);
        int ec = Sqlite.Database.open_v2(file_name, out db, OPEN_READWRITE | OPEN_CREATE | 0x00010000);
        if (ec != Sqlite.OK) {
            throw new Error(-1, 0, "SQLite open error for \"%s\": %d - %s", file_name, db.errcode(), db.errmsg());
        }

        if (key != null) {
            // Escape single quotes for SQL string literal.
            string escaped_key = escape_single_quotes((!)key);
            string key_pragma = "PRAGMA key = '%s';".printf(escaped_key);
            db.exec(key_pragma, null, null);
            
            // Verify encryption
            if (db.exec("SELECT count(*) FROM sqlite_master;", null, null) != Sqlite.OK) {
                // If the DB is plaintext, trying to open it with a key will fail.
                // Fall back and, if possible, migrate plaintext -> encrypted automatically.

                // Re-open without a key to see if it's plaintext.
                db = null;
                ec = Sqlite.Database.open_v2(file_name, out db, OPEN_READWRITE | OPEN_CREATE | 0x00010000);
                if (db.exec("SELECT count(*) FROM sqlite_master;", null, null) == Sqlite.OK) {
                    // Plaintext database detected.
                    bool migrated = false;
                    try {
                        migrated = try_migrate_plaintext_to_encrypted(((!)key));
                    } catch (Error e) {
                        migrated = false;
                    }

                    if (migrated) {
                        if (!logged_plaintext_migration) {
                            message("Qlite: Migrated plain text database to encrypted storage.");
                            logged_plaintext_migration = true;
                        }
                        // Re-open encrypted.
                        db = null;
                        ec = Sqlite.Database.open_v2(file_name, out db, OPEN_READWRITE | OPEN_CREATE | 0x00010000);
                        db.exec(key_pragma, null, null);
                        if (db.exec("SELECT count(*) FROM sqlite_master;", null, null) != Sqlite.OK) {
                            throw new Error(-1, 0, "Qlite: Database migration succeeded but encrypted reopen failed for \"%s\" (Invalid key or corrupted).", file_name);
                        }
                    } else {
                        if (!allow_plaintext_fallback) {
                            throw new Error(-1, 0, "Qlite: Plain text database detected for \"%s\" but encryption migration failed; refusing to run without encryption.", file_name);
                        }
                        if (!logged_plaintext_fallback) {
                            // Not a warning: this can happen on upgrades from versions that stored plaintext.
                            message("Qlite: Plain text database detected; running without encryption because migration failed.");
                            logged_plaintext_fallback = true;
                        }
                        encrypted = false;
                    }
                } else {
                    // Encrypted DB but wrong key, or corrupted DB.
                    throw new Error(-1, 0, "Qlite: Failed to open database \"%s\" (Invalid key or corrupted).", file_name);
                }
            }
        }

        // S4: Restrict file permissions to owner-only (0600) — after potential migration which replaces the file
        // On Windows, Posix.chmod() is a no-op (MinGW stub). DB files inherit
        // user-only ACLs from %APPDATA% parent directory, which is sufficient.
#if !WINDOWS
        Posix.chmod(file_name, Posix.S_IRUSR | Posix.S_IWUSR);
        // Also chmod WAL and SHM files if they exist
        if (FileUtils.test(file_name + "-wal", FileTest.EXISTS)) {
            Posix.chmod(file_name + "-wal", Posix.S_IRUSR | Posix.S_IWUSR);
        }
        if (FileUtils.test(file_name + "-shm", FileTest.EXISTS)) {
            Posix.chmod(file_name + "-shm", Posix.S_IRUSR | Posix.S_IWUSR);
        }
#endif

        this.tables = tables;
        if (debug) db.trace((message) => GLib.debug(@"Qlite trace: $message"));

        // Detect FTS5 availability at runtime
        Sqlite.Database fts_test_db;
        if (Sqlite.Database.open_v2(":memory:", out fts_test_db, OPEN_READWRITE | OPEN_CREATE) == Sqlite.OK) {
            fts5_available = (fts_test_db.exec("CREATE VIRTUAL TABLE _fts5_test USING fts5(x)", null, null) == Sqlite.OK);
            fts_test_db = null;
        }

        // B5: Enable foreign key enforcement (must be outside transaction, per-connection)
        db.exec("PRAGMA foreign_keys = ON;", null, null);

        // O1: Check current auto_vacuum mode; if NONE, switch to INCREMENTAL via VACUUM
        // PRAGMA auto_vacuum must be set before VACUUM converts the database.
        // Must happen BEFORE start_migration() since VACUUM can't run in a transaction.
        int auto_vac_mode = -1;
        {
            Sqlite.Statement av_stmt;
            if (db.prepare_v2("PRAGMA auto_vacuum", -1, out av_stmt) == Sqlite.OK) {
                if (av_stmt.step() == Sqlite.ROW) {
                    auto_vac_mode = av_stmt.column_int(0);
                }
            }
            // av_stmt goes out of scope here → finalized → no read lock
        }
        if (auto_vac_mode == 0) {  // NONE — convert to INCREMENTAL
            db.exec("PRAGMA auto_vacuum = INCREMENTAL", null, null);
            int vc = db.exec("VACUUM", null, null);
            if (vc == Sqlite.OK) {
                message("Qlite: Converted database \"%s\" to incremental auto-vacuum.", file_name);
            } else {
                warning("Qlite: Failed to VACUUM \"%s\" for auto_vacuum conversion: %s", file_name, db.errmsg());
            }
        }

        // P1: Enable WAL mode + relaxed sync BEFORE migration for faster schema upgrades
        db.exec("PRAGMA journal_mode = WAL", null, null);
        db.exec("PRAGMA synchronous = NORMAL", null, null);

        start_migration();
        backup_key = encrypted ? key : null;
    }

    public void close() {
        backup_mutex.lock();
        try {
            db = null;
            backup_key = null;
        } finally {
            backup_mutex.unlock();
        }
    }

    private static string backup_pragma(Sqlite.Database connection, string name) throws Error {
        Sqlite.Statement statement;
        if (connection.prepare_v2("PRAGMA " + name, -1, out statement) != Sqlite.OK ||
                statement.step() != Sqlite.ROW) {
            throw new Error(-1, 0, "Could not read database backup setting %s", name);
        }
        string? value = statement.column_text(0);
        if (value == null || value.length == 0) {
            throw new Error(-1, 0, "Database backup setting %s is unavailable", name);
        }
        return value;
    }

    private static void backup_exec(Sqlite.Database connection, string sql, string operation) throws Error {
        int result = connection.exec(sql);
        if (result != Sqlite.OK) {
            // SQL may contain the encryption key. Report only the operation
            // and result code, never the query or a native expanded SQL string.
            throw new Error(-1, result, "Database backup %s failed (SQLite %d)", operation, result);
        }
    }

    /**
     * Create a consistent snapshot at a new destination path. The online backup
     * API includes committed WAL pages without copying live journal sidecars.
     * Copying can take time; independent databases may use a worker. A caller
     * snapshotting related databases must first quiesce their shared writers.
     * Each step releases SQLite's source mutex. Rekey and close wait here.
     */
    public void backup_to(string destination, BackupCancelled? cancelled = null) throws Error {
        backup_mutex.lock();
        string? temporary = null;
        Sqlite.Database? target = null;
        Sqlite.Backup? transfer = null;
        try {
            if (cancelled != null && cancelled()) throw new Error(-1, 0, "Database snapshot cancelled");
            if (tables == null || db == null) {
                throw new Error(-1, 0, "Cannot back up a database that is not open");
            }
            if (!Path.is_absolute(destination) ||
                    FileUtils.test(destination, FileTest.EXISTS | FileTest.IS_SYMLINK)) {
                throw new Error(-1, 0, "Database backup requires a new absolute destination path");
            }
            if (backup_key != null) {
                string version = backup_pragma(db, "cipher_version");
                string[] components = version.split(".");
                int major = components.length > 0 ? int.parse(components[0]) : 0;
                int minor = components.length > 1 ? int.parse(components[1]) : 0;
                if (major < 4 || (major == 4 && minor < 3)) {
                    throw new Error(-1, 0, "Encrypted online backups require SQLCipher 4.3 or newer");
                }
            }

            temporary = destination + ".backup-XXXXXX";
            int descriptor = FileUtils.mkstemp(temporary);
            if (descriptor < 0) {
                temporary = null;
                throw new Error(-1, 0, "Could not create private database backup staging file");
            }
            Posix.close(descriptor);
            int result = Sqlite.Database.open_v2(temporary, out target,
                    OPEN_READWRITE | 0x00010000);
            if (result != Sqlite.OK) {
                throw new Error(-1, result, "Could not open database backup staging file (SQLite %d)", result);
            }
            target.busy_timeout(0);
            if (backup_key != null) {
                backup_exec(target, "PRAGMA key = '%s'".printf(escape_single_quotes((!) backup_key)), "key setup");
                // SQLCipher only supports equal cipher settings for this API.
                string[] settings = { "kdf_iter", "cipher_page_size", "cipher_use_hmac",
                    "cipher_plaintext_header_size", "cipher_hmac_algorithm", "cipher_kdf_algorithm",
                    "cipher_hmac_pgno", "cipher_hmac_salt_mask" };
                foreach (string setting in settings) {
                    string value = backup_pragma(db, setting);
                    backup_exec(target, "PRAGMA %s = '%s'".printf(setting, escape_single_quotes(value)), "cipher setup");
                }
                if (backup_pragma(db, "cipher_plaintext_header_size") != "0") {
                    string salt = backup_pragma(db, "cipher_salt");
                    backup_exec(target, "PRAGMA cipher_salt = \"x'%s'\"".printf(escape_single_quotes(salt)), "cipher salt setup");
                }
            }
            backup_exec(target, "PRAGMA journal_mode = DELETE", "journal setup");
            backup_exec(target, "PRAGMA synchronous = FULL", "durability setup");

            transfer = new Sqlite.Backup(target, "main", db, "main");
            if (transfer == null) {
                throw new Error(-1, target.errcode(), "Could not initialize database snapshot (SQLite %d)", target.errcode());
            }
            int64 busy_wait = 0;
            int64 deadline = GLib.get_monotonic_time() + 300 * TimeSpan.SECOND;
            while (true) {
                if (cancelled != null && cancelled()) throw new Error(-1, 0, "Database snapshot cancelled");
                result = transfer.step(128);
                if (result == Sqlite.DONE) break;
                if (result != Sqlite.OK && result != Sqlite.BUSY && result != Sqlite.LOCKED) {
                    throw new Error(-1, result, "Database snapshot copy failed (SQLite %d)", result);
                }
                if (result == Sqlite.BUSY || result == Sqlite.LOCKED) {
                    if (busy_wait >= 5 * TimeSpan.SECOND) {
                        throw new Error(-1, result, "Database snapshot could not acquire its lock within five seconds");
                    }
                    Thread.usleep(10000);
                    busy_wait += 10000;
                } else {
                    Thread.usleep(1000);
                }
                if (GLib.get_monotonic_time() >= deadline) {
                    throw new Error(-1, 0, "Database snapshot exceeded its time limit");
                }
            }
            // The VAPI's destructor calls sqlite3_backup_finish; SQLite leaves
            // that operation's result on the destination connection.
            transfer = null;
            if (target.errcode() != Sqlite.OK) {
                throw new Error(-1, target.errcode(), "Database snapshot finalization failed (SQLite %d)", target.errcode());
            }
            if (backup_pragma(target, "quick_check(1)") != "ok") {
                throw new Error(-1, 0, "Database snapshot integrity check failed");
            }
            // Backup can copy the source's WAL journal-mode flag. Convert the
            // finished snapshot to one self-contained file before publication.
            backup_exec(target, "PRAGMA journal_mode = DELETE", "journal finalization");
            target = null;
            if (cancelled != null && cancelled()) throw new Error(-1, 0, "Database snapshot cancelled");
            if (FileUtils.rename(temporary, destination) != 0) {
                throw new Error(-1, 0, "Could not publish the completed database snapshot");
            }
            temporary = null;
        } finally {
            transfer = null;
            target = null;
            if (temporary != null) {
                FileUtils.remove(temporary);
                FileUtils.remove(temporary + "-journal");
                FileUtils.remove(temporary + "-wal");
                FileUtils.remove(temporary + "-shm");
            }
            backup_mutex.unlock();
        }
    }

    private bool try_migrate_plaintext_to_encrypted(string key) throws Error {
        // We currently have an *opened plaintext* database connection in `db`.
        // Create a new encrypted database file, export everything, then atomically replace.
        string tmp_path = file_name + ".enc-tmp";

        // Best-effort cleanup of old tmp.
        FileUtils.remove(tmp_path);

        // Escape key for SQL literal.
        string escaped_key = escape_single_quotes(key);

        // Attach a fresh encrypted database and export.
        // sqlcipher_export is provided by SQLCipher.
        string attach = "ATTACH DATABASE '%s' AS encrypted KEY '%s';".printf(escape_single_quotes(tmp_path), escaped_key);
        if (db.exec(attach, null, null) != Sqlite.OK) {
            return false;
        }
        if (db.exec("SELECT sqlcipher_export('encrypted');", null, null) != Sqlite.OK) {
            db.exec("DETACH DATABASE encrypted;", null, null);
            return false;
        }
        db.exec("DETACH DATABASE encrypted;", null, null);

        // Replace original database file.
        // Note: keep the original if replacement fails.
        string backup_path = file_name + ".bak";
        FileUtils.remove(backup_path);

        // Release the current handle before replacing on disk (best-effort).
        // In Vala, clearing the reference drops the underlying handle.
        db = null;

        // Also remove WAL/SHM files that may hold locks
        FileUtils.remove(file_name + "-wal");
        FileUtils.remove(file_name + "-shm");

        if (FileUtils.test(file_name, FileTest.EXISTS)) {
            // Rename original away, then move tmp into place.
            // On Windows, SQLite may briefly hold file locks after handle close.
            bool renamed = false;
            for (int retry = 0; retry < 5; retry++) {
                if (FileUtils.rename(file_name, backup_path) == 0) {
                    renamed = true;
                    break;
                }
                Thread.usleep(100000);  // 100ms
            }
            if (!renamed) {
                return false;
            }
        }
        bool replaced = false;
        for (int retry = 0; retry < 5; retry++) {
            if (FileUtils.rename(tmp_path, file_name) == 0) {
                replaced = true;
                break;
            }
            Thread.usleep(100000);
        }
        if (!replaced) {
            // Restore backup.
            FileUtils.rename(backup_path, file_name);
            return false;
        }
        // Remove backup after successful replace.
        FileUtils.remove(backup_path);
        return true;
    }

    private static string escape_single_quotes(string s) {
        if (s.index_of("'") < 0) return s;

        var b = new GLib.StringBuilder();
        for (int i = 0; i < s.length; i++) {
            char c = s[i];
            if (c == '\'') {
                b.append("''");
            } else {
                b.append_c(c);
            }
        }
        return b.str;
    }

    public void ensure_init() {
        if (tables == null) error(@"Database $file_name was not initialized, call init()");
    }

    private void start_migration() {
        try {
            exec("BEGIN TRANSACTION");
        } catch (Error e) {
            error("SQLite error: %d - %s", db.errcode(), db.errmsg());
        }
        meta_table.create_table_at_version(expected_version);
        long old_version = 0;
        old_version = meta_table.row_with(meta_name, "version")[meta_int_val, -1];
        if (old_version == -1) {
            foreach (Table t in tables) {
                t.create_table_at_version(expected_version);
            }
            meta_table.insert().value(meta_name, "version").value(meta_int_val, expected_version).perform();
        } else if (expected_version != old_version) {
            foreach (Table t in tables) {
                if (t.has_any_column_for_version(old_version)) {
                    t.create_table_at_version(old_version);
                } else {
                    // Table introduced after old_version; create it directly at the new schema version.
                    t.create_table_at_version(expected_version);
                }
            }
            foreach (Table t in tables) {
                if (t.has_any_column_for_version(old_version)) {
                    t.add_columns_for_version(old_version, expected_version);
                }
            }
            migrate(old_version);
            foreach (Table t in tables) {
                if (t.has_any_column_for_version(old_version)) {
                    t.delete_columns_for_version(old_version, expected_version);
                }
            }
            if (old_version == -1) {
                meta_table.insert().value(meta_name, "version").value(meta_int_val, expected_version).perform();
            } else {
                meta_table.update().with(meta_name, "=", "version").set(meta_int_val, expected_version).perform();
            }
        }
        foreach (Table t in tables) {
            t.post();
        }
        try {
            exec("END TRANSACTION");
        } catch (Error e) {
            error("SQLite error: %d - %s", db.errcode(), db.errmsg());
        }
    }

    internal int errcode() {
        return db.errcode();
    }

    internal string errmsg() {
        return db.errmsg();
    }

    internal int64 last_insert_rowid() {
        return db.last_insert_rowid();
    }

    // To be implemented by actual implementation if required
    // new table columns are added, outdated columns are still present and will be removed afterwards
    public virtual void migrate(long old_version) {
    }

    public QueryBuilder select(Column[]? columns = null) {
        ensure_init();
        return new QueryBuilder(this).select(columns);
    }

    internal MatchQueryBuilder match_query(Table table) {
        ensure_init();
        return new MatchQueryBuilder(this, table);
    }

    public InsertBuilder insert() {
        ensure_init();
        return new InsertBuilder(this);
    }

    public UpdateBuilder update(Table table) {
        ensure_init();
        return new UpdateBuilder(this, table);
    }

    public UpsertBuilder upsert(Table table) {
        ensure_init();
        return new UpsertBuilder(this, table);
    }

    public UpdateBuilder update_named(string table) {
        ensure_init();
        return new UpdateBuilder.for_name(this, table);
    }

    public DeleteBuilder delete() {
        ensure_init();
        return new DeleteBuilder(this);
    }

    public RowIterator query_sql(string sql, string[]? args = null) {
        ensure_init();
        return new RowIterator(this, sql, args);
    }

    internal Statement prepare(string sql) {
        ensure_init();
        Sqlite.Statement statement;
        if (db.prepare_v2(sql, sql.length, out statement) != OK) {
            error("SQLite error: %d - %s: %s", db.errcode(), db.errmsg(), sql);
        }
        return statement;
    }

    public void exec(string sql) throws Error {
        ensure_init();
        if (db.exec(sql) != OK) {
            throw new Error(-1, 0, "SQLite error: %d - %s", db.errcode(), db.errmsg());
        }
    }

    public int changes() {
        return db.changes();
    }

    public void rekey(string new_key) throws Error {
        backup_mutex.lock();
        try {
            ensure_init();
            if (new_key.strip().length == 0) {
                throw new Error(-1, 0, "New database key must not be empty.");
            }

            // SQLCipher: PRAGMA rekey changes the encryption key for the entire database.
            // Escape single quotes for SQL string literal.
            string escaped_key = escape_single_quotes(new_key);
            exec("PRAGMA rekey = '%s';".printf(escaped_key));
            backup_key = new_key;

            // Verify DB is still readable.
            if (db.exec("SELECT count(*) FROM sqlite_master;", null, null) != Sqlite.OK) {
                throw new Error(-1, 0, "Database rekey failed (Invalid key or corrupted).");
            }
        } finally {
            backup_mutex.unlock();
        }
    }

    public bool is_known_column(string table, string field) {
        ensure_init();
        foreach (Table t in tables) {
            if (t.name == table && t.is_known_column(field)) return true;
        }
        return false;
    }
}

}
