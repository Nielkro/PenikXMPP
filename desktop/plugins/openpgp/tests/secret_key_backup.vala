/* Real GnuPG regression tests. Every operation uses a fresh, private test home
 * in a child process; no DinoX profile or operating-system keyring is used. */
namespace OpenPgp.Test {

class SecretKeyBackupTest : Gee.TestCase {
    private const string BACKUP_CODE = "TWNK-KD5Y-MT3T-E1GS-DRDB-KVTW";
    private delegate void KeyringTest(BackupKeyringFixture fixture) throws GLib.Error;

    public SecretKeyBackupTest() {
        base("SecretKeyBackup");
        add_test("canonical_code", test_canonical_code);
        add_test("protected_export_and_cross_client_restore", test_protected_export);
        add_test("cancelled_unlock_preserves_key", test_cancelled_unlock);
        add_test("wrong_unlock_can_be_retried", test_wrong_unlock);
        add_test("legacy_lowercase_backup_restores", test_legacy_lowercase);
        add_test("partial_multi_key_restore_imports_missing_key", test_multi_key_restore);
        add_test("wrong_code_and_public_data_are_rejected", test_invalid_backup);
        add_test("missing_home_never_uses_system_keyring", test_missing_home);
    }

    private void test_canonical_code() {
        assert(GPGHelper.normalize_xep0373_backup_code(BACKUP_CODE) == BACKUP_CODE);
        assert(GPGHelper.normalize_xep0373_backup_code(" twnk kd5y mt3t e1gs drdb kvtw\r\n") == BACKUP_CODE);
        assert(GPGHelper.normalize_xep0373_backup_code("TWNK-KD5Y-MT3T-E1GS-DRDB-KVT0") == "");
        assert(GPGHelper.normalize_xep0373_backup_code("TWNK-KD5Y-MT3T-E1GS-DRDB-KVTO") == "");
        assert(GPGHelper.normalize_xep0373_backup_code("TWNK-KD5Y") == "");
    }

