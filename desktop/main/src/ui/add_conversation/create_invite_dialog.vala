using Gdk;
using Gtk;
#if HAVE_QRENCODE
using Qrencode;
#endif

using Dino.Entities;

namespace Dino.Ui {

public class CreateInviteDialog : Adw.Dialog {

    private StreamInteractor stream_interactor;
    private AccountComboBox account_combobox = new AccountComboBox ();
    private Button create_button;
    private Button copy_web_button;
    private Button copy_xmpp_button;
    private Spinner spinner;
    private Label status_label;
    private Label server_context_label;
    private Label share_hint_label;
    private Box qr_code_box;
#if HAVE_QRENCODE
    private Picture qr_code_picture;
#endif
    private Box web_link_box;
    private Box xmpp_link_box;
    private Entry web_link_entry;
    private Entry xmpp_link_entry;
    private string? current_web_link = null;
    private string? current_xmpp_link = null;
    private uint create_request_id = 0;
    private Account? result_account = null;
    private bool creating_invite = false;

    public CreateInviteDialog (StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        this.title = _("Create Invitation");
        this.content_width = 560;
        this.content_height = 520;

        var toolbar_view = new Adw.ToolbarView ();
        this.child = toolbar_view;

        setup_headerbar (toolbar_view);
        setup_content (toolbar_view);
    }

    private void setup_headerbar (Adw.ToolbarView toolbar_view) {
        var cancel_button = new Button.with_label (_("Cancel"));
        cancel_button.clicked.connect (() => close ());

        spinner = new Spinner ();
        spinner.visible = false;

        create_button = new Button.with_label (_("Create Link"));
        create_button.add_css_class ("suggested-action");
        create_button.clicked.connect (() => create_invite.begin ());

        var header_bar = new Adw.HeaderBar ();
        header_bar.decoration_layout = ":";
        header_bar.pack_start (cancel_button);
        header_bar.pack_end (create_button);
        header_bar.pack_end (spinner);

        var window_title = new Adw.WindowTitle (_("Create Invitation"), "");
        header_bar.title_widget = window_title;
        toolbar_view.add_top_bar (header_bar);
    }

    private void setup_content (Adw.ToolbarView toolbar_view) {
        var content = new Box (Orientation.VERTICAL, 18) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };

        var intro_label = new Label (_("Create a shareable invitation link for the selected account. The server decides who may create invitations and how long they remain valid.")) {
            wrap = true,
            xalign = 0
        };
        content.append (intro_label);

        var account_group = new Adw.PreferencesGroup () {
            title = _("Account")
        };
        var account_row = new Adw.ActionRow () {
            title = _("Invite from")
        };
        account_combobox.initialize (stream_interactor);
        account_combobox.valign = Align.CENTER;
        account_combobox.notify["active-account"].connect (() => {
            Account? account = account_combobox.active_account;
            if (result_account != null && account != result_account) {
                hide_result ();
            }
            create_button.sensitive = !creating_invite && account != null && ((!) account).enabled && current_xmpp_link == null;
            update_server_context ();
        });
        account_row.add_suffix (account_combobox);
        account_row.activatable_widget = account_combobox;
        account_group.add (account_row);
        content.append (account_group);

        server_context_label = new Label ("") {
            wrap = true,
            xalign = 0
        };
        server_context_label.add_css_class ("dim-label");
        content.append (server_context_label);
        update_server_context ();

        var result_box = new Box (Orientation.VERTICAL, 10);
        result_box.append (build_link_row (
            _("Web Link"),
            out web_link_box,
            out web_link_entry,
            out copy_web_button
        ));
        copy_web_button.clicked.connect (() => copy_link (current_web_link));

        result_box.append (build_link_row (
            _("XMPP Link"),
            out xmpp_link_box,
            out xmpp_link_entry,
            out copy_xmpp_button
        ));
        copy_xmpp_button.clicked.connect (() => copy_link (current_xmpp_link));

        qr_code_box = build_qr_code_box ();
        result_box.append (qr_code_box);

        status_label = new Label ("") {
            wrap = true,
            xalign = 0,
            visible = false
        };
        share_hint_label = new Label (_("Share one of these links with the person you want to invite. You can send it by email, messenger, SMS, a website, or an existing chat.")) {
            wrap = true,
            xalign = 0,
            visible = false
        };
        share_hint_label.add_css_class ("dim-label");
        result_box.append (status_label);
        result_box.append (share_hint_label);
        content.append (result_box);

        var scrolled = new ScrolledWindow () {
            hscrollbar_policy = PolicyType.NEVER,
            vexpand = true,
            child = content
        };
        toolbar_view.content = scrolled;

        if (account_combobox.active_account == null) {
            create_button.sensitive = false;
            show_status (_("No enabled account is available."), false);
        }
    }

    private void update_server_context () {
        Account? account = account_combobox.active_account;
        if (account == null || !((!) account).enabled) {
            server_context_label.label = _("No account selected.");
            return;
        }

        string domain = account.domainpart;
        server_context_label.label = _("The invitation is created through the selected account's server: %s. That server decides whether this account may create invitation links.").printf (domain);
    }

