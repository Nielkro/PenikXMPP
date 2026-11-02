using Qlite;
using Qrencode;
using Gee;
using Xmpp;
using Dino.Entities;
using Gtk;
using Omemo;

namespace Dino.Plugins.Omemo {

[CCode (cname = "gtk_menu_button_set_popover", cheader_filename = "gtk/gtk.h")]
private extern static void set_menu_button_popover(MenuButton button, Widget? popover);

internal Adw.ActionRow create_reset_all_sessions_row(Plugin plugin, Account account, Jid jid) {
    var reset_all_row = new Adw.ActionRow();
    reset_all_row.title = _("Reset all sessions");
    reset_all_row.subtitle = _("Delete all encryption sessions. Fresh sessions will be established on the next message.");
    var reset_button = new Gtk.Button.with_label(_("Reset")) { valign = Gtk.Align.CENTER };
    reset_all_row.add_suffix(reset_button);
    reset_all_row.activatable_widget = reset_button;
    AccountKeyScope? scope = null;
    try { scope = new AccountKeyScope(account, plugin.db); }
    catch (Error e) { reset_all_row.sensitive = false; }
    var row_ref = WeakRef(reset_all_row);
    reset_button.clicked.connect(() => {
        Adw.ActionRow? row = row_ref.get() as Adw.ActionRow;
        if (row == null || scope == null || ((!) row).get_root() == null) return;
        try {
            plugin.trust_manager.reset_all_sessions_checked(account, jid, (!) scope);
            ((!) row).subtitle = _("Sessions reset. A fresh key exchange will happen on the next message.");
        } catch (Error e) {
            bool stale = e is DeviceKeyActionError.STALE_KEY;
            var notice = new Adw.AlertDialog(stale ? _("Key changed") : _("Could not update device"),
                stale ? _("The device key has changed. Review the current fingerprint before trying again.")
                      : _("The device settings could not be changed. Please try again."));
            notice.add_response("close", _("Close"));
            Gtk.Root? root = ((!) row).get_root();
            if (root is Gtk.Window) notice.present((Gtk.Window) root);
        }
    });
    return reset_all_row;
}

public class OmemoPreferencesEntry : Plugins.EncryptionPreferencesEntry {

    Plugin plugin;

    public OmemoPreferencesEntry(Plugin plugin) {
        this.plugin = plugin;
    }

    public override Object? get_widget(Account account, WidgetType type) {
        if (type != WidgetType.GTK4) return null;
        var widget  = new OmemoPreferencesWidget(plugin);
        widget.set_jid(account, account.bare_jid);
        return widget;
    }

    public override string id { get { return "omemo_preferences_entryption"; }}
}

[GtkTemplate (ui = "/im/dino/Dino/omemo/encryption_preferences_entry.ui")]
public class OmemoPreferencesWidget : Adw.PreferencesGroup {
    private Plugin plugin;
    private Account account;
    private Jid jid;
    private int identity_id = 0;
    private Store? store = null;
    private Set<uint32> displayed_ids = new HashSet<uint32>();
    private HashMap<int, string> displayed_keys = new HashMap<int, string>();
    private StreamModule? bundle_fetch_module = null;
    private ulong bundle_fetched_handler_id = 0;
    private Adw.AlertDialog? active_label_dialog = null;
    private Gtk.Widget? active_label_row = null;
    private ManageKeyDialog? active_manage_key_dialog = null;
    private Gtk.Widget? active_manage_key_row = null;
    private ulong active_manage_key_response_handler_id = 0;
    private bool destroyed = false;

    [GtkChild] private unowned Adw.SwitchRow automatically_accept_new_row;
    [GtkChild] private unowned Adw.SwitchRow encrypt_by_default_row;
    [GtkChild] private unowned Label new_keys_label;

    [GtkChild] private unowned Adw.PreferencesGroup keys_preferences_group;
    [GtkChild] private unowned Picture qrcode_picture;
    [GtkChild] private unowned Popover qrcode_popover;

    private ArrayList<Widget> keys_preferences_group_children = new ArrayList<Widget>();

