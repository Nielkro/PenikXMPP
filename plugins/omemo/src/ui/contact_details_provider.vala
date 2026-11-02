using Gtk;
using Gee;
using Qlite;
using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.Omemo {

internal static string contact_details_trust_icon_name(TrustLevel trust_level) {
    switch (trust_level) {
        case TrustLevel.VERIFIED:
            return "dino-security-high-symbolic";
        case TrustLevel.TRUSTED:
            return "check-plain-symbolic";
        case TrustLevel.UNTRUSTED:
            return "dialog-warning-symbolic";
        default:
            return "dialog-question-symbolic";
    }
}

private class MucKeyViewState : Object {
    internal bool detached = false;
    internal Gee.ArrayList<Adw.ExpanderRow> rows = new Gee.ArrayList<Adw.ExpanderRow>();
    internal Gee.ArrayList<Gtk.Window> dialogs = new Gee.ArrayList<Gtk.Window>();
}

public class ContactDetailsProvider : Plugins.ContactDetailsProvider, Object {
    public string id { get { return "omemo_info"; } }
    public string tab { get { return "encryption"; } }

    private Plugin plugin;

    public ContactDetailsProvider(Plugin plugin) {
        this.plugin = plugin;
    }

    public void populate(Conversation conversation, Plugins.ContactDetails contact_details, WidgetType type) { }

    public Object? get_widget(Conversation conversation) {
        if (conversation.type_ == Conversation.Type.CHAT) {
            // 1:1 Chat - show OMEMO widget for the counterpart
            var widget = new OmemoPreferencesWidget(plugin);
            widget.set_jid(conversation.account, conversation.counterpart);
            return widget;
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            if (!(GLib.Application.get_default() is Dino.Application)) return null;
            // The About page must not construct every member/device row of a
            // hidden Encryption page. Populate on its first actual display;
            // key actions and their account/identity checks stay unchanged.
            var group = new Adw.PreferencesGroup() {
                title = _("OMEMO Encryption"),
                description = _("Encryption keys for room members")
            };
            WeakRef group_ref = WeakRef(group);
            ulong map_id = 0;
            map_id = group.map.connect(() => {
                var current_group = group_ref.get() as Adw.PreferencesGroup;
                if (current_group == null) return;
                SignalHandler.disconnect(current_group, map_id);
                create_muc_omemo_widget(conversation, current_group);
            });
            return group;
        }
        return null;
    }
    
    private Adw.PreferencesGroup? create_muc_omemo_widget(Conversation conversation, Adw.PreferencesGroup? existing = null) {
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null) return null;
        
        var muc_manager = app.stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        
        var main_group = existing ?? new Adw.PreferencesGroup();
        MucKeyViewState? previous = main_group.get_data<MucKeyViewState>("dinox-omemo-muc-key-view");
        MucKeyViewState state;
        if (previous != null) {
            state = (!) previous;
            close_manage_key_dialogs(state.dialogs);
            foreach (Adw.ExpanderRow old in state.rows) main_group.remove(old);
            state.rows.clear();
        } else {
            state = new MucKeyViewState();
            main_group.set_data<MucKeyViewState>("dinox-omemo-muc-key-view", state);
            main_group.notify["root"].connect((obj, pspec) => {
                var widget = obj as Gtk.Widget;
                if (widget != null && widget.get_root() == null) {
                    state.detached = true;
                    close_manage_key_dialogs(state.dialogs);
                    state.rows.clear();
                }
            });
            main_group.destroy.connect(() => {
                state.detached = true;
                close_manage_key_dialogs(state.dialogs);
                state.rows.clear();
            });
        }
        main_group.title = _("OMEMO Encryption");
        main_group.description = _("Encryption keys for room members");
        // This list is presentation only; send authorization uses the live
        // member/admin/owner snapshot in MucManager.
        Gee.List<Jid>? members = muc_manager.get_offline_members(conversation.counterpart, conversation.account);
        if (members == null || members.size == 0) {
            main_group.description = _("No member JIDs available. This may be an anonymous room.");
            return main_group;
        }

        int identity_id = plugin.db.identity.get_id(conversation.account.id);
        if (identity_id <= 0) return main_group;
        
        // Show room members only; own devices are managed in the account OMEMO settings.
        var sorted_members = new Gee.ArrayList<Jid>();
        foreach (Jid member_jid in members) {
            if (member_jid.equals_bare(conversation.account.bare_jid)) {
                continue;
            }
            sorted_members.add(member_jid);
        }
        
        foreach (Jid member_jid in sorted_members) {
            // Local copy for closures — Vala foreach vars are re-bound each iteration
            Jid the_jid = member_jid;
            bool is_own = the_jid.equals_bare(conversation.account.bare_jid);
            
            var known_devices = new Gee.ArrayList<Row>();
            int hidden_count = 0;
            foreach (Row device in plugin.db.identity_meta.get_known_devices(identity_id, the_jid.bare_jid.to_string())) {
                long last_ts = device[plugin.db.identity_meta.last_active];
                if (last_ts > 0) {
                    known_devices.add(device);
                } else {
                    hidden_count++;
                }
            }
            // Sort known devices by last_active descending (most recent first)
            known_devices.sort((a, b) => {
                long a_ts = a[plugin.db.identity_meta.last_active];
                long b_ts = b[plugin.db.identity_meta.last_active];
                if (a_ts > b_ts) return -1;
                if (a_ts < b_ts) return 1;
                return 0;
            });
            
            var new_devices = new Gee.ArrayList<Row>();
            foreach (Row device in plugin.db.identity_meta.get_new_devices(identity_id, the_jid.bare_jid.to_string())) {
                new_devices.add(device);
            }
            
            int total = known_devices.size + new_devices.size;
            if (total == 0 && hidden_count == 0) continue;
            
            // Expander row per member
            var expander = new Adw.ExpanderRow();
            expander.title = is_own ? _("Your devices") : the_jid.bare_jid.to_string();
            if (hidden_count > 0 && total > 0) {
                expander.subtitle = dngettext(GETTEXT_PACKAGE, "%d device", "%d devices", total).printf(total) + _(" (+%d inactive)").printf(hidden_count);
            } else if (hidden_count > 0) {
                expander.subtitle = _("%d inactive devices").printf(hidden_count);
            } else {
                expander.subtitle = dngettext(GETTEXT_PACKAGE, "%d device", "%d devices", total).printf(total);
            }
            
            // Auto-accept toggle per member
            var auto_accept_row = new Adw.SwitchRow();
            auto_accept_row.title = _("Encrypt to new devices");
            auto_accept_row.subtitle = is_own
                ? _("Automatically accept new keys from your other devices.")
                : _("Automatically accept new keys from this contact.");
            auto_accept_row.active = plugin.db.trust.get_blind_trust(identity_id, the_jid.bare_jid.to_string(), true);
            auto_accept_row.notify["active"].connect(() => {
                if (state.detached || !muc_widget_can_update(main_group, auto_accept_row)) return;
                plugin.trust_manager.set_blind_trust(conversation.account, the_jid, auto_accept_row.active);
            });
            expander.add_row(auto_accept_row);
            
            // "Reset all sessions" action row — useful when messages fail
            if (!is_own && (known_devices.size > 0 || hidden_count > 0)) {
                var reset_all_row = create_reset_all_sessions_row(plugin, conversation.account, the_jid);
                expander.add_row(reset_all_row);
            }
            
            // Known devices — clickable for trust management
            foreach (Row device in known_devices) {
                string? key_base64 = device[plugin.db.identity_meta.identity_key_public_base64];
                if (key_base64 == null) continue;
                
                string fingerprint = fingerprint_from_base64(key_base64);
                TrustLevel trust_level = (TrustLevel) device[plugin.db.identity_meta.trust_level];
                int32 dev_id = device[plugin.db.identity_meta.device_id];
                string? device_label = device[plugin.db.identity_meta.device_label];
                
                string title_text;
                if (device_label != null && device_label.length > 0) {
                    title_text = @"$(device_label) #$(dev_id)";
                } else {
                    title_text = is_own ? _("Your device") + @" #$(dev_id)" : _("Device") + @" #$(dev_id)";
                }
                
                var device_row = new Adw.ActionRow() { use_markup = true };
                device_row.title = Markup.escape_text(title_text);
                
                // Build subtitle: fingerprint + trust + last seen
                long last_active_ts = device[plugin.db.identity_meta.last_active];
                string last_seen = "";
                if (last_active_ts > 0) {
                    var last_dt = new DateTime.from_unix_utc(last_active_ts);
                    var now = new DateTime.now_utc();
                    var diff = now.difference(last_dt);
                    int days_ago = (int)(diff / TimeSpan.DAY);
                    if (days_ago == 0) {
                        last_seen = _("today");
                    } else if (days_ago == 1) {
                        last_seen = _("yesterday");
                    } else if (days_ago < 30) {
                        last_seen = _("%d days ago").printf(days_ago);
                    } else if (days_ago < 365) {
                        int months = days_ago / 30;
                        last_seen = dngettext(GETTEXT_PACKAGE, "%d month ago", "%d months ago", months).printf(months);
                    } else {
                        int years = days_ago / 365;
                        last_seen = dngettext(GETTEXT_PACKAGE, "%d year ago", "%d years ago", years).printf(years);
                    }
                    last_seen = " · " + _("Last seen") + ": " + last_seen;
                }
                device_row.subtitle = fingerprint_markup(fingerprint) + "\n" + trust_level_to_string(trust_level) + last_seen;
                var manage_button = new Gtk.Button.with_label(_("Manage Key")) { valign = Gtk.Align.CENTER };
                device_row.activatable_widget = manage_button;
                
                // Click opens ManageKeyDialog for trust management
                manage_button.clicked.connect(() => {
                    if (state.detached || !muc_widget_can_update(main_group, device_row)) return;
                    Row? updated = plugin.db.identity_meta.get_device(identity_id, the_jid.bare_jid.to_string(), dev_id);
                    if (updated == null) return;
                    var root = main_group.get_root();
                    if (!(root is Gtk.Window)) return;
                    var manage_dialog = new ManageKeyDialog(conversation.account, updated, plugin.db);
                    state.dialogs.add(manage_dialog);
                    manage_dialog.set_transient_for((Gtk.Window) root);
                    manage_dialog.present();
                    var dialog_ref = WeakRef(manage_dialog);
                    manage_dialog.response.connect((resp) => {
                        ManageKeyDialog? dialog = dialog_ref.get() as ManageKeyDialog;
                        if (dialog == null) return;
                        if (state.detached || !muc_widget_can_update(main_group, device_row)) return;
                        bool applied = apply_displayed_device_action(plugin,
                            conversation.account, the_jid, ((!) dialog).key_target, resp, main_group);
                        if (applied && resp == TrustLevel.VERIFIED) {
                            plugin.trust_manager.set_blind_trust(conversation.account, the_jid, false);
                        }
                        create_muc_omemo_widget(conversation, main_group);
                    });
                    manage_dialog.close_request.connect(() => {
                        ManageKeyDialog? dialog = dialog_ref.get() as ManageKeyDialog;
                        if (dialog != null) state.dialogs.remove((!) dialog);
                        return false;
                    });
                });
                
                // Trust indicator icon
                var trust_icon = new Gtk.Image() {
                    icon_name = contact_details_trust_icon_name(trust_level)
                };
                switch (trust_level) {
                    case TrustLevel.VERIFIED:
                        trust_icon.add_css_class("success");
                        break;
                    case TrustLevel.TRUSTED:
                        break;
                    case TrustLevel.UNTRUSTED:
                        trust_icon.add_css_class("warning");
                        break;
                    default:
                        break;
                }
                device_row.add_suffix(trust_icon);
                device_row.add_suffix(manage_button);
                
                expander.add_row(device_row);
            }
            
            // New/pending devices — with accept/reject buttons
            foreach (Row device in new_devices) {
                string? key_base64 = device[plugin.db.identity_meta.identity_key_public_base64];
                if (key_base64 == null) continue;
                
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
                
                var device_row = new Adw.ActionRow() { use_markup = true };
                device_row.title = Markup.escape_text(title_text);
                string fingerprint = fingerprint_markup(fingerprint_from_base64(key_base64));
                device_row.subtitle = key_changed
                    ? _("This device has a new encryption key, for example after a reinstall. DinoX will use it only after your review.") + "\n" + fingerprint
                    : fingerprint;
                
                var accept_btn = new Gtk.Button.from_icon_name("check-plain-symbolic");
                accept_btn.add_css_class("suggested-action");
                accept_btn.valign = Gtk.Align.CENTER;
                accept_btn.tooltip_text = _("Accept key");
                
                var reject_btn = new Gtk.Button.from_icon_name("action-unavailable-symbolic");
                reject_btn.add_css_class("destructive-action");
                reject_btn.valign = Gtk.Align.CENTER;
                reject_btn.tooltip_text = _("Reject key");
                
                var displayed_target = new DeviceKeyTarget(conversation.account, device, plugin.db);

                accept_btn.clicked.connect(() => {
                    if (state.detached || !muc_widget_can_update(main_group, device_row)) return;
                    apply_displayed_device_action(plugin, conversation.account, the_jid,
                        displayed_target, TrustLevel.TRUSTED, main_group);
                    create_muc_omemo_widget(conversation, main_group);
                });
                reject_btn.clicked.connect(() => {
                    if (state.detached || !muc_widget_can_update(main_group, device_row)) return;
                    apply_displayed_device_action(plugin, conversation.account, the_jid,
                        displayed_target, TrustLevel.UNTRUSTED, main_group);
                    create_muc_omemo_widget(conversation, main_group);
                });
                
                var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                btn_box.add_css_class("linked");
                btn_box.append(accept_btn);
                btn_box.append(reject_btn);
                device_row.add_suffix(btn_box);
                
                expander.add_row(device_row);
            }
            
            main_group.add(expander);
            state.rows.add(expander);
        }
        
        return main_group;
    }

    private bool muc_widget_can_update(Adw.PreferencesGroup main_group, Gtk.Widget row) {
        return main_group.get_root() != null && row.get_root() != null;
    }

    private void close_manage_key_dialogs(Gee.List<Gtk.Window> dialogs) {
        var dialogs_to_close = new Gee.ArrayList<Gtk.Window>();
        dialogs_to_close.add_all(dialogs);
        dialogs.clear();
        foreach (Gtk.Window dialog in dialogs_to_close) {
            dialog.close();
        }
    }
    
    
    private string trust_level_to_string(TrustLevel level) {
        switch (level) {
            case TrustLevel.VERIFIED:
                return _("Verified");
            case TrustLevel.TRUSTED:
                return _("Trusted");
            case TrustLevel.UNTRUSTED:
                return _("Untrusted");
            default:
                return _("Unknown");
        }
    }
}

}
