using GLib;

namespace Dino.Security {

/** Password changes and history reset are prepared while running, but applied
 * only before databases/plugins start, under the exclusive ProfileLock. */
public class ProfileMaintenance : Object {
    private const string GROUP = "Maintenance";
    private const string OWNER = ".dinox-maintenance-request";
    private const string COMPLETE = ".dinox-maintenance-complete";

    private class Job : Object {
        public string profile;
        public string parent;
        public string basename;
        public string manifest;
        public string token;
        public string directory { owned get { return Path.build_filename(parent, "." + basename + "-maintenance-" + token); } }
        public string request { owned get { return Path.build_filename(directory, "request.db"); } }
        public string stage { owned get { return Path.build_filename(parent, "dinox-restore-stage-" + token); } }
        public string staged_profile { owned get { return Path.build_filename(stage, "dinox"); } }

        public Job(string profile_dir) throws Error {
            if (!Path.is_absolute(profile_dir)) throw new IOError.INVALID_ARGUMENT("Maintenance requires an absolute profile path");
            profile = Filename.canonicalize(profile_dir);
            parent = Path.get_dirname(profile);
            basename = Path.get_basename(profile);
            if (parent == profile) throw new IOError.INVALID_ARGUMENT("Invalid maintenance profile path");
            string component = parent;
            while (true) {
                require_directory(component);
                string next = Path.get_dirname(component);
                if (next == component) break;
                component = next;
            }
            manifest = Path.build_filename(parent, "." + basename + "-maintenance-pending");
            token = Uuid.string_random();
        }
    }

    private static FileInfo? info(string path) throws Error {
        try {
            return File.new_for_path(path).query_info(
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_IS_SYMLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) { return null; }
    }

    private static void require_directory(string path) throws Error {
        var entry = info(path);
        if (entry == null || entry.get_is_symlink() || entry.get_file_type() != FileType.DIRECTORY)
            throw new IOError.INVALID_DATA("Maintenance directory is missing or unsafe");
    }

    private static string read_control(string path) throws Error {
        var entry = info(path);
        if (entry == null || entry.get_is_symlink() || entry.get_file_type() != FileType.REGULAR || entry.get_size() > 4096)
            throw new IOError.INVALID_DATA("Invalid maintenance control file");
        string contents;
        FileUtils.get_contents(path, out contents);
        if (!contents.validate()) throw new IOError.INVALID_DATA("Invalid maintenance control text");
        return contents;
    }

    private static void write_control(string path, string contents) throws Error {
        var entry = info(path);
        if (entry != null && (entry.get_is_symlink() || entry.get_file_type() != FileType.REGULAR))
            throw new IOError.INVALID_DATA("Unsafe maintenance control destination");
        FileUtils.set_contents_full(path, contents, -1,
            FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
    }

    private static bool valid_token(string token) {
        return token.length == 36 && Uuid.string_is_valid(token) && token == token.ascii_down();
    }

    private static string manifest_data(Job job) {
        var data = new KeyFile();
        data.set_integer(GROUP, "version", 1);
        data.set_string(GROUP, "profile", job.basename);
        data.set_string(GROUP, "token", job.token);
        return data.to_data();
    }

    private static void load_manifest(Job job, string path) throws Error {
        var data = new KeyFile();
        string contents = read_control(path);
        data.load_from_data(contents, contents.length, KeyFileFlags.NONE);
        if (data.get_groups().length != 1 || data.get_keys(GROUP).length != 3 ||
                data.get_integer(GROUP, "version") != 1 || data.get_string(GROUP, "profile") != job.basename)
            throw new IOError.INVALID_DATA("Invalid maintenance ownership");
        string token = data.get_string(GROUP, "token");
        if (!valid_token(token)) throw new IOError.INVALID_DATA("Invalid maintenance token");
        job.token = token;
    }

    private static void require_owned_request(Job job) throws Error {
        require_directory(job.directory);
        string expected = job.token;
        load_manifest(job, Path.build_filename(job.directory, OWNER));
        if (job.token != expected) throw new IOError.INVALID_DATA("Maintenance request ownership mismatch");
    }

    private static void remove_tree(string path, int depth = 0) throws Error {
        if (depth > 64) throw new IOError.INVALID_DATA("Maintenance directory nesting is too deep");
        var entry = info(path);
        if (entry == null) return;
        if (!entry.get_is_symlink() && entry.get_file_type() == FileType.DIRECTORY) {
            var children = File.new_for_path(path).enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null)
                remove_tree(Path.build_filename(path, child.get_name()), depth + 1);
            children.close();
        }
        ProfileDeletion.delete_entry(File.new_for_path(path));
    }

    private static void remove_owned_request(Job job) throws Error {
        require_owned_request(job);
        var children = File.new_for_path(job.directory).enumerate_children(FileAttribute.STANDARD_NAME,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            if (child.get_name() != OWNER) remove_tree(Path.build_filename(job.directory, child.get_name()));
        }
        children.close();
        // Preserve ownership if removing a payload fails, so cleanup can retry.
        string marker = Path.build_filename(job.directory, OWNER);
        ProfileDeletion.sync_deleted_parent(marker);
        try {
            ProfileDeletion.delete_entry(File.new_for_path(marker));
            ProfileDeletion.delete_entry(File.new_for_path(job.directory));
        }
        catch (Error e) {
            if (info(job.directory) != null) write_control(marker, manifest_data(job));
            throw e;
        }
    }

    private static void remove_manifest(Job job) throws Error {
        try {
            ProfileDeletion.delete_entry(File.new_for_path(job.manifest));
        } catch (Error e) {
            // An unlink may have succeeded before its durability check failed.
            // Keep the request intent available for the next offline startup.
            if (info(job.manifest) == null) write_control(job.manifest, manifest_data(job));
            throw e;
        }
    }

    private static void copy_tree(string source, string destination, Cancellable? cancellable, int depth = 0) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (depth > 64) throw new IOError.INVALID_DATA("Maintenance profile nesting is too deep");
        require_directory(source);
        if (DirUtils.create(destination, 0700) != 0) throw new IOError.FAILED("Could not create private maintenance staging");
        var children = File.new_for_path(source).enumerate_children(
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            string from = Path.build_filename(source, child.get_name());
            string to = Path.build_filename(destination, child.get_name());
            if (child.get_is_symlink()) throw new IOError.INVALID_DATA("Maintenance profile contains a symbolic link");
            if (child.get_file_type() == FileType.DIRECTORY) {
                copy_tree(from, to, cancellable, depth + 1);
            } else if (child.get_file_type() == FileType.REGULAR) {
                File.new_for_path(from).copy(File.new_for_path(to), FileCopyFlags.NOFOLLOW_SYMLINKS, cancellable);
                if (FileUtils.chmod(to, 0600) != 0) throw new IOError.FAILED("Could not make staged profile file private");
            } else {
                throw new IOError.INVALID_DATA("Maintenance profile contains a special file");
            }
        }
        children.close();
    }

