using Gee;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;
using Qlite;

public class Dino.HistorySync {

    public enum FetchResult {
        ERROR,
        CANCELLED,
        SUCCESS,
        UNAVAILABLE,
        SUCCESS_WITH_OMEMO_FAILURES
    }

    public signal void account_archive_sync_finished(Account account,
        XmppStream stream, FetchResult result);

    /**
     * Keeps cancellation out of Vala's generated outer GTask.
     *
     * A bare Cancellable parameter can make GTask replace a deliberately
     * returned FetchResult/out value with its implicit zero value.  History
     * sync must instead observe cancellation inside the coroutine and return a
     * deterministic CANCELLED result to its serialized MUC owner.
     */
    public class FetchCancellation : Object {
        public Cancellable? cancellable { get; private set; }
        internal ReloadReport? reload_report { get; set; default = null; }

        public FetchCancellation(Cancellable? cancellable) {
            this.cancellable = cancellable;
        }
    }

    // Only explicit reloads carry this report. Live and automatic offline
    // delivery never inherit a conversation-wide "ignore errors" switch.
    internal class ReloadReport : Object {
        private const string OMEMO_FAILURE = "[This OMEMO message could not be decrypted]";
        private Conversation target;
        private Account account;
        private int account_id;
        private int conversation_id;
        private Conversation.Type type_;
        private Jid peer;
        internal bool has_omemo_failures { get; private set; default = false; }

        internal ReloadReport(Conversation target) {
            this.target = target;
            account = target.account;
            account_id = account.id;
            conversation_id = target.id;
            type_ = target.type_;
            peer = target.counterpart.bare_jid;

        }

        private bool target_is_current() {
            return account.id == account_id && target.account == account &&
                target.id == conversation_id && target.type_ == type_ &&
                target.counterpart.equals_bare(peer);
        }

        internal bool summarize_failure(Xmpp.MessageStanza stanza,
                Entities.Message? message, Conversation? context) {
            if (!target_is_current() || message == null || context == null ||
                    ((!) context).id != conversation_id ||
                    ((!) context).account != account || ((!) context).type_ != type_ ||
                    !((!) context).counterpart.equals_bare(peer) ||
                    ((!) message).account != account ||
                    !((!) message).counterpart.equals_bare(peer) ||
                    ((!) message).encryption != Encryption.OMEMO ||
                    !((!) message).decryption_failed ||
                    (((!) message).body != OMEMO_FAILURE &&
                     ((!) message).body != null)) return false;
            var mam = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
            Jid archive = type_ == Conversation.Type.GROUPCHAT
                ? peer : account.bare_jid;
            if (mam == null || !mam.sender_jid.equals_bare(archive)) return false;
            has_omemo_failures = true;
            return true;
        }

    }

    private class ReloadQueryCancellation : Xmpp.MessageArchiveManagement.QueryCancellation {
        internal ReloadReport? report;

        internal ReloadQueryCancellation(Cancellable? cancellable, ReloadReport? report) {
            base(cancellable);
            this.report = report;
        }
    }

    private static bool fetch_is_cancelled(FetchCancellation? cancellation) {
        if (cancellation == null) return false;
        Cancellable? cancellable = ((!) cancellation).cancellable;
        return cancellable != null && ((!) cancellable).is_cancelled();
    }

    private static bool query_is_cancelled(
            Xmpp.MessageArchiveManagement.QueryCancellation? cancellation) {
        if (cancellation == null) return false;
        Cancellable? cancellable = ((!) cancellation).cancellable;
        return cancellable != null && ((!) cancellable).is_cancelled();
    }

    private static string mam_time_key(string query_id, string mam_id) {
        // Archive IDs are scoped to one MAM query/archive and may collide
        // between the account archive and a room archive. The length prefix
        // keeps this composite key unambiguous without relying on a delimiter
        // that arbitrary server-provided IDs could contain.
        return query_id.length.to_string() + ":" + query_id + mam_id;
    }

    private DateTime? get_mam_time(Account account, string query_id,
            string mam_id) {
        string key = mam_time_key(query_id, mam_id);
        return mam_times.has_key(account) && mam_times[account].has_key(key)
            ? mam_times[account][key] : null;
    }

    private StreamInteractor stream_interactor;
    private Database db;
    private const int BACKGROUND_MAM_PAGE_SIZE = 50;
    private const int MAM_PIPELINE_BATCH_SIZE = 8;
    private ArrayList<AccountReadinessGate> readiness_gates =
        new ArrayList<AccountReadinessGate>();

