using Dino.Entities;
using Xmpp;

namespace Dino.Ui.ViewModel {

/** Server roster state and incoming requests, scoped to one account/contact. */
public class ContactSubscriptionModel : Object {
    public Account account { get; private set; }
    public Jid jid { get; private set; }
    public bool in_roster { get; private set; }
    public bool receives_presence { get; private set; }
    public bool shares_presence { get; private set; }
    public bool outgoing_pending { get; private set; }
    public bool preapproved { get; private set; }
    public bool incoming_pending { get; private set; }
    public bool connected { get; private set; }
    public signal void changed();

    private StreamInteractor interactor;
    private RosterManager roster;
    private PresenceManager presence;
    private CallbackBridge callbacks;
    private ulong updated_id;
    private ulong removed_id;
    private ulong requests_id;
    private ulong connection_id;
    private ulong account_removed_id;
    private ulong enabled_id;
    private bool inactive = false;
    private bool account_removed = false;

    private class CallbackBridge : Object {
        private WeakRef owner;
        public CallbackBridge(ContactSubscriptionModel model) { owner = WeakRef(model); }
        public void updated(Account account, Jid jid, Roster.Item item) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null && model.matches(account, jid)) model.apply_item(item);
        }
        public void removed(Account account, Jid jid, Roster.Item item) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null && model.matches(account, jid)) model.apply_item(null);
        }
        public void requests(Jid jid, Account account) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null && model.matches(account, jid)) model.update_request_state();
        }
        public void connection(Account account, ConnectionManager.ConnectionState state) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null && same_account(model.account, account)) model.refresh();
        }
        public void removed_account(Account account) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null && same_account(model.account, account)) {
                model.account_removed = true;
                model.refresh();
            }
        }
        public void enabled(GLib.ParamSpec spec) {
            var model = owner.get() as ContactSubscriptionModel;
            if (model != null) model.refresh();
        }
    }

    public ContactSubscriptionModel(StreamInteractor interactor, Account account, Jid jid) {
        this.interactor = interactor;
        this.account = account;
        this.jid = jid.bare_jid;
        roster = interactor.get_module<RosterManager>(RosterManager.IDENTITY);
        presence = interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        callbacks = new CallbackBridge(this);
        updated_id = roster.updated_roster_item.connect(callbacks.updated);
        removed_id = roster.removed_roster_item.connect(callbacks.removed);
        requests_id = presence.subscription_requests_changed.connect(callbacks.requests);
        connection_id = interactor.connection_manager.connection_state_changed.connect(callbacks.connection);
        account_removed_id = interactor.account_removed.connect(callbacks.removed_account);
        enabled_id = account.notify["enabled"].connect(callbacks.enabled);
        refresh();
    }

    public static bool same_account(Account left, Account right) {
        return left == right || (left.id > 0 && right.id == left.id &&
            left.bare_jid.equals_bare(right.bare_jid));
    }

    private bool matches(Account event_account, Jid event_jid) {
        return !inactive && !account_removed && same_account(account, event_account) && jid.equals_bare(event_jid);
    }

    public void refresh() {
        if (inactive) return;
        connected = false;
        if (!account_removed && account.enabled) {
            foreach (Account managed in interactor.get_accounts()) {
                if (same_account(account, managed) && managed.enabled) {
                    connected = interactor.get_stream(managed) != null;
                    break;
                }
            }
        }
        apply_item(account_removed ? null : roster.get_roster_item(account, jid));
    }

    private void apply_item(Roster.Item? item) {
        if (inactive) return;
        in_roster = item != null;
        receives_presence = item != null && (item.subscription == Roster.Item.SUBSCRIPTION_TO || item.subscription == Roster.Item.SUBSCRIPTION_BOTH);
        shares_presence = item != null && (item.subscription == Roster.Item.SUBSCRIPTION_FROM || item.subscription == Roster.Item.SUBSCRIPTION_BOTH);
        outgoing_pending = item != null && item.ask == "subscribe" && !receives_presence;
        string? approved = item != null ? item.stanza_node.get_attribute("approved") : null;
        preapproved = item != null && !shares_presence && (approved == "true" || approved == "1");
        update_request_state();
    }

    private void update_request_state() {
        if (inactive) return;
        incoming_pending = !account_removed && !shares_presence && presence.exists_subscription_request(account, jid);
        changed();
    }

    public string describe() {
        string text;
        if (receives_presence && shares_presence) text = _("Both contacts have approved presence sharing");
        else if (receives_presence) text = _("You can see their online status; yours is not shared");
        else if (shares_presence) text = _("They can see your online status; theirs is not shared");
        else if (in_roster) text = _("Contact added; online status is not shared yet");
        else text = _("Not in your contact list");
        if (outgoing_pending) text += " · " + _("Waiting for the contact to approve your request");
        if (incoming_pending) text += " · " + _("This contact is waiting for your approval");
        else if (preapproved) text += " · " + _("Your approval is ready for this contact's next request");
        return text;
    }

    public void deactivate() {
        if (inactive) return;
        inactive = true;
        roster.disconnect(updated_id);
        roster.disconnect(removed_id);
        presence.disconnect(requests_id);
        interactor.connection_manager.disconnect(connection_id);
        interactor.disconnect(account_removed_id);
        account.disconnect(enabled_id);
    }

    public override void dispose() {
        deactivate();
        base.dispose();
    }
}

}
