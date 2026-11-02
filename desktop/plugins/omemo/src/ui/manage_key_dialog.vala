using Gtk;
using Qlite;

namespace Dino.Plugins.Omemo {

internal static bool apply_displayed_device_action(Plugin plugin, Dino.Entities.Account account,
        Xmpp.Jid jid, DeviceKeyTarget target, int action, Gtk.Widget parent) {
    try {
        plugin.trust_manager.perform_key_action(account, jid, target, action);
        if ((action == TrustLevel.TRUSTED || action == TrustLevel.VERIFIED) &&
                parent.get_data<Object>("dinox-omemo-legacy-hidden-notice") == null) {
            try {
                if (plugin.trust_manager.has_unassigned_hidden_messages(account, jid, target.device_id)) {
                    Gtk.Root? root = parent.get_root();
                    if (root is Gtk.Window) {
                        parent.set_data<Object>("dinox-omemo-legacy-hidden-notice", new Object());
                        var notice = new Adw.AlertDialog(_("OMEMO Encryption"),
                            _("Older hidden messages have no recorded fingerprint and cannot be safely assigned to this key."));
                        notice.add_response("close", _("Close"));
                        notice.present((Gtk.Window) root);
                    }
                }
            } catch (Error query_error) {
                warning("OMEMO: Could not check old hidden-message provenance: %s", query_error.message);
            }
        }
        return true;
    } catch (Error e) {
        bool stale = e is DeviceKeyActionError.STALE_KEY;
        warning("OMEMO device action was not applied for account %d: %s", account.id, e.message);
        Gtk.Root? root = parent.get_root();
        if (root is Gtk.Window) {
            var notice = new Adw.AlertDialog(stale ? _("Key changed") : _("Could not update device"),
                stale ? _("The device key has changed. Review the current fingerprint before trying again.")
                      : _("The device settings could not be changed. Please try again."));
            notice.add_response("close", _("Close"));
            notice.present((Gtk.Window) root);
        }
        return false;
    }
}

[GtkTemplate (ui = "/im/dino/Dino/omemo/manage_key_dialog.ui")]
public class ManageKeyDialog : Gtk.Window {

    public signal void response(int response_id);

    [GtkChild] private unowned Stack manage_stack;

    [GtkChild] private unowned Button cancel_button;
    [GtkChild] private unowned Button ok_button;

    [GtkChild] private unowned Label main_desc_label;
    [GtkChild] private unowned ListBox main_action_list;

    [GtkChild] private unowned Image confirm_image;
    [GtkChild] private unowned Label confirm_title_label;
    [GtkChild] private unowned Label confirm_desc_label;

    [GtkChild] private unowned Label verify_label;
    [GtkChild] private unowned Label compare_fingerprint_label;
    [GtkChild] private unowned Button verify_yes_button;
    [GtkChild] private unowned Button verify_no_button;

    public DeviceKeyTarget key_target { get; private set; }

    private Row device;
    private Database db;

    private bool return_to_main;
    private int current_response;

    construct {
        // If we set the strings in the .ui file, they don't get translated
        this.title = _("Manage Key");
        compare_fingerprint_label.label = _("Compare the fingerprint, character by character, with the one shown on your contact's device.");
        verify_no_button.label = _("Fingerprints differ");
        verify_yes_button.label = _("Fingerprints match");
        foreach (Button button in new Button[] { verify_no_button, verify_yes_button }) {
            var label = button.get_child() as Label;
            if (label != null) {
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            }
        }
        cancel_button.label = _("Cancel");
        ok_button.label = _("Confirm");
    }

    public ManageKeyDialog(Dino.Entities.Account account, Row device, Database db) {
        this.device = device;
        this.db = db;
        key_target = new DeviceKeyTarget(account, device, db);
        var context = new Gtk.Label(_("Account: %s\nContact: %s\nDevice: %s").printf(
            account.bare_jid.to_string(), key_target.address_name,
            "#" + key_target.device_id.to_string())) {
                xalign = 0, selectable = true, wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR,
                max_width_chars = 45, margin_start = 16, margin_end = 16,
                margin_top = 12, margin_bottom = 12
            };
        context.add_css_class("dim-label");
        var content = (Gtk.Box) get_child();
        content.orientation = Gtk.Orientation.VERTICAL;
        content.prepend(context);

        setup_main_screen();
        setup_verify_screen();

        cancel_button.clicked.connect(handle_cancel);
        ok_button.clicked.connect(handle_confirm);
        verify_yes_button.clicked.connect(handle_verify_yes);
        verify_no_button.clicked.connect(handle_verify_no);
        set_focus(cancel_button);
    }