    construct {
        // If we set the strings in the .ui file, they don't get translated
        keys_preferences_group.description = _("Each device has its own OMEMO key. Messages can only be decrypted by a device if they are encrypted to its key. Messages are only encrypted to accepted devices.");
        encrypt_by_default_row.title = _("OMEMO by default");
        encrypt_by_default_row.subtitle = _("Enable OMEMO encryption for new conversations");
        automatically_accept_new_row.title = _("Encrypt to new devices");
        automatically_accept_new_row.subtitle = _("Automatically encrypt to new devices from this contact.");
        new_keys_label.label = _("New keys");

        this.map.connect(() => {
            if (identity_id > 0) fetch_unknown_bundles();
        });
        this.notify["root"].connect(() => {
            if (get_root() == null) {
                disconnect_bundle_fetch_handler();
                close_child_dialogs();
            }
        });
        this.destroy.connect(() => {
            destroyed = true;
            disconnect_bundle_fetch_handler();
            close_child_dialogs();
        });
    }

    public OmemoPreferencesWidget(Plugin plugin) {
        this.plugin = plugin;
    }

    public void set_jid(Account account, Jid jid) {
        this.account = account;
        this.jid = jid;
        this.identity_id = plugin.db.identity.get_id(account.id);
        if (identity_id <= 0) {
            warning("OmemoPreferencesWidget missing identity_id");
            return;
        }

        automatically_accept_new_row.active = plugin.db.trust.get_blind_trust(identity_id, jid.bare_jid.to_string(), true);
        automatically_accept_new_row.notify["active"].connect((obj, _) => { on_auto_accept_toggled(((Adw.SwitchRow) obj).active); });

        encrypt_by_default_row.visible = account.bare_jid.equals_bare(jid);
        encrypt_by_default_row.active = plugin.app.settings.get_default_encryption(account) != Encryption.NONE;
        encrypt_by_default_row.notify["active"].connect((obj, _) => { on_omemo_by_default_toggled(((Adw.SwitchRow) obj).active); });

        Dino.Application? app = Application.get_default() as Dino.Application;
        if (app != null) {
            StreamModule? module = app.stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
            if (module != null) store = module.store;
        }

        redraw_key_list();

        // Check for unknown devices
        fetch_unknown_bundles();
    }

    private void redraw_key_list() {
        // Remove current widgets
        foreach (var widget in keys_preferences_group_children) {
            keys_preferences_group.remove(widget);
        }
        keys_preferences_group_children.clear();
        close_detached_child_dialogs();
        displayed_ids.clear();
        displayed_keys.clear();

        // Unparent qrcode_popover so it can be reattached to a new MenuButton
        if (qrcode_popover.get_parent() != null) {
            // The popover is owned by a MenuButton; clear that assignment
            var old_parent = qrcode_popover.get_parent();
            if (old_parent is MenuButton) {
                ((MenuButton) old_parent).popover = null;
            }
        }

        // Dialog opened from the account settings menu
        // Show the fingerprint for this device separately with buttons for a qrcode and to copy
        if(jid.equals(account.bare_jid)) {
            automatically_accept_new_row.subtitle = _("New encryption keys from your other devices will be accepted automatically.");
            add_own_fingerprint();
        }

        //Show the normal devicelist
        var own_id = plugin.db.identity.row_with(plugin.db.identity.account_id, account.id)[plugin.db.identity.device_id];
        int known_count = 0;
        foreach (Row device in plugin.db.identity_meta.get_known_devices(identity_id, jid.to_string())) {
            if(jid.equals(account.bare_jid) && device[plugin.db.identity_meta.device_id] == own_id) {
                // If this is our own account, don't show this device twice (did it separately already)
                continue;
            }
            add_fingerprint(device, (TrustLevel) device[plugin.db.identity_meta.trust_level]);
            known_count++;
        }

        // "Reset all sessions" row — only show for contacts (not own account) with known devices
        if (!jid.equals(account.bare_jid) && known_count > 0) {
            var reset_all_row = create_reset_all_sessions_row(plugin, account, jid);
            keys_preferences_group.add(reset_all_row);
            keys_preferences_group_children.add(reset_all_row);
        }

        //Show any new devices for which the user must decide whether to accept or reject
        foreach (Row device in plugin.db.identity_meta.get_new_devices(identity_id, jid.to_string())) {
            add_new_fingerprint(device);
        }
    }

