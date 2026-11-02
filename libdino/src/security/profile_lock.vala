namespace Dino.Security {

/** Excludes other processes before any profile unlock, restore or database IO. */
public class ProfileLock : Object {
    public string profile_dir { get; private set; }

    private ProfileLock(string physical_directory) {
        profile_dir = physical_directory;
    }

    /**
     * Acquires the sibling lock of the physically resolved profile directory.
     * Throws IOError.BUSY if another process owns it. The OS releases the lock
     * at process exit; dropping this object or closing the tray cannot release
     * it while database workers are still alive. The lock file is never deleted.
     * A missing profile is deliberately not created before pending restore runs.
     */
    public static ProfileLock acquire(string storage_dir) throws Error {
        return new ProfileLock(acquire_native(storage_dir));
    }

    [CCode (cname = "dino_profile_lock_acquire_native", cheader_filename = "security/profile_lock.h")]
    private static extern string acquire_native(string storage_dir) throws Error;
}

}
