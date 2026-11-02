using Gee;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

class AccountComboBox : Box {

    private DropDown dropdown;
    private StreamInteractor? stream_interactor;
    private ulong account_added_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    private HashMap<Account, ulong> account_enabled_handler_ids = new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    public bool allow_fallback_selection { get; set; default = true; }
    private bool refreshing_accounts = false;

    public Account? active_account {
        get {
            return dropdown.selected_item as Account;
        }
        set {
            select_account(value);
        }
    }

    public bool select_account(Account? value) {
        if (value == null) {
            return false;
        }

        var list_model = dropdown.model as GLib.ListStore;
        if (list_model == null) {
            return false;
        }

        for (uint i = 0; i < list_model.get_n_items(); i++) {
            var item = list_model.get_item(i) as Account;
            if (item != null && item.equals(value)) {
                dropdown.selected = i;
                return true;
            }
        }
        return false;
    }

    construct {
        orientation = Orientation.HORIZONTAL;
        spacing = 0;
        
        // Create empty model and set expression immediately to avoid GTK warnings
        var empty_model = new GLib.ListStore(typeof(Account));
        Expression expression = new PropertyExpression(typeof(Account), null, "display_name");
        dropdown = new DropDown(empty_model, expression);
        dropdown.hexpand = true;
        append(dropdown);
        
        dropdown.notify["selected-item"].connect(() => {
            if (refreshing_accounts) return;
            notify_property("active-account");
        });

        this.destroy.connect(() => {
            disconnect_account_signals();
        });
    }

    public void initialize(StreamInteractor stream_interactor) {
        disconnect_account_signals();
        this.stream_interactor = stream_interactor;

        account_added_handler_id = stream_interactor.account_added.connect((account) => {
            connect_account_enabled_signal(account);
            refresh_accounts();
        });
        account_removed_handler_id = stream_interactor.account_removed.connect((account) => {
            disconnect_account_enabled_signal(account);
            refresh_accounts();
        });

        foreach (Account account in stream_interactor.get_accounts()) {
            connect_account_enabled_signal(account);
        }

        refresh_accounts();
    }

    public void refresh_accounts() {
        if (stream_interactor == null) return;

        Account? previous_account = active_account;
        var list_store = new GLib.ListStore(typeof(Account));
        foreach (Account account in ((!) stream_interactor).get_accounts()) {
            if (account.enabled) {
                list_store.append(account);
            }
        }
        
        refreshing_accounts = true;
        dropdown.model = list_store;

        bool selected_previous = false;
        if (previous_account != null && ((!) previous_account).enabled) {
            selected_previous = select_account((!) previous_account);
        }
        if (!selected_previous && allow_fallback_selection && list_store.get_n_items() > 0) {
            dropdown.selected = 0;
        } else if (!selected_previous && !allow_fallback_selection) {
            dropdown.selected = Gtk.INVALID_LIST_POSITION;
        }
        refreshing_accounts = false;

        notify_property("active-account");
    }

    private void connect_account_enabled_signal(Account account) {
        if (account_enabled_handler_ids.has_key(account)) return;
        account_enabled_handler_ids[account] = account.notify["enabled"].connect(() => {
            refresh_accounts();
        });
    }

    private void disconnect_account_enabled_signal(Account account) {
        if (!account_enabled_handler_ids.has_key(account)) return;
        ulong handler_id = account_enabled_handler_ids[account];
        if (SignalHandler.is_connected(account, handler_id)) {
            account.disconnect(handler_id);
        }
        account_enabled_handler_ids.unset(account);
    }

    private void disconnect_account_signals() {
        if (stream_interactor != null && account_added_handler_id != 0) {
            StreamInteractor interactor = (!) stream_interactor;
            if (SignalHandler.is_connected(interactor, account_added_handler_id)) {
                interactor.disconnect(account_added_handler_id);
            }
        }
        if (stream_interactor != null && account_removed_handler_id != 0) {
            StreamInteractor interactor = (!) stream_interactor;
            if (SignalHandler.is_connected(interactor, account_removed_handler_id)) {
                interactor.disconnect(account_removed_handler_id);
            }
        }
        account_added_handler_id = 0;
        account_removed_handler_id = 0;

        var connected_accounts = new ArrayList<Account>();
        foreach (Account account in account_enabled_handler_ids.keys) {
            connected_accounts.add(account);
        }
        foreach (Account account in connected_accounts) {
            disconnect_account_enabled_signal(account);
        }
    }
}

}
