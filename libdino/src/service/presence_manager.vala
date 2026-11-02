using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

public delegate bool PresenceObserverCallback(Jid jid, Account account, bool available);

public enum MutualSubscriptionResult {
    REQUESTED,
    PENDING_APPROVED,
    PREAPPROVED,
    MANUAL_APPROVAL_REQUIRED,
    ALREADY_GRANTED
}

public class PresenceObserver : Object {
    internal weak PresenceManager? manager;
    internal string key;
    internal uint id;
    private PresenceObserverCallback? callback;

    internal PresenceObserver(PresenceManager manager, string key, uint id, owned PresenceObserverCallback callback) {
        this.manager = manager;
        this.key = key;
        this.id = id;
        this.callback = (owned) callback;
    }

    internal bool dispatch(Jid jid, Account account, bool available) {
        return callback != null && ((!) callback)(jid, account, available);
    }

    public void unsubscribe() {
        PresenceManager? owner = manager;
        manager = null;
        callback = null;
        if (owner != null) ((!) owner).remove_presence_observer(this);
    }

    ~PresenceObserver() {
        unsubscribe();
    }
}

public class PresenceManager : StreamInteractionModule, Object {
    public static ModuleIdentity<PresenceManager> IDENTITY = new ModuleIdentity<PresenceManager>("presence_manager");
    private const string MUC_NS_URI = "http://jabber.org/protocol/muc";
    public string id { get { return IDENTITY.id; } }

    public signal void show_received(Jid jid, Account account);
    public signal void received_offline_presence(Jid jid, Account account);
    public signal void received_subscription_request(Jid jid, Account account);
    public signal void received_subscription_approval(Jid jid, Account account);
    public signal void subscription_requests_changed(Jid jid, Account account);
    public signal void subscription_action_failed(Jid jid, Account account);
    public signal void status_changed(string show, string? status_msg);

    private StreamInteractor stream_interactor;
    private HashSet<string> subscription_requests = new HashSet<string>();
    private HashSet<string> active_subscription_actions = new HashSet<string>();
    private HashSet<string> suppress_subscription_keys = new HashSet<string>();
    private HashMap<string, HashSet<string>> pending_suppressions_by_account_jid = new HashMap<string, HashSet<string>>();
    private HashMap<string, HashMap<uint, PresenceObserver>> presence_observers = new HashMap<string, HashMap<uint, PresenceObserver>>();
    private uint next_presence_observer_id = 1;

    private string current_show = "online";
    private string? current_status_msg = null;
    private Database? db = null;

    public string get_current_show() {
        return current_show;
    }

    public string? get_current_status_msg() {
        return current_status_msg;
    }

    public static void start(StreamInteractor stream_interactor, Database? db = null) {
        PresenceManager m = new PresenceManager(stream_interactor, db);
        stream_interactor.add_module(m);
    }

