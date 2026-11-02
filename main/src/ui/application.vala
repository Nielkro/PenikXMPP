/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Adw;

using Dino.Entities;
using Dino.Ui;
using Dino.Security;
using Xmpp;

[CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
private extern void dino_add_style_provider_for_display (Gdk.Display display, Gtk.StyleProvider provider, uint priority);

[CCode (cname = "gtk_style_context_remove_provider_for_display", cheader_filename = "gtk/gtk.h")]
private extern void dino_remove_style_provider_for_display (Gdk.Display display, Gtk.StyleProvider provider);

[CCode (cname = "g_subprocess_newv", cheader_filename = "gio/gio.h")]
private extern Subprocess dino_subprocess_newv ([CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv, SubprocessFlags flags) throws Error;

[CCode (cname = "dino_profile_restore_sync_file", cheader_filename = "security/profile_restore_sync.h")]
private extern void dino_profile_sync_file (string path) throws Error;
#if !WINDOWS
[CCode (cname = "dino_profile_restore_sync_parent", cheader_filename = "security/profile_restore_sync.h")]
private extern void dino_profile_sync_parent (string path) throws Error;
#endif

#if WINDOWS
[CCode (cname = "g_subprocess_launcher_spawnv", cheader_filename = "gio/gio.h")]
private extern Subprocess dino_subprocess_launcher_spawnv (SubprocessLauncher launcher, [CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv) throws Error;
#endif

[CCode (cname = "adw_about_dialog_set_developers", cheader_filename = "adwaita.h")]
private extern void dino_about_dialog_set_developers (Adw.AboutDialog dialog, [CCode (array_length = false, array_null_terminated = true, type = "const char**")] string[] developers);

public class Dino.Ui.Application : Adw.Application, Dino.Application {
    private const string[] KEY_COMBINATION_QUIT = {"<Ctrl>Q", null};
    private const string[] KEY_COMBINATION_ADD_CHAT = {"<Ctrl>T", null};
    private const string[] KEY_COMBINATION_ADD_CONFERENCE = {"<Ctrl>G", null};
    private const string[] KEY_COMBINATION_LOOP_CONVERSATIONS = {"<Ctrl>Tab", null};
    private const string[] KEY_COMBINATION_LOOP_CONVERSATIONS_REV = {"<Ctrl><Shift>Tab", null};
    private const string[] KEY_COMBINATION_SHOW_SETTINGS = {"<Ctrl>comma", null};
    private const string[] KEY_COMBINATION_SHOW_FEEDS = {"<Ctrl><Shift>F", null};
    private const string[] KEY_COMBINATION_PANIC_WIPE = {"<Ctrl><Shift><Alt>P", null};

    public MainWindow window;
    public MainWindowController controller;
    private SystrayManager? systray_manager = null;

    public Database db { get; set; }
    public string? db_key { get; set; }
    public Dino.Security.FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    private Config config;
    public StreamInteractor stream_interactor { get; set; }
    public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry (); }
    public SearchPathGenerator? search_path_generator { get; set; }

    // Plugins are loaded after the encrypted DB has been unlocked.
    public Plugins.Loader? plugin_loader { get; set; }
    private InterfaceStyle? interface_style = null;
    private Gtk.CssProvider? accent_css_provider = null;
    private Gtk.CssProvider? chat_font_css_provider = null;
#if WINDOWS
    private Gtk.CssProvider? windows_font_css_provider = null;
    private Gdk.Display? windows_font_display = null;
    private ulong windows_font_setting_handler = 0;
#endif
    private ulong accent_dark_notify_id = 0;
    private ulong accent_contrast_notify_id = 0;
    private bool plugins_shutdown = false;
    private bool plugins_shutdown_complete = false;

    public bool plugin_shutdown_in_progress {
        get { return plugins_shutdown && !plugins_shutdown_complete; }
    }

    internal static bool print_version = false; // vala-lint=naming-convention
    private const OptionEntry[] OPTIONS = {
        { "version", 0, 0, OptionArg.NONE, ref print_version, "Display version number", null },
        { null }
    };

    private bool core_ready = false;
    private ProfileLock? profile_lock = null;
    private bool profile_ready = false;
    internal static string? profile_preflight_error = null;
    private bool profile_operation_in_progress = false;
    private bool profile_shutting_down = false;
    private Cancellable? profile_operation_cancellable = null;
    private Thread<void*>? profile_worker = null;
    private int account_changes_in_progress = 0;
    private Gee.ArrayList<Gtk.Window> frozen_profile_windows = new Gee.ArrayList<Gtk.Window> ();
    private Gee.ArrayList<SimpleAction> frozen_profile_actions = new Gee.ArrayList<SimpleAction> ();
    private string? active_restore_stage = null;
    private string? maintenance_unlock_error = null;
    private bool pending_activate = false;
    private Gee.Set<string> active_account_invite_dialogs = new Gee.HashSet<string> ();
    private Gee.Set<int> active_muc_invite_dialogs = new Gee.HashSet<int> ();
    private AddChatDialog? active_add_chat_dialog = null;
    private AddConferenceDialog? active_add_conference_dialog = null;
    private ServerAdministrationDialog? active_server_administration_dialog = null;
    private Gee.Map<string, Adw.Dialog> active_muc_join_dialogs = new Gee.HashMap<string, Adw.Dialog> ();
    private SimpleAction check_for_updates_action = new SimpleAction ("check-for-updates", null);
    private Cancellable? update_check_cancellable = null;

    private Subprocess spawn_subprocess (string[] argv, SubprocessFlags flags) throws Error {
        return dino_subprocess_newv (argv, flags);
    }

    private bool communicate_profile_process (Subprocess process, string? input,
                                               Cancellable cancellable,
                                               out string? stderr_text) throws Error {
        // Cancelling GIO communication alone does not terminate the child.
        ulong cancellation_id = cancellable.connect (() => process.force_exit ());
        try {
            process.communicate_utf8 (input, null, null, out stderr_text);
            cancellable.set_error_if_cancelled ();
            return process.get_successful ();
        } finally {
            cancellable.disconnect (cancellation_id);
        }
    }

    private void show_profile_startup_error (string detail) {
        apply_startup_appearance ();
        var parent = new Adw.ApplicationWindow (this);
        parent.title = "DinoX";
        parent.set_default_size (480, 220);
        var page = new Adw.StatusPage ();
        page.title = _("Could Not Open Profile");
        page.description = _("The profile may already be in use, or a pending restore could not be completed. Close other DinoX instances and try again.") + "\n\n" + detail;
        var close_button = new Gtk.Button.with_label (_("Close"));
        close_button.halign = Gtk.Align.CENTER;
        close_button.clicked.connect (() => quit ());
        page.child = close_button;
        parent.content = page;
        parent.present ();
    }

    private bool profile_operation_available () {
        if (profile_shutting_down) return false;
        if (!profile_operation_in_progress && account_changes_in_progress == 0) return true;
        var dialog = new Adw.AlertDialog (_("Operation in Progress"),
            _("Please wait until the current account or data operation has finished."));
        dialog.add_response ("ok", _("OK"));
        present_dialog (dialog, window);
        return false;
    }

    private Cancellable begin_profile_operation () {
        profile_operation_in_progress = true;
        profile_operation_cancellable = new Cancellable ();
        foreach (Gtk.Window app_window in get_windows ()) {
            if ((app_window == window || app_window == unlock_parent) && app_window.sensitive) {
                frozen_profile_windows.add (app_window);
                app_window.sensitive = false;
            }
        }
        foreach (string name in list_actions ()) {
            var action = lookup_action (name) as SimpleAction;
            if (action != null && action.enabled && name != "quit" && name != "panic-wipe") {
                frozen_profile_actions.add (action);
                action.set_enabled (false);
            }
        }
        hold ();
        return (!) profile_operation_cancellable;
    }

    public bool begin_account_change () {
        if (!profile_operation_available ()) return false;
        account_changes_in_progress++;
        return true;
    }

    public void end_account_change () {
        if (account_changes_in_progress > 0) account_changes_in_progress--;
    }

    // Called on the main thread, after all child processes and staging cleanup.
    private bool finish_profile_operation () {
        profile_operation_cancellable = null;
        profile_operation_in_progress = false;
        if (!profile_shutting_down) {
            foreach (Gtk.Window app_window in frozen_profile_windows) app_window.sensitive = true;
            foreach (SimpleAction action in frozen_profile_actions) action.set_enabled (true);
        }
        frozen_profile_windows.clear ();
        frozen_profile_actions.clear ();
        release ();
        return !profile_shutting_down;
    }

    // Get a Windows-native temp directory (avoids MSYS2 path issues)
    internal static string get_profile_temporary_directory () {
        return get_native_tmp_dir ();
    }

    private static string get_native_tmp_dir() {
#if WINDOWS
        // On Windows, Environment.get_tmp_dir() returns MSYS2-style paths like /tmp
        // which become C:\msys64\tmp - but native Windows tools can't find this.
        // Use %TEMP% environment variable for native Windows paths.
        string? temp = Environment.get_variable("TEMP");
        if (temp != null && temp != "") {
            return temp;
        }
        temp = Environment.get_variable("TMP");
        if (temp != null && temp != "") {
            return temp;
        }
        // Fallback to LOCALAPPDATA\Temp
        string? localappdata = Environment.get_variable("LOCALAPPDATA");
        if (localappdata != null && localappdata != "") {
            return Path.build_filename(localappdata, "Temp");
        }
        // Ultimate fallback
        return "C:\\Temp";
#else
        return Environment.get_tmp_dir();
#endif
    }

#if WINDOWS
    // Get the directory where dinox.exe is located
    private static string get_executable_dir() {
        // Use DINOX_EXE_DIR set by main.vala (reliable, based on args[0])
        string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
        if (exe_dir != null) {
            return exe_dir;
        }
        
        // Fallback: probe common locations
        string cwd = Environment.get_current_dir();
        if (FileUtils.test(Path.build_filename(cwd, "bin", "openssl.exe"), FileTest.EXISTS)) {
            return cwd;
        }
        
        string[] possible_dirs = {
            "C:\\Program Files\\DinoX",
            "C:\\Program Files (x86)\\DinoX",
            Path.build_filename(Environment.get_home_dir(), "dino-win", "dist"),
        };
        
        foreach (string dir in possible_dirs) {
            if (FileUtils.test(Path.build_filename(dir, "bin", "openssl.exe"), FileTest.EXISTS)) {
                return dir;
            }
        }
        
        return cwd;
    }

    private static string get_windows_backup_archive_helper () throws Error {
        string exe_dir = get_executable_dir ();
        string[] candidates = {
            Path.build_filename (exe_dir, "bin", "dinox-backup-tar.exe"),
            Path.build_filename (exe_dir, "dinox-backup-tar.exe")
        };
        foreach (string candidate in candidates) {
            if (Path.is_absolute (candidate) && FileUtils.test (candidate, FileTest.IS_REGULAR)) {
                return candidate;
            }
        }
        throw new IOError.NOT_FOUND (
            "Bundled Windows backup archive helper is missing: %s".printf (candidates[0])
        );
    }

    private const uint WINDOWS_HELPER_STDERR_LIMIT = 64 * 1024;

    private static bool run_windows_backup_archive_subprocess (
            bool extract,
            string? cwd,
            string? input_path,
            string? output_path,
            out int exit_status,
            out string? stderr_str,
            Cancellable? cancellable = null) throws Error {
        exit_status = -1;
        stderr_str = null;
        string[] argv = { get_windows_backup_archive_helper (), extract ? "extract" : "create" };

        // Open archive paths through GIO. The bundled helper uses wide
        // filesystem paths and UTF-8 PAX headers, with binary pipes and a
        // Unicode-safe working directory instead of data paths in argv.
        InputStream? input_stream = null;
        if (input_path != null) {
            input_stream = File.new_for_path ((!) input_path).read ();
        }
        OutputStream? output_stream = null;
        if (output_path != null) {
            output_stream = File.new_for_path ((!) output_path).replace (
                null, false, FileCreateFlags.PRIVATE
            );
        }

        SubprocessFlags flags = SubprocessFlags.STDERR_PIPE;
        if (input_stream != null) {
            flags |= SubprocessFlags.STDIN_PIPE;
        }
        if (output_stream != null) {
            flags |= SubprocessFlags.STDOUT_PIPE;
        } else {
            flags |= SubprocessFlags.STDOUT_SILENCE;
        }

        var launcher = new SubprocessLauncher (flags);
        if (cwd != null) {
            launcher.set_cwd ((!) cwd);
        }
        Subprocess proc = dino_subprocess_launcher_spawnv (launcher, argv);
        ulong cancellation_id = cancellable != null
            ? cancellable.connect (() => proc.force_exit ()) : 0;

        string? input_error = null;
        Thread<void*>? input_thread = null;
        if (input_stream != null) {
            OutputStream child_stdin = (!) proc.get_stdin_pipe ();
            input_thread = new Thread<void*> ("windows-helper-stdin", () => {
                try {
                    child_stdin.splice (
                        (!) input_stream,
                        OutputStreamSpliceFlags.CLOSE_SOURCE |
                        OutputStreamSpliceFlags.CLOSE_TARGET
                    );
                } catch (Error err) {
                    input_error = err.message;
                    try {
                        child_stdin.close ();
                    } catch (Error close_err) {
                        // Preserve the original transfer error.
                    }
                }
                return null;
            });
        }

        InputStream child_stderr = (!) proc.get_stderr_pipe ();
        var stderr_bytes = new ByteArray.sized (8192);
        bool stderr_truncated = false;
        string? stderr_error = null;
        var stderr_thread = new Thread<void*> ("windows-helper-stderr", () => {
            uint8[] buffer = new uint8[4096];
            try {
                ssize_t read_count;
                while ((read_count = child_stderr.read (buffer)) > 0) {
                    uint remaining = WINDOWS_HELPER_STDERR_LIMIT -
                                     stderr_bytes.len;
                    int keep = (int) read_count;
                    if ((uint) keep > remaining) {
                        keep = (int) remaining;
                        stderr_truncated = true;
                    }
                    if (keep > 0) {
                        stderr_bytes.append (buffer[0:keep]);
                    }
                }
            } catch (Error err) {
                stderr_error = err.message;
            }
            return null;
        });

        string? output_error = null;
        if (output_stream != null) {
            try {
                InputStream child_stdout = (!) proc.get_stdout_pipe ();
                ((!) output_stream).splice (
                    child_stdout, OutputStreamSpliceFlags.CLOSE_SOURCE
                );
            } catch (Error err) {
                output_error = err.message;
                proc.force_exit ();
            }
        }

        if (input_thread != null) {
            ((!) input_thread).join ();
        }
        if (input_error != null) {
            proc.force_exit ();
        }
        proc.wait ();
        stderr_thread.join ();
        if (cancellable != null) cancellable.disconnect (cancellation_id);

        if (output_stream != null && !((!) output_stream).is_closed ()) {
            try {
                ((!) output_stream).close ();
            } catch (Error err) {
                if (output_error == null) {
                    output_error = err.message;
                }
            }
        }

        if (stderr_bytes.len > 0) {
            stderr_str = ((string) stderr_bytes.data).make_valid (
                (ssize_t) stderr_bytes.len
            );
        }
        if (stderr_truncated) {
            stderr_str = (stderr_str ?? "") +
                         "\n[helper stderr truncated by DinoX]";
        }

        exit_status = proc.get_exit_status ();
        if (input_error != null || output_error != null || stderr_error != null) {
            throw new IOError.FAILED (
                "Windows helper stream failed: %s".printf (
                    input_error ?? output_error ?? stderr_error ?? "unknown error"
                )
            );
        }
        return proc.get_successful ();
    }

    internal static void run_windows_backup_unicode_runtime_smoke () throws Error {
        string smoke_root = Path.build_filename (
            Environment.get_user_cache_dir (),
            "dinox",
            "windows-backup-smoke-" + Uuid.string_random ()
        );
        string data_parent = Path.build_filename (
            smoke_root, "Игорь Петров % ! ^ &"
        );
        string data_dir = Path.build_filename (data_parent, "dinox");
        string source_path = Path.build_filename (
            data_dir, "данные äöü.txt"
        );
        string archive_path = Path.build_filename (
            smoke_root, "архив äöü.tar.gz"
        );
        string restore_root = Path.build_filename (
            smoke_root, "Восстановление % ! ^ &"
        );
        string restored_path = Path.build_filename (
            restore_root, "dinox", "данные äöü.txt"
        );
        string expected = "DinoX Windows tar Unicode smoke: Игорь äöü\n";

        try {
            if (DirUtils.create_with_parents (data_dir, 0700) != 0 ||
                    DirUtils.create_with_parents (restore_root, 0700) != 0) {
                throw new IOError.FAILED (
                    "Could not create Windows backup Unicode smoke directories."
                );
            }
            FileUtils.set_contents (source_path, expected);

            int exit_status;
            string? stderr_str;
            if (!run_windows_backup_archive_subprocess (
                    false,
                    data_parent,
                    null,
                    archive_path,
                    out exit_status,
                    out stderr_str)) {
                throw new IOError.FAILED (
                    "Windows tar Unicode create smoke failed (exit %d): %s".printf (
                        exit_status, stderr_str ?? "no error output"
                    )
                );
            }

            if (!run_windows_backup_archive_subprocess (
                    true,
                    restore_root,
                    archive_path,
                    null,
                    out exit_status,
                    out stderr_str)) {
                throw new IOError.FAILED (
                    "Windows tar Unicode extract smoke failed (exit %d): %s".printf (
                        exit_status, stderr_str ?? "no error output"
                    )
                );
            }

            string restored;
            FileUtils.get_contents (restored_path, out restored);
            if (restored != expected) {
                throw new IOError.FAILED (
                    "Windows tar Unicode smoke changed the archived data."
                );
            }
        } finally {
            FileUtils.unlink (restored_path);
            DirUtils.remove (Path.get_dirname (restored_path));
            DirUtils.remove (restore_root);
            FileUtils.unlink (source_path);
            DirUtils.remove (data_dir);
            DirUtils.remove (data_parent);
            FileUtils.unlink (archive_path);
            DirUtils.remove (smoke_root);
        }
    }

    private static string windows_batch_value (string value) {
        return value.replace ("%", "%%").replace ("/", "\\");
    }

    private static string windows_batch_prelude () {
        // cmd.exe decodes batch files with its console code page, not with the
        // activeCodePage manifest of dinox.exe. Keep the prelude ASCII-only so
        // code page 65001 is active before any UTF-8 path is parsed.
        return "@chcp 65001 >nul 2>&1 || exit /b 1\r\n" +
               "@echo off\r\n" +
               "setlocal DisableDelayedExpansion\r\n";
    }

    private static string windows_batch_set_path (string name, string value) {
        return "set \"%s=%s\"\r\n".printf (name, windows_batch_value (value));
    }

    private static bool windows_controlled_ascii_filename_is_safe (
            string value, string suffix) {
        if (value.length <= suffix.length || !value.has_suffix (suffix)) {
            return false;
        }
        for (int index = 0; index < value.length; index++) {
            char current = value[index];
            if (!((current >= 'A' && current <= 'Z') ||
                    (current >= 'a' && current <= 'z') ||
                    (current >= '0' && current <= '9') ||
                    current == '_' || current == '-' || current == '.')) {
                return false;
            }
        }
        return true;
    }

    private static bool windows_deferred_batch_basename_is_safe (string value) {
        return windows_controlled_ascii_filename_is_safe (value, ".bat");
    }

    private static string windows_batch_set_restart_executable (
            string executable_path) throws Error {
        if (!Path.is_absolute (executable_path)) {
            throw new IOError.INVALID_ARGUMENT (
                "Deferred Windows restart executable path must be absolute."
            );
        }
        string executable_name = Path.get_basename (executable_path);
        if (executable_name != "dinox.exe") {
            throw new IOError.INVALID_ARGUMENT (
                "Deferred Windows restart executable must be named dinox.exe."
            );
        }
        return windows_batch_set_path (
            "DINOX_EXE_DIR", Path.get_dirname (executable_path)
        );
    }

    private static string windows_batch_start_restart_executable (bool deletion_only = false, bool maintenance = false) {
        return "pushd \"%DINOX_EXE_DIR%\" || exit /b 1\r\n" +
               "start \"\" \"dinox.exe\"" + (deletion_only ? " --apply-pending-profile-deletion" : (maintenance ? " --complete-profile-maintenance" : "")) + " || (popd & exit /b 1)\r\n" +
               "popd\r\n";
    }

    private static string get_windows_system32_directory () throws Error {
        string? system32_dir = SystrayWin32.get_system_directory ();
        if (system32_dir == null || !Path.is_absolute ((!) system32_dir)) {
            throw new IOError.NOT_FOUND (
                "Could not resolve the native Windows system directory."
            );
        }
        string[] required = { "cmd.exe", "ping.exe", "tasklist.exe", "find.exe" };
        foreach (string executable in required) {
            string executable_path = Path.build_filename ((!) system32_dir, executable);
            if (!FileUtils.test (executable_path, FileTest.IS_REGULAR)) {
                throw new IOError.NOT_FOUND (
                    "Required Windows system executable is missing: %s".printf (
                        executable_path
                    )
                );
            }
        }
        return (!) system32_dir;
    }

    private void spawn_windows_deferred_batch (string batch_path) throws Error {
        if (!Path.is_absolute (batch_path)) {
            throw new IOError.INVALID_ARGUMENT (
                "Deferred Windows batch path must be absolute."
            );
        }
        string batch_dir = Path.get_dirname (batch_path);
        string batch_name = Path.get_basename (batch_path);
        if (!windows_deferred_batch_basename_is_safe (batch_name)) {
            throw new IOError.INVALID_ARGUMENT (
                "Deferred Windows batch filename is not a controlled ASCII name."
            );
        }

        // cmd.exe parses its /c payload before the batch can switch to UTF-8.
        // An absolute TEMP path containing spaces, cmd metacharacters or a
        // sequence such as %PATH% is therefore unsafe in argv.  GLib passes
        // the directory separately through CreateProcessW's cwd, while cmd
        // sees only the controlled ASCII basename.
        string system32_dir = get_windows_system32_directory ();
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDIN_PIPE |
            SubprocessFlags.STDOUT_SILENCE |
            SubprocessFlags.STDERR_SILENCE
        );
        launcher.set_cwd (batch_dir);
        launcher.setenv ("DINOX_SYSTEM32", system32_dir, true);
        string[] batch_argv = {
            Path.build_filename (system32_dir, "cmd.exe"),
            "/d", "/c", batch_name
        };
        dino_subprocess_launcher_spawnv (launcher, batch_argv);
    }

    private void schedule_windows_profile_restart (bool deletion_only) throws Error {
        string exe_path = Path.build_filename (get_executable_dir (), "dinox.exe");
        if (!FileUtils.test (exe_path, FileTest.IS_REGULAR)) {
            throw new IOError.NOT_FOUND ("Could not locate dinox.exe for restart.");
        }
        string batch_path = Path.build_filename (get_native_tmp_dir (),
            "dinox_restore_restart_%s.bat".printf (Uuid.string_random ()));
        int current_pid = (int) Posix.getpid ();
        string batch_content = windows_batch_prelude ();
        batch_content += windows_batch_set_restart_executable (exe_path);
        batch_content += "for /L %%I in (1,1,120) do (\r\n";
        batch_content += "  \"%%DINOX_SYSTEM32%%\\tasklist.exe\" /FI \"PID eq %d\" /NH 2>nul | \"%%DINOX_SYSTEM32%%\\find.exe\" \"%d\" >nul\r\n".printf (current_pid, current_pid);
        batch_content += "  if errorlevel 1 goto restart_profile\r\n";
        batch_content += "  >nul \"%DINOX_SYSTEM32%\\ping.exe\" 127.0.0.1 -n 2\r\n";
        batch_content += ")\r\nexit /b 1\r\n:restart_profile\r\n";
        // The new process takes the profile lock and applies the pending restore.
        // The batch never renames or writes profile files itself.
        batch_content += windows_batch_start_restart_executable (deletion_only, true);
        batch_content += "(goto) 2>nul & del \"%~f0\"\r\n";
        FileUtils.set_contents (batch_path, batch_content);
        spawn_windows_deferred_batch (batch_path);
    }

#endif

    private string? pending_xmpp_uri = null;

#if WINDOWS
    public static string get_pending_external_xmpp_uri_path () {
        return Path.build_filename (Environment.get_user_cache_dir (), "dinox", "pending-xmpp-uri");
    }
#endif

    private const int MAX_UNLOCK_TRIES = 3;
    private int unlock_failures = 0;
    private Adw.ApplicationWindow? unlock_parent = null;
    private bool unlock_window_centered_once = false;
    private Ui.PreferencesDialog? cached_preferences_dialog = null;
    private bool cache_clear_in_progress = false;

    private bool is_first_run_no_db () {
        string db_path = Path.build_filename (Dino.Application.get_storage_dir (), "dino.db");
        return !FileUtils.test (db_path, FileTest.EXISTS);
    }

    // Panic marker path: placed in the PARENT of the storage dir so it
    // survives the recursive wipe of ~/.local/share/dinox/
    private static string get_panic_marker_path() {
        return Path.build_filename(Environment.get_user_data_dir(), "dinox_panic_marker");
    }

    // Shared post-unlock / post-set-password initialization.
    // Extracted to eliminate duplication between prompt_unlock() and prompt_set_password().
    private void finish_post_unlock () {
        debug ("finish_post_unlock: starting");

        // Prevent GApplication from quitting during the entire unlock→main
        // transition.  On GDK-Win32, window destruction can synchronously
        // re-enter the Win32 message pump — if use_count ever reaches 0
        // during that re-entry the main loop terminates.  hold() keeps
        // use_count > 0 until we release() at the very end.
        this.hold ();

        create_ui_actions ();
        core_ready = true;
        debug ("finish_post_unlock: core_ready=true");

        if (interface_style == null) interface_style = new InterfaceStyle(Gdk.Display.get_default());
        WindowControlPlacement.apply(settings.window_controls);
        settings.notify["window-controls"].connect(() => {
            WindowControlPlacement.apply(settings.window_controls);
            save_startup_appearance();
        });
        interface_style.apply(settings.interface_style);
        settings.notify["interface-style"].connect(() => {
            if (interface_style != null) interface_style.apply(settings.interface_style);
            save_startup_appearance ();
        });
        apply_color_scheme (settings.color_scheme);
        settings.notify["color-scheme"].connect (() => {
            apply_color_scheme (settings.color_scheme);
            apply_accent_color (settings.accent_color);
            save_startup_appearance ();
        });
        settings.notify["accent-color"].connect (() => {
            apply_accent_color (settings.accent_color);
            save_startup_appearance ();
        });
        apply_accent_color (settings.accent_color);
        save_startup_appearance ();
        settings.notify["chat-font-family"].connect (() => {
            apply_chat_font (settings.chat_font_family, settings.chat_font_scale);
        });
        settings.notify["chat-font-scale"].connect (() => {
            apply_chat_font (settings.chat_font_family, settings.chat_font_scale);
        });
        apply_chat_font (settings.chat_font_family, settings.chat_font_scale);
        if (accent_dark_notify_id == 0) {
            accent_dark_notify_id = Adw.StyleManager.get_default ().notify["dark"].connect (() => {
                apply_accent_color (settings.accent_color);
            });
        }

        if (accent_contrast_notify_id == 0) {
            accent_contrast_notify_id = Adw.StyleManager.get_default().notify["high-contrast"].connect(() => {
                apply_accent_color(settings.accent_color);
            });
        }

        NotificationEvents notification_events = stream_interactor.get_module<NotificationEvents> (NotificationEvents.IDENTITY);
        MucVoiceRequestManager voice_request_manager =
            stream_interactor.get_module<MucVoiceRequestManager> (
                MucVoiceRequestManager.IDENTITY);
        MucManager muc_manager = stream_interactor.get_module<MucManager> (
            MucManager.IDENTITY);
        muc_manager.invite_failed.connect ((account, room_jid, invitee_jid,
                condition, text) => {
            show_muc_invite_failure (condition, text);
        });
        voice_request_manager.request_action_failed.connect (
                (request, condition, text) => {
            string detail = text != null && ((!) text).strip () != ""
                ? _("The server rejected the response to the permission request: %s").printf (
                    (!) text)
                : _("The response could not be processed. The request remains open.");
            show_room_action_error (detail);
        });
#if WINDOWS
        notification_events.register_notification_provider.begin(new WindowsNotifier(stream_interactor));
#else
        get_notifications_dbus.begin ((_, res) => {
            DBusNotifications? dbus_notifications = get_notifications_dbus.end (res);
            if (dbus_notifications != null) {
                FreeDesktopNotifier free_desktop_notifier = new FreeDesktopNotifier (stream_interactor, dbus_notifications);
                notification_events.register_notification_provider.begin (free_desktop_notifier);
            } else {
                notification_events.register_notification_provider.begin (new GNotificationsNotifier (stream_interactor));
            }
        });
#endif

        notification_events.notify_content_item.connect ((content_item, conversation) => {
            var desktop_env = Environment.get_variable ("XDG_CURRENT_DESKTOP");
            if (desktop_env == null || !desktop_env.down ().contains ("gnome")) {
                if (this.active_window != null) {
//                    this.active_window.urgency_hint = true;
                }
            }
        });
        stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY).invite_received.connect ((invite) => {
            Idle.add (() => {
                show_muc_invite_dialog (invite.id);
                return Source.REMOVE;
            });
        });
        stream_interactor.get_module<FileManager> (FileManager.IDENTITY).add_metadata_provider (new Util.AudioVideoFileMetadataProvider ());

        debug ("finish_post_unlock: creating SystrayManager");
        systray_manager = new SystrayManager (this);
        debug ("finish_post_unlock: SystrayManager created");
        consume_pending_external_xmpp_uri ();

        // Auto-show certificate warning dialog when TLS cert validation fails
        stream_interactor.connection_manager.certificate_validation_required.connect ((account, peer_cert, errors) => {
            Idle.add (() => {
                var app = (Gtk.Application) GLib.Application.get_default ();
                Gtk.Window? parent_window = app != null ? app.active_window : null;
                if (parent_window != null) {
                    var cert_dialog = new CertificateWarningDialog (
                        account, peer_cert, errors,
                        account.domainpart, stream_interactor
                    );
                    cert_dialog.present (parent_window);
                }
                return false;
            });
        });

        // Create the MainWindow while unlock_parent is still alive.
        debug ("finish_post_unlock: pending_activate=%s", pending_activate.to_string ());
        if (pending_activate) {
            pending_activate = false;
            debug ("finish_post_unlock: calling activate()");
            activate ();
            debug ("finish_post_unlock: activate() returned, window=%s",
                     (window != null).to_string ());
        }

        if (unlock_parent != null) {
            debug ("finish_post_unlock: closing unlock_parent");
            unlock_parent.close ();
            unlock_parent = null;
        }

        // Re-present the main window so it ends up on top after the
        // unlock dialog is gone.  On Windows the modal unlock_parent
        // keeps z-order focus and the MainWindow can end up behind it.
        // We use Idle.add so the window manager has time to process
        // the close before we grab focus, plus a timed fallback.
        if (window != null) {
            var win = window;
            Idle.add (() => {
                win.present ();
                return Source.REMOVE;
            });
            Timeout.add (300, () => {
                win.present ();
                return Source.REMOVE;
            });
        }

        maybe_open_ui_smoke_botmanager ();

        debug ("finish_post_unlock: done — releasing hold");
        this.release ();
    }

    private void maybe_open_ui_smoke_botmanager () {
        string? account_jid = Environment.get_variable ("DINOX_UI_SMOKE_OPEN_BOTMANAGER");
        if (account_jid == null || account_jid.strip () == "") return;

        string target_jid = account_jid.strip ();
        Timeout.add (1200, () => {
            if (window == null) return Source.REMOVE;

            bool account_exists = false;
            foreach (Account account in db.get_accounts ()) {
                if (account.bare_jid.to_string () == target_jid) {
                    account_exists = true;
                    break;
                }
            }

            if (!account_exists) {
                warning ("UI smoke: account not found for Botmanager: %s", target_jid);
                return Source.REMOVE;
            }

            var dialog = new BotManagerDialog ();
            dialog.account_jid = target_jid;
            dialog.present (window);
            message ("UI smoke: opened Botmanager for %s", target_jid);
            return Source.REMOVE;
        });
    }

    // Check if a panic wipe happened before this startup.
    // If a marker file exists, read the timestamp and configure HistorySync
    // to not fetch MAM messages from before the wipe.
    private void check_panic_marker() {
        string marker_path = get_panic_marker_path();
        if (!FileUtils.test(marker_path, FileTest.EXISTS)) return;

        try {
            string contents;
            FileUtils.get_contents(marker_path, out contents);
            long wipe_time = long.parse(contents.strip());
            if (wipe_time > 0) {
                DateTime wipe_dt = new DateTime.from_unix_utc(wipe_time);
                debug("Panic marker found: wipe at %s — setting MAM sync_not_before", wipe_dt.to_string());

                // Tell HistorySync to not fetch messages from before the wipe
                var message_processor = stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
                if (message_processor != null && message_processor.history_sync != null) {
                    message_processor.history_sync.set_panic_sync_floor(wipe_dt);
                }
            }
        } catch (Error e) {
            warning("Failed to read panic marker: %s", e.message);
        }

        // Remove the marker — it has been consumed
        FileUtils.unlink(marker_path);
    }

    public void cleanup_temp_files () {
        // Note: "avatars" is NOT included — avatar files are persistent cache
        // that would require expensive re-fetching from the server on each restart.
        string[] temp_dirs = { "temp_audio", "temp_video", "temp_open", "temp_plaintext" };
        string cache_root = Path.build_filename (Environment.get_user_cache_dir (), "dinox");

        foreach (string dir_name in temp_dirs) {
            string full_path = Path.build_filename (cache_root, dir_name);
            if (FileUtils.test (full_path, FileTest.EXISTS | FileTest.IS_DIR)) {
                try {
                    delete_directory_contents (full_path);
                    DirUtils.remove (full_path);
                } catch (Error e) {
                    warning ("Failed to cleanup temp dir %s: %s", full_path, e.message);
                }
            }
        }

        // Files in a shared temporary directory have no reliable profile owner.
        // Only the current profile's cache directories are safe to clean here.
    }

    private Adw.ApplicationWindow ensure_unlock_window () {
        if (unlock_parent == null) {
            apply_startup_appearance ();
            unlock_parent = new Adw.ApplicationWindow (this);
            unlock_parent.title = "DinoX";
            unlock_parent.default_width = 460;
            unlock_parent.default_height = 260;
            unlock_parent.resizable = false;
#if !WINDOWS
            // On Linux, modal prevents interaction with other windows.
            // On Windows (GDK-Win32), modal without a transient parent
            // causes the mouse cursor to disappear/become unresponsive.
            unlock_parent.modal = true;
#endif

            // Cinnamon/Muffin often places small modal windows at (0,0). Center it once on map.
            ((Gtk.Widget)unlock_parent).map.connect( () => {
                if (unlock_parent == null) return;
                if (unlock_window_centered_once) return;
                if (this.active_window != null) return;

                if (try_center_unlock_window_on_monitor ((!)unlock_parent)) {
                    unlock_window_centered_once = true;
                }
            });
        }

        // Center the unlock window over the main window when available.
        if (this.active_window != null && this.active_window != unlock_parent) {
            unlock_parent.transient_for = this.active_window;
        }
        unlock_parent.present ();
        return (!)unlock_parent;
    }

    private bool try_center_unlock_window_on_monitor (Adw.ApplicationWindow win) {
#if HAVE_X11
        // GTK4 has no generic "center on screen" API. On X11 we can move the window explicitly.
        Gdk.Display? gdk_display = win.get_display( );
        Gdk.Surface? gdk_surface = win.get_surface ();
        if (gdk_display == null || gdk_surface == null) return false;

        var x11_display = gdk_display as Gdk.X11.Display;
        var x11_surface = gdk_surface as Gdk.X11.Surface;
        if (x11_display == null || x11_surface == null) return false;

        Gdk.Monitor? monitor = gdk_display.get_monitor_at_surface (gdk_surface);
        if (monitor == null) return false;

        Gdk.Rectangle area = monitor.geometry;
        var x11_monitor = monitor as Gdk.X11.Monitor;
        if (x11_monitor != null) {
            area = x11_monitor.get_workarea ();
        }

        int w = win.default_width > 0 ? win.default_width : 460;
        int h = win.default_height > 0 ? win.default_height : 260;

        int x = area.x + (area.width - w) / 2;
        int y = area.y + (area.height - h) / 2;
        if (x < area.x) x = area.x;
        if (y < area.y) y = area.y;

        unowned X.Display xdisplay = x11_display.get_xdisplay ();
        xdisplay.move_window (x11_surface.get_xid (), x, y);
        xdisplay.flush ();
        return true;
#else
        return false;
#endif
    }

    private void set_unlock_window_content (Gtk.Widget child) {
        var win = ensure_unlock_window ();
        win.set_content (child);
    }

    // GDK-Win32 has issues with Adw.Dialog sheet overlays: mouse events
    // don't reach overlaid widgets reliably. Force floating (separate
    // window) mode to avoid the cursor-behind-dialog problem.
    private void present_dialog (Adw.Dialog dialog, Gtk.Widget? parent) {
        if (dialog.content_width > 0 && dialog.content_height > 0) {
            dialog.follows_content_size = false;
        }
#if WINDOWS
        dialog.presentation_mode = Adw.DialogPresentationMode.FLOATING;
#endif
        dialog.present (parent);
    }

    private delegate void UnlockFormAction ();

    private Gtk.Widget build_unlock_form (string heading, string body, Gtk.Widget form, string primary_label, UnlockFormAction primary_action) {
        var outer = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        outer.margin_top = 18;
        outer.margin_bottom = 18;
        outer.margin_start = 18;
        outer.margin_end = 18;

        var title = new Gtk.Label (heading);
        title.halign = Gtk.Align.START;
        title.wrap = true;
        title.add_css_class ("title-2");

        var subtitle = new Gtk.Label (body);
        subtitle.halign = Gtk.Align.START;
        subtitle.wrap = true;

        outer.append (title);
        outer.append (subtitle);
        outer.append (form);

        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        buttons.halign = Gtk.Align.END;

        var cancel_btn = new Gtk.Button.with_label (_("Quit"));
        cancel_btn.clicked.connect (() => {
            Process.exit (0);
        });

        var primary_btn = new Gtk.Button.with_label (primary_label);
        primary_btn.add_css_class ("suggested-action");
        primary_btn.clicked.connect (() => {
            primary_action ();
        });

        buttons.append (cancel_btn);
        buttons.append (primary_btn);
        outer.append (buttons);

        var clamp = new Adw.Clamp () {
            maximum_size = 520,
            tightening_threshold = 520,
            child = outer,
            halign = Align.FILL,
            valign = Align.CENTER
        };

        return clamp;
    }

    public Application () throws Error {
#if WINDOWS
        // On Windows with MSYS2/MinGW, DBus session registration often times out or fails
        // if not configured perfectly. NON_UNIQUE bypasses the single-instance lock/registration.
        Object (application_id: "im.dinox.dinox", flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.NON_UNIQUE);
#else
        Object (application_id: "im.dinox.dinox", flags: ApplicationFlags.HANDLES_OPEN);
#endif
        Environment.set_application_name ("DinoX");
        Gtk.Window.set_default_icon_name ("im.dinox.dinox");

        // Suppress known harmless GTK4 warnings that cannot be fixed from
        // application code (PopoverMenu accounting, GtkText blinking selection).
        GLib.Log.set_handler("Gtk", GLib.LogLevelFlags.LEVEL_WARNING, (domain, level, msg) => {
            if (msg.contains("Broken accounting of active state") ||
                msg.contains("unexpected blinking selection")) {
                return; // swallow
            }
            GLib.Log.default_handler(domain, level, msg);
        });

        // For AppImage: ensure GTK4 can find bundled icons by prepending to XDG_DATA_DIRS.
        // (AppRun also sets this, but do it here as safety net for direct execution.)
        string? appdir = Environment.get_variable("APPDIR");
        if (appdir != null) {
            string share_dir = Path.build_filename(appdir, "usr", "share");
            string? current_xdg = Environment.get_variable("XDG_DATA_DIRS");
            if (current_xdg == null || !current_xdg.contains(share_dir)) {
                string new_xdg = share_dir;
                if (current_xdg != null && current_xdg != "") {
                    new_xdg = share_dir + ":" + current_xdg;
                } else {
                    new_xdg = share_dir + ":/usr/local/share:/usr/share";
                }
                Environment.set_variable("XDG_DATA_DIRS", new_xdg, true);
            }
        }

        add_main_option_entries (OPTIONS);

        // Register core (libdino) option entries early (before command line parsing).
        ((Dino.Application)this).ensure_core_options_registered( );

        // Panic wipe should be available even before unlocking.
        create_pre_unlock_actions( );

        open.connect( (files, hint) => {
            if (files.length != 1) {
                warning ("Can't handle more than one URI at once.");
                return;
            }
            File file = files[0];
            if (!file.has_uri_scheme ("xmpp")) {
                warning ("xmpp:-URI expected");
                return;
            }
            string uri = file.get_uri ();
            if (!core_ready || window == null) {
                pending_xmpp_uri = uri;
                activate ();
                return;
            }
            window.present ();
            handle_pending_xmpp_uri (uri);
        });

        startup.connect (() => {
            // Force registration of custom widgets to avoid builder errors on Windows
            typeof(Dino.Ui.SizeRequestBox).ensure();
            typeof(Dino.Ui.SizeRequestBin).ensure();
            typeof(Dino.Ui.SizingBin).ensure();

#if !WINDOWS
            // Ensure the app icon (im.dinox.dinox) is discoverable from the build dir
            // and installed prefix.  On GDK-Win32 this display-scoped icon
            // theme setup can run before the backend is fully ready and crash
            // packaged startup; the Windows package provides icon theme assets
            // via XDG_DATA_DIRS and the bundled Adwaita/hicolor trees instead.
            var display = Gdk.Display.get_default();
            if (display != null) {
                var icon_theme = Gtk.IconTheme.get_for_display(display);

                // Determine executable directory for icon search paths.
                string? exe_dir = null;
                try {
                    string exe = FileUtils.read_link("/proc/self/exe");
                    exe_dir = Path.get_dirname(exe);
                } catch (FileError e) {
                    // /proc not available (non-Linux)
                }

                if (exe_dir != null) {
                    // Installed layout: <prefix>/bin/../share/icons
                    string icon_base = Path.build_filename(exe_dir, "..", "share", "icons");
                    if (FileUtils.test(icon_base, FileTest.IS_DIR)) {
                        icon_theme.add_search_path(icon_base);
                        debug("startup: Added icon search path: %s", icon_base);
                    }

                    // Build dir layout: build/main/../../main/data/icons
                    string build_icons = Path.build_filename(exe_dir, "..", "..", "main", "data", "icons");
                    if (FileUtils.test(build_icons, FileTest.IS_DIR)) {
                        icon_theme.add_search_path(build_icons);
                        debug("startup: Added build-dir icon search path: %s", build_icons);
                    }
                }

                // Explicitly register GResource icon path for custom dino-* icons.
                icon_theme.add_resource_path("/im/dinox/dinox/icons");
                debug("startup: Added icon resource path: /im/dinox/dinox/icons");
            }
#endif

#if WINDOWS
            apply_windows_font_settings ();
#endif

            if (print_version) {
                stdout.printf ("Dino %s\n", Dino.get_version( ));
                stdout.flush ();
                Process.exit (0);
            }

            if (profile_preflight_error != null) {
                show_profile_startup_error ((!) profile_preflight_error);
                return;
            }
            try {
                profile_lock = ProfileLock.acquire (Dino.Application.get_storage_dir ());
                if (ProfileDeletion.has_pending (((!) profile_lock).profile_dir)) {
                    schedule_profile_restart ();
                    quit ();
                    return;
                }
                ProfileRestore.apply_pending (((!) profile_lock).profile_dir);
                ProfileMaintenance.finish_completed (((!) profile_lock).profile_dir);
                profile_ready = true;
            } catch (Error err) {
                // A busy or damaged profile is never an incorrect password.
                // In particular, do not enter the unlock failure/panic-wipe path.
                show_profile_startup_error (err.message);
                return;
            }

            cleanup_temp_files ();

            // Require unlock before initializing the core.
            prompt_unlock( );
        });

        activate.connect (() => {
            debug ("activate handler: core_ready=%s, window=%s",
                     core_ready.to_string (), (window != null).to_string ());
            if (!core_ready) {
                pending_activate = true;
                debug ("activate handler: deferred (pending_activate=true)");
                return;
            }
            if (window == null) {
                debug ("activate handler: creating MainWindow");
                controller = new MainWindowController (this, stream_interactor, db);
                config = new Config (db);
                window = new MainWindow (this, stream_interactor, db, config);
                debug ("activate handler: MainWindow created");
                controller.set_window (window);
                // Always enable hide_on_close - we'll control quit behavior in close_request handler
                window.hide_on_close = true;

                // Connect systray to window
                if (systray_manager != null) {
                    systray_manager.set_window (window);
                }

#if HAVE_MALLOC_TRIM
                // Periodically return freed heap memory to the OS.
                // glibc keeps freed pages in its arena; malloc_trim(0) releases them.
                Timeout.add_seconds(60, () => {
                    malloc_trim(0);
                    return Source.CONTINUE;
                });
#endif
            }
            window.present ();

            if (pending_xmpp_uri != null) {
                handle_pending_xmpp_uri ((!)pending_xmpp_uri);
                pending_xmpp_uri = null;
            }
        });
    }

#if WINDOWS
    private void apply_windows_font_settings () {
        var display = Gdk.Display.get_default ();
        if (display == null) return;

        var gtk_settings = Gtk.Settings.get_for_display (display);
        if (gtk_settings != null) {
            WindowsFontSettings.apply_for_display (gtk_settings, display);
            WindowsFontSettings.apply_rendering (gtk_settings);
            if (windows_font_setting_handler == 0) {
                windows_font_display = display;
                windows_font_setting_handler = WindowsFontSettings.watch_display (gtk_settings, display);
            }

        }

        if (windows_font_css_provider != null) return;
        windows_font_css_provider = new Gtk.CssProvider ();
        string css = ".monospace { font-family: Consolas, monospace; }";
#if GTK_4_12 && (VALA_0_56_GREATER_11 || VALA_0_58)
        windows_font_css_provider.load_from_string (css);
#elif (VALA_0_56_11 || VALA_0_56_12)
        windows_font_css_provider.load_from_data (css, css.length);
#else
        windows_font_css_provider.load_from_data (css.data);
#endif
        dino_add_style_provider_for_display (display, windows_font_css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 20);
    }
#endif

    private void prompt_unlock () {
        if (core_ready) return;

        if (is_first_run_no_db ()) {
            prompt_set_password ();
            return;
        }

        // Detect whether this startup follows a backup restore.
        // If so, the DB on disk is encrypted with the backup's original
        // password, which may differ from whatever the user set most recently
        // (e.g. after a Panic Wipe + fresh password + restore).
        string restore_marker = Path.build_filename (
            Dino.Application.get_storage_dir (), ".restore_pending"
        );
        bool is_restore = FileUtils.test (restore_marker, FileTest.EXISTS);
        bool is_maintenance = false;
        try {
            is_maintenance = ProfileMaintenance.has_pending (((!) profile_lock).profile_dir);
        } catch (Error err) {
            show_profile_startup_error (err.message);
            return;
        }

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.hexpand = true;
        password_entry.show_peek_icon = true;

        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var label = new Gtk.Label (_("Password"));
        label.halign = Gtk.Align.START;
        form.append (label);
        form.append (password_entry);

        string heading;
        string body;
        if (is_maintenance) {
            heading = _("Complete Database Maintenance");
            body = _("Enter the password that was active when you requested this operation. DinoX will finish maintenance before opening your accounts.");
            if (maintenance_unlock_error != null) body += "\n\n" + maintenance_unlock_error;
        } else if (is_restore) {
            heading = _("Backup Restored");
            if (unlock_failures > 0) {
                body = _("Wrong password.\n\nPlease enter the password that was active for the database when the backup was created.");
            } else {
                body = _("A backup has been restored.\n\nPlease enter the password that was active for the database when the backup was created.");
            }
        } else {
            heading = _("Unlock DinoX");
            body = _("Please enter your password to open the encrypted database.");
            if (unlock_failures > 0) {
                body = _("Wrong password. Attempt %d/%d").printf( unlock_failures + 1, MAX_UNLOCK_TRIES);
            }
        }

        UnlockFormAction do_unlock = () => {
            if (profile_operation_in_progress) return;
            string password = password_entry.text ?? "";
            if (password.strip ().length == 0) {
                unlock_failures++;
                warning ("Unlock failed: empty password");
                // Never panic-wipe after a restore — the user just needs
                // the correct original password from the backup.
                if (!is_restore && !is_maintenance && unlock_failures >= MAX_UNLOCK_TRIES) {
                    panic_wipe_and_exit ();
                }
                prompt_unlock ();
                return;
            }
            if (!is_maintenance) {
                complete_unlock (password, is_restore, false, restore_marker);
                return;
            }
            var cancellable = begin_profile_operation ();
            var progress = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            var spinner = new Gtk.Spinner () { spinning = true, height_request = 48 };
            progress.append (spinner);
            var progress_label = new Gtk.Label (_("Completing database maintenance…"));
            progress_label.wrap = true;
            progress.append (progress_label);
            set_unlock_window_content (progress);
            string profile = ((!) profile_lock).profile_dir;
            profile_worker = new Thread<void*> ("profile-maintenance", () => {
                string? effective_key = null;
                string? failure = null;
                try {
                    effective_key = ProfileMaintenance.apply_pending (profile, password, cancellable);
                } catch (Error err) {
                    failure = err.message;
                }
                Idle.add (() => {
                    if (!finish_profile_operation ()) return false;
                    if (effective_key != null) {
                        maintenance_unlock_error = null;
                        complete_unlock ((!) effective_key, true, true, restore_marker);
                    } else {
                        // A published replacement must finish during startup,
                        // before another attempt opens either database set.
                        try {
                            if (ProfileRestore.has_pending (profile)) {
                                show_profile_startup_error (_("Close DinoX and start it again to finish the prepared maintenance operation.") + "\n" + (failure ?? ""));
                                return false;
                            }
                        } catch (Error err) {
                            show_profile_startup_error (err.message);
                            return false;
                        }
                        // I/O errors and failed maintenance are never counted
                        // as incorrect passwords that could trigger panic wipe.
                        maintenance_unlock_error = _("Maintenance could not be completed. Check your password and available disk space.") + "\n" + (failure ?? "");
                        prompt_unlock ();
                    }
                    return false;
                });
                return null;
            });
        };

        password_entry.activate.connect (() => do_unlock ());
        set_unlock_window_content (build_unlock_form (heading, body, form, _("Unlock"), do_unlock));
    }

    private void complete_unlock (string password, bool is_restore, bool maintenance_attempt, string restore_marker) {
        try {
            this.db_key = password;
            ((Dino.Application) this).init ();
            if (FileUtils.test (restore_marker, FileTest.EXISTS)) FileUtils.unlink (restore_marker);
            if (plugin_loader != null) {
                try { plugin_loader.load_all (); }
                catch (Error plugin_err) { warning ("Plugin loading error (non-fatal): %s", plugin_err.message); }
            }
            finish_post_unlock ();
            check_panic_marker ();
        } catch (Error err) {
            warning ("Unlock failed: %s", err.message);
            if (!maintenance_attempt) unlock_failures++;
            if (!is_restore && !maintenance_attempt && unlock_failures >= MAX_UNLOCK_TRIES) {
                panic_wipe_and_exit ();
            }
            prompt_unlock ();
        }
    }

    private void prompt_set_password () {
        if (core_ready) return;

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.hexpand = true;
        password_entry.show_peek_icon = true;

        var password_entry_confirm = new Gtk.PasswordEntry ();
        password_entry_confirm.hexpand = true;
        password_entry_confirm.show_peek_icon = true;

        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        var l1 = new Gtk.Label (_("Password"));
        l1.halign = Gtk.Align.START;
        var l2 = new Gtk.Label (_("Confirm Password"));
        l2.halign = Gtk.Align.START;
        form.append (l1);
        form.append (password_entry);
        form.append (l2);
        form.append (password_entry_confirm);

        string heading = _("Set Password");
        string body = _("On first use, you need to set a password. Without a password, DinoX cannot open the encrypted database.");
        if (unlock_failures > 0) {
            body = _("Invalid password. Attempt %d/%d").printf( unlock_failures + 1, MAX_UNLOCK_TRIES);
        }

        UnlockFormAction do_set = () => {
            string password = password_entry.text ?? "";
            string password2 = password_entry_confirm.text ?? "";

            if (password.strip ().length == 0) {
                unlock_failures++;
                warning ("Set password failed: empty password");
            } else if (password != password2) {
                unlock_failures++;
                warning ("Set password failed: mismatch");
            } else {
                try {
                    this.db_key = password;
                    ((Dino.Application)this).init ();

                    if (plugin_loader != null) {
                        plugin_loader.load_all ();
                    }
                    finish_post_unlock ();
                    return;
                } catch (Error e) {
                    unlock_failures++;
                    warning ("Set password failed: %s", e.message);
                }
            }

            if (unlock_failures >= MAX_UNLOCK_TRIES) {
                panic_wipe_and_exit ();
            }

            prompt_set_password ();
        };

        password_entry_confirm.activate.connect (() => do_set ());
        set_unlock_window_content (build_unlock_form (heading, body, form, _("Set Password"), do_set));
    }

    private void create_pre_unlock_actions () {
        SimpleAction panic_wipe_action = new SimpleAction ("panic-wipe", null);
        panic_wipe_action.activate.connect ((variant) => {
            panic_wipe_and_exit ();
        });
        add_action (panic_wipe_action);
        set_accels_for_action ("app.panic-wipe", KEY_COMBINATION_PANIC_WIPE);
    }

    private void handle_pending_xmpp_uri (string uri) {
        XmppUriInfo? info = parse_xmpp_uri (uri);
        if (info == null) {
            warning ("Invalid URI");
            return;
        }
        handle_uri (info.jid, info.query, info.options);
    }

    public void consume_pending_external_xmpp_uri () {
#if WINDOWS
        string path = get_pending_external_xmpp_uri_path ();
        if (!FileUtils.test (path, FileTest.IS_REGULAR)) return;

        string uri;
        try {
            FileUtils.get_contents (path, out uri);
            FileUtils.remove (path);
        } catch (FileError e) {
            warning ("Failed to read pending XMPP URI: %s", e.message);
            return;
        }

        uri = uri.strip ();
        if (uri == "") return;

        if (!core_ready || window == null) {
            pending_xmpp_uri = uri;
            activate ();
            return;
        }

        window.present ();
        handle_pending_xmpp_uri (uri);
#endif
    }

    private void panic_wipe_and_exit () {
        if (!profile_ready) return;
        // Persist intent now, even if shutdown happens before a worker's Idle
        // callback. The helper waits for this process (and its workers) to exit.
        if (profile_operation_cancellable != null) profile_operation_cancellable.cancel ();
        request_profile_deletion (true);
    }

    private void request_profile_deletion (bool panic) {
        if (profile_lock == null) return;
        try {
            ProfileDeletion.schedule (((!) profile_lock).profile_dir, panic);
            if (panic) {
                FileUtils.set_contents_full (get_panic_marker_path (),
                    new DateTime.now_utc ().to_unix ().to_string (), -1,
                    FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
            }
            schedule_profile_restart (panic);
            quit ();
        } catch (Error err) {
            var dialog = new Adw.AlertDialog (_("Could Not Complete Operation"),
                _("The operation could not be completed. Close DinoX and start it again to retry.") + "\n\n" + err.message);
            dialog.add_response ("ok", _("OK"));
            present_dialog (dialog, window);
        }
    }

    public void handle_uri (string jid, string query, Gee.Map<string, string> options) {
        switch (query) {
            case "join":
                if (uri_has_preauth (options)) {
                    confirm_muc_invite.begin (jid);
                } else {
                    show_join_muc_dialog (null, jid);
                }
                break;
            case "register":
                if (uri_has_preauth (options)) {
                    confirm_account_invite (jid, options["preauth"]);
                } else {
                    show_unsupported_xmpp_invite_dialog (
                        _("Account Invitation"),
                        _("DinoX recognized an account registration link for %s, but it does not contain an invitation token.").printf (jid)
                    );
                }
                break;
            case "message":
            case "roster":
                if (uri_has_preauth (options)) {
                    if (!has_enabled_accounts () && options.has_key ("ibr") && options["ibr"] == "y") {
                        confirm_user_invite_account_registration.begin (jid, options["preauth"]);
                    } else if (!has_enabled_accounts ()) {
                        show_unsupported_xmpp_invite_dialog (
                            _("Contact Invitation"),
                            _("DinoX recognized an invitation from %s, but no account is available to accept it.").printf (jid)
                        );
                    } else {
                        confirm_chat_invite.begin (jid, options["preauth"], options.has_key ("name") ? options["name"] : null);
                    }
                } else {
                    open_chat_uri (jid);
                }
                break;
            case "pubsub":
                // Example: xmpp:romeo@montague.lit?pubsub;action=retrieve;node=urn:xmpp:stickers:0;item=EpRv...
                if (!options.has_key( "action") || options["action"] != "retrieve") return;
                if (!options.has_key ("node") || options["node"] != Xmpp.Xep.Stickers.NS_URI) return;
                if (!options.has_key ("item") || options["item"] == "") return;
                try {
                    var src = new Xmpp.Jid (jid);
                    var dialog = new Dino.Ui.StickerPackImportDialog (stream_interactor, src, options["node"], options["item"]);
                    dialog.set_transient_for (window);
                    dialog.present ();
                } catch (Xmpp.InvalidJidError e) {
                    warning ("Invalid JID in pubsub URI: %s", e.message);
                }
                break;
            default:
                show_unsupported_xmpp_invite_dialog (
                    _("Unsupported XMPP Link"),
                    _("DinoX cannot handle this XMPP link type yet.")
                );
                break;
        }
    }

    private static bool uri_has_preauth (Gee.Map<string, string> options) {
        return options.has_key ("preauth") && options["preauth"] != "";
    }

    private bool has_enabled_accounts () {
        foreach (Account account in stream_interactor.get_accounts ()) {
            if (account.enabled) return true;
        }
        return false;
    }

    private void open_chat_uri (string jid) {
        Gee.List<Account> accounts = stream_interactor.get_accounts ();
        Jid parsed_jid = null;
        try {
            parsed_jid = new Jid (jid);
        } catch (InvalidJidError ignored) {
            // Ignored
        }
        if (accounts.size == 1 && parsed_jid != null) {
            Conversation conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).create_conversation (parsed_jid, accounts[0], Conversation.Type.CHAT);
            stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).start_conversation (conversation);
            controller.select_conversation (conversation);
        } else {
            AddChatDialog dialog = new AddChatDialog (stream_interactor, stream_interactor.get_accounts ());
            dialog.set_filter (jid);
            dialog.added.connect ((conversation) => {
                controller.select_conversation (conversation);
            });
            present_dialog (dialog, window);
        }
    }

    private async void confirm_chat_invite (string jid, string preauth_token, string? suggested_name) {
        bool accepted = yield ask_xmpp_invite_confirmation (
            _("Contact Invitation"),
            _("This link invites you to contact %s. The authorization token is hidden and will not be shown.").printf (jid),
            _("Add Contact")
        );
        if (accepted) {
            add_contact_from_invite (jid, preauth_token, suggested_name);
        }
    }

    private async void confirm_muc_invite (string jid) {
        bool accepted = yield ask_xmpp_invite_confirmation (
            _("Group Invitation"),
            _("This link invites you to join %s. The authorization token is hidden and will not be shown.").printf (jid),
            _("Join")
        );
        if (accepted) {
            show_join_muc_dialog (null, jid);
        }
    }

    private async void confirm_user_invite_account_registration (string inviter_jid, string preauth_token) {
        string server = inviter_jid;
        try {
            Jid jid = new Jid (inviter_jid);
            server = jid.domain_jid.to_string ();
        } catch (InvalidJidError e) {
            warning ("Invalid contact invitation JID: %s", e.message);
            return;
        }

        bool accepted = yield ask_xmpp_invite_confirmation (
            _("Contact Invitation"),
            _("This link invites you to contact %s. You can create an account on %s to accept it.").printf (inviter_jid, server),
            _("Create Account")
        );
        if (accepted) {
            confirm_account_invite (server, preauth_token);
        }
    }

    private void confirm_account_invite (string jid, string preauth_token) {
        if (window == null) return;
        string invite_key = jid + "\n" + preauth_token;
        if (active_account_invite_dialogs.contains (invite_key)) {
            window.present ();
            return;
        }
        active_account_invite_dialogs.add (invite_key);
        var dialog = new Ui.ManageAccounts.AddAccountDialog (stream_interactor, db, false, jid, preauth_token);
        dialog.closed.connect (() => {
            active_account_invite_dialogs.remove (invite_key);
        });
        dialog.present (window);
    }

    private string muc_join_dialog_room_key (string jid) {
        string room_key = jid.strip ();
        try {
            room_key = new Jid (room_key).bare_jid.to_string ();
        } catch (InvalidJidError e) {
        }
        return room_key;
    }

    private string muc_join_dialog_key (Account? account, string jid) {
        string account_key = account != null ? ((!) account).id.to_string () : "any";
        string room_key = muc_join_dialog_room_key (jid);
        return account_key + "\n" + room_key;
    }

    private bool present_existing_muc_join_dialog (Account? account, string jid) {
        string dialog_key = muc_join_dialog_key (account, jid);
        if (active_muc_join_dialogs.has_key (dialog_key)) {
            present_dialog (active_muc_join_dialogs[dialog_key], window);
            return true;
        }

        string any_key = muc_join_dialog_key (null, jid);
        if (account != null && active_muc_join_dialogs.has_key (any_key)) {
            present_dialog (active_muc_join_dialogs[any_key], window);
            return true;
        }

        if (account == null) {
            string room_suffix = "\n" + muc_join_dialog_room_key (jid);
            foreach (string active_key in active_muc_join_dialogs.keys) {
                if (active_key.has_suffix (room_suffix)) {
                    present_dialog (active_muc_join_dialogs[active_key], window);
                    return true;
                }
            }
        }

        return false;
    }

    private void add_contact_from_invite (string jid, string? preauth_token, string? suggested_name) {
        try {
            new Jid (jid);
        } catch (InvalidJidError e) {
            warning ("Invalid contact invitation JID: %s", e.message);
            return;
        }

        AddContactDialog dialog = new AddContactDialog (stream_interactor, preauth_token);
        dialog.jid = jid;
        if (suggested_name != null && suggested_name != "") {
            dialog.alias = (!) suggested_name;
        }
        present_dialog (dialog, window);
    }

    private async bool ask_xmpp_invite_confirmation (string title, string body, string accept_label) {
        var dialog = new Adw.AlertDialog (title, body);
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("accept", accept_label);
        dialog.default_response = "accept";
        dialog.close_response = "cancel";
        dialog.set_response_appearance ("accept", Adw.ResponseAppearance.SUGGESTED);

        string response = yield dialog.choose (window, null);
        return response == "accept";
    }

    private void show_unsupported_xmpp_invite_dialog (string title, string body) {
        var dialog = new Adw.AlertDialog (title, body);
        dialog.add_response ("close", _("Close"));
        present_dialog (dialog, window);
    }

    private void show_room_action_error (string detail) {
        var dialog = new Adw.AlertDialog (_("Room action failed"), detail);
        dialog.add_response ("close", _("Close"));
        Util.present_window (window);
        present_dialog (dialog, window);
    }

    private void show_muc_invite_failure (string condition,
                                          string? server_text) {
        string detail;
        if (condition == ErrorStanza.CONDITION_FORBIDDEN &&
                (server_text == null || ((!) server_text).strip () == "")) {
            detail = _("The room rejected the invitation because your current role or affiliation is not allowed to invite contacts.");
        } else if (server_text != null && ((!) server_text).strip () != "") {
            detail = _("The room rejected the invitation: %s").printf (
                (!) server_text);
        } else {
            detail = _("The room rejected the invitation.");
        }
        show_room_action_error (detail);
    }

    private string get_voice_request_action_error (GLib.Error error) {
        if (error is IOError.CANCELLED) {
            return _("This permission request is no longer open.");
        }
        if (error is IOError.NOT_CONNECTED) {
            return _("You are no longer connected to this room.");
        }
        if (error is IOError.PERMISSION_DENIED ||
                error is IOError.INVALID_ARGUMENT) {
            return _("The current room state no longer allows this permission request to be answered.");
        }
        return _("The response to the permission request could not be sent. Please try again.");
    }

    private void create_ui_actions () {
        var administration_manager = stream_interactor.get_module<ServerAdministrationManager> (ServerAdministrationManager.IDENTITY);
        SimpleAction server_administration_action = new SimpleAction ("server-administration", null);
        server_administration_action.set_enabled (administration_manager.has_admin_accounts ());
        server_administration_action.activate.connect (show_server_administration_dialog);
        administration_manager.commands_changed.connect ((account) => {
            server_administration_action.set_enabled (administration_manager.has_admin_accounts ());
        });
        add_action (server_administration_action);

        SimpleAction preferences_action = new SimpleAction ("preferences", null);
        SimpleAction feeds_action = new SimpleAction ("feeds", null);
        feeds_action.activate.connect (() => {
            var feeds = new FeedsDialog (stream_interactor, controller.conversation);
            feeds.present (window);
        });
        add_action (feeds_action);
        set_accels_for_action ("app.feeds", KEY_COMBINATION_SHOW_FEEDS);
        preferences_action.activate.connect (() => {
            show_preferences_window ();
        });
        add_action (preferences_action);
        set_accels_for_action ("app.preferences", KEY_COMBINATION_SHOW_SETTINGS);

        SimpleAction preferences_page_action = new SimpleAction ("preferences-page", VariantType.STRING);
        preferences_page_action.activate.connect ((action, variant) => {
            string? page_name = variant != null ? variant.get_string () : null;
            show_preferences_window (page_name);
        });
        add_action (preferences_page_action);

        SimpleAction set_status_message_action = new SimpleAction ("set-status-message", null);
        set_status_message_action.activate.connect (show_status_message_dialog);
        add_action (set_status_message_action);

        SimpleAction preferences_account_action = new SimpleAction ("preferences-account", VariantType.INT32);
        preferences_account_action.activate.connect ((variant) => {
            Account? account = db.get_account_by_id (variant.get_int32 ());
            if (account == null) return;
            show_preferences_account_window (account);
        });
        add_action (preferences_account_action);

        SimpleAction about_action = new SimpleAction ("about", null);
        about_action.activate.connect (show_about_window);
        add_action (about_action);

        check_for_updates_action.activate.connect (start_update_check);
        add_action (check_for_updates_action);

        SimpleAction quit_action = new SimpleAction ("quit", null);
        quit_action.activate.connect (() => {
            if (systray_manager != null) {
                systray_manager.quit_application ();
            } else {
                quit ();
            }
        });
        add_action (quit_action);
        set_accels_for_action ("app.quit", KEY_COMBINATION_QUIT);

        // Systray actions
        SimpleAction show_window_action = new SimpleAction( "show-window", null);
        show_window_action.activate.connect (() => {
            if (systray_manager != null) {
                window.present ();
            }
        });
        add_action (show_window_action);

        SimpleAction hide_window_action = new SimpleAction ("hide-window", null);
        hide_window_action.activate.connect (() => {
            if (systray_manager != null && window != null) {
                systray_manager.hide_window ();
            }
        });
        add_action (hide_window_action);

        SimpleAction open_conversation_action = new SimpleAction ("open-conversation", VariantType.INT32);
        open_conversation_action.activate.connect ((variant) => {
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (variant.get_int32 ());
            if (conversation != null) controller.select_conversation (conversation);
            Util.present_window (window);
        });
        add_action (open_conversation_action);

        SimpleAction close_conversation_action = new SimpleAction ("close-conversation", VariantType.INT32);
        close_conversation_action.activate.connect ((variant) => {
            int conv_id = variant.get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conv_id);
            if (conversation != null) {
                if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                    stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).hide_conversation (conversation);
                } else {
                    stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).close_conversation (conversation);
                }
            }
        });
        add_action (close_conversation_action);

        SimpleAction leave_conversation_action = new SimpleAction ("leave-conversation", VariantType.INT32);
        leave_conversation_action.activate.connect ((variant) => {
            int conv_id = variant.get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conv_id);
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
            stream_interactor.get_module<MucManager> (MucManager.IDENTITY).part (conversation.account, conversation.counterpart);
        });
        add_action (leave_conversation_action);

        SimpleAction leave_conversation_permanently_action = new SimpleAction ("leave-conversation-permanently", VariantType.INT32);
        leave_conversation_permanently_action.activate.connect ((variant) => {
            int conv_id = variant.get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conv_id);
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;

            var dialog = new Adw.AlertDialog (
                _("Leave Group Permanently?"),
                _("This leaves the group, removes its bookmark, and stops DinoX from joining it automatically. The group is not destroyed and your local message history is kept.")
            );
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("leave", _("Leave Permanently"));
            dialog.set_response_appearance ("leave", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_default_response ("cancel");
            dialog.set_close_response ("cancel");

            dialog.response.connect ((response) => {
                if (response != "leave") return;
                stream_interactor.get_module<MucManager> (MucManager.IDENTITY).leave_permanently.begin (conversation.account, conversation.counterpart, (obj, res) => {
                    try {
                        stream_interactor.get_module<MucManager> (MucManager.IDENTITY).leave_permanently.end (res);
                    } catch (GLib.Error e) {
                        var error_dialog = new Adw.AlertDialog (_("Failed to leave group"), e.message);
                        error_dialog.add_response ("close", _("Close"));
                        present_dialog (error_dialog, window);
                    }
                });
            });

            present_dialog (dialog, window);
        });
        add_action (leave_conversation_permanently_action);

        // Hide conversation: removes from sidebar without leaving MUC rooms
        SimpleAction hide_conversation_action = new SimpleAction ("hide-conversation", VariantType.INT32);
        hide_conversation_action.activate.connect ((variant) => {
            int conv_id = variant.get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conv_id);
            if (conversation != null) {
                stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).hide_conversation (conversation);
            }
        });
        add_action (hide_conversation_action);

        SimpleAction open_conversation_details_action = new SimpleAction ("open-conversation-details", new VariantType("(is)"));
        open_conversation_details_action.activate.connect ((variant) => {
            int conversation_id = variant.get_child_value (0).get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conversation_id);
            if (conversation == null) return;

            string stack_value = variant.get_child_value (1).get_string ();

            var conversation_details = ConversationDetails.setup_dialog (conversation, stream_interactor);
            conversation_details.select_page(stack_value);
            present_dialog (conversation_details, window);
        });
        add_action (open_conversation_details_action);

        SimpleAction deny_subscription_action = new SimpleAction ("deny-subscription", VariantType.INT32);
        deny_subscription_action.activate.connect ((variant) => {
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (variant.get_int32 ());
            if (conversation == null || conversation.type_ != Conversation.Type.CHAT) return;
            var presence = stream_interactor.get_module<PresenceManager> (PresenceManager.IDENTITY);
            presence.deny_subscription_async.begin (conversation.account, conversation.counterpart, (obj, result) => {
                try {
                    presence.deny_subscription_async.end (result);
                } catch (IOError error) {
                    presence.subscription_action_failed (conversation.counterpart.bare_jid, conversation.account);
                }
            });
        });
        add_action (deny_subscription_action);

        var weak_app = WeakRef(this);
        stream_interactor.get_module<PresenceManager> (PresenceManager.IDENTITY).subscription_action_failed.connect((jid, account) => {
            var app = weak_app.get() as Application;
            if (app == null || app.window == null) return;
            var dialog = new Adw.AlertDialog(_("Could not update contact permissions"),
                _("The request for %s on %s could not be completed. Check your connection and try again.")
                    .printf(jid.bare_jid.to_string(), account.bare_jid.to_string()));
            dialog.add_response("close", _("Close"));
            app.present_dialog(dialog, app.window);
        });

        SimpleAction contacts_action = new SimpleAction ("add_chat", null);
        contacts_action.activate.connect (() => {
            if (active_add_chat_dialog != null) {
                present_dialog ((!) active_add_chat_dialog, window);
                return;
            }

            AddChatDialog add_chat_dialog = new AddChatDialog (stream_interactor, stream_interactor.get_accounts ());
            active_add_chat_dialog = add_chat_dialog;
            add_chat_dialog.closed.connect (() => {
                if (active_add_chat_dialog == add_chat_dialog) {
                    active_add_chat_dialog = null;
                }
            });
            add_chat_dialog.added.connect ((conversation) => controller.select_conversation (conversation));
            present_dialog (add_chat_dialog, window);
        });
        add_action (contacts_action);
        set_accels_for_action ("app.add_chat", KEY_COMBINATION_ADD_CHAT);

        SimpleAction conference_action = new SimpleAction ("add_conference", null);
        conference_action.activate.connect (() => {
            if (active_add_conference_dialog != null) {
                present_dialog ((!) active_add_conference_dialog, window);
                return;
            }

            AddConferenceDialog add_conference_dialog = new AddConferenceDialog (stream_interactor);
            active_add_conference_dialog = add_conference_dialog;
            add_conference_dialog.closed.connect (() => {
                if (active_add_conference_dialog == add_conference_dialog) {
                    active_add_conference_dialog = null;
                }
            });
            Idle.add (() => {
                present_dialog (add_conference_dialog, window);
                return Source.REMOVE;
            });
        });
        add_action (conference_action);
        set_accels_for_action ("app.add_conference", KEY_COMBINATION_ADD_CONFERENCE);

        SimpleAction create_invite_action = new SimpleAction ("create_invite", null);
        create_invite_action.activate.connect (() => {
            CreateInviteDialog dialog = new CreateInviteDialog (stream_interactor);
            present_dialog (dialog, window);
        });
        add_action (create_invite_action);

        SimpleAction accept_muc_invite_action = new SimpleAction ("open-muc-join", VariantType.INT32);
        accept_muc_invite_action.activate.connect ((variant) => {
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (variant.get_int32 ());
            if (conversation == null || conversation.type_ != Conversation.Type.GROUPCHAT) return;
            show_join_muc_dialog (conversation.account, conversation.counterpart.to_string ());
        });
        add_action (accept_muc_invite_action);

        SimpleAction open_pending_muc_invite_action = new SimpleAction ("open-muc-invite", VariantType.INT32);
        open_pending_muc_invite_action.activate.connect ((variant) => {
            show_muc_invite_dialog (variant.get_int32 ());
        });
        add_action (open_pending_muc_invite_action);

        SimpleAction accept_pending_muc_invite_action = new SimpleAction ("accept-muc-invite", VariantType.INT32);
        accept_pending_muc_invite_action.activate.connect ((variant) => {
            show_muc_invite_dialog (variant.get_int32 ());
        });
        add_action (accept_pending_muc_invite_action);

        SimpleAction deny_pending_muc_invite_action = new SimpleAction ("deny-muc-invite", VariantType.INT32);
        deny_pending_muc_invite_action.activate.connect ((variant) => {
            stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY).decline (variant.get_int32 ());
        });
        add_action (deny_pending_muc_invite_action);

        SimpleAction accept_voice_request_action = new SimpleAction (
            "accept-voice-request", VariantType.STRING);
        accept_voice_request_action.activate.connect ((variant) => {
            string request_id = variant.get_string ();
            MucVoiceRequestManager manager = stream_interactor.get_module<
                MucVoiceRequestManager> (MucVoiceRequestManager.IDENTITY);
            manager.accept.begin (request_id, (obj, res) => {
                try {
                    manager.accept.end (res);
                } catch (GLib.Error e) {
                    warning ("Failed to grant MUC voice request %s: %s",
                        request_id, e.message);
                    show_room_action_error (
                        get_voice_request_action_error (e));
                }
            });
        });
        add_action (accept_voice_request_action);

        SimpleAction deny_voice_request_action = new SimpleAction (
            "deny-voice-request", VariantType.STRING);
        deny_voice_request_action.activate.connect ((variant) => {
            string request_id = variant.get_string ();
            MucVoiceRequestManager manager = stream_interactor.get_module<
                MucVoiceRequestManager> (MucVoiceRequestManager.IDENTITY);
            manager.deny.begin (request_id, (obj, res) => {
                try {
                    manager.deny.end (res);
                } catch (GLib.Error e) {
                    warning ("Failed to deny MUC voice request %s: %s",
                        request_id, e.message);
                    show_room_action_error (
                        get_voice_request_action_error (e));
                }
            });
        });
        add_action (deny_voice_request_action);

        SimpleAction set_status_action = new SimpleAction ("set-status", VariantType.STRING);
        set_status_action.activate.connect ((variant) => {
            string status = variant.get_string ();
            var pm = stream_interactor.get_module<PresenceManager> (PresenceManager.IDENTITY);
            pm.set_status (status, pm.get_current_status_msg ());
        });
        add_action (set_status_action);

        SimpleAction loop_conversations_action = new SimpleAction ("loop_conversations", null);
        loop_conversations_action.activate.connect (() => { window.loop_conversations (false); });
        add_action (loop_conversations_action);
        set_accels_for_action ("app.loop_conversations", KEY_COMBINATION_LOOP_CONVERSATIONS);

        SimpleAction loop_conversations_bw_action = new SimpleAction ("loop_conversations_bw", null);
        loop_conversations_bw_action.activate.connect (() => { window.loop_conversations (true); });
        add_action (loop_conversations_bw_action);
        set_accels_for_action ("app.loop_conversations_bw", KEY_COMBINATION_LOOP_CONVERSATIONS_REV);

        SimpleAction accept_call_action = new SimpleAction ("accept-call", new VariantType("(ii)"));
        accept_call_action.activate.connect ((variant) => {
            int conversation_id = variant.get_child_value (0).get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conversation_id);
            if (conversation == null) return;

            int call_id = variant.get_child_value (1).get_int32 ();
            Call? call = stream_interactor.get_module<CallStore> (CallStore.IDENTITY).get_call_by_id (call_id, conversation);
            if (call == null) return;
            CallState? call_state = stream_interactor.get_module<Calls> (Calls.IDENTITY).call_states[call];
            if (call_state == null) return;

            call_state.accept ();

            var call_window = new CallWindow ();
            call_window.controller = new CallWindowController (call_window, call_state, stream_interactor);
            call_window.present ();
        });
        add_action (accept_call_action);

        SimpleAction deny_call_action = new SimpleAction ("reject-call", new VariantType("(ii)"));
        deny_call_action.activate.connect ((variant) => {
            int conversation_id = variant.get_child_value (0).get_int32 ();
            Conversation? conversation = stream_interactor.get_module<ConversationManager> (ConversationManager.IDENTITY).get_conversation_by_id (conversation_id);
            if (conversation == null) return;

            int call_id = variant.get_child_value (1).get_int32 ();
            Call? call = stream_interactor.get_module<CallStore> (CallStore.IDENTITY).get_call_by_id (call_id, conversation);
            if (call == null) return;
            CallState? call_state = stream_interactor.get_module<Calls> (Calls.IDENTITY).call_states[call];
            if (call_state == null) return;

            call_state.reject ();
        });
        add_action (deny_call_action);
    }

    private void show_status_message_dialog () {
        // Adw.Dialog cannot be mapped inside a hidden parent (including the
        // floating Windows presentation). Tray actions may start here hidden.
        if (window != null) Util.present_window (window);
        var presence_manager = stream_interactor.get_module<PresenceManager> (PresenceManager.IDENTITY);
        string current_status = presence_manager.get_current_status_msg () ?? "";

        var dialog = new Adw.AlertDialog (_("Set Status Message"), null);
        var entry = new Entry ();
        entry.placeholder_text = _("Status Message");
        entry.text = current_status;
        entry.activate.connect (() => {
            dialog.response ("set");
        });

        dialog.extra_child = entry;
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("set", _("Set"));
        dialog.default_response = "set";
        dialog.close_response = "cancel";

        dialog.response.connect ((response) => {
            if (response == "set") {
                presence_manager.set_status (presence_manager.get_current_show (), entry.text);
            }
        });

        present_dialog (dialog, window);
    }

    private void show_server_administration_dialog () {
        bool timing = UiTiming.enabled ();
        int64 open_start_us = timing ? UiTiming.now_us () : 0;
        var administration_manager = stream_interactor.get_module<ServerAdministrationManager> (ServerAdministrationManager.IDENTITY);
        if (!administration_manager.has_admin_accounts ()) return;

        if (active_server_administration_dialog != null) {
            present_dialog ((!) active_server_administration_dialog, window);
            if (timing) UiTiming.log_ms ("ServerAdministration.open: reuse active", open_start_us);
            return;
        }

        int64 construct_start_us = timing ? UiTiming.now_us () : 0;
        var dialog = new ServerAdministrationDialog (administration_manager);
        if (timing) UiTiming.log_ms ("ServerAdministration.open: construct", construct_start_us);
        active_server_administration_dialog = dialog;
        dialog.closed.connect (() => {
            if (active_server_administration_dialog == dialog) {
                active_server_administration_dialog = null;
            }
        });
        int64 present_start_us = timing ? UiTiming.now_us () : 0;
        present_dialog (dialog, window);
        if (timing) {
            UiTiming.log_ms ("ServerAdministration.open: present", present_start_us);
            UiTiming.log_ms ("ServerAdministration.open: callback", open_start_us);
            dialog.add_tick_callback ((widget, frame_clock) => {
                UiTiming.log_ms ("ServerAdministration.open: first tick", open_start_us);
                return Source.REMOVE;
            });
        }
    }

    private void show_preferences_window (string? navigate_to_page = null) {
        bool timing = UiTiming.enabled ();
        int64 open_start_us = timing ? UiTiming.now_us () : 0;
        if (cached_preferences_dialog == null) {
            int64 stage_start_us = timing ? UiTiming.now_us () : 0;
            cached_preferences_dialog = new Ui.PreferencesDialog ();
            if (timing) UiTiming.log_ms ("Preferences.open: construct", stage_start_us);
            stage_start_us = timing ? UiTiming.now_us () : 0;
            configure_preferences (cached_preferences_dialog);
            if (timing) UiTiming.log_ms ("Preferences.open: configure plugins", stage_start_us);
            stage_start_us = timing ? UiTiming.now_us () : 0;
            cached_preferences_dialog.model.populate (db, stream_interactor);
            if (timing) UiTiming.log_ms ("Preferences.open: populate model", stage_start_us);
            cached_preferences_dialog.backup_requested.connect (() => {
                string data_dir = Path.build_filename (Environment.get_user_data_dir (), "dinox");
                create_backup (data_dir);
            });
            cached_preferences_dialog.restore_backup_requested.connect (() => restore_from_backup ());
            cached_preferences_dialog.show_data_location.connect (() => show_data_location_dialog ());
            cached_preferences_dialog.change_db_password_requested.connect (() => show_change_db_password_dialog ());
            cached_preferences_dialog.clear_cache_requested.connect (() => clear_cache ());
            cached_preferences_dialog.reset_database_requested.connect (() => reset_database ());
            cached_preferences_dialog.factory_reset_requested.connect (() => factory_reset ());
        }
        int64 present_start_us = timing ? UiTiming.now_us () : 0;
        present_dialog (cached_preferences_dialog, window);
        if (timing) UiTiming.log_ms ("Preferences.open: present", present_start_us);
        
        // Navigate to specific page if requested (e.g. "tor" from the Tor indicator)
        if (navigate_to_page != null) {
            cached_preferences_dialog.set_visible_page_name (navigate_to_page);
        }
        if (timing) {
            UiTiming.log_ms ("Preferences.open: callback", open_start_us);
            cached_preferences_dialog.add_tick_callback ((widget, frame_clock) => {
                UiTiming.log_ms ("Preferences.open: first tick", open_start_us);
                return Source.REMOVE;
            });
        }
    }

    private void show_change_db_password_dialog () {
        if (!profile_operation_available ()) return;
        if (this.db_key == null) {
            warning ("Cannot change database password: db_key is not set");
            return;
        }

        var old_entry = new Gtk.PasswordEntry ();
        old_entry.hexpand = true;
        old_entry.show_peek_icon = true;

        var new_entry = new Gtk.PasswordEntry ();
        new_entry.hexpand = true;
        new_entry.show_peek_icon = true;

        var new_entry_confirm = new Gtk.PasswordEntry ();
        new_entry_confirm.hexpand = true;
        new_entry_confirm.show_peek_icon = true;

        var grid = new Gtk.Grid ();
        grid.row_spacing = 12;
        grid.column_spacing = 12;
        grid.margin_top = 6;
        grid.margin_bottom = 6;
        grid.margin_start = 6;
        grid.margin_end = 6;

        var l_old = new Gtk.Label (_("Current Password"));
        l_old.halign = Gtk.Align.START;
        var l_new = new Gtk.Label (_("New Password"));
        l_new.halign = Gtk.Align.START;
        var l_new2 = new Gtk.Label (_("Confirm New Password"));
        l_new2.halign = Gtk.Align.START;

        grid.attach (l_old, 0, 0, 1, 1);
        grid.attach (old_entry, 0, 1, 1, 1);
        grid.attach (l_new, 0, 2, 1, 1);
        grid.attach (new_entry, 0, 3, 1, 1);
        grid.attach (l_new2, 0, 4, 1, 1);
        grid.attach (new_entry_confirm, 0, 5, 1, 1);

        var dialog = new Adw.AlertDialog (
            _("Change Database Password"),
            _("DinoX will restart to change the database password safely. After restarting, enter your current password once to complete the change. Existing messages and files will remain readable.")
);
        dialog.extra_child = grid;
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("change", _("Change"));
        dialog.default_response = "change";
        dialog.close_response = "cancel";

        dialog.response.connect ((response) => {
            if (response != "change") return;

            string old_pw = old_entry.text ?? "";
            string new_pw = new_entry.text ?? "";
            string new_pw2 = new_entry_confirm.text ?? "";

            if (old_pw != (!)this.db_key) {
                warning ("Change DB password failed: wrong current password");
                Idle.add (() => { show_change_db_password_dialog (); return false; });
                return;
            }
            if (new_pw.strip ().length == 0) {
                warning ("Change DB password failed: empty new password");
                Idle.add (() => { show_change_db_password_dialog (); return false; });
                return;
            }
            if (new_pw != new_pw2) {
                warning ("Change DB password failed: mismatch");
                Idle.add (() => { show_change_db_password_dialog (); return false; });
                return;
            }

            if (!profile_operation_available ()) return;
            try {
                ProfileMaintenance.schedule_password_change (((!) profile_lock).profile_dir,
                    (!) this.db_key, new_pw);
                schedule_profile_restart ();
                quit ();
            } catch (Error e) {
                warning ("Change DB password failed: %s", e.message);
                var error_dialog = new Adw.AlertDialog (_("Password Change Could Not Be Completed"),
                    _("Close DinoX and start it again. If the change was prepared successfully, it will continue after you enter your current password.") + "\n\n" + e.message);
                error_dialog.add_response ("close", _("Close"));
                present_dialog (error_dialog, window);
                return;
            }
        });

        present_dialog (dialog, window);
    }

    private void show_preferences_account_window (Account account) {
        show_preferences_window();
        if (cached_preferences_dialog != null) {
            cached_preferences_dialog.accounts_page.account_chosen (account);
        }
    }

    private void start_update_check () {
        if (update_check_cancellable != null) return;

        Util.present_window (window);
        var cancellable = new Cancellable ();
        update_check_cancellable = cancellable;
        check_for_updates_action.set_enabled (false);

        var progress_dialog = new Adw.AlertDialog (
            _("Checking for Updates…"),
            _("Contacting the DinoX release server…")
        );
        var spinner = new Gtk.Spinner ();
        spinner.spinning = true;
        spinner.width_request = 48;
        spinner.height_request = 48;
        spinner.halign = Gtk.Align.CENTER;
        spinner.margin_top = 12;
        spinner.margin_bottom = 12;
        progress_dialog.set_extra_child (spinner);
        progress_dialog.add_response ("cancel", _("Cancel"));
        progress_dialog.set_close_response ("cancel");

        bool check_finished = false;
        progress_dialog.response.connect ((response) => {
            if (!check_finished && response == "cancel") {
                cancellable.cancel ();
            }
        });
        present_dialog (progress_dialog, window);

        var checker = new UpdateChecker ();
        checker.check.begin (Dino.get_version (), cancellable, (obj, res) => {
            UpdateCheckResult? result = null;
            bool cancelled = cancellable.is_cancelled ();
            try {
                result = checker.check.end (res);
            } catch (UpdateCheckError.CANCELLED error) {
                cancelled = true;
            } catch (Error error) {
                warning ("Manual update check failed: %s", error.message);
            }

            check_finished = true;
            if (!cancelled) {
                progress_dialog.force_close ();
            }
            update_check_cancellable = null;
            check_for_updates_action.set_enabled (true);

            if (cancelled) return;
            if (result == null) {
                show_update_check_failure ();
                return;
            }
            show_update_check_result ((!) result);
        });
    }

    private void show_update_check_result (UpdateCheckResult result) {
        Adw.AlertDialog dialog;
        if (result.update_available) {
            dialog = new Adw.AlertDialog (
                _("Update Available"),
                _("DinoX %s is available. Installed version: %s.").printf (
                    result.latest_release.version,
                    result.current_version
                )
            );

            var release_link = new Gtk.LinkButton.with_label (
                result.latest_release.release_url,
                _("Open Release Page")
            );
            release_link.halign = Gtk.Align.CENTER;
            release_link.margin_top = 12;
            release_link.margin_bottom = 6;
            release_link.set_tooltip_text (result.latest_release.release_url);
            dialog.set_extra_child (release_link);
        } else {
            dialog = new Adw.AlertDialog (
                _("No New Version Available"),
                _("Installed version: %s\nLatest published version: %s").printf (
                    result.current_version,
                    result.latest_release.version
                )
            );
        }

        dialog.add_response ("close", _("Close"));
        dialog.set_close_response ("close");
        present_dialog (dialog, window);
    }

    private void show_update_check_failure () {
        var dialog = new Adw.AlertDialog (
            _("Update Check Failed"),
            _("DinoX could not check for updates. Check your internet connection and try again.")
        );
        dialog.add_response ("close", _("Close"));
        dialog.set_close_response ("close");
        present_dialog (dialog, window);
    }

    private void show_about_window () {
        string? version = Dino.get_version ().strip ().length == 0 ? null : Dino.get_version ();
        if (version != null && !version.contains ("git")) {
            switch (version.substring (0, 3)) {
                case "0.2": version = @"$version - Mexican Caribbean Coral Reefs"; break;
                case "0.3": version = @"$version - Theikenmeer"; break;
                case "0.4": version = @"$version - Ilulissat"; break;
                case "0.5": version = @"$version - Alentejo"; break;
            }
        }

        Adw.AboutDialog about_dialog = new Adw.AboutDialog ();
        about_dialog.application_icon = "im.dinox.dinox";
        about_dialog.application_name = "DinoX";
        about_dialog.issue_url = "https://git.dinox.im/dinoxim/dinox/issues";
        about_dialog.support_url = "mailto:contact@dinox.im";
        about_dialog.title = _("About DinoX");
        about_dialog.version = version;
        about_dialog.website = "https://dinox.im";
        about_dialog.copyright = "Copyright © 2025-2026 - DinoX Team\nBased on Dino — Copyright © 2016-2025 - Dino Team";
        about_dialog.license_type = License.GPL_3_0;
        about_dialog.add_legal_section(
            _("Third-party components"),
            null,
            License.CUSTOM,
            _("DinoX uses third-party components under their respective licenses. See the "
                + "<a href=\"https://git.dinox.im/dinoxim/dinox/src/branch/master/README.md#user-content-license\">"
                + "license information</a> for package-specific notices and corresponding-source details.")
        );
        about_dialog.comments = _("Modern XMPP client with extended features");

        // Add debug info with data location
        string data_dir = Path.build_filename( Environment.get_user_data_dir( ), "dinox");
        string config_dir = Path.build_filename (Environment.get_user_config_dir (), "dinox");
        string cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "dinox");

        string env_type = "Native (deb / source)";
        if (Environment.get_variable("FLATPAK_ID") != null) {
            env_type = "Flatpak";
        } else if (Environment.get_variable("APPIMAGE") != null) {
            env_type = "AppImage";
        }

        string support_info = _("User Data Locations (%s)").printf(env_type) + """
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

""" + _("Data & Database:") + """
%s

""" + _("Configuration:") + """
%s

""" + _("Cache:") + """
%s

ℹ """ + _("Info:") + """
""" + _("Your personal data (accounts, messages, files) is stored separately from the application.") + """

""" + _("When you update DinoX, your data remains intact.") + """

""" + _("Use Settings → General → Backup User Data to create a backup.");
        support_info = support_info.printf (data_dir, config_dir, cache_dir);

        about_dialog.debug_info = support_info;
        about_dialog.debug_info_filename = "dinox-data-locations.txt";

        string[] developers = {
            "DinoX Team",
            "Dino Team (Dino Project)",
            null
        };
        dino_about_dialog_set_developers (about_dialog, developers);

        present_dialog (about_dialog, window);
    }

    public void restore_from_backup () {
        if (!profile_operation_available ()) return;
        var file_chooser = new Gtk.FileDialog ();
        file_chooser.title = _("Select Backup File");
        file_chooser.modal = true;

        // Filter for backup files (both encrypted and unencrypted)
        var filter = new Gtk.FileFilter( );
        filter.add_pattern ("*.tar.gz");
        filter.add_pattern ("*.tar.gz.gpg");
        filter.add_pattern ("*.tgz");
        filter.set_filter_name (_("Backup Files (*.tar.gz, *.tar.gz.gpg)"));

        var filters = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        file_chooser.filters = filters;
        file_chooser.default_filter = filter;

        file_chooser.open.begin (window, null, (obj, res) => {
            GLib.File? file = null;
            try {
                file = file_chooser.open.end (res);
            } catch (Error err) {
                // User cancelled
                return;
            }

            if (file != null) {
                string path = file.get_path ();
                // Check if encrypted backup
                if (path.has_suffix( ".gpg")) {
                    show_password_dialog_for_restore (path);
                } else {
                    confirm_restore_backup (path, null);
                }
            }
        });
    }

    private void show_password_dialog_for_restore (string backup_path) {
        var dialog = new Adw.AlertDialog (
            _("Enter Backup Password"),
            _("This backup is encrypted. Please enter the password to decrypt it.")
);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.margin_start = 24;
        box.margin_end = 24;

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.show_peek_icon = true;
        password_entry.placeholder_text = _("Password");
        password_entry.activates_default = true;

        box.append (password_entry);
        dialog.set_extra_child (box);

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("ok", _("Decrypt & Restore"));
        dialog.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("ok");
        dialog.set_close_response ("cancel");

        // Enable OK button only when password is entered
        dialog.set_response_enabled( "ok", false);
        password_entry.changed.connect (() => {
            dialog.set_response_enabled ("ok", password_entry.text.length > 0);
        });

        dialog.response.connect ((response) => {
            if (response == "ok" && password_entry.text.length > 0) {
                confirm_restore_backup (backup_path, password_entry.text);
            }
        });

        present_dialog (dialog, window);
    }

    private void confirm_restore_backup (string backup_path, string? password) {
        var dialog = new Adw.AlertDialog (
            _("Restore from Backup"),
            _("This will replace all current data with the backup.\n\n<b>Current accounts, messages and settings will be overwritten!</b>\n\nDinoX will restart after restoring.")
);
        dialog.body_use_markup = true;

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("restore", _("Restore Backup"));
        dialog.set_response_appearance ("restore", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "restore") {
                perform_restore_backup (backup_path, password);
            }
        });

        present_dialog (dialog, window);
    }

    private void cleanup_profile_stage (string? directory) {
        if (directory == null || profile_lock == null) return;
        try {
            string profile = ((!) profile_lock).profile_dir;
            if (Path.get_basename (directory).has_prefix ("dinox-restore-stage-")) {
                ProfileRestore.discard_stage (profile, directory);
            } else {
                ProfileDeletion.cleanup_backup_stage (profile, directory);
            }
        } catch (Error err) {
            warning ("Could not remove temporary profile staging: %s", err.message);
        }
    }

    private void schedule_profile_restart (bool deletion_only = false) throws Error {
#if WINDOWS
        schedule_windows_profile_restart (deletion_only);
#else
        string? exe_path = Environment.get_variable ("APPIMAGE");
        if (exe_path == null || !FileUtils.test (exe_path, FileTest.IS_EXECUTABLE)) {
            exe_path = FileUtils.read_link ("/proc/self/exe");
        }
        // Keep arguments out of shell source, and wait for complete process exit.
        string[] argv = { "/bin/sh", "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -le 120 ] || exit 1; sleep 1; done; if [ \"$3\" = yes ]; then exec \"$2\" --apply-pending-profile-deletion; else exec \"$2\" --complete-profile-maintenance; fi",
            "dinox-restore-restart", ((int) Posix.getpid ()).to_string (), exe_path, deletion_only ? "yes" : "no" };
        spawn_subprocess (argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
#endif
    }

    private void perform_restore_backup (string backup_path, string? password = null) {
        if (!profile_operation_available () || profile_lock == null) return;
        var cancellable = begin_profile_operation ();
        var progress_dialog = new Adw.AlertDialog (_("Restoring Backup…"),
            _("Please wait, this may take a moment…"));
        var spinner = new Gtk.Spinner () { spinning = true, height_request = 48,
            halign = Gtk.Align.CENTER, margin_top = 12, margin_bottom = 12 };
        progress_dialog.set_extra_child (spinner);
        progress_dialog.set_close_response ("none");
        present_dialog (progress_dialog, window);

        string profile = ((!) profile_lock).profile_dir;
        string staging_root = Path.build_filename (Path.get_dirname (profile),
            "dinox-restore-stage-" + Uuid.string_random ());
        active_restore_stage = staging_root;
        profile_worker = new Thread<void*> ("restore-backup", () => {
            bool success = false;
            string? error_message = null;
            string tar_path = backup_path;
            try {
                ProfileRestore.prepare_stage (profile, staging_root);
                if (password != null && backup_path.has_suffix (".gpg")) {
                    tar_path = Path.build_filename (staging_root, "restore.tar.gz");
                    string openssl_exe = get_backup_openssl_executable ();
                    string backup_file = backup_path;
                    string[] dec_argv = {
                        openssl_exe, "enc", "-d", "-aes-256-cbc", "-pbkdf2",
                        "-in", backup_file,
                        "-out", tar_path,
                        "-pass", "stdin"
                    };
                    Subprocess proc = spawn_subprocess (dec_argv,
                        SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
                    if (!communicate_profile_process (proc, password, cancellable, out error_message)) {
                        throw new IOError.FAILED (_("Could not decrypt the backup file.\n\nPlease check if the password is correct."));
                    }
                }
                cancellable.set_error_if_cancelled ();
                int exit_status;
                string? stderr_str;
#if WINDOWS
                success = run_windows_backup_archive_subprocess (
                        true,
                        staging_root,
                        tar_path,
                        null,
                        out exit_status,
                        out stderr_str,
                        cancellable
                );
#else
                string[] argv = { "tar", "-xzf", tar_path, "-C", staging_root,
                    "--no-same-owner", "--no-same-permissions", "--", "dinox" };
                Subprocess proc = spawn_subprocess (argv,
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
                success = communicate_profile_process (proc, "", cancellable, out stderr_str);
                exit_status = proc.get_exit_status ();
#endif
                if (!success) throw new IOError.FAILED (stderr_str ?? "Archive extraction failed (%d)".printf (exit_status));
                if (tar_path != backup_path) FileUtils.unlink (tar_path);
                cancellable.set_error_if_cancelled ();
            } catch (Error err) {
                success = false;
                error_message = err.message;
            }
            if (!success) cleanup_profile_stage (staging_root);

            Idle.add (() => {
                // Schedule on the UI thread so a panic request cannot race with
                // publication of a pending restore that would recreate wiped data.
                if (success && cancellable.is_cancelled ()) {
                    cleanup_profile_stage (staging_root);
                    success = false;
                }
                if (success) {
                    try {
                        ProfileRestore.schedule (profile, staging_root);
                        active_restore_stage = null;
                    } catch (Error err) {
                        // A durable publish can report an I/O error after the
                        // manifest appeared; preserve its stage for recovery.
                        try {
                            if (!ProfileRestore.has_pending (profile)) cleanup_profile_stage (staging_root);
                        } catch (Error pending_error) {
                            warning ("Could not inspect pending restore: %s", pending_error.message);
                        }
                        success = false;
                        error_message = err.message;
                    }
                }
                if (!finish_profile_operation ()) return false;
                spinner.spinning = false;
                if (success) {
                    progress_dialog.heading = _("Restore Prepared");
                    try {
                        schedule_profile_restart ();
                        progress_dialog.body = _("DinoX will now restart…");
                        // Graceful shutdown finishes all writes to the OLD profile.
                        // Only the next process may install the restored one.
                        quit ();
                    } catch (Error err) {
                        warning ("Could not restart after staging restore: %s", err.message);
                        progress_dialog.body = _("The backup is prepared. Close and reopen DinoX to complete the restore.");
                        progress_dialog.add_response ("close", _("Close"));
                        progress_dialog.set_close_response ("close");
                    }
                } else {
                    progress_dialog.heading = _("Restore Failed");
                    progress_dialog.body = _("Could not restore the backup file.\n\nError: %s").printf (error_message ?? _("Unknown error"));
                    progress_dialog.add_response ("close", _("Close"));
                    progress_dialog.set_close_response ("close");
                }
                return false;
            });
            return null;
        });
    }

    private static string get_backup_openssl_executable () {
#if WINDOWS
        string bundled = Path.build_filename (get_executable_dir (), "bin", "openssl.exe");
        if (FileUtils.test (bundled, FileTest.IS_REGULAR)) return bundled;
        string msys = "C:\\msys64\\mingw64\\bin\\openssl.exe";
        if (FileUtils.test (msys, FileTest.IS_REGULAR)) return msys;
#endif
        return "openssl";
    }

    private void show_data_location_dialog () {
        string config_dir = Path.build_filename (Environment.get_user_config_dir (), "dinox");
        string data_dir = Path.build_filename (Environment.get_user_data_dir (), "dinox");
        string cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "dinox");

        string env_type = "Native (deb / source)";
        if (Environment.get_variable("FLATPAK_ID") != null) {
            env_type = "Flatpak";
        } else if (Environment.get_variable("APPIMAGE") != null) {
            env_type = "AppImage";
        }

        var dialog = new Adw.AlertDialog (
            _("User Data Locations (%s)").printf(env_type),
            null
);

        string message = """<b>%s</b>
%s

<b>%s</b>
%s

<b>%s</b>
%s

<small>%s</small>""".printf( 
            Markup.escape_text (_("Configuration:")),
            Markup.escape_text (config_dir),
            Markup.escape_text (_("Data & Database:")),
            Markup.escape_text (data_dir),
            Markup.escape_text (_("Cache:")),
            Markup.escape_text (cache_dir),
            Markup.escape_text (_("Your personal data (accounts, messages, files) is stored separately from the application. When you update DinoX, your data remains intact."))
);

        dialog.body_use_markup = true;
        dialog.body = message;
        dialog.add_response ("close", _("Close"));
        dialog.set_response_appearance ("close", Adw.ResponseAppearance.DEFAULT);
        present_dialog (dialog, window);
    }

    private void clear_cache () {
        if (!profile_operation_available ()) return;
        string cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "dinox");

        var dialog = new Adw.AlertDialog (
            _("Clear Cache"),
            _("This will delete cached avatars, previews and service discovery data for all accounts.\n\nContacts, local sticker packs, encryption keys, message archive sync state and files currently in use are kept.")
);

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("clear", _("Clear Cache"));
        dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "clear") {
                perform_clear_cache (cache_dir);
            }
        });

        present_dialog (dialog, window);
    }

    private void perform_clear_cache (string cache_dir) {
        if (cache_clear_in_progress || !profile_operation_available ()) return;
        var cancellable = begin_profile_operation ();
        cache_clear_in_progress = true;
        var toast_overlay = window.get_first_child () as Adw.ToastOverlay;

        // Fence queued avatar writes before deleting the filesystem cache.
        // The in-memory purge stays after the worker/database phase so it
        // cannot start lifecycle resync while cache deletion is still active.
        var avatar_mgr = stream_interactor.get_module<AvatarManager> (
            AvatarManager.IDENTITY);
        if (avatar_mgr != null) {
            avatar_mgr.begin_cache_clear ();
        }

        profile_worker = new Thread<void*> ("clear-cache", () => {
            int64 freed_bytes = 0;
            int db_rows_deleted = 0;
            bool success = true;

            // 1. Clear regenerable data, preserving active media and runtime files.
            try {
                freed_bytes = ProfileDeletion.clear_disposable_caches (cache_dir, cancellable);
            } catch (Error err) {
                success = false;
                warning ("Failed to clear filesystem cache: %s", err.message);
            }

            Idle.add (() => {
                // Keep the complete savepoint on the main context. SQLite's
                // per-call mutex cannot prevent other main-context writes
                // from joining a transaction opened on a background thread.
                try {
                    cancellable.set_error_if_cancelled ();
                    db_rows_deleted = db.purge_caches ();
                } catch (Error err) {
                    success = false;
                    warning ("Failed to clear database caches: %s", err.message);
                }
                // 3. Clear in-memory avatar state and allow new-generation
                // writes only after filesystem and database deletion ended.
                if (avatar_mgr != null) {
                    avatar_mgr.finish_cache_clear ();
                }
                cache_clear_in_progress = false;
                if (!finish_profile_operation ()) return false;
                if (toast_overlay != null) {
                    Adw.Toast toast;
                    if (success) {
                        string size_str = format_size (freed_bytes);
                        toast = new Adw.Toast (_("Cache cleared (%s freed, %d DB rows removed)").printf (size_str, db_rows_deleted));
                        toast.timeout = 3;
                    } else {
                        toast = new Adw.Toast (_("Failed to clear cache"));
                        toast.timeout = 3;
                    }
                    toast_overlay.add_toast (toast);
                }
                return false;
            });

            return null;
        });
    }

    private int64 delete_directory_contents (string path) throws Error {
        return ProfileDeletion.delete_contents (path);
    }

    private void reset_database () {
        if (!profile_operation_available ()) return;
        var dialog = new Adw.AlertDialog (
            _("Reset Database"),
            _("This will delete all messages, files and OMEMO encryption keys for all accounts.\n\n<b>Your accounts will remain, but you will lose all chat history and need to re-verify encryption with your contacts.</b>\n\nDinoX will restart. Enter your current database password after restarting to complete the reset. This action cannot be undone!")
);
        dialog.body_use_markup = true;

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("reset", _("Reset Database"));
        dialog.set_response_appearance ("reset", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "reset") {
                perform_reset_database ();
            }
        });

        present_dialog (dialog, window);
    }

    private void perform_reset_database () {
        if (!profile_operation_available () || profile_lock == null || db_key == null) return;
        try {
            ProfileMaintenance.schedule_reset (((!) profile_lock).profile_dir, (!) db_key);
            schedule_profile_restart ();
            quit ();
        } catch (Error err) {
            var dialog = new Adw.AlertDialog (_("Could Not Complete Operation"),
                _("The operation could not be completed. Close DinoX and start it again to retry.") + "\n\n" + err.message);
            dialog.add_response ("ok", _("OK"));
            present_dialog (dialog, window);
        }
    }

    private void factory_reset () {
        if (!profile_operation_available ()) return;
        var dialog = new Adw.AlertDialog (
            _("Factory Reset"),
            _("<b>⚠️ WARNING: This will delete ALL data!</b>\n\n• All accounts\n• All messages and files\n• All encryption keys\n• All settings\n\nThis is irreversible. Make sure to create a backup first!")
);
        dialog.body_use_markup = true;

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("backup", _("Create Backup First"));
        dialog.add_response ("reset", _("Delete Everything"));
        dialog.set_response_appearance ("reset", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "reset") {
                // Show second confirmation
                confirm_factory_reset( );
            } else if (response == "backup") {
                string data_dir = Path.build_filename (Environment.get_user_data_dir (), "dinox");
                create_backup (data_dir);
            }
        });

        present_dialog (dialog, window);
    }

    private void confirm_factory_reset () {
        var dialog = new Adw.AlertDialog (
            _("Are you absolutely sure?"),
            _("Type 'DELETE' to confirm factory reset.\n\nThis will permanently remove all your DinoX data.")
);

        var entry = new Gtk.Entry ();
        entry.placeholder_text = "DELETE";
        entry.margin_start = 24;
        entry.margin_end = 24;
        dialog.set_extra_child (entry);

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("confirm", _("Confirm Delete"));
        dialog.set_response_appearance ("confirm", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        // Disable confirm button until correct text is entered
        dialog.set_response_enabled( "confirm", false);
        entry.changed.connect (() => {
            dialog.set_response_enabled ("confirm", entry.text == "DELETE");
        });

        dialog.response.connect ((response) => {
            if (response == "confirm" && entry.text == "DELETE") {
                perform_factory_reset ();
            }
        });

        present_dialog (dialog, window);
    }

    private void perform_factory_reset () {
        if (!profile_operation_available ()) return;
        request_profile_deletion (false);
    }

    private void create_backup (string data_dir) {
        if (!profile_operation_available ()) return;
        // Always enforce encryption for backups
        show_password_dialog_for_backup( data_dir);
    }

    private void show_password_dialog_for_backup (string data_dir) {
        var dialog = new Adw.AlertDialog (
            _("Set Backup Password"),
            _("Enter a password to encrypt the backup.\n\n<b>Important:</b> Remember this password! Without it, the backup cannot be restored.")
);
        dialog.body_use_markup = true;

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_start = 24;
        box.margin_end = 24;

        var password_label = new Gtk.Label (_("Password (minimum 4 characters)"));
        password_label.halign = Gtk.Align.START;
        password_label.add_css_class ("dim-label");

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.show_peek_icon = true;
        password_entry.placeholder_text = _("Password");

        var confirm_label = new Gtk.Label (_("Confirm Password"));
        confirm_label.halign = Gtk.Align.START;
        confirm_label.add_css_class ("dim-label");
        confirm_label.margin_top = 8;

        var confirm_entry = new Gtk.PasswordEntry ();
        confirm_entry.show_peek_icon = true;
        confirm_entry.placeholder_text = _("Confirm Password");
        confirm_entry.activates_default = true;

        var status_label = new Gtk.Label ("");
        status_label.halign = Gtk.Align.START;
        status_label.add_css_class ("dim-label");
        status_label.margin_top = 8;

        box.append (password_label);
        box.append (password_entry);
        box.append (confirm_label);
        box.append (confirm_entry);
        box.append (status_label);

        dialog.set_extra_child (box);

        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("ok", _("Create Encrypted Backup"));
        dialog.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("ok");
        dialog.set_close_response ("cancel");

        // Disable OK until passwords match
        dialog.set_response_enabled( "ok", false);

        password_entry.changed.connect (() => {
            string pw1 = password_entry.text;
            string pw2 = confirm_entry.text;
            if (pw1.length < 4) {
                status_label.label = _("Password too short");
            } else if (pw2.length > 0 && pw1 != pw2) {
                status_label.label = _("Passwords do not match");
            } else if (pw1.length >= 4 && pw1 == pw2) {
                status_label.label = _("✓ Passwords match");
            } else {
                status_label.label = "";
            }
            dialog.set_response_enabled ("ok", pw1.length >= 4 && pw1 == pw2);
        });

        confirm_entry.changed.connect (() => {
            string pw1 = password_entry.text;
            string pw2 = confirm_entry.text;
            if (pw1.length < 4) {
                status_label.label = _("Password too short");
            } else if (pw2.length > 0 && pw1 != pw2) {
                status_label.label = _("Passwords do not match");
            } else if (pw1.length >= 4 && pw1 == pw2) {
                status_label.label = _("✓ Passwords match");
            } else {
                status_label.label = "";
            }
            dialog.set_response_enabled ("ok", pw1.length >= 4 && pw1 == pw2);
        });

        dialog.response.connect ((response) => {
            if (response == "ok") {
                show_backup_file_chooser (data_dir, password_entry.text);
            }
        });

        present_dialog (dialog, window);
    }

    private void show_backup_file_chooser (string data_dir, string? password) {
        var file_chooser = new Gtk.FileDialog ();
        file_chooser.title = _("Select Backup Location");
        file_chooser.modal = true;

        var now = new DateTime.now_local ();
        string extension = password != null ? ".tar.gz.gpg" : ".tar.gz";
        string default_name = "dinox-backup-%s%s".printf( now.format( "%Y%m%d-%H%M%S"), extension);
        file_chooser.initial_name = default_name;

        file_chooser.save.begin (window, null, (obj, res) => {
            GLib.File? file = null;
            try {
                file = file_chooser.save.end (res);
            } catch (Error err) {
                // User cancelled
                return;
            }

            if (file != null) {
                string backup_path = file.get_path ();
                perform_backup (data_dir, backup_path, password);
            }
        });
    }

    private async void prepare_profile_snapshot (string data_dir, string stage_root, Cancellable cancellable) throws Error {
        var processor = stream_interactor.get_module<MessageProcessor> (MessageProcessor.IDENTITY);
        yield processor.pause_for_snapshot (cancellable);
        try {
            cancellable.set_error_if_cancelled ();
            if (!FileUtils.test (data_dir, FileTest.IS_DIR)) {
                throw new IOError.NOT_FOUND (_("No data directory found to backup"));
            }
            if (DirUtils.create (stage_root, 0700) != 0) {
                throw new IOError.FAILED ("Could not create private backup staging directory.");
            }
            FileUtils.set_contents (Path.build_filename (stage_root, ".dinox-backup-owner"),
                ((!) profile_lock).profile_dir);
            string staged_profile = Path.build_filename (stage_root, "dinox");
            if (DirUtils.create (staged_profile, 0700) != 0) {
                throw new IOError.FAILED ("Could not create backup profile directory.");
            }
            // No yield/main-context iteration between these snapshots. All
            // incoming decrypt/store pipelines have drained, and native OMEMO
            // ratchet callbacks run synchronously on this same main context.
            db.backup_to (Path.build_filename (staged_profile, "dino.db"), () => cancellable.is_cancelled ());
            if (plugin_loader != null) plugin_loader.backup_databases (staged_profile, cancellable);
        } finally {
            processor.resume_after_snapshot ();
        }
    }

    private void perform_backup (string data_dir, string destination_path, string? password = null) {
        if (!profile_operation_available ()) return;
        var cancellable = begin_profile_operation ();
        var progress_dialog = new Adw.AlertDialog (
            password != null ? _("Creating Encrypted Backup…") : _("Creating Backup…"),
            _("Please wait while your data is being backed up."));
        var spinner = new Gtk.Spinner () { spinning = true, height_request = 48,
            halign = Gtk.Align.CENTER, margin_top = 12, margin_bottom = 12 };
        progress_dialog.set_extra_child (spinner);
        progress_dialog.set_close_response ("none");
        present_dialog (progress_dialog, window);

        string stage_root = Path.build_filename (get_native_tmp_dir (),
            "dinox-backup-stage-" + Uuid.string_random ());
        prepare_profile_snapshot.begin (data_dir, stage_root, cancellable, (obj, result) => {
            try {
                prepare_profile_snapshot.end (result);
            } catch (Error err) {
                cleanup_profile_stage (stage_root);
                if (!finish_profile_operation ()) return;
                spinner.spinning = false;
                progress_dialog.heading = _("Backup Failed");
                progress_dialog.body = _("Backup failed: %s").printf (err.message);
                progress_dialog.add_response ("close", _("Close"));
                progress_dialog.set_close_response ("close");
                return;
            }
        profile_worker = new Thread<void*> ("backup", () => {
            bool success = false;
            string? error_message = null;
            string size_str = "";
            string final_temporary_path = destination_path + ".tmp-" + Uuid.string_random ();
            try {
                string staged_profile = Path.build_filename (stage_root, "dinox");
                cancellable.set_error_if_cancelled ();
                ProfileSnapshot.copy_files (data_dir, staged_profile, cancellable);

                string data_parent = stage_root;
                string temp_tar_path = Path.build_filename (stage_root, "backup.tar.gz");
                int exit_status;
                string? stderr_str;
#if WINDOWS
                success = run_windows_backup_archive_subprocess (
                    false,
                    data_parent,
                    null,
                    temp_tar_path,
                    out exit_status,
                    out stderr_str,
                    cancellable
                );
#else
                string[] argv = { "tar", "-czf", temp_tar_path, "-C", data_parent, "dinox" };
                Subprocess proc = spawn_subprocess (argv,
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
                success = communicate_profile_process (proc, "", cancellable, out stderr_str);
                exit_status = proc.get_exit_status ();
#endif
                if (!success) throw new IOError.FAILED (stderr_str ?? "Archive creation failed (%d)".printf (exit_status));
                string archive_path = temp_tar_path;
                if (password != null) {
                    string openssl_exe = get_backup_openssl_executable ();
                    string backup_path = Path.build_filename (stage_root, "backup.tar.gz.gpg");
                    string[] enc_argv = {
                        openssl_exe, "enc", "-aes-256-cbc", "-salt", "-pbkdf2",
                        "-in", temp_tar_path,
                        "-out", backup_path,
                        "-pass", "stdin"
                    };
                    Subprocess encrypt = spawn_subprocess (enc_argv,
                        SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
                    if (!communicate_profile_process (encrypt, password, cancellable, out stderr_str)) {
                        throw new IOError.FAILED (stderr_str ?? "Backup encryption failed");
                    }
                    archive_path = backup_path;
                }
                File archive = File.new_for_path (archive_path);
                size_str = format_size (archive.query_info (FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NONE, cancellable).get_size ());
                // Publish only a complete archive; failure preserves an existing backup.
                File temporary = File.new_for_path (final_temporary_path);
                archive.copy (temporary, FileCopyFlags.NONE, cancellable);
                dino_profile_sync_file (final_temporary_path);
                cancellable.set_error_if_cancelled ();
                temporary.move (File.new_for_path (destination_path), FileCopyFlags.OVERWRITE, cancellable);
#if !WINDOWS
                dino_profile_sync_parent (destination_path);
#endif
                success = true;
            } catch (Error err) {
                success = false;
                error_message = err.message;
            }
            FileUtils.unlink (final_temporary_path);
            cleanup_profile_stage (stage_root);
            Idle.add (() => {
                if (!finish_profile_operation ()) return false;
                spinner.spinning = false;
                progress_dialog.set_extra_child (null);
                progress_dialog.add_response ("close", _("Close"));
                progress_dialog.set_default_response ("close");
                progress_dialog.set_close_response ("close");
                if (success) {
                    progress_dialog.heading = password != null ? _("Encrypted Backup Created") : _("Backup Created");
                    progress_dialog.body = password != null
                        ? _("Your encrypted backup was created successfully.\n\nSize: %s").printf (size_str)
                        : _("Your backup was created successfully.\n\nSize: %s").printf (size_str);
                } else {
                    progress_dialog.heading = _("Backup Failed");
                    progress_dialog.body = _("Backup failed: %s").printf (error_message ?? _("Unknown error"));
                }
                return false;
            });
            return null;
        });
        });
    }

    private void show_join_muc_dialog (Account? account, string jid) {
        string dialog_key = muc_join_dialog_key (account, jid);
        if (present_existing_muc_join_dialog (account, jid)) {
            return;
        }

        var dialog = new Adw.Dialog ();
        dialog.title = _("Join Group");
        dialog.content_width = 400;
        dialog.content_height = 300;

        var toolbar_view = new Adw.ToolbarView ();
        dialog.child = toolbar_view;

        var header = new Adw.HeaderBar ();
        header.decoration_layout = ":";
        toolbar_view.add_top_bar (header);

        var cancel_button = new Gtk.Button.with_label (_("Cancel"));
        cancel_button.clicked.connect (() => dialog.close ());
        header.pack_start (cancel_button);

        var ok_button = new Gtk.Button.with_label (_("Join"));
        ok_button.add_css_class ("suggested-action");
        header.pack_end (ok_button);

        ConferenceDetailsFragment conference_fragment = new ConferenceDetailsFragment (stream_interactor) { ok_button=ok_button };
        ok_button.clicked.connect (() => {
            conference_fragment.submit_join ();
        });
        conference_fragment.jid = jid;
        if (account != null) {
            conference_fragment.account = account;
        }
        toolbar_view.content = conference_fragment;
        active_muc_join_dialogs[dialog_key] = dialog;

        ulong joined_handler_id = 0;
        dialog.closed.connect (() => {
            if (joined_handler_id != 0) {
                conference_fragment.disconnect (joined_handler_id);
                joined_handler_id = 0;
            }
            conference_fragment.fragment_active = false;
            conference_fragment.cancel_pending_join ();
            active_muc_join_dialogs.unset (dialog_key);
        });

        joined_handler_id = conference_fragment.joined.connect (() => {
            dialog.close ();
        });

        present_dialog (dialog, window);
    }

    private void show_muc_invite_dialog (int invite_id) {
        if (active_muc_invite_dialogs.contains (invite_id)) return;

        PendingMucInvite? invite = stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY).get_invite (invite_id);
        if (invite == null) return;

        activate ();

        if (invite.state == MucInviteState.ALREADY_JOINED) {
            var already_joined_dialog = new Adw.AlertDialog (
                _("Already in group"),
                _("You are already in this group.")
            );
            already_joined_dialog.add_response ("close", _("Close"));
            active_muc_invite_dialogs.add (invite_id);
            already_joined_dialog.closed.connect (() => {
                active_muc_invite_dialogs.remove (invite_id);
            });
            present_dialog (already_joined_dialog, window);
            return;
        }
        if (invite.state != MucInviteState.PENDING) return;

        string room = invite.room_jid.bare_jid.to_string ();
        string inviter = invite.from_jid.to_string ();
        string body = _("%s invited you to %s").printf (inviter, room);
        body = "%s\n\n%s".printf (body, _("Account: %s").printf (invite.account.bare_jid.to_string ()));
        if (invite.reason != null && invite.reason != "") {
            body = "%s\n\n%s".printf (body, invite.reason);
        }
        if (invite.password != null && invite.password != "") {
            body = "%s\n\n%s".printf (body, _("This invitation includes a room password."));
        }

        var dialog = new Adw.AlertDialog (_("Group Invitation"), body);
        dialog.add_response ("cancel", _("Later"));
        dialog.add_response ("deny", _("Deny"));
        dialog.add_response ("accept", _("Join"));
        dialog.set_response_appearance ("deny", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("accept", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        active_muc_invite_dialogs.add (invite_id);
        dialog.closed.connect (() => {
            active_muc_invite_dialogs.remove (invite_id);
        });
        dialog.response.connect ((response) => {
            PendingMucInvite? current_invite = stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY).get_invite (invite_id);
            if (current_invite == null) return;
            if (current_invite.state == MucInviteState.ALREADY_JOINED) {
                active_muc_invite_dialogs.remove (invite_id);
                var already_joined_dialog = new Adw.AlertDialog (
                    _("Already in group"),
                    _("You are already in this group.")
                );
                already_joined_dialog.add_response ("close", _("Close"));
                active_muc_invite_dialogs.add (invite_id);
                already_joined_dialog.closed.connect (() => {
                    active_muc_invite_dialogs.remove (invite_id);
                });
                present_dialog (already_joined_dialog, window);
                return;
            }
            if (current_invite.state != MucInviteState.PENDING) return;

            if (response == "accept") {
                accept_muc_invite.begin (invite_id, (_, res) => {
                    accept_muc_invite.end (res);
                });
            } else if (response == "deny") {
                stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY).decline (invite_id);
            }
        });
        present_dialog (dialog, window);
    }

    private async void accept_muc_invite (int invite_id) {
        MucInviteManager invite_manager = stream_interactor.get_module<MucInviteManager> (MucInviteManager.IDENTITY);
        PendingMucInvite? invite = invite_manager.get_invite (invite_id);
        if (invite == null) return;

        string nick = (invite.account.localpart ?? invite.account.domainpart) ?? "dinox";
        Xmpp.Xep.Muc.JoinResult? result = yield invite_manager.accept (invite_id, nick);
        if (result != null && result.nick != null) return;

        activate ();
        var dialog = new Adw.AlertDialog (
            _("Could not join group"),
            _("The invitation is still pending. Check the room password, nickname, or your permissions and try again.")
        );
        dialog.add_response ("close", _("Close"));
        present_dialog (dialog, window);
    }

    private void apply_startup_appearance () {
        if (interface_style != null) return;
        var appearance = StartupAppearance.load(Dino.Application.get_storage_dir());
        WindowControlPlacement.apply(appearance.window_controls);
        apply_color_scheme (appearance.color_scheme);
        interface_style = new InterfaceStyle(Gdk.Display.get_default());
        interface_style.apply(appearance.interface_style);
        apply_accent_color (appearance.accent_color);
    }

    private void save_startup_appearance () {
        StartupAppearance.save(Dino.Application.get_storage_dir(),
            settings.interface_style, settings.color_scheme, settings.accent_color, settings.window_controls);
    }

    private void apply_color_scheme (string scheme) {
        var style_manager = Adw.StyleManager.get_default ();
        switch (scheme) {
            case "light":
                style_manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
                break;
            case "dark":
                style_manager.color_scheme = Adw.ColorScheme.FORCE_DARK;
                break;
            default:
                style_manager.color_scheme = Adw.ColorScheme.DEFAULT;
                break;
        }
    }

    private void apply_accent_color (string accent) {
        var display = Gdk.Display.get_default ();
        if (display == null) return;

        if (accent_css_provider != null) {
            dino_remove_style_provider_for_display (display, accent_css_provider);
            accent_css_provider = null;
        }

        if (Adw.StyleManager.get_default().high_contrast) return;
        string css = build_accent_css (accent, Adw.StyleManager.get_default ().dark);
        if (css == "") return;

        accent_css_provider = new Gtk.CssProvider ();
#if GTK_4_12 && (VALA_0_56_GREATER_11 || VALA_0_58)
        accent_css_provider.load_from_string (css);
#elif (VALA_0_56_11 || VALA_0_56_12)
        accent_css_provider.load_from_data (css, css.length);
#else
        accent_css_provider.load_from_data (css.data);
#endif
        dino_add_style_provider_for_display (display, accent_css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10);
    }

    private string build_accent_css (string accent, bool dark) {
        switch (accent) {
            case "blue":
                return accent_css (dark ? "#78aeed" : "#1c71d8", "#3584e4", "#ffffff");
            case "green":
                return accent_css (dark ? "#8ff0a4" : "#1b8553", dark ? "#26a269" : "#2ec27e", "#ffffff");
            case "yellow":
                return accent_css (dark ? "#f8e45c" : "#9c6e03", "#e5a50a", "rgba(0, 0, 0, 0.8)");
            case "orange":
                return accent_css (dark ? "#ffbe6f" : "#c64600", "#ff7800", "#ffffff");
            case "red":
                return accent_css (dark ? "#ff7b63" : "#c01c28", dark ? "#c01c28" : "#e01b24", "#ffffff");
            case "purple":
                return accent_css (dark ? "#dc8add" : "#813d9c", "#9141ac", "#ffffff");
            default:
                return "";
        }
    }

    private string accent_css (string color, string bg_color, string fg_color) {
        return """
@define-color accent_color %s;
@define-color accent_bg_color %s;
@define-color accent_fg_color %s;
@define-color theme_selected_bg_color %s;
@define-color theme_selected_fg_color %s;
""".printf (color, bg_color, fg_color, bg_color, fg_color);
    }

    private void apply_chat_font (string family, int scale) {
        var display = Gdk.Display.get_default ();
        if (display == null) return;

        if (chat_font_css_provider != null) {
            dino_remove_style_provider_for_display (display, chat_font_css_provider);
            chat_font_css_provider = null;
        }

        int safe_scale = 100;
        switch (scale) {
            case 100:
            case 110:
            case 125:
            case 150:
            case 175:
            case 200:
                safe_scale = scale;
                break;
        }
        string css = ".dino-chat-text { font-size: %d%%;".printf (safe_scale);
        if (family != "system" && family.strip () != "") {
            css += " font-family: \"%s\", sans-serif;".printf (escape_css_string (family));
        }
        css += " }";

        chat_font_css_provider = new Gtk.CssProvider ();
#if GTK_4_12 && (VALA_0_56_GREATER_11 || VALA_0_58)
        chat_font_css_provider.load_from_string (css);
#elif (VALA_0_56_11 || VALA_0_56_12)
        chat_font_css_provider.load_from_data (css, css.length);
#else
        chat_font_css_provider.load_from_data (css.data);
#endif
        dino_add_style_provider_for_display (display, chat_font_css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 20);
    }

    private string escape_css_string (string value) {
        return value
            .replace ("\\", "\\\\")
            .replace ("\"", "\\\"")
            .replace ("\n", " ")
            .replace ("\r", " ")
            .replace ("\f", " ");
    }

    public override void shutdown () {
        profile_shutting_down = true;
        if (profile_operation_cancellable != null) profile_operation_cancellable.cancel ();
        if (profile_worker != null) {
            ((!) profile_worker).join ();
            profile_worker = null;
        }
        if (active_restore_stage != null && profile_lock != null) {
            try {
                string profile = ((!) profile_lock).profile_dir;
                if (!ProfileRestore.has_pending (profile)) cleanup_profile_stage (active_restore_stage);
            } catch (Error err) {
                warning ("Could not inspect unfinished restore staging: %s", err.message);
            }
        }
        if (profile_ready) cleanup_temp_files ();

        if (update_check_cancellable != null) {
            ((!) update_check_cancellable).cancel ();
            update_check_cancellable = null;
        }

        if (systray_manager != null) {
            systray_manager.cleanup ();
            systray_manager = null;
        }

        // Abort any in-flight HTTP requests to avoid libsoup dispose warnings
        if (stream_interactor != null) {
            var stickers = stream_interactor.get_module<Stickers>(Stickers.IDENTITY);
            if (stickers != null) stickers.shutdown();
        }

        // Close XMPP connections without triggering account_removed.
        // stream_interactor.disconnect_account() fires account_removed which
        // causes the OMEMO plugin to DELETE all identity keys and sessions.
        // During shutdown we only want to close the network connections, not
        // wipe cryptographic material.
        if (stream_interactor != null) {
            stream_interactor.connection_manager.disconnect_all ();
        }

        shutdown_plugins_once ();

#if WINDOWS
        if (windows_font_display != null && windows_font_setting_handler != 0) {
            windows_font_display.disconnect (windows_font_setting_handler);
            windows_font_setting_handler = 0;
            windows_font_display = null;
        }
#endif
        if (interface_style != null) {
            interface_style.close();
            interface_style = null;
        }
        if (accent_dark_notify_id != 0) {
            Adw.StyleManager.get_default().disconnect(accent_dark_notify_id);
            accent_dark_notify_id = 0;
        }
        if (accent_contrast_notify_id != 0) {
            Adw.StyleManager.get_default().disconnect(accent_contrast_notify_id);
            accent_contrast_notify_id = 0;
        }
        base.shutdown ();
    }

    public void shutdown_plugins_once () {
        if (plugins_shutdown) return;
        plugins_shutdown = true;

        if (plugin_loader != null) {
            plugin_loader.shutdown ();
        }
        plugins_shutdown_complete = true;
    }
}