    private void run_isolated(owned KeyringTest test) {
        if (!GLib.Test.subprocess()) {
            if (Environment.find_program_in_path("gpg") == null || Environment.find_program_in_path("gpgconf") == null) {
                GLib.Test.skip("GnuPG tools are required for isolated backup regression tests");
                return;
            }
            GLib.Test.trap_subprocess(null, 45000000, GLib.TestSubprocessFlags.DEFAULT);
            GLib.Test.trap_assert_passed();
            return;
        }
        BackupKeyringFixture? fixture = null;
        try {
            fixture = new BackupKeyringFixture();
            test((!) fixture);
        } catch (GLib.Error e) {
            GLib.Test.message("Isolated backup test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            GPGHelper.clear_passphrases();
            if (fixture != null) ((!) fixture).cleanup();
        }
    }

    private void test_protected_export() {
        run_isolated((fixture) => {
            string fingerprint = fixture.generate_key("xmpp:account-a@example.test", "isolated-original-passphrase", true);
            fixture.stop_agent();
            var provider = new BackupPassphraseProvider("isolated-original-passphrase");
            GPGHelper.set_passphrase_provider(provider);
            string payload = (!) GPGHelper.export_and_encrypt_secret_key(fingerprint, BACKUP_CODE.down());
            assert(provider.calls == 1);
            assert(provider.fingerprint == fingerprint);
            assert(provider.operation == "export");

            string encrypted = fixture.write_payload("backup.pgp", payload);
            string plaintext = fixture.path("secret.pgp");
            fixture.gpg({ "--decrypt", "--output", plaintext, encrypted }, BACKUP_CODE);
            string packets = fixture.gpg({ "--list-packets", plaintext });
            assert(!packets.contains("S2K"));
            assert(!packets.contains("protected"));

            // Exporting must leave the original primary key and encryption
            // subkey protected, even after the backup-specific clone is gone.
            GPGHelper.clear_passphrases();
            fixture.stop_agent();
            assert(GPGHelper.key_requires_passphrase(fingerprint));
            assert(GPGHelper.get_private_key(fingerprint) != null);

            fixture.select_new_home();
            var restored = GPGHelper.decrypt_and_import_secret_key_with_result(payload, BACKUP_CODE);
            assert(restored.imported && !restored.already_present);
            assert(restored.key_info.secret_fingerprints.contains(fingerprint));
            assert(GPGHelper.get_private_key(fingerprint) != null);
            assert(!GPGHelper.key_requires_passphrase(fingerprint));
            string generated_code = GPGHelper.generate_xep0373_backup_code();
            assert(generated_code == GPGHelper.normalize_xep0373_backup_code(generated_code));
            assert(generated_code.length == 29);
        });
    }

    private void test_cancelled_unlock() {
        run_isolated((fixture) => {
            string fingerprint = fixture.generate_key("xmpp:cancel@example.test", "isolated-original-passphrase");
            fixture.stop_agent();
            var provider = new BackupPassphraseProvider(null);
            GPGHelper.set_passphrase_provider(provider);
            bool cancelled = false;
            try {
                GPGHelper.export_and_encrypt_secret_key(fingerprint, BACKUP_CODE);
            } catch (IOError e) {
                cancelled = e is IOError.CANCELLED;
            }
            assert(cancelled && provider.calls == 1);
            assert(GPGHelper.get_private_key(fingerprint) != null);
            assert(GPGHelper.key_requires_passphrase(fingerprint));
        });
    }

    private void test_wrong_unlock() {
        run_isolated((fixture) => {
            string fingerprint = fixture.generate_key("xmpp:retry@example.test", "isolated-original-passphrase");
            fixture.stop_agent();
            var wrong = new BackupPassphraseProvider("isolated-wrong-passphrase");
            GPGHelper.set_passphrase_provider(wrong);
            bool failed = false;
            try {
                GPGHelper.export_and_encrypt_secret_key(fingerprint, BACKUP_CODE);
            } catch (GLib.Error e) {
                failed = true;
            }
            assert(failed && wrong.calls == 1);
            var correct = new BackupPassphraseProvider("isolated-original-passphrase");
            GPGHelper.set_passphrase_provider(correct);
            string? payload = GPGHelper.export_and_encrypt_secret_key(fingerprint, BACKUP_CODE);
            assert(payload != null && correct.calls == 1);
            assert(GPGHelper.get_private_key(fingerprint) != null);
        });
    }

    private void test_legacy_lowercase() {
        run_isolated((fixture) => {
            string fingerprint = fixture.generate_key("xmpp:legacy-backup@example.test");
            string payload = fixture.create_backup({ fingerprint }, BACKUP_CODE.down());
            fixture.select_new_home();
            var restored = GPGHelper.decrypt_and_import_secret_key_with_result(payload, BACKUP_CODE);
            assert(restored.imported && !restored.already_present);
            assert(restored.key_info.secret_fingerprints.contains(fingerprint));
            assert(GPGHelper.get_private_key(fingerprint) != null);
        });
    }

    private void test_multi_key_restore() {
        run_isolated((fixture) => {
            string first = fixture.generate_key("xmpp:first@example.test");
            string second = fixture.generate_key("xmpp:second@example.test");
            string payload = fixture.create_backup({ first, second }, BACKUP_CODE);
            fixture.gpg({ "--delete-secret-and-public-key", second });
            GPGHelper.invalidate_secret_keys_cache();
            assert(GPGHelper.get_private_key(second) == null);
            var available = new Gee.HashSet<string>();
            available.add(first);
            var restored = GPGHelper.decrypt_and_import_secret_key_with_result(payload, BACKUP_CODE, available);
            assert(restored.imported && !restored.already_present);
            assert(restored.key_info.secret_fingerprints.size == 2);
            assert(GPGHelper.get_private_key(first) != null);
            assert(GPGHelper.get_private_key(second) != null);

            available.add(second);
            var present = GPGHelper.decrypt_and_import_secret_key_with_result(payload, BACKUP_CODE, available);
            assert(!present.imported && present.already_present);
            assert(present.key_info.secret_fingerprints.size == 2);
        });
    }

    private void test_invalid_backup() {
        run_isolated((fixture) => {
            string fingerprint = fixture.generate_key("xmpp:invalid-backup@example.test");
            string payload = fixture.create_backup({ fingerprint }, BACKUP_CODE);
            fixture.select_new_home();
            bool rejected = false;
            try {
                GPGHelper.decrypt_and_import_secret_key_with_result(payload, "TWNK-KD5Y-MT3T-E1GS-DRDB-KVTX");
            } catch (GLib.Error e) {
                rejected = true;
            }
            assert(rejected && GPGHelper.get_private_key(fingerprint) == null);

            fixture.select_home(0);
            string public_path = fixture.path("public-key.pgp");
            fixture.gpg({ "--output", public_path, "--export", fingerprint });
            string public_backup = fixture.encrypt_file(public_path, BACKUP_CODE);
            fixture.select_home(1);
            rejected = false;
            try {
                GPGHelper.decrypt_and_import_secret_key_with_result(public_backup, BACKUP_CODE);
            } catch (GLib.Error e) {
                rejected = true;
            }
            assert(rejected && GPGHelper.get_public_key(fingerprint) == null);
        });
    }

    private void test_missing_home() {
        run_isolated((fixture) => {
            GPGHelper.set_homedir_path_for_tests(null);
            bool rejected = false;
            try {
                GPGHelper.generate_xep0373_backup_code();
            } catch (GLib.Error e) {
                rejected = e.message.contains("keyring directory is unavailable");
            }
            assert(rejected);
            string invalid_home = fixture.path("not-a-directory");
            FileUtils.set_contents(invalid_home, "not a keyring");
            GPGHelper.set_homedir_path_for_tests(invalid_home);
            rejected = false;
            try {
                GPGHelper.generate_xep0373_backup_code();
            } catch (GLib.Error e) {
                rejected = e.message.contains("keyring directory is unavailable");
            }
            assert(rejected);
            fixture.select_home(0);
            assert(GPGHelper.get_keylist(null, true).size == 0);
        });
    }
}

private class BackupPassphraseProvider : Object, GPGHelper.PassphraseProvider {
    private string? passphrase;
    public int calls = 0;
    public string fingerprint = "";
    public string operation = "";
    public BackupPassphraseProvider(string? passphrase) { this.passphrase = passphrase; }
    public string? request_passphrase(string fingerprint, string operation) {
        calls++;
        this.fingerprint = fingerprint;
        this.operation = operation;
        return passphrase;
    }
}

private class BackupKeyringFixture : Object {
    private string root;
    private string home;
    private string binary;
    private Gee.ArrayList<string> homes = new Gee.ArrayList<string>();

