namespace Dino.Security {

// These operations are deliberately applied in a new process, under the same
// ProfileLock as normal startup. No running database or worker may recreate data.
public class ProfileDeletion : Object {
#if !WINDOWS
    [CCode (cname = "dino_profile_restore_sync_parent", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void sync_parent_native(string path) throws Error;
    [CCode (cname = "dino_profile_restore_sync_directory", cheader_filename = "security/profile_restore_sync.h")]
    private static extern void sync_directory_native(string path) throws Error;
#endif

    /** Confirm namespace updates after an unlink, including a retry where that
     * entry is already absent. Windows checked deletion protects process-crash
     * retry, but does not promise the POSIX directory-fsync power-loss boundary.
     * Win32's documented volume flush would require administrator privileges. */
    internal static void sync_deleted_parent(string path) throws Error {
#if !WINDOWS
        sync_parent_native(path);
#endif
    }

    internal static void delete_entry(File file, Cancellable? cancellable = null) throws Error {
        string? path = file.get_path();
        if (path == null) throw new IOError.INVALID_ARGUMENT("Profile cleanup requires a local path");
        file.delete(cancellable);
        sync_deleted_parent((!) path);
    }

    private static string request_path(string profile) throws Error {
        if (!Path.is_absolute(profile) || Path.get_dirname(profile) == profile) {
            throw new IOError.INVALID_ARGUMENT("Invalid profile deletion directory");
        }
        return Path.build_filename(Path.get_dirname(profile),
            "." + Path.get_basename(profile) + "-delete-pending");
    }

    public static void schedule(string profile, bool panic) throws Error {
        string path = request_path(profile);
        File file = File.new_for_path(path);
        if (file.query_exists() || FileUtils.test(path, FileTest.IS_SYMLINK)) {
            throw new IOError.EXISTS("A profile deletion is already pending");
        }
        string contents = panic ? "1\npanic\n" : "1\nfactory\n";
        FileUtils.set_contents_full(path, contents, -1,
            FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
    }

    public static bool has_pending(string profile) throws Error {
        string path = request_path(profile);
        return File.new_for_path(path).query_exists() || FileUtils.test(path, FileTest.IS_SYMLINK);
    }

    public static bool apply_pending(string profile, string configuration,
                                    string cache, string temporary_directory) throws Error {
        string path = request_path(profile);
        File request = File.new_for_path(path);
        FileInfo entry;
        try {
            entry = request.query_info("standard::type,standard::size",
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) {
            return false;
        }
        if (entry.get_file_type() != FileType.REGULAR || entry.get_size() > 32) {
            throw new IOError.INVALID_DATA("Invalid pending profile deletion");
        }
        string contents;
        FileUtils.get_contents(path, out contents);
        if (contents != "1\npanic\n" && contents != "1\nfactory\n") {
            throw new IOError.INVALID_DATA("Unknown profile deletion operation");
        }
        // Abort staged operations first: otherwise an old restore could bring
        // the deleted identity back on the next application startup.
        ProfileRestore.cleanup_owned_artifacts(profile);
        ProfileMaintenance.cancel_pending(profile);
        cleanup_backup_stages(profile, temporary_directory);
        delete_tree(File.new_for_path(profile));
        delete_tree(File.new_for_path(configuration));
        delete_tree(File.new_for_path(cache));
        // Restore/request/backup cleanup may have failed after unlink in an
        // earlier process. Confirm all surviving namespace parents before the
        // final intent disappears, even if no matching artifact was found now.
        sync_deleted_parent(path);
#if !WINDOWS
        sync_directory_native(temporary_directory);
#endif
        try {
            delete_entry(request);
        } catch (Error e) {
            // A directory fsync can fail after request.unlink succeeded. Keep
            // retry intent rather than presenting an uncertain result as done.
            if (!request.query_exists()) {
                try {
                    FileUtils.set_contents_full(path, contents, -1,
                        FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
                } catch (Error restore_error) {
                    throw new IOError.FAILED("Deletion intent could not be restored after '%s': %s", e.message, restore_error.message);
                }
            }
            throw e;
        }
        return true;
    }

    /** Only these caches can be regenerated while the application is running.
     * Recordings, plaintext leases, TLS bundles, pending links and unknown
     * entries have independent lifetimes and must remain untouched. */
    public static int64 clear_disposable_caches(string directory, Cancellable? cancellable = null) throws Error {
        File root = File.new_for_path(directory);
        FileInfo entry;
        try {
            entry = root.query_info(FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable);
        } catch (IOError.NOT_FOUND e) {
            return 0;
        }
        if (entry.get_file_type() != FileType.DIRECTORY)
            throw new IOError.INVALID_ARGUMENT("Disposable cache root must be a real directory");
        int64 bytes = 0;
        foreach (string name in new string[] { "avatars", "providers" }) {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            bytes += delete_tree(root.get_child(name), cancellable);
        }
        return bytes;
    }

    // Checked deletion also powers cache cleanup. Never follow directory links.
    public static int64 delete_tree(File file, Cancellable? cancellable = null) throws Error {
        FileInfo entry;
        try {
            entry = file.query_info("standard::type,standard::size",
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable);
        } catch (IOError.NOT_FOUND e) {
            string? path = file.get_path();
            if (path != null) sync_deleted_parent((!) path);
            return 0;
        }
        int64 bytes = 0;
        if (entry.get_file_type() == FileType.DIRECTORY) {
            bytes = delete_contents((!)file.get_path(), cancellable);
        } else {
            bytes = entry.get_size();
        }
        delete_entry(file, cancellable);
        return bytes;
    }

    public static int64 delete_contents(string directory, Cancellable? cancellable = null) throws Error {
        File root = File.new_for_path(directory);
        FileEnumerator entries;
        try {
            if (root.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable) == FileType.SYMBOLIC_LINK) {
                throw new IOError.INVALID_ARGUMENT("Refusing to clear a directory through a symbolic link");
            }
            entries = root.enumerate_children(FileAttribute.STANDARD_NAME,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable);
        } catch (IOError.NOT_FOUND e) {
            return 0;
        }
        int64 bytes = 0;
        FileInfo? entry;
        while ((entry = entries.next_file(cancellable)) != null) {
            bytes += delete_tree(root.get_child(entry.get_name()), cancellable);
        }
        entries.close(cancellable);
        return bytes;
    }

    /** Remove one completed or failed backup's owned staging directory. Keep
     * its ownership marker until all payload deletion has succeeded, so a
     * later retry or profile wipe can still identify an interrupted cleanup. */
    public static void cleanup_backup_stage(string profile, string stage_path) throws Error {
        const string prefix = "dinox-backup-stage-";
        string name = Path.get_basename(stage_path);
        if (!Path.is_absolute(profile) || !Path.is_absolute(stage_path) ||
                !name.has_prefix(prefix) || !Uuid.string_is_valid(name.substring(prefix.length))) {
            throw new IOError.INVALID_ARGUMENT("Invalid backup staging directory");
        }
        File stage = File.new_for_path(stage_path);
        FileInfo entry;
        try {
            entry = stage.query_info(FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        } catch (IOError.NOT_FOUND e) {
            sync_deleted_parent(stage_path);
            return;
        }
        if (entry.get_file_type() != FileType.DIRECTORY) {
            throw new IOError.INVALID_DATA("Backup staging root is not a directory");
        }
        File marker = stage.get_child(".dinox-backup-owner");
        var marker_info = marker.query_info("standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (marker_info.get_file_type() != FileType.REGULAR || marker_info.get_size() > 32768) {
            throw new IOError.INVALID_DATA("Invalid backup staging ownership marker");
        }
        string owner;
        FileUtils.get_contents((!) marker.get_path(), out owner);
        if (owner != profile) throw new IOError.PERMISSION_DENIED("Backup staging belongs to another profile");
        delete_owned_backup_stage(stage, marker, owner);
    }

    private static void cleanup_backup_stages(string profile, string temporary_directory) throws Error {
        File temporary = File.new_for_path(temporary_directory);
        var entries = temporary.enumerate_children("standard::name,standard::type",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? entry;
        const string prefix = "dinox-backup-stage-";
        while ((entry = entries.next_file()) != null) {
            string name = entry.get_name();
            if (entry.get_file_type() != FileType.DIRECTORY || !name.has_prefix(prefix) ||
                    !Uuid.string_is_valid(name.substring(prefix.length))) continue;
            File stage = temporary.get_child(name);
            File marker = stage.get_child(".dinox-backup-owner");
            string owner;
            try {
                var info = marker.query_info("standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (info.get_file_type() != FileType.REGULAR || info.get_size() > 32768) continue;
                FileUtils.get_contents((!)marker.get_path(), out owner);
            } catch (IOError.NOT_FOUND e) {
                // An unrelated/incomplete directory is never assumed to be ours.
                continue;
            }
            if (owner == profile) delete_owned_backup_stage(stage, marker, owner);
        }
        entries.close();
#if !WINDOWS
        sync_directory_native(temporary_directory);
#endif
    }

    private static void delete_owned_backup_stage(File stage, File marker, string owner) throws Error {
        var children = stage.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file()) != null) {
            if (child.get_name() != ".dinox-backup-owner")
                delete_tree(stage.get_child(child.get_name()));
        }
        children.close();
        // Payload deletions have all reached their POSIX directory boundary.
        // Retain ownership until this point so a failed wipe remains retryable.
        try {
            delete_entry(marker);
            delete_entry(stage);
        } catch (Error e) {
            if (stage.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
                FileUtils.set_contents_full((!) marker.get_path(), owner, -1,
                    FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
            }
            throw e;
        }
    }
}

}
