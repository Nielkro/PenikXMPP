using Dino.Entities;
using Omemo;
using Qlite;
using Xmpp;
using Gee;

namespace Dino.Plugins.Omemo {

internal enum PrivateMucKeyReadinessStatus {
    READY,
    ROOM_INFO_PENDING,
    NOT_PRIVATE,
    SNAPSHOT_UNAVAILABLE,
    NO_OTHER_MEMBER,
    MEMBER_UNSUPPORTED,
    STALE
}

internal class PrivateMucKeyReadinessResult : Object {
    internal PrivateMucKeyReadinessStatus status { get; private set; }
    internal Jid? member { get; private set; }

    internal PrivateMucKeyReadinessResult(
            PrivateMucKeyReadinessStatus status, Jid? member = null) {
        this.status = status;
        this.member = member;
    }
}

/** One coalesced private-MUC device-readiness pass on the GTK main context. */
private class PendingPrivateMucKeyReadiness : Object {
    internal MucManager.MucOwnerMutationContext context {
        get; private set;
    }
    internal Gee.List<Jid> members { get; private set; }
    internal uint snapshot_revision { get; private set; }
    private HashMap<Jid, uint> initial_device_generations =
        new HashMap<Jid, uint>(Jid.hash_bare_func,
            Jid.equals_bare_func);

    private Promise<PrivateMucKeyReadinessResult> promise =
        new Promise<PrivateMucKeyReadinessResult>();

    internal PendingPrivateMucKeyReadiness(
            MucManager.MucOwnerMutationContext context,
            Gee.Collection<Jid> members, uint snapshot_revision,
            Gee.Map<Jid, uint> device_generations) {
        this.context = context;
        this.snapshot_revision = snapshot_revision;
        var snapshot = new ArrayList<Jid>();
        var seen = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        foreach (Jid member in members) {
            Jid bare = member.bare_jid;
            if (seen.add(bare)) snapshot.add(bare);
        }
        this.members = snapshot;
        foreach (Map.Entry<Jid, uint> entry in device_generations.entries) {
            initial_device_generations[entry.key.bare_jid] = entry.value;
        }
    }

    internal uint initial_device_generation(Jid member) {
        Jid bare = member.bare_jid;
        return initial_device_generations.has_key(bare)
            ? initial_device_generations[bare] : 0;
    }

    internal async PrivateMucKeyReadinessResult wait_for_result() {
        try {
            return yield promise.future.wait_async();
        } catch (Gee.FutureError e) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
    }

    internal void complete(PrivateMucKeyReadinessResult result) {
        if (!promise.future.ready) promise.set_value(result);
    }
}

/** Retry hint retained only after a member advertised no usable devices. */
private class PrivateMucReadinessWatch : Object {
    internal MucManager.MucOwnerMutationContext context {
        get; private set;
    }
    internal Jid member { get; private set; }
    internal uint snapshot_revision { get; private set; }

    internal PrivateMucReadinessWatch(
            MucManager.MucOwnerMutationContext context, Jid member,
            uint snapshot_revision) {
        this.context = context;
        this.member = member.bare_jid;
        this.snapshot_revision = snapshot_revision;
    }
}

/** Main-context-only hint for optional private-MUC key prefetch. */
internal class ProactiveMucDiscoveryHint : Object {
    internal Account account { get; private set; }
    internal Jid room { get; private set; }
    internal Jid real_jid { get; private set; }
    internal uint generation { get; private set; }
    internal string key { get; private set; }

    internal ProactiveMucDiscoveryHint(Account account, Jid room,
            Jid real_jid, uint generation) {
        this.account = account;
        this.room = room.bare_jid;
        this.real_jid = real_jid.bare_jid;
        this.generation = generation;
        this.key = @"$(account.id)\x1f$(generation)\x1f$(this.real_jid.to_string())";
    }
}

/**
 * FIFO limiter for best-effort private-MUC device discovery.
 *
 * It bounds only concurrent prefetch work. Pending unique recipients are not
 * dropped, and this queue is never consulted when choosing OMEMO recipients.
 */
internal class ProactiveMucDiscoveryQueue : Object {
    private uint max_concurrent;
    private GLib.Queue<ProactiveMucDiscoveryHint> pending =
        new GLib.Queue<ProactiveMucDiscoveryHint>();
    private HashSet<string> pending_keys = new HashSet<string>();
    private HashSet<string> active_keys = new HashSet<string>();

    internal uint queued_count { get { return pending.length; } }
    internal uint active_count { get { return (uint) active_keys.size; } }

    internal ProactiveMucDiscoveryQueue(uint max_concurrent) {
        this.max_concurrent = uint.max(1, max_concurrent);
    }

    internal bool enqueue(Account account, Jid room, Jid real_jid,
            uint generation) {
        var hint = new ProactiveMucDiscoveryHint(account, room, real_jid,
            generation);
        if (pending_keys.contains(hint.key) || active_keys.contains(hint.key)) {
            return false;
        }
        pending.push_tail(hint);
        pending_keys.add(hint.key);
        return true;
    }

    internal ProactiveMucDiscoveryHint? take() {
        if (active_keys.size >= (int) max_concurrent || pending.is_empty()) {
            return null;
        }
        ProactiveMucDiscoveryHint hint = pending.pop_head();
        pending_keys.remove(hint.key);
        active_keys.add(hint.key);
        return hint;
    }

    internal void complete(ProactiveMucDiscoveryHint hint) {
        active_keys.remove(hint.key);
    }

    internal void cancel_account(int account_id) {
        uint count = pending.length;
        for (uint i = 0; i < count; i++) {
            ProactiveMucDiscoveryHint hint = pending.pop_head();
            if (hint.account.id == account_id) {
                pending_keys.remove(hint.key);
            } else {
                pending.push_tail(hint);
            }
        }
    }
}

public class Manager : StreamInteractionModule, Object {
    public static ModuleIdentity<Manager> IDENTITY = new ModuleIdentity<Manager>("omemo_manager");
    private static TimeSpan LEGACY_DEVICELIST_MAX_AGE = 5 * TimeSpan.MINUTE; // vala-lint=naming-convention
    private const uint PROACTIVE_MUC_DISCOVERY_MAX_CONCURRENT = 4;
    public string id { get { return IDENTITY.id; } }
    public bool auto_publish_own_device_lists { get; set; default = true; }
    public signal void private_muc_readiness_changed(Account account,
        Jid room);
    /** Persisted local device metadata changed; does not request readiness. */
    public signal void device_trust_state_changed(Account account, Jid jid);

    private StreamInteractor stream_interactor;
    private Database db;
    private TrustManager trust_manager;
    private HashMap<Account, OmemoEncryptor> encryptors;
    private HashMap<Account, Omemo2Encrypt> encryptors_v2;
    // This is the state of individual pipeline objects, not content dedupe.
    // Entity equality ignores the account and hashes the mutable message body.
    private Map<Entities.Message, MessageState> message_states = new HashMap<Entities.Message, MessageState>();
    /* ── Bundle-Retry ──────────────────────────────────────────────
     * Wenn ein OMEMO-2-Bundle leer/kaputt vom Server kommt (z.B.
     * Kaidan publiziert <ik/> ohne Inhalt), wird das Gerät hier
     * eingetragen.  Alle BUNDLE_RETRY_INTERVAL_SEC Sekunden fragt
     * DinoX das Bundle erneut ab.  Nach BUNDLE_RETRY_MAX_ATTEMPTS
     * erfolglosen Versuchen wird das Gerät nicht mehr probiert.
     * Sobald ein gültiges Bundle eintrifft, wird der Eintrag
     * entfernt und die Session normal aufgebaut.
     * ─────────────────────────────────────────────────────────── */
    private const int BUNDLE_RETRY_INTERVAL_SEC = 10 * 60;   // 10 Minuten
    private const int BUNDLE_RETRY_MAX_ATTEMPTS = 5;

    private class BundleRetryEntry {
        public Account account;
        public Jid jid;
        public int32 device_id;
        public int attempts;
        public BundleRetryEntry(Account account, Jid jid, int32 device_id) {
            this.account = account;
            this.jid = jid;
            this.device_id = device_id;
            this.attempts = 0;
        }
        public string key() {
            return @"$(account.id):$(jid.bare_jid):$device_id";
        }
    }

    /* Map: "account_id:bare_jid:device_id" → BundleRetryEntry */
    private HashMap<string, BundleRetryEntry> bundle_retry_queue
        = new HashMap<string, BundleRetryEntry>();
    private uint bundle_retry_timer_id = 0;
    private HashMap<string, DateTime> legacy_devicelist_loaded = new HashMap<string, DateTime>();
    private bool require_current_legacy_devicelists = true;
    private ProactiveMucDiscoveryQueue proactive_muc_discovery =
        new ProactiveMucDiscoveryQueue(PROACTIVE_MUC_DISCOVERY_MAX_CONCURRENT);
    private HashMap<Account, uint> proactive_muc_generations =
        new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashMap<Account, ulong> pending_store_init_handlers =
        new HashMap<Account, ulong>(Account.hash_func, Account.equals_func);
    private uint proactive_muc_drain_source = 0;
    private HashMap<string, PendingPrivateMucKeyReadiness>
        pending_private_muc_key_readiness =
            new HashMap<string, PendingPrivateMucKeyReadiness>();
    private HashMap<string, PrivateMucReadinessWatch>
        private_muc_readiness_watches =
            new HashMap<string, PrivateMucReadinessWatch>();
    private HashMap<string, uint> private_muc_device_generations =
        new HashMap<string, uint>();

    internal static bool should_wait_for_own_sessions(Xep.Omemo.EncryptState new_try) {
        return new_try.own_unknown > 0;
    }

    internal static bool should_wait_for_counterpart_sessions(Xep.Omemo.EncryptState new_try) {
        // An unknown session is pending work, not an unavailable device.
        // This also applies to groups: sending after one warm member succeeds
        // strands a cold member and skips the bundle-fetch/retry path entirely.
        // Explicit lost/failure classifications retain the group policy below.
        return new_try.other_unknown > 0;
    }



    internal class MessageState {
        public Entities.Message msg { get; private set; }
        public Xep.Omemo.EncryptState last_try { get; private set; }
        public int waiting_other_sessions { get; set; }
        public int waiting_own_sessions { get; set; }
        public bool waiting_own_devicelist { get; set; }
        public int waiting_other_devicelists { get; set; }
        public bool force_next_attempt { get; set; }
        public bool will_send_now { get; private set; }
        public bool active_send_attempt { get; set; }

        public MessageState(Entities.Message msg, Xep.Omemo.EncryptState last_try) {
            update_from_encrypt_status(msg, last_try);
        }

        public void update_from_encrypt_status(Entities.Message msg, Xep.Omemo.EncryptState new_try) {
            this.msg = msg;
            this.last_try = new_try;
            this.waiting_other_sessions = new_try.other_unknown;
            this.waiting_own_sessions = new_try.own_unknown;
            this.waiting_own_devicelist = !new_try.own_list;
            this.waiting_other_devicelists = new_try.other_waiting_lists;
            this.active_send_attempt = false;
            will_send_now = false;

            // Determine WONTSEND: nobody can receive the message
            bool dominated = false;
            if (msg.type_ == Entities.Message.Type.GROUPCHAT) {
                // MUC: send if at least one other participant's device succeeded.
                // Lost/failed devices (deleted accounts, unreachable servers) are
                // simply skipped — those participants won't receive the message.
                // WONTSEND only when NO device succeeded AND nothing is pending.
                if (new_try.other_success < 1 && new_try.other_unknown < 1
                        && new_try.other_waiting_lists < 1) {
                    if (new_try.other_devices == 0) {
                        // Store a locale-independent reason; the chat UI
                        // localizes it when presenting this blocked message.
                        msg.delivery_error_text = "OMEMO private-MUC encryption requires a trusted device of another member";
                    }
                    msg.marked = Entities.Message.Marked.WONTSEND;
                    dominated = true;
                }
            } else {
                // 1:1 chat: strict — any hard failure or all devices lost blocks the message.
                if (new_try.other_failure > 0 || (new_try.other_lost == new_try.other_devices && new_try.other_devices > 0)) {
                    msg.marked = Entities.Message.Marked.WONTSEND;
                    dominated = true;
                }
            }

            if (dominated) {
                // Already decided — do not evaluate further
            } else if (new_try.other_waiting_lists > 0 || !new_try.own_list || new_try.own_devices == 0) {
                // Still waiting for device lists — must block
                msg.marked = Entities.Message.Marked.UNSENT;
            } else if (should_wait_for_counterpart_sessions(new_try)) {
                // Every active unknown session must receive a preparation or
                // explicit failure decision before committing a group payload.
                msg.marked = Entities.Message.Marked.UNSENT;
            } else if (should_wait_for_own_sessions(new_try)) {
                // Same-JID devices must get a repair/ignore decision before sending;
                // otherwise sent carbons can be missing on another own client.
                msg.marked = Entities.Message.Marked.UNSENT;
            } else if (!new_try.encrypted) {
                msg.marked = Entities.Message.Marked.WONTSEND;
            } else {
                // Devices may be skipped only after explicit lost/ignore classification.
                msg.delivery_error_text = null;
                will_send_now = true;
            }
        }

        public bool should_retry_now() {
            return !waiting_own_devicelist && waiting_other_devicelists <= 0 && waiting_other_sessions <= 0 && waiting_own_sessions <= 0 && !active_send_attempt;
        }

        public string to_string() {
            return @"MessageState (msg=$(msg.stanza_id), send=$will_send_now, $last_try)";
        }
    }

