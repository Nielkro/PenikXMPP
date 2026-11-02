using Adw;
using Dino.Entities;
using Gtk;

namespace Dino.Plugins.OpenPgp {

    public class PgpPreferencesEntry : Plugins.EncryptionPreferencesEntry {

        private Plugin plugin;

        public PgpPreferencesEntry(Plugin plugin) {
            this.plugin = plugin;
        }

        public override Object? get_widget(Account account, WidgetType type) {
            if (type != WidgetType.GTK4) return null;
            return new PgpPreferencesWidget(plugin, account);
        }

        public override string id { get { return "pgp_preferences_encryption"; }}
    }

    private class PgpPreferencesWidget : Adw.PreferencesGroup {

        private Plugin plugin;
        private Account account;
        private Gtk.ListBox? list_box;
        private KeyManagementDialog? key_dialog;
        private int key_dialog_account_id = -1;
        private ulong keys_changed_handler_id = 0;
        private ulong key_dialog_closed_handler_id = 0;
        private uint build_generation = 0;
        // private Gee.List<GPG.Key>? cached_keys = null;
        private Gee.List<GpgKeyInfo>? cached_keys = null;
        private const uint GPG_UI_OPERATION_TIMEOUT_SECONDS = 45;
        private bool destroyed = false;
        private Cancellable? key_load_cancellable = null;
        private Subprocess? key_load_process = null;

        public PgpPreferencesWidget(Plugin plugin, Account account) {
            this.plugin = plugin;
            this.account = account;
            this.title = "OpenPGP";
            var target_list = new Gtk.ListBox();
            list_box = target_list;
            target_list.selection_mode = Gtk.SelectionMode.NONE;
            target_list.add_css_class("boxed-list");
            
            // Add loading placeholder immediately
            var loading_row = new Adw.ActionRow();
            loading_row.title = _("Loading keys...");
            loading_row.add_prefix(new Gtk.Spinner() { spinning = true });
            target_list.append(loading_row);
            
            this.add(target_list);
            build_generation++;
            build_ui.begin(account, target_list, build_generation);
            // PreferencesDialog is cached and unroots its contents whenever it
            // is closed.  Unrooting therefore does not end this widget's
            // lifetime; marking it destroyed here leaves the visible rows with
            // inert activation handlers when the dialog is presented again.
            this.destroy.connect(() => { cleanup(); });
        }

        private void cleanup() {
            if (destroyed) return;
            destroyed = true;
            build_generation++;
            disconnect_key_dialog_handlers();
            if (key_dialog != null && ((!) key_dialog).is_open) {
                ((!) key_dialog).close();
            }
            cancel_key_load();
            key_dialog = null;
            key_dialog_account_id = -1;
            list_box = null;
            cached_keys = null;
        }

        private void cancel_key_load() {
            if (key_load_cancellable != null) {
                ((!) key_load_cancellable).cancel();
            }
            if (key_load_process != null) {
                ((!) key_load_process).force_exit();
            }
            key_load_cancellable = null;
            key_load_process = null;
        }

        private void clear_list(Gtk.ListBox target_list) {
            Gtk.ListBoxRow? row;
            while ((row = target_list.get_row_at_index(0)) != null) {
                target_list.remove(row);
            }
        }

        private bool build_ui_is_current(Gtk.ListBox target_list, uint generation) {
            return !destroyed && generation == build_generation && list_box == target_list;
        }

        private static bool ui_timing_enabled() {
            return Environment.get_variable("DINOX_UI_TIMING") != null;
        }

        private static void log_ui_timing(string label, int64 start_us) {
            if (!ui_timing_enabled()) return;
            double ms = (GLib.get_monotonic_time() - start_us) / 1000.0;
            GLib.message("UI-TIMING %s: %.2f ms", label, ms);
        }