    public HashMap<Account, HashMap<Jid, int>> current_catchup_id = new HashMap<Account, HashMap<Jid, int>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> live_cursor_generations =
        new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func,
            Account.equals_func);
    public WeakMap<Account, XmppStream> sync_streams = new WeakMap<Account, XmppStream>(Account.hash_func, Account.equals_func);
    private WeakMap<Account, XmppStream> settled_account_streams =
        new WeakMap<Account, XmppStream>(Account.hash_func,
            Account.equals_func);
    public HashMap<Account, HashMap<Jid, Cancellable>> cancellables = new HashMap<Account, HashMap<Jid, Cancellable>>(Account.hash_func, Account.equals_func);
    public HashMap<Account, HashMap<string, DateTime>> mam_times = new HashMap<Account, HashMap<string, DateTime>>();
    private HashMap<Account, int> active_history_fetches = new HashMap<Account, int>(Account.hash_func, Account.equals_func);
    public HashMap<string, int> hitted_range = new HashMap<string, int>();
    internal bool auto_fetch_enabled { get; set; default = true; }

    // Server ID of the latest message of the previous segment
    public HashMap<Account, string> catchup_until_id = new HashMap<Account, string>(Account.hash_func, Account.equals_func);
    // Time of the latest message of the previous segment
    public HashMap<Account, DateTime> catchup_until_time = new HashMap<Account, DateTime>(Account.hash_func, Account.equals_func);

    // Minimum time for MAM sync. After a panic wipe, this is set to the wipe
    // timestamp so that old messages are not re-fetched from the server archive.
    // For fresh installs (no panic wipe), defaults to 30 days ago.
    public DateTime sync_not_before { get; set; default = new DateTime.now_utc().add_days(-30); }
    public DateTime? panic_sync_not_before { get; private set; default = null; }

    public void set_panic_sync_floor(DateTime floor) {
        panic_sync_not_before = floor;
        // Auto keeps the established setter semantics, even for an old wipe
        // marker. An explicit room period overrides only the soft default.
        sync_not_before = floor;
    }

    private class DirectHistoryRequest : Object {
        public Account account;
        public Conversation conversation;
        public XmppStream stream;
        public int account_id;
        public int conversation_id;
        public Jid archive;
        public Jid peer;
        public DateTime? floor = null;
        public string key;
        public Cancellable cancellable = new Cancellable();
        public ReloadReport? reload_report = null;
        private weak HistorySync owner;
        private ulong conversation_handler = 0;
        private ulong account_handler = 0;

        public DirectHistoryRequest(HistorySync owner, Conversation conversation,
                XmppStream stream) throws InvalidJidError {
            this.owner = owner;
            this.conversation = conversation;
            this.account = conversation.account;
            this.stream = stream;
            account_id = account.id;
            conversation_id = conversation.id;
            archive = new Jid.components(account.bare_jid.localpart,
                account.bare_jid.domainpart, null);
            peer = new Jid.components(conversation.counterpart.localpart,
                conversation.counterpart.domainpart, null);
            key = account_id.to_string() + ":" + conversation_id.to_string();
            conversation_handler = conversation.notify.connect(on_target_notify);
            account_handler = account.notify.connect(on_account_notify);
        }

        private void on_target_notify(Object object, ParamSpec spec) {
            if (spec.name == "id" || spec.name == "type-" ||
                    spec.name == "account" || spec.name == "counterpart") {
                if (owner == null || !owner.is_direct_request_current(this)) {
                    cancellable.cancel();
                }
            }
        }

        private void on_account_notify(Object object, ParamSpec spec) {
            if (spec.name == "id" || spec.name == "bare-jid" ||
                    spec.name == "enabled") {
                if (owner == null || !owner.is_direct_request_current(this)) {
                    cancellable.cancel();
                }
            }
        }

        public void finish() {
            if (conversation_handler != 0) {
                SignalHandler.disconnect(conversation, conversation_handler);
                conversation_handler = 0;
            }
            if (account_handler != 0) {
                SignalHandler.disconnect(account, account_handler);
                account_handler = 0;
            }
        }
    }

    private HashMap<string, DirectHistoryRequest> direct_history_requests =
        new HashMap<string, DirectHistoryRequest>();

    private bool is_durable_direct_target(Conversation conversation) {
        if (conversation.type_ != Conversation.Type.CHAT ||
                !conversation.matches_persisted_identity(db) ||
                conversation.account.id <= 0) return false;
        if (db.account.select()
                .with(db.account.id, "=", conversation.account.id)
                .with(db.account.bare_jid, "=",
                    conversation.account.bare_jid.to_string()).count() != 1) {
            return false;
        }
        return db.conversation.select()
            .with(db.conversation.id, "=", conversation.id)
            .with(db.conversation.account_id, "=", conversation.account.id)
            .with(db.conversation.type_, "=", (int) Conversation.Type.CHAT)
            .join_with(db.jid, db.conversation.jid_id, db.jid.id)
            .with(db.jid.bare_jid, "=",
                conversation.counterpart.bare_jid.to_string()).count() == 1;
    }

    private bool is_direct_request_current(DirectHistoryRequest request) {
        return direct_history_requests.has_key(request.key) &&
            direct_history_requests[request.key] == request &&
            !request.cancellable.is_cancelled() &&
            request.account.enabled && request.account.id == request.account_id &&
            request.conversation.id == request.conversation_id &&
            request.conversation.account == request.account &&
            request.account.bare_jid.equals_bare(request.archive) &&
            request.conversation.counterpart.equals_bare(request.peer) &&
            is_durable_direct_target(request.conversation) &&
            is_account_ready(request.account) &&
            stream_interactor.get_stream(request.account) == request.stream;
    }

    private bool direct_message_matches(DirectHistoryRequest request,
            Xmpp.MessageStanza message) {
        var archive = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message);
        Jid? from = message.from;
        Jid? to = message.to;
        if (archive == null || !archive.sender_jid.equals(request.archive) ||
                archive.server_time == null || request.floor == null ||
                ((!) archive.server_time).compare((!) request.floor) < 0 ||
                from == null || to == null ||
                (message.type_ != MessageStanza.TYPE_CHAT &&
                 message.type_ != MessageStanza.TYPE_NORMAL)) return false;
        // A bare-peer filter includes all resources, in either direction.
        // Keep the direction pairs intact, including self-conversations.
        return (((!) from).equals_bare(request.peer) &&
                ((!) to).equals_bare(request.archive)) ||
            (((!) from).equals_bare(request.archive) &&
                ((!) to).equals_bare(request.peer));
    }

    public async FetchResult refresh_direct_conversation(Conversation conversation) {
        DateTime requested_at = new DateTime.now_utc();
        if (!is_durable_direct_target(conversation)) return FetchResult.UNAVAILABLE;
        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (!conversation.account.enabled || stream == null ||
                !is_account_ready(conversation.account)) return FetchResult.UNAVAILABLE;
        DirectHistoryRequest request;
        try {
            request = new DirectHistoryRequest(this, conversation, (!) stream);
        } catch (InvalidJidError error) {
            return FetchResult.UNAVAILABLE;
        }
        request.reload_report = new ReloadReport(conversation);
        if (direct_history_requests.has_key(request.key)) {
            direct_history_requests[request.key].cancellable.cancel();
        }
        direct_history_requests[request.key] = request;
        begin_history_fetch(request.account);
        try {
            bool supported = yield stream_interactor.get_module<EntityInfo>(
                EntityInfo.IDENTITY).has_feature(request.account,
                    request.archive, Xmpp.MessageArchiveManagement.NS_URI);
            if (!is_direct_request_current(request)) return FetchResult.CANCELLED;
            if (!supported) return FetchResult.UNAVAILABLE;
            if (!stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY).prepare_history_restore(
                        conversation, requested_at) ||
                    !is_direct_request_current(request)) return FetchResult.CANCELLED;
            DateTime floor = sync_not_before;
            if (panic_sync_not_before != null &&
                    ((!) panic_sync_not_before).compare(floor) > 0) {
                floor = (!) panic_sync_not_before;
            }
            if (conversation.history_cleared_at != null &&
                    ((!) conversation.history_cleared_at).compare(floor) > 0) {
                floor = (!) conversation.history_cleared_at;
            }
            if (conversation.message_expiry_seconds > 0) {
                DateTime expiry = new DateTime.now_utc().add_seconds(
                    -conversation.message_expiry_seconds);
                if (expiry.compare(floor) > 0) floor = expiry;
            }
            request.floor = floor;
            var query = new Xmpp.MessageArchiveManagement.V2.MamQueryParams
                .query_latest(request.archive, floor, null) {
                    with = request.peer, max_items = BACKGROUND_MAM_PAGE_SIZE
                };
            PageRequestResult? previous = null;
            var cancellation = new ReloadQueryCancellation(
                request.cancellable, request.reload_report);
            do {
                if (!is_direct_request_current(request)) return FetchResult.CANCELLED;
                PageRequestResult page = yield get_mam_page(request.account,
                    query, previous, cancellation, request);
                if (!is_direct_request_current(request) ||
                        page.page_result == PageResult.Cancelled) return FetchResult.CANCELLED;
                if (page.page_result == PageResult.Error) return FetchResult.ERROR;
                if (page.page_result == PageResult.NoMoreMessages) {
                    return ((!) request.reload_report).has_omemo_failures
                        ? FetchResult.SUCCESS_WITH_OMEMO_FAILURES : FetchResult.SUCCESS;
                }
                // Incomplete empty/repeated pages cannot make RSM progress.
                if (page.query_result.first == null ||
                        (previous != null && page.query_result.first ==
                            ((!) previous).query_result.first)) return FetchResult.ERROR;
                previous = page;
            } while (true);
        } finally {
            if (direct_history_requests.has_key(request.key) &&
                    direct_history_requests[request.key] == request) {
                direct_history_requests.unset(request.key);
            }
            request.finish();
            end_history_fetch(request.account);
        }
    }

    private HashMap<string, Gee.List<Xmpp.MessageStanza>> stanzas = new HashMap<string, Gee.List<Xmpp.MessageStanza>>();
    private WeakMap<string, XmppStream> stanza_streams =
        new WeakMap<string, XmppStream>();

    public HistorySync(Database db, StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        this.db = db;

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect((account) => {
            settled_account_streams.unset(account);
            live_cursor_generations.unset(account);
            var keys = new ArrayList<string>();
            keys.add_all(direct_history_requests.keys);
            foreach (string key in keys) {
                DirectHistoryRequest request = direct_history_requests[key];
                if (request.account_id == account.id) {
                    request.cancellable.cancel();
                    direct_history_requests.unset(key);
                }
            }
        });

        stream_interactor.stream_negotiated.connect(begin_account_archive_sync);
        // A resumed SM stream replays queued stanzas only after <resumed/>.
        // Run the same account-archive fence so lifecycle consumers cannot
        // treat the resume signal itself as authoritative catch-up completion.
        stream_interactor.stream_resumed.connect(begin_account_archive_sync);
    }

    private void begin_account_archive_sync(Account account,
            XmppStream stream) {
        settled_account_streams.unset(account);
        if (current_catchup_id.has_key(account)) {
            debug("MAM: [%s] Reset catchup_id", account.bare_jid.to_string());
            current_catchup_id[account].clear();
        }
        maybe_fetch_account_archive.begin(account, stream);
    }

    public void add_readiness_gate(AccountReadinessGate gate) {
        readiness_gates.add(gate);
        gate.readiness_changed.connect((account) => {
            on_readiness_changed(account);
        });
    }

    internal bool is_account_ready(Account account) {
        foreach (AccountReadinessGate gate in readiness_gates) {
            if (!gate.is_ready(account)) return false;
        }
        return true;
    }

    private void on_readiness_changed(Account account) {
        if (!is_account_ready(account)) {
            var direct_requests = new ArrayList<DirectHistoryRequest>();
            direct_requests.add_all(direct_history_requests.values);
            foreach (DirectHistoryRequest request in direct_requests) {
                if (request.account_id == account.id) request.cancellable.cancel();
            }
            // Cancellation fences an in-flight page before its result can
            // advance a MAM range.  The owning account/MUC synchronizer keeps
            // its normal retry intent and observes CANCELLED/ERROR.
            if (cancellables.has_key(account)) {
                var to_cancel = new ArrayList<Cancellable>();
                to_cancel.add_all(cancellables[account].values);
                foreach (Cancellable cancellable in to_cancel) {
                    cancellable.cancel();
                }
            }
            sync_streams.unset(account);
            return;
        }

        // A store may become ready after stream feature discovery (for
        // example while a newly persisted Account receives its database id).
        // Re-run the cached feature check without waiting for a reconnect.
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            maybe_fetch_account_archive.begin(account, (!) stream);
        }
    }

    private void begin_history_fetch(Account account) {
        int active_count = active_history_fetches.has_key(account)
            ? active_history_fetches[account] : 0;
        active_history_fetches[account] = active_count + 1;
    }

    private void end_history_fetch(Account account) {
        if (!active_history_fetches.has_key(account)) return;

        int active_count = active_history_fetches[account] - 1;
        if (active_count > 0) {
            active_history_fetches[account] = active_count;
            return;
        }

        active_history_fetches.unset(account);

        // MAM result timestamps are shared by all concurrent queries of an
        // account.  Clear them only after the last account-wide or MUC fetch
        // has consumed its own page result and updated the DB range.
        if (mam_times.has_key(account)) {
            int old_size = mam_times[account].size;
            mam_times[account].clear();
            if (old_size > 100) {
                debug("[%s] Cleared %d mam_times entries after all syncs", account.bare_jid.to_string(), old_size);
            }
        }
    }

    public bool process(Account account, XmppStream stream,
            Xmpp.MessageStanza message_stanza) {
        var mam_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message_stanza);

        if (mam_flag != null) {
            process_mam_message(account, stream, message_stanza, mam_flag);
            return true;
        } else {
            // Live cursor progress belongs to the admitted message pipeline.
            // While a profile snapshot drains older messages, new arrivals
            // must not advance a cursor before their own pipeline can run.
            return false;
        }
    }

    internal uint get_live_cursor_generation(Account account, Jid archive) {
        Jid bare_archive = archive.bare_jid;
        return live_cursor_generations.has_key(account) &&
            live_cursor_generations[account].has_key(bare_archive)
            ? live_cursor_generations[account][bare_archive] : 0;
    }

    internal void invalidate_live_cursor(Account account, Jid archive) {
        Jid bare_archive = archive.bare_jid;
        if (current_catchup_id.has_key(account)) {
            current_catchup_id[account].unset(bare_archive);
        }
        if (!live_cursor_generations.has_key(account)) {
            live_cursor_generations[account] = new HashMap<Jid, uint>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        uint next = get_live_cursor_generation(account, bare_archive) + 1;
        if (next == 0) next = 1;
        // Increment even without a published cursor: an in-flight first page
        // must not publish coverage after its room visit has ended.
        live_cursor_generations[account][bare_archive] = next;
    }

    internal void reset_muc_history_coverage(Account account, Jid room) {
        // Direct chats share the account archive and must never use this:
        // their explicit peer-filtered refresh already ignores global ranges.
        if (room.equals_bare(account.bare_jid)) return;
        invalidate_live_cursor(account, room);
        db.mam_catchup.delete()
            .with(db.mam_catchup.account_id, "=", account.id)
            .with(db.mam_catchup.server_jid, "=", room.bare_jid.to_string())
            .perform();
    }

    private bool is_live_cursor_scope_current(Account account, Jid archive,
            uint generation, XmppStream? expected_stream) {
        return get_live_cursor_generation(account, archive) == generation &&
            stream_interactor.get_stream(account) == expected_stream;
    }

    private FetchResult publish_completed_live_range(Account account,
            Jid archive, int row_id, uint generation,
            XmppStream? expected_stream) {
        if (!is_live_cursor_scope_current(account, archive, generation,
                expected_stream)) return FetchResult.CANCELLED;
        if (row_id >= 0) {
            if (!current_catchup_id.has_key(account)) {
                current_catchup_id[account] = new HashMap<Jid, int>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
            }
            current_catchup_id[account][archive.bare_jid] = row_id;
        }
        return FetchResult.SUCCESS;
    }

    private static bool query_reaches_archive_start(
            Xmpp.MessageArchiveManagement.V2.MamQueryParams query_params) {
        // complete=true ends the filtered result set, not necessarily the
        // archive. Upper bounds still permit finding its oldest item, but
        // time/ID lower bounds and a peer filter do not.
        return query_params.start == null && query_params.start_id == null &&
            query_params.with == null;
    }

    public void update_latest_db_range(Account account, Xmpp.MessageStanza message_stanza) {
        if (!is_account_ready(account)) return;

        Jid mam_server = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(message_stanza.from.bare_jid, account) ? message_stanza.from.bare_jid : account.bare_jid;

        if (!current_catchup_id.has_key(account) || !current_catchup_id[account].has_key(mam_server)) return;

        string? stanza_id = UniqueStableStanzaIDs.get_stanza_id(message_stanza, mam_server);
        if (stanza_id == null) return;

        db.mam_catchup.update()
                .with(db.mam_catchup.id, "=", current_catchup_id[account][mam_server])
                .set(db.mam_catchup.to_time, (long)new DateTime.now_utc().to_unix())
                .set(db.mam_catchup.to_id, stanza_id)
                .perform();
    }

    public void process_mam_message(Account account, XmppStream stream,
            Xmpp.MessageStanza message_stanza,
            Xmpp.MessageArchiveManagement.MessageFlag mam_flag) {
        Jid mam_server = mam_flag.sender_jid;
        Jid message_author = message_stanza.from;

        // MUC servers may only send MAM messages from that MUC
        bool is_muc_mam = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(mam_server, account) &&
                message_author.equals_bare(mam_server);

        bool from_our_server = mam_server.equals_bare(account.bare_jid);

        if (!is_muc_mam && !from_our_server) {
            warning("Received alleged MAM message from %s, ignoring", mam_server.to_string());
            return;
        }

        XmppStream? query_stream = stanza_streams[mam_flag.query_id];
        if (query_stream == null && stanzas.has_key(mam_flag.query_id)) {
            clear_query_stanzas(mam_flag.query_id);
        }
        if (query_stream != null && query_stream != stream) {
            warning("Ignoring MAM query-id collision across streams: %s",
                mam_flag.query_id);
            return;
        }
        if (!stanzas.has_key(mam_flag.query_id)) {
            stanzas[mam_flag.query_id] = new ArrayList<Xmpp.MessageStanza>();
            stanza_streams[mam_flag.query_id] = stream;
        }
        stanzas[mam_flag.query_id].add(message_stanza);
    }

    private void clear_query_stanzas(string query_id) {
        stanzas.unset(query_id);
        stanza_streams.unset(query_id);
    }

    private void on_unprocessed_message(Account account, XmppStream stream, MessageStanza message) {
        if (stream_interactor.get_stream(account) != stream) return;

        // Check that it's a legit MAM server
        bool is_muc_mam = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(message.from, account);
        bool from_our_server = message.from.equals_bare(account.bare_jid);
        if (!is_muc_mam && !from_our_server) return;

        // Get the server time of the message and store it in `mam_times`
        string? id = message.stanza.get_deep_attribute(Xmpp.MessageArchiveManagement.NS_URI + ":result", "id");
        if (id == null) return;
        StanzaNode? delay_node = message.stanza.get_deep_subnode(Xmpp.MessageArchiveManagement.NS_URI + ":result", StanzaForwarding.NS_URI + ":forwarded", DelayedDelivery.NS_URI + ":delay");
        if (delay_node == null) {
            warning("MAM result did not contain delayed time %s", message.stanza.to_string());
            return;
        }
        DateTime? time = DelayedDelivery.get_time_for_node(delay_node);
        if (time == null) return;
        string? query_id = message.stanza.get_deep_attribute(Xmpp.MessageArchiveManagement.NS_URI + ":result", Xmpp.MessageArchiveManagement.NS_URI + ":queryid");
        if (query_id == null) return;
        mam_times[account][mam_time_key((!) query_id, id)] = time;

        // Check if this is the target message
        if (id == catchup_until_id[account]) {
            debug("[%s] Hitted range (id) %s", account.bare_jid.to_string(), id);
            hitted_range[(!) query_id] = -2;
        }
    }

    public void on_server_id_duplicate(Account account, Xmpp.MessageStanza message_stanza, Entities.Message message) {
        Xmpp.MessageArchiveManagement.MessageFlag? mam_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message_stanza);
        if (mam_flag == null) return;

//        debug(@"MAM: [%s] Hitted range duplicate server id. id %s qid %s", account.bare_jid.to_string(), message.server_id, mam_flag.query_id);
        if (catchup_until_time.has_key(account) && mam_flag.server_time.compare(catchup_until_time[account]) < 0) {
            hitted_range[mam_flag.query_id] = -1;
//            debug(@"MAM: [%s] In range (time) %s < %s", account.bare_jid.to_string(), mam_flag.server_time.to_string(), catchup_until_time[account].to_string());
        }
    }

    public async FetchResult fetch_everything(Account account, Jid mam_server,
            FetchCancellation? cancellation = null,
            DateTime until_earliest_time = new DateTime.from_unix_utc(0)) {
        begin_history_fetch(account);
        try {
        if (!is_account_ready(account)) return FetchResult.ERROR;
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;
        if (cancellable != null && ((!) cancellable).is_cancelled()) {
            return FetchResult.CANCELLED;
        }
        uint cursor_generation = get_live_cursor_generation(account,
            mam_server);
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        // A live cursor is valid only once the entire requested gap has been
        // processed. New arrivals while a page is pending must not turn an
        // old range into proof of continuity across that gap.
        if (current_catchup_id.has_key(account)) {
            current_catchup_id[account].unset(mam_server.bare_jid);
        }
        debug("[%s | %s] Fetch everything %s", account.bare_jid.to_string(), mam_server.to_string(), until_earliest_time != null ? @"(until $until_earliest_time)" : "");
        RowOption latest_row_opt = db.mam_catchup.select()
                .with(db.mam_catchup.account_id, "=", account.id)
                .with(db.mam_catchup.server_jid, "=", mam_server.to_string())
                .with(db.mam_catchup.to_time, ">=", (long) until_earliest_time.to_unix())
                .order_by(db.mam_catchup.to_time, "DESC")
                .single().row();
        Row? latest_row = latest_row_opt.is_present() ? latest_row_opt.inner : null;

        FetchResult latest_result;
        Row? new_row = yield fetch_latest_page(account, mam_server,
            latest_row, until_earliest_time, cancellation,
            out latest_result);
        if (fetch_is_cancelled(cancellation)) return FetchResult.CANCELLED;
        if (latest_result != FetchResult.SUCCESS) return latest_result;
        if (!is_live_cursor_scope_current(account, mam_server,
                cursor_generation, expected_stream)) {
            return FetchResult.CANCELLED;
        }

        int latest_row_id = new_row != null ? new_row[db.mam_catchup.id]
            : latest_row != null ? latest_row[db.mam_catchup.id] : -1;

        // Set the previous and current row
        Row? previous_row = null;
        Row? current_row = null;
        if (new_row != null) {
            current_row = new_row;
            previous_row = latest_row;
        } else if (latest_row != null) {
            current_row = latest_row;
            RowOption previous_row_opt = db.mam_catchup.select()
                    .with(db.mam_catchup.account_id, "=", account.id)
                    .with(db.mam_catchup.server_jid, "=", mam_server.to_string())
                    .with(db.mam_catchup.to_time, "<", current_row[db.mam_catchup.from_time])
                    .with(db.mam_catchup.to_time, ">=", (long) until_earliest_time.to_unix())
                    .order_by(db.mam_catchup.to_time, "DESC")
                    .single().row();
            previous_row = previous_row_opt.is_present() ? previous_row_opt.inner : null;
        }

        // Fetch messages between two db ranges and merge them
        while (current_row != null && previous_row != null) {
            if (current_row[db.mam_catchup.from_end]) {
                debug("[%s | %s] No logs on server before %s, aborting sync.", account.bare_jid.to_string(), mam_server.to_string(), current_row[db.mam_catchup.from_time].to_string());
                return publish_completed_live_range(account, mam_server,
                    latest_row_id, cursor_generation, expected_stream);
            }

            debug("[%s | %s] Fetching between ranges %s - %s", account.bare_jid.to_string(), mam_server.to_string(), previous_row[db.mam_catchup.to_time].to_string(), current_row[db.mam_catchup.from_time].to_string());
            FetchResult range_result;
            current_row = yield fetch_between_ranges(account, mam_server,
                previous_row, current_row, cancellation, out range_result);
            if (fetch_is_cancelled(cancellation)) return FetchResult.CANCELLED;
            if (!is_live_cursor_scope_current(account, mam_server,
                    cursor_generation, expected_stream)) {
                return FetchResult.CANCELLED;
            }
            if (range_result != FetchResult.SUCCESS) return range_result;
            if (current_row == null) {
                return publish_completed_live_range(account, mam_server,
                    latest_row_id, cursor_generation, expected_stream);
            }

            RowOption previous_row_opt = db.mam_catchup.select()
                    .with(db.mam_catchup.account_id, "=", account.id)
                    .with(db.mam_catchup.server_jid, "=", mam_server.to_string())
                    .with(db.mam_catchup.to_time, "<", current_row[db.mam_catchup.from_time])
                    .with(db.mam_catchup.to_time, ">=", (long) until_earliest_time.to_unix())
                    .order_by(db.mam_catchup.to_time, "DESC")
                    .single().row();
            previous_row = previous_row_opt.is_present() ? previous_row_opt.inner : null;
        }

        // We're at the earliest range. Try to expand it even further back.
        if (current_row == null) {
            debug("[%s | %s] No current range, aborting sync.", account.bare_jid.to_string(), mam_server.to_string());
            return publish_completed_live_range(account, mam_server,
                latest_row_id, cursor_generation, expected_stream);
        } else if (current_row[db.mam_catchup.from_end]) {
            debug("[%s | %s] No logs on server before %s, aborting sync.", account.bare_jid.to_string(), mam_server.to_string(), current_row[db.mam_catchup.from_time].to_string());
            return publish_completed_live_range(account, mam_server,
                latest_row_id, cursor_generation, expected_stream);
        }
        // We don't want to fetch before the earliest range over and over again in MUCs if it's after until_earliest_time.
        // For now, don't query if we are within a week of until_earliest_time
        if (until_earliest_time != null && current_row[db.mam_catchup.from_time] <= until_earliest_time.to_unix()) {
            debug("[%s | %s] Current range starting %s is before limit %s, aborting sync.", account.bare_jid.to_string(), mam_server.to_string(), current_row[db.mam_catchup.from_time].to_string(), until_earliest_time.to_unix().to_string());
            return publish_completed_live_range(account, mam_server,
                latest_row_id, cursor_generation, expected_stream);
        }
        FetchResult before_result = yield fetch_before_range(account,
            mam_server, current_row, until_earliest_time, cancellation);
        if (fetch_is_cancelled(cancellation)) return FetchResult.CANCELLED;
        return before_result == FetchResult.SUCCESS
            ? publish_completed_live_range(account, mam_server,
                latest_row_id, cursor_generation, expected_stream)
            : before_result;
        } finally {
            end_history_fetch(account);
        }
    }

    // Fetches the latest page (up to previous db row). Extends the previous db row if it was reached, creates a new row otherwise.
    public async Row? fetch_latest_page(Account account, Jid mam_server,
            Row? latest_row, DateTime? until_earliest_time,
            FetchCancellation? cancellation, out FetchResult fetch_result) {
        fetch_result = FetchResult.ERROR;
        begin_history_fetch(account);
        try {
        if (!is_account_ready(account)) return null;
        uint cursor_generation = get_live_cursor_generation(account,
            mam_server);
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        debug("[%s | %s] Fetching latest page", account.bare_jid.to_string(), mam_server.to_string());
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;

        if (cancellable != null && ((!) cancellable).is_cancelled()) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }

        int latest_row_id = -1;
        DateTime latest_message_time = until_earliest_time;
        string? latest_message_id = null;

        if (latest_row != null) {
            latest_row_id = latest_row[db.mam_catchup.id];
            latest_message_time = (new DateTime.from_unix_utc(latest_row[db.mam_catchup.to_time])).add_minutes(-5);
            latest_message_id = latest_row[db.mam_catchup.to_id];

            // Make sure we only fetch to until_earliest_time if latest_message_time is further back
            if (until_earliest_time != null && latest_message_time.compare(until_earliest_time) < 0) {
                // Retain overlap only inside the explicit history/privacy
                // floor; a panic wipe or clear boundary must not be widened.
                latest_message_time = until_earliest_time;
                latest_message_id = null;
            }
        }

        var query_params = new Xmpp.MessageArchiveManagement.V2.MamQueryParams.query_latest(mam_server, latest_message_time, latest_message_id);
        query_params.max_items = BACKGROUND_MAM_PAGE_SIZE;
        var query_cancellation = new ReloadQueryCancellation(cancellable,
            cancellation != null ? ((!) cancellation).reload_report : null);

        PageRequestResult page_result = yield get_mam_page(account, query_params, null, query_cancellation);
        debug("[%s | %s] Latest page result: %s", account.bare_jid.to_string(), mam_server.to_string(), page_result.page_result.to_string());

        if (!is_account_ready(account)) {
            fetch_result = fetch_is_cancelled(cancellation)
                ? FetchResult.CANCELLED : FetchResult.ERROR;
            return null;
        }
        if (fetch_is_cancelled(cancellation)) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }
        if (!is_live_cursor_scope_current(account, mam_server,
                cursor_generation, expected_stream)) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }
        if (page_result.page_result == PageResult.Error ||
                page_result.page_result == PageResult.Cancelled) {
            fetch_result = page_result.page_result == PageResult.Cancelled
                ? FetchResult.CANCELLED : FetchResult.ERROR;
            return null;
        }
        fetch_result = FetchResult.SUCCESS;

        // Catchup finished within first page. Update latest db entry.
        if (latest_row_id != -1 &&
                page_result.page_result in new PageResult[] { PageResult.TargetReached, PageResult.NoMoreMessages }) {

            if (page_result.stanzas == null) return null;

            string latest_mam_id = page_result.query_result.last;
            DateTime? latest_mam_dt = get_mam_time(account,
                query_params.query_id, latest_mam_id);
            if (latest_mam_dt == null) {
                fetch_result = FetchResult.ERROR;
                return null;
            }
            long latest_mam_time = (long) latest_mam_dt.to_unix();

            var query = db.mam_catchup.update()
                    .with(db.mam_catchup.id, "=", latest_row_id)
                    .set(db.mam_catchup.to_time, latest_mam_time)
                    .set(db.mam_catchup.to_id, latest_mam_id);

            if (page_result.page_result == PageResult.NoMoreMessages &&
                    query_reaches_archive_start(query_params)) {
                query.set(db.mam_catchup.from_end, true);
            }
            query.perform();
            return null;
        }

        if (page_result.query_result.first == null || page_result.query_result.last == null) {
            return null;
        }

        // Either we need to fetch more pages or this is the first db entry ever
        debug("[%s | %s] Creating new db range for latest page", account.bare_jid.to_string(), mam_server.to_string());

        string from_id = page_result.query_result.first;
        string to_id = page_result.query_result.last;

        DateTime? from_dt = get_mam_time(account, query_params.query_id,
            from_id);
        DateTime? to_dt = get_mam_time(account, query_params.query_id, to_id);
        if (from_dt == null || to_dt == null) {
            debug("Missing from/to id %s %s", from_id, to_id);
            fetch_result = FetchResult.ERROR;
            return null;
        }

        long from_time = (long) ((!) from_dt).to_unix();
        long to_time = (long) ((!) to_dt).to_unix();

        int new_row_id = (int) db.mam_catchup.insert()
                .value(db.mam_catchup.account_id, account.id)
                .value(db.mam_catchup.server_jid, mam_server.to_string())
                .value(db.mam_catchup.from_id, from_id)
                .value(db.mam_catchup.from_time, from_time)
                .value(db.mam_catchup.from_end,
                    page_result.page_result == PageResult.NoMoreMessages &&
                        query_reaches_archive_start(query_params))
                .value(db.mam_catchup.to_id, to_id)
                .value(db.mam_catchup.to_time, to_time)
                .perform();
        return db.mam_catchup.select().with(db.mam_catchup.id, "=", new_row_id).single().row().inner;
        } finally {
            end_history_fetch(account);
        }
    }

    /** Fetches messages between the end of `earlier_range` and start of `later_range`
     ** Merges the `earlier_range` db row into the `later_range` db row.
     ** @return The resulting range comprising `earlier_range`, `later_rage`, and everything in between. null if fetching/merge failed.
     **/
    private async Row? fetch_between_ranges(Account account, Jid mam_server,
            Row earlier_range, Row later_range,
            FetchCancellation? cancellation,
            out FetchResult fetch_result) {
        fetch_result = FetchResult.ERROR;
        if (!is_account_ready(account)) return null;
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;
        if (fetch_is_cancelled(cancellation)) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }
        uint cursor_generation = get_live_cursor_generation(account,
            mam_server);
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        int later_range_id = (int) later_range[db.mam_catchup.id];
        DateTime earliest_time = new DateTime.from_unix_utc(earlier_range[db.mam_catchup.to_time]);
        DateTime latest_time = new DateTime.from_unix_utc(later_range[db.mam_catchup.from_time]);
        debug("[%s | %s] Fetching between %s (%s) and %s (%s)", account.bare_jid.to_string(), mam_server.to_string(), earliest_time.to_string(), earlier_range[db.mam_catchup.to_id], latest_time.to_string(), later_range[db.mam_catchup.from_id]);

        var query_params = new Xmpp.MessageArchiveManagement.V2.MamQueryParams.query_between(mam_server,
            earliest_time, earlier_range[db.mam_catchup.to_id],
            latest_time, later_range[db.mam_catchup.from_id]);
        query_params.max_items = BACKGROUND_MAM_PAGE_SIZE;
        var query_cancellation = new ReloadQueryCancellation(cancellable,
            cancellation != null ? ((!) cancellation).reload_report : null);

        PageRequestResult page_result = yield fetch_query(account, query_params, later_range_id, query_cancellation);

        if (!is_account_ready(account)) {
            fetch_result = fetch_is_cancelled(cancellation)
                ? FetchResult.CANCELLED : FetchResult.ERROR;
            return null;
        }
        if (fetch_is_cancelled(cancellation)) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }
        if (!is_live_cursor_scope_current(account, mam_server,
                cursor_generation, expected_stream)) {
            fetch_result = FetchResult.CANCELLED;
            return null;
        }
        if (page_result.page_result == PageResult.Error ||
                page_result.page_result == PageResult.Cancelled) {
            fetch_result = page_result.page_result == PageResult.Cancelled
                ? FetchResult.CANCELLED : FetchResult.ERROR;
            return null;
        }
        fetch_result = FetchResult.SUCCESS;

        if (page_result.page_result == PageResult.TargetReached || page_result.page_result == PageResult.NoMoreMessages) {
            debug("[%s | %s] Merging range %i into %i", account.bare_jid.to_string(), mam_server.to_string(), earlier_range[db.mam_catchup.id], later_range_id);
            // Merge earlier range into later one.
            db.mam_catchup.update()
                .with(db.mam_catchup.id, "=", later_range_id)
                .set(db.mam_catchup.from_time, earlier_range[db.mam_catchup.from_time])
                .set(db.mam_catchup.from_id, earlier_range[db.mam_catchup.from_id])
                .set(db.mam_catchup.from_end, earlier_range[db.mam_catchup.from_end])
                .perform();

            db.mam_catchup.delete().with(db.mam_catchup.id, "=", earlier_range[db.mam_catchup.id]).perform();

            // Return the updated version of the later range
            return db.mam_catchup.select().with(db.mam_catchup.id, "=", later_range_id).single().row().inner;
        }

        return null;
    }

    private async FetchResult fetch_before_range(Account account,
            Jid mam_server, Row range, DateTime? until_earliest_time,
            FetchCancellation? cancellation = null) {
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;
        if (!is_account_ready(account)) return FetchResult.ERROR;
        if (fetch_is_cancelled(cancellation)) return FetchResult.CANCELLED;
        DateTime latest_time = new DateTime.from_unix_utc(range[db.mam_catchup.from_time]);
        string latest_id = range[db.mam_catchup.from_id];
        debug("[%s | %s] Fetching before range < %s, %s", account.bare_jid.to_string(), mam_server.to_string(), latest_time.to_string(), latest_id);

        Xmpp.MessageArchiveManagement.V2.MamQueryParams query_params;
        if (until_earliest_time == null) {
            query_params = new Xmpp.MessageArchiveManagement.V2.MamQueryParams.query_before(mam_server, latest_time, latest_id);
        } else {
            query_params = new Xmpp.MessageArchiveManagement.V2.MamQueryParams.query_between(
                    mam_server,
                    until_earliest_time, null,
                    latest_time, latest_id
            );
        }
        query_params.max_items = BACKGROUND_MAM_PAGE_SIZE;
        var query_cancellation = new ReloadQueryCancellation(cancellable,
            cancellation != null ? ((!) cancellation).reload_report : null);
        PageRequestResult page_result = yield fetch_query(account,
            query_params, range[db.mam_catchup.id], query_cancellation);
        if (!is_account_ready(account)) {
            return fetch_is_cancelled(cancellation)
                ? FetchResult.CANCELLED : FetchResult.ERROR;
        }
        if (fetch_is_cancelled(cancellation)) return FetchResult.CANCELLED;
        if (page_result.page_result == PageResult.Cancelled) {
            return FetchResult.CANCELLED;
        }
        if (page_result.page_result == PageResult.Error) {
            return FetchResult.ERROR;
        }
        return FetchResult.SUCCESS;
    }

    /**
     * Iteratively fetches all pages returned for a query (until a PageResult other than MorePagesAvailable is returned)
     * @return The last PageRequestResult result
     **/
    private async PageRequestResult fetch_query(Account account, Xmpp.MessageArchiveManagement.V2.MamQueryParams query_params, int db_id, Xmpp.MessageArchiveManagement.QueryCancellation? cancellation = null) {
        uint cursor_generation = get_live_cursor_generation(account,
            query_params.mam_server);
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        debug("[%s | %s] Fetch query %s - %s", account.bare_jid.to_string(), query_params.mam_server.to_string(), query_params.start != null ? query_params.start.to_string() : "", query_params.end != null ? query_params.end.to_string() : "");
        PageRequestResult? page_result = null;
        do {
            if (!is_account_ready(account)) {
                var unavailable_result = new Xmpp.MessageArchiveManagement.QueryResult();
                unavailable_result.error = true;
                return new PageRequestResult(PageResult.Error,
                    unavailable_result, null);
            }
            page_result = yield get_mam_page(account, query_params, page_result, cancellation);
            debug("[%s | %s] Page result %s (got stanzas: %s)", account.bare_jid.to_string(), query_params.mam_server.to_string(), page_result.page_result.to_string(), (page_result.stanzas != null).to_string());

            if (query_is_cancelled(cancellation)) {
                return new PageRequestResult(PageResult.Cancelled,
                    page_result.query_result, page_result.stanzas);
            }
            if (!is_live_cursor_scope_current(account,
                    query_params.mam_server, cursor_generation,
                    expected_stream)) {
                return new PageRequestResult(PageResult.Cancelled,
                    page_result.query_result, page_result.stanzas);
            }
            if (page_result.page_result == PageResult.Error || page_result.page_result == PageResult.Cancelled) return page_result;

            string earliest_mam_id = page_result.query_result.first;
            DateTime? earliest_mam_dt = earliest_mam_id != null
                ? get_mam_time(account, query_params.query_id,
                    (!) earliest_mam_id) : null;
            if (earliest_mam_id != null && earliest_mam_dt == null) {
                debug("[%s | %s] Missing MAM timestamp for %s", account.bare_jid.to_string(), query_params.mam_server.to_string(), earliest_mam_id);
                return new PageRequestResult(PageResult.Error,
                    page_result.query_result, page_result.stanzas);
            }
            long earliest_mam_time = earliest_mam_dt != null
                ? (long) ((!) earliest_mam_dt).to_unix() : 0;

            var query = db.mam_catchup.update()
                    .with(db.mam_catchup.id, "=", db_id);
            if (earliest_mam_id != null) {
                debug("[%s | %s] Updating to %s, %s", account.bare_jid.to_string(), query_params.mam_server.to_string(), earliest_mam_time.to_string(), earliest_mam_id);
                query.set(db.mam_catchup.from_id, earliest_mam_id);
                if (page_result.page_result != PageResult.NoMoreMessages || (query_params.start != null && earliest_mam_time < query_params.start.to_unix())) {
                    query.set(db.mam_catchup.from_time, earliest_mam_time);
                }
            }

            if (page_result.page_result == PageResult.NoMoreMessages) {
                // If the server doesn't have more messages, store that this range is at its end or update the from timestamp
                if (query_params.start != null) {
                    debug("[%s | %s] Updating to %s based on query", account.bare_jid.to_string(), query_params.mam_server.to_string(), query_params.start.to_string());
                    query.set(db.mam_catchup.from_time, (long) query_params.start.to_unix());
                }
                query.set(db.mam_catchup.from_end,
                    query_reaches_archive_start(query_params));
            }
            query.perform();
        } while (page_result.page_result == PageResult.MorePagesAvailable);

        return page_result;
    }

    enum PageResult {
        MorePagesAvailable,
        TargetReached,
        NoMoreMessages,
        Error,
        Cancelled
    }

    /**
     * prev_page_result: null if this is the first page request
     **/
    private async PageRequestResult get_mam_page(Account account, Xmpp.MessageArchiveManagement.V2.MamQueryParams query_params, PageRequestResult? prev_page_result, Xmpp.MessageArchiveManagement.QueryCancellation? cancellation = null,
            DirectHistoryRequest? direct_request = null) {
        if (!is_account_ready(account)) {
            var unavailable_result = new Xmpp.MessageArchiveManagement.QueryResult();
            unavailable_result.error = true;
            return new PageRequestResult(PageResult.Error,
                unavailable_result, null);
        }
        if (query_is_cancelled(cancellation) ||
                (direct_request != null && !is_direct_request_current((!) direct_request))) {
            var cancelled_result = new Xmpp.MessageArchiveManagement.QueryResult();
            cancelled_result.error = true;
            return new PageRequestResult(PageResult.Cancelled,
                cancelled_result, null);
        }
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) {
            var unavailable_result = new Xmpp.MessageArchiveManagement.QueryResult();
            unavailable_result.error = true;
            bool cancelled = cancellation != null &&
                ((!) cancellation).cancellable != null &&
                ((!) ((!) cancellation).cancellable).is_cancelled();
            return new PageRequestResult(cancelled
                    ? PageResult.Cancelled : PageResult.Error,
                unavailable_result, null);
        }
        Xmpp.MessageArchiveManagement.QueryResult query_result = null;
        var trace_cancellation = cancellation as ReloadQueryCancellation;
        string trace_origin = direct_request != null ? "manual-direct" :
            trace_cancellation != null && trace_cancellation.report != null ? "manual-muc" : "automatic";
        string? trace_page_before = prev_page_result != null ? prev_page_result.query_result.first : null;
        HistoryDiagnostics.query("query-start", account, query_params,
            trace_origin, trace_page_before);
        if (prev_page_result == null) {
            query_result = yield Xmpp.MessageArchiveManagement.V2.query_archive(
                (!) stream, query_params, cancellation);
        } else {
            query_result = yield Xmpp.MessageArchiveManagement.V2.page_through_results(
                (!) stream, query_params, prev_page_result.query_result,
                cancellation);
        }
        HistoryDiagnostics.query("query-result", account, query_params,
            trace_origin, trace_page_before, query_result);
        if (!is_account_ready(account) ||
                stream_interactor.get_stream(account) != stream) {
            clear_query_stanzas(query_params.query_id);
            query_result.error = true;
            return new PageRequestResult(query_is_cancelled(cancellation)
                    ? PageResult.Cancelled : PageResult.Error,
                query_result, null);
        }
        if (direct_request != null && !is_direct_request_current((!) direct_request)) {
            clear_query_stanzas(query_params.query_id);
            return new PageRequestResult(PageResult.Cancelled, query_result, null);
        }
        return yield process_query_result(account, (!) stream, query_params,
            query_result, cancellation, direct_request);
    }

    private async PageRequestResult process_query_result(Account account,
            XmppStream stream,
            Xmpp.MessageArchiveManagement.V2.MamQueryParams query_params,
            Xmpp.MessageArchiveManagement.QueryResult query_result,
            Xmpp.MessageArchiveManagement.QueryCancellation? cancellation =
                null, DirectHistoryRequest? direct_request = null) {
        PageResult page_result = PageResult.MorePagesAvailable;
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;
        string query_id = query_params.query_id;
        try {

        if (!is_account_ready(account) ||
                stream_interactor.get_stream(account) != stream) {
            clear_query_stanzas(query_id);
            query_result.error = true;
            return new PageRequestResult(query_is_cancelled(cancellation)
                    ? PageResult.Cancelled : PageResult.Error,
                query_result, null);
        }

        if (direct_request != null && !is_direct_request_current((!) direct_request)) {
            clear_query_stanzas(query_id);
            return new PageRequestResult(PageResult.Cancelled, query_result, null);
        }
        if (query_result.malformed || query_result.error) {
            page_result = PageResult.Error;
            // Clean up stanzas to prevent memory leak on query error
            if (stanzas.has_key(query_id)) {
                clear_query_stanzas(query_id);
            }
        }

        if (direct_request != null && page_result == PageResult.Error) {
            return new PageRequestResult(PageResult.Error, query_result, null);
        }
        // We wait until all the messages from the page are processed (and we got the `mam_times` from them)
        Idle.add(process_query_result.callback, Priority.LOW);
        yield;

        if (!is_account_ready(account)) {
            clear_query_stanzas(query_id);
            query_result.error = true;
            return new PageRequestResult(query_is_cancelled(cancellation)
                    ? PageResult.Cancelled : PageResult.Error,
                query_result, null);
        }

        // We might have successfully reached the target or the server doesn't have all messages stored anymore
        // If it's the former, we'll overwrite the value with PageResult.MorePagesAvailable below.
        if (query_result.complete) {
            page_result = PageResult.NoMoreMessages;
        }

        string? after_id = query_params.start_id;

        var stanzas_for_query = stanzas.has_key(query_id) && !stanzas[query_id].is_empty ? stanzas[query_id] : null;
        if (cancellable != null && cancellable.is_cancelled()) {
            clear_query_stanzas(query_id);
            return new PageRequestResult(PageResult.Cancelled, query_result, stanzas_for_query);
        }

        if (direct_request != null) {
            if (!is_direct_request_current((!) direct_request)) {
                clear_query_stanzas(query_id);
                return new PageRequestResult(PageResult.Cancelled, query_result, null);
            }
            if (stanzas_for_query != null) {
                foreach (Xmpp.MessageStanza message in stanzas_for_query) {
                    if (!direct_message_matches((!) direct_request, message)) {
                        clear_query_stanzas(query_id);
                        return new PageRequestResult(PageResult.Error, query_result, null);
                    }
                }
            }
        }
        if (stanzas_for_query != null && direct_request == null) {

            // Check it we reached our target (from_id)
            foreach (Xmpp.MessageStanza message in stanzas_for_query) {
                Xmpp.MessageArchiveManagement.MessageFlag? mam_message_flag = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(message);
                if (mam_message_flag != null && mam_message_flag.mam_id != null) {
                    if (after_id != null && mam_message_flag.mam_id == after_id) {
                        // Successfully fetched the whole range
                        bool pipeline_ready = yield
                            send_messages_back_into_pipeline(account, stream,
                                query_id, cancellation);
                        if (!pipeline_ready) {
                            query_result.error = true;
                            return new PageRequestResult(
                                query_is_cancelled(cancellation)
                                    ? PageResult.Cancelled : PageResult.Error,
                                query_result, stanzas_for_query);
                        }
                        if (cancellable != null && cancellable.is_cancelled()) {
                            return new PageRequestResult(PageResult.Cancelled, query_result, stanzas_for_query);
                        }
                        return new PageRequestResult(PageResult.TargetReached, query_result, stanzas_for_query);
                    }
                }
            }
            if (hitted_range.has_key(query_id) && hitted_range[query_id] == -2) {
                // Message got filtered out by xmpp-vala, but succesful range fetch nevertheless
                bool pipeline_ready = yield
                    send_messages_back_into_pipeline(account, stream,
                        query_id, cancellation);
                if (!pipeline_ready) {
                    query_result.error = true;
                    return new PageRequestResult(
                        query_is_cancelled(cancellation)
                            ? PageResult.Cancelled : PageResult.Error,
                        query_result, stanzas_for_query);
                }
                if (cancellable != null && cancellable.is_cancelled()) {
                    return new PageRequestResult(PageResult.Cancelled, query_result, stanzas_for_query);
                }
                return new PageRequestResult(PageResult.TargetReached, query_result, stanzas_for_query);
            }
        }

        bool pipeline_ready = yield send_messages_back_into_pipeline(account,
            stream, query_id, cancellation, direct_request);
        if (!pipeline_ready) {
            query_result.error = true;
            return new PageRequestResult(query_is_cancelled(cancellation)
                    ? PageResult.Cancelled : PageResult.Error,
                query_result, stanzas_for_query);
        }
        if (cancellable != null && cancellable.is_cancelled()) {
            page_result = PageResult.Cancelled;
        }
        return new PageRequestResult(page_result, query_result, stanzas_for_query);
        } finally {
            hitted_range.unset(query_id);
        }
    }

    private async bool send_messages_back_into_pipeline(Account account,
            XmppStream stream, string query_id,
            Xmpp.MessageArchiveManagement.QueryCancellation? cancellation =
                null, DirectHistoryRequest? direct_request = null) {
        Cancellable? cancellable = cancellation != null
            ? ((!) cancellation).cancellable : null;
        var reload_cancellation = cancellation as ReloadQueryCancellation;
        ReloadReport? report = reload_cancellation != null
            ? ((!) reload_cancellation).report : null;
        if (!stanzas.has_key(query_id)) {
            return (direct_request == null || is_direct_request_current((!) direct_request)) &&
                is_account_ready(account) &&
                stream_interactor.get_stream(account) == stream;
        }

        XmppStream? recorded_stream = stanza_streams[query_id];
        if (recorded_stream == null || recorded_stream != stream) {
            clear_query_stanzas(query_id);
            return false;
        }

        int processed = 0;
        foreach (Xmpp.MessageStanza message in stanzas[query_id]) {
            if (!is_account_ready(account) ||
                    stream_interactor.get_stream(account) != stream ||
                    (cancellable != null && cancellable.is_cancelled()) ||
                    (direct_request != null && !is_direct_request_current((!) direct_request))) {
                clear_query_stanzas(query_id);
                return false;
            }
            if (HistoryDiagnostics.enabled()) {
                message.set_data<string>("dinox-history-trace-origin",
                    direct_request != null ? "manual-direct" : report != null ? "manual-muc" : "automatic");
            }
            if (direct_request != null) {
                DirectHistoryRequest request = (!) direct_request;
                yield stream_interactor.get_module<MessageProcessor>(
                    MessageProcessor.IDENTITY).run_pipeline_announce_on_stream(
                        account, stream, message, (parsed, context) => {
                            bool admitted = is_direct_request_current(request) &&
                                direct_message_matches(request, message);
                            if (parsed != null) {
                                admitted = admitted &&
                                    ((!) parsed).type_ == Entities.Message.Type.CHAT &&
                                    ((!) parsed).account.id == request.account_id &&
                                    ((!) parsed).counterpart != null &&
                                    ((!) ((!) parsed).counterpart).equals_bare(request.peer);
                            }
                            if (context != null) {
                                admitted = admitted &&
                                    ((!) context).type_ == Conversation.Type.CHAT &&
                                    ((!) context).id == request.conversation_id &&
                                    ((!) context).account.id == request.account_id &&
                                    ((!) context).counterpart.equals_bare(request.peer);
                            }
                            if (!admitted) request.cancellable.cancel();
                            return admitted && (report == null ||
                                !((!) report).summarize_failure(message, parsed, context));
                        });
            } else {
                yield stream_interactor.get_module<MessageProcessor>(
                    MessageProcessor.IDENTITY).run_pipeline_announce_on_stream(
                        account, stream, message, (parsed, context) => {
                            return (cancellable == null || !cancellable.is_cancelled()) &&
                                (report == null || !((!) report).summarize_failure(
                                    message, parsed, context));
                        });
            }
            if (!is_account_ready(account) ||
                    stream_interactor.get_stream(account) != stream ||
                    (direct_request != null && !is_direct_request_current((!) direct_request))) {
                clear_query_stanzas(query_id);
                return false;
            }
            processed++;
            if (processed % MAM_PIPELINE_BATCH_SIZE == 0) {
                Idle.add(send_messages_back_into_pipeline.callback, Priority.LOW);
                yield;
            }
        }
        clear_query_stanzas(query_id);
        return is_account_ready(account) &&
            stream_interactor.get_stream(account) == stream &&
            (cancellable == null || !cancellable.is_cancelled()) &&
            (direct_request == null || is_direct_request_current((!) direct_request));
    }

    private void on_account_added(Account account) {
        cleanup_db_ranges(db, account);

        mam_times[account] = new HashMap<string, DateTime>();

        stream_interactor.connection_manager.stream_attached_modules.connect((account, stream) => {
            if (!current_catchup_id.has_key(account)) {
                current_catchup_id[account] = new HashMap<Jid, int>(Jid.hash_func, Jid.equals_func);
            } else {
                current_catchup_id[account].clear();
            }
        });

        stream_interactor.module_manager.get_module<Xmpp.MessageArchiveManagement.Module>(account, Xmpp.MessageArchiveManagement.Module.IDENTITY).feature_available.connect((stream) => {
            consider_fetch_everything(account, stream);
        });

        stream_interactor.module_manager.get_module<Xmpp.MessageModule>(account, Xmpp.MessageModule.IDENTITY).received_message_unprocessed.connect((stream, message) => {
            on_unprocessed_message(account, stream, message);
        });
    }

    private void consider_fetch_everything(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;

        if (!auto_fetch_enabled) {
            debug("[%s] MAM auto-fetch disabled", account.bare_jid.to_string());
            finish_account_archive_sync(account, stream,
                FetchResult.UNAVAILABLE);
            return;
        }
        if (!is_account_ready(account)) {
            debug("[%s] MAM auto-fetch deferred until persistent plugin state is ready",
                account.bare_jid.to_string());
            return;
        }
        if (sync_streams.has(account, stream)) return;

        debug("[%s] MAM available, sync_not_before=%s", account.bare_jid.to_string(), sync_not_before.to_string());
        sync_streams[account] = stream;
        if (!cancellables.has_key(account)) {
            cancellables[account] = new HashMap<Jid, Cancellable>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (cancellables[account].has_key(account.bare_jid)) {
            cancellables[account][account.bare_jid].cancel();
        }
        Cancellable sync_owner = new Cancellable();
        cancellables[account][account.bare_jid] = sync_owner;
        fetch_everything.begin(account, account.bare_jid,
                new FetchCancellation(sync_owner),
                sync_not_before, (_, res) => {
            FetchResult fetch_result = fetch_everything.end(res);
            if (!cancellables.has_key(account) ||
                    !cancellables[account].has_key(account.bare_jid) ||
                    cancellables[account][account.bare_jid] != sync_owner) {
                return;
            }
            cancellables[account].unset(account.bare_jid);
            if (cancellables[account].is_empty) {
                cancellables.unset(account);
            }
            if (fetch_result != FetchResult.CANCELLED &&
                    is_account_ready(account)) {
                finish_account_archive_sync(account, stream, fetch_result);
            }
        });
    }

    private async void maybe_fetch_account_archive(Account account, XmppStream stream) {
        if (sync_streams.has(account, stream)) return;

        EntityInfo? entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        if (entity_info == null) return;

        bool mam_available = yield ((!) entity_info).has_feature(account, account.bare_jid, Xmpp.MessageArchiveManagement.NS_URI);
        if (mam_available) {
            consider_fetch_everything(account, stream);
        } else {
            finish_account_archive_sync(account, stream,
                FetchResult.UNAVAILABLE);
        }
    }

    private void finish_account_archive_sync(Account account,
            XmppStream stream, FetchResult result) {
        if (stream_interactor.get_stream(account) != stream ||
                settled_account_streams.has(account, stream)) {
            return;
        }
        settled_account_streams[account] = stream;
        account_archive_sync_finished(account, stream, result);
    }

    public static void cleanup_db_ranges(Database db, Account account) {
        var ranges = new HashMap<Jid, ArrayList<MamRange>>(Jid.hash_func, Jid.equals_func);
        foreach (Row row in db.mam_catchup.select().with(db.mam_catchup.account_id, "=", account.id)) {
            var mam_range = new MamRange();
            mam_range.id = row[db.mam_catchup.id];
            try {
                mam_range.server_jid = new Jid(row[db.mam_catchup.server_jid]);
            } catch (Xmpp.InvalidJidError e) {
                warning("Invalid JID in MAM catchup DB: %s", e.message);
                continue;
            }
            mam_range.from_time = row[db.mam_catchup.from_time];
            mam_range.from_id = row[db.mam_catchup.from_id];
            mam_range.from_end = row[db.mam_catchup.from_end];
            mam_range.to_time = row[db.mam_catchup.to_time];
            mam_range.to_id = row[db.mam_catchup.to_id];

            if (!ranges.has_key(mam_range.server_jid)) ranges[mam_range.server_jid] = new ArrayList<MamRange>();
            ranges[mam_range.server_jid].add(mam_range);
        }

        var to_delete = new ArrayList<MamRange>();

        foreach (Jid server_jid in ranges.keys) {
            foreach (var range1 in ranges[server_jid]) {
                if (to_delete.contains(range1)) continue;

                foreach (MamRange range2 in ranges[server_jid]) {
                    debug("[%s | %s] | %s - %s vs %s - %s", account.bare_jid.to_string(), server_jid.to_string(), range1.from_time.to_string(), range1.to_time.to_string(), range2.from_time.to_string(), range2.to_time.to_string());
                    if (range1 == range2 || to_delete.contains(range2)) continue;

                    // Check if range2 is a subset of range1
                    // range1: #####################
                    // range2:         ######
                    if (range1.from_time <= range2.from_time && range1.to_time >= range2.to_time) {
                        warning("Removing db range which is a subset of %li-%li", range1.from_time, range1.to_time);
                        to_delete.add(range2);
                        continue;
                    }

                    // Check if range2 is an extension of range1 (towards earlier)
                    // range1:        #####################
                    // range2: ###############
                    if (range1.from_time <= range2.to_time <= range1.to_time && range2.from_time <= range1.from_time) {
                        warning("Removing db range that overlapped %li-%li (towards earlier)", range1.from_time, range1.to_time);
                        db.mam_catchup.update()
                                .with(db.mam_catchup.id, "=", range1.id)
                                .set(db.mam_catchup.from_id, range2.from_id)
                                .set(db.mam_catchup.from_time, range2.from_time)
                                .set(db.mam_catchup.from_end, range2.from_end)
                                .perform();
                        to_delete.add(range2);
                        continue;
                    }
                }
            }
        }

        foreach (MamRange row in to_delete) {
            db.mam_catchup.delete().with(db.mam_catchup.id, "=", row.id).perform();
            warning("Removing db range %s %li-%li", row.server_jid.to_string(), row.from_time, row.to_time);
        }
    }

    class MamRange {
        public int id;
        public Jid server_jid;
        public long from_time;
        public string from_id;
        public bool from_end;
        public long to_time;
        public string to_id;
    }

    class PageRequestResult {
        public Gee.List<MessageStanza> stanzas { get; set; }
        public PageResult page_result { get; set; }
        public Xmpp.MessageArchiveManagement.QueryResult query_result { get; set; }

        public PageRequestResult(PageResult page_result, Xmpp.MessageArchiveManagement.QueryResult query_result, Gee.List<MessageStanza>? stanzas) {
            this.page_result = page_result;
            this.query_result = query_result;
            this.stanzas = stanzas;
        }
    }
}