    private Manager(StreamInteractor stream_interactor, Database db, TrustManager trust_manager, HashMap<Account, OmemoEncryptor> encryptors, HashMap<Account, Omemo2Encrypt> encryptors_v2, bool connect_service_signals = true) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.trust_manager = trust_manager;
        this.encryptors = encryptors;
        this.encryptors_v2 = encryptors_v2;
        this.require_current_legacy_devicelists = connect_service_signals;

        if (!connect_service_signals) return;

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).pre_message_send.connect(on_pre_message_send);
        stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).mutual_subscription.connect(on_mutual_subscription);
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_cleared.connect(on_conversation_cleared);
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).conference_removed.connect(on_conference_removed);
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .left_signal.connect((account, room) => {
                cancel_private_muc_key_readiness(account, room);
            });

        // Proactively fetch OMEMO keys when a new member joins a private MUC
        // Without this, keys are only fetched on first message send → visible delay
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).private_room_occupant_updated.connect((account, room, occupant) => {
            queue_private_room_occupant_discovery(account, room, occupant);
        });
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).private_room_occupant_real_jid_ready.connect((account, room, occupant, real_jid) => {
            queue_private_room_real_jid_discovery(account, room, real_jid);
        });

        // When the user removes an own device via TrustManager, republish the device list
        trust_manager.own_device_removed.connect((account, device_id) => {
            if (!auto_publish_own_device_lists) return;
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                ArrayList<int32> removed_devices = new ArrayList<int32>();
                removed_devices.add(device_id);
                republish_device_list_removing_devices(account, stream, removed_devices);
                if (should_publish_own_omemo2()) {
                    republish_device_list_v2(account, stream);
                }
            }
        });
    }

    private bool should_publish_own_omemo2() {
        return auto_publish_own_device_lists && trust_manager.omemo2_enabled;
    }

    private bool should_query_omemo2() {
        return trust_manager.omemo2_enabled;
    }

    private void configure_omemo2_publish(StreamModule2? module2) {
        if (module2 != null) {
            ((!) module2).auto_publish_own_device_list = should_publish_own_omemo2() &&
                    !((!) module2).store.registration_pending;
        }
    }

    private void queue_private_room_occupant_discovery(Account account,
            Jid room, Jid occupant) {
        // A new member joined or real JID was revealed in a private MUC.
        // Proactively fetch their OMEMO device list + bundles so encryption
        // is ready when the user sends a message (no delay).
        Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(occupant, account);
        if (real_jid == null) return;
        queue_private_room_real_jid_discovery(account, room, (!) real_jid);
    }

    private void queue_private_room_real_jid_discovery(Account account,
            Jid room, Jid real_jid) {
        if (real_jid.equals(account.bare_jid)) return;
        Jid bare = real_jid.bare_jid;
        if (trust_manager.is_known_address(account, bare)) return;

        if (stream_interactor.get_stream(account) == null) return;
        if (proactive_muc_discovery.enqueue(account, room, bare,
                get_proactive_muc_generation(account))) {
            schedule_proactive_muc_discovery();
        }
    }

    private uint get_proactive_muc_generation(Account account) {
        if (!proactive_muc_generations.has_key(account)) {
            proactive_muc_generations[account] = 1;
        }
        return proactive_muc_generations[account];
    }

    private void advance_proactive_muc_generation(Account account) {
        uint next = get_proactive_muc_generation(account) + 1;
        if (next == 0) next = 1;
        proactive_muc_generations[account] = next;
        proactive_muc_discovery.cancel_account(account.id);
    }

    private void schedule_proactive_muc_discovery() {
        if (proactive_muc_drain_source != 0) return;
        proactive_muc_drain_source = Idle.add_full(GLib.Priority.LOW, () => {
            proactive_muc_drain_source = 0;
            start_proactive_muc_discovery();
            return Source.REMOVE;
        });
    }

    private void start_proactive_muc_discovery() {
        while (true) {
            ProactiveMucDiscoveryHint? next = proactive_muc_discovery.take();
            if (next == null) return;
            ProactiveMucDiscoveryHint hint = (!) next;
            XmppStream? stream = stream_interactor.get_stream(hint.account);
            if (stream == null || hint.generation !=
                    get_proactive_muc_generation(hint.account) ||
                    trust_manager.is_known_address(hint.account,
                        hint.real_jid)) {
                proactive_muc_discovery.complete(hint);
                continue;
            }

            start_one_proactive_muc_discovery(hint, (!) stream);
        }
    }

    private void start_one_proactive_muc_discovery(
            ProactiveMucDiscoveryHint hint, XmppStream stream) {
        fetch_private_muc_member_devices.begin(hint, stream, (obj, res) => {
            fetch_private_muc_member_devices.end(res);
            proactive_muc_discovery.complete(hint);
            schedule_proactive_muc_discovery();
        });
    }

    private bool is_current_proactive_muc_discovery(
            ProactiveMucDiscoveryHint hint, XmppStream stream) {
        return hint.generation == get_proactive_muc_generation(hint.account) &&
            stream_interactor.get_stream(hint.account) == stream;
    }

    private async void fetch_private_muc_member_devices(
            ProactiveMucDiscoveryHint hint, XmppStream stream) {
        if (!is_current_proactive_muc_discovery(hint, stream)) return;

        StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
        if (module != null) {
            yield module.request_user_devicelist(stream, hint.real_jid);
        }
        if (!is_current_proactive_muc_discovery(hint, stream)) return;
        StreamModule2? module2 = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 != null && should_query_omemo2()) {
            yield module2.request_user_devicelist(stream, hint.real_jid);
        }
    }

    internal void on_conversation_cleared(Conversation conversation) {
        /* Local history deletion is not a cryptographic reset.
         *
         * OMEMO Signal sessions are long-lived per contact device. Removing
         * them here breaks incoming normal ratchet messages from clients that
         * still use the existing session, especially after DinoX is restarted
         * before the next message arrives. Device knowledge, trust decisions
         * and sessions are therefore intentionally preserved.
         *
         * Bad-message UI state is cleared by BadMessagesPopulator through the
         * same ConversationManager.conversation_cleared signal. */
        debug("OMEMO: Preserving sessions, device knowledge and trust for %s after local history clear",
              conversation.counterpart.bare_jid.to_string());
    }

    private void on_conference_removed(Account account, Jid room_jid) {
        cancel_private_muc_key_readiness(account, room_jid);
        // When a MUC is destroyed/left, clean OMEMO data stored under the room JID.
        // Member keys (stored under real JIDs) are intentionally preserved.
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        string room_address = room_jid.bare_jid.to_string();

        db.identity_meta.delete()
                .with(db.identity_meta.identity_id, "=", identity_id)
                .with(db.identity_meta.address_name, "=", room_address)
                .perform();

        db.session.delete()
                .with(db.session.identity_id, "=", identity_id)
                .with(db.session.address_name, "=", room_address)
                .perform();

        db.trust.delete()
                .with(db.trust.identity_id, "=", identity_id)
                .with(db.trust.address_name, "=", room_address)
                .perform();

        debug("OMEMO: Cleaned data for removed MUC %s", room_address);
    }

    /**
     * Fully wipe all OMEMO data for a contact (identity_meta, sessions, trust).
     * Used for account removal and MUC cleanup.  NOT used for chat-clear
     * (see on_conversation_cleared which preserves device knowledge).
     */
    internal void clear_contact_data(Account account, Xmpp.Jid jid) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        string address_name = jid.bare_jid.to_string();

        // Delete all OMEMO data for this contact
        db.identity_meta.delete()
                .with(db.identity_meta.identity_id, "=", identity_id)
                .with(db.identity_meta.address_name, "=", address_name)
                .perform();

        db.session.delete()
                .with(db.session.identity_id, "=", identity_id)
                .with(db.session.address_name, "=", address_name)
                .perform();

        db.trust.delete()
                .with(db.trust.identity_id, "=", identity_id)
                .with(db.trust.address_name, "=", address_name)
                .perform();

        // Note: content_item_meta is tied to message_id, already deleted when messages are deleted
    }

    public void clear_device_list(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        stream.get_module<StreamModule>(StreamModule.IDENTITY).clear_device_list(stream);
    }

    private bool try_get_occupants(Jid jid, Account account, out Gee.List<Jid> occupants, out string? block_reason) {
        block_reason = null;
        occupants = new ArrayList<Jid>(Jid.equals_bare_func);
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        // This is a group send. Missing room state must never turn the room
        // address into a direct OMEMO recipient.
        if (!muc_manager.has_live_private_room_features(account, jid)) {
            block_reason = "OMEMO groupchat encryption requires live private members-only non-anonymous room features";
            return false;
        }

        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(account, jid)) {
            block_reason = "OMEMO private-MUC encryption requires completed member, admin and owner affiliation queries";
            warning("OMEMO: Refusing MUC encryption for %s because the private-room affiliation snapshot is incomplete", jid.to_string());
            return false;
        }

        Gee.List<Jid>? occupant_jids = muc_manager.get_private_muc_member_affiliation_snapshot(account, jid);
        if (occupant_jids == null || occupant_jids.size == 0) {
            block_reason = "OMEMO private-MUC encryption requires a known member list";
            warning("OMEMO: Refusing MUC encryption for %s because the private-room member list is empty", jid.to_string());
            return false;
        }

        foreach (Jid occupant in occupant_jids) {
            if (!occupant.equals_bare(account.bare_jid)) {
                occupants.add(occupant.bare_jid);
            }
        }
        if (occupants.size == 0) {
            block_reason = "OMEMO private-MUC encryption requires at least one other known member";
            warning("OMEMO: Refusing MUC encryption for %s because the private-room member list contains only this account", jid.to_string());
            return false;
        }
        return true;
    }

    private Gee.List<Jid> get_message_recipients(Entities.Message message) {
        Gee.List<Jid> recipients = new ArrayList<Jid>(Jid.equals_bare_func);
        if (message.counterpart == null) return recipients;
        if (message.type_ != Entities.Message.Type.GROUPCHAT) {
            recipients.add(message.counterpart.bare_jid);
            return recipients;
        }
        string? block_reason = null;
        if (try_get_occupants(message.counterpart.bare_jid, message.account,
                out recipients, out block_reason)) {
            return recipients;
        }
        return new ArrayList<Jid>(Jid.equals_bare_func);
    }

    private Conversation? get_pending_conversation(Entities.Message message) {
        if (message.counterpart == null) return null;
        // A room and a direct conversation may share a bare JID. A key reply
        // must resume the original kind of send, not the first cache match.
        return stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
            .get_conversation(message.counterpart, message.account, Util.get_conversation_type_for_message(message));
    }

    private Xep.Omemo.EncryptState get_legacy_devicelist_wait_state(Account account, Gee.List<Jid> recipients) {
        var state = new Xep.Omemo.EncryptState();
        state.own_list = has_loaded_legacy_devicelist(account, account.bare_jid);
        if (state.own_list) {
            state.own_devices = trust_manager.get_trusted_devices_omemo1(account, account.bare_jid).size;
        }

        var seen = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        foreach (Jid recipient in recipients) {
            Jid bare = recipient.bare_jid;
            if (!seen.add(bare)) continue;
            if (!has_loaded_legacy_devicelist(account, bare)) {
                state.other_waiting_lists++;
            } else {
                state.other_devices += trust_manager.get_trusted_devices_omemo1(account, bare).size;
            }
        }
        return state;
    }

    private bool legacy_devicelists_are_current(Account account, Gee.List<Jid> recipients) {
        if (!has_loaded_legacy_devicelist(account, account.bare_jid)) return false;
        foreach (Jid recipient in recipients) {
            if (!has_loaded_legacy_devicelist(account, recipient.bare_jid)) return false;
        }
        return true;
    }

    internal MessageState update_send_state(Entities.Message message,
            Xep.Omemo.EncryptState enc_state) {
        lock (message_states) {
            MessageState state;
            if (message_states.has_key(message)) {
                state = message_states.get(message);
                state.update_from_encrypt_status(message, enc_state);
                if (state.will_send_now) {
                    debug("sending message delayed: %s", state.to_string());
                }
            } else {
                state = new MessageState(message, enc_state);
                message_states[message] = state;
            }
            if (state.will_send_now) {
                message_states.unset(message);
            }
            return state;
        }
    }

    internal void forget_pending_messages_for_account(Account account) {
        lock (message_states) {
            var stale = new ArrayList<Entities.Message>();
            foreach (Entities.Message message in message_states.keys) {
                if (message.account == account || (account.id > 0 &&
                        message.account.id == account.id)) {
                    stale.add(message);
                }
            }
            foreach (Entities.Message message in stale) {
                message_states.unset(message);
            }
        }
    }

    private void on_pre_message_send(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        if (message.encryption == Encryption.OMEMO) {
            if (message.type_ == Message.Type.GROUPCHAT_PM) {
                message.marked = Message.Marked.WONTSEND;
                return;
            }
            XmppStream? stream = stream_interactor.get_stream(conversation.account);
            if (stream == null) {
                message.marked = Entities.Message.Marked.UNSENT;
                return;
            }
            StreamModule? module_ = ((!)stream).get_module<StreamModule>(StreamModule.IDENTITY);
            if (module_ == null) {
                message.marked = Entities.Message.Marked.UNSENT;
                return;
            }
            StreamModule module = (!)module_;

            //Get a list of everyone for whom the message should be encrypted
            Gee.List<Jid> recipients;
            if (message_stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
                string? block_reason = null;
                if (!try_get_occupants((!)message.to.bare_jid, conversation.account, out recipients, out block_reason)) {
                    message.delivery_error_text = block_reason;
                    message.marked = Entities.Message.Marked.WONTSEND;
                    return;
                }
            } else {
                recipients = new ArrayList<Jid>(Jid.equals_bare_func);
                recipients.add(message_stanza.to);
            }

            //Attempt to encrypt the message
            /* Use v2 encryptor ONLY if ALL recipients have v2 devices AND none
             * have v1-only devices. This ensures compatibility in MUCs where
             * some members may only support OMEMO v1 (Monal, Conversations).
             * A single v1-only member forces the entire message to use v1 format. */
            bool use_v2 = trust_manager.should_use_omemo2(conversation.account, recipients);

            // An authoritative empty legacy list is a result, not a pending
            // lookup. The encryptor's active-device check alone cannot tell
            // these apart; repeating the query would retry forever.
            if (!use_v2) {
                foreach (Jid recipient in recipients) {
                    if (has_loaded_legacy_devicelist(conversation.account, recipient) &&
                            !trust_manager.is_known_address(conversation.account, recipient)) {
                        message.delivery_error_text = _("No active OMEMO devices were published for %s. Check the recipient's devices, then retry the encrypted message.").printf(recipient.bare_jid.to_string());
                        message.marked = Entities.Message.Marked.WONTSEND;
                        lock (message_states) { message_states.unset(message); }
                        return;
                    }
                }
            }

            Xep.Omemo.EncryptState enc_state;
            bool require_fresh_direct_lists = message.type_ != Entities.Message.Type.GROUPCHAT;
            if (module.store.registration_pending) {
                enc_state = get_legacy_devicelist_wait_state(conversation.account, recipients);
                enc_state.own_list = false;
            } else if (!use_v2 && require_fresh_direct_lists && require_current_legacy_devicelists &&
                    !legacy_devicelists_are_current(conversation.account, recipients)) {
                // Cached database rows cannot reveal a device added while
                // DinoX was offline. Delay encryption until this stream has
                // fetched every relevant legacy device list.
                enc_state = get_legacy_devicelist_wait_state(conversation.account, recipients);
            } else if (use_v2 && encryptors_v2.has_key(conversation.account)) {
                debug("OMEMO 2: Using v2 encryptor for message (recipient has v2 devices)");
                enc_state = encryptors_v2[conversation.account].encrypt(message_stanza, conversation.account.bare_jid, recipients, stream);
            } else {
                enc_state = encryptors[conversation.account].encrypt(message_stanza, conversation.account.bare_jid, recipients, stream);
            }
            MessageState state = update_send_state(message, enc_state);

            //Encryption failed - need to fetch more information
            if (!state.will_send_now) {
                if (message.marked == Entities.Message.Marked.WONTSEND) {
                    debug("retracting message %s", state.to_string());
                    lock (message_states) {
                        message_states.unset(message);
                    }
                } else {
                    debug("delaying message %s", state.to_string());

                    // Fetch bundles via both legacy and v2 modules
                    StreamModule2? module2_delay = ((!)stream).get_module<StreamModule2>(StreamModule2.IDENTITY);

                    if (state.waiting_own_devicelist) {
                        module.request_user_devicelist.begin((!)stream, conversation.account.bare_jid);
                    }
                    if (state.waiting_own_sessions > 0) {
                        Gee.List<int32> own_devices = trust_manager.get_trusted_devices_omemo1(conversation.account, conversation.account.bare_jid);
                        own_devices.remove((int32) module.store.local_registration_id);
                        module.fetch_bundles((!)stream, conversation.account.bare_jid, own_devices);
                        if (use_v2 && module2_delay != null) {
                            Gee.List<int32> own_devices_v2 = trust_manager.get_trusted_devices_omemo2(conversation.account, conversation.account.bare_jid);
                            own_devices_v2.remove((int32) module2_delay.store.local_registration_id);
                            module2_delay.fetch_bundles((!)stream, conversation.account.bare_jid, own_devices_v2);
                        }
                    }
                    if (state.waiting_other_sessions > 0 && message.counterpart != null) {
                        foreach(Jid jid in recipients) {
                            module.fetch_bundles((!)stream, jid, trust_manager.get_trusted_devices_omemo1(conversation.account, jid));
                            if (use_v2 && module2_delay != null) {
                                module2_delay.fetch_bundles((!)stream, jid, trust_manager.get_trusted_devices_omemo2(conversation.account, jid));
                            }
                        }
                    }
                    if (state.waiting_other_devicelists > 0 && message.counterpart != null) {
                        foreach(Jid jid in recipients) {
                            // Re-fetching every already known member here can
                            // create an IQ/retry loop while another list is
                            // still missing. Request only the missing state.
                            if (!trust_manager.is_known_address(conversation.account, jid) ||
                                    (!use_v2 && require_fresh_direct_lists && require_current_legacy_devicelists &&
                                     !has_loaded_legacy_devicelist(conversation.account, jid))) {
                                module.request_user_devicelist.begin((!)stream, jid);
                            }
                        }
                    }
                }
            }
        }
    }

    internal void pre_message_send_for_tests(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        on_pre_message_send(message, message_stanza, conversation);
    }

    private void on_mutual_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if(stream == null) return;

        stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY).request_user_devicelist.begin((!)stream, jid);
        StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 != null && should_query_omemo2()) {
            module2.request_user_devicelist.begin((!)stream, jid);
        }
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        cancel_private_muc_key_readiness_for_account(account);
        advance_proactive_muc_generation(account);
        clear_legacy_devicelist_state(account);
        sanitize_omemo2_runtime_disabled_state(account);
        StreamModule module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module != null && auto_publish_own_device_lists) {
            // Request our device list - this will automatically trigger republish if needed
            module.request_user_devicelist.begin(stream, account.bare_jid, (obj, res) => {
                ArrayList<int32> devices = module.request_user_devicelist.end(res);
                if (stream_interactor.get_stream(account) != stream || devices.size == 0) return;
                // Clean stale devices, then republish clean device list
                cleanup_stale_own_devices(account, stream);
            });
        }
        if (should_query_omemo2()) {
            start_bundle_retry_timer();
        }

        /* Also request OMEMO 2 device list */
        StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 != null && should_publish_own_omemo2()) {
            module2.request_user_devicelist.begin(stream, account.bare_jid);
        }

        if (module2 != null && should_query_omemo2()) {
            /* Request v2 device lists for all active conversation partners.
             * PEP auto-notifications may not arrive for all contacts,
             * so we actively fetch their v2 device lists too. */
            Gee.List<Conversation> conversations = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations(account);
            foreach (Conversation conv in conversations) {
                if (conv.counterpart != null && !conv.counterpart.equals_bare(account.bare_jid)) {
                    module2.request_user_devicelist.begin(stream, conv.counterpart.bare_jid);
                }
            }
        }
    }

    private bool has_omemo1_devices(Account account, Jid jid) {
        return trust_manager.has_omemo1_devices(account, jid);
    }

    private string devicelist_state_key(Account account, Jid jid) {
        return @"$(account.id):$(jid.bare_jid.to_string())";
    }

    private bool has_loaded_legacy_devicelist(Account account, Jid jid) {
        string key = devicelist_state_key(account, jid);
        DateTime? loaded_at = legacy_devicelist_loaded[key];
        if (loaded_at == null) return false;
        if (new DateTime.now_utc().difference((!) loaded_at) > LEGACY_DEVICELIST_MAX_AGE) {
            legacy_devicelist_loaded.unset(key);
            return false;
        }
        return true;
    }

    internal void mark_legacy_devicelist_loaded_for_tests(Account account, Jid jid) {
        legacy_devicelist_loaded[devicelist_state_key(account, jid)] = new DateTime.now_utc();
    }

    private void clear_legacy_devicelist_state(Account account) {
        string prefix = @"$(account.id):";
        var stale_keys = new ArrayList<string>();
        foreach (string key in legacy_devicelist_loaded.keys) {
            if (key.has_prefix(prefix)) {
                stale_keys.add(key);
            }
        }
        foreach (string key in stale_keys) {
            legacy_devicelist_loaded.unset(key);
        }
    }

    /* ── Bundle-Retry-Timer ────────────────────────────────────────
     * Startet einen GLib.Timeout, der alle BUNDLE_RETRY_INTERVAL_SEC
     * Sekunden die Retry-Queue abarbeitet.  Wird nur einmal gestartet
     * und läuft, solange die Queue Einträge hat.
     * ───────────────────────────────────────────────────────────── */
    private void start_bundle_retry_timer() {
        if (bundle_retry_timer_id != 0) return;  // läuft bereits
        bundle_retry_timer_id = Timeout.add_seconds(BUNDLE_RETRY_INTERVAL_SEC, () => {
            process_bundle_retry_queue();
            if (bundle_retry_queue.size == 0) {
                debug("OMEMO 2: Bundle retry queue empty – timer stopped");
                bundle_retry_timer_id = 0;
                return false;  // Timer beenden
            }
            return true;  // weiter laufen lassen
        });
        debug("OMEMO 2: Bundle retry timer started (%d sec interval)", BUNDLE_RETRY_INTERVAL_SEC);
    }

    /* Alle Einträge in der Retry-Queue durchgehen und Bundle erneut
     * vom Server abfragen.  Einträge mit zu vielen Versuchen werden
     * entfernt und das Gerät ignoriert. */
    private void process_bundle_retry_queue() {
        if (bundle_retry_queue.size == 0) return;

        var to_remove = new ArrayList<string>();

        foreach (var entry in bundle_retry_queue.entries) {
            BundleRetryEntry r = entry.value;
            r.attempts++;

            if (r.attempts > BUNDLE_RETRY_MAX_ATTEMPTS) {
                debug("OMEMO 2: Giving up on bundle for %s/%d after %d attempts",
                      r.jid.to_string(), r.device_id, BUNDLE_RETRY_MAX_ATTEMPTS);
                to_remove.add(entry.key);
                continue;
            }

            XmppStream? stream = stream_interactor.get_stream(r.account);
            if (stream == null) continue;

            StreamModule2? module2 = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
            if (module2 == null) continue;

            debug("OMEMO 2: Retry bundle fetch for %s/%d (attempt %d/%d)",
                  r.jid.to_string(), r.device_id, r.attempts, BUNDLE_RETRY_MAX_ATTEMPTS);
            module2.fetch_bundle(stream, r.jid, r.device_id, false);
        }

        foreach (string key in to_remove) {
            bundle_retry_queue.unset(key);
        }
    }

    private void republish_device_list_removing_devices(Account account, XmppStream stream, Gee.List<int32> remove_devices) {
        republish_device_list_from_server.begin(account, stream, remove_devices, false);
    }

    private void republish_device_list_for_label_update(Account account, XmppStream stream) {
        republish_device_list_from_server.begin(account, stream, null, true);
    }

    private async void republish_device_list_from_server(Account account, XmppStream stream, Gee.List<int32>? remove_devices, bool force_publish) {
        if (!auto_publish_own_device_lists) return;
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
        if (module == null) return;
        if (module.store.registration_pending) {
            module.request_user_devicelist.begin(stream, account.bare_jid);
            return;
        }
        int32 current_device_id = (int32) module.store.local_registration_id;
        mark_own_device_available(account, current_device_id, should_publish_own_omemo2());

        ArrayList<int32> server_devices = yield module.request_user_devicelist(stream, account.bare_jid);
        if (stream_interactor.get_stream(account) != stream) return;
        if (server_devices.size == 0 && !has_loaded_legacy_devicelist(account, account.bare_jid)) return;

        ArrayList<int32> devices = new ArrayList<int32>();
        foreach (int32 device_id in server_devices) {
            if (device_id <= 0) continue;
            if (remove_devices != null && ((!) remove_devices).contains(device_id)) continue;
            if (!devices.contains(device_id)) {
                devices.add(device_id);
            }
        }

        if (!devices.contains(current_device_id)) {
             devices.add(current_device_id);
        }

        if (!force_publish && device_lists_equal(server_devices, devices)) return;

        module.publish_own_devicelist(stream, account.bare_jid, devices);
        
        debug("Republished device list for %s with %d devices", account.bare_jid.to_string(), devices.size);
    }

    private bool device_lists_equal(Gee.List<int32> first, Gee.List<int32> second) {
        if (first.size != second.size) return false;
        foreach (int32 device_id in first) {
            if (!second.contains(device_id)) return false;
        }
        return true;
    }

    private void sanitize_omemo2_runtime_disabled_state(Account account) {
        if (trust_manager.omemo2_enabled) return;

        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        int64 active_v2 = db.identity_meta.count_active_omemo2_devices(identity_id);
        if (active_v2 == 0) return;

        db.identity_meta.disable_omemo2_runtime_state(identity_id);
        debug("OMEMO 2 runtime disabled: sanitized %lld active v2 device states for %s",
              active_v2, account.bare_jid.to_string());
    }

    /**
     * Republish OMEMO 2 device list to PubSub based on current DB state.
     * Same intent as the v1 server-derived republish path, but for the urn:xmpp:omemo:2:devices node.
     */
    private void republish_device_list_v2(Account account, XmppStream stream) {
        if (!should_publish_own_omemo2()) return;
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        StreamModule2? module2 = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 == null) return;
        if (module2.store.registration_pending) return;
        int32 current_device_id = (int32) module2.store.local_registration_id;
        mark_own_device_available(account, current_device_id, true);

        // Build the OMEMO 2 device list only from devices that advertise OMEMO 2.
        ArrayList<int32> devices = new ArrayList<int32>();
        foreach (Row row in db.identity_meta.with_address(identity_id, account.bare_jid.to_string())
                .with(db.identity_meta.now_active, "=", true)
                .with(db.identity_meta.supports_omemo2, "=", true)) {
            devices.add(row[db.identity_meta.device_id]);
        }

        // Ensure current device is in the list
        if (!devices.contains(current_device_id)) {
            devices.add(current_device_id);
        }

        module2.publish_own_devicelist(stream, account.bare_jid, devices);

        debug("Republished OMEMO 2 device list for %s with %d devices", account.bare_jid.to_string(), devices.size);
    }

    private void mark_own_device_available(Account account, int32 device_id, bool supports_omemo2 = false) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0 || device_id <= 0) return;

        db.identity_meta.upsert()
            .value(db.identity_meta.identity_id, identity_id, true)
            .value(db.identity_meta.address_name, account.bare_jid.to_string(), true)
            .value(db.identity_meta.device_id, device_id, true)
            .value(db.identity_meta.identity_key_public_base64, db.identity.row_with(db.identity.account_id, account.id)[db.identity.identity_key_public_base64])
            .value(db.identity_meta.trust_level, TrustLevel.TRUSTED)
            .value(db.identity_meta.supports_omemo1, true)
            .value(db.identity_meta.supports_omemo2, supports_omemo2)
            .value(db.identity_meta.now_active, true)
            .value(db.identity_meta.last_active, (long) new DateTime.now_utc().to_unix())
            .perform();
    }

    private bool identity_key_would_change(int identity_id, Jid jid,
            int32 device_id, string new_identity_key_base64) throws Error {
        Row? device = db.identity_meta.get_device_checked(identity_id,
                jid.bare_jid.to_string(), device_id);
        return device != null &&
            device[db.identity_meta.identity_key_public_base64] != null &&
            device[db.identity_meta.identity_key_public_base64] != new_identity_key_base64;
    }

    private bool restore_identity_transition_memory(Store store,
            Address address, uint8[]? previous_session,
            uint8[]? previous_identity, string protocol_label,
            Error original_error) {
        bool restore_failed = false;
        string failure_details = "";
        BackedSessionStore? session_store =
                store.session_store as BackedSessionStore;
        if (session_store == null) {
            restore_failed = true;
            failure_details += " session-store-not-backed";
        } else {
            try {
                ((!) session_store).restore_memory_only(address,
                        previous_session);
            } catch (Error e) {
                restore_failed = true;
                failure_details += " session: " + e.message;
            }
        }

        // The native remote-identity store is memory-only. SQLCipher's
        // identity_meta row was already restored by ROLLBACK TO SAVEPOINT.
        try {
            if (previous_identity == null) {
                store.identity_key_store.delete_identity(address);
            } else {
                store.identity_key_store.save_identity(address,
                        (!) previous_identity);
            }
        } catch (Error e) {
            restore_failed = true;
            failure_details += " identity: " + e.message;
        }

        if (restore_failed) {
            store.mark_persistence_unavailable();
            critical("OMEMO %s: In-memory identity transition rollback failed after '%s': %s; disabling the account store",
                    protocol_label, original_error.message,
                    failure_details.strip());
        }
        return !restore_failed;
    }

    private bool persist_bundle_and_start_session(Account account, Jid jid,
            int32 device_id, ECPublicKey identity_key,
            string identity_key_base64, TrustLevel trust,
            bool identity_changed, string protocol_label,
            Bundle? legacy_bundle = null,
            Bundle2? omemo2_bundle = null,
            bool build_session = true) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        int identity_id;
        try {
            identity_id = db.identity.get_id_checked(account.id);
        } catch (Error e) {
            warning("OMEMO %s: Failed to read the persistent account identity before changing %s/%d: %s",
                    protocol_label, jid.bare_jid.to_string(), device_id,
                    e.message);
            return false;
        }
        if (identity_id <= 0) return false;

        Store? store = null;
        StreamModule? module = ((!) stream).get_module<StreamModule>(StreamModule.IDENTITY);
        StreamModule2? module2 = ((!) stream).get_module<StreamModule2>(StreamModule2.IDENTITY);
        if (legacy_bundle != null && module != null) {
            store = module.store;
        } else if (omemo2_bundle != null && module2 != null) {
            store = module2.store;
        }

        if (store == null || (legacy_bundle == null && omemo2_bundle == null)) {
            return false;
        }
        try {
            ((!) store).require_persistence_ready();
        } catch (Error e) {
            warning("OMEMO %s: Persistent store is unavailable before bundle processing for %s/%d: %s",
                    protocol_label, jid.bare_jid.to_string(), device_id,
                    e.message);
            return false;
        }

        string address_name = jid.bare_jid.to_string();
        Address address = new Address(address_name, device_id);
        uint8[]? previous_session = null;
        uint8[]? previous_identity = null;
        bool savepoint_active = false;
        bool mutation_started = false;
        try {
            previous_session = ((!) store).session_store.load_session(address);
            previous_identity = ((!) store).identity_key_store.load_identity(address);
            db.exec("SAVEPOINT omemo_identity_change");
            savepoint_active = true;
            mutation_started = true;
            if (identity_changed && ((!) store).contains_session(address)) {
                ((!) store).delete_session(address);
                debug("OMEMO %s: Deleted stale session for %s/%d after identity key change",
                      protocol_label, address_name, device_id);
            }
            if (identity_changed) {
                // libsignal keeps a separate in-memory identity store. Updating
                // it here is required before SessionBuilder can accept the new
                // bundle. Application-level trust remains UNKNOWN in the DB.
                ((!) store).save_identity(address, identity_key);
            }
            db.identity_meta.insert_device_session_checked(identity_id,
                    address_name, device_id, identity_key_base64, trust);

            // Discovery persists authenticated metadata without a ratchet.
            // When a send requires a session, keep its native construction
            // inside this savepoint as well: any SessionBuilder/store failure
            // must restore the previously working identity/session state.
            bool session_ready = !build_session;
            if (build_session && legacy_bundle != null && module != null) {
                session_ready = ((!) module).start_session((!) stream, jid,
                        device_id, (!) legacy_bundle);
            } else if (build_session && omemo2_bundle != null && module2 != null) {
                session_ready = ((!) module2).start_session((!) stream, jid,
                        device_id, (!) omemo2_bundle);
            }
            if (!session_ready) {
                throw new GLib.Error(
                        Quark.from_string("omemo-session-transition"),
                        ErrorCode.UNKNOWN,
                        "Authenticated bundle did not produce a persistent session");
            }
            db.exec("RELEASE SAVEPOINT omemo_identity_change");
            savepoint_active = false;
        } catch (Error e) {
            bool rollback_failed = false;
            if (savepoint_active) {
                try {
                    db.exec("ROLLBACK TO SAVEPOINT omemo_identity_change");
                    db.exec("RELEASE SAVEPOINT omemo_identity_change");
                } catch (Error rollback_error) {
                    rollback_failed = true;
                    warning("OMEMO %s: Database rollback failed for %s/%d: %s",
                            protocol_label, address_name, device_id,
                            rollback_error.message);
                }
            }
            if (rollback_failed) {
                ((!) store).mark_persistence_unavailable();
            }
            bool memory_restored = true;
            if (mutation_started) {
                memory_restored = restore_identity_transition_memory(
                        (!) store, address, previous_session,
                        previous_identity, protocol_label, e);
            }
            if (mutation_started && !rollback_failed && memory_restored &&
                    ((!) store).is_persistence_ready) {
                if (legacy_bundle != null && module != null) {
                    ((!) module).unignore_device(jid, device_id);
                } else if (omemo2_bundle != null && module2 != null) {
                    ((!) module2).unignore_device(jid, device_id);
                }
            }
            warning("OMEMO %s: Failed to persist identity transition for %s/%d: %s",
                    protocol_label, address_name, device_id, e.message);
            address.device_id = 0;
            return false;
        }
        address.device_id = 0;
        device_trust_state_changed(account, jid.bare_jid);
        return true;
    }

    /**
     * Entfernt veraltete eigene Geräte aus der Device-List (v1+v2) und der lokalen DB.
     * Wird nach dem Laden der Device-List beim Connect aufgerufen.
     *
     * Ablauf:
     * 1. Alle eigenen Geräte in identity_meta, die NICHT das aktuelle Gerät sind,
     *    werden als now_active=false markiert.
     * 2. Die bereinigte Device-List wird auf dem Server veröffentlicht (v1 + v2).
     * 3. Veraltete v1-Bundle-Nodes werden vom PubSub gelöscht.
     * 4. Veraltete v2-Bundle-Items werden vom PubSub zurückgezogen.
     */
    private string[] device_list_to_strings(ArrayList<int32> devices) {
        string[] result = new string[devices.size];
        for (int i = 0; i < devices.size; i++) {
            result[i] = devices[i].to_string();
        }
        return result;
    }

    private void cleanup_stale_own_devices(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
        if (module == null) return;
        int32 own_device_id = (int32) module.store.local_registration_id;
        if (own_device_id == 0) return;

        string own_jid = account.bare_jid.to_string();

        // Only remove TRUE phantom devices: those without an identity key.
        // Devices WITH an identity key are legitimate other clients (e.g. Monal,
        // Conversations) using the same JID — they must NOT be removed.
        debug("OMEMO cleanup: own_device_id=%d, checking active devices for %s", own_device_id, own_jid);
        var stale_devices = new ArrayList<int32>();
        int kept_count = 0;
        foreach (Row row in db.identity_meta.with_address(identity_id, own_jid)
                .with(db.identity_meta.device_id, "!=", own_device_id)
                .with(db.identity_meta.now_active, "=", true)) {
            int32 dev_id = row[db.identity_meta.device_id];
            string? pub_key = row[db.identity_meta.identity_key_public_base64];
            if (pub_key == null || pub_key.length == 0) {
                bool supports_omemo1 = row[db.identity_meta.supports_omemo1];
                bool supports_omemo2 = row[db.identity_meta.supports_omemo2];
                if (supports_omemo1 || supports_omemo2) {
                    // Still server-advertised in at least one OMEMO stack. Bundle
                    // fetch may be pending or rate-limited; do not delete a real
                    // same-JID device just because the local identity key is not
                    // stored yet.
                    debug("OMEMO cleanup: device %d → KEPT (advertised, bundle pending)", dev_id);
                    kept_count++;
                    continue;
                }
                debug("OMEMO cleanup: device %d → PHANTOM (no protocol support/key) → will remove", dev_id);
                stale_devices.add(dev_id);
            } else {
                debug("OMEMO cleanup: device %d → KEPT (has identity key)", dev_id);
                kept_count++;
            }
        }

        if (stale_devices.size == 0) {
            // No server-visible state changed. Missing current devices are added
            // by parse_device_list(); avoid a duplicate publish on every login.
            debug("OMEMO cleanup: no phantoms found, %d other devices kept", kept_count);
            return;
        }

        debug("OMEMO: Cleaning %d stale phantom devices for %s (no identity key)", stale_devices.size, own_jid);

        // Deactivate only phantom devices (no identity key)
        foreach (int32 stale_id in stale_devices) {
            db.identity_meta.update()
                .with(db.identity_meta.identity_id, "=", identity_id)
                .with(db.identity_meta.address_name, "=", own_jid)
                .with(db.identity_meta.device_id, "=", stale_id)
                .set(db.identity_meta.now_active, false)
                .perform();
        }

        if (stream_interactor.get_stream(account) != stream) return;

        // Bereinigte Device-List veröffentlichen (enthält nur noch unser Gerät)
        republish_device_list_removing_devices(account, stream, stale_devices);

        var pubsub = stream.get_module<Xep.Pubsub.Module>(Xep.Pubsub.Module.IDENTITY);
        if (should_publish_own_omemo2()) {
            // Delete then republish v2 devicelist node to clear accumulated old items.
            // Keep the publish after the async delete result; otherwise a delayed delete
            // can remove the freshly republished "current" item and leave the v2 node
            // temporarily missing on real PEP servers.
            if (pubsub != null) {
                debug("OMEMO: Deleting v2 devicelist node to clear stale items");
                pubsub.delete_node_async.begin(stream, account.bare_jid, Xep.Omemo.NODE_DEVICELIST_V2, (obj, res) => {
                    bool deleted = pubsub.delete_node_async.end(res);
                    if (!deleted) {
                        debug("OMEMO: v2 devicelist node delete did not succeed; republishing current item anyway");
                    }
                    if (stream_interactor.get_stream(account) == stream) {
                        republish_device_list_v2(account, stream);
                    }
                });
            } else {
                republish_device_list_v2(account, stream);
            }
        }

        // Veraltete v1-Bundle-Nodes löschen
        if (pubsub != null) {
            foreach (int32 stale_id in stale_devices) {
                if (stream_interactor.get_stream(account) != stream) return;
                string v1_bundle_node = NODE_BUNDLES + ":" + stale_id.to_string();
                debug("OMEMO: Deleting stale v1 bundle node %s", v1_bundle_node);
                pubsub.delete_node(stream, account.bare_jid, v1_bundle_node);

                if (should_publish_own_omemo2()) {
                    debug("OMEMO: Retracting stale v2 bundle item %d", stale_id);
                    pubsub.retract_item.begin(stream, account.bare_jid, NODE_BUNDLES_V2, stale_id.to_string());
                }
            }
        }

        debug("OMEMO: Stale phantom device cleanup done for %s — removed %d devices", own_jid, stale_devices.size);
    }

    private void on_account_added(Account account) {
        get_proactive_muc_generation(account);
        StreamModule module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module != null) {
            module.device_list_loaded.connect((jid, devices) => on_device_list_loaded(account, jid, devices));
            module.device_list_fetch_failed.connect((jid, result) => on_device_list_fetch_failed(account, jid, result));
            module.bundle_ready.connect((jid, device_id, bundle, build_session) => on_bundle_fetched(account, jid, device_id, bundle, build_session));
            module.bundle_fetch_failed.connect((jid) => continue_message_sending(account, jid));
            module.bundle_access_denied.connect((jid, device_id, presence_required) =>
                on_bundle_access_denied(account, jid, device_id, presence_required));
            module.registration_candidate_ready.connect(() => {
                load_own_device_label(account, module);
                mark_own_device_available(account, (int32) module.store.local_registration_id, should_publish_own_omemo2());
                if (module.own_device_label != null) {
                    int identity_id = db.identity.get_id(account.id);
                    db.identity_meta.update_device_label(identity_id, account.bare_jid.to_string(),
                            (int32) module.store.local_registration_id, (!) module.own_device_label);
                }
            });
            module.store.notify["registration-pending"].connect(() => {
                StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
                configure_omemo2_publish(module2);
                XmppStream? stream = stream_interactor.get_stream(account);
                if (!module.store.registration_pending && stream != null &&
                        module2 != null && should_publish_own_omemo2()) {
                    ((!) module2).request_user_devicelist.begin((!) stream, account.bare_jid);
                }
            });
            module.device_label_received.connect((jid, device_id, label) => {
                int identity_id = db.identity.get_id(account.id);
                if (identity_id >= 0) {
                    db.identity_meta.update_device_label(identity_id, jid.bare_jid.to_string(), device_id, label);
                    debug("OMEMO 1: Stored device label '%s' for %s/%d", label, jid.to_string(), device_id);
                }
            });
        }
        /* OMEMO 2 stream module */
        StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 != null) {
            module2.device_list_loaded.connect((jid, devices) => {
                /* Handle v2 device list separately -- must be ADDITIVE.
                 * DO NOT call on_device_list_loaded() here! That function
                 * uses insert_device_list() which destructively deactivates
                 * ALL existing devices before reactivating listed ones.
                 * An empty v2 list (contact doesn't support OMEMO 2) would
                 * wipe all v1 devices. Even a non-empty v2 list would
                 * deactivate v1-only devices. */
                on_device_list_loaded_v2(account, jid, devices);
            });
            module2.bundle_fetched.connect((jid, device_id, bundle) => on_bundle_v2_fetched(account, jid, device_id, bundle));
            module2.bundle_fetch_failed.connect((jid) => continue_message_sending(account, jid));
            module2.device_label_received.connect((jid, device_id, label) => {
                int identity_id = db.identity.get_id(account.id);
                if (identity_id >= 0) {
                    db.identity_meta.update_device_label(identity_id, jid.bare_jid.to_string(), device_id, label);
                    debug("OMEMO 2: Stored device label '%s' for %s/%d", label, jid.to_string(), device_id);
                }
            });
        }
        schedule_store_initialization(account);
    }

    private void on_account_removed(Account account) {
        forget_pending_messages_for_account(account);
        cancel_private_muc_key_readiness_for_account(account);
        cancel_pending_store_initialization(account);
        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module != null) {
            ((!) module).store.discard_sensitive_state();
        } else {
            StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
            if (module2 != null) ((!) module2).store.discard_sensitive_state();
        }
        encryptors.unset(account);
        encryptors_v2.unset(account);
        advance_proactive_muc_generation(account);
        clear_legacy_devicelist_state(account);
        // Clean up all OMEMO data for this account from omemo.db
        bool savepoint_active = false;
        try {
            int identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) return;

            db.exec("SAVEPOINT omemo_account_removal");
            savepoint_active = true;

            // Delete child tables first (reference identity_id), but expose
            // none of the deletion until every table and the own keypair have
            // been removed successfully.
            db.content_item_meta.delete().with(db.content_item_meta.identity_id, "=", identity_id).perform_checked();
            db.trust.delete().with(db.trust.identity_id, "=", identity_id).perform_checked();
            db.identity_meta.delete().with(db.identity_meta.identity_id, "=", identity_id).perform_checked();
            db.session.delete().with(db.session.identity_id, "=", identity_id).perform_checked();
            db.pre_key.delete().with(db.pre_key.identity_id, "=", identity_id).perform_checked();
            db.signed_pre_key.delete().with(db.signed_pre_key.identity_id, "=", identity_id).perform_checked();
            db.identity.delete().with(db.identity.account_id, "=", account.id).perform_checked();

            db.exec("RELEASE SAVEPOINT omemo_account_removal");
            savepoint_active = false;
        } catch (Error e) {
            if (savepoint_active) {
                try {
                    db.exec("ROLLBACK TO SAVEPOINT omemo_account_removal");
                    db.exec("RELEASE SAVEPOINT omemo_account_removal");
                } catch (Error rollback_error) {
                    critical("OMEMO: Database rollback failed while removing account %d after '%s': %s",
                            account.id, e.message, rollback_error.message);
                    return;
                }
            }
            warning("OMEMO: Failed to remove the persistent cryptographic state for account %d: %s",
                    account.id, e.message);
        }

    }

    private void on_device_list_loaded(Account account, Jid jid, ArrayList<int32> device_list) {
        // Filter out non-user JIDs (PubSub services, MUC room JIDs, server components)
        string bare_str = jid.bare_jid.to_string();
        if (!bare_str.contains("@") || stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_groupchat(jid.bare_jid, account)) {
            debug("OMEMO: Ignoring device list from non-user JID %s", bare_str);
            return;
        }
        debug("received device list for %s from %s", account.bare_jid.to_string(), jid.to_string());

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) {
            return;
        }
        StreamModule? module = ((!)stream).get_module<StreamModule>(StreamModule.IDENTITY);
        if (module == null) {
            return;
        }

        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;
        legacy_devicelist_loaded[devicelist_state_key(account, jid)] = new DateTime.now_utc();

        /* Multi-Device-sicher: Device-Listen vom Server werden
         * unveraendert uebernommen. Echte Geraete (Handy, Tablet)
         * behalten ihre Device-IDs. Stale Devices blockieren das
         * Senden nicht; unbekannte eigene Geraete blockieren bis zur
         * Session-Reparatur oder Ignore-Klassifizierung.
         * cleanup_stale_own_devices() raeumt nur wirklich tote
         * Geraete auf (kein Identity Key = nie ein Bundle gesehen). */
        if (jid.equals_bare(account.bare_jid)) {
            debug("OMEMO device_list_loaded: OWN JID %s — server sent %d devices: %s",
                  jid.to_string(), device_list.size,
                  string.joinv(", ", device_list_to_strings(device_list)));
        }
        db.identity_meta.insert_device_list(identity_id, jid.bare_jid.to_string(), device_list);
        // Also notify for an empty list: the last trusted device may be gone.
        device_trust_state_changed(account, jid.bare_jid);

        // Fetch the bundle for each new device via legacy OMEMO. Do not start
        // v2 bundle fetches for a JID that just advertised v1; the shared
        // identity/session store must remain driven by the legacy stack for
        // mixed OMEMO1/OMEMO2 Bare-JIDs.
        StreamModule2? module2 = ((!)stream).get_module<StreamModule2>(StreamModule2.IDENTITY);
        int inc = 0;
        foreach (Row row in db.identity_meta.get_unknown_devices(identity_id, jid.bare_jid.to_string())) {
            try {
                Jid device_jid = new Jid(row[db.identity_meta.address_name]);
                int device_id = row[db.identity_meta.device_id];
                module.fetch_bundle_info(stream, device_jid, device_id, false);
                inc++;
            } catch (InvalidJidError e) {
                warning("Ignoring device with invalid Jid: %s", e.message);
            }
        }
        if (inc > 0) {
            debug("new legacy bundles %i/%i for %s", inc, device_list.size, jid.to_string());
        }

        /* Also fetch v2 bundles for known devices without a session,
         * but ONLY for v2-only JIDs.  For JIDs with v1 devices we use the
         * v1 encryptor, and a v4 session in the shared store would produce
         * messages with a broken version byte (SG_ERR_LEGACY_MESSAGE). */
        string dl_bare = jid.bare_jid.to_string();
        if (should_query_omemo2() && module2 != null && !has_omemo1_devices(account, jid)) {
            int v2_inc = 0;
            foreach (int32 device_id in device_list) {
                Address address = new Address(dl_bare, device_id);
                try {
                    if (!module.store.contains_session(address)) {
                        module2.fetch_bundle(stream, jid, device_id, false);
                        v2_inc++;
                    }
                } catch (Error e) {
                    // ignore
                }
                address.device_id = 0;
            }
            if (v2_inc > 0) {
                debug("v2 session-less bundles %i/%i for %s", v2_inc, device_list.size, dl_bare);
            }
        }

        //Create an entry for the jid in the account table if one does not exist already
        if (db.trust.select().with(db.trust.identity_id, "=", identity_id).with(db.trust.address_name, "=", jid.bare_jid.to_string()).count() == 0) {
            db.trust.insert().value(db.trust.identity_id, identity_id).value(db.trust.address_name, jid.bare_jid.to_string()).value(db.trust.blind_trust, true).perform();
        }

        // An authoritative list may remove a device whose bundle/session was
        // pending. Old attempt counters then cannot settle via its callback.
        // Re-run normal encryption for affected sends so current active devices
        // are checked again, including any newly added unknown devices.
        HashSet<Entities.Message> send_now = new HashSet<Entities.Message>();
        lock (message_states) {
            foreach (var entry in message_states.entries) {
                Entities.Message msg = entry.key;
                if (msg.account != account &&
                        (account.id <= 0 || msg.account.id != account.id)) continue;
                MessageState state = entry.value;
                if (state == null || state.active_send_attempt ||
                        msg.marked != Entities.Message.Marked.UNSENT ||
                        msg.counterpart == null) continue;
                bool relevant_list = account.bare_jid.equals_bare(jid);
                if (!relevant_list) {
                    Gee.List<Jid> occupants = get_message_recipients(msg);
                    relevant_list = occupants.contains(jid);
                }
                if (relevant_list) {
                    send_now.add(msg);
                    state.active_send_attempt = true;
                }
            }
        }
        foreach (Entities.Message msg in send_now) {
            if (msg.counterpart == null) continue;
            Entities.Conversation? conv = get_pending_conversation(msg);
            if (conv == null) continue;
            stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(msg, (!)conv, true);
        }

        if (device_list.size > 0) {
            advance_private_muc_device_generation(account, jid);
            notify_private_muc_readiness_watches(account, jid, true);
        }

    }

    internal void device_list_loaded_for_tests(Account account, Jid jid,
            ArrayList<int32> device_list) {
        on_device_list_loaded(account, jid, device_list);
    }

    internal void on_device_list_fetch_failed(Account account, Jid jid,
            Xep.Pubsub.RequestAllResult? result = null) {
        lock (message_states) {
            var failed = new ArrayList<Entities.Message>();
            foreach (var entry in message_states.entries) {
                Entities.Message msg = entry.key;
                if (msg.account != account &&
                        (account.id <= 0 || msg.account.id != account.id)) continue;
                MessageState state = entry.value;
                if (state == null || state.active_send_attempt ||
                        msg.marked != Entities.Message.Marked.UNSENT ||
                        msg.type_ != Entities.Message.Type.CHAT) continue;
                bool waiting_for_list = account.bare_jid.equals_bare(jid)
                    ? state.waiting_own_devicelist
                    : state.waiting_other_devicelists > 0 &&
                        msg.counterpart != null && msg.counterpart.equals_bare(jid);
                if (!waiting_for_list) continue;

                msg.delivery_error_text = result != null && ((!) result).is_access_denied()
                    ? omemo_access_error_text(((!) result).presence_subscription_required,
                        account.bare_jid.equals_bare(jid))
                    : _("Could not retrieve the OMEMO device list. Retry the encrypted message.");
                msg.marked = Entities.Message.Marked.ERROR;
                failed.add(msg);
            }
            foreach (Entities.Message msg in failed) {
                message_states.unset(msg);
            }
        }
    }

    private static string omemo_access_error_text(bool presence_required, bool own_keys) {
        if (own_keys) {
            return presence_required
                ? _("The server requires a presence subscription to access this account's OMEMO keys. Check account permissions, then retry the encrypted message.")
                : _("The server denied access to this account's OMEMO keys. Check account permissions, then retry the encrypted message.");
        }
        return presence_required
            ? _("OMEMO key access requires a presence subscription. Ask the contact to approve it, then retry the encrypted message.")
            : _("The server denied access to the OMEMO keys. Check contact permissions, then retry the encrypted message.");
    }

    internal void on_bundle_access_denied(Account account, Jid jid,
            int device_id, bool presence_required = false) {
        XmppStream? stream = stream_interactor.get_stream(account);
        StreamModule? module = stream != null
            ? ((!) stream).get_module<StreamModule>(StreamModule.IDENTITY) : null;
        if (module == null || device_id <= 0 ||
                !trust_manager.get_trusted_devices_omemo1(account, jid).contains(device_id)) return;
        // Metadata discovery for the current sender is not a missing receiver
        // session and must not fail a send waiting for another own device.
        if (jid.equals_bare(account.bare_jid) &&
                device_id == (int32) ((!) module).store.local_registration_id) return;
        // Revalidate the current native store: a metadata query can be denied
        // even while a usable session already exists. That does not block send.
        if (((!) module).has_legacy_session_for_send(jid, device_id)) return;
        StreamModule2? module2 = ((!) stream).get_module<StreamModule2>(StreamModule2.IDENTITY);
        // Match the current encryptor's recipient selection: metadata denial
        // for an already skipped device cannot block another needed device.
        if (((!) module).is_ignored_device(jid, device_id) &&
                (module2 == null || ((!) module2).is_ignored_device(jid, device_id))) return;

        lock (message_states) {
            var failed = new ArrayList<Entities.Message>();
            foreach (var entry in message_states.entries) {
                Entities.Message msg = entry.key;
                if (msg.account != account &&
                        (account.id <= 0 || msg.account.id != account.id)) continue;
                MessageState state = entry.value;
                if (state == null || state.active_send_attempt ||
                        msg.marked != Entities.Message.Marked.UNSENT ||
                        (msg.type_ != Entities.Message.Type.CHAT &&
                         msg.type_ != Entities.Message.Type.GROUPCHAT)) continue;
                bool group_recipient = false;
                if (msg.type_ == Entities.Message.Type.GROUPCHAT) {
                    MucManager? muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
                    if (muc == null || msg.counterpart == null ||
                            !((!) muc).is_groupchat(msg.counterpart.bare_jid, account) ||
                            !((!) muc).has_live_private_room_features(account, msg.counterpart.bare_jid) ||
                            !((!) muc).has_complete_private_muc_affiliation_snapshot(account, msg.counterpart.bare_jid)) continue;
                    Gee.List<Jid>? members = ((!) muc).get_private_muc_member_affiliation_snapshot(account, msg.counterpart.bare_jid);
                    group_recipient = account.bare_jid.equals_bare(jid);
                    if (members != null) {
                        foreach (Jid member in (!) members) {
                            if (member.equals_bare(jid)) group_recipient = true;
                        }
                    }
                    if (!group_recipient) continue;
                }
                bool waiting_for_session = account.bare_jid.equals_bare(jid)
                    ? state.waiting_own_sessions > 0
                    : state.waiting_other_sessions > 0 &&
                        (group_recipient ||
                         (msg.counterpart != null && msg.counterpart.equals_bare(jid)));
                if (!waiting_for_session) continue;
                msg.delivery_error_text = omemo_access_error_text(presence_required,
                    account.bare_jid.equals_bare(jid));
                msg.marked = Entities.Message.Marked.ERROR;
                failed.add(msg);
            }
            foreach (Entities.Message msg in failed) message_states.unset(msg);
        }
    }

    /**
     * Handle OMEMO 2 device list results -- ADDITIVE processing.
     * Unlike the v1 handler, this does NOT deactivate existing devices.
     * Empty v2 lists are ignored (contact doesn't support OMEMO 2).
     */
    private void on_device_list_loaded_v2(Account account, Jid jid, ArrayList<int32> device_list) {
        // Filter out non-user JIDs (PubSub services, MUC room JIDs, server components)
        string bare_str = jid.bare_jid.to_string();
        if (!bare_str.contains("@") || stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_groupchat(jid.bare_jid, account)) {
            debug("OMEMO 2: Ignoring v2 device list from non-user JID %s", bare_str);
            return;
        }
        if (!should_query_omemo2()) {
            debug("OMEMO 2: Ignoring v2 device list for %s because OMEMO2 is disabled", bare_str);
            continue_message_sending(account, jid);
            return;
        }

        debug("OMEMO 2: received v2 device list for %s (%d devices)", jid.to_string(), device_list.size);

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        /* Multi-Device-sicher: v2-Device-Listen unveraendert uebernehmen. */

        // Replace the v2 view while preserving legacy-only devices.
        db.identity_meta.insert_device_list_omemo2(identity_id, jid.bare_jid.to_string(), device_list);
        device_trust_state_changed(account, jid.bare_jid);

        if (device_list.size == 0) {
            continue_message_sending(account, jid);
            return;
        }

        // Create trust entry if needed
        if (db.trust.select().with(db.trust.identity_id, "=", identity_id).with(db.trust.address_name, "=", jid.bare_jid.to_string()).count() == 0) {
            db.trust.insert().value(db.trust.identity_id, identity_id).value(db.trust.address_name, jid.bare_jid.to_string()).value(db.trust.blind_trust, true).perform();
        }

        // Fetch v2 bundles only for v2-only JIDs. In mixed v1/v2 JIDs the
        // legacy stack remains the active interop path; writing v2 identity
        // keys into the shared identity column would flap trust/session state.
        StreamModule2? module2 = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
        bool has_legacy_devices = has_omemo1_devices(account, jid);
        if (module2 != null && !has_legacy_devices) {
            if (!has_loaded_legacy_devicelist(account, jid)) {
                StreamModule? module = stream.get_module<StreamModule>(StreamModule.IDENTITY);
                if (module != null) {
                    debug("OMEMO 2: delaying v2 bundle fetches for %s until legacy device-list is checked",
                          jid.bare_jid.to_string());
                    module.request_user_devicelist.begin(stream, jid, (obj, res) => {
                        module.request_user_devicelist.end(res);
                        if (stream_interactor.get_stream(account) != stream) return;
                        if (has_loaded_legacy_devicelist(account, jid) && !has_omemo1_devices(account, jid)) {
                            fetch_v2_bundles_for_known_devices(account, stream, jid, device_list);
                        } else {
                            debug("OMEMO 2: not fetching v2 bundles for %s after legacy check (has_v1=%s loaded=%s)",
                                  jid.bare_jid.to_string(), has_omemo1_devices(account, jid).to_string(),
                                  has_loaded_legacy_devicelist(account, jid).to_string());
                        }
                    });
                }
            } else {
                fetch_v2_bundles_for_known_devices(account, stream, jid, device_list);
            }
        }

        // Continue any waiting messages
        continue_message_sending(account, jid);
        advance_private_muc_device_generation(account, jid);
        notify_private_muc_readiness_watches(account, jid, true);
    }

    private void fetch_v2_bundles_for_known_devices(Account account, XmppStream stream, Jid jid, ArrayList<int32> device_list) {
        if (!should_query_omemo2()) return;
        if (stream_interactor.get_stream(account) != stream) return;
        if (has_omemo1_devices(account, jid)) return;

        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        StreamModule2? module2 = stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
        if (module2 == null) return;

        int v2_fetches = 0;
        foreach (Row row in db.identity_meta.with_address(identity_id, jid.bare_jid.to_string())
                .with(db.identity_meta.now_active, "=", true)
                .with(db.identity_meta.supports_omemo2, "=", true)) {
            int32 device_id = row[db.identity_meta.device_id];
            string? identity_key = row[db.identity_meta.identity_key_public_base64];
            bool missing_identity = identity_key == null || identity_key.length == 0;
            bool missing_session = false;
            Address address = new Address(jid.bare_jid.to_string(), device_id);
            try {
                missing_session = !module2.store.contains_session(address);
            } catch (Error e) {
                // ignore
            }
            address.device_id = 0;
            if (missing_identity || missing_session) {
                module2.fetch_bundle(stream, jid, device_id, false);
                v2_fetches++;
            }
        }
        if (v2_fetches > 0) {
            debug("OMEMO 2: v2 bundle fetches %d/%d for %s (v2-only)",
                  v2_fetches, device_list.size, jid.bare_jid.to_string());
        }
    }

    private void on_bundle_fetched(Account account, Jid jid, int32 device_id, Bundle bundle, bool build_session) {
        if (!StreamModule.is_valid_legacy_bundle(bundle)) {
            warning("OMEMO 1: Ignoring broken bundle for %s/%d",
                    jid.bare_jid.to_string(), device_id);
            continue_message_sending(account, jid);
            return;
        }

        ECPublicKey identity_key = (!) bundle.identity_key;
        string identity_key_b64 = Base64.encode(identity_key.serialize());
        int identity_id;
        bool blind_trust;
        bool key_changed;
        Row? device;
        try {
            identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) {
                throw new GLib.Error(Quark.from_string("omemo-identity-store"),
                        ErrorCode.UNKNOWN,
                        "Persistent OMEMO account identity is unavailable");
            }
            blind_trust = db.trust.get_blind_trust_checked(identity_id,
                    jid.bare_jid.to_string(), true);
            device = db.identity_meta.get_device_checked(identity_id,
                    jid.bare_jid.to_string(), device_id);
            key_changed = identity_key_would_change(identity_id, jid,
                    device_id, identity_key_b64);
        } catch (Error e) {
            warning("OMEMO 1: Failed to read persistent trust state for %s/%d: %s",
                    jid.bare_jid.to_string(), device_id, e.message);
            continue_message_sending(account, jid);
            return;
        }

        // If blind trust is disabled, only the exact identity key already
        // stored for this device is known. A read failure above is fatal for
        // this transition and must never be treated as an unknown device.
        bool known_identity = device != null &&
                ((!) device)[db.identity_meta.identity_key_public_base64] != null &&
                ((!) device)[db.identity_meta.identity_key_public_base64] == identity_key_b64;
        bool untrust = !(blind_trust || known_identity);

        // Get trust information from the database if the device id is known.
        TrustLevel trusted = TrustLevel.UNKNOWN;
        if (device != null) {
            trusted = (TrustLevel) ((!) device)[db.identity_meta.trust_level];
        }

        if(untrust) {
            trusted = TrustLevel.UNKNOWN;
        } else if (blind_trust && trusted == TrustLevel.UNKNOWN) {
            trusted = TrustLevel.TRUSTED;
        }

        // This also covers the same-identity v4-to-v3 replacement performed
        // by StreamModule.start_session(): metadata, session deletion and the
        // replacement ratchet commit or roll back as one unit.
        bool session_ready = persist_bundle_and_start_session(account, jid,
                device_id, identity_key, identity_key_b64, trusted,
                key_changed, "1", bundle, null, build_session);
        if (!session_ready) {
            continue_message_sending(account, jid);
            return;
        }

        continue_message_sending(account, jid);
    }

    /**
     * Handle OMEMO 2 bundle fetch results.
     * Uses the same session setup via libomemo-c Signal protocol.
     */
    private void on_bundle_v2_fetched(Account account, Jid jid, int32 device_id, Bundle2 bundle) {
        if (!should_query_omemo2()) {
            debug("OMEMO 2: Ignoring v2 bundle for %s/%d because OMEMO2 is disabled", jid.to_string(), device_id);
            continue_message_sending(account, jid);
            return;
        }
        if (!StreamModule2.is_valid_omemo2_bundle(bundle)) {
            warning("OMEMO 2: Ignoring bundle with an invalid signed pre-key for %s/%d",
                    jid.bare_jid.to_string(), device_id);
            continue_message_sending(account, jid);
            return;
        }

        string ok_key = @"$(account.id):$(jid.bare_jid):$device_id";
        if (!has_loaded_legacy_devicelist(account, jid) || has_omemo1_devices(account, jid)) {
            bundle_retry_queue.unset(ok_key);
            debug("OMEMO 2: skipping v2 bundle DB write for %s/%d (legacy_loaded=%s has_v1=%s)",
                  jid.to_string(), device_id, has_loaded_legacy_devicelist(account, jid).to_string(),
                  has_omemo1_devices(account, jid).to_string());
            continue_message_sending(account, jid);
            return;
        }

        ECPublicKey? identity_key = bundle.identity_key;
        if (identity_key == null) {
            /* Bundle ist leer/kaputt – für periodischen Retry vormerken.
             * Typisch für Kaidan u.a., die manchmal <ik/> ohne Inhalt
             * publizieren.  Beim nächsten Retry-Zyklus wird das Bundle
             * erneut abgefragt; repariert der Kontakt sein Bundle
             * zwischenzeitlich, klappt der Session-Aufbau automatisch. */
            var entry = new BundleRetryEntry(account, jid, device_id);
            string key = entry.key();
            if (!bundle_retry_queue.has_key(key)) {
                bundle_retry_queue[key] = entry;
                debug("OMEMO 2: Bundle for %s/%d has no identity key – queued for retry",
                      jid.to_string(), device_id);
            } else {
                debug("OMEMO 2: Bundle for %s/%d still broken (attempt %d)",
                      jid.to_string(), device_id,
                      bundle_retry_queue[key].attempts);
            }

            /* Gerät auch im v2-Modul als ignored markieren, damit der
             * Encryptor es als 'lost' statt 'unknown' zählt.  Sonst
             * blockiert ein einzelnes kaputtes Gerät ALLE Nachrichten
             * an den Kontakt, obwohl andere Geräte erreichbar sind. */
            XmppStream? ign_stream = stream_interactor.get_stream(account);
            if (ign_stream != null) {
                StreamModule2? m2 = ign_stream.get_module<StreamModule2>(StreamModule2.IDENTITY);
                if (m2 != null) {
                    m2.ignore_device(jid, device_id);
                    debug("OMEMO 2: Ignoring device %s/%d (broken bundle)",
                          jid.to_string(), device_id);
                }
            }
            continue_message_sending(account, jid);
            return;
        }

        /* Gültiges Bundle erhalten → aus Retry-Queue entfernen, falls vorhanden */
        if (bundle_retry_queue.has_key(ok_key)) {
            debug("OMEMO 2: Bundle for %s/%d now valid – removed from retry queue",
                  jid.to_string(), device_id);
            bundle_retry_queue.unset(ok_key);
        }

        string identity_key_b64 = Base64.encode(identity_key.serialize());
        int identity_id;
        bool blind_trust;
        bool key_changed;
        Row? device;
        try {
            identity_id = db.identity.get_id_checked(account.id);
            if (identity_id <= 0) {
                throw new GLib.Error(Quark.from_string("omemo2-identity-store"),
                        ErrorCode.UNKNOWN,
                        "Persistent OMEMO account identity is unavailable");
            }
            blind_trust = db.trust.get_blind_trust_checked(identity_id,
                    jid.bare_jid.to_string(), true);
            device = db.identity_meta.get_device_checked(identity_id,
                    jid.bare_jid.to_string(), device_id);
            key_changed = identity_key_would_change(identity_id, jid,
                    device_id, identity_key_b64);
        } catch (Error e) {
            warning("OMEMO 2: Failed to read persistent trust state for %s/%d: %s",
                    jid.bare_jid.to_string(), device_id, e.message);
            continue_message_sending(account, jid);
            return;
        }

        bool known_identity = device != null &&
                ((!) device)[db.identity_meta.identity_key_public_base64] != null &&
                ((!) device)[db.identity_meta.identity_key_public_base64] == identity_key_b64;
        bool untrust = !(blind_trust || known_identity);

        TrustLevel trusted = TrustLevel.UNKNOWN;
        if (device != null) {
            trusted = (TrustLevel) ((!) device)[db.identity_meta.trust_level];
        }

        if (untrust) {
            trusted = TrustLevel.UNKNOWN;
        } else if (blind_trust && trusted == TrustLevel.UNKNOWN) {
            trusted = TrustLevel.TRUSTED;
        }

        bool session_ready = persist_bundle_and_start_session(account, jid,
                device_id, (!) identity_key, identity_key_b64, trusted,
                key_changed, "2", null, bundle);
        if (!session_ready) {
            continue_message_sending(account, jid);
            return;
        }
        continue_message_sending(account, jid);
    }

    private void continue_message_sending(Account account, Jid jid) {
        //Get all messages waiting and determine if they can now be sent
        HashSet<Entities.Message> send_now = new HashSet<Entities.Message>();
        lock (message_states) {
            foreach (var entry in message_states.entries) {
                Entities.Message msg = entry.key;
                if (!msg.account.equals(account)) continue;
                MessageState state = entry.value;
                if (state == null || msg.marked != Entities.Message.Marked.UNSENT) continue;

                if (account.bare_jid.equals(jid)) {
                    state.waiting_own_sessions--;
                } else if (msg.counterpart != null) {
                    Gee.List<Jid> occupants = get_message_recipients(msg);
                    if (occupants.contains(jid)) {
                        state.waiting_other_sessions--;
                    } else {
                        continue;
                    }
                }
                if (state.should_retry_now()){
                    send_now.add(msg);
                    state.active_send_attempt = true;
                }
            }
        }
        foreach (Entities.Message msg in send_now) {
            if (msg.counterpart == null) continue;
            Entities.Conversation? conv = get_pending_conversation(msg);
            if (conv == null) continue;
            stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).send_xmpp_message(msg, (!)conv, true);
        }
    }

    private void cancel_pending_store_initialization(Account account) {
        if (!pending_store_init_handlers.has_key(account)) return;
        ulong handler_id = pending_store_init_handlers[account];
        if (handler_id != 0 && SignalHandler.is_connected(account, handler_id)) {
            SignalHandler.disconnect(account, handler_id);
        }
        pending_store_init_handlers.unset(account);
    }

    private void schedule_store_initialization(Account account) {
        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module == null) return;
        ((!) module).store.mark_persistence_unavailable();
        cancel_pending_store_initialization(account);

        if (account.id > 0) {
            initialize_store(account);
            return;
        }

        ulong handler_id = account.notify["id"].connect(() => {
            if (account.id <= 0) return;
            cancel_pending_store_initialization(account);
            initialize_store(account);
        });
        pending_store_init_handlers[account] = handler_id;
    }

    private void initialize_store(Account account) {
        if (account.id <= 0) return;
        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module == null) return;
        Store store = ((!) module).store;
        var registration_guard = new LegacyRegistrationGuard(db, account.id);
        module.registration_guard = registration_guard;
        store.mark_persistence_unavailable();
        Qlite.Row? row = null;
        try {
            RowIterator identity_rows = db.identity.select()
                    .with(db.identity.account_id, "=", account.id)
                    .single()
                    .iterator();
            row = identity_rows.get_next_checked();
        } catch (Error e) {
            warning("OMEMO store initialization for %s failed while reading the identity: %s",
                    account.bare_jid.to_string(), e.message);
            return;
        }
        int identity_id = -1;
        uint32 registration_id = 0;
        Bytes? identity_private = null;
        Bytes? identity_public = null;

        if (row == null) {
            // OMEMO not yet initialized, starting with empty base
            try {
                registration_id = Random.int_range(1, int32.MAX);
                ECKeyPair key_pair = Plugin.get_context().generate_key_pair();
                identity_private = new Bytes(key_pair.private.serialize());
                identity_public = new Bytes(key_pair.public.serialize());

                identity_id = (int) db.identity.upsert()
                        .value(db.identity.account_id, account.id, true)
                        .value(db.identity.registration_pending, true)
                        .value(db.identity.device_id, (int) registration_id)
                        .value(db.identity.identity_key_private_base64, Base64.encode(((!) identity_private).get_data()))
                        .value(db.identity.identity_key_public_base64, Base64.encode(((!) identity_public).get_data()))
                        .perform_checked();
            } catch (Error e) {
                warning("OMEMO store initialization for %s failed while persisting the identity: %s",
                        account.bare_jid.to_string(), e.message);
                return;
            }
        } else {
            try {
                registration_id = (uint32) ((!) row)[db.identity.device_id];
                identity_id = ((!) row)[db.identity.id];
                identity_private = new Bytes(Base64.decode(((!) row)[db.identity.identity_key_private_base64]));
                identity_public = new Bytes(Base64.decode(((!) row)[db.identity.identity_key_public_base64]));
                if (registration_id == 0 || identity_id <= 0 ||
                        ((!) identity_private).length == 0 ||
                        ((!) identity_public).length == 0) {
                    throw new GLib.Error(-1, 0, "invalid persisted identity fields");
                }
                ECPrivateKey private_key = Plugin.get_context().decode_private_key(
                        ((!) identity_private).get_data());
                ECPublicKey public_key = Plugin.get_context().decode_public_key(
                        ((!) identity_public).get_data());
                ECPublicKey derived_public = generate_public_key(private_key);
                if (derived_public.compare(public_key) != 0) {
                    throw new GLib.Error(-1, 0,
                            "persisted OMEMO public/private identity keys do not match");
                }
            } catch (Error e) {
                warning("OMEMO store initialization for %s rejected an invalid persisted identity: %s",
                        account.bare_jid.to_string(), e.message);
                return;
            }
        }

        if (identity_id > 0 && registration_id > 0 &&
                identity_private != null && identity_public != null) {
            BackedSignedPreKeyStore signed_pre_keys = new BackedSignedPreKeyStore(db, identity_id);
            BackedPreKeyStore pre_keys = new BackedPreKeyStore(db, identity_id);
            BackedSessionStore sessions = new BackedSessionStore(db, identity_id);

            if (!signed_pre_keys.is_ready || !pre_keys.is_ready || !sessions.is_ready) {
                const string unavailable = "another persistent OMEMO store failed to initialize";
                signed_pre_keys.mark_unavailable(unavailable);
                pre_keys.mark_unavailable(unavailable);
                sessions.mark_unavailable(unavailable);
                warning("OMEMO is unavailable for %s because its persistent stores could not be loaded safely",
                        account.bare_jid.to_string());
                return;
            }

            // Publish the fully coherent state atomically to native callers.
            store.identity_key_store.local_registration_id = registration_id;
            store.identity_key_store.identity_key_private = (!) identity_private;
            store.identity_key_store.identity_key_public = (!) identity_public;
            store.signed_pre_key_store = signed_pre_keys;
            store.pre_key_store = pre_keys;
            store.session_store = sessions;
            try {
                store.registration_pending = registration_guard.read_pending_checked();
            } catch (Error e) {
                warning("OMEMO: Could not load device registration state: %s", e.message);
                return;
            }
            store.mark_persistence_ready();
            sanitize_omemo2_runtime_disabled_state(account);
        } else {
            warning("store for %s is not persisted!", account.bare_jid.to_string());
        }

        // Generated new device ID, ensure this gets added to the devicelist
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            // Load own device label from DB and set it on both modules
            if (!store.registration_pending) {
                load_own_device_label(account, module);
                mark_own_device_available(account, (int32) module.store.local_registration_id, should_publish_own_omemo2());
            }

            StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
            configure_omemo2_publish(module2);
            if (module2 != null && !store.registration_pending) {
                load_own_device_label_v2(account, module2);
            }

            if (!auto_publish_own_device_lists) return;

            module.request_user_devicelist.begin((!)stream, account.bare_jid);
            if (module2 != null && should_publish_own_omemo2() && !store.registration_pending) {
                module2.request_user_devicelist.begin((!)stream, account.bare_jid);
            }
        }
    }

    private void load_own_device_label(Account account, StreamModule module) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;
        int32 device_id = (int32) module.store.local_registration_id;
        Row? meta = db.identity_meta.get_device(identity_id, account.bare_jid.to_string(), device_id);
        if (meta != null) {
            module.own_device_label = meta[db.identity_meta.device_label];
        }
    }

    private void load_own_device_label_v2(Account account, StreamModule2 module2) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;
        int32 device_id = (int32) module2.store.local_registration_id;
        Row? meta = db.identity_meta.get_device(identity_id, account.bare_jid.to_string(), device_id);
        if (meta != null) {
            module2.own_device_label = meta[db.identity_meta.device_label];
        }
    }

    /** Set own device label, store in DB, and republish device lists (v1 + v2) */
    public void set_own_device_label(Account account, string label) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        StreamModule? module = stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY);
        if (module == null) return;
        if (module.store.registration_pending) {
            // Do not write metadata under a provisional ID that may belong
            // to another device. Save it once the collision check succeeds.
            module.own_device_label = label;
            return;
        }
        int32 device_id = (int32) module.store.local_registration_id;

        // Store in DB
        Row? meta = db.identity_meta.get_device(identity_id, account.bare_jid.to_string(), device_id);
        string? previous_label = meta != null ? ((!) meta)[db.identity_meta.device_label] : null;
        bool label_changed = meta == null || previous_label != label;

        db.identity_meta.update_device_label(identity_id, account.bare_jid.to_string(), device_id, label);
        debug("Stored own device label '%s' for %s/%d", label, account.bare_jid.to_string(), device_id);

        // Set on modules
        module.own_device_label = label;
        StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
        configure_omemo2_publish(module2);
        if (module2 != null) {
            module2.own_device_label = label;
        }

        // Republish device lists with label
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            if (label_changed) {
                republish_device_list_for_label_update(account, stream);
            }
            if (should_publish_own_omemo2()) {
                republish_device_list_v2(account, stream);
            }
        }
    }

    public async bool ensure_get_keys_for_conversation(Conversation conversation) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            PrivateMucKeyReadinessResult result = yield
                ensure_private_muc_keys_for_conversation(conversation);
            return result.status == PrivateMucKeyReadinessStatus.READY;
        }

        return yield ensure_get_keys_for_jid(conversation.account, conversation.counterpart.bare_jid);
    }

    internal async PrivateMucKeyReadinessResult
            ensure_private_muc_keys_for_conversation(
                Conversation conversation) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? maybe_context =
            muc_manager.capture_current_muc_context(conversation.account,
                conversation.counterpart);
        if (maybe_context == null) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
        MucManager.MucOwnerMutationContext context = (!) maybe_context;

        Gee.List<Jid>? members = yield muc_manager
            .ensure_private_muc_affiliation_snapshot(conversation.account,
                conversation.counterpart);
        if (!muc_manager.is_current_muc_context(conversation.account,
                context)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
        if (members == null && muc_manager.has_pending_muc_room_info(
                conversation.account, conversation.counterpart)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.ROOM_INFO_PENDING);
        }
        if (members == null && muc_manager.has_failed_muc_room_info(
                conversation.account, conversation.counterpart)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.SNAPSHOT_UNAVAILABLE);
        }
        if (!muc_manager.has_live_private_room_features(
                conversation.account, conversation.counterpart)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.NOT_PRIVATE);
        }
        if (members == null) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.SNAPSHOT_UNAVAILABLE);
        }
        if (!private_muc_member_snapshot_matches(muc_manager,
                conversation.account, conversation.counterpart,
                (!) members)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }

        return yield ensure_private_muc_member_devices(conversation.account,
            context, (!) members, muc_manager
                .get_private_muc_affiliation_snapshot_revision(
                    conversation.account, conversation.counterpart));
    }

    private async PrivateMucKeyReadinessResult
            ensure_private_muc_member_devices(Account account,
                MucManager.MucOwnerMutationContext context,
                Gee.Collection<Jid> members, uint snapshot_revision) {
        string key = private_muc_key_readiness_key(account, context.room);
        if (pending_private_muc_key_readiness.has_key(key)) {
            PendingPrivateMucKeyReadiness existing =
                pending_private_muc_key_readiness[key];
            if (same_private_muc_context(existing.context, context) &&
                    existing.snapshot_revision == snapshot_revision &&
                    same_private_muc_member_snapshot(existing.members,
                        members)) {
                return yield existing.wait_for_result();
            }
            // Install no replacement gap visible to resumed stale waiters.
            pending_private_muc_key_readiness.unset(key);
            existing.complete(new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE));
        }

        private_muc_readiness_watches.unset(key);
        var device_generations = new HashMap<Jid, uint>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        foreach (Jid member in members) {
            Jid bare = member.bare_jid;
            device_generations[bare] = private_muc_device_generation(account,
                bare);
        }
        var pending = new PendingPrivateMucKeyReadiness(context, members,
            snapshot_revision, device_generations);
        pending_private_muc_key_readiness[key] = pending;
        run_private_muc_key_readiness.begin(account, pending);
        return yield pending.wait_for_result();
    }

    private async void run_private_muc_key_readiness(Account account,
            PendingPrivateMucKeyReadiness pending) {
        PrivateMucKeyReadinessResult result = yield
            verify_private_muc_member_devices(account, pending);
        string key = private_muc_key_readiness_key(account,
            pending.context.room);
        if (!pending_private_muc_key_readiness.has_key(key) ||
                pending_private_muc_key_readiness[key] != pending) {
            pending.complete(new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE));
            return;
        }

        bool availability_changed_during_probe = false;
        if (result.status == PrivateMucKeyReadinessStatus.MEMBER_UNSUPPORTED &&
                result.member != null) {
            private_muc_readiness_watches[key] =
                new PrivateMucReadinessWatch(pending.context,
                    (!) result.member, pending.snapshot_revision);
            availability_changed_during_probe =
                private_muc_device_generation(account, (!) result.member) !=
                    pending.initial_device_generation((!) result.member);
        } else {
            private_muc_readiness_watches.unset(key);
        }

        // Remove before waking waiters so a reentrant configuration event can
        // install its own operation without being joined to a completed pass.
        pending_private_muc_key_readiness.unset(key);
        pending.complete(result);
        if (availability_changed_during_probe && result.member != null) {
            Jid member = (!) result.member;
            Idle.add(() => {
                notify_private_muc_readiness_watches(account, member, true);
                return Source.REMOVE;
            });
        }
    }

    private async PrivateMucKeyReadinessResult
            verify_private_muc_member_devices(Account account,
                PendingPrivateMucKeyReadiness pending) {
        PrivateMucKeyReadinessResult? invalid =
            private_muc_key_readiness_invalid_result(account, pending);
        if (invalid != null) return (!) invalid;

        bool has_non_self_member = false;
        foreach (Jid member in pending.members) {
            if (member.equals_bare(account.bare_jid)) continue;
            has_non_self_member = true;
            invalid = private_muc_key_readiness_invalid_result(account,
                pending);
            if (invalid != null) return (!) invalid;
            bool ok = yield ensure_get_keys_for_jid_on_stream(
                account, member, pending.context.stream, true, pending);
            invalid = private_muc_key_readiness_invalid_result(account,
                pending);
            if (invalid != null) return (!) invalid;
            if (!ok) {
                return new PrivateMucKeyReadinessResult(
                    PrivateMucKeyReadinessStatus.MEMBER_UNSUPPORTED, member);
            }
        }
        invalid = private_muc_key_readiness_invalid_result(account, pending);
        if (invalid != null) return (!) invalid;
        return new PrivateMucKeyReadinessResult(has_non_self_member
            ? PrivateMucKeyReadinessStatus.READY
            : PrivateMucKeyReadinessStatus.NO_OTHER_MEMBER);
    }

    private PrivateMucKeyReadinessResult?
            private_muc_key_readiness_invalid_result(Account account,
                PendingPrivateMucKeyReadiness pending) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        string key = private_muc_key_readiness_key(account,
            pending.context.room);
        if (!pending_private_muc_key_readiness.has_key(key) ||
                pending_private_muc_key_readiness[key] != pending ||
                !muc_manager.is_current_muc_context(account,
                    pending.context)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
        if (!muc_manager.has_live_private_room_features(account,
                pending.context.room)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.NOT_PRIVATE);
        }
        if (!private_muc_member_snapshot_matches(muc_manager, account,
                pending.context.room, pending.members)) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
        if (muc_manager.get_private_muc_affiliation_snapshot_revision(account,
                pending.context.room) != pending.snapshot_revision) {
            return new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE);
        }
        return null;
    }

    private static string private_muc_key_readiness_key(Account account,
            Jid room) {
        return @"$(account.id)\x1f$(room.bare_jid.to_string())";
    }

    private static string private_muc_device_generation_key(Account account,
            Jid member) {
        return @"$(account.id)\x1f$(member.bare_jid.to_string())";
    }

    private uint private_muc_device_generation(Account account, Jid member) {
        string key = private_muc_device_generation_key(account, member);
        return private_muc_device_generations.has_key(key)
            ? private_muc_device_generations[key] : 0;
    }

    private void advance_private_muc_device_generation(Account account,
            Jid member) {
        string key = private_muc_device_generation_key(account, member);
        uint next = private_muc_device_generation(account, member) + 1;
        if (next == 0) next = 1;
        private_muc_device_generations[key] = next;
    }

    private static bool same_private_muc_context(
            MucManager.MucOwnerMutationContext left,
            MucManager.MucOwnerMutationContext right) {
        if (left.stream != right.stream ||
                !left.room.equals_bare(right.room) ||
                !left.own_jid.equals(right.own_jid) ||
                left.runtime_generation != right.runtime_generation ||
                (left.room_generation == null) !=
                    (right.room_generation == null)) {
            return false;
        }
        return left.room_generation == null ||
            (!) left.room_generation == (!) right.room_generation;
    }

    private void cancel_private_muc_key_readiness(Account account,
            Jid room) {
        string key = private_muc_key_readiness_key(account, room);
        private_muc_readiness_watches.unset(key);
        if (!pending_private_muc_key_readiness.has_key(key)) return;
        PendingPrivateMucKeyReadiness pending =
            pending_private_muc_key_readiness[key];
        pending_private_muc_key_readiness.unset(key);
        pending.complete(new PrivateMucKeyReadinessResult(
            PrivateMucKeyReadinessStatus.STALE));
    }

    private void cancel_private_muc_key_readiness_for_account(
            Account account) {
        string prefix = @"$(account.id)\x1f";
        var keys = new ArrayList<string>();
        foreach (string key in pending_private_muc_key_readiness.keys) {
            if (key.has_prefix(prefix)) keys.add(key);
        }
        foreach (string key in keys) {
            PendingPrivateMucKeyReadiness pending =
                pending_private_muc_key_readiness[key];
            pending_private_muc_key_readiness.unset(key);
            pending.complete(new PrivateMucKeyReadinessResult(
                PrivateMucKeyReadinessStatus.STALE));
        }
        var watch_keys = new ArrayList<string>();
        foreach (string key in private_muc_readiness_watches.keys) {
            if (key.has_prefix(prefix)) watch_keys.add(key);
        }
        foreach (string key in watch_keys) {
            private_muc_readiness_watches.unset(key);
        }
        var generation_keys = new ArrayList<string>();
        foreach (string key in private_muc_device_generations.keys) {
            if (key.has_prefix(prefix)) generation_keys.add(key);
        }
        foreach (string key in generation_keys) {
            private_muc_device_generations.unset(key);
        }
    }

    private void notify_private_muc_readiness_watches(Account account,
            Jid member, bool has_devices) {
        if (!has_devices) return;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        var stale_keys = new ArrayList<string>();
        var ready_rooms = new ArrayList<Jid>();
        string account_prefix = @"$(account.id)\x1f";
        foreach (Map.Entry<string, PrivateMucReadinessWatch> entry in
                private_muc_readiness_watches.entries) {
            PrivateMucReadinessWatch watch = entry.value;
            if (!entry.key.has_prefix(account_prefix) ||
                    !watch.member.equals_bare(member)) continue;
            if (!muc_manager.is_current_muc_context(account,
                        watch.context) ||
                    !muc_manager.has_live_private_room_features(account,
                        watch.context.room) ||
                    muc_manager.get_private_muc_affiliation_snapshot_revision(
                        account, watch.context.room) !=
                        watch.snapshot_revision) {
                stale_keys.add(entry.key);
                continue;
            }
            Gee.List<Jid>? current = muc_manager
                .get_private_muc_member_affiliation_snapshot(account,
                    watch.context.room);
            if (current == null || !((!) current).contains(member.bare_jid)) {
                stale_keys.add(entry.key);
                continue;
            }
            stale_keys.add(entry.key);
            ready_rooms.add(watch.context.room);
        }
        foreach (string key in stale_keys) {
            private_muc_readiness_watches.unset(key);
        }
        foreach (Jid room in ready_rooms) {
            private_muc_readiness_changed(account, room);
        }
    }

    private bool private_muc_member_snapshot_matches(MucManager muc_manager,
            Account account, Jid room,
            Gee.Collection<Jid> expected_members) {
        if (!muc_manager.has_complete_private_muc_affiliation_snapshot(
                account, room)) {
            return false;
        }
        Gee.List<Jid>? current_members = muc_manager
            .get_private_muc_member_affiliation_snapshot(
                account, room);
        if (current_members == null) return false;

        return same_private_muc_member_snapshot(expected_members,
            (!) current_members);
    }

    internal static bool same_private_muc_member_snapshot(
            Gee.Collection<Jid> expected_members,
            Gee.Collection<Jid> current_members) {
        var expected = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        var current = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        expected.add_all(expected_members);
        current.add_all(current_members);
        return expected.size == current.size && expected.contains_all(current);
    }

    public async bool ensure_get_keys_for_jid(Account account, Jid jid) {
        return yield ensure_get_keys_for_jid_on_stream(account, jid, null,
            false);
    }

    private async bool ensure_get_keys_for_jid_on_stream(Account account,
            Jid jid, XmppStream? expected_stream, bool force_refresh,
            PendingPrivateMucKeyReadiness? readiness = null) {
        if (!private_muc_key_readiness_can_continue(account, readiness)) {
            return false;
        }
        if (jid.localpart == null) {
            debug("OMEMO: Not requesting keys for domain JID %s", jid.to_string());
            return false;
        }
        if (!force_refresh && trust_manager.is_known_address(account, jid)) {
            return true;
        }
        
        // Wait for stream to become available (up to 10 seconds)
        // On first start, the XMPP connection may still be establishing
        // when the chat window opens and checks OMEMO availability.
        XmppStream? stream = expected_stream ??
            stream_interactor.get_stream(account);
        if (expected_stream != null &&
                stream_interactor.get_stream(account) != expected_stream) {
            return false;
        }
        if (stream == null) {
            debug("OMEMO: Stream not ready for %s, waiting...", jid.to_string());
            for (int i = 0; i < 20; i++) {
                Timeout.add(500, () => {
                    ensure_get_keys_for_jid_on_stream.callback();
                    return false;
                });
                yield;
                if (!private_muc_key_readiness_can_continue(account,
                        readiness)) return false;
                stream = stream_interactor.get_stream(account);
                if (stream != null) {
                    debug("OMEMO: Stream became available for %s after %d ms", jid.to_string(), (i + 1) * 500);
                    break;
                }
            }
        }
        
        if (stream != null) {
            // Try up to 8 times (4 seconds) to get device list.
            // Bot accounts may still be publishing their device list via PubSub
            // when we first check, causing a false "does not support OMEMO".
            for (int attempt = 0; attempt < 8; attempt++) {
                if (!private_muc_key_readiness_can_continue(account,
                        readiness)) return false;
                // Check DB first (PEP notification may have arrived)
                if (expected_stream != null &&
                        stream_interactor.get_stream(account) !=
                            expected_stream) return false;
                if (!force_refresh &&
                        trust_manager.is_known_address(account, jid)) {
                    return true;
                }

                var device_list = yield stream_interactor.module_manager.get_module<StreamModule>(account, StreamModule.IDENTITY).request_user_devicelist(stream, jid);
                if (!private_muc_key_readiness_can_continue(account,
                        readiness)) return false;
                if (expected_stream != null &&
                        stream_interactor.get_stream(account) !=
                            expected_stream) return false;
                /* Also try OMEMO 2 device list */
                StreamModule2? module2 = stream_interactor.module_manager.get_module<StreamModule2>(account, StreamModule2.IDENTITY);
                configure_omemo2_publish(module2);
                if (module2 != null && should_query_omemo2()) {
                    var device_list_v2 = yield module2.request_user_devicelist(stream, jid);
                    if (!private_muc_key_readiness_can_continue(account,
                            readiness)) return false;
                    if (expected_stream != null &&
                            stream_interactor.get_stream(account) !=
                                expected_stream) return false;
                    if (device_list_v2.size > 0 && device_list.size == 0) {
                        return true;
                    }
                }
                if (device_list.size > 0) return true;

                // No devices yet — wait 500ms and retry
                if (attempt < 7) {
                    debug("OMEMO: No devices for %s yet (attempt %d/8), retrying...", jid.to_string(), attempt + 1);
                    Timeout.add(500,
                        ensure_get_keys_for_jid_on_stream.callback);
                    yield;
                    if (!private_muc_key_readiness_can_continue(account,
                            readiness)) return false;
                }
            }
            debug("OMEMO: No devices found for %s after retries", jid.to_string());
            return false;
        }
        debug("OMEMO: Cannot verify keys for %s - no stream available after waiting", jid.to_string());
        return false;
    }

    private bool private_muc_key_readiness_can_continue(Account account,
            PendingPrivateMucKeyReadiness? readiness) {
        if (readiness == null) return true;
        return private_muc_key_readiness_invalid_result(account,
            (!) readiness) == null;
    }

    public static Manager start(StreamInteractor stream_interactor, Database db, TrustManager trust_manager, HashMap<Account, OmemoEncryptor> encryptors, HashMap<Account, Omemo2Encrypt> encryptors_v2 = new HashMap<Account, Omemo2Encrypt>(Account.hash_func, Account.equals_func)) {
        Manager m = new Manager(stream_interactor, db, trust_manager, encryptors, encryptors_v2);
        stream_interactor.add_module(m);
        return m;
    }

    internal static Manager create_for_tests(StreamInteractor stream_interactor, Database db, TrustManager trust_manager, HashMap<Account, OmemoEncryptor> encryptors, HashMap<Account, Omemo2Encrypt> encryptors_v2 = new HashMap<Account, Omemo2Encrypt>(Account.hash_func, Account.equals_func)) {
        return new Manager(stream_interactor, db, trust_manager, encryptors, encryptors_v2, false);
    }
}

}
