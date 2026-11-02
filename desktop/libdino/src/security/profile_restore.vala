using GLib;

namespace Dino.Security {

/** A whole-profile replacement, applied only while holding ProfileLock.
 * Scheduling never modifies the live profile. The manifest contains names and
 * a UUID, not paths supplied by an archive. All renames stay in one parent.
 */
public class ProfileRestore : Object {
    [CCode (cname = "dino_profile_restore_sync_tree", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void sync_tree(string path) throws Error;
    [CCode (cname = "dino_profile_restore_rename_directory", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void rename_directory_sync(string source, string destination) throws Error;
#if !WINDOWS
    [CCode (cname = "dino_profile_restore_sync_directory", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void sync_directory(string path) throws Error;
    [CCode (cname = "dino_profile_restore_sync_parent", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void sync_parent(string path) throws Error;
#endif
    private const string STAGE_PREFIX = "dinox-restore-stage-";
    private const string OWNER_MARKER = ".dinox-restore-stage";
    private const string ROLLBACK_MARKER = ".dinox-restore-rollback";
    private const string PROFILE_MARKER = ".dinox-restore-transaction";
    private const string GROUP = "Restore";

    private class Job : Object {
        public string profile;
        public string parent;
        public string basename;
        public string manifest;
        public string token;
        public string phase;
        public bool had_profile;

        public string stage_root { owned get { return Path.build_filename(parent, STAGE_PREFIX + token); } }
        public string staged_profile { owned get { return Path.build_filename(stage_root, "dinox"); } }
        public string rollback { owned get { return Path.build_filename(parent, "." + basename + "-restore-rollback-" + token); } }

        public Job(string profile_dir) throws Error {
            if (!Path.is_absolute(profile_dir)) throw new IOError.INVALID_ARGUMENT("Restore profile path must be absolute");
            profile = Filename.canonicalize(profile_dir);
            basename = Path.get_basename(profile);
            parent = Path.get_dirname(profile);
            if (parent == profile || basename == "." || basename == "..")
                throw new IOError.INVALID_ARGUMENT("Invalid restore profile path");
            require_directory_chain(parent);
            manifest = Path.build_filename(parent, "." + basename + "-restore-pending");
            token = "";
            phase = "prepared";
        }
    }

    // Query without following symlinks, including dangling ones.
    private static FileInfo? info(string path) throws Error {
        try {
            return File.new_for_path(path).query_info(
                FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_IS_SYMLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) {
            return null;
        }
    }

    private static bool directory_exists(string path) throws Error {
        var entry = info(path);
        if (entry == null) return false;
        if (entry.get_is_symlink() || entry.get_file_type() != FileType.DIRECTORY)
            throw new IOError.INVALID_DATA("Restore directory is not a real directory: %s", path);
        return true;
    }

    private static void require_directory_chain(string path) throws Error {
        string component = path;
        while (true) {
            if (!directory_exists(component)) throw new IOError.NOT_FOUND("Restore parent directory does not exist: %s", component);
            string next = Path.get_dirname(component);
            if (next == component) break;
            component = next;
        }
    }

    private static string read_small_file(string path) throws Error {
        var entry = info(path);
        if (entry == null || entry.get_is_symlink() || entry.get_file_type() != FileType.REGULAR || entry.get_size() > 4096)
            throw new IOError.INVALID_DATA("Invalid restore control file: %s", path);
        string contents;
        FileUtils.get_contents(path, out contents);
        if (!contents.validate()) throw new IOError.INVALID_DATA("Restore control file is not valid text");
        return contents;
    }

    private static void write_control(string path, string contents) throws Error {
        var entry = info(path);
        if (entry != null && (entry.get_is_symlink() || entry.get_file_type() != FileType.REGULAR))
            throw new IOError.INVALID_DATA("Refusing to replace a nonregular restore control file: %s", path);
        FileUtils.set_contents_full(path, contents, -1,
            FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
    }

    private static bool valid_token(string token) {
        return token.length == 36 && Uuid.string_is_valid(token) && token == token.ascii_down();
    }

    private static void validate_tree(string path, int depth = 0) throws Error {
        if (depth > 64) throw new IOError.INVALID_DATA("Restore profile directory nesting is too deep");
        if (!directory_exists(path)) throw new IOError.NOT_FOUND("Staged restore profile is missing");
        var children = File.new_for_path(path).enumerate_children(
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK + ",unix::nlink",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            string child_path = Path.build_filename(path, child.get_name());
            if (child.get_is_symlink()) {
                throw new IOError.INVALID_DATA("Restore profile contains a symbolic link: %s", child_path);
            } else if (child.get_file_type() == FileType.DIRECTORY) {
                validate_tree(child_path, depth + 1);
            } else if (child.get_file_type() != FileType.REGULAR) {
                throw new IOError.INVALID_DATA("Restore profile contains a link or special file: %s", child_path);
            }
#if !WINDOWS
            if (child.get_file_type() == FileType.REGULAR && child.has_attribute("unix::nlink") &&
                child.get_attribute_uint32("unix::nlink") > 1)
                throw new IOError.INVALID_DATA("Restore profile contains a hard-linked file: %s", child_path);
#endif
        }
    }

    private static void validate_profile(string path) throws Error {
        validate_tree(path);
        var database = info(Path.build_filename(path, "dino.db"));
        if (database == null || database.get_file_type() != FileType.REGULAR || database.get_size() == 0)
            throw new IOError.INVALID_DATA("Staged restore has no nonempty dino.db");
    }

    private static void write_manifest(Job job) throws Error {
        var manifest = new KeyFile();
        manifest.set_integer(GROUP, "version", 1);
        manifest.set_string(GROUP, "profile", job.basename);
        manifest.set_string(GROUP, "token", job.token);
        manifest.set_string(GROUP, "phase", job.phase);
        manifest.set_boolean(GROUP, "had-profile", job.had_profile);
        write_control(job.manifest, manifest.to_data());
    }

    private static void read_manifest(Job job) throws Error {
        var manifest = new KeyFile();
        string contents = read_small_file(job.manifest);
        manifest.load_from_data(contents, contents.length, KeyFileFlags.NONE);
        if (manifest.get_groups().length != 1 || manifest.get_keys(GROUP).length != 5 ||
            manifest.get_integer(GROUP, "version") != 1 || manifest.get_string(GROUP, "profile") != job.basename)
            throw new IOError.INVALID_DATA("Invalid pending profile restore manifest");
        job.token = manifest.get_string(GROUP, "token");
        job.phase = manifest.get_string(GROUP, "phase");
        job.had_profile = manifest.get_boolean(GROUP, "had-profile");
        if (!valid_token(job.token) || (job.phase != "prepared" && job.phase != "moving" && job.phase != "installed"))
            throw new IOError.INVALID_DATA("Invalid pending profile restore transaction");
    }

    private static bool is_installed(Job job) throws Error {
        string marker = Path.build_filename(job.profile, PROFILE_MARKER);
        return info(marker) != null && read_small_file(marker) == job.token;
    }

    private static string owner_data(Job job) {
        var data = new KeyFile();
        data.set_string(GROUP, "profile", job.basename);
        data.set_string(GROUP, "token", job.token);
        return data.to_data();
    }

    private static bool owned_by(Job job, string marker) throws Error {
        var data = new KeyFile();
        string contents = read_small_file(marker);
        data.load_from_data(contents, contents.length, KeyFileFlags.NONE);
        return data.get_groups().length == 1 && data.get_keys(GROUP).length == 2 &&
            data.get_string(GROUP, "profile") == job.basename &&
            data.get_string(GROUP, "token") == job.token;
    }

    private static void require_owned_stage(Job job) throws Error {
        if (!directory_exists(job.stage_root) || !owned_by(job, Path.build_filename(job.stage_root, OWNER_MARKER)))
            throw new IOError.INVALID_DATA("Pending restore staging ownership is invalid");
    }

    // The native rename is durable and never falls back to a cross-filesystem
    // copy. An open Windows database fails without creating a partial profile.
    private static void rename_directory(string source, string destination) throws Error {
        if (info(destination) != null) throw new IOError.EXISTS("Restore destination already exists: %s", destination);
        rename_directory_sync(source, destination);
    }

    /** Also treats an invalid manifest as pending, so failure cleanup cannot
     * destroy staging while publication/durability is uncertain. */
    public static bool has_pending(string profile_dir) throws Error {
        var job = new Job(profile_dir);
        return info(job.manifest) != null;
    }

    private static Job stage_job(string profile_dir, string stage_root) throws Error {
        var job = new Job(profile_dir);
        if (!Path.is_absolute(stage_root) || Filename.canonicalize(stage_root) != stage_root ||
            Path.get_dirname(stage_root) != job.parent || !Path.get_basename(stage_root).has_prefix(STAGE_PREFIX))
            throw new IOError.INVALID_ARGUMENT("Restore staging must be a direct, named profile sibling");
        job.token = Path.get_basename(stage_root).substring(STAGE_PREFIX.length);
        if (!valid_token(job.token)) throw new IOError.INVALID_ARGUMENT("Invalid restore staging token");
        return job;
    }

    /** Mark ownership before archive extraction, so cancellation/wipe can find
     * an unfinished stage without interpreting archive contents as ownership. */
    public static void prepare_stage(string profile_dir, string stage_root) throws Error {
        var job = stage_job(profile_dir, stage_root);
        if (DirUtils.create(stage_root, 0700) != 0)
            throw new IOError.FAILED("Could not create private restore staging directory");
        write_control(Path.build_filename(stage_root, OWNER_MARKER), owner_data(job));
    }

    /** Caller holds the profile lock; stage_root must be a private sibling. */
    public static void schedule(string profile_dir, string stage_root) throws Error {
        var job = stage_job(profile_dir, stage_root);
        if (info(job.manifest) != null) throw new IOError.EXISTS("A profile restore is already pending");
        if (info(job.rollback) != null) throw new IOError.EXISTS("Restore rollback directory already exists");
        job.had_profile = directory_exists(job.profile);
        if (!directory_exists(stage_root)) throw new IOError.NOT_FOUND("Restore staging directory is missing");
        validate_profile(job.staged_profile);
        if (FileUtils.chmod(stage_root, 0700) != 0 || FileUtils.chmod(job.staged_profile, 0700) != 0)
            throw new IOError.FAILED("Could not make restore staging private");
        write_control(Path.build_filename(stage_root, OWNER_MARKER), owner_data(job));
        write_control(Path.build_filename(job.staged_profile, PROFILE_MARKER), job.token);
        write_control(Path.build_filename(job.staged_profile, ".restore_pending"), "1");
        sync_tree(job.stage_root);
        write_manifest(job);
    }

    private static void finish(Job job) throws Error {
        job.phase = "installed";
        write_manifest(job);
        delete_manifest(job);
        // Never recursively delete a staging path. Only remove our marker and
        // an empty directory; unexpected extra archive entries are retained.
        try {
            require_owned_stage(job);
            var children = File.new_for_path(job.stage_root).enumerate_children(
                FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null) {
                if (child.get_name() != OWNER_MARKER) {
                    // Keep ownership with retained archive entries so an
                    // explicitly requested wipe can later remove this stage.
                    children.close();
                    return;
                }
            }
            children.close();
            remove_empty_owned_directory(job, job.stage_root, OWNER_MARKER);
        } catch (Error e) {
            debug("Retained restore staging after successful install: %s", e.message);
        }
    }

    /** Called before opening any profile file, with an exclusive ProfileLock.
     * A failed second rename restores the old profile before reporting failure.
     * The rollback remains after success, including all original WAL/key files.
     */
    public static bool apply_pending(string profile_dir) throws Error {
        var job = new Job(profile_dir);
        if (info(job.manifest) == null) return false;
        read_manifest(job);
        bool active = directory_exists(job.profile);
        bool rollback = directory_exists(job.rollback);
        if (rollback && !owned_by(job, Path.build_filename(job.rollback, ROLLBACK_MARKER)))
            throw new IOError.INVALID_DATA("Restore rollback ownership is invalid");
        if (active && is_installed(job)) {
            if (job.phase == "prepared" || directory_exists(job.staged_profile) || (job.had_profile && !rollback))
                throw new IOError.INVALID_DATA("Inconsistent installed restore transaction");
            finish(job);
            return true;
        }
        if (job.phase == "installed" || (active && rollback) || (rollback && !job.had_profile) ||
            (job.phase == "prepared" && rollback) || (!active && !rollback && job.had_profile) ||
            (active && !job.had_profile))
            throw new IOError.INVALID_DATA("Inconsistent pending restore directory state");

        try {
            require_owned_stage(job);
            validate_profile(job.staged_profile);
            if (read_small_file(Path.build_filename(job.staged_profile, PROFILE_MARKER)) != job.token ||
                read_small_file(Path.build_filename(job.staged_profile, ".restore_pending")) != "1")
                throw new IOError.INVALID_DATA("Staged restore transaction marker is invalid");
            sync_tree(job.stage_root);
        } catch (Error e) {
            if (!active && rollback) rename_directory(job.rollback, job.profile);
            throw e;
        }

        if (job.phase != "moving") {
            job.phase = "moving";
            write_manifest(job);
        }
        if (active) {
            // This runs offline under the profile lock, never during schedule.
            // The marker lets an explicitly requested wipe identify this old
            // profile without trusting a name pattern alone.
            write_control(Path.build_filename(job.profile, ROLLBACK_MARKER), owner_data(job));
            rename_directory(job.profile, job.rollback);
        }
        try {
            rename_directory(job.staged_profile, job.profile);
        } catch (Error e) {
            // A native durability error may be reported after the rename has
            // completed. Never overwrite that installed profile; its marker
            // allows recovery on the next start while the rollback stays safe.
            if (job.had_profile && !directory_exists(job.profile))
                rename_directory(job.rollback, job.profile);
            throw e;
        }
        finish(job);
        return true;
    }

    private static void remove_tree_without_following_links(string path) throws Error {
        var entry = info(path);
        if (entry == null) return;
        if (!entry.get_is_symlink() && entry.get_file_type() == FileType.DIRECTORY) {
            var children = File.new_for_path(path).enumerate_children(FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null)
                remove_tree_without_following_links(Path.build_filename(path, child.get_name()));
            children.close();
        }
        File.new_for_path(path).delete();
    }

    private static void remove_empty_owned_directory(Job job, string path,
            string marker_name) throws Error {
        string marker = Path.build_filename(path, marker_name);
#if !WINDOWS
        // All direct payload entries must be durably absent before retiring
        // their ownership marker. Nested deletion failures keep that marker.
        sync_directory(path);
#endif
        try {
            File.new_for_path(marker).delete();
#if !WINDOWS
            sync_directory(path);
#endif
            File.new_for_path(path).delete();
#if !WINDOWS
            sync_parent(path);
#endif
        } catch (Error e) {
            // A failed final directory removal must remain identifiable for
            // a later cleanup. No payload remains when the marker is removed.
            if (directory_exists(path)) write_control(marker, owner_data(job));
            throw e;
        }
    }

    private static void delete_manifest(Job job) throws Error {
        try {
            File.new_for_path(job.manifest).delete();
#if !WINDOWS
            sync_parent(job.manifest);
#endif
        } catch (Error e) {
            // Preserve intent when unlink succeeded but its durability check
            // failed. Windows has checked deletes, without a directory-fsync
            // guarantee; process-crash recovery still uses the same markers.
            if (info(job.manifest) == null) write_manifest(job);
            throw e;
        }
    }

    private static void remove_owned_directory(Job job, string path,
            string marker_name) throws Error {
        if (!directory_exists(path)) return;
        if (!owned_by(job, Path.build_filename(path, marker_name)))
            throw new IOError.INVALID_DATA("Restore cleanup ownership is invalid");
        var children = File.new_for_path(path).enumerate_children(
            FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            if (child.get_name() != marker_name)
                remove_tree_without_following_links(Path.build_filename(path, child.get_name()));
        }
        children.close();
        // Keep the root ownership marker until every old key/payload is gone,
        // including when a nested delete fails halfway through cleanup.
        remove_empty_owned_directory(job, path, marker_name);
    }

    /** Abandon one unfinished owned extraction, never a published restore. */
    public static void discard_stage(string profile_dir, string stage_root) throws Error {
        var job = stage_job(profile_dir, stage_root);
        if (info(job.manifest) != null) {
            var pending = new Job(profile_dir);
            read_manifest(pending);
            if (pending.token == job.token)
                throw new IOError.BUSY("Cannot discard staging referenced by a pending restore");
        }
        if (!directory_exists(job.stage_root)) {
#if !WINDOWS
            sync_parent(job.stage_root);
#endif
            return;
        }
        require_owned_stage(job);
        remove_owned_directory(job, job.stage_root, OWNER_MARKER);
    }

    /** A password change/reset explicitly retires its previous profile keys.
     * Unlike normal restore, that maintenance may remove its own rollback once
     * the replacement is installed. It may not remove any older transaction. */
    public static void cleanup_completed(string profile_dir, string token) throws Error {
        var job = new Job(profile_dir);
        if (!valid_token(token)) throw new IOError.INVALID_ARGUMENT("Invalid completed restore token");
        job.token = token;
        if (!directory_exists(job.profile) || !is_installed(job))
            throw new IOError.INVALID_DATA("The requested restore transaction is not installed");
        sync_tree(job.profile);
        var owned_paths = new Gee.ArrayList<string>();
        foreach (string path in new string[] { job.stage_root, job.rollback }) {
            if (!directory_exists(path)) continue;
            string marker = path == job.stage_root ? OWNER_MARKER : ROLLBACK_MARKER;
            if (!owned_by(job, Path.build_filename(path, marker)))
                throw new IOError.INVALID_DATA("Completed restore artifact ownership is invalid");
            owned_paths.add(path);
        }
        foreach (string path in owned_paths)
            remove_owned_directory(job, path, path == job.stage_root ? OWNER_MARKER : ROLLBACK_MARKER);
#if !WINDOWS
        // Also finish a previous unlink whose parent synchronization failed.
        sync_directory(job.parent);
#endif
    }

    /** Only for an explicitly requested factory reset/panic wipe, offline under
     * ProfileLock. Normal restore never deletes a rollback. Other profiles and
     * unmarked directories are untouched; actual deletion errors propagate. */
    public static void cleanup_owned_artifacts(string profile_dir) throws Error {
        var job = new Job(profile_dir);
        bool pending = info(job.manifest) != null;
        if (pending) read_manifest(job);
        string? pending_token = pending ? job.token : null;
        var owned_paths = new Gee.ArrayList<string>();
        var children = File.new_for_path(job.parent).enumerate_children(
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        string rollback_prefix = "." + job.basename + "-restore-rollback-";
        while ((child = children.next_file()) != null) {
            string name = child.get_name();
            bool stage = name.has_prefix(STAGE_PREFIX);
            if (!stage && !name.has_prefix(rollback_prefix)) continue;
            job.token = name.substring(stage ? STAGE_PREFIX.length : rollback_prefix.length);
            if (!valid_token(job.token)) continue;
            string path = Path.build_filename(job.parent, name);
            if (child.get_is_symlink() || child.get_file_type() != FileType.DIRECTORY) {
                if (pending_token == job.token) throw new IOError.INVALID_DATA("Pending restore artifact is not a real directory");
                continue;
            }
            try {
                if (owned_by(job, Path.build_filename(path, stage ? OWNER_MARKER : ROLLBACK_MARKER))) {
                    owned_paths.add(path);
                } else if (pending_token == job.token) {
                    throw new IOError.INVALID_DATA("Pending restore artifact has mismatched ownership");
                }
            } catch (Error e) {
                if (pending_token == job.token) throw e;
                // A similarly named directory is not proof of ownership.
            }
        }
        children.close();
        foreach (string path in owned_paths) {
            string name = Path.get_basename(path);
            bool stage = name.has_prefix(STAGE_PREFIX);
            job.token = name.substring(stage ? STAGE_PREFIX.length : rollback_prefix.length);
            remove_owned_directory(job, path, stage ? OWNER_MARKER : ROLLBACK_MARKER);
        }
#if !WINDOWS
        sync_directory(job.parent);
#endif
        if (pending) {
            read_manifest(job);
            delete_manifest(job);
        }
    }
}

}