    private static string escape_for_iri_path_segment(string s) {
        // from RFC 3986, 2.2. Reserved Characters:
        string SUB_DELIMS = "!$&'()*+,;=";
        // from RFC 3986, 3.3. Path (pchar without unreserved and pct-encoded):
        string ALLOWED_RESERVED_CHARS = SUB_DELIMS + ":@";
        return GLib.Uri.escape_string(s, ALLOWED_RESERVED_CHARS, true);
    }

    private void fetch_unknown_bundles() {
        if (destroyed) return;
        Dino.Application app = Application.get_default() as Dino.Application;
        XmppStream? stream = app.stream_interactor.get_stream(account);
        if (stream == null) return;
        StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
        if (module == null) return;
        if (bundle_fetch_module != module || bundle_fetched_handler_id == 0) {
            disconnect_bundle_fetch_handler();
            bundle_fetch_module = module;
            bundle_fetched_handler_id = module.bundle_fetched.connect_after((bundle_jid, device_id, bundle) => {
                if (destroyed || get_root() == null) return;
                if (bundle_jid.equals_bare(jid)) {
                    Row? latest = plugin.db.identity_meta.get_device(identity_id, jid.bare_jid.to_string(), device_id);
                    string? current_key = latest != null ? ((!) latest)[plugin.db.identity_meta.identity_key_public_base64] : null;
                    if (!displayed_ids.contains(device_id) || displayed_keys[device_id] != current_key) {
                        redraw_key_list();
                    }
                }
            });
        }
        foreach (Row device in plugin.db.identity_meta.get_unknown_devices(identity_id, jid.to_string())) {
            try {
                module.fetch_bundle_info(stream, new Jid(device[plugin.db.identity_meta.address_name]), device[plugin.db.identity_meta.device_id], false);
            } catch (InvalidJidError e) {
                warning("Ignoring device with invalid Jid: %s", e.message);
            }
        }
    }

    private void disconnect_bundle_fetch_handler() {
        if (bundle_fetch_module != null && bundle_fetched_handler_id != 0) {
            StreamModule module = (!) bundle_fetch_module;
            if (SignalHandler.is_connected(module, bundle_fetched_handler_id)) {
                module.disconnect(bundle_fetched_handler_id);
            }
        }
        bundle_fetch_module = null;
        bundle_fetched_handler_id = 0;
    }

    private void close_child_dialogs() {
        if (active_label_dialog != null) {
            ((!) active_label_dialog).force_close();
            active_label_dialog = null;
        }
        active_label_row = null;
        if (active_manage_key_dialog != null) {
            ManageKeyDialog dialog = (!) active_manage_key_dialog;
            if (active_manage_key_response_handler_id != 0 &&
                    SignalHandler.is_connected(dialog, active_manage_key_response_handler_id)) {
                dialog.disconnect(active_manage_key_response_handler_id);
            }
            active_manage_key_response_handler_id = 0;
            active_manage_key_dialog = null;
            active_manage_key_row = null;
            dialog.close();
        }
    }

    private void close_detached_child_dialogs() {
        bool label_row_detached = active_label_row != null && ((!) active_label_row).get_root() == null;
        bool manage_row_detached = active_manage_key_row != null && ((!) active_manage_key_row).get_root() == null;
        if (label_row_detached || manage_row_detached) {
            close_child_dialogs();
        }
    }

    private bool can_mutate_settings() {
        return !destroyed && get_root() != null && identity_id > 0;
    }