        private async void build_ui(Account account_snapshot, Gtk.ListBox target_list, uint generation) {
            if (!build_ui_is_current(target_list, generation)) return;
            int64 load_start_us = ui_timing_enabled() ? GLib.get_monotonic_time() : 0;
            cached_keys = yield get_pgp_keys();
            log_ui_timing("Preferences.openpgp: load secret keys", load_start_us);
            if (!build_ui_is_current(target_list, generation)) return;
            clear_list(target_list);

            if (cached_keys == null) {
                target_list.append(new Adw.ActionRow() { title=_("Outgoing OpenPGP messages"), subtitle=_("Error in GnuPG") });
                add_manage_button(target_list, account_snapshot);
                return;
            }
            
            if (cached_keys.size == 0) {
                target_list.append(new Adw.ActionRow() { title=_("Outgoing OpenPGP messages"), subtitle=_("No keys available. Generate or import one!") });
                add_manage_button(target_list, account_snapshot);
                return;
            }

            string? current_xmpp_key_id = plugin.db.get_account_xmpp_key(account_snapshot);
            if (current_xmpp_key_id != null && !cached_keys_contain_usable_xmpp_key((!) current_xmpp_key_id)) {
                warning("OpenPGP: Configured XMPP account key %s for %s is missing, revoked, expired, or unusable; disabling it",
                        (!) current_xmpp_key_id, account_snapshot.bare_jid.to_string());
                plugin.db.remove_account_xmpp_key(account_snapshot);
                retract_previous_xmpp_key_if_needed(current_xmpp_key_id, Database.ACCOUNT_KEY_MODE_XMPP);
                sync_legacy_presence_module();
                resend_presence_for_current_account();
                refresh_active_openpgp_conversations_for_current_account();
                current_xmpp_key_id = null;
            }

            string account_key_mode = plugin.db.get_account_key_mode(account_snapshot);
            string? current_legacy_key_id = plugin.db.get_account_legacy_key(account_snapshot);
            if (current_legacy_key_id != null && !cached_keys_contain_usable_legacy_key((!) current_legacy_key_id)) {
                warning("OpenPGP: Configured legacy account key %s for %s is missing, revoked, expired, unusable, or has no email UID; disabling it",
                        (!) current_legacy_key_id, account_snapshot.bare_jid.to_string());
                plugin.db.remove_account_legacy_key(account_snapshot);
                sync_legacy_presence_module();
                resend_presence_for_current_account();
                refresh_active_openpgp_conversations_for_current_account();
                account_key_mode = plugin.db.get_account_key_mode(account_snapshot);
                current_legacy_key_id = null;
            }
            var send_mode_row = new Adw.ActionRow();
            send_mode_row.title = _("Outgoing OpenPGP messages");
            if (account_key_mode == Database.ACCOUNT_KEY_MODE_LEGACY && current_legacy_key_id != null) {
                send_mode_row.subtitle = _("DinoX currently sends OpenPGP as legacy XEP-0027 using keyserver/contact keys.");
                send_mode_row.add_suffix(new Gtk.Image.from_icon_name("network-workgroup-symbolic"));
            } else if (account_key_mode == Database.ACCOUNT_KEY_MODE_XMPP && current_xmpp_key_id != null) {
                send_mode_row.subtitle = _("DinoX currently sends OpenPGP for XMPP using XEP-0373/0374.");
                send_mode_row.add_suffix(new Gtk.Image.from_icon_name("channel-secure-symbolic"));
            } else {
                send_mode_row.subtitle = _("No OpenPGP send key is active for this account.");
                send_mode_row.add_suffix(new Gtk.Image.from_icon_name("dialog-information-symbolic"));
            }
            target_list.append(send_mode_row);

            add_manage_button(target_list, account_snapshot);
        }
        
        private bool matches_fingerprint(string configured_key, string fingerprint) {
            return configured_key == fingerprint || fingerprint.has_suffix(configured_key) || configured_key.has_suffix(fingerprint);
        }

        private bool cached_keys_contain_usable_xmpp_key(string configured_key) {
            if (cached_keys == null) return false;
            foreach (var key in cached_keys) {
                if (matches_fingerprint(configured_key, key.fingerprint)) {
                    return key.usable_for_openpgp() && key.has_matching_xmpp_uid;
                }
            }
            return false;
        }

        private bool cached_keys_contain_usable_legacy_key(string configured_key) {
            if (cached_keys == null) return false;
            foreach (var key in cached_keys) {
                if (matches_fingerprint(configured_key, key.fingerprint)) {
                    return key.usable_for_openpgp() && key.has_email_uid;
                }
            }
            return false;
        }

        private void retract_previous_xmpp_key_if_needed(string? previous_key, string previous_mode, string? replacement_key = null) {
            if (destroyed || plugin.xep0373_manager == null || previous_mode != Database.ACCOUNT_KEY_MODE_XMPP) return;
            if (previous_key != null && replacement_key != null && matches_fingerprint((!) previous_key, (!) replacement_key)) return;
            plugin.xep0373_manager.replace_published_key(account, previous_key, replacement_key);
        }

