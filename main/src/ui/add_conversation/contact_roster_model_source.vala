using Gee;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

/** Widget-free, account-scoped adapter from RosterManager into ContactListModel. */
internal class ContactRosterModelSource : Object {
    public ViewModel.ContactListModel model { get; private set; }

    private StreamInteractor stream_interactor;
    private ArrayList<Account> accounts = new ArrayList<Account>();
    private RosterManager? roster_manager = null;
    private CallbackBridge callbacks;
    private ulong roster_updated_handler_id = 0;
    private ulong roster_removed_handler_id = 0;
    private ulong account_removed_handler_id = 0;
    private bool deactivated = false;

    private class CallbackBridge : Object {
        private WeakRef owner_ref;

        public CallbackBridge(ContactRosterModelSource owner) {
            owner_ref = WeakRef(owner);
        }

        public void roster_updated(Account account, Jid jid, Roster.Item roster_item) {
            ContactRosterModelSource? owner = (ContactRosterModelSource?) owner_ref.get();
            if (owner != null) ((!) owner).on_roster_updated(account, jid, roster_item);
        }

        public void roster_removed(Account account, Jid jid, Roster.Item roster_item) {
            ContactRosterModelSource? owner = (ContactRosterModelSource?) owner_ref.get();
            if (owner != null) ((!) owner).on_roster_removed(account, jid);
        }

        public void account_removed(Account account) {
            ContactRosterModelSource? owner = (ContactRosterModelSource?) owner_ref.get();
            if (owner != null) ((!) owner).on_account_removed(account);
        }

        public void clear() {
            owner_ref.set(null);
        }
    }

    public ContactRosterModelSource(StreamInteractor stream_interactor, Gee.List<Account> accounts) {
        this.stream_interactor = stream_interactor;
        this.accounts.add_all(accounts);
        model = new ViewModel.ContactListModel();
        callbacks = new CallbackBridge(this);
        roster_manager = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY);

        if (roster_manager != null) {
            roster_updated_handler_id = ((!) roster_manager).updated_roster_item.connect(callbacks.roster_updated);
            roster_removed_handler_id = ((!) roster_manager).removed_roster_item.connect(callbacks.roster_removed);
        } else {
            warning("ContactRosterModelSource: RosterManager unavailable");
        }
        account_removed_handler_id = stream_interactor.account_removed.connect(callbacks.account_removed);
        load_snapshot();
    }

    public void deactivate() {
        if (deactivated) return;
        deactivated = true;
        if (roster_manager != null && roster_updated_handler_id != 0 &&
                SignalHandler.is_connected((!) roster_manager, roster_updated_handler_id)) {
            SignalHandler.disconnect((!) roster_manager, roster_updated_handler_id);
        }
        if (roster_manager != null && roster_removed_handler_id != 0 &&
                SignalHandler.is_connected((!) roster_manager, roster_removed_handler_id)) {
            SignalHandler.disconnect((!) roster_manager, roster_removed_handler_id);
        }
        roster_updated_handler_id = 0;
        roster_removed_handler_id = 0;
        if (account_removed_handler_id != 0 &&
                SignalHandler.is_connected(stream_interactor, account_removed_handler_id)) {
            SignalHandler.disconnect(stream_interactor, account_removed_handler_id);
        }
        account_removed_handler_id = 0;
        callbacks.clear();
    }

    public override void dispose() {
        deactivate();
        base.dispose();
    }

    private void load_snapshot() {
        bool timing = UiTiming.enabled();
        int64 started_us = timing ? UiTiming.now_us() : 0;
        uint loaded = 0;
        if (roster_manager != null) {
            foreach (Account account in accounts) {
                foreach (Roster.Item roster_item in ((!) roster_manager).get_roster(account)) {
                    model.upsert(account, roster_item.jid, roster_item.name);
                    loaded++;
                }
            }
        }
        if (timing) {
            UiTiming.log_ms("ContactRosterModelSource.snapshot: accounts=%d rows=%u".printf(
                accounts.size, loaded), started_us);
        }
    }

    private void on_roster_updated(Account account, Jid jid, Roster.Item roster_item) {
        if (deactivated || !contains_account(account)) return;
        model.upsert(account, jid, roster_item.name);
    }

    private void on_roster_removed(Account account, Jid jid) {
        if (deactivated || !contains_account(account)) return;
        model.remove(account, jid);
    }

    private void on_account_removed(Account account) {
        if (deactivated || !contains_account(account)) return;
        for (int index = accounts.size - 1; index >= 0; index--) {
            if (accounts[index] == account) accounts.remove_at(index);
        }
        var jids = new ArrayList<Jid>();
        for (uint index = 0; index < model.items.get_n_items(); index++) {
            ViewModel.ContactListItem? item = model.items.get_item(index) as ViewModel.ContactListItem;
            if (item != null && ((!) item).account == account) jids.add(((!) item).jid);
        }
        foreach (Jid jid in jids) model.remove(account, jid);
    }

    private bool contains_account(Account account) {
        foreach (Account scoped_account in accounts) {
            if (scoped_account == account) return true;
        }
        return false;
    }
}

}