    private void add_own_fingerprint() {
        string own_b64 = plugin.db.identity.row_with(plugin.db.identity.account_id, account.id)[plugin.db.identity.identity_key_public_base64];
        string fingerprint = fingerprint_from_base64(own_b64);
        int sid = plugin.db.identity.row_with(plugin.db.identity.account_id, account.id)[plugin.db.identity.device_id];

        // Try to get own device label from identity_meta
        Row? own_meta = plugin.db.identity_meta.get_device(identity_id, account.bare_jid.to_string(), sid);
        string? own_label = null;
        if (own_meta != null) {
            own_label = own_meta[plugin.db.identity_meta.device_label];
        }
        string title_text;
        if (own_label != null && own_label.length > 0) {
            title_text = @"$(own_label) #$(sid) (" + _("This device") + ")";
        } else {
            title_text = _("This device") + @" #$(sid)";
        }

        Adw.ActionRow action_row = new Adw.ActionRow() { use_markup = true };

        var own_action_box = new Box(Orientation.HORIZONTAL, 6);
        var edit_label_button = new Button() { icon_name="document-edit-symbolic", valign=Align.CENTER, tooltip_text=_("Set device name") };
        edit_label_button.clicked.connect(() => {
            show_label_dialog(action_row, sid, own_label);
        });
        own_action_box.append(edit_label_button);
        var show_qrcode_button = new MenuButton() { icon_name="dino-qr-code-symbolic", valign=Align.CENTER };
        own_action_box.append(show_qrcode_button);
        var copy_button = new Button() { icon_name="edit-copy-symbolic", valign=Align.CENTER };
        copy_button.clicked.connect(() => { copy_button.get_clipboard().set_text(fingerprint); });
        own_action_box.append(copy_button);

        action_row.title = Markup.escape_text(title_text);
        action_row.subtitle = fingerprint_markup(fingerprint_from_base64(own_b64));
        action_row.add_suffix(own_action_box);
        add_key_row(action_row);

        // Create and set QR code popover
        var iri_query = @"omemo-sid-$(sid)=$(fingerprint)";
#if GLIB_2_66 && VALA_0_50
        string iri = GLib.Uri.join(UriFlags.NONE, "xmpp", null, null, 0, jid.to_string(), iri_query, null);
#else
        var iri_path_seg = escape_for_iri_path_segment(jid.to_string());
        var iri = @"xmpp:$(iri_path_seg)?$(iri_query)";
#endif

        const int QUIET_ZONE_MODULES = 4;  // MUST be at least 4
        const int MODULE_SIZE_PX = 4;  // arbitrary
        var qr_paintable = new QRcode(iri, 2)
            .to_paintable(MODULE_SIZE_PX * qrcode_picture.scale_factor);
        qrcode_picture.paintable = qr_paintable;
        qrcode_picture.margin_top = qrcode_picture.margin_end =
                qrcode_picture.margin_bottom = qrcode_picture.margin_start = QUIET_ZONE_MODULES * MODULE_SIZE_PX;
        qrcode_popover.add_css_class("qrcode-container");

        // Use set_popover() instead of property assignment to avoid
        // -Wincompatible-pointer-types (C setter takes GtkWidget*, not GtkPopover*)
        set_menu_button_popover(show_qrcode_button, qrcode_popover);
    }