    private Widget build_link_row (string title, out Box row, out Entry entry, out Button copy_button) {
        row = new Box (Orientation.VERTICAL, 6) {
            visible = false
        };

        var label = new Label (title) {
            xalign = 0
        };
        label.add_css_class ("heading");

        var input_row = new Box (Orientation.HORIZONTAL, 6);
        entry = new Entry () {
            editable = false,
            hexpand = true
        };
        copy_button = new Button.from_icon_name ("edit-copy-symbolic") {
            tooltip_text = _("Copy Link")
        };

        input_row.append (entry);
        input_row.append (copy_button);
        row.append (label);
        row.append (input_row);
        return row;
    }

    private Box build_qr_code_box () {
        var box = new Box (Orientation.VERTICAL, 8) {
            visible = false,
            halign = Align.CENTER
        };

        var label = new Label (_("QR Code")) {
            xalign = 0,
            halign = Align.CENTER
        };
        label.add_css_class ("heading");
        box.append (label);

#if HAVE_QRENCODE
        qr_code_picture = new Picture () {
            width_request = 192,
            height_request = 192,
            can_shrink = false,
            halign = Align.CENTER
        };
        qr_code_picture.add_css_class ("qrcode-container");
        box.append (qr_code_picture);
#else
        var missing_label = new Label (_("QR code support is not available in this build.")) {
            wrap = true,
            xalign = 0
        };
        missing_label.add_css_class ("dim-label");
        box.append (missing_label);
#endif
        return box;
    }

    private async void create_invite () {
        Account? account = account_combobox.active_account;
        if (account == null || !((!) account).enabled) {
            show_status (_("No enabled account is available."), false);
            return;
        }
        Account request_account = (!) account;
        uint request_id = ++create_request_id;

        set_busy (true);
        hide_result ();

        InviteManager manager = stream_interactor.get_module<InviteManager> (InviteManager.IDENTITY);
        InviteResult? result = yield manager.create_user_invite (request_account);

        Account? selected_account = account_combobox.active_account;
        if (request_id != create_request_id) return;
        if (!request_account.enabled || selected_account != request_account) {
            set_busy (false);
            return;
        }

        set_busy (false);

        if (result == null) {
            show_status (describe_error (manager.last_error), false);
            return;
        }

        current_web_link = result.landing_url;
        current_xmpp_link = result.uri;
        result_account = request_account;

        web_link_entry.text = current_web_link ?? "";
        web_link_box.visible = current_web_link != null && current_web_link != "";

        xmpp_link_entry.text = current_xmpp_link ?? "";
        xmpp_link_box.visible = current_xmpp_link != null && current_xmpp_link != "";

        if (result.expires_at != null && result.expires_at != "") {
            show_status (_("Invitation created. It expires at %s.").printf ((!) result.expires_at), true);
        } else {
            show_status (_("Invitation created."), true);
        }
        create_button.sensitive = false;
        update_qr_code ();
        share_hint_label.visible = true;
    }

    private void update_qr_code () {
        string? link = current_web_link ?? current_xmpp_link;
        if (link == null || link == "") {
            qr_code_box.visible = false;
            return;
        }

#if HAVE_QRENCODE
        const int QUIET_ZONE_MODULES = 4;
        const int MODULE_SIZE_PX = 4;
        var qr_paintable = new QRcode ((!) link)
            .to_paintable (MODULE_SIZE_PX * qr_code_picture.scale_factor);
        qr_code_picture.paintable = qr_paintable;
        int margin = QUIET_ZONE_MODULES * MODULE_SIZE_PX;
        qr_code_picture.margin_top = margin;
        qr_code_picture.margin_end = margin;
        qr_code_picture.margin_bottom = margin;
        qr_code_picture.margin_start = margin;
        qr_code_box.visible = true;
#else
        qr_code_box.visible = true;
#endif
    }

    private void copy_link (string? link) {
        if (link == null || link == "") return;

        Display? display = Display.get_default ();
        if (display != null) {
            display.get_clipboard ().set_text ((!) link);
            show_status (_("Invitation link copied."), true);
        }
    }

    private string describe_error (string? error) {
        switch (error) {
            case "account-not-connected":
                return _("The selected account is not connected yet.");
            case "invite-result-invalid":
                return _("The server returned an invitation response DinoX could not understand.");
            case "command-failed":
            default:
                return _("This account is not allowed to create invitations, or the server does not provide them.");
        }
    }

    private void set_busy (bool busy) {
        creating_invite = busy;
        Account? account = account_combobox.active_account;
        create_button.sensitive = !busy && current_xmpp_link == null && account != null && ((!) account).enabled;
        account_combobox.sensitive = !busy;
        spinner.visible = busy;
        if (busy) {
            spinner.start ();
        } else {
            spinner.stop ();
        }
    }

    private void hide_result () {
        current_web_link = null;
        current_xmpp_link = null;
        result_account = null;
        web_link_entry.text = "";
        xmpp_link_entry.text = "";
        web_link_box.visible = false;
        xmpp_link_box.visible = false;
        qr_code_box.visible = false;
#if HAVE_QRENCODE
        qr_code_picture.paintable = null;
#endif
        status_label.visible = false;
        share_hint_label.visible = false;
    }

    private void show_status (string text, bool success) {
        status_label.label = text;
        status_label.visible = true;
        status_label.remove_css_class ("error");
        status_label.remove_css_class ("success");
        status_label.add_css_class (success ? "success" : "error");
    }
}

}
