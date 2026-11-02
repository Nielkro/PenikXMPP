using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class SelectContactDialog : Adw.Dialog {

    public signal void selected(Account account, Jid jid);

    public Button ok_button;

    private ContactRosterModelSource roster_source;
    private ContactSelectionView contact_view;
    private StreamInteractor stream_interactor;
    private Gee.List<Account> accounts;
    private HashSet<string> pending_contact_removals = new HashSet<string>();
    private bool selection_closed = false;

    public SelectContactDialog(StreamInteractor stream_interactor, Gee.List<Account> accounts) {
        bool timing = UiTiming.enabled();
        int64 t0_us = timing ? UiTiming.now_us() : 0;
        this.content_width = 460;
        this.content_height = 550;

        this.stream_interactor = stream_interactor;
        this.accounts = accounts;

        var toolbar_view = new Adw.ToolbarView();
        this.child = toolbar_view;

        setup_headerbar(toolbar_view);
        setup_view(toolbar_view);
        if (timing) {
            UiTiming.log_ms("SelectContactDialog.constructor: accounts=%d".printf(accounts.size), t0_us);
        }

        this.closed.connect(on_closed);
        this.unmap.connect(on_unmapped);
    }

    public void set_filter(string str) {
        contact_view.set_filter(str);
    }

    private void setup_headerbar(Adw.ToolbarView toolbar_view) {
        Button cancel_button = new Button();
        cancel_button.set_label(_("Cancel"));
        cancel_button.visible = true;

        ok_button = new Button();
        ok_button.add_css_class("suggested-action");
        ok_button.sensitive = false;
        ok_button.visible = true;

        var header_bar = new Adw.HeaderBar();
        header_bar.decoration_layout = ":";
        header_bar.pack_start(cancel_button);
        header_bar.pack_end(ok_button);

        var window_title = new Adw.WindowTitle("", "");
        this.bind_property("title", window_title, "title", BindingFlags.SYNC_CREATE);
        header_bar.title_widget = window_title;
        
        toolbar_view.add_top_bar(header_bar);

        cancel_button.clicked.connect(on_cancel_clicked);
        ok_button.clicked.connect(submit_choice);
        set_default_widget(ok_button);
    }

    private void setup_view(Adw.ToolbarView toolbar_view) {
        roster_source = new ContactRosterModelSource(stream_interactor, accounts);
        contact_view = new ContactSelectionView(stream_interactor, accounts, roster_source.model);
        contact_view.choice_changed.connect(on_choice_changed);
        contact_view.choice_activated.connect(submit_choice);
        contact_view.add_contact_requested.connect(open_add_contact_dialog);
        contact_view.remove_contact_requested.connect(confirm_remove_contact);
        contact_view.directory_search_requested.connect(open_directory_search);
        toolbar_view.content = contact_view;
    }

    private void on_cancel_clicked() {
        close();
    }

    private void on_choice_changed() {
        ok_button.sensitive = contact_view.done &&
            account_is_active_managed(contact_view.selected_account);
    }

    private void submit_choice() {
        if (selection_closed) return;
        Account? account = contact_view.selected_account;
        Jid? jid = contact_view.selected_jid;
        if (account == null || jid == null || !account_is_active_managed(account)) {
            ok_button.sensitive = false;
            return;
        }
        selected((!) account, (!) jid);
        close();
    }

    private void open_add_contact_dialog() {
        Account? account = contact_view.preferred_account;
        AddContactDialog dialog = account != null
            ? AddContactDialog.for_account(stream_interactor, (!) account)
            : new AddContactDialog(stream_interactor);
        dialog.present(this);
    }

    private void open_directory_search(string query, Account? requested_account) {
        Account? account = requested_account != null
            ? (directory_account_is_connected(requested_account) ? requested_account : null)
            : first_connected_scoped_account();
        if (account == null) return;

        Account search_account = (!) account;
        var dialog = new UserSearchDialog(stream_interactor, search_account, query);
        connect_directory_result(dialog, this, search_account);
        dialog.present(this);
    }

    private static void connect_directory_result(UserSearchDialog dialog,
            SelectContactDialog owner, Account search_account) {
        var weak_parent = WeakRef(owner);
        dialog.contact_selected.connect((jid) => {
            var parent = weak_parent.get() as SelectContactDialog;
            if (parent == null || parent.selection_closed || !parent.directory_account_is_connected(search_account)) return;
            parent.selected(search_account, jid);
            parent.close();
        });
    }

    private Account? first_connected_scoped_account() {
        foreach (Account account in accounts) {
            if (directory_account_is_connected(account)) return account;
        }
        return null;
    }

    private bool directory_account_is_connected(Account? account) {
        if (!account_is_active_managed(account)) return false;
        XmppStream? stream = stream_interactor.get_stream((!) account);
        return stream != null && ((!) stream).negotiation_complete;
    }

    private void on_closed() {
        if (selection_closed) return;
        selection_closed = true;
        contact_view.deactivate();
        roster_source.deactivate();
    }

    private void on_unmapped() {
        // libadwaita 1.5 Gtk.Window fallback hosts can dismiss without closed.
        // Embedded Adw dialogs retain their normal closed lifecycle, including
        // temporary hiding while another dialog is presented on top.
        Gtk.Root? root = get_root();
        if (root is Gtk.Window && !(root is Adw.Window) &&
                !(root is Adw.ApplicationWindow) &&
                !((Gtk.Window) root).get_visible()) {
            on_closed();
        }
    }

    private void confirm_remove_contact(Account account, Jid jid) {
        string operation_key = contact_operation_key(account, jid);
        if (pending_contact_removals.contains(operation_key)) return;
        var dialog = new Adw.AlertDialog(
            _("Remove contact?"),
            _("This will:\n• Delete all conversation history\n• Remove %s from your contact list\n\nThis action cannot be undone.").printf(jid.to_string())
        );
        dialog.add_response("cancel", _("Cancel"));
        dialog.add_response("remove", _("Remove"));
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response("cancel");
        dialog.set_close_response("cancel");

        dialog.response.connect((response) => {
            if (response == "remove") {
                // The account can disappear while the confirmation dialog is
                // open. The async helper also keeps history intact until the
                // server has confirmed the roster removal.
                if (!account_is_active_managed(account)) return;
                remove_contact_and_history.begin(account, jid);
            }
        });

        dialog.present(this);
    }

    private async void remove_contact_and_history(Account account, Jid jid) {
        string operation_key = contact_operation_key(account, jid);
        if (pending_contact_removals.contains(operation_key)) return;
        pending_contact_removals.add(operation_key);
        if (!account_is_active_managed(account)) {
            pending_contact_removals.remove(operation_key);
            return;
        }
        var manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        RosterRemoveResult result = yield manager.remove_contact_and_history(account, jid);
        pending_contact_removals.remove(operation_key);
        if (result != RosterRemoveResult.SUCCESS && this.get_root() != null)
            Util.show_remove_contact_failure(this, jid, result);
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }

    private string contact_operation_key(Account account, Jid jid) {
        return "%d|%s".printf(account.id, jid.bare_jid.to_string());
    }
}

public class AddChatDialog : SelectContactDialog {

    public signal void added(Conversation conversation);
    private StreamInteractor add_chat_stream_interactor;

    public AddChatDialog(StreamInteractor stream_interactor, Gee.List<Account> accounts) {
        base(stream_interactor, accounts);
        this.add_chat_stream_interactor = stream_interactor;
        title = _("Start Conversation");
        ok_button.label = _("Start");
        selected.connect(on_selected);
    }

    private void on_selected(Account account, Jid jid) {
        ConversationManager conversation_manager = add_chat_stream_interactor
            .get_module<ConversationManager>(ConversationManager.IDENTITY);
        Conversation conversation = conversation_manager.create_conversation(
            jid, account, Conversation.Type.CHAT);
        conversation_manager.start_conversation(conversation);
        added(conversation);
    }
}

}