    private PresenceManager(StreamInteractor stream_interactor, Database? db = null) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);

        // Restore persisted status from database
        if (db != null) {
            var settings = new Dino.Entities.Settings.from_db(db);
            string saved_show = settings.presence_show;
            string saved_msg = settings.presence_status_msg;
            if (saved_show != null && saved_show.strip() != "") {
                this.current_show = saved_show;
            }
            if (saved_msg != null && saved_msg.strip() != "") {
                this.current_status_msg = saved_msg;
            } else {
                this.current_status_msg = null;
            }
        }
    }

    public void set_status(string show, string? status_msg) {
        this.current_show = show;
        this.current_status_msg = status_msg;

        // Persist to database
        if (db != null) {
            var settings = new Dino.Entities.Settings.from_db(db);
            settings.presence_show = show;
            settings.presence_status_msg = status_msg ?? "";
        }

        status_changed(show, status_msg);

        foreach (Account account in stream_interactor.get_accounts()) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                send_current_presence(stream);
            }
        }
    }

    /**
     * Resend presence for a specific account (e.g., after OpenPGP key change)
     */
    public void resend_presence(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            send_current_presence(stream);
        }
    }

    private void send_current_presence(XmppStream stream) {
        var presence_module = stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY);
        var presence = new Xmpp.Presence.Stanza();
        apply_current_status_to_presence(presence, false);
        
        // Add priority to ensure the presence is recognized and prioritized by the server and other clients (like Gajim)
        presence.priority = 5;

        debug("Sending global presence for stream %s: show='%s', status='%s'", 
              stream.get_flag(Bind.Flag.IDENTITY).my_jid != null ? stream.get_flag(Bind.Flag.IDENTITY).my_jid.to_string() : "unknown", 
              current_show, current_status_msg ?? "null");
        presence_module.send_presence(stream, presence);
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        // The initial presence already has the correct status injected
        // via on_pre_send_presence, so we don't need to send a second one.
        // Just fire our signal so the UI updates.
        status_changed(current_show, current_status_msg);
    }

    public string? get_last_show(Jid jid, Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;

        var presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
        if (presence_flag == null) return null;

        Xmpp.Presence.Stanza? presence = presence_flag.get_presence(jid);
        if (presence == null) return null;

        return presence.show;
    }

    public bool has_presence(Jid jid, Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        var presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
        if (presence_flag == null) return false;

        return presence_flag.get_presence(jid) != null;
    }

    public PresenceObserver observe_presence(Account account, Jid jid, owned PresenceObserverCallback callback) {
        string key = presence_observer_key(account.id, jid);
        if (!presence_observers.has_key(key)) {
            presence_observers[key] = new HashMap<uint, PresenceObserver>();
        }

        uint observer_id = next_presence_observer_id++;
        if (next_presence_observer_id == 0) next_presence_observer_id = 1;
        var observer = new PresenceObserver(this, key, observer_id, (owned) callback);
        presence_observers[key][observer_id] = observer;
        return observer;
    }

    internal void remove_presence_observer(PresenceObserver observer) {
        if (!presence_observers.has_key(observer.key)) return;

        presence_observers[observer.key].unset(observer.id);
        if (presence_observers[observer.key].is_empty) presence_observers.unset(observer.key);
    }

    public string? get_last_status_msg(Jid jid, Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;

        var presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
        if (presence_flag == null) return null;

        Xmpp.Presence.Stanza? presence = presence_flag.get_presence(jid);
        if (presence == null) return null;

        return presence.status;
    }

    public Gee.List<Jid>? get_full_jids(Jid jid, Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            Xmpp.Presence.Flag flag = stream.get_flag(Presence.Flag.IDENTITY);
            if (flag == null) return null;
            return flag.get_resources(jid.bare_jid);
        }
        return null;
    }

    public bool exists_subscription_request(Account account, Jid jid) {
        return subscription_requests.contains(get_subscription_request_key(account, jid));
    }

    // Suppress subscription notifications for a specific account/JID pair (used by bot plugin)
    public void suppress_subscription_notification(Account account, Jid jid) {
        suppress_subscription_keys.add(get_subscription_suppression_key(account, jid));
    }

    public void suppress_subscription_notification_for_account_jid(Jid account_jid, Jid jid) {
        string account_key = account_jid.bare_jid.to_string();
        foreach (Account account in stream_interactor.get_accounts()) {
            if (account.bare_jid.equals_bare(account_jid)) {
                suppress_subscription_notification(account, jid);
                return;
            }
        }
        if (!pending_suppressions_by_account_jid.has_key(account_key)) {
            pending_suppressions_by_account_jid[account_key] = new HashSet<string>();
        }
        pending_suppressions_by_account_jid[account_key].add(jid.bare_jid.to_string());
    }

    // Check if subscription notification is suppressed for an account/JID pair
    public bool is_subscription_suppressed(Account account, Jid jid) {
        return suppress_subscription_keys.contains(get_subscription_suppression_key(account, jid));
    }

    public void request_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY).request_subscription(stream, jid.bare_jid);
    }

    public bool supports_subscription_preapproval(Account account) {
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) return false;
        Xmpp.Presence.Module? module = ((!) stream).get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY);
        return module != null && ((!) module).supports_subscription_preapproval((!) stream);
    }

    // Both directions require a deliberate user action. A successful return
    // means these writes completed; roster pushes still own subscription state.
    public async MutualSubscriptionResult request_mutual_subscription(
            Account account, Jid jid, bool grant_presence,
            string? preauth_token = null) throws IOError {
        Jid bare = jid.bare_jid;
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("The account is not connected");
        Xmpp.Presence.Module? module = ((!) stream).get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_CONNECTED("The presence module is unavailable");
        string key = get_subscription_request_key(account, bare);
        if (!active_subscription_actions.add(key)) {
            throw new IOError.PENDING("A subscription action is already running");
        }
        try {
            Xmpp.Roster.Flag? roster = ((!) stream).get_flag(Xmpp.Roster.Flag.IDENTITY);
            Xmpp.Roster.Item? item = roster != null ? ((!) roster).get_item(bare) : null;
            bool receives_presence = item != null &&
                (item.subscription == Xmpp.Roster.Item.SUBSCRIPTION_TO ||
                 item.subscription == Xmpp.Roster.Item.SUBSCRIPTION_BOTH);
            bool shares_presence = item != null &&
                (item.subscription == Xmpp.Roster.Item.SUBSCRIPTION_FROM ||
                 item.subscription == Xmpp.Roster.Item.SUBSCRIPTION_BOTH);
            bool outgoing_pending = item != null && item.ask == "subscribe";
            MutualSubscriptionResult result = MutualSubscriptionResult.REQUESTED;

            if (grant_presence) {
                bool incoming_pending = exists_subscription_request(account, bare);
                if (shares_presence) {
                    remove_subscription_request(account, bare);
                    result = MutualSubscriptionResult.ALREADY_GRANTED;
                } else if (!incoming_pending && item != null && (item.stanza_node.get_attribute("approved") == "true" ||
                        item.stanza_node.get_attribute("approved") == "1")) {
                    // This pre-approval was confirmed by the server. It is
                    // distinct from FROM/BOTH and needs no repeated grant.
                    result = MutualSubscriptionResult.PREAPPROVED;
                } else if (incoming_pending || ((!) module).supports_subscription_preapproval((!) stream)) {
                    var approval = new Xmpp.Presence.Stanza() {
                        to = bare,
                        type_ = Xmpp.Presence.Stanza.TYPE_SUBSCRIBED
                    };
                    yield ((!) module).send_presence_async((!) stream, approval);
                    ensure_subscription_action_stream(account, (!) stream);
                    if (incoming_pending) remove_subscription_request(account, bare);
                    result = incoming_pending ? MutualSubscriptionResult.PENDING_APPROVED
                        : MutualSubscriptionResult.PREAPPROVED;
                } else {
                    // RFC 6121 section 3.4.1 forbids unsolicited subscribed
                    // when the server did not advertise pre-approval support.
                    result = MutualSubscriptionResult.MANUAL_APPROVAL_REQUIRED;
                }
            }

            if (!receives_presence && !outgoing_pending) {
                ensure_subscription_action_stream(account, (!) stream);
                var request = new Xmpp.Presence.Stanza() {
                    to = bare,
                    type_ = Xmpp.Presence.Stanza.TYPE_SUBSCRIBE
                };
                if (preauth_token != null && preauth_token.length > 0) {
                    request.stanza.put_node(new StanzaNode.build("preauth", Xep.InBandRegistration.NS_URI_PARS)
                        .add_self_xmlns().put_attribute("token", preauth_token));
                }
                yield ((!) module).send_presence_async((!) stream, request);
                ensure_subscription_action_stream(account, (!) stream);
            }
            return result;
        } finally {
            active_subscription_actions.remove(key);
        }
    }

    private void ensure_subscription_action_stream(Account account,
            XmppStream stream) throws IOError {
        if (stream_interactor.get_connected_stream_for_action(account) != stream) {
            throw new IOError.NOT_CONNECTED("The account connection changed during the subscription action");
        }
    }

    private void remove_subscription_request(Account account, Jid jid) {
        if (subscription_requests.remove(get_subscription_request_key(account, jid))) {
            subscription_requests_changed(jid.bare_jid, account);
        }
    }

    public void request_subscription_with_preauth(Account account, Jid jid, string token) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY).request_subscription_with_preauth(stream, jid.bare_jid, token);
    }

    public void approve_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY).approve_subscription(stream, jid.bare_jid);
            remove_subscription_request(account, jid);
        }
    }

    public void deny_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY).deny_subscription(stream, jid.bare_jid);
            remove_subscription_request(account, jid);
        }
    }

    public async void deny_subscription_async(Account account, Jid jid) throws IOError {
        XmppStream? stream = stream_interactor.get_connected_stream_for_action(account);
        if (stream == null) throw new IOError.NOT_CONNECTED("The account is not connected");
        // A delayed notification action may outlive a grant on another own
        // client. Denying that stale request must not revoke an active grant.
        if (!exists_subscription_request(account, jid)) return;
        Xmpp.Presence.Module? module = ((!) stream).get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY);
        if (module == null) throw new IOError.NOT_CONNECTED("The presence module is unavailable");
        string key = get_subscription_request_key(account, jid);
        if (!active_subscription_actions.add(key)) {
            throw new IOError.PENDING("A subscription action is already running");
        }
        try {
            var denial = new Xmpp.Presence.Stanza() {
                to = jid.bare_jid,
                type_ = Xmpp.Presence.Stanza.TYPE_UNSUBSCRIBED
            };
            yield ((!) module).send_presence_async((!) stream, denial);
            ensure_subscription_action_stream(account, (!) stream);
            remove_subscription_request(account, jid);
        } finally {
            active_subscription_actions.remove(key);
        }
    }

    public void cancel_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) stream.get_module<Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY).cancel_subscription(stream, jid.bare_jid);
    }

    private void on_account_added(Account account) {
        apply_pending_subscription_suppressions(account);

        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).pre_send_presence_stanza.connect(on_pre_send_presence);
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_available.connect((stream, presence) =>
            on_received_available(account, presence.from)
        );
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_unavailable.connect((stream, presence) =>
            on_received_unavailable(account, presence.from)
        );
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_subscription_request.connect((stream, jid) => {
            if (stream_interactor.get_connected_stream_for_action(account) != stream) return;
            Jid bare_jid = jid.bare_jid;
            if (subscription_requests.add(get_subscription_request_key(account, bare_jid))) {
                subscription_requests_changed(bare_jid, account);
            }
            received_subscription_request(bare_jid, account);
        });
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_subscription_approval.connect((stream, jid) => {
            if (stream_interactor.get_connected_stream_for_action(account) != stream) return;
            received_subscription_approval(jid.bare_jid, account);
        });
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_unsubscription.connect((stream, jid) => {
            if (stream_interactor.get_connected_stream_for_action(account) != stream) return;
            remove_subscription_request(account, jid);
        });
        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).item_updated.connect_after((stream, item) => {
            if (stream_interactor.get_connected_stream_for_action(account) != stream) return;
            clear_approved_subscription_request(account, item);
        });
        stream_interactor.module_manager.get_module<Roster.Module>(account, Roster.Module.IDENTITY).received_roster.connect_after((stream, items) => {
            if (stream_interactor.get_connected_stream_for_action(account) != stream) return;
            foreach (Roster.Item item in items) clear_approved_subscription_request(account, item);
        });
    }

    private void clear_approved_subscription_request(Account account,
            Roster.Item item) {
        if (item.jid != null && (item.subscription == Roster.Item.SUBSCRIPTION_FROM ||
                item.subscription == Roster.Item.SUBSCRIPTION_BOTH)) {
            remove_subscription_request(account, item.jid);
        }
    }

    private void on_account_removed(Account account) {
        string subscription_prefix = account.id.to_string() + ":";
        var stale_requests = new ArrayList<string>();
        foreach (string key in subscription_requests) {
            if (key.has_prefix(subscription_prefix)) stale_requests.add(key);
        }
        foreach (string key in stale_requests) {
            try {
                remove_subscription_request(account, new Jid(key.substring(subscription_prefix.length)));
            } catch (InvalidJidError e) {
                subscription_requests.remove(key);
            }
        }
        string prefix = account.id.to_string() + "\n";
        var observers = new ArrayList<PresenceObserver>();
        foreach (var entry in presence_observers.entries) {
            if (entry.key.has_prefix(prefix)) observers.add_all(entry.value.values);
        }
        foreach (PresenceObserver observer in observers) observer.unsubscribe();
    }

    /**
     * Inject current status into outgoing initial presence.
     * This covers broadcast presence after stream negotiation and MUC join
     * presence, so rejoining a room preserves the selected status.
     */
    private void on_pre_send_presence(XmppStream stream, Xmpp.Presence.Stanza presence) {
        if (presence.type_ != Xmpp.Presence.Stanza.TYPE_AVAILABLE) return;

        bool is_broadcast_presence = presence.to == null;
        bool is_muc_join_presence = presence.to != null && presence.stanza.get_subnode("x", MUC_NS_URI) != null;
        if (!is_broadcast_presence && !is_muc_join_presence) return;

        apply_current_status_to_presence(presence, true);
    }

    private void apply_current_status_to_presence(Xmpp.Presence.Stanza presence, bool preserve_existing) {
        if (current_show != "online" && (!preserve_existing || presence.show == null || presence.show == "online")) {
            presence.show = current_show;
        }
        if (current_status_msg != null && current_status_msg.strip() != "" && (!preserve_existing || presence.status == null)) {
            presence.status = current_status_msg;
        }
    }

    private void on_received_available(Account account, Jid jid) {
        show_received(jid, account);
        notify_presence_observers(account, jid, true);
    }

    private void on_received_unavailable(Account account, Jid jid) {
        received_offline_presence(jid, account);
        notify_presence_observers(account, jid, false);
    }

    private void notify_presence_observers(Account account, Jid jid, bool available) {
        notify_presence_observer_key(presence_observer_key(account.id, jid), jid, account, available);
        if (jid.is_full()) {
            notify_presence_observer_key(presence_observer_key(account.id, jid.bare_jid), jid, account, available);
        }
    }

    private void notify_presence_observer_key(string key, Jid jid, Account account, bool available) {
        if (!presence_observers.has_key(key)) return;

        var observers = new ArrayList<PresenceObserver>();
        observers.add_all(presence_observers[key].values);
        foreach (PresenceObserver observer in observers) {
            if (!observer.dispatch(jid, account, available)) observer.unsubscribe();
        }
    }

    private string presence_observer_key(int account_id, Jid jid) {
        return account_id.to_string() + "\n" + jid.to_string();
    }

    private void apply_pending_subscription_suppressions(Account account) {
        string account_key = account.bare_jid.to_string();
        if (!pending_suppressions_by_account_jid.has_key(account_key)) return;

        foreach (string jid_str in pending_suppressions_by_account_jid[account_key]) {
            try {
                suppress_subscription_notification(account, new Jid(jid_str));
            } catch (Error e) {
                warning("Ignoring invalid pending subscription suppression JID %s: %s", jid_str, e.message);
            }
        }
        pending_suppressions_by_account_jid.unset(account_key);
    }

    private string get_subscription_request_key(Account account, Jid jid) {
        return @"$(account.id):$(jid.bare_jid.to_string())";
    }

    private string get_subscription_suppression_key(Account account, Jid jid) {
        return @"$(account.id):$(jid.bare_jid.to_string())";
    }
}
}
