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

namespace Dino.Plugins.OpenPgp {

/**
 * Simple key info structure parsed from GPG output
 */
public class GpgKeyInfo {
    public string fingerprint;
    public string uid;
    public string email;
    public int64 created_timestamp;
    public string expires;
    public bool revoked;
    public bool expired;
    public bool can_encrypt;
    public bool can_sign;
    public bool has_email_uid = false;
    public bool has_matching_email_uid = false;
    public bool has_matching_xmpp_uid = false;

    public GpgKeyInfo(string fpr, string uid_str, int64 created = 0, bool revoked = false,
            bool expired = false, bool can_encrypt = true, bool can_sign = true, string? account_bare_jid = null) {
        this.fingerprint = fpr;
        this.uid = uid_str;
        this.created_timestamp = created;
        this.revoked = revoked;
        this.expired = expired;
        this.can_encrypt = can_encrypt;
        this.can_sign = can_sign;
        note_user_id(uid_str, account_bare_jid);

        // Extract email from uid (format: "Name <email>")
        if (uid_str.contains("<") && uid_str.contains(">")) {
            int start = uid_str.index_of("<") + 1;
            int end = uid_str.index_of(">");
            this.email = uid_str.substring(start, end - start);
        } else {
            this.email = "";
        }
    }

    public void note_user_id(string uid_str, string? account_bare_jid = null) {
        if (GPGHelper.email_from_uid(uid_str) != null) {
            has_email_uid = true;
        }
        if (account_bare_jid != null) {
            string? email = GPGHelper.email_from_uid(uid_str);
            if (email != null) {
                has_matching_email_uid = has_matching_email_uid || email.down() == ((!) account_bare_jid).down();
            }
        }
        if (account_bare_jid != null && ((!) account_bare_jid).length > 0 &&
                GPGHelper.uid_matches_xmpp_jid(uid_str, (!) account_bare_jid)) {
            has_matching_xmpp_uid = true;
        }
    }

    public bool usable_for_openpgp() {
        return !revoked && !expired && can_encrypt && can_sign;
    }
}

/**
 * Dialog for managing OpenPGP keys - generate, import, export, delete.
 * Uses GPG command line for reliability.
 */
public class KeyManagementDialog : Object {
    private enum KeyCreationPurpose {
        XMPP,
        KEYSERVER
    }

    private enum ServerSecretRestoreState {
        IDLE,
        FETCHING,
        PASSWORD_OPEN,
        IMPORTING,
        RESULT_OPEN,
        CANCELLED
    }

    private class ServerSecretRestoreFlow : Object {
        public uint id;
        public int account_id;
        public Dino.Entities.Account account;
        public string? operation_token;
        public ServerSecretRestoreState state = ServerSecretRestoreState.IDLE;
        public Adw.AlertDialog? fetch_progress_dialog = null;
        public ulong fetch_progress_response_handler_id = 0;
        public ulong fetch_progress_closed_handler_id = 0;
        public Adw.AlertDialog? password_dialog = null;
        public Gtk.PasswordEntry? password_entry = null;
        public Adw.AlertDialog? import_progress_dialog = null;
        public Adw.AlertDialog? result_dialog = null;
        public uint fetch_timeout_id = 0;
        public uint fetch_result_idle_id = 0;
        public uint inspect_timeout_id = 0;
        public uint import_timeout_id = 0;
        public uint password_close_fallback_id = 0;
        public bool password_response_handled = false;
        public bool inspect_terminal_pending = false;
        public bool closing = false;

        public ServerSecretRestoreFlow(uint id, Dino.Entities.Account account, string operation_token) {
            this.id = id;
            this.account_id = account.id;
            this.account = account;
            this.operation_token = operation_token;
        }
    }

    private static uint next_key_management_dialog_instance_id = 0;
    private uint key_management_dialog_instance_id = 0;
    private Adw.Dialog dialog;
    private Gtk.Window parent_window;
    private Adw.PreferencesGroup keys_group;
    private Gee.List<GpgKeyInfo> current_keys;
    private Gee.List<Gtk.Widget> key_group_rows = new Gee.ArrayList<Gtk.Widget>();
    private Gee.List<string> account_matching_key_fingerprints = new Gee.ArrayList<string>();
    private uint key_load_generation = 0;
    private Database? db;
    private Xep0373KeyManager? xep0373_manager;
    private Dino.Entities.Account? account;
    private Module? legacy_module;
    private Dino.StreamInteractor? stream_interactor;
    private const uint GPG_UI_OPERATION_TIMEOUT_SECONDS = 45;
    private const uint SERVER_IMPORT_REENTRY_GUARD_MS = 750;
    private uint ui_lifecycle_generation = 0;
    private Gee.List<Adw.AlertDialog> transient_child_dialogs = new Gee.ArrayList<Adw.AlertDialog>();
    private Cancellable? file_dialog_cancellable = null;

    public signal void keys_changed();
    public signal void dialog_closed();
    public bool is_open { get; private set; default = false; }

    public KeyManagementDialog(Gtk.Window parent, Database? database = null, Xep0373KeyManager? xep0373_mgr = null, Dino.Entities.Account? account = null, Module? legacy_module = null, Dino.StreamInteractor? stream_interactor = null) {
        this.key_management_dialog_instance_id = ++next_key_management_dialog_instance_id;
        this.parent_window = parent;
        this.current_keys = new Gee.ArrayList<GpgKeyInfo>();
        this.db = database;
        this.xep0373_manager = xep0373_mgr;
        this.account = account;
        this.legacy_module = legacy_module;
        this.stream_interactor = stream_interactor;
    }

    public void present() {
        if (is_open) {
            trace_server_import_flow("key management present existing");
            dialog.present(parent_window);
            return;
        }

        trace_server_import_flow("key management present new");
        is_open = true;
        server_import_fetch_rearm_required = false;
        server_import_fetch_activation_armed = false;
        server_import_fetch_pointer_inside = false;
        dialog = new Adw.Dialog();
        dialog.title = _("OpenPGP Key Management");
        dialog.content_width = 500;
        dialog.content_height = 600;
        dialog.closed.connect(() => {
            trace_server_import_flow("key management closed");
            ui_lifecycle_generation++;
            key_load_generation++;
            clear_key_group_rows();
            close_transient_child_dialogs();
            cancel_all_dialog_operations();
            server_import_fetch_rearm_required = false;
            server_import_fetch_activation_armed = false;
            server_import_fetch_pointer_inside = false;
            is_open = false;
            dialog_closed();
        });

        var toolbar_view = new Adw.ToolbarView();

        var header = new Adw.HeaderBar();
        toolbar_view.add_top_bar(header);

        var content_page = new Adw.PreferencesPage();

        // Actions group
        var actions_group = new Adw.PreferencesGroup();
        actions_group.title = _("Actions");
        if (account != null) {
            actions_group.description = _("Keys and server backups for %s").printf(((!) account).bare_jid.to_string());
        }

        // Generate Key button - use activatable_widget for proper click handling
        var generate_row = new Adw.ActionRow();
        generate_row.title = _("Generate New Key");
        generate_row.subtitle = _("Create a new OpenPGP key pair");
        var gen_icon = new Gtk.Image.from_icon_name("list-add-symbolic");
        generate_row.add_suffix(gen_icon);
        var gen_btn = new Gtk.Button();
        gen_btn.add_css_class("flat");
        gen_btn.child = new Gtk.Image.from_icon_name("go-next-symbolic");
        gen_btn.valign = Gtk.Align.CENTER;
        gen_btn.clicked.connect(() => {
            debug("Generate clicked!");
            show_generate_dialog();
        });
        generate_row.add_suffix(gen_btn);
        generate_row.activatable_widget = gen_btn;
        actions_group.add(generate_row);

        // Import Key button
        var import_row = new Adw.ActionRow();
        import_row.title = _("Import Key");
        import_row.subtitle = _("Import a private key for this account or a public key from a contact. Importing does not activate a key.");
        var imp_icon = new Gtk.Image.from_icon_name("document-open-symbolic");
        import_row.add_suffix(imp_icon);
        var imp_btn = new Gtk.Button();
        imp_btn.add_css_class("flat");
        imp_btn.child = new Gtk.Image.from_icon_name("go-next-symbolic");
        imp_btn.valign = Gtk.Align.CENTER;
        imp_btn.clicked.connect(() => {
            debug("Import clicked!");
            show_import_dialog();
        });
        import_row.add_suffix(imp_btn);
        import_row.activatable_widget = imp_btn;
        actions_group.add(import_row);

        if (xep0373_manager != null && account != null) {
            var remove_backup_row = new Adw.ActionRow();
            remove_backup_row.title = _("Delete Server Backup");
            remove_backup_row.subtitle = _("Remove this account's encrypted private-key backup. Local keys and public-key publications are kept.");
            remove_backup_row.activatable = true;
            remove_backup_row.add_suffix(new Gtk.Image.from_icon_name("edit-delete-symbolic"));
            remove_backup_row.activated.connect(confirm_delete_server_backup);
            actions_group.add(remove_backup_row);
            var fetch_row = new Adw.ActionRow();
            fetch_row.title = _("Fetch Key from Server (Sync)");
            fetch_row.subtitle = _("Import your secret key backup from your server");
            var fetch_icon = new Gtk.Image.from_icon_name("sync-synchronizing-symbolic");
            fetch_row.add_prefix(fetch_icon);
            var fetch_btn = new Gtk.Button();
            fetch_btn.add_css_class("flat");
            fetch_btn.child = new Gtk.Image.from_icon_name("go-next-symbolic");
            fetch_btn.valign = Gtk.Align.CENTER;
            var fetch_motion = new Gtk.EventControllerMotion();
            fetch_motion.enter.connect((x, y) => {
                server_import_fetch_pointer_inside = true;
            });
            fetch_motion.leave.connect(() => {
                server_import_fetch_pointer_inside = false;
                server_import_fetch_activation_armed = false;
            });
            fetch_row.add_controller(fetch_motion);
            var fetch_click_gesture = new Gtk.GestureClick();
            fetch_click_gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            fetch_click_gesture.pressed.connect((n_press, x, y) => {
                arm_server_import_fetch_activation("pointer press");
            });
            fetch_row.add_controller(fetch_click_gesture);
            var fetch_button_click_gesture = new Gtk.GestureClick();
            fetch_button_click_gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            fetch_button_click_gesture.pressed.connect((n_press, x, y) => {
                arm_server_import_fetch_activation("button pointer press");
            });
            fetch_btn.add_controller(fetch_button_click_gesture);
            fetch_btn.clicked.connect(() => {
                debug("Fetch from server clicked!");
                trace_server_import_flow("fetch button clicked");
                try_start_server_import_from_ui();
            });
            fetch_row.add_suffix(fetch_btn);
            fetch_row.activatable_widget = fetch_btn;
            actions_group.add(fetch_row);
        }

        content_page.add(actions_group);

        // Keys list group
        keys_group = new Adw.PreferencesGroup();
        keys_group.title = _("Your Keys");
        keys_group.description = _("Private keys available for signing and decryption");
        content_page.add(keys_group);

        toolbar_view.content = content_page;
        dialog.child = toolbar_view;

        // Load keys
        load_keys.begin();

        dialog.present(parent_window);
    }

    public void close() {
        if (!is_open) return;
        dialog.force_close();
    }

    private void cancel_all_dialog_operations() {
        file_import_active = false;
        cancel_file_dialog();
        if (active_server_restore_flow != null) {
            cancel_server_import_flow((!) active_server_restore_flow);
        } else {
            server_import_active = false;
        }
        if (server_backup_active) {
            cancel_server_backup_flow(server_backup_generation);
        } else {
            server_backup_generation++;
            release_server_secret_operation();
        }
        clear_server_backup_timeout(server_backup_timeout_generation);
        server_import_fetch_pending = false;
        server_secret_backend_pending = false;
        release_server_secret_operation();
    }

    private uint begin_ui_operation() {
        ui_lifecycle_generation++;
        return ui_lifecycle_generation;
    }

    private bool ui_operation_is_current(uint generation) {
        return is_open && ui_lifecycle_generation == generation;
    }

    private void present_transient_child_dialog(Adw.AlertDialog child_dialog, Gtk.Widget parent) {
        transient_child_dialogs.add(child_dialog);
        child_dialog.closed.connect(() => {
            transient_child_dialogs.remove(child_dialog);
            if (progress_dialog == child_dialog) {
                progress_dialog = null;
            }
        });
        child_dialog.present(parent);
    }

    private void close_transient_child_dialogs() {
        var dialogs_to_close = new Gee.ArrayList<Adw.AlertDialog>();
        dialogs_to_close.add_all(transient_child_dialogs);
        transient_child_dialogs.clear();
        foreach (Adw.AlertDialog child_dialog in dialogs_to_close) {
            child_dialog.force_close();
        }
        progress_dialog = null;
    }

    private void cancel_file_dialog() {
        if (file_dialog_cancellable != null) {
            ((!) file_dialog_cancellable).cancel();
            file_dialog_cancellable = null;
        }
    }

    private async bool communicate_gpg_utf8_with_timeout(Subprocess proc, string stdin_data,
            out string? stdout_str, out string? stderr_str) throws Error {
        stdout_str = null;
        stderr_str = null;

        bool timed_out = false;
        var cancellable = new Cancellable();
        GPGHelper.register_external_subprocess_for_shutdown(proc, cancellable);
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
            timed_out = true;
            cancellable.cancel();
            proc.force_exit();
            timeout_id = 0;
            return Source.REMOVE;
        });

        try {
            yield proc.communicate_utf8_async(stdin_data, cancellable, out stdout_str, out stderr_str);
        } catch (Error e) {
            if (timed_out) {
                throw new IOError.FAILED(_("GnuPG did not respond."));
            }
            if (GPGHelper.is_shutting_down()) {
                throw new IOError.CANCELLED("GPG helper is shutting down");
            }
            throw e;
        } finally {
            if (timeout_id != 0) {
                Source.remove(timeout_id);
            }
            GPGHelper.clear_external_subprocess_for_shutdown(proc);
        }

