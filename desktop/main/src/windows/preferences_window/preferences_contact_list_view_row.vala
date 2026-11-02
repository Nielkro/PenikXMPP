using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

/** Reusable action row for the virtualized Preferences contact list. */
internal class PreferencesContactListViewRow : Object {
    public signal void edit_requested(Account account, Jid jid, string? current_alias);
    public signal void mute_requested(Account account, Jid jid, bool currently_muted, Conversation conversation);
    public signal void block_requested(Account account, Jid jid, bool currently_blocked);
    public signal void remove_requested(Account account, Jid jid);

    private Box root_box;
    private ContactListViewRow identity_row;
    private Button edit_button;
    private Button mute_button;
    private Button block_button;
    private Button remove_button;
    private Spinner removing_spinner;
    private Label removing_label;

    private ViewModel.PreferencesDialog? preferences_model = null;
    private ViewModel.ContactListItem? item = null;
    private bool removing = false;
    public string? contact_key {
        owned get {
            if (item == null) return null;
            return "%d:%s".printf(((!) item).account.id, ((!) item).jid.bare_jid.to_string());
        }
    }

    construct {
        root_box = new Box(Orientation.HORIZONTAL, 4) { hexpand = true };
        identity_row = new ContactListViewRow();
        Widget identity_widget = identity_row.get_widget();
        identity_widget.hexpand = true;
        root_box.append(identity_widget);

        edit_button = make_action_button("document-edit-symbolic", _("Edit Alias"));
        mute_button = make_action_button("dino-bell-large-symbolic", _("Mute"));
        block_button = make_action_button("action-unavailable-symbolic", _("Block Contact"));
        remove_button = make_action_button("user-trash-symbolic", _("Remove Contact"));
        remove_button.margin_end = 6;
        removing_spinner = new Spinner() {
            spinning = true,
            visible = false,
            valign = Align.CENTER,
            margin_start = 6,
            margin_end = 0
        };
        removing_label = new Label(_("Removing")) {
            visible = false,
            valign = Align.CENTER,
            margin_start = 4,
            margin_end = 12
        };

        root_box.append(edit_button);
        root_box.append(mute_button);
        root_box.append(block_button);
        root_box.append(remove_button);
        root_box.append(removing_spinner);
        root_box.append(removing_label);

        edit_button.clicked.connect(on_edit_clicked);
        mute_button.clicked.connect(on_mute_clicked);
        block_button.clicked.connect(on_block_clicked);
        remove_button.clicked.connect(on_remove_clicked);
    }

    public Widget get_widget() {
        return root_box;
    }

    public void bind(ViewModel.PreferencesDialog preferences_model,
            ViewModel.ContactListItem item, bool show_account_hint, bool removing) {
        unbind();
        this.preferences_model = preferences_model;
        this.item = item;
        identity_row.bind(preferences_model.stream_interactor, item, show_account_hint, true);
        refresh_state(removing);
    }

    public void refresh_state(bool removing) {
        this.removing = removing;
        if (preferences_model == null || item == null) return;

        ViewModel.PreferencesDialog current_model = (!) preferences_model;
        ViewModel.ContactListItem current_item = (!) item;
        ConversationManager? conversation_manager = current_model.stream_interactor
            .get_module<ConversationManager>(ConversationManager.IDENTITY);
        Conversation? conversation = conversation_manager != null
            ? ((!) conversation_manager).get_conversation(
                current_item.jid, current_item.account, Conversation.Type.CHAT)
            : null;
        bool muted = conversation != null && ((!) conversation).get_notification_setting(
            current_model.stream_interactor) == Conversation.NotifySetting.OFF;
        mute_button.set_icon_name(muted
            ? "dino-bell-large-none-symbolic"
            : "dino-bell-large-symbolic");
        set_action_label(mute_button, muted ? _("Unmute") : _("Mute"));

        BlockingManager? blocking_manager = current_model.stream_interactor
            .get_module<BlockingManager>(BlockingManager.IDENTITY);
        bool blocked = blocking_manager != null && ((!) blocking_manager).is_blocked(
            current_item.account, current_item.jid);
        set_action_label(block_button, blocked ? _("Unblock Contact") : _("Block Contact"));
        if (blocked) block_button.add_css_class("error");
        else block_button.remove_css_class("error");

        edit_button.sensitive = !removing;
        mute_button.sensitive = conversation_manager != null && !removing;
        block_button.sensitive = blocking_manager != null && !removing;
        remove_button.sensitive = !removing;
        remove_button.visible = !removing;
        removing_spinner.visible = removing;
        removing_label.visible = removing;
    }

    public void set_show_account_hint(bool show_account_hint) {
        identity_row.set_show_account_hint(show_account_hint);
    }

    public void unbind() {
        identity_row.unbind();
        preferences_model = null;
        item = null;
        removing = false;
        edit_button.sensitive = false;
        mute_button.sensitive = false;
        block_button.sensitive = false;
        remove_button.sensitive = false;
        remove_button.visible = true;
        removing_spinner.visible = false;
        removing_label.visible = false;
        block_button.remove_css_class("error");
    }

    public void cleanup() {
        unbind();
    }

    private Button make_action_button(string icon_name, string tooltip) {
        var button = new Button.from_icon_name(icon_name) {
            valign = Align.CENTER,
            tooltip_text = tooltip
        };
        button.add_css_class("flat");
        button.add_css_class("circular");
        set_action_label(button, tooltip);
        return button;
    }

    private void set_action_label(Button button, string label) {
        button.tooltip_text = label;
        button.update_property(AccessibleProperty.LABEL, label, -1);
    }

    private void on_edit_clicked() {
        if (removing || item == null) return;
        ViewModel.ContactListItem current_item = (!) item;
        edit_requested(current_item.account, current_item.jid, current_item.alias);
    }

    private void on_mute_clicked() {
        if (removing || item == null || preferences_model == null) return;
        ViewModel.PreferencesDialog current_model = (!) preferences_model;
        ViewModel.ContactListItem current_item = (!) item;
        ConversationManager? manager = current_model.stream_interactor
            .get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (manager == null) return;
        Conversation conversation = ((!) manager).create_conversation(
            current_item.jid, current_item.account, Conversation.Type.CHAT);
        bool currently_muted = conversation.get_notification_setting(
            current_model.stream_interactor) == Conversation.NotifySetting.OFF;
        mute_requested(current_item.account, current_item.jid, currently_muted, conversation);
    }

    private void on_block_clicked() {
        if (removing || item == null || preferences_model == null) return;
        ViewModel.PreferencesDialog current_model = (!) preferences_model;
        ViewModel.ContactListItem current_item = (!) item;
        BlockingManager? manager = current_model.stream_interactor
            .get_module<BlockingManager>(BlockingManager.IDENTITY);
        if (manager == null) return;
        bool currently_blocked = ((!) manager).is_blocked(current_item.account, current_item.jid);
        block_requested(current_item.account, current_item.jid, currently_blocked);
    }

    private void on_remove_clicked() {
        if (removing || item == null) return;
        ViewModel.ContactListItem current_item = (!) item;
        remove_requested(current_item.account, current_item.jid);
    }
}

}
