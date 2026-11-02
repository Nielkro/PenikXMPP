namespace Dino.Security {

// Database files in destination must already have been written using the
// database backup API. Never combine a copied live DB with an unrelated WAL.
public class ProfileSnapshot : Object {
    public static void copy_files(string profile, string destination,
                                  Cancellable? cancellable = null) throws Error {
        copy_directory(File.new_for_path(profile), File.new_for_path(destination),
                       true, cancellable);
    }

    private static void copy_directory(File source, File destination, bool root,
                                       Cancellable? cancellable) throws Error {
        var entries = source.enumerate_children(
            "standard::name,standard::type,standard::is-symlink",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable);
        FileInfo? entry;
        while ((entry = entries.next_file(cancellable)) != null) {
            string name = entry.get_name();
            File from = source.get_child(name);
            File to = destination.get_child(name);
            if (root && name.has_suffix(".db")) {
                if (entry.get_is_symlink() ||
                        to.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) != FileType.REGULAR) {
                    throw new IOError.FAILED("No consistent snapshot available for database %s", name);
                }
                continue;
            }
            if (root && (name.has_suffix(".db-wal") || name.has_suffix(".db-shm") ||
                         name.has_suffix(".db-journal") || name == ".restore_pending")) {
                continue;
            }
            if (entry.get_is_symlink()) {
                throw new IOError.FAILED("Profile contains a symbolic link that cannot be restored safely: %s", name);
            }
            if (entry.get_file_type() == FileType.DIRECTORY) {
                if (DirUtils.create_with_parents((!)to.get_path(), 0700) != 0) {
                    throw new IOError.FAILED("Could not create backup directory");
                }
                copy_directory(from, to, false, cancellable);
            } else if (entry.get_file_type() == FileType.REGULAR) {
                from.copy(to, FileCopyFlags.NOFOLLOW_SYMLINKS, cancellable);
            }
            // Process-local sockets, FIFOs and device nodes are not profile data.
        }
        entries.close(cancellable);
    }
}

}