        if (timed_out) {
            throw new IOError.FAILED(_("GnuPG did not respond."));
        }
        return proc.get_if_exited() && proc.get_exit_status() == 0;
    }

    private async void load_keys() {
        uint load_generation = ++key_load_generation;
        clear_key_group_rows();
        current_keys.clear();
        rebuild_account_matching_key_fingerprints();
        if (db != null && account != null && db.get_pending_secret_key_backup_cleanup_fingerprint((!) account) != null) {
            var pending_row = new Adw.ActionRow();
            pending_row.title = _("Server Backup Cleanup Pending");
            pending_row.subtitle = _("The key was kept locally. DinoX will retry removing its matching backup when this account reconnects. Then retry revoking the key.");
            pending_row.add_prefix(new Gtk.Image.from_icon_name("dialog-warning-symbolic"));
            add_key_group_row(pending_row);
        }
        bool load_error = false;
        string? load_error_message = null;

        // Use GPG command to get keys with proper info
        try {
            string? openpgp_gnupg_home = GPGHelper.get_homedir_path();
            string gpg_bin = GPGHelper.get_binary_path();
            if (openpgp_gnupg_home == null || openpgp_gnupg_home.length == 0) {
                throw new IOError.FAILED("OpenPGP keyring directory is not configured");
            }

            // Prefer using GNUPGHOME env var implicitly, but if we pass it, ensure it matches what the Plugin set up.
            string[] argv = { gpg_bin, "--no-secmem-warning", "--homedir", openpgp_gnupg_home, "--list-secret-keys", "--with-colons" };

            var proc = new_subprocess(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? stdout_str = null;
            string? stderr_str = null;

            bool ok = yield communicate_gpg_utf8_with_timeout(proc, "", out stdout_str, out stderr_str);
            if (!is_open || load_generation != key_load_generation) return;

            if (ok && stdout_str != null) {
                parse_gpg_output(stdout_str);
            } else {
                load_error = true;
                load_error_message = stderr_str;
            }
        } catch (Error e) {
            debug("Error listing GPG keys: %s", e.message);
            load_error = true;
            load_error_message = e.message;
        }

        if (!is_open || load_generation != key_load_generation) return;

        // Display keys
        if (load_error) {
            var error_row = new Adw.ActionRow();
            error_row.title = _("Could not load OpenPGP keys");
            error_row.subtitle = load_error_message ?? _("GnuPG did not respond.");
            error_row.add_prefix(new Gtk.Image.from_icon_name("dialog-warning-symbolic"));
            add_key_group_row(error_row);
        } else {
            int shown_count = 0;
            foreach (var key in current_keys) {
                if (!should_show_key_for_current_account(key)) {
                    continue;
                }
                add_key_row(key);
                shown_count++;
            }
            if (shown_count == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = _("No private keys found");
                empty_row.subtitle = _("Generate or import a key to get started");
                empty_row.add_prefix(new Gtk.Image.from_icon_name("dialog-information-symbolic"));
                add_key_group_row(empty_row);
            }
        }
    }

    private void clear_key_group_rows() {
        foreach (Gtk.Widget row in key_group_rows) {
            keys_group.remove(row);
        }
        key_group_rows.clear();
    }

    private void add_key_group_row(Gtk.Widget row) {
        keys_group.add(row);
        key_group_rows.add(row);
    }

    private void rebuild_account_matching_key_fingerprints() {
        account_matching_key_fingerprints.clear();

        if (db == null || account == null) return;

        var bare_jid = ((!) account).bare_jid;
        add_matching_key_fingerprint(db.get_account_xmpp_key((!) account));
        add_matching_key_fingerprint(db.get_account_legacy_key((!) account));
        foreach (string fingerprint in db.get_account_private_key_bindings((!) account)) {
            add_matching_key_fingerprint(fingerprint);
        }
        add_matching_key_fingerprint(db.get_contact_key((!) account, bare_jid));
        add_matching_key_fingerprint(db.get_contact_legacy_key((!) account, bare_jid));
        add_matching_key_fingerprint(db.get_contact_xmpp_key((!) account, bare_jid));
    }

    private void add_matching_key_fingerprint(string? fingerprint) {
        if (fingerprint == null || fingerprint.length == 0) return;
        bool already_present = false;
        foreach (string existing in account_matching_key_fingerprints) {
            if (is_account_key_for_fingerprint(existing, fingerprint)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) {
            account_matching_key_fingerprints.add(fingerprint);
        }
    }

    private bool key_is_account_bound(string fingerprint) {
        foreach (string configured_fingerprint in account_matching_key_fingerprints) {
            if (is_account_key_for_fingerprint(configured_fingerprint, fingerprint)) return true;
        }

        return false;
    }

    private void parse_gpg_output(string output) {
        string? current_fpr = null;
        GpgKeyInfo? current_key = null;
        int64 current_created = 0;
        bool current_revoked = false;
        bool current_expired = false;
        bool current_can_encrypt = true;
        bool current_can_sign = true;
        bool in_main_key = false;  // Track if we're processing a main key (sec), not subkey (ssb)
        string? account_bare_jid = account != null ? ((!) account).bare_jid.to_string() : null;

        foreach (var line in output.split("\n")) {
            var parts = line.split(":");
            if (parts.length < 2) continue;

            if (parts[0] == "sec") {
                // Secret key line - start of a new main key
                in_main_key = true;
                current_fpr = null;
                current_key = null;
                current_created = 0;
                string validity = parts.length > 1 ? parts[1] : "";
                current_revoked = validity == "r";
                current_expired = validity == "e";
                string capabilities = parts.length > 11 ? parts[11] : "";
                current_can_encrypt = capabilities.length == 0 || capabilities.contains("e") || capabilities.contains("E");
                current_can_sign = capabilities.length == 0 || capabilities.contains("s") || capabilities.contains("S");
                if (parts.length > 5 && parts[5].length > 0) {
                    current_created = int64.parse(parts[5]);
                }
            } else if (parts[0] == "ssb") {
                // Subkey line - ignore subkeys, they belong to the main key
                in_main_key = false;
            } else if (parts[0] == "fpr" && in_main_key && current_fpr == null) {
                // First fingerprint after sec is the main key fingerprint
                if (parts.length > 9 && parts[9].length > 0) {
                    current_fpr = parts[9];
                }
            } else if (parts[0] == "uid" && in_main_key && current_fpr != null) {
                // UID is in field index 9
                if (parts.length > 9) {
                    string uid = GPGHelper.decode_gpg_colon_escapes(parts[9]);
                    if (uid.length > 0) {
                        if (current_key == null) {
                            current_key = new GpgKeyInfo(current_fpr, uid, current_created,
                                    current_revoked, current_expired, current_can_encrypt, current_can_sign, account_bare_jid);
                            current_keys.add((!) current_key);
                        } else {
                            ((!) current_key).note_user_id(uid, account_bare_jid);
                        }
                    }
                }
            }
        }

        // Sort by creation timestamp, newest first
        current_keys.sort((a, b) => {
            if (b.created_timestamp > a.created_timestamp) return 1;
            if (b.created_timestamp < a.created_timestamp) return -1;
            return 0;
        });
    }

    private bool is_account_key_for_fingerprint(string? key_id, string fingerprint) {
        if (db == null || key_id == null) return false;
        return matches_fingerprint((!) key_id, fingerprint);
    }

    internal bool should_show_key_for_current_account(GpgKeyInfo key) {
        if (account == null) return true;
        if (db == null) return true;
        if (key_is_account_bound(key.fingerprint)) {
            return true;
        }

        return key.has_matching_xmpp_uid || key.has_matching_email_uid;
    }

    private void add_key_row(GpgKeyInfo key) {
        var row = new Adw.ExpanderRow();
        row.use_markup = false;

        // Key UIDs are plain text, including literal email angle brackets.
        row.title = key.uid;

        // Check if key is published to keyserver
        bool is_keyserver_published = (db != null) ? db.is_key_published(key.fingerprint) : false;
        bool has_account_xmpp_uid = key_has_matching_xmpp_uid(key);
        bool has_legacy_email_uid = key.has_email_uid;
        bool is_account_key = false;
        bool is_xmpp_account_key = false;
        bool is_legacy_account_key = false;
        bool is_xmpp_configured_key = false;
        bool is_legacy_configured_key = false;
        if (db != null && account != null) {
            string? xmpp_key = db.get_account_xmpp_key((!) account);
            string? legacy_key = db.get_account_legacy_key((!) account);
            string account_key_mode = db.get_account_key_mode((!) account);
            is_xmpp_configured_key = xmpp_key != null && matches_fingerprint((!) xmpp_key, key.fingerprint);
            is_legacy_configured_key = legacy_key != null && matches_fingerprint((!) legacy_key, key.fingerprint);
            is_xmpp_account_key = is_xmpp_configured_key && account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP;
            is_legacy_account_key = is_legacy_configured_key && account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY;
            is_account_key = is_xmpp_account_key || is_legacy_account_key;
        }
        bool is_legacy_keyserver_published = is_keyserver_published && has_legacy_email_uid;
        bool should_show_legacy_keyserver_ui = has_legacy_email_uid || is_legacy_configured_key;
        bool can_use_legacy_for_account = has_legacy_email_uid;

        row.subtitle = build_key_summary(key, is_xmpp_account_key, is_xmpp_configured_key,
                is_legacy_account_key, is_legacy_configured_key, has_account_xmpp_uid,
                has_legacy_email_uid, is_legacy_keyserver_published);

        var icon = new Gtk.Image.from_icon_name("channel-secure-symbolic");
        row.add_prefix(icon);

        // Add globe icon for published keys
        if (is_legacy_keyserver_published) {
            var globe = new Gtk.Image.from_icon_name("network-workgroup-symbolic");
            globe.tooltip_text = _("Published to keyserver");
            row.add_suffix(globe);
        }
        if (is_account_key) {
            var account_icon = new Gtk.Image.from_icon_name("check-plain-symbolic");
            account_icon.tooltip_text = is_xmpp_account_key && is_legacy_account_key
                ? _("Active legacy and XMPP account key")
                : (is_legacy_account_key ? _("Active legacy XEP-0027 account key") : _("Active XMPP account key"));
            row.add_suffix(account_icon);
        }

        // Fingerprint row
        var fp_row = new Adw.ActionRow();
        fp_row.title = _("Fingerprint");
        var fp_label = new Gtk.Label(format_fingerprint(key.fingerprint));
        fp_label.add_css_class("monospace");
        fp_label.add_css_class("dim-label");
        fp_label.selectable = true;
        fp_label.wrap = true;
        fp_label.xalign = 1;
        fp_row.add_suffix(fp_label);
        row.add_row(fp_row);

        if (db != null && account != null && !is_xmpp_configured_key && !is_legacy_configured_key &&
                db.get_account_private_key_bindings((!) account).contains(key.fingerprint.up())) {
            var unassign_row = new Adw.ActionRow();
            unassign_row.title = _("Remove Assignment to This Account");
            unassign_row.subtitle = _("Keep the key in DinoX's keyring and remove only its manual assignment to this account.");
            unassign_row.activatable = true;
            unassign_row.add_suffix(new Gtk.Image.from_icon_name("list-remove-symbolic"));
            unassign_row.activated.connect(() => {
                db.unbind_private_key_from_account((!) account, key.fingerprint);
                load_keys.begin();
            });
            row.add_row(unassign_row);
        }

        var xmpp_publish_row = new Adw.ActionRow();
        xmpp_publish_row.title = _("OpenPGP for XMPP (XEP-0373/0374)");
        if (is_xmpp_account_key) {
            xmpp_publish_row.subtitle = _("Active for this account. DinoX publishes this key through XMPP for OpenPGP-capable clients.");
        } else if (is_xmpp_configured_key) {
            xmpp_publish_row.subtitle = _("Stored for OpenPGP for XMPP, but not active while legacy XEP-0027/keyserver mode is selected.");
        } else if (is_legacy_account_key) {
            xmpp_publish_row.subtitle = _("Inactive. This key is currently selected for legacy XEP-0027/keyserver use.");
        } else if (!has_account_xmpp_uid) {
            xmpp_publish_row.subtitle = _("Not available for this account. OpenPGP for XMPP keys must contain an xmpp: user ID for this XMPP address.");
        } else {
            xmpp_publish_row.subtitle = _("Not active for this account. Select it below to publish it through XMPP.");
        }
        xmpp_publish_row.add_suffix(new Gtk.Image.from_icon_name(is_xmpp_account_key ? "check-plain-symbolic" : "dialog-information-symbolic"));
        row.add_row(xmpp_publish_row);

        if (account != null && key.usable_for_openpgp() && has_account_xmpp_uid) {
            var use_xmpp_row = new Adw.ActionRow();
            use_xmpp_row.title = is_xmpp_account_key
                ? _("Selected for OpenPGP for XMPP")
                : _("Use for OpenPGP for XMPP");
            if (is_xmpp_account_key) {
                use_xmpp_row.subtitle = _("DinoX uses this key for XEP-0373/0374 messages and publishes it through XMPP.");
                use_xmpp_row.add_suffix(new Gtk.Image.from_icon_name("check-plain-symbolic"));
            } else {
                use_xmpp_row.subtitle = _("Selects this key for XEP-0373/0374 messages and publishes it through XMPP.");
                use_xmpp_row.activatable = true;
                use_xmpp_row.add_suffix(new Gtk.Image.from_icon_name("object-select-symbolic"));
                use_xmpp_row.activated.connect(() => {
                    select_xmpp_account_key(key.fingerprint);
                    keys_changed();
                    dialog.force_close();
                    show_message(_("OpenPGP for XMPP Key Selected"), _("DinoX will use this key for OpenPGP for XMPP and publish it through XMPP for this account."));
                });
            }
            row.add_row(use_xmpp_row);
        }

        if (account != null && xep0373_manager != null && key.usable_for_openpgp() && has_account_xmpp_uid) {
            var backup_row = new Adw.ActionRow();
            backup_row.title = _("Backup Secret Key to Server");
            backup_row.subtitle = _("Securely encrypt this key and store it on the server to sync across your devices.");
            backup_row.activatable = true;
            backup_row.add_suffix(new Gtk.Image.from_icon_name("document-save-symbolic"));
            backup_row.activated.connect(() => {
                show_server_backup_dialog(key.fingerprint);
            });
            row.add_row(backup_row);
        }

        if (account != null && xep0373_manager != null && is_xmpp_account_key) {
            var disable_xmpp_row = new Adw.ActionRow();
            disable_xmpp_row.title = _("Disable OpenPGP for XMPP for this account");
            disable_xmpp_row.subtitle = _("Removes the XMPP PubSub publication and keeps the secret key locally. Legacy XEP-0027/keyserver state is not changed.");
            disable_xmpp_row.activatable = true;
            disable_xmpp_row.add_suffix(new Gtk.Image.from_icon_name("edit-clear-symbolic"));
            disable_xmpp_row.activated.connect(() => {
                confirm_disable_xmpp_account_key(key.fingerprint);
            });
            row.add_row(disable_xmpp_row);
        }

        if (should_show_legacy_keyserver_ui) {
            var keyserver_status_row = new Adw.ActionRow();
            keyserver_status_row.title = _("Legacy keyserver publication");
            if (!key.usable_for_openpgp()) {
                keyserver_status_row.subtitle = _("This key is revoked, expired, or not usable for signing and encryption.");
            } else if (!has_legacy_email_uid && is_legacy_configured_key) {
                keyserver_status_row.subtitle = _("Stored for legacy XEP-0027/keyserver, but this key has no email user ID for new keyserver publishing.");
            } else if (is_legacy_account_key && is_legacy_keyserver_published) {
                keyserver_status_row.subtitle = _("Active for legacy XEP-0027. The email address on the key must still be verified on the keyserver.");
            } else if (is_legacy_configured_key && is_legacy_keyserver_published) {
                keyserver_status_row.subtitle = _("Stored for legacy XEP-0027/keyserver, but not active while OpenPGP for XMPP mode is selected.");
            } else if (is_legacy_keyserver_published) {
                keyserver_status_row.subtitle = _("Uploaded for legacy OpenPGP clients. The email address on the key must still be verified on the keyserver.");
            } else {
                keyserver_status_row.subtitle = _("Not uploaded. Legacy OpenPGP clients may not find this key unless you publish it to a keyserver.");
            }
            keyserver_status_row.add_suffix(new Gtk.Image.from_icon_name(is_legacy_keyserver_published ? "network-workgroup-symbolic" : "dialog-information-symbolic"));
            row.add_row(keyserver_status_row);
        }

        if (account != null && key.usable_for_openpgp() && can_use_legacy_for_account) {
            var use_legacy_row = new Adw.ActionRow();
            use_legacy_row.title = is_legacy_account_key
                ? _("Selected for legacy XEP-0027/keyserver")
                : _("Use for legacy XEP-0027/keyserver");
            if (is_legacy_account_key) {
                use_legacy_row.subtitle = _("DinoX uses this key for legacy OpenPGP messages and keyserver-based contacts.");
            } else if (is_legacy_keyserver_published) {
                use_legacy_row.subtitle = _("Selects this key for legacy OpenPGP messages. The keyserver entry still needs a verified email address.");
                use_legacy_row.activatable = true;
                use_legacy_row.add_suffix(new Gtk.Image.from_icon_name("object-select-symbolic"));
                use_legacy_row.activated.connect(() => {
                    select_legacy_account_key(key.fingerprint);
                    keys_changed();
                    dialog.force_close();
                    show_message(_("Legacy OpenPGP Key Selected"), _("DinoX will use this key for XEP-0027/keyserver OpenPGP."));
                });
            } else {
                use_legacy_row.subtitle = _("Not published to a keyserver. You can select it, but other legacy clients may not find it automatically.");
                use_legacy_row.activatable = true;
                use_legacy_row.add_suffix(new Gtk.Image.from_icon_name("object-select-symbolic"));
                use_legacy_row.activated.connect(() => {
                    select_legacy_account_key(key.fingerprint);
                    keys_changed();
                    dialog.force_close();
                    show_message(_("Legacy OpenPGP Key Selected"), _("DinoX will use this key for XEP-0027. Publish it to a keyserver if legacy clients should find it automatically."));
                });
            }
            if (is_legacy_account_key) {
                use_legacy_row.add_suffix(new Gtk.Image.from_icon_name("check-plain-symbolic"));
            }
            row.add_row(use_legacy_row);
        }

        if (account != null && is_legacy_configured_key) {
            var disable_legacy_row = new Adw.ActionRow();
            disable_legacy_row.title = is_legacy_account_key
                ? _("Stop using for legacy XEP-0027/keyserver")
                : _("Remove stored legacy XEP-0027/keyserver selection");
            disable_legacy_row.subtitle = is_legacy_account_key
                ? _("Keeps the key locally and on the keyserver. DinoX stops announcing it in signed presence.")
                : _("Keeps the key locally and on the keyserver. DinoX removes this inactive legacy account selection.");
            disable_legacy_row.activatable = true;
            disable_legacy_row.add_suffix(new Gtk.Image.from_icon_name("edit-clear-symbolic"));
            disable_legacy_row.activated.connect(() => {
                disable_legacy_account_key(key.fingerprint);
                keys_changed();
                dialog.force_close();
                show_message(_("Legacy OpenPGP Disabled"), _("DinoX will no longer use or announce this key for XEP-0027/keyserver OpenPGP. The key remains in your keyring and on the keyserver if it was published."));
            });
            row.add_row(disable_legacy_row);
        }

        // Publish to keyserver row (if not already published)
        if (!is_legacy_keyserver_published && key.usable_for_openpgp() && has_legacy_email_uid) {
            var publish_row = new Adw.ActionRow();
            publish_row.title = _("Publish public key to keyserver for legacy discovery");
            publish_row.subtitle = _("Requires a real email address you can verify.");
            publish_row.activatable = true;
            publish_row.add_suffix(new Gtk.Image.from_icon_name("network-workgroup-symbolic"));
            publish_row.activated.connect(() => publish_key_to_keyserver(key));
            row.add_row(publish_row);
        }

        // Export public key button row
        var export_row = new Adw.ActionRow();
        export_row.title = _("Export Public Key");
        export_row.activatable = true;
        export_row.add_suffix(new Gtk.Image.from_icon_name("document-save-symbolic"));
        export_row.activated.connect(() => export_key(key, false));
        row.add_row(export_row);

        // Export secret key button row (for backup)
        var export_secret_row = new Adw.ActionRow();
        export_secret_row.title = _("Export Secret Key (Backup)");
        export_secret_row.subtitle = _("Required for restoring your key");
        export_secret_row.activatable = true;
        export_secret_row.add_suffix(new Gtk.Image.from_icon_name("channel-secure-symbolic"));
        export_secret_row.activated.connect(() => export_key(key, true));
        row.add_row(export_secret_row);

        if (!key.revoked) {
            // Revoke button row
            var revoke_row = new Adw.ActionRow();
            revoke_row.title = _("Revoke Key");
            revoke_row.subtitle = _("Invalidate key, keep locally for old messages");
            revoke_row.add_css_class("error");
            revoke_row.activatable = true;
            revoke_row.add_suffix(new Gtk.Image.from_icon_name("dialog-warning-symbolic"));
            revoke_row.activated.connect(() => confirm_revoke_key(key));
            row.add_row(revoke_row);

            // Revoke & Delete button row
            var revoke_delete_row = new Adw.ActionRow();
            revoke_delete_row.title = _("Revoke &amp; Delete Key");
            revoke_delete_row.subtitle = _("Invalidate and remove key completely");
            revoke_delete_row.add_css_class("error");
            revoke_delete_row.activatable = true;
            revoke_delete_row.add_suffix(new Gtk.Image.from_icon_name("edit-delete-symbolic"));
            revoke_delete_row.activated.connect(() => confirm_revoke_and_delete_key(key));
            row.add_row(revoke_delete_row);
        }

        // Delete button row
        var delete_row = new Adw.ActionRow();
        delete_row.title = _("Delete Key");
        delete_row.subtitle = _("Remove locally without revocation; active XMPP publication is removed first");
        delete_row.activatable = true;
        delete_row.add_suffix(new Gtk.Image.from_icon_name("user-trash-symbolic"));
        delete_row.activated.connect(() => confirm_delete_key(key));
        row.add_row(delete_row);

        add_key_group_row(row);
    }

    private string format_fingerprint(string fpr) {
        var sb = new StringBuilder();
        for (int i = 0; i < fpr.length; i++) {
            sb.append_c(fpr[i]);
            if ((i + 1) % 4 == 0 && i < fpr.length - 1) {
                sb.append(" ");
            }
        }
        return sb.str;
    }

    private string build_key_summary(GpgKeyInfo key, bool is_xmpp_account_key, bool is_xmpp_configured_key,
            bool is_legacy_account_key, bool is_legacy_configured_key, bool has_account_xmpp_uid,
            bool has_legacy_email_uid, bool is_legacy_keyserver_published) {
        string summary = key.fingerprint.substring(key.fingerprint.length - 16);
        if (key.revoked) summary += " · " + _("Revoked");

        if (is_xmpp_account_key) {
            summary += " · " + _("Active OpenPGP XMPP (XEP-0373/0374)");
        } else if (is_xmpp_configured_key) {
            summary += " · " + _("Stored OpenPGP XMPP (XEP-0373/0374)");
        } else if (has_account_xmpp_uid) {
            summary += " · " + _("OpenPGP XMPP key (XEP-0373/0374)");
        }

        if (is_legacy_account_key) {
            summary += " · " + _("Active legacy XEP-0027/keyserver");
        } else if (is_legacy_configured_key) {
            summary += " · " + _("Stored legacy XEP-0027/keyserver");
        } else if (has_legacy_email_uid) {
            summary += " · " + _("Legacy-capable key");
        }

        if (is_legacy_keyserver_published) {
            summary += " · " + _("Keyserver uploaded");
        }
        return summary;
    }

    private bool key_has_matching_xmpp_uid(GpgKeyInfo key) {
        return key.has_matching_xmpp_uid;
    }

    private bool key_has_matching_xmpp_uid_by_fingerprint(string fingerprint) {
        if (account == null) return false;
        try {
            return GPGHelper.key_has_xmpp_uid(fingerprint, ((!) account).bare_jid.to_string());
        } catch (Error e) {
            debug("OpenPGP: Failed to check XMPP user ID for key %s: %s", fingerprint, e.message);
            return false;
        }
    }

    private void show_generate_dialog() {
        var gen_dialog = new Adw.AlertDialog(
            _("Generate New OpenPGP Key"),
            _("Enter your details to create a new key pair.")
        );

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.margin_start = 24;
        box.margin_end = 24;

        // Name
        var name_label = new Gtk.Label(_("Name"));
        name_label.xalign = 0;
        box.append(name_label);

        var name_entry = new Gtk.Entry();
        name_entry.placeholder_text = _("Your Name");
        box.append(name_entry);

        var purpose_label = new Gtk.Label(_("Key usage"));
        purpose_label.xalign = 0;
        purpose_label.margin_top = 8;
        box.append(purpose_label);

        var xmpp_radio = new Gtk.CheckButton();
        xmpp_radio.active = true;
        var xmpp_label_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        var xmpp_title = new Gtk.Label(_("DinoX / OpenPGP for XMPP"));
        xmpp_title.xalign = 0;
        xmpp_title.add_css_class("heading");
        var xmpp_subtitle = new Gtk.Label(_("Uses your XMPP address and publishes the selected account key through XMPP. No email verification is needed."));
        xmpp_subtitle.xalign = 0;
        xmpp_subtitle.wrap = true;
        xmpp_subtitle.add_css_class("dim-label");
        xmpp_subtitle.add_css_class("caption");
        xmpp_label_box.append(xmpp_title);
        xmpp_label_box.append(xmpp_subtitle);
        xmpp_radio.child = xmpp_label_box;
        box.append(xmpp_radio);

        var keyserver_radio = new Gtk.CheckButton();
        keyserver_radio.set_group(xmpp_radio);
        var keyserver_label_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        var keyserver_title = new Gtk.Label(_("Legacy keyserver / XEP-0027"));
        keyserver_title.xalign = 0;
        keyserver_title.add_css_class("heading");
        var keyserver_subtitle = new Gtk.Label(_("Uses a real email address and uploads the key for older OpenPGP clients. The email address must be verified."));
        keyserver_subtitle.xalign = 0;
        keyserver_subtitle.wrap = true;
        keyserver_subtitle.add_css_class("dim-label");
        keyserver_subtitle.add_css_class("caption");
        keyserver_label_box.append(keyserver_title);
        keyserver_label_box.append(keyserver_subtitle);
        keyserver_radio.child = keyserver_label_box;
        box.append(keyserver_radio);

        var identity_label = new Gtk.Label(_("XMPP address"));
        identity_label.xalign = 0;
        identity_label.margin_top = 8;
        box.append(identity_label);

        var identity_entry = new Gtk.Entry();
        identity_entry.placeholder_text = _("xmpp@example.com");
        if (account != null) {
            identity_entry.text = ((!) account).bare_jid.to_string();
        }
        box.append(identity_entry);

        var identity_hint = new Gtk.Label(_("This key will be selected for this DinoX account and published through XMPP for OpenPGP-for-XMPP capable clients."));
        identity_hint.xalign = 0;
        identity_hint.wrap = true;
        identity_hint.add_css_class("dim-label");
        identity_hint.add_css_class("caption");
        box.append(identity_hint);

        // Passphrase
        var pass_label = new Gtk.Label(_("Passphrase (optional)"));
        pass_label.xalign = 0;
        pass_label.margin_top = 8;
        box.append(pass_label);

        var pass_entry = new Gtk.PasswordEntry();
        pass_entry.show_peek_icon = true;
        box.append(pass_entry);

        keyserver_radio.toggled.connect(() => {
            if (keyserver_radio.active) {
                identity_label.label = _("Email address");
                identity_entry.placeholder_text = _("name@example.com");
                identity_hint.label = _("Use a mailbox you can access. keys.openpgp.org requires email verification before older XEP-0027 clients can find this key.");
            } else {
                identity_label.label = _("XMPP address");
                identity_entry.placeholder_text = _("xmpp@example.com");
                if (account != null) {
                    identity_entry.text = ((!) account).bare_jid.to_string();
                }
                identity_hint.label = _("This key will be selected for this DinoX account and published through XMPP for OpenPGP-for-XMPP capable clients.");
            }
        });

        // Separator
        var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        sep.margin_top = 12;
        box.append(sep);

        var info_label = new Gtk.Label(_("4096-bit RSA key, valid for 2 years."));
        info_label.add_css_class("dim-label");
        info_label.margin_top = 12;
        box.append(info_label);

        gen_dialog.extra_child = box;

        gen_dialog.add_response("cancel", _("Cancel"));
        gen_dialog.add_response("generate", _("Generate"));
        gen_dialog.set_response_appearance("generate", Adw.ResponseAppearance.SUGGESTED);
        gen_dialog.default_response = "generate";
        gen_dialog.close_response = "cancel";

        gen_dialog.response.connect((response) => {
            if (response == "generate") {
                string name = name_entry.text.strip();
                string identity = identity_entry.text.strip();
                string passphrase = pass_entry.text;
                KeyCreationPurpose purpose = keyserver_radio.active ? KeyCreationPurpose.KEYSERVER : KeyCreationPurpose.XMPP;

                if (name.length < 2) {
                    show_message(_("Error"), _("Name must be at least 2 characters"));
                    return;
                }
                if (purpose == KeyCreationPurpose.KEYSERVER) {
                    if (!is_valid_keyserver_email(identity)) {
                        show_message(_("Error"), _("Please enter a valid email address"));
                        return;
                    }
                } else {
                    try {
                        Xmpp.Jid jid = new Xmpp.Jid(identity);
                        if (jid.localpart == null || jid.resourcepart != null) {
                            show_message(_("Error"), _("Please enter a bare XMPP address, for example name@example.com"));
                            return;
                        }
                        identity = jid.bare_jid.to_string();
                        if (account != null && identity != ((!) account).bare_jid.to_string()) {
                            show_message(_("Error"), _("OpenPGP for XMPP keys must use this account's XMPP address."));
                            return;
                        }
                    } catch (Xmpp.InvalidJidError e) {
                        show_message(_("Error"), _("Please enter a valid XMPP address"));
                        return;
                    }
                }

                generate_key(name, identity, passphrase, purpose);
            }
        });

        present_transient_child_dialog(gen_dialog, dialog);
    }

    private Adw.AlertDialog? progress_dialog;
    private KeyCreationPurpose pending_key_purpose = KeyCreationPurpose.XMPP;

    private void generate_key(string name, string identity, string passphrase, KeyCreationPurpose purpose) {
        uint operation_generation = begin_ui_operation();
        pending_key_purpose = purpose;

        // Show progress dialog with spinner
        progress_dialog = new Adw.AlertDialog(
            _("Generating Key..."),
            _("Please wait while your key is being generated. This may take a moment.")
        );

        var spinner = new Gtk.Spinner();
        spinner.spinning = true;
        spinner.set_size_request(48, 48);
        spinner.halign = Gtk.Align.CENTER;
        spinner.margin_top = 12;
        spinner.margin_bottom = 12;
        progress_dialog.extra_child = spinner;

        // No close button - user must wait
        present_transient_child_dialog((!) progress_dialog, dialog);

        bool key_generated = false;
        string stdout_str = "";
        string stderr_str = "";
        string? error_msg = null;
        string? new_fingerprint = null;

        new Thread<void*>("openpgp-generate-key", () => {
            try {
                if (purpose == KeyCreationPurpose.XMPP) {
                    key_generated = GPGHelper.generate_xmpp_secret_key(name, identity, passphrase, out stdout_str, out stderr_str);
                } else {
                    key_generated = GPGHelper.generate_secret_key(name, identity, passphrase, out stdout_str, out stderr_str);
                }
                if (key_generated) {
                    new_fingerprint = get_newest_key_fingerprint();
                }
            } catch (Error err) {
                error_msg = err.message;
            }

            Idle.add(() => {
                bool ui_current = ui_operation_is_current(operation_generation);
                if (progress_dialog != null) {
                    progress_dialog.force_close();
                    progress_dialog = null;
                }

                if (key_generated) {
                    if (new_fingerprint != null && passphrase.length > 0) {
                        GPGHelper.cache_passphrase(new_fingerprint, passphrase);
                    }

                    if (pending_key_purpose == KeyCreationPurpose.KEYSERVER && new_fingerprint != null) {
                        upload_key_async.begin(new_fingerprint, (obj, res) => {
                            bool uploaded = upload_key_async.end(res);
                            if (uploaded && db != null) {
                                db.set_key_published(new_fingerprint);
                                if (account != null) {
                                    select_legacy_account_key(new_fingerprint);
                                }
                            }
                            keys_changed();
                            if (!ui_operation_is_current(operation_generation)) return;
                            dialog.force_close();
                            if (uploaded) {
                                show_message(_("Success"), _("Key generated and uploaded to the keyserver. Check your email to verify it before XEP-0027 clients can reliably find it."));
                            } else {
                                show_message(_("Partial Success"), _("Key generated locally, but keyserver upload failed. It is not published for legacy XEP-0027 clients yet. You can retry from Key Management."));
                            }
                        });
                    } else {
                        if (new_fingerprint != null && db != null && account != null) {
                            if (key_has_matching_xmpp_uid_by_fingerprint(new_fingerprint)) {
                                select_xmpp_account_key(new_fingerprint);
                            } else {
                                keys_changed();
                                if (ui_current) {
                                    dialog.force_close();
                                    show_message(_("Partial Success"), _("Key generated locally, but it was not selected because it does not contain the required xmpp: user ID for this account."));
                                }
                                return Source.REMOVE;
                            }
                        }
                        keys_changed();
                        if (ui_current) {
                            dialog.force_close();
                            show_message(_("Success"), _("Key generated and selected for OpenPGP for XMPP. DinoX will publish it through XMPP for this account."));
                            
                            if (xep0373_manager != null && account != null && new_fingerprint != null) {
                                show_server_backup_dialog(new_fingerprint);
                            }
                        }
                    }
                } else {
                    if (!ui_current) return Source.REMOVE;
                    string details = "STDERR:\n" + (stderr_str ?? "") + "\nSTDOUT:\n" + (stdout_str ?? "");
                    if (error_msg != null) {
                        details = (!) error_msg + "\n\n" + details;
                    }
                    show_message(_("Error"), _("Failed to generate key.") + "\n\n" + details);
                }
                return Source.REMOVE;
            });
            return null;
        });
    }

    private bool is_valid_keyserver_email(string email) {
        if (email.has_prefix("xmpp:") || email.contains("/") || email.contains("<") || email.contains(">") || email.contains(" ")) {
            return false;
        }
        int at_pos = email.index_of("@");
        if (at_pos <= 0 || at_pos >= email.length - 1) return false;
        return email.index_of("@", at_pos + 1) < 0;
    }

    private void show_import_dialog() {
        if (server_dialog_flow_is_active()) return;
        cancel_file_dialog();
        uint operation_generation = begin_ui_operation();
        file_import_active = true;
        
        var file_dialog = new Gtk.FileDialog();
        file_dialog.title = _("Import OpenPGP Key");

        var filters = new GLib.ListStore(typeof(Gtk.FileFilter));

        var key_filter = new Gtk.FileFilter();
        key_filter.name = _("OpenPGP Keys (*.asc, *.gpg)");
        key_filter.add_pattern("*.asc");
        key_filter.add_pattern("*.gpg");
        key_filter.add_pattern("*.pgp");
        filters.append(key_filter);

        var all_filter = new Gtk.FileFilter();
        all_filter.name = _("All Files");
        all_filter.add_pattern("*");
        filters.append(all_filter);

        file_dialog.filters = filters;
        file_dialog.default_filter = key_filter;
        file_dialog_cancellable = new Cancellable();
        Cancellable cancellable = (!) file_dialog_cancellable;

        file_dialog.open.begin(parent_window, cancellable, (obj, res) => {
            if (file_dialog_cancellable == cancellable) {
                file_dialog_cancellable = null;
            }
            file_import_active = false;
            if (!ui_operation_is_current(operation_generation)) return;
            try {
                var file = file_dialog.open.end(res);
                if (file != null) {
                    import_key_from_file.begin(file.get_path());
                }
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    internal async void import_key_from_file(string path) {
        uint operation_generation = begin_ui_operation();
        var progress = new Adw.AlertDialog(_("Importing Key..."), _("Checking and importing the selected key into DinoX's private keyring..."));
        progress.extra_child = new Gtk.Spinner() { spinning = true, halign = Gtk.Align.CENTER };
        present_transient_child_dialog(progress, dialog);
        var cancellable = new Cancellable();
        file_dialog_cancellable = cancellable;
        try {
            var contents = new ByteArray();
            var input = yield File.new_for_path(path).read_async(Priority.DEFAULT, cancellable);
            try {
                while (true) {
                    Bytes chunk = yield input.read_bytes_async(65536, Priority.DEFAULT, cancellable);
                    if (chunk.get_size() == 0) break;
                    if (contents.len + chunk.get_size() > 16 * 1024 * 1024) {
                        throw new IOError.FAILED(_("The key file is too large. Choose an OpenPGP key file up to 16 MiB."));
                    }
                    contents.append(chunk.get_data());
                    if (!ui_operation_is_current(operation_generation)) return;
                }
            } finally {
                try { input.close(null); } catch (Error ignored) { }
            }
            if (!ui_operation_is_current(operation_generation)) return;
            string payload = Base64.encode(contents.data);
            GPGHelper.KeyDataInfo? key_info = null;
            bool imported = false;
            string? error_message = null;
            SourceFunc resume = import_key_from_file.callback;
            new Thread<void*>("openpgp-file-import", () => {
                try {
                    key_info = GPGHelper.inspect_key_data_base64(payload);
                    if (((!) key_info).valid_key_data) imported = GPGHelper.import_key_data_base64(payload);
                } catch (Error e) { error_message = e.message; }
                Idle.add((owned) resume);
                return null;
            });
            yield;
            // Bind only private keys proven to be contained in this exact file;
            // importing a contact's public key never assigns its private key.
            if (imported && key_info != null && db != null && account != null) {
                foreach (string fingerprint in ((!) key_info).secret_fingerprints) {
                    db.bind_private_key_to_account((!) account, fingerprint);
                }
            }
            progress.force_close();
            if (imported) {
                keys_changed();
                if (!ui_operation_is_current(operation_generation)) return;
                yield load_keys();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Key Imported"), key_info != null && ((!) key_info).secret_fingerprints.size > 0
                    ? _("The key is available below. Select it to use it for this account; the current encryption mode has not changed.")
                    : _("The public key was imported into DinoX's keyring. Your account's encryption mode and key selection have not changed."));
            } else {
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Import failed: ") + (error_message ?? _("The file does not contain an importable OpenPGP key.")));
            }
        } catch (Error e) {
            progress.force_close();
            if (!ui_operation_is_current(operation_generation)) return;
            show_message(_("Error"), e.message);
        } finally {
            if (file_dialog_cancellable == cancellable) file_dialog_cancellable = null;
            progress.force_close();
        }
    }

    private void export_key(GpgKeyInfo key, bool export_secret = false) {
        cancel_file_dialog();
        uint operation_generation = begin_ui_operation();
        var file_dialog = new Gtk.FileDialog();
        if (export_secret) {
            file_dialog.title = _("Export Secret Key (Backup)");
            file_dialog.initial_name = key.email.replace("@", "_") + "_SECRET.asc";
        } else {
            file_dialog.title = _("Export Public Key");
            file_dialog.initial_name = key.email.replace("@", "_") + "_public.asc";
        }
        file_dialog_cancellable = new Cancellable();
        Cancellable cancellable = (!) file_dialog_cancellable;

        file_dialog.save.begin(parent_window, cancellable, (obj, res) => {
            if (file_dialog_cancellable == cancellable) {
                file_dialog_cancellable = null;
            }
            if (!ui_operation_is_current(operation_generation)) return;
            try {
                var file = file_dialog.save.end(res);
                if (file != null) {
                    export_key_to_file.begin(key, file.get_path(), export_secret, operation_generation);
                }
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    private async void export_key_to_file(GpgKeyInfo key, string path, bool export_secret = false, uint operation_generation = 0) {
        try {
            string? openpgp_gnupg_home = GPGHelper.get_homedir_path();
            string gpg_bin = GPGHelper.get_binary_path();
            if (openpgp_gnupg_home == null || openpgp_gnupg_home.length == 0) {
                throw new IOError.FAILED("OpenPGP keyring directory is not configured");
            }

            string[] argv;
            if (export_secret) {
                argv = { gpg_bin, "--no-secmem-warning", "--homedir", openpgp_gnupg_home, "--armor", "--export-secret-keys", key.fingerprint };
            } else {
                argv = { gpg_bin, "--no-secmem-warning", "--homedir", openpgp_gnupg_home, "--armor", "--export", key.fingerprint };
            }

            var proc = new_subprocess(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? stdout_str = null;
            string? stderr_str = null;

            bool ok = yield communicate_gpg_utf8_with_timeout(proc, "", out stdout_str, out stderr_str);
            if (operation_generation != 0 && !ui_operation_is_current(operation_generation)) return;

            if (ok && stdout_str != null && stdout_str.length > 0) {
                try {
                    // Use File.replace_contents_async correctly
                    File f = File.new_for_path(path);
                    yield f.replace_contents_async(stdout_str.data, null, false, FileCreateFlags.NONE, null, null);
                    if (operation_generation != 0 && !ui_operation_is_current(operation_generation)) return;
                    if (export_secret) {
                        show_message(_("Success"), _("Secret key exported to: ") + path + "\n\n" + _("Keep this file safe! Anyone with this file can read your encrypted messages."));
                    } else {
                        show_message(_("Success"), _("Key exported to: ") + path);
                    }
                } catch (Error e) {
                    if (operation_generation != 0 && !ui_operation_is_current(operation_generation)) return;
                    show_message(_("Error"), e.message);
                }
            } else {
                if (operation_generation != 0 && !ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Export failed."));
            }
        } catch (Error e) {
            if (operation_generation != 0 && !ui_operation_is_current(operation_generation)) return;
            show_message(_("Error"), e.message);
        }
    }

    private bool matches_fingerprint(string configured_key, string fingerprint) {
        return configured_key == fingerprint || fingerprint.has_suffix(configured_key) || configured_key.has_suffix(fingerprint);
    }

    private void resend_presence_for_account() {
        if (stream_interactor == null || account == null) return;
        var presence_manager = ((!) stream_interactor).get_module<Dino.PresenceManager>(Dino.PresenceManager.IDENTITY);
        if (presence_manager != null) {
            presence_manager.resend_presence((!) account);
        }
    }

    private void refresh_active_openpgp_conversations_for_account() {
        if (stream_interactor == null || account == null) return;
        var manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
        if (manager != null) {
            // Account mode changes also affect the unselected OpenPGP menu
            // entry. Emit only the display event, preserving readiness work.
            manager.key_state_changed((!) account, null);
            manager.refresh_active_openpgp_conversations((!) account);
        }
    }

    private void invalidate_active_xmpp_contact_refreshes_for_account() {
        if (stream_interactor == null || account == null) return;
        var manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
        if (manager != null) {
            manager.invalidate_active_xep0373_contact_refreshes((!) account);
        }
    }

    private void retract_previous_xmpp_key_if_needed(string? previous_key, string previous_mode, string? replacement_key = null) {
        if (xep0373_manager == null || account == null || previous_mode != Database.ACCOUNT_KEY_MODE_XMPP) return;
        if (previous_key != null && replacement_key != null && matches_fingerprint((!) previous_key, (!) replacement_key)) return;
        xep0373_manager.replace_published_key((!) account, previous_key, replacement_key);
    }

    private void publish_selected_xmpp_key(string? previous_key, string previous_mode, string fingerprint) {
        if (xep0373_manager == null || account == null) return;
        if (previous_mode == Database.ACCOUNT_KEY_MODE_XMPP &&
                previous_key != null && !matches_fingerprint((!) previous_key, fingerprint)) {
            xep0373_manager.replace_published_key((!) account, previous_key, fingerprint);
        } else {
            xep0373_manager.republish_key((!) account);
        }
    }

    private void select_xmpp_account_key(string fingerprint) {
        if (db == null || account == null) return;
        string? previous_key = db.get_account_xmpp_key((!) account);
        string previous_mode = db.get_account_key_mode((!) account);

        db.set_account_xmpp_key((!) account, fingerprint);
        sync_legacy_presence_module();
        resend_presence_for_account();
        publish_selected_xmpp_key(previous_key, previous_mode, fingerprint);
        invalidate_active_xmpp_contact_refreshes_for_account();
        refresh_active_openpgp_conversations_for_account();
    }

    internal async bool disable_xmpp_account_key(string fingerprint) {
        if (db == null || account == null || xep0373_manager == null) return false;

        string? previous_key = db.get_account_xmpp_key((!) account);
        if (previous_key == null || !matches_fingerprint((!) previous_key, fingerprint)) return false;

        bool pubsub_ok = yield xep0373_manager.retract_published_key((!) account, (!) previous_key);
        if (!pubsub_ok) return false;
        string? current_key = db.get_account_xmpp_key((!) account);
        if (current_key == null || !matches_fingerprint((!) current_key, (!) previous_key)) return false;

        db.remove_account_xmpp_key((!) account);
        sync_legacy_presence_module();
        resend_presence_for_account();
        refresh_active_openpgp_conversations_for_account();
        return true;
    }

    private void confirm_disable_xmpp_account_key(string fingerprint) {
        uint confirm_generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(
            _("Disable OpenPGP for XMPP?"),
            _("This removes the XMPP PubSub publication and stops using this key for XEP-0373/0374 on this account. The secret key stays local and legacy XEP-0027/keyserver state is not changed.")
        );
        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("disable", _("Disable XMPP Publishing"));
        confirm.set_response_appearance("disable", Adw.ResponseAppearance.DESTRUCTIVE);
        confirm.default_response = "cancel";
        confirm.close_response = "cancel";
        confirm.response.connect((response) => {
            if (response != "disable") return;
            if (!ui_operation_is_current(confirm_generation)) return;
            uint operation_generation = begin_ui_operation();
            var progress = new Adw.AlertDialog(_("Disabling OpenPGP for XMPP..."), _("Removing the XMPP PubSub publication..."));
            var spinner = new Gtk.Spinner() { spinning = true };
            spinner.set_size_request(32, 32);
            spinner.halign = Gtk.Align.CENTER;
            progress.extra_child = spinner;
            present_transient_child_dialog(progress, dialog);

            disable_xmpp_account_key.begin(fingerprint, (obj, res) => {
                bool disabled = disable_xmpp_account_key.end(res);
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;

                if (disabled) {
                    keys_changed();
                    dialog.force_close();
                    show_message(_("OpenPGP for XMPP Disabled"), _("DinoX no longer publishes this key through XMPP PubSub for this account. The secret key stays local and legacy XEP-0027/keyserver state was not changed."));
                } else {
                    show_message(_("Error"), _("Could not remove the XMPP publication. OpenPGP for XMPP was not disabled."));
                }
            });
        });
        present_transient_child_dialog(confirm, dialog);
    }

    private void select_legacy_account_key(string fingerprint) {
        if (db == null || account == null) return;

        db.set_account_legacy_key((!) account, fingerprint);
        sync_legacy_presence_module();
        resend_presence_for_account();
        refresh_active_openpgp_conversations_for_account();
    }

    private void disable_legacy_account_key(string fingerprint) {
        if (db == null || account == null) return;

        string? previous_key = db.get_account_legacy_key((!) account);
        if (previous_key == null || !matches_fingerprint((!) previous_key, fingerprint)) return;

        db.remove_account_legacy_key((!) account);
        sync_legacy_presence_module();
        resend_presence_for_account();
        refresh_active_openpgp_conversations_for_account();
    }

    private void remove_account_key_if_matches(string fingerprint, bool retract_xmpp_publication = true) {
        if (db == null || account == null) return;
        string? xmpp_key = db.get_account_xmpp_key(account);
        string? legacy_key = db.get_account_legacy_key(account);
        bool removed_xmpp = xmpp_key != null && matches_fingerprint((!) xmpp_key, fingerprint);
        bool removed_legacy = legacy_key != null && matches_fingerprint((!) legacy_key, fingerprint);

        if (removed_xmpp) {
            db.remove_account_xmpp_key(account);
            if (retract_xmpp_publication) {
                retract_previous_xmpp_key_if_needed(xmpp_key, Database.ACCOUNT_KEY_MODE_XMPP);
            }
        }
        if (removed_legacy) {
            db.remove_account_legacy_key(account);
        }
        if (removed_xmpp || removed_legacy) {
            sync_legacy_presence_module();
            resend_presence_for_account();
            refresh_active_openpgp_conversations_for_account();
        }
    }

    private void remove_xmpp_account_key_if_matches(string fingerprint) {
        if (db == null || account == null) return;
        string? xmpp_key = db.get_account_xmpp_key(account);
        if (xmpp_key == null || !matches_fingerprint((!) xmpp_key, fingerprint)) return;

        db.remove_account_xmpp_key(account);
        sync_legacy_presence_module();
        resend_presence_for_account();
        refresh_active_openpgp_conversations_for_account();
    }

    private void sync_legacy_presence_module() {
        if (db == null || account == null || legacy_module == null) return;
        ((!) legacy_module).set_private_key_id(db.get_account_legacy_key_for_presence((!) account));
    }

    private bool should_publish_revocation_to_keyserver(GpgKeyInfo key) {
        return db != null && db.is_key_published(key.fingerprint) && key.has_email_uid;
    }

    private bool should_retract_xmpp_publication_for_key(GpgKeyInfo key) {
        if (db == null || account == null) return false;
        string? current_xmpp_key = db.get_account_xmpp_key(account);
        if (current_xmpp_key != null && ((!) current_xmpp_key).length > 0) {
            return matches_fingerprint((!) current_xmpp_key, key.fingerprint);
        }
        return false;
    }

    private void finish_keyring_change() {
        GPGHelper.invalidate_secret_keys_cache();
        keys_changed();
        dialog.force_close();
    }

    private bool ensure_key_is_not_shared(string fingerprint) {
        if (db == null || account == null) return true;
        var application = parent_window.application as Dino.Application;
        Gee.Set<int>? existing_accounts = null;
        if (application != null) {
            existing_accounts = new Gee.HashSet<int>();
            // Disabled accounts still own their keys. Deleted core accounts
            // must not be mistaken for live users of a historical assignment.
            foreach (Dino.Entities.Account other in application.db.get_accounts()) existing_accounts.add(other.id);
        }
        if (!db.key_has_other_account_users((!) account, fingerprint, existing_accounts)) return true;
        show_message(_("Key Assigned to Another Account"),
            _("This key is also assigned to another DinoX account. Revoking or deleting it would affect that account too. Remove its key selections and manual assignment there first, or keep the key locally."));
        return false;
    }

    private async bool cleanup_backup_before_revocation(string fingerprint, uint generation) {
        if (account == null || xep0373_manager == null || db == null) {
            if (ui_operation_is_current(generation)) show_message(_("Server Backup Not Checked"),
                _("The server backup could not be checked. The key was not revoked or deleted. Connect this account and try again."));
            return false;
        }
        try {
            SecretBackupCleanupResult result = yield xep0373_manager.cleanup_secret_key_backup_for_key((!) account, fingerprint);
            if (!ui_operation_is_current(generation)) return false;
            switch (result) {
                case SecretBackupCleanupResult.ABSENT:
                case SecretBackupCleanupResult.UNRELATED:
                case SecretBackupCleanupResult.DELETED:
                    return true;
                case SecretBackupCleanupResult.UNKNOWN:
                    show_message(_("Server Backup Not Identified"),
                        _("DinoX cannot safely identify the keys in this account's current server backup. Restore it using its backup code to identify it, or use Delete Server Backup to remove the whole backup explicitly. The key was not revoked or deleted."));
                    break;
                case SecretBackupCleanupResult.MULTIPLE:
                    show_message(_("Server Backup Contains Other Keys"),
                        _("This backup also contains other private keys and cannot be removed for just this key. Save a local copy of all keys you need, then use Delete Server Backup and create a new backup for the keys you want to keep. The key was not revoked or deleted."));
                    break;
                case SecretBackupCleanupResult.FAILED:
                    load_keys.begin();
                    show_message(_("Server Backup Cleanup Failed"),
                        _("The matching server backup could not be removed. The key was not revoked or deleted. DinoX will retry the cleanup when this account reconnects; then retry revoking the key."));
                    break;
            }
        } catch (Error e) {
            if (ui_operation_is_current(generation)) show_message(_("Server Backup Not Checked"),
                _("The server backup could not be checked. The key was not revoked or deleted. Connect this account and try again."));
        }
        return false;
    }

    private void confirm_delete_server_backup() {
        if (account == null || xep0373_manager == null) return;
        uint generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(_("Delete This Account's Server Backup?"),
            _("This removes the entire encrypted private-key backup for %s from the server, including every key it contains. Other devices will no longer be able to restore it. Local keys and public-key publications are kept.").printf(((!) account).bare_jid.to_string()));
        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("delete", _("Delete Server Backup"));
        confirm.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        confirm.default_response = "cancel";
        confirm.close_response = "cancel";
        confirm.response.connect((response) => {
            if (response == "delete" && ui_operation_is_current(generation)) delete_server_backup.begin();
        });
        present_transient_child_dialog(confirm, dialog);
    }

    private async void delete_server_backup() {
        uint generation = begin_ui_operation();
        var progress = new Adw.AlertDialog(_("Deleting Server Backup..."), _("Checking and removing this account's server backup..."));
        progress.extra_child = new Gtk.Spinner() { spinning = true, halign = Gtk.Align.CENTER };
        present_transient_child_dialog(progress, dialog);
        try {
            string? payload = yield xep0373_manager.fetch_secret_key_backup_checked((!) account);
            if (!ui_operation_is_current(generation)) return;
            bool deleted = payload == null || yield xep0373_manager.retract_secret_key_backup_if_unchanged((!) account, (!) payload);
            if (!ui_operation_is_current(generation)) return;
            progress.force_close();
            if (deleted) {
                load_keys.begin();
                show_message(_("Server Backup Removed"), _("This account has no server backup now. Local keys and public-key publications were kept."));
            } else {
                show_message(_("Server Backup Cleanup Failed"), _("The backup was not removed. The server may be unavailable or another device may have replaced the backup. Try again."));
            }
        } catch (Error e) {
            if (ui_operation_is_current(generation)) show_message(_("Server Backup Cleanup Failed"),
                _("The backup was not removed. The server may be unavailable or another device may have replaced the backup. Try again."));
        } finally { progress.force_close(); }
    }

    private void confirm_delete_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint confirm_generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(_("Delete Key?"),
            _("Delete this key?\n\n%s\n\nWarning: The key will be removed locally without revocation. If it is currently published for OpenPGP for XMPP, DinoX must remove the XMPP publication before deleting it.\n\nConsider using 'Revoke and Delete' instead.\n\nThis cannot be undone!").printf(key.uid));

        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("delete", _("Delete"));
        confirm.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        confirm.default_response = "cancel";
        confirm.close_response = "cancel";

        confirm.response.connect((response) => {
            if (response == "delete") {
                if (!ui_operation_is_current(confirm_generation)) return;
                delete_key.begin(key);
            }
        });

        present_transient_child_dialog(confirm, dialog);
    }

    private async void delete_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint operation_generation = begin_ui_operation();
        var progress = new Adw.AlertDialog(_("Deleting..."), _("Deleting key from the local OpenPGP keyring..."));
        var spinner = new Gtk.Spinner() { spinning = true };
        spinner.set_size_request(32, 32);
        spinner.halign = Gtk.Align.CENTER;
        progress.extra_child = spinner;
        present_transient_child_dialog(progress, dialog);

        bool delete_ok = false;
        string? error_msg = null;
        SourceFunc callback_ref = delete_key.callback;
        string fp_copy = key.fingerprint;
        bool retract_xmpp_publication = should_retract_xmpp_publication_for_key(key);

        if (retract_xmpp_publication) {
            if (xep0373_manager == null || account == null) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not deleted."));
                return;
            }
            bool pubsub_ok = yield xep0373_manager.retract_published_key((!) account, key.fingerprint);
            if (!pubsub_ok) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not deleted."));
                return;
            }
            remove_xmpp_account_key_if_matches(key.fingerprint);
        }

        if (!ui_operation_is_current(operation_generation) || !ensure_key_is_not_shared(key.fingerprint)) {
            progress.force_close();
            return;
        }

        new Thread<void*>("delete-openpgp-key", () => {
            try {
                delete_ok = GPGHelper.delete_secret_and_public_key(fp_copy);
            } catch (Error e) {
                error_msg = e.message;
                debug("Delete key failed: %s", e.message);
            }
            Idle.add((owned) callback_ref);
            return null;
        });
        yield;

        bool ui_current = ui_operation_is_current(operation_generation);
        progress.force_close();

        if (delete_ok) {
            if (db != null) db.unbind_private_key(key.fingerprint);
            remove_account_key_if_matches(key.fingerprint, !retract_xmpp_publication);
            if (!ui_current) {
                GPGHelper.invalidate_secret_keys_cache();
                keys_changed();
                return;
            }
            finish_keyring_change();
            show_message(_("Success"), _("Key deleted."));
        } else {
            if (!ui_current) return;
            string details = _("Delete failed: ") + (error_msg ?? _("Unknown error"));
            if (retract_xmpp_publication) {
                details += "\n" + _("The XMPP publication was already removed; the key was kept locally.");
            }
            show_message(_("Error"), details);
        }
    }

    private void confirm_revoke_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint confirm_generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(_("Revoke Key?"),
            _("Revoke this key?\n\n%s\n\nThe key will be permanently marked as invalid. This cannot be undone!\n\nDinoX will update only the publications that apply to this key: XMPP publication for OpenPGP-for-XMPP keys, and keyserver revocation upload for legacy keys that were uploaded to a keyserver.").printf(key.uid));

        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("revoke", _("Revoke"));
        confirm.set_response_appearance("revoke", Adw.ResponseAppearance.DESTRUCTIVE);
        confirm.default_response = "cancel";
        confirm.close_response = "cancel";

        confirm.response.connect((response) => {
            if (response == "revoke") {
                if (!ui_operation_is_current(confirm_generation)) return;
                perform_revoke_key.begin(key);
            }
        });

        present_transient_child_dialog(confirm, dialog);
    }

    private async void perform_revoke_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint operation_generation = begin_ui_operation();
        // Show progress dialog
        var progress = new Adw.AlertDialog(_("Revoking..."), _("Revoking key and updating applicable publications..."));
        var spinner = new Gtk.Spinner() { spinning = true };
        spinner.set_size_request(32, 32);
        spinner.halign = Gtk.Align.CENTER;
        progress.extra_child = spinner;
        present_transient_child_dialog(progress, dialog);

        bool gpg_ok = false;
        bool pubsub_ok = false;
        bool xmpp_publication_retracted = false;
        bool keyserver_ok = false;
        string? error_msg = null;

        // 1. Revoke key in GPG (background thread)
        SourceFunc callback_ref = perform_revoke_key.callback;
        string fp_copy = key.fingerprint;
        bool publish_revocation_to_keyserver = should_publish_revocation_to_keyserver(key);
        bool retract_xmpp_publication = should_retract_xmpp_publication_for_key(key);

        if (!yield cleanup_backup_before_revocation(key.fingerprint, operation_generation)) {
            progress.force_close();
            return;
        }

        if (retract_xmpp_publication) {
            if (xep0373_manager == null || account == null) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not revoked."));
                return;
            }
            pubsub_ok = yield xep0373_manager.retract_published_key((!) account, key.fingerprint);
            if (!pubsub_ok) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not revoked."));
                return;
            }
            xmpp_publication_retracted = true;
        }

        if (!ui_operation_is_current(operation_generation) || !ensure_key_is_not_shared(key.fingerprint)) {
            progress.force_close();
            return;
        }

        new Thread<void*>("revoke-key", () => {
            try {
                gpg_ok = GPGHelper.revoke_key(fp_copy, 0, "Key revoked by user");
            } catch (Error e) {
                error_msg = e.message;
                debug("Revoke failed: %s", e.message);
            }

            // Also try uploading the revoked key to keyserver if this was a
            // legacy keyserver-published key. XMPP-only keys must not be sent
            // to a keyserver.
            if (gpg_ok && publish_revocation_to_keyserver) {
                try {
                    keyserver_ok = GPGHelper.upload_key_to_keyserver(fp_copy);
                } catch (Error e) {
                    debug("Keyserver upload of revoked key failed: %s", e.message);
                    // Not fatal - key is still revoked locally
                }
            }

            Idle.add((owned) callback_ref);
            return null;
        });
        yield;

        // 2. Clean up database
        if (gpg_ok) {
            remove_account_key_if_matches(key.fingerprint, !retract_xmpp_publication);
        } else if (xmpp_publication_retracted) {
            remove_xmpp_account_key_if_matches(key.fingerprint);
        }

        // 3. Invalidate caches
        GPGHelper.invalidate_secret_keys_cache();

        bool ui_current = ui_operation_is_current(operation_generation);
        progress.force_close();
        if (!ui_current) {
            if (gpg_ok || xmpp_publication_retracted) {
                keys_changed();
            }
            return;
        }

        if (gpg_ok) {
            finish_keyring_change();
            string details = _("Key revoked successfully.");
            if (keyserver_ok) {
                details += "\n" + _("Revocation published to keyserver.");
            }
            if (pubsub_ok) {
                details += "\n" + _("Key removed from XMPP server.");
            }
            show_message(_("Success"), details);
        } else {
            string details = _("Revocation failed: ") + (error_msg ?? _("Unknown error"));
            if (xmpp_publication_retracted) {
                details += "\n" + _("The XMPP publication was already removed; the key was kept locally.");
            }
            show_message(_("Error"), details);
        }
    }

    private void confirm_revoke_and_delete_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint confirm_generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(_("Revoke and Delete Key?"),
            _("Revoke and delete this key?\n\n%s\n\nThe key will be permanently invalidated and then removed. DinoX will update only the publications that apply to this key: XMPP publication for OpenPGP-for-XMPP keys, and keyserver revocation upload for legacy keys that were uploaded to a keyserver.\n\nYou will no longer be able to decrypt old messages encrypted with this key.\n\nThis cannot be undone!").printf(key.uid));

        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("revoke-delete", _("Revoke and Delete"));
        confirm.set_response_appearance("revoke-delete", Adw.ResponseAppearance.DESTRUCTIVE);
        confirm.default_response = "cancel";
        confirm.close_response = "cancel";

        confirm.response.connect((response) => {
            if (response == "revoke-delete") {
                if (!ui_operation_is_current(confirm_generation)) return;
                perform_revoke_and_delete_key.begin(key);
            }
        });

        present_transient_child_dialog(confirm, dialog);
    }

    private async void perform_revoke_and_delete_key(GpgKeyInfo key) {
        if (!ensure_key_is_not_shared(key.fingerprint)) return;
        uint operation_generation = begin_ui_operation();
        // Show progress dialog
        var progress = new Adw.AlertDialog(_("Revoking & Deleting..."), _("Revoking key, updating applicable publications, and deleting..."));
        var spinner = new Gtk.Spinner() { spinning = true };
        spinner.set_size_request(32, 32);
        spinner.halign = Gtk.Align.CENTER;
        progress.extra_child = spinner;
        present_transient_child_dialog(progress, dialog);

        bool gpg_ok = false;
        bool keyserver_ok = false;
        bool delete_ok = false;
        bool pubsub_ok = false;
        bool xmpp_publication_retracted = false;
        string? error_msg = null;

        SourceFunc callback_ref = perform_revoke_and_delete_key.callback;
        string fp_copy = key.fingerprint;
        bool publish_revocation_to_keyserver = should_publish_revocation_to_keyserver(key);
        bool retract_xmpp_publication = should_retract_xmpp_publication_for_key(key);

        if (!yield cleanup_backup_before_revocation(key.fingerprint, operation_generation)) {
            progress.force_close();
            return;
        }

        // 1. Remove XMPP publication before locally mutating the key.  If this
        // fails, keep the key untouched so the user can retry without leaving a
        // stale XEP-0373 PubSub item behind.
        if (retract_xmpp_publication) {
            if (xep0373_manager == null || account == null) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not revoked or deleted."));
                return;
            }
            pubsub_ok = yield xep0373_manager.retract_published_key((!) account, key.fingerprint);
            if (!pubsub_ok) {
                progress.force_close();
                if (!ui_operation_is_current(operation_generation)) return;
                show_message(_("Error"), _("Could not remove the XMPP publication. The key was not revoked or deleted."));
                return;
            }
            xmpp_publication_retracted = true;
        }

        if (!ui_operation_is_current(operation_generation) || !ensure_key_is_not_shared(key.fingerprint)) {
            progress.force_close();
            return;
        }

        // 2. Revoke key in GPG + upload to keyserver (background thread)
        new Thread<void*>("revoke-delete-key", () => {
            try {
                gpg_ok = GPGHelper.revoke_key(fp_copy, 0, "Key revoked by user");
            } catch (Error e) {
                error_msg = e.message;
                debug("Revoke failed: %s", e.message);
            }

            // Upload revoked key to keyserver before deleting, but only for
            // legacy keyserver-published keys. XMPP-only keys stay off the
            // keyserver.
            if (gpg_ok && publish_revocation_to_keyserver) {
                try {
                    keyserver_ok = GPGHelper.upload_key_to_keyserver(fp_copy);
                } catch (Error e) {
                    debug("Keyserver upload of revoked key failed: %s", e.message);
                }
            }

            Idle.add((owned) callback_ref);
            return null;
        });
        yield;

        // 3. Clean up database
        if (gpg_ok) {
            remove_account_key_if_matches(key.fingerprint, !retract_xmpp_publication);
        } else if (xmpp_publication_retracted) {
            remove_xmpp_account_key_if_matches(key.fingerprint);
        }

        if (gpg_ok && publish_revocation_to_keyserver && !keyserver_ok) {
            GPGHelper.invalidate_secret_keys_cache();
            if (!ui_operation_is_current(operation_generation)) {
                keys_changed();
                return;
            }
            progress.force_close();
            finish_keyring_change();
            show_message(_("Error"), _("The key was revoked locally, but the revocation could not be uploaded to the keyserver. The key was kept locally so you can retry publishing the revocation."));
            return;
        }

        // 4. Now delete the key from GPG keyring (background thread)
        if (gpg_ok) {
            SourceFunc delete_callback = perform_revoke_and_delete_key.callback;

            new Thread<void*>("delete-revoked-key", () => {
                try {
                    delete_ok = GPGHelper.delete_secret_and_public_key(fp_copy);
                } catch (Error e) {
                    debug("Delete after revoke error: %s", e.message);
                }
                Idle.add((owned) delete_callback);
                return null;
            });
            yield;
            if (delete_ok && db != null) db.unbind_private_key(key.fingerprint);
        }

        // 5. Invalidate caches
        GPGHelper.invalidate_secret_keys_cache();

        bool ui_current = ui_operation_is_current(operation_generation);
        progress.force_close();
        if (!ui_current) {
            if (gpg_ok || xmpp_publication_retracted) {
                keys_changed();
            }
            return;
        }

        if (gpg_ok) {
            finish_keyring_change();
            string details = _("Key revoked");
            if (keyserver_ok) {
                details += ", " + _("keyserver notified");
            }
            if (pubsub_ok) {
                details += ", " + _("XMPP server updated");
            }
            if (delete_ok) {
                details += ", " + _("key deleted");
            }
            details += ".";
            show_message(_("Success"), details);
        } else {
            string details = _("Revocation failed: ") + (error_msg ?? _("Unknown error"));
            if (xmpp_publication_retracted) {
                details += "\n" + _("The XMPP publication was already removed; the key was kept locally.");
            }
            show_message(_("Error"), details);
        }
    }

    private void show_message(string title, string message) {
        var msg = new Adw.AlertDialog(title, message);
        msg.add_response("ok", _("OK"));
        msg.default_response = "ok";
        msg.close_response = "ok";
        msg.present(parent_window);
    }

    private void publish_key_to_keyserver(GpgKeyInfo key) {
        if (!key.has_email_uid) {
            show_message(_("Not Available"), _("This key has no email user ID for legacy keyserver publishing. Create a legacy key with a real email address for XEP-0027/keyserver use."));
            return;
        }

        uint confirm_generation = begin_ui_operation();
        var confirm = new Adw.AlertDialog(
            _("Publish Key?"),
            _("This uploads your public key to keys.openpgp.org. You must verify the email address on the key before XEP-0027 clients can reliably find it.")
        );
        confirm.add_response("cancel", _("Cancel"));
        confirm.add_response("publish", _("Publish"));
        confirm.set_response_appearance("publish", Adw.ResponseAppearance.SUGGESTED);

        confirm.response.connect((response) => {
            if (response == "publish") {
                if (!ui_operation_is_current(confirm_generation)) return;
                uint operation_generation = begin_ui_operation();
                // Show progress
                var progress = new Adw.AlertDialog(_("Publishing..."), _("Uploading key to keyserver..."));
                var spinner = new Gtk.Spinner() { spinning = true };
                spinner.set_size_request(32, 32);
                spinner.halign = Gtk.Align.CENTER;
                progress.extra_child = spinner;
                present_transient_child_dialog(progress, dialog);

                upload_key_async.begin(key.fingerprint, (obj, res) => {
                    bool uploaded = upload_key_async.end(res);
                    progress.force_close();

                    if (uploaded) {
                        if (db != null) {
                            db.set_key_published(key.fingerprint);
                        }
                        keys_changed();
                    }
                    if (!ui_operation_is_current(operation_generation)) return;
                    if (uploaded) {
                        load_keys.begin();
                        show_message(_("Success"), _("Key uploaded to the OpenPGP keyserver. Check your email to verify it before XEP-0027 clients can reliably find it. The active OpenPGP mode for this account was not changed."));
                    } else {
                        show_message(_("Error"), _("Failed to publish key. Check your internet connection."));
                    }
                });
            }
        });

        present_transient_child_dialog(confirm, dialog);
    }

    // Get fingerprint of the most recently created key
    private string? get_newest_key_fingerprint() {
        try {
            if (GPGHelper.is_shutting_down()) return null;

            string? openpgp_gnupg_home = GPGHelper.get_homedir_path();
            string gpg_bin = GPGHelper.get_binary_path();
            if (openpgp_gnupg_home == null || openpgp_gnupg_home.length == 0) {
                throw new IOError.FAILED("OpenPGP keyring directory is not configured");
            }

            string[] argv = { gpg_bin, "--no-secmem-warning", "--homedir", openpgp_gnupg_home, "--list-secret-keys", "--with-colons" };
            var proc = new_subprocess(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? stdout_str = null;
            string? stderr_str = null;

            bool timed_out = false;
            var cancellable = new Cancellable();
            GPGHelper.register_external_subprocess_for_shutdown(proc, cancellable);
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
                timed_out = true;
                cancellable.cancel();
                proc.force_exit();
                timeout_id = 0;
                return Source.REMOVE;
            });

            try {
                proc.communicate_utf8("", cancellable, out stdout_str, out stderr_str);
            } finally {
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                }
                GPGHelper.clear_external_subprocess_for_shutdown(proc);
            }

            if (timed_out || GPGHelper.is_shutting_down()) return null;

            if (stdout_str == null) return null;

            string? newest_fpr = null;
            int64 newest_time = 0;
            int64 current_time = 0;
            bool in_main_key = false;

            foreach (var line in stdout_str.split("\n")) {
                var parts = line.split(":");
                if (parts.length < 2) continue;

                if (parts[0] == "sec") {
                    in_main_key = true;
                    current_time = 0;
                    if (parts.length > 5 && parts[5].length > 0) {
                        current_time = int64.parse(parts[5]);
                    }
                } else if (parts[0] == "fpr" && in_main_key) {
                    if (parts.length > 9 && parts[9].length > 0) {
                        if (current_time > newest_time) {
                            newest_time = current_time;
                            newest_fpr = parts[9];
                        }
                    }
                    in_main_key = false;
                }
            }
            return newest_fpr;
        } catch (Error e) {
            debug("Failed to get newest key: %s", e.message);
            return null;
        }
    }

    private void show_server_backup_dialog(string fingerprint) {
        if (xep0373_manager == null || account == null || server_dialog_flow_is_active() || !reserve_server_secret_operation()) return;
        uint flow_generation = begin_server_backup_flow();
        server_backup_operation_generation = flow_generation;
        trace_server_backup_flow("dialog requested", flow_generation, fingerprint);

        string backup_code;
        try {
            backup_code = GPGHelper.generate_xep0373_backup_code();
        } catch (Error err) {
            cancel_server_backup_flow(flow_generation);
            show_message(_("Backup Failed"), _("Failed to generate a secure backup code.") + "\n\n" + err.message);
            return;
        }
        
        var backup_dialog = new Adw.AlertDialog(
            _("Backup Secret Key to Server"),
            _("Save this backup code before uploading the key. You will need exactly this code to restore the key on another device.")
        );

        server_backup_password_dialog = backup_dialog;

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 6;
        box.margin_bottom = 6;

        var code_title = new Gtk.Label(_("Backup Code"));
        code_title.xalign = 0;
        code_title.add_css_class("heading");
        box.append(code_title);

        var code_label = new Gtk.Label(backup_code);
        code_label.xalign = 0;
        code_label.selectable = true;
        code_label.wrap = true;
        code_label.add_css_class("monospace");
        box.append(code_label);

        var copy_button = new Gtk.Button.with_label(_("Copy Backup Code"));
        copy_button.halign = Gtk.Align.START;
        copy_button.clicked.connect(() => {
            get_dialog_parent_widget().get_display().get_clipboard().set_text(backup_code);
            copy_button.set_label(_("Backup Code Copied"));
            backup_dialog.set_response_enabled("backup", true);
        });
        box.append(copy_button);

        backup_dialog.extra_child = box;

        backup_dialog.add_response("cancel", _("Cancel"));
        backup_dialog.add_response("backup", _("Backup to Server"));
        backup_dialog.set_response_appearance("backup", Adw.ResponseAppearance.SUGGESTED);
        backup_dialog.set_response_enabled("backup", false);
        backup_dialog.close_response = "cancel";

        bool backup_requested = false;
        bool backup_closed_handled = false;
        uint backup_close_fallback_id = 0;
        string backup_passphrase = "";
        backup_dialog.closed.connect(() => {
            trace_server_backup_flow(backup_requested ? "dialog closed after backup response" : "dialog closed without backup response", flow_generation, fingerprint);
            if (backup_closed_handled) return;
            if (backup_close_fallback_id != 0) return;
            backup_close_fallback_id = Idle.add(() => {
                backup_close_fallback_id = 0;
                if (backup_closed_handled) return Source.REMOVE;
                backup_closed_handled = true;
                if (server_backup_password_dialog == backup_dialog) {
                    server_backup_password_dialog = null;
                }

                if (backup_requested) {
                    string passphrase = backup_passphrase;
                    backup_passphrase = "";
                    if (server_backup_flow_is_current(flow_generation)) {
                        trace_server_backup_flow("starting upload from dialog close", flow_generation, fingerprint);
                        start_server_backup_upload(flow_generation, fingerprint, passphrase);
                    }
                } else {
                    backup_passphrase = "";
                    if (server_backup_flow_is_current(flow_generation)) {
                        trace_server_backup_flow("cancel from dialog close", flow_generation, fingerprint);
                        cancel_server_backup_flow(flow_generation);
                    }
                }
                return Source.REMOVE;
            });
        });

        backup_dialog.response.connect((response) => {
            trace_server_backup_flow("dialog response " + response, flow_generation, fingerprint);
            if (!server_backup_flow_is_current(flow_generation)) return;
            backup_requested = response == "backup";
            if (backup_requested) {
                backup_passphrase = backup_code;
                trace_server_backup_flow("backup response accepted", flow_generation, fingerprint);
            } else {
                backup_passphrase = "";
                trace_server_backup_flow("non-backup response", flow_generation, fingerprint);
            }
        });

        backup_dialog.present(get_dialog_parent_widget());
    }
    
    private void start_server_backup_upload(uint flow_generation, string fingerprint, string passphrase) {
        if (!server_backup_flow_is_current(flow_generation)) return;
        trace_server_backup_flow("upload start", flow_generation, fingerprint);

        var progress = new Adw.AlertDialog(_("Backing up..."), _("Encrypting and uploading key..."));
        var spinner = new Gtk.Spinner();
        spinner.spinning = true;
        spinner.set_size_request(48, 48);
        spinner.halign = Gtk.Align.CENTER;
        spinner.margin_top = 12;
        spinner.margin_bottom = 12;
        progress.extra_child = spinner;
        server_backup_progress_dialog = progress;
        progress.closed.connect(() => {
            if (server_backup_progress_dialog == progress) {
                server_backup_progress_dialog = null;
            }
        });
        progress.present(get_dialog_parent_widget());

        server_secret_backend_pending = true;
        server_backup_timed_out = false;
        clear_server_backup_timeout(flow_generation);
        server_backup_timeout_generation = flow_generation;
        server_backup_timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
            if (server_backup_timeout_generation != flow_generation) {
                return Source.REMOVE;
            }
            if (!server_secret_backend_pending) {
                server_backup_timeout_id = 0;
                return Source.REMOVE;
            }
            server_backup_timed_out = true;
            server_secret_backend_pending = false;
            if (server_backup_flow_is_current(flow_generation)) {
                cancel_server_backup_flow(flow_generation);
                show_message(_("Backup Failed"), _("GnuPG or the server did not respond while backing up the secret key."));
            } else {
                release_server_secret_operation_for_backup(flow_generation);
            }
            progress.force_close();
            server_backup_timeout_id = 0;
            return Source.REMOVE;
        });

        perform_server_backup(flow_generation, fingerprint, passphrase, progress);
    }

    private void perform_server_backup(uint flow_generation, string fingerprint, string passphrase, Adw.AlertDialog progress) {
        trace_server_backup_flow("encrypt start", flow_generation, fingerprint);
        new Thread<void*>("openpgp-encrypt-backup", () => {
            string? encrypted_payload = null;
            string? error_msg = null;
            bool cancelled = false;
            try {
                encrypted_payload = GPGHelper.export_and_encrypt_secret_key(fingerprint, passphrase);
            } catch (IOError.CANCELLED err) {
                cancelled = true;
            } catch (Error err) {
                error_msg = err.message;
            }
	            
            Idle.add(() => {
                if (server_backup_timeout_generation != flow_generation) return Source.REMOVE;
                if (server_backup_timed_out) return Source.REMOVE;
                if (!server_backup_flow_is_current(flow_generation)) {
                    clear_server_backup_timeout(flow_generation);
                    server_secret_backend_pending = false;
                    progress.force_close();
                    release_server_secret_operation_for_backup(flow_generation);
                    return Source.REMOVE;
                }

                if (cancelled) {
                    cancel_server_backup_flow(flow_generation);
                    progress.force_close();
                } else if (error_msg != null) {
                    trace_server_backup_flow("encrypt failed", flow_generation, fingerprint);
                    clear_server_backup_timeout(flow_generation);
                    server_secret_backend_pending = false;
                    close_server_backup_progress_with_result(flow_generation, progress, _("Encryption Error"), (!) error_msg);
                } else if (encrypted_payload != null) {
                    trace_server_backup_flow("encrypt completed", flow_generation, fingerprint);
                    finish_server_backup.begin(flow_generation, (!) encrypted_payload, progress, fingerprint);
                } else {
                    trace_server_backup_flow("encrypt produced no payload", flow_generation, fingerprint);
                    clear_server_backup_timeout(flow_generation);
                    server_secret_backend_pending = false;
                    close_server_backup_progress_with_result(flow_generation, progress, _("Backup Failed"), _("Failed to prepare the encrypted secret key backup."));
                }
                return Source.REMOVE;
            });
            return null;
        });
    }

    private async void finish_server_backup(uint flow_generation, string encrypted_payload, Adw.AlertDialog progress, string fingerprint) {
        trace_server_backup_flow("publish start", flow_generation);
        if (server_backup_timeout_generation != flow_generation) return;
        if (!server_backup_flow_is_current(flow_generation)) {
            clear_server_backup_timeout(flow_generation);
            server_secret_backend_pending = false;
            release_server_secret_operation_for_backup(flow_generation);
            return;
        }
        if (account == null || xep0373_manager == null) {
            clear_server_backup_timeout(flow_generation);
            server_secret_backend_pending = false;
            close_server_backup_progress_with_result(flow_generation, progress, _("Backup Failed"), _("Failed to publish the backup to the server."));
            return;
        }

        Dino.Entities.Account backup_account = (!) account;
        bool published = yield xep0373_manager.publish_secret_key_backup(backup_account, encrypted_payload);
        if (published && db != null) {
            var fingerprints = new Gee.ArrayList<string>();
            fingerprints.add(fingerprint);
            db.remember_secret_key_backup(backup_account, encrypted_payload, fingerprints);
            db.bind_private_key_to_account(backup_account, fingerprint);
        }
        trace_server_backup_flow(published ? "publish success" : "publish failed", flow_generation);
        if (server_backup_timeout_generation != flow_generation) return;
        if (server_backup_timed_out) return;
        clear_server_backup_timeout(flow_generation);
        server_secret_backend_pending = false;
        if (!server_backup_flow_is_current(flow_generation)) {
            progress.force_close();
            release_server_secret_operation_for_backup(flow_generation);
            return;
        }

        if (published) {
            close_server_backup_progress_with_result(flow_generation, progress, _("Backup Successful"), _("Your encrypted secret key has been securely stored on the server."));
        } else {
            close_server_backup_progress_with_result(flow_generation, progress, _("Backup Failed"), _("Failed to publish the backup to the server."));
        }
    }

    private void trace_server_backup_flow(string event, uint flow_generation, string? fingerprint = null) {
        // Intentionally silent. Kept as a single choke point for temporary
        // restore/backup lifecycle diagnostics during future investigations.
    }

    private bool file_import_active = false;
    private bool server_backup_active = false;
    private bool server_import_active = false;
    private bool server_import_fetch_pending = false;
    private bool server_secret_backend_pending = false;
    private bool server_backup_timed_out = false;
    private uint server_backup_timeout_id = 0;
    private uint server_backup_timeout_generation = 0;
    private uint server_backup_generation = 0;
    private string? server_backup_operation_token = null;
    private uint server_backup_operation_generation = 0;
    private Adw.AlertDialog? server_backup_password_dialog = null;
    private Adw.AlertDialog? server_backup_progress_dialog = null;
    private Adw.AlertDialog? server_backup_result_dialog = null;
    private bool server_import_closing = false;
    private uint server_import_closing_clear_id = 0;
    private bool server_import_fetch_rearm_required = false;
    private bool server_import_fetch_activation_armed = false;
    private bool server_import_fetch_pointer_inside = false;
    private ServerSecretRestoreFlow? active_server_restore_flow = null;
    private static Gee.HashSet<string>? active_server_secret_operations = null;
    private static uint next_server_secret_operation_id = 0;
    private static uint next_server_secret_restore_flow_id = 0;

    private static Gee.HashSet<string> get_active_server_secret_operations() {
        if (active_server_secret_operations == null) {
            active_server_secret_operations = new Gee.HashSet<string>();
        }
        return (!) active_server_secret_operations;
    }

    private string? reserve_server_secret_operation_token() {
        var active_operations = get_active_server_secret_operations();
        if (active_operations.size > 0) return null;
        string token = "%u".printf(++next_server_secret_operation_id);
        active_operations.add(token);
        return token;
    }

    private bool server_secret_operation_token_is_owned(string? token) {
        return token != null && get_active_server_secret_operations().contains((!) token);
    }

    private void release_server_secret_operation_token(string? token) {
        if (token == null) return;
        get_active_server_secret_operations().remove((!) token);
    }

    private bool reserve_server_secret_operation() {
        if (account == null) return false;
        string? token = reserve_server_secret_operation_token();
        if (token == null) return false;
        server_backup_operation_token = token;
        return true;
    }

    private void release_server_secret_operation() {
        release_server_secret_operation_token(server_backup_operation_token);
        server_backup_operation_token = null;
        server_backup_operation_generation = 0;
    }

    private void release_server_secret_operation_for_backup(uint generation) {
        if (generation != server_backup_operation_generation) return;
        release_server_secret_operation();
    }

    private void clear_server_backup_timeout(uint flow_generation) {
        if (server_backup_timeout_generation != flow_generation) return;
        if (server_backup_timeout_id != 0) {
            Source.remove(server_backup_timeout_id);
            server_backup_timeout_id = 0;
        }
    }

    private bool server_dialog_flow_is_active() {
        return file_import_active || server_backup_active || server_import_active || server_import_closing || active_server_restore_flow != null;
    }

    private uint begin_server_backup_flow() {
        server_backup_active = true;
        return ++server_backup_generation;
    }

    private bool server_backup_flow_is_current(uint generation) {
        return server_backup_active && generation == server_backup_generation;
    }

    private void cancel_server_backup_flow(uint generation) {
        if (generation != server_backup_generation) return;
        server_backup_generation++;
        server_backup_active = false;
        clear_server_backup_timeout(generation);
        server_backup_timeout_generation = 0;
        var password_dialog = server_backup_password_dialog;
        server_backup_password_dialog = null;
        if (password_dialog != null) {
            ((!) password_dialog).force_close();
        }
        var progress_dialog = server_backup_progress_dialog;
        server_backup_progress_dialog = null;
        if (progress_dialog != null) {
            ((!) progress_dialog).force_close();
        }
        var result_dialog = server_backup_result_dialog;
        server_backup_result_dialog = null;
        if (result_dialog != null) {
            ((!) result_dialog).force_close();
        }
        release_server_secret_operation_for_backup(generation);
    }

    private void finish_server_backup_flow(uint generation) {
        if (generation != server_backup_generation) return;
        server_backup_generation++;
        server_backup_active = false;
        release_server_secret_operation_for_backup(generation);
    }

    private void show_server_backup_result(uint flow_generation, string title, string message) {
        if (!server_backup_flow_is_current(flow_generation)) return;

        var result_dialog = new Adw.AlertDialog(title, message);
        result_dialog.add_response("ok", _("OK"));
        result_dialog.default_response = "ok";
        result_dialog.close_response = "ok";
        server_backup_result_dialog = result_dialog;
        bool result_handled = false;
        result_dialog.response.connect((response) => {
            if (result_handled) return;
            result_handled = true;
            if (server_backup_result_dialog == result_dialog) {
                server_backup_result_dialog = null;
            }
            finish_server_backup_flow(flow_generation);
        });
        result_dialog.closed.connect(() => {
            if (result_handled) return;
            result_handled = true;
            if (server_backup_result_dialog == result_dialog) {
                server_backup_result_dialog = null;
            }
            if (server_backup_flow_is_current(flow_generation)) {
                finish_server_backup_flow(flow_generation);
            }
        });
        result_dialog.present(get_dialog_parent_widget());
    }

    private void close_server_backup_progress_with_result(uint flow_generation, Adw.AlertDialog progress, string title, string message) {
        if (!server_backup_flow_is_current(flow_generation)) return;

        bool closed_by_flow = false;
        bool result_shown = false;
        progress.closed.connect(() => {
            if (!closed_by_flow || result_shown || !server_backup_flow_is_current(flow_generation)) return;
            result_shown = true;
            show_server_backup_result(flow_generation, title, message);
        });
        closed_by_flow = true;
        progress.force_close();
    }

    private bool is_current_server_restore_flow(ServerSecretRestoreFlow flow) {
        return active_server_restore_flow == flow &&
            account != null &&
            ((!) account).id == flow.account_id &&
            flow.operation_token != null &&
            server_secret_operation_token_is_owned(flow.operation_token);
    }

    private void disconnect_server_fetch_progress_handlers(ServerSecretRestoreFlow flow, Adw.AlertDialog progress) {
        if (flow.fetch_progress_response_handler_id != 0) {
            if (SignalHandler.is_connected(progress, flow.fetch_progress_response_handler_id)) {
                progress.disconnect(flow.fetch_progress_response_handler_id);
            }
            flow.fetch_progress_response_handler_id = 0;
        }
        if (flow.fetch_progress_closed_handler_id != 0) {
            if (SignalHandler.is_connected(progress, flow.fetch_progress_closed_handler_id)) {
                progress.disconnect(flow.fetch_progress_closed_handler_id);
            }
            flow.fetch_progress_closed_handler_id = 0;
        }
    }

    private void remove_server_restore_sources(ServerSecretRestoreFlow flow) {
        if (flow.fetch_timeout_id != 0) {
            Source.remove(flow.fetch_timeout_id);
            flow.fetch_timeout_id = 0;
        }
        if (flow.import_timeout_id != 0) {
            Source.remove(flow.import_timeout_id);
            flow.import_timeout_id = 0;
        }
        if (flow.fetch_result_idle_id != 0) {
            Source.remove(flow.fetch_result_idle_id);
            flow.fetch_result_idle_id = 0;
        }
        if (flow.inspect_timeout_id != 0) {
            Source.remove(flow.inspect_timeout_id);
            flow.inspect_timeout_id = 0;
        }
        if (flow.password_close_fallback_id != 0) {
            Source.remove(flow.password_close_fallback_id);
            flow.password_close_fallback_id = 0;
        }
        if (flow.fetch_progress_dialog != null) {
            disconnect_server_fetch_progress_handlers(flow, (!) flow.fetch_progress_dialog);
        }
    }

    private void close_server_restore_dialogs(ServerSecretRestoreFlow flow) {
        var fetch_dialog = flow.fetch_progress_dialog;
        flow.fetch_progress_dialog = null;
        if (fetch_dialog != null) {
            disconnect_server_fetch_progress_handlers(flow, (!) fetch_dialog);
            ((!) fetch_dialog).force_close();
        }

        var password_dialog = flow.password_dialog;
        flow.password_dialog = null;
        if (flow.password_entry != null) {
            ((!) flow.password_entry).set_text("");
            flow.password_entry = null;
        }
        if (password_dialog != null) {
            ((!) password_dialog).force_close();
        }

        var import_dialog = flow.import_progress_dialog;
        flow.import_progress_dialog = null;
        if (import_dialog != null) {
            ((!) import_dialog).force_close();
        }

        var result_dialog = flow.result_dialog;
        flow.result_dialog = null;
        if (result_dialog != null) {
            ((!) result_dialog).force_close();
        }
    }

    private void release_server_restore_flow(ServerSecretRestoreFlow flow) {
        trace_server_import_flow("release flow begin", flow);
        if (active_server_restore_flow == flow) {
            active_server_restore_flow = null;
        }
        server_import_active = false;
        server_import_fetch_pending = false;
        server_secret_backend_pending = false;

        string? token = flow.operation_token;
        flow.operation_token = null;
        if (server_import_closing) {
            Timeout.add(SERVER_IMPORT_REENTRY_GUARD_MS, () => {
                trace_server_import_flow("release delayed operation token");
                release_server_secret_operation_token(token);
                return Source.REMOVE;
            });
            return;
        }
        Idle.add(() => {
            trace_server_import_flow("release idle operation token");
            release_server_secret_operation_token(token);
            return Source.REMOVE;
        });
    }

    private void arm_server_import_closing_guard() {
        trace_server_import_flow("arm closing guard");
        if (server_import_closing_clear_id != 0) {
            Source.remove(server_import_closing_clear_id);
            server_import_closing_clear_id = 0;
        }
        server_import_closing = true;
        server_import_closing_clear_id = Timeout.add(SERVER_IMPORT_REENTRY_GUARD_MS, () => {
            trace_server_import_flow("clear closing guard");
            server_import_closing_clear_id = 0;
            server_import_closing = false;
            return Source.REMOVE;
        });
    }

    private void require_server_import_fetch_rearm(string reason, ServerSecretRestoreFlow? flow = null) {
        server_import_fetch_rearm_required = true;
        server_import_fetch_activation_armed = false;
        if (flow != null) {
            trace_server_import_flow("fetch activation rearm required after " + reason, (!) flow);
        } else {
            trace_server_import_flow("fetch activation rearm required after " + reason);
        }
    }

    private void clear_server_import_fetch_rearm(string reason) {
        if (!server_import_fetch_rearm_required) return;
        server_import_fetch_rearm_required = false;
        server_import_fetch_activation_armed = false;
        trace_server_import_flow("fetch activation rearmed by " + reason);
    }

    private void arm_server_import_fetch_activation(string reason) {
        if (!server_import_fetch_rearm_required) return;
        if (server_dialog_flow_is_active() || get_active_server_secret_operations().size > 0) return;
        server_import_fetch_activation_armed = true;
        trace_server_import_flow("fetch activation armed by " + reason);
    }

    private void cancel_server_import_flow(ServerSecretRestoreFlow flow) {
        trace_server_import_flow("cancel flow requested", flow);
        if (active_server_restore_flow != flow || flow.closing) return;
        flow.closing = true;
        flow.state = ServerSecretRestoreState.CANCELLED;
        require_server_import_fetch_rearm("cancel", flow);
        remove_server_restore_sources(flow);
        close_server_restore_dialogs(flow);
        arm_server_import_closing_guard();
        release_server_restore_flow(flow);
    }

    private void suppress_server_import_fetch_activation_after_result(ServerSecretRestoreFlow flow) {
        require_server_import_fetch_rearm("result", flow);
    }

    private void finish_server_import_flow(ServerSecretRestoreFlow flow) {
        trace_server_import_flow("finish flow requested", flow);
        if (active_server_restore_flow != flow || flow.closing) return;
        flow.closing = true;
        remove_server_restore_sources(flow);
        release_server_restore_flow(flow);
    }

    private Gtk.Widget get_dialog_parent_widget() {
        return dialog != null && is_open ? (Gtk.Widget) dialog : (Gtk.Widget) parent_window;
    }

    private void trace_server_import_flow(string event, ServerSecretRestoreFlow? flow = null) {
        // Intentionally silent. Kept as a single choke point for temporary
        // restore/import lifecycle diagnostics during future investigations.
    }

    private void try_start_server_import_from_ui() {
        if (server_import_fetch_rearm_required) {
            if (!server_import_fetch_activation_armed) {
                trace_server_import_flow("fetch button click blocked by rearm gate");
                return;
            }
        }
        if (server_dialog_flow_is_active()) {
            trace_server_import_flow("fetch button click blocked by active flow");
            return;
        }
        if (get_active_server_secret_operations().size > 0) {
            trace_server_import_flow("fetch button click blocked by operation token");
            return;
        }
        if (server_import_fetch_rearm_required) {
            clear_server_import_fetch_rearm("fresh activation");
        }
        server_import_fetch_activation_armed = false;
        start_server_import_dialog();
    }

    private void start_server_import_dialog() {
        trace_server_import_flow("start requested");
        if (xep0373_manager == null || account == null || server_dialog_flow_is_active()) {
            trace_server_import_flow("start blocked by precondition");
            return;
        }
        string? operation_token = reserve_server_secret_operation_token();
        if (operation_token == null) {
            trace_server_import_flow("start blocked by operation token");
            return;
        }

        Xep0373KeyManager manager = (!) xep0373_manager;
        Dino.Entities.Account import_account = (!) account;
        var flow = new ServerSecretRestoreFlow(++next_server_secret_restore_flow_id, import_account, (!) operation_token);
        flow.state = ServerSecretRestoreState.FETCHING;
        active_server_restore_flow = flow;
        server_import_active = true;
        trace_server_import_flow("start accepted", flow);
        show_server_import_dialog.begin(flow, manager);
    }

    private async void show_server_import_dialog(ServerSecretRestoreFlow flow, Xep0373KeyManager manager) {
        trace_server_import_flow("fetch dialog enter", flow);
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) return;

        var progress = new Adw.AlertDialog(_("Checking Server..."), _("Looking for a secret key backup..."));
        var spinner = new Gtk.Spinner();
        spinner.spinning = true;
        spinner.set_size_request(48, 48);
        spinner.halign = Gtk.Align.CENTER;
        spinner.margin_top = 12;
        spinner.margin_bottom = 12;
        progress.extra_child = spinner;
        progress.add_response("cancel", _("Cancel"));
        progress.close_response = "cancel";
        flow.fetch_progress_dialog = progress;
        bool progress_closed_for_transition = false;
        bool progress_transition_timeout = false;
        bool progress_showing_terminal_result = false;

        flow.fetch_progress_response_handler_id = progress.response.connect((response) => {
            trace_server_import_flow("fetch progress response " + response, flow);
            if (response == "cancel" &&
                    !progress_closed_for_transition &&
                    flow.fetch_progress_dialog == progress &&
                    is_current_server_restore_flow(flow) &&
                    flow.state == ServerSecretRestoreState.FETCHING) {
                cancel_server_import_flow(flow);
            }
        });
        flow.fetch_progress_closed_handler_id = progress.closed.connect(() => {
            trace_server_import_flow("fetch progress closed", flow);
            if (flow.fetch_progress_dialog == progress) {
                if (flow.fetch_progress_response_handler_id != 0 &&
                        SignalHandler.is_connected(progress, flow.fetch_progress_response_handler_id)) {
                    progress.disconnect(flow.fetch_progress_response_handler_id);
                }
                flow.fetch_progress_response_handler_id = 0;
                flow.fetch_progress_closed_handler_id = 0;
                flow.fetch_progress_dialog = null;
                if (progress_closed_for_transition) {
                    if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING || flow.closing) {
                        return;
                    }
                    if (progress_transition_timeout) {
                        show_server_import_result(flow, _("Import Failed"), _("The server did not respond while fetching the secret key backup."), false);
                    }
                } else if (progress_showing_terminal_result &&
                        is_current_server_restore_flow(flow) &&
                        flow.state == ServerSecretRestoreState.RESULT_OPEN) {
                    suppress_server_import_fetch_activation_after_result(flow);
                    finish_server_import_flow(flow);
                } else if (is_current_server_restore_flow(flow) && flow.state == ServerSecretRestoreState.FETCHING) {
                    cancel_server_import_flow(flow);
                }
            }
        });
        progress.present(get_dialog_parent_widget());

        server_import_fetch_pending = true;
        server_secret_backend_pending = true;
        flow.fetch_timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
            if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) {
                flow.fetch_timeout_id = 0;
                return Source.REMOVE;
            }
            server_import_fetch_pending = false;
            server_secret_backend_pending = false;
            flow.fetch_timeout_id = 0;
            progress_closed_for_transition = true;
            progress_transition_timeout = true;
            progress.force_close();
            return Source.REMOVE;
        });

        bool fetched_from_secret_backup = false;
        string? fetched_payload = null;
        bool fetch_failed = false;
        try {
            fetched_payload = yield manager.fetch_secret_key_backup_checked(flow.account);
        } catch (Error e) { fetch_failed = true; }
        if (fetched_payload != null) {
            fetched_from_secret_backup = true;
        }
        if (fetched_payload == null) {
            trace_server_import_flow("fetch completed without payload", flow);
        } else {
            trace_server_import_flow("fetch completed with secret backup payload", flow);
        }
        if (flow.fetch_timeout_id != 0) {
            Source.remove(flow.fetch_timeout_id);
            flow.fetch_timeout_id = 0;
        }
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) {
            return;
        }
        server_import_fetch_pending = false;
        server_secret_backend_pending = false;

        if (fetch_failed) {
            flow.state = ServerSecretRestoreState.RESULT_OPEN;
            progress_showing_terminal_result = true;
            spinner.spinning = false;
            progress.extra_child = null;
            progress.heading = _("Import Failed");
            progress.body = _("Could not retrieve this account's server backup. Check the account connection and try again.");
            progress.set_response_label("cancel", _("OK"));
            return;
        }

        if (fetched_payload != null) {
            string payload = (!) fetched_payload;
            handle_fetched_server_secret_payload(flow, progress, payload, fetched_from_secret_backup);
            return;
        }

        // A missing PubSub node can return before AdwDialog has completed its
        // first presentation.  force_close() is ignored during that phase, so
        // waiting for its closed signal leaves the completed result hidden
        // behind the spinner until the user presses Cancel.  Show this terminal
        // result in the already presented dialog instead of closing and
        // reopening another alert.
        flow.state = ServerSecretRestoreState.RESULT_OPEN;
        progress_showing_terminal_result = true;
        spinner.spinning = false;
        progress.extra_child = null;
        progress.heading = _("No Backup Found");
        progress.body = _("There is no secret key backup stored on the server for this account.");
        progress.set_response_label("cancel", _("OK"));
    }

    private void handle_fetched_server_secret_payload(ServerSecretRestoreFlow flow, Adw.AlertDialog progress, string base64_payload, bool from_secret_backup_node) {
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) return;

        server_secret_backend_pending = true;
        flow.inspect_timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
            if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) {
                flow.inspect_timeout_id = 0;
                return Source.REMOVE;
            }
            server_secret_backend_pending = false;
            flow.inspect_timeout_id = 0;
            flow.inspect_terminal_pending = true;
            close_server_fetch_progress_dialog(flow, progress);
            Idle.add(() => {
                if (!is_current_server_restore_flow(flow) ||
                        flow.state != ServerSecretRestoreState.FETCHING ||
                        flow.closing) {
                    return Source.REMOVE;
                }
                show_server_import_result(flow, _("Import Failed"), _("GnuPG did not respond while checking the server key data."), false);
                return Source.REMOVE;
            });
            return Source.REMOVE;
        });
        new Thread<void*>("openpgp-inspect-server-secret", () => {
            GPGHelper.KeyDataInfo? key_info = null;
            string? inspect_error = null;
            try {
                key_info = GPGHelper.inspect_key_data_base64(base64_payload);
            } catch (Error e) {
                inspect_error = e.message;
            }

            Idle.add(() => {
                if (flow.inspect_timeout_id != 0) {
                    Source.remove(flow.inspect_timeout_id);
                    flow.inspect_timeout_id = 0;
                }
                server_secret_backend_pending = false;
                if (!is_current_server_restore_flow(flow) ||
                        flow.state != ServerSecretRestoreState.FETCHING ||
                        flow.closing ||
                        flow.inspect_terminal_pending) {
                    return Source.REMOVE;
                }

                if (inspect_error != null) {
                    debug("OpenPGP server import: fetched payload is not inspectable as raw key data: %s", (!) inspect_error);
                }

                if (key_info != null && ((!) key_info).valid_key_data) {
                    handle_inspected_server_secret_payload(flow, progress, base64_payload, (!) key_info, from_secret_backup_node);
                    return Source.REMOVE;
                }

                if (!from_secret_backup_node) {
                    close_server_fetch_progress_dialog(flow, progress);
                    Idle.add(() => {
                        if (!is_current_server_restore_flow(flow) ||
                                flow.state != ServerSecretRestoreState.FETCHING ||
                                flow.closing) {
                            return Source.REMOVE;
                        }
                        show_server_import_result(flow,
                            _("No Backup Found"),
                            _("There is no secret key backup stored on the server for this account."),
                            false);
                        return Source.REMOVE;
                    });
                    return Source.REMOVE;
                }

                close_server_fetch_progress_dialog(flow, progress);
                Idle.add(() => {
                    if (!is_current_server_restore_flow(flow) ||
                            flow.state != ServerSecretRestoreState.FETCHING ||
                            flow.closing) {
                        return Source.REMOVE;
                    }
                    show_server_import_password_dialog(flow, base64_payload);
                    return Source.REMOVE;
                });
                return Source.REMOVE;
            });
            return null;
        });
    }

    private void handle_inspected_server_secret_payload(ServerSecretRestoreFlow flow, Adw.AlertDialog progress, string base64_payload, GPGHelper.KeyDataInfo key_info, bool from_secret_backup_node) {
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) return;

        bool local_secret_key_available = server_secret_payload_already_available_for_current_account(key_info);

        if (!from_secret_backup_node) {
            close_server_fetch_progress_dialog(flow, progress);
            Idle.add(() => {
                if (!is_current_server_restore_flow(flow) ||
                        flow.state != ServerSecretRestoreState.FETCHING ||
                        flow.closing) {
                    return Source.REMOVE;
                }
                if (local_secret_key_available) {
                    show_server_import_result(flow,
                        _("No Secret Key Backup"),
                        _("The public XMPP key is published on the server and the matching private key is already available locally, but no secret key backup was found on the server."),
                        false);
                } else {
                    show_server_import_result(flow,
                        _("No Secret Key Backup"),
                        _("The public XMPP key is published on the server, but no private key backup was found for this account."),
                        false);
                }
                return Source.REMOVE;
            });
            return;
        }

        if (!key_info.contains_secret_key) {
            close_server_fetch_progress_dialog(flow, progress);
            Idle.add(() => {
                if (!is_current_server_restore_flow(flow) ||
                        flow.state != ServerSecretRestoreState.FETCHING ||
                        flow.closing) {
                    return Source.REMOVE;
                }
                if (local_secret_key_available) {
                    show_server_import_result(flow,
                        _("Key Already Present"),
                        _("The key from the server is already available for this account. No import was needed."),
                        false);
                } else {
                    show_server_import_result(flow,
                        _("No Secret Key Backup"),
                        _("The server contains public OpenPGP key data, but no private key backup for this account."),
                        false);
                }
                return Source.REMOVE;
            });
            return;
        }

        if (local_secret_key_available) {
            close_server_fetch_progress_dialog(flow, progress);
            Idle.add(() => {
                if (!is_current_server_restore_flow(flow) ||
                        flow.state != ServerSecretRestoreState.FETCHING ||
                        flow.closing) {
                    return Source.REMOVE;
                }
                show_server_import_result(flow,
                    _("Key Already Present"),
                    _("The secret key from the server is already available for this account. No import was needed."),
                    false);
                return Source.REMOVE;
            });
            return;
        }

        close_server_fetch_progress_dialog(flow, progress);
        Idle.add(() => {
            if (!is_current_server_restore_flow(flow) ||
                    flow.state != ServerSecretRestoreState.FETCHING ||
                    flow.closing) {
                return Source.REMOVE;
            }
            show_server_import_result(flow,
                _("Unsupported Backup Format"),
                _("The server contains unencrypted secret key data. DinoX now expects an encrypted XEP-0373 secret key backup. Create a new server backup to replace it."),
                false);
            return Source.REMOVE;
        });
    }

    private bool server_secret_payload_already_available_for_current_account(GPGHelper.KeyDataInfo key_info) {
        // Public-key fallback is only an availability hint. It must never
        // be imported or recorded as a private backup by this branch.
        Gee.List<string> fingerprints = key_info.contains_secret_key ? key_info.secret_fingerprints : key_info.fingerprints;
        if (fingerprints.size == 0) return false;
        foreach (string fetched_fingerprint in fingerprints) {
            bool available = false;
            foreach (GpgKeyInfo local_key in current_keys) {
                if (local_key.fingerprint.up() == fetched_fingerprint.up() &&
                        should_show_key_for_current_account(local_key)) {
                    available = true;
                    break;
                }
            }
            if (!available) return false;
        }
        return true;
    }

    private void close_server_fetch_progress_dialog(ServerSecretRestoreFlow flow, Adw.AlertDialog progress) {
        if (flow.fetch_progress_dialog == progress) {
            flow.fetch_progress_dialog = null;
        }
        disconnect_server_fetch_progress_handlers(flow, progress);
        progress.force_close();
    }

    private void show_server_import_password_dialog(ServerSecretRestoreFlow flow, string base64_payload) {
        trace_server_import_flow("password dialog requested", flow);
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.FETCHING) {
            trace_server_import_flow("password dialog blocked by state", flow);
            return;
        }
        flow.state = ServerSecretRestoreState.PASSWORD_OPEN;
        trace_server_import_flow("password dialog created", flow);

        var password_dialog = new Adw.AlertDialog(
            _("Import Secret Key"),
            _("A secret key backup was found on the server. Enter your backup code to decrypt and import it.")
        );

        var password_entry = new Gtk.PasswordEntry();
        password_entry.placeholder_text = _("Backup Code");
        password_entry.activates_default = true;
        password_entry.show_peek_icon = true;
        password_entry.hexpand = true;
        password_entry.margin_top = 12;
        password_entry.margin_bottom = 12;
        password_entry.margin_start = 12;
        password_entry.margin_end = 12;
        flow.password_entry = password_entry;
        password_dialog.extra_child = password_entry;

        if (!password_dialog.has_response("cancel")) {
            password_dialog.add_response("cancel", _("Cancel"));
        } else {
            password_dialog.set_response_label("cancel", _("Cancel"));
        }
        if (!password_dialog.has_response("import")) {
            password_dialog.add_response("import", _("Import"));
        } else {
            password_dialog.set_response_label("import", _("Import"));
        }
        password_dialog.set_response_appearance("import", Adw.ResponseAppearance.SUGGESTED);
        password_dialog.set_response_enabled("import", true);
        password_dialog.default_response = "import";
        password_dialog.close_response = "cancel";
        flow.password_dialog = password_dialog;

        password_dialog.closed.connect(() => {
            trace_server_import_flow("password dialog closed", flow);
            if (flow.password_dialog == password_dialog &&
                    !flow.password_response_handled &&
                    is_current_server_restore_flow(flow) &&
                    flow.state == ServerSecretRestoreState.PASSWORD_OPEN &&
                    flow.password_close_fallback_id == 0) {
                flow.password_close_fallback_id = Idle.add(() => {
                    flow.password_close_fallback_id = 0;
                    if (flow.password_dialog != password_dialog ||
                            flow.password_response_handled ||
                            !is_current_server_restore_flow(flow) ||
                            flow.state != ServerSecretRestoreState.PASSWORD_OPEN) {
                        return Source.REMOVE;
                    }
                    trace_server_import_flow("password dialog closed fallback cancel", flow);
                    password_entry.set_text("");
                    if (flow.password_entry == password_entry) {
                        flow.password_entry = null;
                    }
                    flow.password_dialog = null;
                    cancel_server_import_flow(flow);
                    return Source.REMOVE;
                });
            }
        });

        password_dialog.response.connect((response) => {
            trace_server_import_flow("password dialog response " + response, flow);
            if (flow.password_response_handled) return;

            if (response == "import") {
                begin_server_secret_key_import_from_password_dialog(flow, password_dialog, password_entry, base64_payload);
                return;
            }

            flow.password_response_handled = true;
            if (flow.password_close_fallback_id != 0) {
                Source.remove(flow.password_close_fallback_id);
                flow.password_close_fallback_id = 0;
            }

            password_entry.set_text("");
            if (flow.password_entry == password_entry) {
                flow.password_entry = null;
            }
            if (flow.password_dialog == password_dialog) {
                flow.password_dialog = null;
            }
            cancel_server_import_flow(flow);
        });

        password_dialog.present(get_dialog_parent_widget());
        trace_server_import_flow("password dialog presented", flow);
    }

    private void begin_server_secret_key_import_from_password_dialog(ServerSecretRestoreFlow flow, Adw.AlertDialog password_dialog, Gtk.PasswordEntry password_entry, string base64_payload) {
        trace_server_import_flow("password dialog import requested", flow);
        if (flow.password_response_handled ||
                !is_current_server_restore_flow(flow) ||
                flow.state != ServerSecretRestoreState.PASSWORD_OPEN ||
                password_entry.get_text().strip().length == 0) {
            return;
        }
        flow.password_response_handled = true;
        if (flow.password_close_fallback_id != 0) {
            Source.remove(flow.password_close_fallback_id);
            flow.password_close_fallback_id = 0;
        }

        string import_passphrase = "%s".printf(password_entry.get_text());
        password_entry.set_text("");
        if (flow.password_entry == password_entry) {
            flow.password_entry = null;
        }
        flow.state = ServerSecretRestoreState.IMPORTING;
        if (flow.password_dialog == password_dialog) {
            flow.password_dialog = null;
        }
        Idle.add(() => {
            start_server_secret_key_import(flow, base64_payload, import_passphrase);
            return Source.REMOVE;
        });
    }

    private void start_server_secret_key_import(ServerSecretRestoreFlow flow, string base64_payload, string passphrase) {
        if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.IMPORTING) return;

        server_secret_backend_pending = true;
        flow.import_timeout_id = Timeout.add_seconds(GPG_UI_OPERATION_TIMEOUT_SECONDS, () => {
            if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.IMPORTING) {
                flow.import_timeout_id = 0;
                return Source.REMOVE;
            }
            server_secret_backend_pending = false;
            flow.import_timeout_id = 0;
            show_server_import_result(flow, _("Import Failed"), _("GnuPG did not respond while importing the secret key backup."), false);
            return Source.REMOVE;
        });

        Gee.Set<string> local_account_secret_fingerprints = get_current_account_secret_key_fingerprint_set();
        new Thread<void*>("openpgp-decrypt-import", () => {
            GPGHelper.DecryptImportResult? import_result = null;
            string? error_msg = null;
            try {
                import_result = GPGHelper.decrypt_and_import_secret_key_with_result(base64_payload, passphrase, local_account_secret_fingerprints);
            } catch (Error e) {
                error_msg = e.message;
            }

            Idle.add(() => {
                if (flow.import_timeout_id != 0) {
                    Source.remove(flow.import_timeout_id);
                    flow.import_timeout_id = 0;
                }
                if (!is_current_server_restore_flow(flow) || flow.state != ServerSecretRestoreState.IMPORTING) {
                    return Source.REMOVE;
                }
                server_secret_backend_pending = false;

                if (db != null && import_result != null &&
                        (((!) import_result).already_present || ((!) import_result).imported)) {
                    Gee.List<string> fingerprints = ((!) import_result).key_info.secret_fingerprints;
                    db.remember_secret_key_backup(flow.account, base64_payload, fingerprints);
                    foreach (string fingerprint in fingerprints) db.bind_private_key_to_account(flow.account, fingerprint);
                }

                if (error_msg != null) {
                    show_server_import_result(flow, _("Import Failed"), (!) error_msg, false);
                } else if (import_result != null && ((!) import_result).already_present) {
                    show_server_import_result(flow, _("Key Already Present"), _("The secret key from the server is already available for this account. No import was needed."), false);
                } else if (import_result != null && ((!) import_result).imported) {
                    show_server_import_result(flow, _("Import Successful"), _("The secret key was successfully imported from the server."), true);
                } else {
                    show_server_import_result(flow, _("Import Failed"), _("The backup code was incorrect or the secret key backup could not be imported."), false);
                }
                return Source.REMOVE;
            });
            return null;
        });
    }

    private Gee.Set<string> get_current_account_secret_key_fingerprint_set() {
        var fingerprints = new Gee.HashSet<string>();
        foreach (GpgKeyInfo local_key in current_keys) {
            if (should_show_key_for_current_account(local_key)) {
                fingerprints.add(local_key.fingerprint.up().replace(" ", ""));
            }
        }
        return fingerprints;
    }

    private void show_server_import_result(ServerSecretRestoreFlow flow, string title, string message, bool refresh_keys) {
        if (!is_current_server_restore_flow(flow) ||
                (flow.state != ServerSecretRestoreState.FETCHING && flow.state != ServerSecretRestoreState.IMPORTING)) return;
        flow.state = ServerSecretRestoreState.RESULT_OPEN;

        var result_dialog = new Adw.AlertDialog(title, message);
        result_dialog.add_response("ok", _("OK"));
        result_dialog.default_response = "ok";
        result_dialog.close_response = "ok";
        flow.result_dialog = result_dialog;
        bool result_handled = false;
        result_dialog.response.connect((response) => {
            if (result_handled) return;
            result_handled = true;
            if (flow.result_dialog == result_dialog) {
                flow.result_dialog = null;
            }
            if (refresh_keys) {
                load_keys.begin();
                keys_changed();
            }
            suppress_server_import_fetch_activation_after_result(flow);
            finish_server_import_flow(flow);
        });
        result_dialog.closed.connect(() => {
            if (result_handled) return;
            result_handled = true;
            if (flow.result_dialog == result_dialog) {
                flow.result_dialog = null;
            }
            if (refresh_keys) {
                load_keys.begin();
                keys_changed();
            }
            suppress_server_import_fetch_activation_after_result(flow);
            finish_server_import_flow(flow);
        });
        result_dialog.present(get_dialog_parent_widget());
    }

    // Upload key to keyserver asynchronously
    private async bool upload_key_async(string fingerprint) {
        bool success = false;
        SourceFunc callback = upload_key_async.callback;

        new Thread<void*>(null, () => {
            try {
                success = GPGHelper.upload_key_to_keyserver(fingerprint);
            } catch (Error err) {
                debug("Keyserver upload failed: %s", err.message);
            }
            Idle.add((owned)callback);
            return null;
        });
        yield;
        return success;
    }
}

}