        private void resend_presence_for_current_account() {
            if (destroyed) return;
            var presence_manager = plugin.app.stream_interactor.get_module<Dino.PresenceManager>(Dino.PresenceManager.IDENTITY);
            if (presence_manager != null) {
                presence_manager.resend_presence(account);
                debug("OpenPGP: Resent presence after account key usage change for %s", account.bare_jid.to_string());
            }
        }

        private void refresh_active_openpgp_conversations_for_current_account() {
            if (destroyed) return;
            var manager = plugin.app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
            if (manager != null) {
                manager.refresh_active_openpgp_conversations(account);
            }
        }

        private void sync_legacy_presence_module() {
            if (destroyed) return;
            Module? legacy_module = plugin.modules.has_key(account) ? plugin.modules[account] : null;
            if (legacy_module == null) return;
            ((!) legacy_module).set_private_key_id(plugin.db.get_account_legacy_key_for_presence(account));
        }

        private void add_manage_button(Gtk.ListBox target_list, Account account_snapshot) {
            var manage_row = new Adw.ActionRow();
            manage_row.title = _("Manage Keys");
            manage_row.subtitle = _("Generate, import, export, or delete keys");
            manage_row.activatable = true;
            manage_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
            manage_row.activated.connect(() => { open_key_dialog(account_snapshot); });
            target_list.append(manage_row);
        }

        private void on_keys_changed() {
            if (destroyed || list_box == null) return;
            build_generation++;
            build_ui.begin(account, (!) list_box, build_generation);
        }

        private void disconnect_key_dialog_handlers() {
            if (key_dialog != null && keys_changed_handler_id > 0) {
                KeyManagementDialog dialog = (!) key_dialog;
                if (SignalHandler.is_connected(dialog, keys_changed_handler_id)) {
                    dialog.disconnect(keys_changed_handler_id);
                }
            }
            if (key_dialog != null && key_dialog_closed_handler_id > 0) {
                KeyManagementDialog dialog = (!) key_dialog;
                if (SignalHandler.is_connected(dialog, key_dialog_closed_handler_id)) {
                    dialog.disconnect(key_dialog_closed_handler_id);
                }
            }
            keys_changed_handler_id = 0;
            key_dialog_closed_handler_id = 0;
        }

        private void open_key_dialog(Account account_snapshot) {
            if (list_box == null) return;
            if (key_dialog != null && ((!) key_dialog).is_open && key_dialog_account_id == account_snapshot.id) {
                ((!) key_dialog).present();
                return;
            }
            if (key_dialog != null && ((!) key_dialog).is_open) {
                ((!) key_dialog).close();
            }
            disconnect_key_dialog_handlers();

            var root = ((!) list_box).get_root();
            if (!(root is Gtk.Window)) {
                warning("OpenPGP: Cannot present key management without a parent window");
                return;
            }

            Gtk.Window parent_window = (Gtk.Window) root;
            Module? legacy_module = plugin.modules.has_key(account_snapshot) ? plugin.modules[account_snapshot] : null;
            var new_dialog = new KeyManagementDialog(parent_window, plugin.db, plugin.xep0373_manager, account_snapshot, legacy_module, plugin.app.stream_interactor);
            key_dialog = new_dialog;
            key_dialog_account_id = account_snapshot.id;
            keys_changed_handler_id = new_dialog.keys_changed.connect(() => { on_keys_changed(); });
            key_dialog_closed_handler_id = new_dialog.dialog_closed.connect(() => {
                if (key_dialog == new_dialog) {
                    if (keys_changed_handler_id != 0 && SignalHandler.is_connected(new_dialog, keys_changed_handler_id)) {
                        new_dialog.disconnect(keys_changed_handler_id);
                    }
                    key_dialog = null;
                    key_dialog_account_id = -1;
                    keys_changed_handler_id = 0;
                    key_dialog_closed_handler_id = 0;
                }
            });
            new_dialog.present();
        }