    public static bool has_pending(string profile_dir) throws Error {
        return info(new Job(profile_dir).manifest) != null;
    }

    public static void schedule_password_change(string profile_dir, string old_key, string new_key) throws Error {
        if (new_key.strip().length == 0) throw new IOError.INVALID_ARGUMENT("New database password must not be empty");
        schedule(profile_dir, old_key, "password", new_key);
    }

    public static void schedule_reset(string profile_dir, string old_key) throws Error {
        schedule(profile_dir, old_key, "reset", "");
    }

    private static void schedule(string profile_dir, string old_key, string operation, string new_key) throws Error {
        var job = new Job(profile_dir);
        require_directory(job.profile);
        if (old_key.length == 0) throw new IOError.INVALID_ARGUMENT("Database password must not be empty");
        if (info(job.manifest) != null || ProfileRestore.has_pending(job.profile))
            throw new IOError.EXISTS("Another profile replacement is already pending");
        if (DirUtils.create(job.directory, 0700) != 0) throw new IOError.FAILED("Could not create private maintenance request");
        Qlite.Database? request = null;
        try {
            write_control(Path.build_filename(job.directory, OWNER), manifest_data(job));
            request = Qlite.Database.create_encrypted(job.request, old_key);
            request.exec("CREATE TABLE maintenance (token TEXT NOT NULL, operation TEXT NOT NULL, new_key TEXT NOT NULL)");
            request.exec_prepared("INSERT INTO maintenance VALUES (?, ?, ?)", { job.token, operation, new_key });
            request.exec("PRAGMA wal_checkpoint(TRUNCATE)");
            request.exec("PRAGMA journal_mode = DELETE");
            request.close();
            request = null;
            write_control(job.manifest, manifest_data(job));
        } catch (Error e) {
            if (request != null) { request.close(); request = null; }
            // A durable atomic write may report an error after publication.
            // Keep the request if a manifest could already refer to it.
            if (info(job.manifest) == null) remove_tree(job.directory);
            throw e;
        }
    }

    /** Called after ProfileRestore.apply_pending at startup, before unlocking.
     * A successfully installed marker permits cleanup without the old password. */
    public static bool finish_completed(string profile_dir) throws Error {
        var job = new Job(profile_dir);
        if (info(job.manifest) == null) return false;
        load_manifest(job, job.manifest);
        string marker = Path.build_filename(job.profile, COMPLETE);
        if (info(marker) == null || read_control(marker) != job.token) return false;
        ProfileRestore.cleanup_completed(job.profile, job.token);
        // Maintenance uses the restore transaction, but its installed profile
        // expects the new password after a password change. Retire only this
        // confirmed transaction's backup-unlock hint before dropping its
        // request: a crash must not present an original-backup-password prompt.
        string restore_hint = Path.build_filename(job.profile, ".restore_pending");
        if (info(restore_hint) != null) {
            if (read_control(restore_hint) != "1")
                throw new IOError.INVALID_DATA("Invalid completed maintenance restore hint");
            ProfileDeletion.delete_entry(File.new_for_path(restore_hint));
        } else {
            // A previous unlink may have succeeded before its directory sync
            // failed. Keep the request until that boundary has also completed.
            ProfileDeletion.sync_deleted_parent(restore_hint);
        }
        if (info(job.directory) != null) {
            remove_owned_request(job);
        }
        // Also complete a prior directory unlink whose parent sync failed.
        ProfileDeletion.sync_deleted_parent(job.directory);
        remove_manifest(job);
        return true;
    }

