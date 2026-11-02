using GLib;

namespace Dino.Security {

internal delegate string? LegacyKeyLookup() throws Error;

public class KeyManager : Object {
    private const string SCHEMA_NAME = "im.dino.omemo.database.key";
    private const string KEY_ATTRIBUTE = "db_name";
    private const string KEY_VALUE = "omemo.db";

    /**
     * Get or create the OMEMO database encryption key.
     * New profiles store the key at <data_dir>/dinox/omemo.key.
     * Linux can also recover an existing legacy key from the secrets service.
     * An existing database must never receive a newly generated replacement key.
     */
    public static string get_or_create_db_key() throws Error {
#if WINDOWS
        return get_or_create_db_key_for_directory(get_key_dir(), null);
#else
        return get_or_create_db_key_for_directory(get_key_dir(), try_secrets_service);
#endif
    }

    // The explicit directory and lookup keep recovery tests away from the real
    // user profile and keyring. Production uses the same decision path.
    internal static string get_or_create_db_key_for_directory(string key_dir,
            LegacyKeyLookup? legacy_lookup) throws Error {
        // Always try file-based key first (works everywhere, required on Windows)
        string? file_key = try_file_based_key(key_dir);
        if (file_key != null) {
            return file_key;
        }

        string omemo_db_path = Path.build_filename(key_dir, "omemo.db");
        if (!FileUtils.test(omemo_db_path, FileTest.EXISTS)) {
            return generate_new_file_key(key_dir);
        }

        // Legacy migration path: only query the secrets service when an OMEMO
        // database already exists without the file key. Fresh profiles must not
        // trigger a desktop keyring prompt. Windows has no legacy lookup.
        if (legacy_lookup != null) {
            try {
                string? secret_key = legacy_lookup();
                if (secret_key != null && secret_key.strip().length > 0) {
                    ensure_file_key(key_dir, secret_key);
                    return secret_key;
                }
            } catch (Error e) {
                warning("KeyManager: Legacy secrets-service key recovery failed: %s", e.message);
            }
        }

        throw new IOError.FAILED("OMEMO database exists at %s but key file is missing. Cannot recover without the legacy secrets-service key.", omemo_db_path);
    }

    /**
     * Try to read existing key from file, or return null if no key file exists.
     * Throws if key file exists but is unreadable (to prevent data loss).
     */
    private static string? try_file_based_key(string key_dir) throws Error {
        string key_file_path = Path.build_filename(key_dir, "omemo.key");
        File key_file = File.new_for_path(key_file_path);

        if (key_file.query_exists()) {
            try {
                string content;
                if (FileUtils.get_contents(key_file_path, out content)) {
                    string key_str = content.strip();
                    if (key_str.length > 0) {
                        debug("KeyManager: Loaded key from file %s", key_file_path);
                        return key_str;
                    }
                }
            } catch (Error e) {
                // CRITICAL: If we can't read an existing key file, we MUST NOT generate a new one
                // as this would make the existing omemo.db unreadable!
                warning("KeyManager: Could not read existing key file: %s", e.message);
                throw new IOError.FAILED("Cannot read existing OMEMO key file at %s. Database would become inaccessible.", key_file_path);
            }
        }

        return null;
    }

    /**
     * Persist a key that was recovered from libsecret as omemo.key.
     * This keeps package formats that cannot share the same keyring namespace
     * from orphaning an existing omemo.db.
     */
    private static void ensure_file_key(string key_dir, string key) {
        string key_file_path = Path.build_filename(key_dir, "omemo.key");

        if (FileUtils.test(key_file_path, FileTest.EXISTS)) {
            return;
        }

        try {
            if (!FileUtils.test(key_dir, FileTest.EXISTS)) {
                DirUtils.create_with_parents(key_dir, 0700);
            }

            File key_file = File.new_for_path(key_file_path);
            key_file.replace_contents(key.data, null, false, FileCreateFlags.PRIVATE, null);
            debug("KeyManager: Migrated secrets service key to %s", key_file_path);
        } catch (Error e) {
            warning("KeyManager: Could not migrate secrets service key to %s: %s", key_file_path, e.message);
        }
    }

#if !WINDOWS
    /**
     * Try to get key from the system secrets service (libsecret / GNOME Keyring).
     * Returns null if no key stored yet, throws if the service is not available.
     */
    private static string? try_secrets_service() throws Error {
        var schema = new Secret.Schema(SCHEMA_NAME, Secret.SchemaFlags.NONE,
            KEY_ATTRIBUTE, Secret.SchemaAttributeType.STRING
        );

        string? password = Secret.password_lookup_sync(schema, null, KEY_ATTRIBUTE, KEY_VALUE);

        if (password != null) {
            debug("KeyManager: Loaded key from secrets service");
            return password;
        }

        // This lookup is only reached for an existing encrypted database.
        // Generating a key here cannot recover it and would persist a wrong key.
        return null;
    }
#endif

    /**
     * Generate a new file-based key and save it.
     * Only allowed when no omemo.db exists yet (to prevent orphaning an existing DB).
     */
    private static string generate_new_file_key(string key_dir) throws Error {
        // Safety check: if omemo.db exists but no key file, we MUST NOT generate a new key
        string omemo_db_path = Path.build_filename(key_dir, "omemo.db");
        if (FileUtils.test(omemo_db_path, FileTest.EXISTS)) {
            throw new IOError.FAILED("OMEMO database exists at %s but key file is missing. Cannot recover — would make database inaccessible.", omemo_db_path);
        }

        // Generate 32 random bytes as hex key using CSPRNG
        uint8[] key_bytes = new uint8[32];
        Crypto.randomize(key_bytes);  // Uses GCrypt CSPRNG, not Mersenne Twister

        StringBuilder hex = new StringBuilder();
        foreach (uint8 b in key_bytes) {
            hex.append_printf("%02x", b);
        }
        string new_key = hex.str;

        // Save to file
        if (!FileUtils.test(key_dir, FileTest.EXISTS)) {
            DirUtils.create_with_parents(key_dir, 0700);
        }
        string key_file_path = Path.build_filename(key_dir, "omemo.key");
        File key_file = File.new_for_path(key_file_path);
        key_file.replace_contents(new_key.data, null, false, FileCreateFlags.PRIVATE, null);

        debug("KeyManager: Generated and saved new key to %s", key_file_path);
        return new_key;
    }

    /**
     * Get the directory for storing key files.
     */
    private static string get_key_dir() {
        string config_dir = Environment.get_user_data_dir();
        return Path.build_filename(config_dir, "dinox");
    }
}

}