        private async Gee.List<GpgKeyInfo>? get_pgp_keys() {
            cancel_key_load();
            var keys = new Gee.ArrayList<GpgKeyInfo>();
            string? account_bare_jid = account.bare_jid.to_string();
            
            // Call GPG CLI directly to avoid GPGME crashes in preferences UI
            try {
                if (GPGHelper.is_shutting_down()) return null;

                string openpgp_gnupg_home = Environment.get_variable("GNUPGHOME");
                if (openpgp_gnupg_home == null) openpgp_gnupg_home = Path.build_filename(Application.get_storage_dir(), "openpgp", "gnupg");

                string gpg_bin = Environment.find_program_in_path("gpg");
                if (gpg_bin == null) {
                    string? exe_dir = Environment.get_variable("DINOX_EXE_DIR");
                    if (exe_dir != null && exe_dir.length > 0) {
                        string bundled_gpg = Path.build_filename(exe_dir, "bin", "gpg.exe");
                        if (FileUtils.test(bundled_gpg, FileTest.EXISTS)) gpg_bin = bundled_gpg;
                    }
                    if (gpg_bin == null) {
                        if (FileUtils.test("C:/msys64/mingw64/bin/gpg.exe", FileTest.EXISTS)) gpg_bin = "C:/msys64/mingw64/bin/gpg.exe";
                        else if (FileUtils.test("/usr/bin/gpg.exe", FileTest.EXISTS)) gpg_bin = "/usr/bin/gpg.exe";
                        else if (FileUtils.test("C:/msys64/usr/bin/gpg.exe", FileTest.EXISTS)) gpg_bin = "C:/msys64/usr/bin/gpg.exe";
                        else gpg_bin = "gpg";
                    }
                }

                string[] argv = { gpg_bin, "--no-secmem-warning", "--homedir", openpgp_gnupg_home, "--list-secret-keys", "--with-colons" };
                
                // Use Subprocess for async execution to not block UI
                var proc = new_subprocess(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                key_load_process = proc;
                string? stdout_str = null;
                string? stderr_str = null;

                bool timed_out = false;
                var cancellable = new Cancellable();
                key_load_cancellable = cancellable;
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
                    yield proc.communicate_utf8_async("", cancellable, out stdout_str, out stderr_str);
                } catch (Error e) {
                    if (timed_out) {
                        warning("OpenPGP: Timed out while loading keys for preferences");
                        return null;
                    }
                    if (GPGHelper.is_shutting_down()) {
                        return null;
                    }
                    throw e;
                } finally {
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                    }
                    GPGHelper.clear_external_subprocess_for_shutdown(proc);
                    if (key_load_process == proc) key_load_process = null;
                    if (key_load_cancellable == cancellable) key_load_cancellable = null;
                }

                if (timed_out) {
                    warning("OpenPGP: Timed out while loading keys for preferences");
                    return null;
                }

                if (proc.get_exit_status() == 0 && stdout_str != null) {
                    string? current_fpr = null;
                    GpgKeyInfo? current_key = null;
                    int64 current_created = 0;
                    bool current_revoked = false;
                    bool current_expired = false;
                    bool current_can_encrypt = true;
                    bool current_can_sign = true;
                    bool in_main_key = false;
                    
                    foreach (var line in stdout_str.split("\n")) {
                        var parts = line.split(":");
                        if (parts.length < 2) continue;
                        
                        if (parts[0] == "sec") {
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
                            if (parts.length > 5 && parts[5].length > 0) current_created = int64.parse(parts[5]);
                        } else if (parts[0] == "ssb") {
                            in_main_key = false;
                        } else if (parts[0] == "fpr" && in_main_key && current_fpr == null) {
                            if (parts.length > 9 && parts[9].length > 0) current_fpr = parts[9];
                        } else if (parts[0] == "uid" && in_main_key && current_fpr != null) {
                            if (parts.length > 9) {
                                string uid = GPGHelper.decode_gpg_colon_escapes(parts[9]);
                                if (uid.length > 0) {
                                    if (current_key == null) {
                                        current_key = new GpgKeyInfo(current_fpr, uid, current_created,
                                                current_revoked, current_expired, current_can_encrypt, current_can_sign, account_bare_jid);
                                        keys.add((!) current_key);
                                    } else {
                                        ((!) current_key).note_user_id(uid, account_bare_jid);
                                    }
                                }
                            }
                        }
                    }
                }
            } catch (Error e) {
                debug("Error listing GPG keys: %s", e.message);
            }
            
            return keys;
        }
    }
}