    private void show_label_dialog(Adw.ActionRow action_row, int32 sid, string? current_label) {
        close_child_dialogs();

        var dialog = new Adw.AlertDialog(_("Device Name"), _("Set a name for this device that other contacts can see."));
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("save", _("Save"));
        dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "save";
        dialog.close_response = "cancel";

        var entry = new Gtk.Entry() { text = current_label ?? "", placeholder_text = "DinoX", max_length = 50 };
        entry.activate.connect(() => { dialog.response("save"); });
        var clamp = new Adw.Clamp() { maximum_size = 400, child = entry };
        dialog.extra_child = clamp;

        int dialog_account_id = account.id;
        string dialog_jid = jid.bare_jid.to_string();
        active_label_dialog = dialog;
        active_label_row = action_row;
        dialog.response.connect((response) => {
            if (active_label_dialog != dialog) return;
            if (!can_mutate_settings()) return;
            if (dialog_account_id != account.id || dialog_jid != jid.bare_jid.to_string()) return;
            if (action_row.get_root() == null) return;
            if (response == "save") {
                string new_label = entry.text.strip();
                // Save and publish via Manager
                Manager? manager = plugin.app.stream_interactor.get_module<Manager>(Manager.IDENTITY);
                if (manager != null) {
                    manager.set_own_device_label(account, new_label);
                }
                // Update title
                string title_text;
                if (new_label.length > 0) {
                    title_text = @"$(new_label) #$(sid) (" + _("This device") + ")";
                } else {
                    title_text = _("This device") + @" #$(sid)";
                }
                action_row.title = Markup.escape_text(title_text);
            }
        });
        dialog.closed.connect(() => {
            if (active_label_dialog == dialog) {
                active_label_dialog = null;
            }
        });
        var root = get_root();
        if (!(root is Gtk.Window)) return;
        dialog.present((Gtk.Window) root);
    }

