using Gee;
using Gtk;
using Adw;

using Dino.Entities;

extern const string GETTEXT_PACKAGE;
extern const string LOCALE_INSTALL_DIR;

#if WINDOWS
[CCode (cname = "openpgp_fix_windows_stdio", cheader_filename = "gpgme_fix.h")]
extern void openpgp_fix_windows_stdio();
#endif

namespace Dino.Plugins.OpenPgp {

[CCode (cname = "g_subprocess_newv", cheader_filename = "gio/gio.h")]
private extern static Subprocess subprocess_newv_const([CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv, SubprocessFlags flags) throws Error;

#if !WINDOWS
private static bool path_is_in_directory(string path, string directory) {
    string dir_prefix = directory.has_suffix("/") ? directory : directory + "/";
    return path == directory || path.has_prefix(dir_prefix);
}

private static bool should_drop_appimage_library_path(string[] argv) {
    string? appdir = Environment.get_variable("APPDIR");
    if (appdir == null || appdir.length == 0) return false;
    if (Environment.get_variable("APPIMAGE") == null) return false;
    if (argv.length == 0 || argv[0] == null || argv[0].length == 0) return true;

    string? resolved_binary = Path.is_absolute(argv[0]) ? argv[0] : Environment.find_program_in_path(argv[0]);
    return resolved_binary == null || !path_is_in_directory(resolved_binary, appdir);
}
#endif

internal static Subprocess new_subprocess(string[] argv, SubprocessFlags flags) throws Error {
#if WINDOWS
    return subprocess_newv_const(argv, flags);
#else
    var launcher = new SubprocessLauncher(flags);
    if (should_drop_appimage_library_path(argv)) {
        launcher.unsetenv("LD_LIBRARY_PATH");
    }
    return launcher.spawnv(argv);
#endif
}

private const uint GPGCONF_OPERATION_TIMEOUT_SECONDS = 5;

private class BoundedSubprocessTimeoutState : Object {
    private Mutex mutex;
    private bool completed = false;
    private bool timed_out = false;

    public bool is_completed() {
        mutex.lock();
        bool result = completed;
        mutex.unlock();
        return result;
    }

    public bool mark_timed_out() {
        mutex.lock();
        if (completed) {
            mutex.unlock();
            return false;
        }
        timed_out = true;
        mutex.unlock();
        return true;
    }

    public void mark_completed() {
        mutex.lock();
        completed = true;
        mutex.unlock();
    }

    public bool has_timed_out() {
        mutex.lock();
        bool result = timed_out;
        mutex.unlock();
        return result;
    }
}

internal static bool run_bounded_subprocess(string[] argv, string? stdin_data, uint timeout_seconds,
        out int exit_status, out string stderr_str, string log_label) {
    exit_status = -1;
    stderr_str = "";

    try {
        var subprocess = new_subprocess(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
        var timeout_state = new BoundedSubprocessTimeoutState();
        Thread<void*>? timeout_thread = null;
        if (timeout_seconds > 0) {
            timeout_thread = new Thread<void*>("openpgp-bounded-subprocess-timeout", () => {
                int64 deadline = get_monotonic_time() + (int64) timeout_seconds * 1000000;
                while (!timeout_state.is_completed() && get_monotonic_time() < deadline) {
                    Thread.usleep(100000);
                }
                if (timeout_state.mark_timed_out()) {
                    debug("OpenPGP: %s timed out after %u seconds; terminating subprocess", log_label, timeout_seconds);
                    subprocess.force_exit();
                }
                return null;
            });
        }

        try {
            string? captured_stderr = null;
            subprocess.communicate_utf8(stdin_data ?? "", null, null, out captured_stderr);
            stderr_str = captured_stderr ?? "";
        } catch (Error e) {
            if (timeout_state.has_timed_out()) {
                exit_status = -2;
                stderr_str = "%s timed out".printf(log_label);
                return false;
            }
            stderr_str = e.message;
            return false;
        } finally {
            timeout_state.mark_completed();
            if (timeout_thread != null) {
                ((!) timeout_thread).join();
            }
        }

        if (timeout_state.has_timed_out()) {
            exit_status = -2;
            stderr_str = "%s timed out".printf(log_label);
            return false;
        }

        exit_status = subprocess.get_if_exited() ? subprocess.get_exit_status() : -1;
        return exit_status == 0;
    } catch (Error e) {
        stderr_str = e.message;
        return false;
    }
}

public class Plugin : Plugins.RootInterface, GPGHelper.PassphraseProvider, Object {
    public Dino.Application app;
    public Database db;
    public HashMap<Account, Module> modules = new HashMap<Account, Module>(Account.hash_func, Account.equals_func);
    public Xep0373KeyManager? xep0373_manager = null;

    private EncryptionListEntry list_entry;
    private ContactDetailsProvider contact_details_provider;
    private string? env_gnupg_home = null;
    private string? gpgconf_binary = null;

    private string resolve_gpgconf_binary(string? gpg_bindir = null) {
#if WINDOWS
        string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
        if (exe_dir != null && exe_dir.length > 0) {
            string bundled_gpgconf = Path.build_filename(exe_dir, "bin", "gpgconf.exe");
            if (FileUtils.test(bundled_gpgconf, FileTest.EXISTS)) {
                return GPGHelper.to_windows_path(bundled_gpgconf);
            }
        }

        if (gpg_bindir != null && gpg_bindir.length > 0) {
            string candidate = Path.build_filename(gpg_bindir, "gpgconf.exe");
            if (FileUtils.test(candidate, FileTest.EXISTS)) {
                return GPGHelper.to_windows_path(candidate);
            }
        }
#endif
        string? found = Environment.find_program_in_path("gpgconf");
        return found ?? "gpgconf";
    }

    public void registered(Dino.Application app) {
        this.app = app;

        string locales_dir = app.search_path_generator != null
            ? ((!) app.search_path_generator).get_locale_path(GETTEXT_PACKAGE, LOCALE_INSTALL_DIR)
            : LOCALE_INSTALL_DIR;
        internationalize(GETTEXT_PACKAGE, locales_dir);

        // Use an app-scoped GnuPG keyring so that Panic-Wipe can safely destroy all OpenPGP material
        // without touching the user's global ~/.gnupg keyring.
        string openpgp_gnupg_home = Path.build_filename(Application.get_storage_dir(), "openpgp", "gnupg");
        if (DirUtils.create_with_parents(openpgp_gnupg_home, 0700) == -1) {
            warning("OpenPGP plugin disabled: could not create keyring dir '%s'", openpgp_gnupg_home);
            return;
        }

        // On Windows (MSYS2), get_storage_dir returns a Unix-style path (/c/...), but native GPG
        // expects Windows-style paths (C:\...). If we set GNUPGHOME to the Unix path, GPG fails.
        string env_gnupg_home = openpgp_gnupg_home;
#if WINDOWS
        string? gpg_bindir = null;
        openpgp_fix_windows_stdio();
        // Force backslashes for Windows paths to ensure native GPG compatibility
        // First handle potential MSYS path conversion if it starts with /c/
        if (openpgp_gnupg_home.has_prefix("/")) {
            if (openpgp_gnupg_home.length > 2 && openpgp_gnupg_home[2] == '/') { // /c/Users...
                env_gnupg_home = GPGHelper.to_windows_path(openpgp_gnupg_home);
            } else {
                 env_gnupg_home = GPGHelper.to_windows_path(openpgp_gnupg_home);
            }
            debug("Relocated GNUPGHOME for Windows: %s -> %s", openpgp_gnupg_home, env_gnupg_home);
        } else {
            // Already starts with Drive letter, just ensure backslashes
            env_gnupg_home = GPGHelper.to_windows_path(openpgp_gnupg_home);
        }

        // Add GPG directory to PATH to ensure gpg-agent and other tools can be found.
        // Packaged Windows builds must prefer the bundled dist/bin tools.  MSYS2 is
        // only a development fallback for local builds from the build tree.
        string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
        if (exe_dir != null && exe_dir.length > 0) {
            string bundled_gpg_bindir = Path.build_filename(exe_dir, "bin");
            string bundled_gpg = Path.build_filename(bundled_gpg_bindir, "gpg.exe");
            if (FileUtils.test(bundled_gpg, FileTest.EXISTS)) {
                gpg_bindir = bundled_gpg_bindir.replace("/", "\\");
            }
        }

        if (gpg_bindir == null && FileUtils.test("C:/msys64/mingw64/bin/gpg.exe", FileTest.EXISTS)) {
            gpg_bindir = "C:\\msys64\\mingw64\\bin";
        }
        
        if (gpg_bindir != null) {
            string old_path = Environment.get_variable("PATH") ?? "";
            // Prepend to PATH so native GPG tools are found first
            Environment.set_variable("PATH", gpg_bindir + ";" + old_path, true);
            debug("Added GPG bin to PATH: %s", gpg_bindir);
        }
        this.gpgconf_binary = resolve_gpgconf_binary(gpg_bindir);
#endif
        this.env_gnupg_home = env_gnupg_home;
        Environment.set_variable("GNUPGHOME", env_gnupg_home, true);


        // Keep GnuPG scoped to DinoX and allow loopback passphrase handling.
        // The OpenPGP manager asks for passphrases in DinoX UI instead of
        // relying on a system pinentry/key manager.
        string gpg_conf_path = Path.build_filename(openpgp_gnupg_home, "gpg.conf");
        string agent_conf_path = Path.build_filename(openpgp_gnupg_home, "gpg-agent.conf");
        bool gpg_agent_config_changed = false;
        try {
             // GnuPG may emit "secure memory" diagnostics on stderr depending on
             // libgcrypt/GPG build options.  DinoX uses an app-scoped GNUPGHOME, so
             // keep this CLI noise out of all OpenPGP subprocesses centrally.
             string gpg_conf = "no-secmem-warning\n";
             string? old_gpg_conf = null;
             if (!FileUtils.get_contents(gpg_conf_path, out old_gpg_conf) || old_gpg_conf != gpg_conf) {
                 FileUtils.set_contents(gpg_conf_path, gpg_conf);
             }

             // Configure gpg-agent for DinoX-scoped loopback operations:
             // 1. Cache passphrases for a reasonable time (8 hours = 28800 seconds)
             // 2. Allow --pinentry-mode loopback for DinoX-managed prompts
             // 3. Disable smart card daemon (not needed, can cause issues)
             StringBuilder config = new StringBuilder();
             config.append("disable-scdaemon\n");
             config.append("default-cache-ttl 28800\n");
             config.append("max-cache-ttl 28800\n");
             config.append("allow-loopback-pinentry\n");

             string? old_agent_conf = null;
             if (!FileUtils.get_contents(agent_conf_path, out old_agent_conf) || old_agent_conf != config.str) {
                 FileUtils.set_contents(agent_conf_path, config.str);
                 gpg_agent_config_changed = true;
             }
        } catch (Error e) {
             debug("Failed to write gpg-agent.conf: %s", e.message);
        }
        
        // Restart gpg-agent in the background so it picks up the app-scoped
        // loopback config without blocking Windows startup.
#if WINDOWS
        if (gpg_agent_config_changed) {
            string env_gnupg_home_for_agent = env_gnupg_home;
            string gpgconf_for_agent = gpgconf_binary ?? resolve_gpgconf_binary(gpg_bindir);
            new Thread<void*>("openpgp-restart-agent", () => {
                string[] kill_args = { gpgconf_for_agent, "--homedir", env_gnupg_home_for_agent, "--kill", "gpg-agent" };
                int exit_status;
                string stderr_str;
                run_bounded_subprocess(kill_args, "", GPGCONF_OPERATION_TIMEOUT_SECONDS, out exit_status, out stderr_str, "gpg-agent config restart");
                if (exit_status == 0) {
                    debug("OpenPGP: Restarted gpg-agent after config change (exit=%d)", exit_status);
                } else {
                    debug("OpenPGP: Failed to restart gpg-agent after config change (exit=%d): %s", exit_status, stderr_str);
                }
                return null;
            });
        }
#endif
        
        // CRITICAL: On Windows, sometimes setting the ENV var isn't enough for the spawned process if environment inheritance is weird,
        // OR GPG defaults to a different "socket dir" than "home dir".
        // We will pass --homedir explicitly in key_management_dialog.vala.

        try {
            this.db = new Database(Path.build_filename(Application.get_storage_dir(), "pgp.db"), app.db_key);
            this.db.clear_contact_legacy_key_announcements();
        } catch (Error e) {
            warning("OpenPGP plugin disabled: %s", e.message);
            return;
        }
        this.list_entry = new EncryptionListEntry(app.stream_interactor, db);
        this.contact_details_provider = new ContactDetailsProvider(app.stream_interactor, db);

        app.plugin_registry.register_encryption_list_entry(list_entry);
        app.plugin_registry.register_encryption_preferences_entry(new PgpPreferencesEntry(this));
        app.plugin_registry.register_contact_details_entry(contact_details_provider);
        app.stream_interactor.module_manager.initialize_account_modules.connect(on_initialize_account_modules);

        Manager.start(app.stream_interactor, db);
        
        // Initialize XEP-0373 key manager for PubSub-based key distribution
        // This enables interoperability with Conversations, Monocles, and other modern clients
        this.xep0373_manager = new Xep0373KeyManager(app.stream_interactor, db);
        debug("OpenPGP: XEP-0373 key manager initialized");
        GPGHelper.set_passphrase_provider(this);
        
        // Connect XEP-0373 manager to the encryption list entry for async key fetching
        this.list_entry.set_xep0373_manager(this.xep0373_manager);
        
        // Connect XEP-0373 manager to the PGP manager for automatic key fetching
        Manager? pgp_manager = app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
        if (pgp_manager != null) {
            pgp_manager.xep0373_manager = this.xep0373_manager;
            pgp_manager.key_state_changed.connect(on_key_trust_state_changed);
            debug("OpenPGP: Connected XEP-0373 manager to PGP manager");
        }
        
        // When XEP-0373 receives a key, store it in the database so it can be used for encryption
        this.xep0373_manager.key_received.connect((account, jid, fingerprint, key_data) => {
            debug("OpenPGP: XEP-0373 key received for %s, fingerprint: %s", jid.to_string(), fingerprint);
            // Store the fingerprint as the contact key
            // XEP-0373 keys are already imported into GPG keyring by xep0373_key_manager
            db.set_contact_key(account, jid.bare_jid, fingerprint, Database.KEY_SOURCE_XEP0373, false);
            Manager? manager = app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
            if (manager != null) {
                manager.mark_xep0373_key_received(account, jid);
                manager.refresh_xep0374_support.begin(account, jid.bare_jid);
                manager.notify_key_state_changed(account, jid.bare_jid);
            }
        });
        this.xep0373_manager.key_cleared.connect((account, jid) => {
            debug("OpenPGP: XEP-0373 key cleared for %s", jid.to_string());
            Manager? manager = app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
            if (manager != null) {
                manager.forget_xep0373_key_refresh(account, jid.bare_jid);
                manager.notify_key_state_changed(account, jid.bare_jid);
            }
        });
        
        // Do not fetch XEP-0373 keys merely because a conversation was restored
        // or opened.  Contact details and encryption selection show cached
        // state; explicit refresh/send paths perform network key discovery.
        
        app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY).add_file_encryptor(new PgpFileEncryptor(app.stream_interactor));
        app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY).add_file_decryptor(new PgpFileDecryptor(app.stream_interactor, db));
        JingleFileHelperRegistry.instance.add_encryption_helper(Encryption.PGP, new JingleFileEncryptionHelperTransferOnly());
    }

    private void on_key_trust_state_changed(Account account, Xmpp.Jid? jid) {
        app.plugin_registry.encryption_trust_changed(Encryption.PGP, account,
            jid != null ? ((!) jid).bare_jid : null);
    }

    public void shutdown() {
        GPGHelper.clear_passphrases();
        if (!GPGHelper.shutdown_workers()) {
            warning("OpenPGP: GPG helper worker did not drain before shutdown");
        }
        stop_gpg_components();
    }

    private void stop_gpg_components() {
        if (env_gnupg_home == null || env_gnupg_home == "") return;

        string[] kill_all_args = { gpgconf_binary ?? resolve_gpgconf_binary(), "--homedir", (!) env_gnupg_home, "--kill", "all" };
        string stderr_str;
        int exit_status;
        run_bounded_subprocess(kill_all_args, "", GPGCONF_OPERATION_TIMEOUT_SECONDS, out exit_status, out stderr_str, "gpgconf shutdown");
        if (exit_status == 0) {
            message("OpenPGP: Stopped app-scoped GnuPG components (exit=%d)", exit_status);
        } else {
            warning("OpenPGP: Failed to stop app-scoped GnuPG components (exit=%d)", exit_status);
        }
    }

    public void rekey_database(string new_key) throws Error {
        if (db != null) {
            db.rekey(new_key);
        }
    }

    public void checkpoint_database() {
        if (db != null) {
            try {
                db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
            } catch (Error e) {
                warning("OpenPGP: WAL checkpoint failed: %s", e.message);
            }
        }
    }

    public void backup_database(string directory, Cancellable? cancellable = null) throws Error {
        if (db != null) db.backup_to(Path.build_filename(directory, "pgp.db"),
            () => cancellable != null && cancellable.is_cancelled());
    }

    public string? request_passphrase(string fingerprint, string operation) {
        string? result = null;
        bool done = false;
        Mutex mutex = Mutex();
        Cond cond = Cond();
        MainLoop? nested_loop = null;

        SourceFunc show_dialog = () => {
            var dialog = new Adw.AlertDialog(
                _("OpenPGP Passphrase Required"),
                _("Enter the passphrase for your OpenPGP key to continue.")
            );

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            box.margin_start = 24;
            box.margin_end = 24;

            var key_label = new Gtk.Label(format_passphrase_fingerprint(fingerprint));
            key_label.xalign = 0;
            key_label.add_css_class("monospace");
            key_label.add_css_class("dim-label");
            key_label.wrap = true;
            box.append(key_label);

            var pass_entry = new Gtk.PasswordEntry();
            pass_entry.show_peek_icon = true;
            pass_entry.placeholder_text = _("Passphrase");
            box.append(pass_entry);

            dialog.extra_child = box;
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("unlock", _("Unlock"));
            dialog.set_response_appearance("unlock", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "unlock";
            dialog.close_response = "cancel";

            dialog.response.connect((response) => {
                if (response == "unlock") {
                    result = pass_entry.text;
                }
                if (nested_loop != null) {
                    nested_loop.quit();
                } else {
                    mutex.lock();
                    done = true;
                    cond.signal();
                    mutex.unlock();
                }
            });

            Gtk.Window? parent = null;
            Gtk.Application? gtk_app = GLib.Application.get_default() as Gtk.Application;
            if (gtk_app != null) parent = gtk_app.active_window;
            dialog.present(parent);
            pass_entry.grab_focus();
            return false;
        };

        if (MainContext.default().is_owner()) {
            nested_loop = new MainLoop();
            show_dialog();
            nested_loop.run();
        } else {
            MainContext.default().invoke((owned) show_dialog);

            mutex.lock();
            while (!done) {
                cond.wait(mutex);
            }
            mutex.unlock();
        }

        if (result == null || result.length == 0) return null;
        return result;
    }

    private string format_passphrase_fingerprint(string fingerprint) {
        var sb = new StringBuilder();
        for (int i = 0; i < fingerprint.length; i++) {
            sb.append_c(fingerprint[i]);
            if ((i + 1) % 4 == 0 && i < fingerprint.length - 1) {
                sb.append(" ");
            }
        }
        return sb.str;
    }

    private void on_initialize_account_modules(Account account, ArrayList<Xmpp.XmppStreamModule> modules) {
        string? key_id = db.get_account_key(account);
        string key_mode = db.get_account_key_mode(account);
        string? legacy_key_id = db.get_account_legacy_key_for_presence(account);
        
        // NOTE: We do NOT verify the key here synchronously anymore!
        // The Module.do_key_setup() handles this asynchronously in a background thread.
        // This prevents the app from hanging during startup if GPG is slow or unresponsive.
        // If the key is invalid, do_key_setup() will simply fail to enable signing,
        // and the user will see that OpenPGP is not working.
        
        debug("OpenPGP: Initializing modules for account %s, selected_key: %s, legacy_presence_key: %s, mode: %s",
              account.bare_jid.to_string(), key_id ?? "none", legacy_key_id ?? "none", key_mode);

        // Add XEP-0027 module (legacy presence-based key signing)
        Manager? pgp_manager = app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
        PresenceManager? presence_manager = app.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        Module module = new Module(db, account, legacy_key_id, pgp_manager, presence_manager);
        this.modules[account] = module;
        modules.add(module);
        
        // Add XEP-0373 module (modern PubSub-based key distribution)
        // This enables interoperability with Conversations, Monocles, and other modern clients
        modules.add(new Xmpp.Xep.OpenPgp.Module());
        
        // Add XEP-0374 module (modern OpenPGP message encryption)
        // This enables encrypted messaging with Conversations, Monocles, and other modern clients
        modules.add(new Xmpp.Xep.OpenPgpContent.Module());
        
        debug("OpenPGP: Added XEP-0027, XEP-0373, and XEP-0374 modules for account %s", account.bare_jid.to_string());
    }
}

}