    private static string read_request_value(Qlite.Database request, string column) throws Error {
        string[] values = request.query_column_checked("SELECT " + column + " FROM maintenance");
        if (values.length != 1) throw new IOError.INVALID_DATA("Invalid maintenance request row count");
        return values[0];
    }

    /** Returns the effective database password. Failure before publication only
     * removes this request's unfinished copy; the original profile stays intact. */
    public static string apply_pending(string profile_dir, string entered_key, Cancellable? cancellable = null) throws Error {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        var job = new Job(profile_dir);
        if (info(job.manifest) == null) return entered_key;
        load_manifest(job, job.manifest);
        require_owned_request(job);
        string operation = "";
        string new_key = "";
        {
            var request = Qlite.Database.open_existing(job.request, entered_key);
            try {
                if (read_request_value(request, "token") != job.token)
                    throw new IOError.INVALID_DATA("Maintenance request token mismatch");
                operation = read_request_value(request, "operation");
                new_key = read_request_value(request, "new_key");
            } finally { request.close(); }
        }
        if ((operation != "password" && operation != "reset") ||
                (operation == "password" && new_key.strip().length == 0) || (operation == "reset" && new_key != ""))
            throw new IOError.INVALID_DATA("Invalid maintenance operation");
        if (ProfileRestore.has_pending(job.profile)) throw new IOError.BUSY("Profile restore must finish before maintenance");
        if (info(job.stage) != null) ProfileRestore.discard_stage(job.profile, job.stage);
        try {
            ProfileRestore.prepare_stage(job.profile, job.stage);
            copy_tree(job.profile, job.staged_profile, cancellable);
            string[] shared_databases = { "dino.db", "pgp.db", "mqtt.db", "bot_registry.db" };
            foreach (string name in shared_databases) {
                if (cancellable != null) cancellable.set_error_if_cancelled();
                if (operation == "reset" && name != "dino.db") continue;
                string path = Path.build_filename(job.staged_profile, name);
                if (info(path) == null && name != "dino.db") continue;
                var database = Qlite.Database.open_existing(path, entered_key);
                try {
                    database.exec("PRAGMA synchronous = FULL");
                    if (name == "dino.db") {
                        Dino.Database.ensure_file_encryption_key(database, entered_key);
                        if (operation == "reset") Dino.Database.reset_local_history(database);
                    }
                    if (operation == "password") database.rekey(new_key);
                    database.exec("PRAGMA wal_checkpoint(TRUNCATE)");
                    database.exec("PRAGMA journal_mode = DELETE");
                } finally { database.close(); }
            }
            if (operation == "reset") {
                foreach (string name in new string[] { "omemo.db", "omemo.db-wal", "omemo.db-shm", "omemo.db-journal", "omemo.key", "omemo", "files" })
                    remove_tree(Path.build_filename(job.staged_profile, name));
            }
            if (cancellable != null) cancellable.set_error_if_cancelled();
            write_control(Path.build_filename(job.staged_profile, COMPLETE), job.token);
            ProfileRestore.schedule(job.profile, job.stage);
            ProfileRestore.apply_pending(job.profile);
            try { finish_completed(job.profile); }
            catch (Error cleanup_error) {
                // The installed profile already has the new key. Keep the
                // request for the next startup; never report the old key here.
                warning("Profile maintenance completed; transaction cleanup must be retried at startup");
            }
            return operation == "password" ? new_key : entered_key;
        } catch (Error e) {
            if (!ProfileRestore.has_pending(job.profile) && info(job.stage) != null)
                ProfileRestore.discard_stage(job.profile, job.stage);
            throw e;
        }
    }

    /** Explicit factory reset/panic cleanup, under ProfileLock. Restore-owned
     * stages are cleaned by ProfileRestore.cleanup_owned_artifacts first. */
    public static void cancel_pending(string profile_dir) throws Error {
        var job = new Job(profile_dir);
        bool pending = info(job.manifest) != null;
        if (pending) load_manifest(job, job.manifest);
        string? pending_token = pending ? job.token : null;
        var children = File.new_for_path(job.parent).enumerate_children(
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        string prefix = "." + job.basename + "-maintenance-";
        var owned_paths = new Gee.ArrayList<string>();
        while ((child = children.next_file()) != null) {
            string name = child.get_name();
            if (!name.has_prefix(prefix)) continue;
            string token = name.substring(prefix.length);
            if (!valid_token(token)) continue;
            job.token = token;
            try {
                require_owned_request(job);
                owned_paths.add(job.directory);
            } catch (Error e) {
                if (pending_token == token) throw e;
            }
        }
        children.close();
        foreach (string path in owned_paths) {
            job.token = Path.get_basename(path).substring(prefix.length);
            remove_owned_request(job);
        }
        ProfileDeletion.sync_deleted_parent(job.manifest);
        if (pending) {
            job.token = (!) pending_token;
            remove_manifest(job);
        }
    }
}

}