    private void add_fingerprint(Row device, TrustLevel trust) {
        string key_base64 = device[plugin.db.identity_meta.identity_key_public_base64];
        if (store != null) {
            try {
                Address address = new Address(jid.to_string(), device[plugin.db.identity_meta.device_id]);
                SessionRecord? session = null;
                if (store.contains_session(address)) {
                    session = store.load_session(address);
                    string session_key_base64 = Base64.encode(session.state.remote_identity_key.serialize());
                    if (key_base64 != session_key_base64) {
                        critical("Session and database identity key mismatch!");
                        key_base64 = session_key_base64;
                    }
                }
            } catch (Error e) {
                warning("Error while reading session store: %s", e.message);
            }
        }

        {
            bool is_active = device[plugin.db.identity_meta.now_active];
            int32 dev_id = device[plugin.db.identity_meta.device_id];
            long last_active_ts = device[plugin.db.identity_meta.last_active];
            string? device_label = device[plugin.db.identity_meta.device_label];

            Adw.ActionRow action_row = new Adw.ActionRow() { use_markup = true };
            var manage_button = new Button.with_label(_("Manage Key")) { valign = Align.CENTER };
            manage_button.clicked.connect(() => {
                if (destroyed || get_root() == null) return;
                int row_identity_id = device[plugin.db.identity_meta.identity_id];
                string row_address_name = device[plugin.db.identity_meta.address_name];
                int32 row_device_id = device[plugin.db.identity_meta.device_id];
                Row? updated_device = plugin.db.identity_meta.get_device(row_identity_id, row_address_name, row_device_id);
                if (updated_device == null) return;
                var root = get_root();
                if (!(root is Gtk.Window)) return;
                close_child_dialogs();
                ManageKeyDialog manage_dialog = new ManageKeyDialog(account, updated_device, plugin.db);
                active_manage_key_dialog = manage_dialog;
                active_manage_key_row = action_row;
                manage_dialog.set_transient_for((Gtk.Window) root);
                manage_dialog.present();
                var dialog_ref = WeakRef(manage_dialog);
                active_manage_key_response_handler_id = manage_dialog.response.connect((response) => {
                    ManageKeyDialog? dialog = dialog_ref.get() as ManageKeyDialog;
                    if (dialog == null || active_manage_key_dialog != dialog) return;
                    if (destroyed || get_root() == null) return;
                    if (action_row.get_root() == null) return;
                    update_stored_trust(response, ((!) dialog).key_target);
                    redraw_key_list();
                });
                manage_dialog.close_request.connect(() => {
                    ManageKeyDialog? dialog = dialog_ref.get() as ManageKeyDialog;
                    if (dialog != null && active_manage_key_dialog == dialog) {
                        if (active_manage_key_response_handler_id != 0 &&
                                SignalHandler.is_connected((!) dialog, active_manage_key_response_handler_id)) {
                            ((!) dialog).disconnect(active_manage_key_response_handler_id);
                        }
                        active_manage_key_dialog = null;
                        active_manage_key_row = null;
                        active_manage_key_response_handler_id = 0;
                    }
                    return false;
                });
            });
            action_row.activatable_widget = manage_button;

            // Build title with device label or ID
            string title_base;
            if (device_label != null && device_label.length > 0) {
                title_base = device_label;
            } else if (account.bare_jid.equals_bare(jid)) {
                title_base = _("Other device");
            } else {
                title_base = _("Device");
            }
            // Always append device ID for identification
            string title_text = @"$(title_base) #$(dev_id)";
            if (!is_active) {
                title_text += " (" + _("inactive") + ")";
            }
            action_row.title = Markup.escape_text(title_text);

            // Build subtitle: fingerprint + last active info
            string fp_markup = fingerprint_markup(fingerprint_from_base64(key_base64));
            string last_active_info = "";
            if (last_active_ts > 0) {
                var last_dt = new DateTime.from_unix_utc(last_active_ts);
                var now = new DateTime.now_utc();
                var diff = now.difference(last_dt);
                int days_ago = (int)(diff / TimeSpan.DAY);
                if (days_ago == 0) {
                    last_active_info = _("today");
                } else if (days_ago == 1) {
                    last_active_info = _("yesterday");
                } else if (days_ago < 30) {
                    last_active_info = _("%d days ago").printf(days_ago);
                } else if (days_ago < 365) {
                    int months = days_ago / 30;
                    last_active_info = dngettext(GETTEXT_PACKAGE, "%d month ago", "%d months ago", months).printf(months);
                } else {
                    int years = days_ago / 365;
                    last_active_info = dngettext(GETTEXT_PACKAGE, "%d year ago", "%d years ago", years).printf(years);
                }
                last_active_info = _("Last seen") + ": " + last_active_info;
            } else {
                last_active_info = _("Last seen") + ": " + _("unknown");
            }
            action_row.subtitle = fp_markup + "\n<small>" + Markup.escape_text(last_active_info) + "</small>";

            // Trust and locally observed activity in suffix
            string trust_str = _("Accepted");
            switch(trust) {
                case TrustLevel.UNTRUSTED:
                    trust_str = _("Rejected");
                    break;
                case TrustLevel.VERIFIED:
                    trust_str = _("Verified");
                    break;
                case TrustLevel.TRUSTED:
                default:
                    break;
            }

            // Local observation only: the device can still be in use even if
            // this DinoX has not recorded activity from it for over 60 days.
            bool not_seen_recently = is_active && last_active_ts > 0;
            if (not_seen_recently) {
                var last_dt = new DateTime.from_unix_utc(last_active_ts);
                var now = new DateTime.now_utc();
                var diff = now.difference(last_dt);
                not_seen_recently = (diff / TimeSpan.DAY) > 60;
            }

            var suffix_box = new Box(Orientation.VERTICAL, 2) { valign = Align.CENTER };
            var trust_label = new Label(trust_str);
            suffix_box.append(trust_label);

            if (!is_active) {
                var inactive_label = new Label(_("Inactive"));
                inactive_label.add_css_class("dim-label");
                suffix_box.append(inactive_label);
            } else if (not_seen_recently) {
                var activity_label = new Label(_("Not seen recently"));
                activity_label.add_css_class("dim-label");
                activity_label.tooltip_text = _("This DinoX has not observed any activity from this device for over 60 days. The device may still be in use.");
                suffix_box.append(activity_label);
            }

            suffix_box.append(manage_button);
            action_row.add_suffix(suffix_box);
            add_key_row(action_row);
        }
        displayed_ids.add(device[plugin.db.identity_meta.device_id]);
        displayed_keys[device[plugin.db.identity_meta.device_id]] = device[plugin.db.identity_meta.identity_key_public_base64] ?? "";
    }