    public BackupKeyringFixture() throws GLib.Error {
        root = DirUtils.make_tmp("dx-pgp-test-XXXXXX");
        home = Path.build_filename(root, "keyring-0");
        if (DirUtils.create(home, 0700) != 0) throw new IOError.FAILED("Cannot create isolated GnuPG test home");
        homes.add(home);
        Environment.set_variable("GNUPGHOME", home, true);
        binary = GPGHelper.get_binary_path();
        GPGHelper.set_homedir_path_for_tests(home);
        GPGHelper.clear_passphrases();
    }

    public string path(string filename) { return Path.build_filename(root, filename); }

    private string[] to_command_array(Gee.Collection<string> values) {
        string[] result = new string[values.size];
        int i = 0;
        foreach (string value in values) result[i++] = value;
        return result;
    }

    public string gpg(string[] args, string passphrase = "") throws GLib.Error {
        var command = new Gee.ArrayList<string>();
        command.add(binary);
        command.add("--no-options");
        command.add("--homedir");
        command.add(home);
        command.add("--batch");
        command.add("--yes");
        command.add("--pinentry-mode");
        command.add("loopback");
        command.add("--passphrase-fd");
        command.add("0");
        foreach (string arg in args) command.add(arg);
        // Match the production argv conversion and const-correct launcher;
        // generic Gee.to_array() is not a native null-terminated string vector.
        var process = Dino.Plugins.OpenPgp.new_subprocess(to_command_array(command),
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        string? stdout_str;
        string? stderr_str;
        process.communicate_utf8(passphrase + "\n", null, out stdout_str, out stderr_str);
        if (!process.get_successful()) throw new IOError.FAILED("Isolated GnuPG fixture command failed (exit %d)".printf(process.get_exit_status()));
        return stdout_str ?? "";
    }

    public string generate_key(string uid, string passphrase = "", bool encryption_subkey = false) throws GLib.Error {
        gpg({ "--quick-generate-key", uid, "ed25519", "sign", "1d" }, passphrase);
        var keys = GPGHelper.get_keylist(uid, true);
        if (keys.size != 1) throw new IOError.FAILED("Cannot identify the isolated GnuPG test key");
        if (encryption_subkey) gpg({ "--quick-add-key", keys[0].fpr, "cv25519", "encr", "1d" }, passphrase);
        return keys[0].fpr;
    }

    public string write_payload(string filename, string payload) throws GLib.Error {
        string output = path(filename);
        GPGHelper.secure_write_data(output, Base64.decode(payload));
        return output;
    }

    public string create_backup(string[] fingerprints, string code) throws GLib.Error {
        string secret = path("fixture-secret-" + Uuid.string_random());
        var args = new Gee.ArrayList<string>();
        args.add("--output"); args.add(secret); args.add("--export-secret-keys");
        foreach (string fingerprint in fingerprints) args.add(fingerprint);
        gpg(to_command_array(args));
        return encrypt_file(secret, code);
    }

    public string encrypt_file(string input, string code) throws GLib.Error {
        string output = path("fixture-encrypted-" + Uuid.string_random());
        gpg({ "--symmetric", "--cipher-algo", "AES256", "--no-symkey-cache", "--output", output, input }, code);
        uint8[] data;
        FileUtils.get_data(output, out data);
        return Base64.encode(data);
    }

    public void select_new_home() throws GLib.Error {
        string next_home = Path.build_filename(root, "keyring-%d".printf(homes.size));
        if (DirUtils.create(next_home, 0700) != 0) throw new IOError.FAILED("Cannot create isolated restore test home");
        homes.add(next_home);
        select_home(homes.size - 1);
    }

    public void select_home(int index) {
        home = homes[index];
        GPGHelper.clear_passphrases();
        GPGHelper.set_homedir_path_for_tests(home);
    }

    private string gpgconf_binary() {
        string sibling = Path.build_filename(Path.get_dirname(binary),
#if WINDOWS
            "gpgconf.exe"
#else
            "gpgconf"
#endif
        );
        return FileUtils.test(sibling, FileTest.EXISTS) ? sibling : "gpgconf";
    }

    public void stop_agent() throws GLib.Error {
        var process = Dino.Plugins.OpenPgp.new_subprocess({ gpgconf_binary(), "--homedir", home, "--kill", "all" },
            SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        process.wait_check();
    }

    public void cleanup() {
        try {
            foreach (string keyring in homes) {
                home = keyring;
                stop_agent();
            }
            delete_tree(File.new_for_path(root));
        } catch (GLib.Error e) {
            GLib.Test.message("Cannot clean up isolated GnuPG fixture: %s", e.message);
            GLib.Test.fail();
        }
    }

    private void delete_tree(File directory) throws GLib.Error {
        var enumerator = directory.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? info;
        while ((info = enumerator.next_file()) != null) {
            var child = directory.get_child(((!) info).get_name());
            if (((!) info).get_file_type() == FileType.DIRECTORY) delete_tree(child);
            else if (((!) info).get_file_type() == FileType.SYMBOLIC_LINK) child.delete();
            else GPGHelper.secure_delete_file(child.get_path());
        }
        enumerator.close();
        directory.delete();
    }
}

}