    private void handle_confirm() {
        response(current_response);
        close();
    }

    private void handle_verify_yes() {
        ok_button.label = _("Confirm");
        ok_button.remove_css_class("destructive-action");
        ok_button.add_css_class("suggested-action");
        confirm_image.set_from_icon_name("security-high-symbolic");
        confirm_title_label.label = _("Verify key");
        confirm_desc_label.set_markup(_("Future messages sent by %s from the device that uses this key will be highlighted accordingly in the chat window.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
        manage_stack.set_visible_child_name("confirm");
        ok_button.sensitive = true;
        return_to_main = false;
        current_response = TrustLevel.VERIFIED;
    }

    private void handle_verify_no() {
        ok_button.sensitive = false;
        return_to_main = false;
        confirm_image.set_from_icon_name("dialog-warning-symbolic");
        confirm_title_label.label = _("Fingerprints do not match");
        confirm_desc_label.set_markup(_("Please verify that you are comparing the correct fingerprint. If fingerprints do not match, %s's account may be compromised and you should consider rejecting this key.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
        manage_stack.set_visible_child_name("confirm");
    }

    private void handle_cancel() {
        if (manage_stack.get_visible_child_name() == "main") close();

        if (manage_stack.get_visible_child_name() == "verify") {
            manage_stack.set_visible_child_name("main");
            cancel_button.label = _("Cancel");
        }

        if (manage_stack.get_visible_child_name() == "confirm") {
            if (return_to_main) {
                manage_stack.set_visible_child_name("main");
                cancel_button.label = _("Cancel");
            } else {
                manage_stack.set_visible_child_name("verify");
            }
        }

        ok_button.sensitive = false;
        ok_button.label = _("Confirm");
    }

    private Adw.ActionRow make_action_row(string name, string title, string desc, string icon) {
        var row = new Adw.ActionRow() {
            name = name, title = title, subtitle = desc, use_markup = false
        };
        row.add_prefix(new Image.from_icon_name(icon));
        bool removes_device = name == "omemo-remove";
        var open_button = new Button.with_label(removes_device ? _("Remove device") : _("Open")) { valign = Align.CENTER };
        if (removes_device) open_button.add_css_class("destructive-action");
        row.add_suffix(open_button);
        row.activatable_widget = open_button;
        bind_action_button(open_button, row, this);
        return row;
    }

    private static void bind_action_button(Button button, Adw.ActionRow row, ManageKeyDialog owner) {
        var dialog_ref = WeakRef(owner);
        var row_ref = WeakRef(row);
        button.clicked.connect(() => {
            ManageKeyDialog? dialog = dialog_ref.get() as ManageKeyDialog;
            Adw.ActionRow? action_row = row_ref.get() as Adw.ActionRow;
            if (dialog == null || action_row == null ||
                    !dialog.visible || action_row.get_root() != dialog) return;
            dialog.handle_main_action(action_row);
        });
    }

    private void setup_main_screen() {
        main_action_list.set_header_func(update_action_header);

        var verify_row = make_action_row("omemo-verify", _("Verify key fingerprint"), _("Compare this key's fingerprint with the fingerprint displayed on the contact's device."), "dino-security-high-symbolic");
        var reject_row = make_action_row("omemo-reject", _("Reject key"), _("Block encrypted communication with the contact's device that uses this key."), "action-unavailable-symbolic");
        var accept_row = make_action_row("omemo-accept", _("Accept key"), _("Allow encrypted communication with the contact's device that uses this key."), "check-plain-symbolic");
        var reset_row = make_action_row("omemo-reset", _("Reset session"), _("Delete the encryption session for this device. A fresh session will be established on the next message. Use this when messages are not arriving."), "view-refresh-symbolic");
        var remove_row = make_action_row("omemo-remove", _("Remove device"), _("Delete this device's key and session data. Use this for old or inactive devices."), "user-trash-symbolic");

        switch((TrustLevel) device[db.identity_meta.trust_level]) {
            case TrustLevel.TRUSTED:
                main_desc_label.set_markup(_("This key is currently %s.").printf("<b>"+_("accepted")+"</b>")+" "+_("This means it can be used by %s to receive and send encrypted messages.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
                main_action_list.append(verify_row);
                main_action_list.append(reject_row);
                main_action_list.append(reset_row);
                main_action_list.append(remove_row);
                break;
            case TrustLevel.VERIFIED:
                main_desc_label.set_markup(_("This key is currently %s.").printf("<b>"+_("verified")+"</b>")+" "+_("This means it can be used by %s to receive and send encrypted messages.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>") + " " + _("Additionally it has been verified to match the key on the contact's device."));
                main_action_list.append(reject_row);
                main_action_list.append(reset_row);
                main_action_list.append(remove_row);
                break;
            case TrustLevel.UNTRUSTED:
                main_desc_label.set_markup(_("This key is currently %s.").printf("<b>"+_("rejected")+"</b>")+" "+_("This means it cannot be used by %s to decipher your messages, and you won't see messages encrypted with it.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
                main_action_list.append(accept_row);
                main_action_list.append(reset_row);
                main_action_list.append(remove_row);
                break;
            default:
                break;
        }

        manage_stack.set_visible_child_name("main");
    }

    private static void update_action_header(ListBoxRow row, ListBoxRow? before_row) {
        if (row.get_header() == null && before_row != null) {
            row.set_header(new Separator(Orientation.HORIZONTAL));
        }
    }

    private void handle_main_action(ListBoxRow row) {
        ok_button.sensitive = false;
        ok_button.label = _("Confirm");
        ok_button.remove_css_class("suggested-action");
        ok_button.remove_css_class("destructive-action");
        bool destructive = row.name == "omemo-reject" || row.name == "omemo-reset" || row.name == "omemo-remove";
        ok_button.add_css_class(destructive ? "destructive-action" : "suggested-action");
        if (row.name == "omemo-verify") {
            manage_stack.set_visible_child_name("verify");
        } else if (row.name == "omemo-reject") {
            confirm_image.set_from_icon_name("action-unavailable-symbolic");
            confirm_title_label.label = _("Reject key");
            confirm_desc_label.set_markup(_("You won't see encrypted messages from the device of %s that uses this key. Conversely, that device won't be able to decipher your messages anymore.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
            manage_stack.set_visible_child_name("confirm");
            ok_button.sensitive = true;
            return_to_main = true;
            current_response = TrustLevel.UNTRUSTED;
        } else if (row.name == "omemo-accept") {
            confirm_image.set_from_icon_name("check-plain-symbolic");
            confirm_title_label.label = _("Accept key");
            confirm_desc_label.set_markup(_("You will be able to exchange encrypted messages with the device of %s that uses this key.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
            manage_stack.set_visible_child_name("confirm");
            ok_button.sensitive = true;
            return_to_main = true;
            current_response = TrustLevel.TRUSTED;
        } else if (row.name == "omemo-remove") {
            confirm_image.set_from_icon_name("user-trash-symbolic");
            confirm_title_label.label = _("Remove device");
            confirm_desc_label.set_markup(_("The key and session data for this device of %s will be deleted. If the device is still active, it will re-appear when a new message is received.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>") + "\n\n" + _("Please click “Remove device” at the top to confirm deletion."));
            ok_button.label = _("Remove device");
            manage_stack.set_visible_child_name("confirm");
            ok_button.sensitive = true;
            return_to_main = true;
            current_response = -1;
        } else if (row.name == "omemo-reset") {
            confirm_image.set_from_icon_name("view-refresh-symbolic");
            confirm_title_label.label = _("Reset session");
            confirm_desc_label.set_markup(_("The encryption session for this device of %s will be deleted. A fresh session will be negotiated automatically when the next message is sent. The key and trust level are preserved.").printf(@"<b>$(Markup.escape_text(device[db.identity_meta.address_name]))</b>"));
            manage_stack.set_visible_child_name("confirm");
            ok_button.sensitive = true;
            return_to_main = true;
            current_response = -2;
        }
        cancel_button.label = _("Back");
    }

    private void setup_verify_screen() {
        verify_label.set_markup(fingerprint_markup(fingerprint_from_base64(device[db.identity_meta.identity_key_public_base64])));
    }
}

}