    private bool on_auto_accept_toggled(bool active) {
        if (!can_mutate_settings()) return false;
        plugin.trust_manager.set_blind_trust(account, jid, active);

        if (active) {
            int identity_id = plugin.db.identity.get_id(account.id);
            if (identity_id < 0) return false;

            foreach (Row device in plugin.db.identity_meta.get_new_devices(identity_id, jid.to_string())) {
                var target = new DeviceKeyTarget(account, device, plugin.db);
                if (!apply_displayed_device_action(plugin, account, jid, target,
                        TrustLevel.TRUSTED, this)) break;
                add_fingerprint(device, TrustLevel.TRUSTED);
            }
        }
        return false;
    }

    private bool on_omemo_by_default_toggled(bool active) {
        if (!can_mutate_settings()) return false;
        var encryption_value = active ? Encryption.OMEMO : Encryption.NONE;
        plugin.app.settings.set_default_encryption(account, encryption_value);
        return false;
    }

    private void update_stored_trust(int response, DeviceKeyTarget target) {
        if (!can_mutate_settings()) return;
        if (!apply_displayed_device_action(plugin, account, jid, target, response, this)) return;
        if (response == TrustLevel.VERIFIED) {
            plugin.trust_manager.set_blind_trust(account, jid, false);
            automatically_accept_new_row.active = false;
        }
    }

    private void add_new_fingerprint(Row device) {
        int32 dev_id = device[plugin.db.identity_meta.device_id];
        string? device_label = device[plugin.db.identity_meta.device_label];
        bool key_changed = device[plugin.db.identity_meta.identity_key_changed];
        string title_text;
        if (key_changed) {
            title_text = _("Encryption key changed") + @" #$(dev_id)";
        } else if (device_label != null && device_label.length > 0) {
            title_text = @"$(device_label) #$(dev_id)";
        } else {
            title_text = _("New device") + @" #$(dev_id)";
        }

        Adw.ActionRow action_row = new Adw.ActionRow() { use_markup = true };
        action_row.title = Markup.escape_text(title_text);
        string fingerprint = fingerprint_markup(fingerprint_from_base64(device[plugin.db.identity_meta.identity_key_public_base64]));
        action_row.subtitle = key_changed
            ? _("This device has a new encryption key, for example after a reinstall. DinoX will use it only after your review.") + "\n" + fingerprint
            : fingerprint;

        var displayed_target = new DeviceKeyTarget(account, device, plugin.db);

        Button accept_button = new Button() { visible = true, valign = Align.CENTER, hexpand = true };
        accept_button.set_icon_name("check-plain-symbolic"); // using .image = sets .image-button. Together with .suggested/destructive action that breaks the button Adwaita
        accept_button.add_css_class("suggested-action");
        accept_button.tooltip_text = _("Accept key");

        Button reject_button = new Button() { visible = true, valign = Align.CENTER, hexpand = true };
        reject_button.set_icon_name("action-unavailable-symbolic");
        reject_button.add_css_class("destructive-action");
        reject_button.tooltip_text = _("Reject key");

        accept_button.clicked.connect(() => {
            if (!can_mutate_settings() || action_row.get_root() == null) return;
            apply_displayed_device_action(plugin, account, jid, displayed_target, TrustLevel.TRUSTED, this);
            redraw_key_list();
        });

        reject_button.clicked.connect(() => {
            if (!can_mutate_settings() || action_row.get_root() == null) return;
            apply_displayed_device_action(plugin, account, jid, displayed_target, TrustLevel.UNTRUSTED, this);
            redraw_key_list();
        });

        Box control_box = new Box(Gtk.Orientation.HORIZONTAL, 0) { visible = true, hexpand = true };
        control_box.append(accept_button);
        control_box.append(reject_button);
        control_box.add_css_class("linked"); // .linked: Visually link the accept / reject buttons

        action_row.add_suffix(control_box);

        add_key_row(action_row);
        displayed_ids.add(device[plugin.db.identity_meta.device_id]);
        displayed_keys[device[plugin.db.identity_meta.device_id]] = device[plugin.db.identity_meta.identity_key_public_base64] ?? "";
    }

    private void add_key_row(Adw.PreferencesRow widget) {
        keys_preferences_group.add(widget);
        keys_preferences_group_children.add(widget);
    }

}
}
