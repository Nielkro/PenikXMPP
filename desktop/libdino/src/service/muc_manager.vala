/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

namespace Dino {

public enum MucInviteDelivery {
    MEDIATED,
    DIRECT
}

public enum MucConfigSaveResult {
    REJECTED,
    REJECTED_PREFLIGHT_MEMBERS_PRESERVED,
    APPLIED,
    APPLIED_LOCAL_SYNC_WARNING,
    APPLIED_SERVER_STATE_UNVERIFIED
}

public enum MucDestroyResult {
    APPLIED,
    APPLIED_LOCAL_SYNC_WARNING
}

public enum MucHistoryRefreshResult {
    QUEUED,
    PENDING_JOIN,
    UNAVAILABLE
}

private errordomain MucConfigPreflightError {
    MEMBERS_PRESERVED
}

public class MucInviteSendResult : Object {
    public MucInviteDelivery delivery { get; private set; }
    public bool sent { get; private set; }
    public string? error { get; private set; }

    internal MucInviteSendResult(MucInviteDelivery delivery, bool sent, string? error = null) {
        this.delivery = delivery;
        this.sent = sent;
        this.error = error;
    }
}

public enum MucRoomUpdateKind {
    ROOM_INFO,
    SUBJECT,
    PRIVATE_OCCUPANT
}

public delegate bool MucRoomObserverCallback(MucRoomUpdateKind kind, Account account, Jid room, Jid? occupant);

public class MucRoomObserver : Object {
    internal weak MucManager? manager;
    internal string key;
    internal uint id;
    private MucRoomObserverCallback? callback;

    internal MucRoomObserver(MucManager manager, string key, uint id, owned MucRoomObserverCallback callback) {
        this.manager = manager;
        this.key = key;
        this.id = id;
        this.callback = (owned) callback;
    }

    internal bool dispatch(MucRoomUpdateKind kind, Account account, Jid room, Jid? occupant) {
        return callback != null && ((!) callback)(kind, account, room, occupant);
    }

    public void unsubscribe() {
        MucManager? owner = manager;
        manager = null;
        callback = null;
        if (owner != null) ((!) owner).remove_room_observer(this);
    }

    ~MucRoomObserver() {
        unsubscribe();
    }
}

public class MucManager : StreamInteractionModule, Object {
    public static ModuleIdentity<MucManager> IDENTITY = new ModuleIdentity<MucManager>("muc_manager");
    private const uint MAM_FEATURE_TIMEOUT_SECONDS = 10;
    private const uint MUC_MAM_RETRY_MAX_ATTEMPTS = 3;
    private const uint MUC_INITIAL_PRESENCE_SYNC_MAX_SECONDS = 45;
    private const uint MUC_INITIAL_PRESENCE_SYNC_SETTLE_SECONDS = 5;
    private const uint MUC_INITIAL_ROSTER_COMMIT_BATCH = 16;
    private const int64 MUC_INITIAL_ROSTER_COMMIT_BUDGET_US = 4000;
    private const uint MUC_LIVE_BATCH_VISIBLE_DELAY_MS = 50;
    private const uint MUC_LIVE_BATCH_BACKGROUND_DELAY_MS = 150;
    private const uint AUTOJOIN_QUEUE_INITIAL_DELAY_MS = 250;
    private const uint AUTOJOIN_QUEUE_NEXT_DELAY_MS = 1500;
    private const string TIMED_BANS_ACCOUNT_SETTING = "muc-timed-bans-v1";
    private const string PENDING_BOOKMARK_REMOVALS_ACCOUNT_SETTING =
        "muc-pending-bookmark-removals-v1";
    public string id { get { return IDENTITY.id; } }

    public signal void left_signal(Account account, Jid jid);
    public signal void subject_set(Account account, Jid jid, string? subject);
    public signal void room_info_updated(Account account, Jid muc_jid);
    public signal void room_avatar_info_updated(Account account, Jid muc_jid,
        Xep.MucAvatars.RoomAvatarInfo info);
    public signal void room_info_query_failed(Account account, Jid muc_jid);
    public signal void private_muc_affiliation_snapshot_changed(
        Account account, Jid room, uint revision);
    public signal void private_room_occupant_updated(Account account, Jid room, Jid occupant);
    public signal void invite_received(Account account, Jid room_jid, Jid from_jid, string? password, string? reason);
    public signal void invite_received_with_context(Account account, Jid room_jid, Jid from_jid, string? password, string? reason, bool continue_thread, string? thread);
    public signal void invite_received_with_source(Account account, Jid room_jid, Jid from_jid, string? password, string? reason, bool continue_thread, string? thread, MucInviteSource source);
    public signal void invite_failed(Account account, Jid room_jid,
        Jid invitee_jid, string condition, string? text);
    public signal void joined(Account account, Jid jid);
    public signal void default_muc_server_changed(Account account,
        Jid? server);
    public signal void voice_request_received(Account account, Jid room_jid,
        Jid from_jid, string nick, string? stanza_id);
    public signal void voice_request_sent(Account account, Jid room_jid,
        string correlation_id);
    public signal void voice_request_failed(Account account, Jid room_jid,
        string correlation_id, string condition, string? text);
    public signal void voice_request_response_failed(Account account,
        Jid room_jid, string correlation_id, string condition, string? text);
    public signal void voice_request_response_settled(Account account,
        Jid room_jid, string correlation_id);
    public signal void received_occupant_role(Account account, Jid jid, Xep.Muc.Role? role);
    /** Confirmed IQ mutation; display membership still comes from room presence. */
    public signal void occupant_role_change_confirmed(Account account,
        Jid occupant_jid, Xep.Muc.Role role);
    public signal void received_occupant_hats(Account account, Jid jid, Gee.List<Xep.Muc.Hat> hats);
    public signal void bookmarks_updated(Account account, Set<Conference> conferences);
    public signal void conference_added(Account account, Conference conference);
    public signal void conference_removed(Account account, Jid jid);
    public signal void self_removed(Account account, Jid room_jid, Xep.Muc.StatusCode code, string? reason);
    public signal void occupant_removed(Account account, Jid room_jid, Jid occupant_jid, Xep.Muc.StatusCode code);
    public signal void occupant_affiliation_updated(Account account, Jid room_jid, Jid occupant_jid, Xep.Muc.Affiliation affiliation);
    public signal void room_initial_sync_started(Account account, Jid room_jid);
    public signal void room_occupants_snapshot_ready(Account account, Jid room_jid, MucRoomDelta delta);
    /** Display/state batch only; never an OMEMO membership proof. */
    public signal void room_occupants_changed_batch(Account account, Jid room_jid, MucRoomDelta delta);
    /** Fallback invalidation when confirmed config hides live presences. */
    public signal void room_occupant_projection_changed(Account account,
        Jid room_jid);
    /** Best-effort prefetch hint only; never an OMEMO recipient decision. */
    public signal void private_room_occupant_real_jid_ready(Account account,
        Jid room_jid, Jid occupant_jid, Jid real_jid);
    public signal void room_real_jid_visibility_revoked(Account account,
        Jid room_jid);
    public signal void room_real_jid_visibility_changed(Account account,
        Jid room_jid, Xep.Muc.RealJidVisibility visibility);
    public signal void room_initial_sync_finished(Account account, Jid room_jid);
    public signal void history_refresh_finished(Conversation conversation,
        HistorySync.FetchResult result);

    private class PendingMucJoinWaiter : Object {
        public Muc.JoinResult? result { get; private set; default=null; }

        private SourceFunc? resume_callback;

        public PendingMucJoinWaiter(owned SourceFunc resume_callback) {
            this.resume_callback = (owned) resume_callback;
        }

        public void complete(Muc.JoinResult? result) {
            this.result = result;
            Idle.add(() => {
                SourceFunc? callback = (owned) resume_callback;
                if (callback != null) {
                    ((!) callback)();
                }
                return Source.REMOVE;
            });
        }
    }

    private class PendingMucJoin : Object {
        public bool should_set_autojoin { get; private set; default=false; }
        public string? bookmark_nick { get; private set; }
        public string? bookmark_password { get; private set; }
        public Cancellable? owner_cancellable { get; private set; }

        private bool completed = false;
        private Muc.JoinResult? result = null;
        private ArrayList<PendingMucJoinWaiter> waiters = new ArrayList<PendingMucJoinWaiter>();

        public PendingMucJoin(bool already_autojoin, string? nick, string? password, Cancellable? owner_cancellable) {
            this.owner_cancellable = owner_cancellable;
            merge(already_autojoin, nick, password);
        }

        public void merge(bool already_autojoin, string? nick, string? password) {
            if (!already_autojoin) {
                should_set_autojoin = true;
                if (nick != null) {
                    bookmark_nick = nick;
                }
                if (password != null) {
                    bookmark_password = password;
                }
            }
        }

        public async Muc.JoinResult? wait_for_result() {
            if (completed) return result;

            PendingMucJoinWaiter waiter = new PendingMucJoinWaiter(wait_for_result.callback);
            waiters.add(waiter);
            yield;
            return waiter.result;
        }

        public void complete(Muc.JoinResult? result) {
            if (completed) return;

            this.result = result;
            completed = true;
            foreach (PendingMucJoinWaiter waiter in waiters) {
                waiter.complete(result);
            }
            waiters.clear();
        }
    }

    private class PendingPrivateMucSnapshotWaiter : Object {
        public Gee.List<Jid>? result { get; private set; default=null; }

        private SourceFunc? resume_callback;

        public PendingPrivateMucSnapshotWaiter(
                owned SourceFunc resume_callback) {
            this.resume_callback = (owned) resume_callback;
        }

        public void complete(Gee.List<Jid>? result) {
            this.result = result;
            Idle.add(() => {
                SourceFunc? callback = (owned) resume_callback;
                if (callback != null) ((!) callback)();
                return Source.REMOVE;
            });
        }
    }

    private class PendingPrivateMucSnapshot : Object {
        public MucOwnerMutationContext context { get; private set; }
        public bool force_refresh { get; private set; }
        private bool completed = false;
        private Gee.List<Jid>? result = null;
        private ArrayList<PendingPrivateMucSnapshotWaiter> waiters =
            new ArrayList<PendingPrivateMucSnapshotWaiter>();

        public PendingPrivateMucSnapshot(MucOwnerMutationContext context,
                bool force_refresh) {
            this.context = context;
            this.force_refresh = force_refresh;
        }

        public async Gee.List<Jid>? wait_for_result() {
            if (completed) return result;

            var waiter = new PendingPrivateMucSnapshotWaiter(
                wait_for_result.callback);
            waiters.add(waiter);
            yield;
            return waiter.result;
        }

        public void complete(Gee.List<Jid>? result) {
            if (completed) return;

            this.result = result;
            completed = true;
            foreach (PendingPrivateMucSnapshotWaiter waiter in waiters) {
                waiter.complete(result);
            }
            waiters.clear();
        }

        public bool is_completed() {
            return completed;
        }

        public bool has_succeeded() {
            return completed && result != null;
        }
    }

    /** One suspended consumer of the room-info query already owned by enter(). */
    private class PendingMucRoomInfoWaiter : Object {
        public bool result { get; private set; default = false; }

        private SourceFunc? resume_callback;

        public PendingMucRoomInfoWaiter(owned SourceFunc resume_callback) {
            this.resume_callback = (owned) resume_callback;
        }

        public void complete(bool result) {
            if (resume_callback == null) return;
            this.result = result;
            SourceFunc? callback = (owned) resume_callback;
            if (callback != null) Idle.add((owned) callback);
        }
    }

    private enum AutojoinPriority {
        BACKGROUND,
        ACTIVE
    }

    private enum MucRealJidRetentionAuthority {
        DENIED,
        ALLOWED
    }

    private class AutojoinCandidate : Object {
        public Conference conference;
        public AutojoinPriority priority = AutojoinPriority.BACKGROUND;

        public AutojoinCandidate(Conference conference, AutojoinPriority priority) {
            this.conference = conference;
            this.priority = priority;
        }
    }

    private class AutojoinBookmarkWrite : Object {
        public bool remove_bookmark;
        public bool recreate_if_missing;
        public bool autojoin;
        public string? nick;
        public string? name;
        public string? password;
        public bool allow_leave_marker;
        public bool remove_echo_seen;
        public uint generation;
        public int attempts;

        public AutojoinBookmarkWrite(bool autojoin, string? nick,
                string? password, bool allow_leave_marker, uint generation,
                int attempts = 0, bool remove_bookmark = false,
                bool recreate_if_missing = false, string? name = null) {
            this.remove_bookmark = remove_bookmark;
            this.recreate_if_missing = recreate_if_missing;
            this.autojoin = autojoin;
            this.nick = nick;
            this.name = name;
            this.password = password;
            this.allow_leave_marker = allow_leave_marker;
            this.generation = generation;
            this.attempts = attempts;
        }
    }

    private class BookmarkWriteCompletion : Object {
        public uint generation;
        public bool result { get; private set; default = false; }
        private SourceFunc? resume_callback;

        public BookmarkWriteCompletion(uint generation,
                owned SourceFunc resume_callback) {
            this.generation = generation;
            this.resume_callback = (owned) resume_callback;
        }

        public void complete(bool result) {
            if (resume_callback == null) return;
            this.result = result;
            SourceFunc? callback = (owned) resume_callback;
            if (callback != null) Idle.add((owned) callback);
        }
    }

    /** Main-context-only binding. Only its immutable room key enters the worker. */
    private class MucOccupantRoom : Object {
        public Account account { get; private set; }
        public Jid room { get; private set; }
        public MucRoomKey worker_key { get; private set; }
        public uint64 next_sequence { get; set; default = 1; }
        public bool finish_requested { get; set; default = false; }
        public bool initial_snapshot_committed { get; set; default = false; }
        public uint commit_index { get; set; default = 0; }
        public uint commit_source_id { get; set; default = 0; }
        public ShadowMucAggregate? comparison { get; set; }
        public HashSet<string> enqueued_occupant_ids { get; private set; default = new HashSet<string>(); }
        public uint boundary_reconciled { get; set; default = 0; }
        public uint live_flush_source_id { get; set; default = 0; }
        public bool live_flush_pending { get; set; default = false; }
        public bool initial_commit_complete { get; set; default = false; }
        public bool live_batching_enabled { get; set; default = false; }
        public bool interactive_priority { get; set; default = false; }
        public bool allow_leave_block_override { get; private set; }
        public MucRealJidRetentionAuthority real_jid_retention_authority {
            get; set; default = MucRealJidRetentionAuthority.DENIED;
        }
        public HashMap<Jid, string> pending_occupant_ids {
            get; private set; default = new HashMap<Jid, string>(
                Jid.hash_func, Jid.equals_func);
        }
        public Jid? pending_own_occupant_jid { get; set; }
        public string? pending_own_occupant_id { get; set; }
        public HashMap<string, MucOccupantSnapshot> stable_occupants {
            get; private set; default = new HashMap<string, MucOccupantSnapshot>();
        }
        public uint64 stable_revision { get; set; default = 0; }
        public MucRoomDelta? materialized_snapshot { get; set; }

        public MucOccupantRoom(Account account, Jid room,
                MucRoomKey worker_key, bool interactive_priority,
                bool allow_leave_block_override,
                MucRealJidRetentionAuthority real_jid_retention_authority) {
            this.account = account;
            this.room = room;
            this.worker_key = worker_key;
            this.interactive_priority = interactive_priority;
            this.allow_leave_block_override = allow_leave_block_override;
            this.real_jid_retention_authority =
                real_jid_retention_authority;
        }
    }

    /**
     * Frozen authority and lifecycle boundary for one MUC transaction. The
     * optional room generation guards normal MucManager joins even after their
     * live worker binding was released. MUJI-created rooms do not own such a
     * generation and intentionally keep it nullable.
     */
    public class MucOwnerMutationContext : Object {
        public XmppStream stream { get; private set; }
        public Jid room { get; private set; }
        public Jid own_jid { get; private set; }
        public uint runtime_generation { get; private set; }
        public uint? room_generation;

        public MucOwnerMutationContext(XmppStream stream, Jid room,
                Jid own_jid, uint runtime_generation,
                uint? room_generation) {
            this.stream = stream;
            this.room = room.bare_jid;
            this.own_jid = own_jid;
            this.runtime_generation = runtime_generation;
            this.room_generation = room_generation;
        }
    }

    internal class RoomDestructionContext : Object {
        public XmppStream stream;
        public Jid room;
        public uint runtime_generation;
        public uint? room_generation;
        public uint bookmark_generation;
        public Conference? desired_bookmark;
    }

    /** Main-context snapshot captured at the same FIFO boundary as FINISH_ROOM. */
    private class ShadowMucAggregate : Object {
        public uint occupants { get; set; }
        public uint affiliations { get; set; }
        public uint roles { get; set; }
        public uint real_jids { get; set; }
        public uint hats { get; set; }
    }

    private enum MucMamSyncMode {
        LATEST_ONLY,
        FULL,
        RELOAD
    }

    private StreamInteractor stream_interactor;
    private Database? database;
    private HashMap<Account, HashMap<Jid, HistorySync.ReloadReport>>
        manual_history_reports = new HashMap<Account, HashMap<Jid, HistorySync.ReloadReport>>(
            Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> mucs_joined = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> mucs_joining = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, PendingMucJoin>> pending_muc_joins = new HashMap<Account, HashMap<Jid, PendingMucJoin>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, PendingPrivateMucSnapshot>>
        pending_private_muc_snapshots = new HashMap<Account,
            HashMap<Jid, PendingPrivateMucSnapshot>>(Account.hash_func,
                Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>>
        private_muc_snapshot_revisions = new HashMap<Account,
            HashMap<Jid, uint>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, string>>
        private_muc_snapshot_fingerprints = new HashMap<Account,
            HashMap<Jid, string>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>>
        private_muc_unsent_resumes_in_flight = new HashMap<Account,
            HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> private_muc_room_info_ready =
        new HashMap<Account, HashSet<Jid>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashSet<Jid>> private_muc_room_info_failed =
        new HashMap<Account, HashSet<Jid>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid,
        ArrayList<PendingMucRoomInfoWaiter>>> pending_muc_room_info_waiters =
        new HashMap<Account, HashMap<Jid,
            ArrayList<PendingMucRoomInfoWaiter>>>(Account.hash_func,
                Account.equals_func);
    private HashMap<Account, HashSet<Jid>> muc_self_pings_in_flight = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<int, uint> muc_self_ping_generations =
        new HashMap<int, uint>();
    private HashMap<int, uint> muc_transport_pause_generations =
        new HashMap<int, uint>();
    private HashMap<Account, XmppStream> muc_provisional_disconnect_streams =
        new HashMap<Account, XmppStream>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> muc_initial_presence_sync_timeouts = new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, Cancellable>> mucs_sync_cancellables = new HashMap<Account, HashMap<Jid, Cancellable>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> pending_muc_mam_syncs =
        new HashMap<Account, HashSet<Jid>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid, MucMamSyncMode>>
        pending_muc_mam_sync_modes = new HashMap<Account,
            HashMap<Jid, MucMamSyncMode>>(Account.hash_func,
                Account.equals_func);
    private HashMap<Account, HashMap<Jid, MucMamSyncMode>>
        active_muc_mam_sync_modes = new HashMap<Account,
            HashMap<Jid, MucMamSyncMode>>(Account.hash_func,
                Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> muc_mam_retry_sources =
        new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> muc_mam_retry_attempts =
        new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashSet<Jid>> muc_mam_retry_exhausted =
        new HashMap<Account, HashSet<Jid>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> muc_mam_intent_generations =
        new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func,
            Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint>>
        muc_mam_feature_request_generations = new HashMap<Account,
            HashMap<Jid, uint>>(Account.hash_func, Account.equals_func);
    private HashSet<Account> muc_mam_resume_active = new HashSet<Account>(
        Account.hash_func, Account.equals_func);
    private HashSet<Account> muc_mam_resume_requested = new HashSet<Account>(
        Account.hash_func, Account.equals_func);
    private HashMap<Account, uint> muc_runtime_generations = new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> muc_cancelled_joins_should_exit = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashSet<string> active_muc_avatar_mutations = new HashSet<string>();
    private HashMap<Jid, Xep.Muc.MucEnterError> enter_errors = new HashMap<Jid, Xep.Muc.MucEnterError>(Jid.hash_func, Jid.equals_func);
    private HashMap<Account, HashMap<Jid, uint>> autojoin_write_generations = new HashMap<Account, HashMap<Jid, uint>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>> pending_autojoin_bookmark_writes = new HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>> active_autojoin_bookmark_writes = new HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, ArrayList<BookmarkWriteCompletion>>> bookmark_write_completions = new HashMap<Account, HashMap<Jid, ArrayList<BookmarkWriteCompletion>>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>> stale_bookmark_remove_echo_fences = new HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>> active_manual_bookmark_removals = new HashMap<Account, HashMap<Jid, AutojoinBookmarkWrite>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> leave_markers = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> permanent_leave_markers = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> pending_permanent_bookmark_removals = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashSet<int> restored_pending_bookmark_removal_accounts = new HashSet<int>();
    private HashMap<Account, HashSet<Jid>> manually_removed_bookmarks = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashSet<Jid>> manual_bookmark_removal_notified = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, ArrayList<AutojoinCandidate>> autojoin_queues = new HashMap<Account, ArrayList<AutojoinCandidate>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, uint> autojoin_queue_source_ids = new HashMap<Account, uint>(Account.hash_func, Account.equals_func);
    private HashSet<Account> autojoin_queue_active = new HashSet<Account>(Account.hash_func, Account.equals_func);
    private Account? foreground_autojoin_account = null;
    private Jid? foreground_autojoin_room = null;
    private Account? visible_muc_account = null;
    private Jid? visible_muc_room = null;
    private ReceivedMessageListener received_message_listener;
    private HashMap<Account, BookmarksProvider> bookmarks_provider = new HashMap<Account, BookmarksProvider>(Account.hash_func, Account.equals_func);
    private HashMap<Account, Gee.List<Jid>> invites = new HashMap<Account, Gee.List<Jid>>(Account.hash_func, Account.equals_func);
    public HashMap<Account, Jid> default_muc_server = new HashMap<Account, Jid>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, string>> own_occupant_ids = new HashMap<Account, HashMap<Jid, string>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, string>> current_pm_peer_identities = new HashMap<Account, HashMap<Jid, string>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, HashSet<string>>> current_pm_peer_identity_aliases = new HashMap<Account, HashMap<Jid, HashSet<string>>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, uint64?>> room_real_jid_visibility_generations = new HashMap<Account, HashMap<Jid, uint64?>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, string>> bookmark_names = new HashMap<Account, HashMap<Jid, string>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, Conference>> desired_manual_bookmarks = new HashMap<Account, HashMap<Jid, Conference>>(Account.hash_func, Account.equals_func);
    private HashMap<string, HashMap<uint, MucRoomObserver>> room_observers = new HashMap<string, HashMap<uint, MucRoomObserver>>();
    private uint next_room_observer_id = 1;
    private MucOccupantWorker muc_occupant_worker;
    private HashMap<string, MucOccupantRoom> muc_occupant_rooms = new HashMap<string, MucOccupantRoom>();
    private HashMap<string, uint> muc_occupant_room_generations = new HashMap<string, uint>();
    private HashMap<string, MucRoomDelta> muc_occupant_snapshots = new HashMap<string, MucRoomDelta>();
    private HashMap<string, PendingTimedBan> pending_timed_bans = new HashMap<string, PendingTimedBan>();
    private HashSet<int> restored_timed_ban_accounts = new HashSet<int>();
    private bool shadow_muc_stats_enabled = false;
    private bool muc_occupant_shutdown = false;
    private uint64 shadow_muc_compared = 0;
    private uint64 shadow_muc_matched = 0;
    private uint64 shadow_muc_mismatched = 0;
    private uint64 shadow_muc_stale_outputs = 0;

    private class PendingTimedBan : Object {
        public Account account;
        public Jid room;
        public Jid target;
        public string restore_affiliation;
        public int64 expires_at;
        public uint source_id = 0;
        public uint retry_count = 0;

        public PendingTimedBan(Account account, Jid room, Jid target,
                string restore_affiliation, int64 expires_at) {
            this.account = account;
            this.room = room.bare_jid;
            this.target = target.bare_jid;
            this.restore_affiliation = restore_affiliation;
            this.expires_at = expires_at;
        }
    }

    public static void start(StreamInteractor stream_interactor, Database? database = null) {
        MucManager m = new MucManager(stream_interactor, database);
        stream_interactor.add_module(m);
        Calls? calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
        if (calls != null) ((!) calls).bind_muc_manager(m);
        ConversationManager? conversation_manager =
            stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY);
        if (conversation_manager != null) {
            ((!) conversation_manager).bind_muc_manager(m);
        }
    }

    private MucManager(StreamInteractor stream_interactor, Database? database = null) {
        this.stream_interactor = stream_interactor;
        this.database = database;
        this.shadow_muc_stats_enabled = Environment.get_variable("DINOX_MUC_OCCUPANT_SHADOW_STATS") == "1";
        this.muc_occupant_worker = new MucOccupantWorker(null,
            MucOccupantWorker.DEFAULT_INGRESS_CAPACITY,
            MucOccupantWorker.DEFAULT_PER_ROOM_AVAILABLE_CAPACITY,
            MucOccupantWorker.DEFAULT_EGRESS_CAPACITY,
            MucOccupantWorker.DEFAULT_MAIN_DRAIN_BATCH,
            false, false, true);
        WeakRef manager_weak = WeakRef(this);
        this.muc_occupant_worker.delta_ready.connect((delta) => {
            MucManager? manager = (MucManager?) manager_weak.get();
            if (manager != null) ((!) manager).on_muc_occupant_delta(delta);
        });
        this.muc_occupant_worker.room_flushed.connect((room) => {
            MucManager? manager = (MucManager?) manager_weak.get();
            if (manager != null) ((!) manager).on_muc_occupant_room_flushed(room);
        });
        this.received_message_listener = new ReceivedMessageListener(stream_interactor);
        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        stream_interactor.connection_manager.connection_state_changed.connect(
            on_connection_state_changed);
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).received_pipeline.connect(received_message_listener);
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_deactivated.connect((conversation) => {
            // Conversation is still active if only the account is disabled. We don't need to part the room in this
            // case, as we will just go offline instead.
            if (conversation.type_ == Conversation.Type.GROUPCHAT && !conversation.active) {
                Account acc = conversation.account;
                Jid jid = conversation.counterpart;
                // Only part if still joined — prevents double-part when
                // close-conversation already called part() directly.
                if (mucs_joined.has_key(acc) && mucs_joined[acc].contains(jid)) {
                    part(acc, jid);
                }
            }
        });
        stream_interactor.stream_resumed.connect(on_stream_resumed);
        Timeout.add_seconds(60 * 3, () => {
            foreach (Account account in stream_interactor.get_accounts()) {
                self_ping(account);
            }
            return true;
        });
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY).build_message_stanza.connect(on_build_message_stanza);
        stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).status_changed.connect(on_global_status_changed);
        room_info_updated.connect((account, room) => {
            notify_room_observers(MucRoomUpdateKind.ROOM_INFO, account, room, null);
        });
        subject_set.connect((account, room, subject) => {
            notify_room_observers(MucRoomUpdateKind.SUBJECT, account, room, null);
        });
        private_room_occupant_updated.connect((account, room, occupant) => {
            // Presence and validated affiliation updates mutate an already
            // complete recipient snapshot in place. Publish only a real
            // member-set delta; routine presence for the same set is ignored.
            publish_private_muc_affiliation_snapshot_change(account, room);
            notify_room_observers(MucRoomUpdateKind.PRIVATE_OCCUPANT, account, room, occupant);
        });
        room_occupants_snapshot_ready.connect((account, room, delta) => {
            // Private-room avatars and other display-only room observers need
            // one refresh for the committed snapshot, not one per occupant.
            if (is_private_room(account, room)) {
                notify_room_observers(MucRoomUpdateKind.PRIVATE_OCCUPANT,
                    account, room, null);
            }
        });
        room_occupants_changed_batch.connect((account, room, delta) => {
            // One room-level refresh replaces per-occupant real-JID fanout for
            // worker-backed live batches.
            if (is_private_room(account, room)) {
                notify_room_observers(MucRoomUpdateKind.PRIVATE_OCCUPANT,
                    account, room, null);
            }
        });
    }

    public MucRoomObserver observe_room(Account account, Jid room, owned MucRoomObserverCallback callback) {
        string key = room_observer_key(account.id, room);
        if (!room_observers.has_key(key)) {
            room_observers[key] = new HashMap<uint, MucRoomObserver>();
        }

        uint observer_id = next_room_observer_id++;
        if (next_room_observer_id == 0) next_room_observer_id = 1;
        var observer = new MucRoomObserver(this, key, observer_id, (owned) callback);
        room_observers[key][observer_id] = observer;
        return observer;
    }

    internal void remove_room_observer(MucRoomObserver observer) {
        if (!room_observers.has_key(observer.key)) return;

        room_observers[observer.key].unset(observer.id);
        if (room_observers[observer.key].is_empty) room_observers.unset(observer.key);
    }

    private void notify_room_observers(MucRoomUpdateKind kind, Account account, Jid room, Jid? occupant) {
        string key = room_observer_key(account.id, room);
        if (!room_observers.has_key(key)) return;

        var observers = new ArrayList<MucRoomObserver>();
        observers.add_all(room_observers[key].values);
        Jid bare_room = room.bare_jid;
        foreach (MucRoomObserver observer in observers) {
            if (!observer.dispatch(kind, account, bare_room, occupant)) observer.unsubscribe();
        }
    }

    private string room_observer_key(int account_id, Jid room) {
        return account_id.to_string() + "\n" + room.bare_jid.to_string();
    }

    private void remove_room_observers_for_account(int account_id) {
        string prefix = account_id.to_string() + "\n";
        var observers = new ArrayList<MucRoomObserver>();
        foreach (var entry in room_observers.entries) {
            if (entry.key.has_prefix(prefix)) observers.add_all(entry.value.values);
        }
        foreach (MucRoomObserver observer in observers) observer.unsubscribe();
    }

    private void on_global_status_changed(string show, string? status_msg) {
        foreach (Account account in mucs_joined.keys) {
            send_own_presence_to_joined_rooms(account, show, status_msg);
        }
    }

    /** Resend current occupant presence after an extension such as the avatar
     * hash changed. This mirrors status updates and does not rejoin rooms. */
    public void resend_own_presence_to_joined_rooms(Account account) {
        PresenceManager? presence_manager = stream_interactor.get_module<
            PresenceManager>(PresenceManager.IDENTITY);
        if (presence_manager == null) return;
        send_own_presence_to_joined_rooms(account,
            ((!) presence_manager).get_current_show(),
            ((!) presence_manager).get_current_status_msg());
    }

    private void send_own_presence_to_joined_rooms(Account account, string show,
            string? status_msg) {
        if (!mucs_joined.has_key(account)) return;
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        foreach (Jid joined_jid in mucs_joined[account]) {
            Jid bare_jid = joined_jid.bare_jid;
            Jid? own_jid = get_own_jid(bare_jid, account);
            if (own_jid == null || ((!) own_jid).resourcepart == null) continue;

            try {
                var presence = new Xmpp.Presence.Stanza();
                presence.to = bare_jid.with_resource(
                    ((!) own_jid).resourcepart);
                if (show != "online") presence.show = show;
                if (status_msg != null && status_msg != "") {
                    presence.status = status_msg;
                }

                Xmpp.Presence.Module? presence_module = ((!) stream).get_module<
                    Xmpp.Presence.Module>(Xmpp.Presence.Module.IDENTITY);
                if (presence_module != null) {
                    ((!) presence_module).send_presence((!) stream, presence);
                }
            } catch (Xmpp.InvalidJidError e) {
                warning("Invalid JID while sending presence to MUC: %s",
                    e.message);
            }
        }
    }

    // already_autojoin: Without this flag we'd be retrieving bookmarks (to check for autojoin) from the sender on every join
    public async Muc.JoinResult? join(Account account, Jid jid, string? nick, string? password, bool already_autojoin = false, Cancellable? cancellable = null, bool override_leave_block = false, bool force_rejoin = false) {
        bool allow_leave_block_override = override_leave_block || !already_autojoin;
        bool manual_replaces_pending = !already_autojoin && mucs_joining.has_key(account) && mucs_joining[account].contains(jid.bare_jid);
        bool manual_rejoins_after_leave = !already_autojoin && is_leave_blocked(account, jid);
        if (!already_autojoin || force_rejoin || manual_replaces_pending) {
            consume_cancelled_join_exit(account, jid);
        }
        return yield join_internal(account, jid, nick, password, already_autojoin, cancellable, force_rejoin || manual_replaces_pending || manual_rejoins_after_leave, allow_leave_block_override);
    }

    public void cancel_join(Account account, Jid jid) {
        cancel_pending_join(account, jid.bare_jid, true);
    }

    private PendingMucJoin begin_pending_join(Account account, Jid jid, string? nick, string? password, bool already_autojoin, Cancellable? cancellable, out bool owns_side_effects) {
        if (!pending_muc_joins.has_key(account)) {
            pending_muc_joins[account] = new HashMap<Jid, PendingMucJoin>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (!mucs_joining.has_key(account)) {
            mucs_joining[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }

        Jid bare_jid = jid.bare_jid;
        if (pending_muc_joins[account].has_key(bare_jid)) {
            PendingMucJoin pending = pending_muc_joins[account][bare_jid];
            pending.merge(already_autojoin, nick, password);
            owns_side_effects = false;
            return pending;
        }

        PendingMucJoin pending = new PendingMucJoin(already_autojoin, nick, password, cancellable);
        pending_muc_joins[account][bare_jid] = pending;
        mucs_joining[account].add(bare_jid);
        owns_side_effects = true;
        return pending;
    }

    private void finish_pending_join(Account account, Jid jid, PendingMucJoin pending, bool owns_side_effects) {
        if (!owns_side_effects) return;

        Jid bare_jid = jid.bare_jid;
        if (pending_muc_joins.has_key(account) && pending_muc_joins[account].has_key(bare_jid) && pending_muc_joins[account][bare_jid] == pending) {
            pending_muc_joins[account].unset(bare_jid);
            if (pending_muc_joins[account].is_empty) {
                pending_muc_joins.unset(account);
            }
            if (mucs_joining.has_key(account)) {
                mucs_joining[account].remove(bare_jid);
                if (mucs_joining[account].is_empty) {
                    mucs_joining.unset(account);
                }
            }
        }
    }

    private async Muc.JoinResult? join_internal(Account account, Jid jid, string? nick, string? password, bool already_autojoin, Cancellable? cancellable, bool force_rejoin, bool override_leave_block = false) {
        int64 t_start = GLib.get_monotonic_time();
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        uint runtime_generation = get_muc_runtime_generation(account);
        if (!override_leave_block && is_leave_blocked(account, jid)) return null;
        if (already_autojoin && is_manually_removed_bookmark(account, jid) && !override_leave_block) return null;

        string nick_ = (nick ?? account.localpart) ?? account.domainpart;
        Jid? own_jid = get_own_jid(jid.bare_jid, account);
        if (!force_rejoin && own_jid != null && ((!) own_jid).resourcepart != null) {
            string own_nick = ((!) own_jid).resourcepart;
            enter_errors.unset(jid);
            if (!already_autojoin && bookmarks_provider.has_key(account)) {
                clear_manually_removed_bookmark(account, jid.bare_jid);
                set_autojoin(account, stream, jid.bare_jid, own_nick, password);
            }
            activate_joined_conversation(account, jid, own_nick);
            debug("MUC join [%s]: already joined as %s, reactivated conversation",
                    jid.to_string(), own_nick);
            return new Muc.JoinResult() { nick=own_nick };
        }

        bool owns_side_effects;
        if (force_rejoin) {
            cancel_pending_join(account, jid.bare_jid, false);
            cancel_muc_enter(account, jid.bare_jid);
        }
        PendingMucJoin pending_join = begin_pending_join(account, jid, nick, password, already_autojoin, cancellable, out owns_side_effects);

        if (!owns_side_effects) {
            Muc.JoinResult? coalesced_result = yield pending_join.wait_for_result();
            debug("MUC join [%s]: total %" + int64.FORMAT + " ms (coalesced continuation)",
                    jid.to_string(), (GLib.get_monotonic_time() - t_start) / 1000);
            return coalesced_result;
        }

        // A new room visit cannot inherit a cursor claiming continuity from
        // the previous visit. Fence both late pages and discovery/retry work
        // before enter() can deliver any live or legacy-history messages.
        remove_pending_muc_mam_sync(account, jid.bare_jid);
        stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).history_sync.invalidate_live_cursor(
                account, jid.bare_jid);
        cancel_sync(account, jid.bare_jid);

        DateTime? history_since = null;
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
            .get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
        // Preserve whether this was the first ever room activation before
        // activate_joined_conversation() creates the Conversation.  A first
        // join needs only the latest archive page; reconnecting an established
        // room may fill the bounded historical gap.
        MucMamSyncMode mam_sync_mode = conversation == null
            ? MucMamSyncMode.LATEST_ONLY : MucMamSyncMode.FULL;
        if (conversation != null) {
            Entities.Message? last_message = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_last_message(conversation);
            if (last_message != null) history_since = last_message.time;
        }

        EntityInfo entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        bool can_do_mam = entity_info.has_feature_offline(account, jid, Xmpp.MessageArchiveManagement.NS_URI);
        bool receive_history = true;
        if (can_do_mam) {
            receive_history = false;
            history_since = null;
        }

        clear_private_muc_room_info_ready(account, jid.bare_jid);
        cancel_private_muc_snapshot_request(account, jid.bare_jid);
        mark_initial_presence_sync(account, jid.bare_jid,
            MUC_INITIAL_PRESENCE_SYNC_MAX_SECONDS, !already_autojoin,
            override_leave_block);

        int64 t_enter_start = GLib.get_monotonic_time();
        Muc.JoinResult? res = yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).enter(stream, jid.bare_jid, nick_, password, history_since, receive_history, null);
        debug("MUC join [%s]: enter() took %" + int64.FORMAT + " ms",
                jid.to_string(), (GLib.get_monotonic_time() - t_enter_start) / 1000);

        bool pending_still_current = pending_muc_joins.has_key(account) &&
            pending_muc_joins[account].has_key(jid.bare_jid) &&
            pending_muc_joins[account][jid.bare_jid] == pending_join;
        bool runtime_stale = runtime_generation != get_muc_runtime_generation(account);
        bool exit_late_success = consume_cancelled_join_exit(account, jid);
        bool manual_autojoin_cancelled = already_autojoin && is_manually_removed_bookmark(account, jid);
        XmppStream? continuing_stream = get_retained_muc_stream(
            account, stream);
        bool session_still_current = continuing_stream != null;
        if (!pending_still_current || runtime_stale || manual_autojoin_cancelled || (cancellable != null && ((!) cancellable).is_cancelled()) || !session_still_current) {
            if (res != null && res.nick != null && session_still_current &&
                    (pending_still_current || exit_late_success)) {
                ((!) continuing_stream).get_module<Xep.Muc.Module>(
                    Xep.Muc.Module.IDENTITY).exit((!) continuing_stream,
                    jid.bare_jid, res.nick);
            }
            if (!runtime_stale && pending_still_current) {
                clear_initial_presence_sync(account, jid.bare_jid);
            }
            pending_join.complete(null);
            finish_pending_join(account, jid, pending_join, owns_side_effects);
            debug("MUC join [%s]: discarded stale/cancelled enter result", jid.to_string());
            return null;
        }

        if (res == null) {
            clear_initial_presence_sync(account, jid.bare_jid);
            pending_join.complete(null);
            finish_pending_join(account, jid, pending_join, owns_side_effects);
            debug("MUC join [%s]: total %" + int64.FORMAT + " ms (no result)",
                    jid.to_string(), (GLib.get_monotonic_time() - t_start) / 1000);
            return null;
        }

        if (res.nick != null) {
            if (!override_leave_block && is_leave_blocked(account, jid)) {
                clear_initial_presence_sync(account, jid.bare_jid);
                ((!) continuing_stream).get_module<Xep.Muc.Module>(
                    Xep.Muc.Module.IDENTITY).exit((!) continuing_stream,
                    jid.bare_jid, res.nick);
                pending_join.complete(null);
                finish_pending_join(account, jid, pending_join, owns_side_effects);
                return null;
            }
            if (override_leave_block) {
                clear_leave_marker(account, jid);
                clear_permanent_leave_marker(account, jid);
                clear_pending_permanent_bookmark_removal(account, jid);
            }
            mark_initial_presence_sync(account, jid.bare_jid, MUC_INITIAL_PRESENCE_SYNC_SETTLE_SECONDS);
            // Join completed
            enter_errors.unset(jid);
            if (pending_join.should_set_autojoin && !is_leave_blocked(account, jid)) {
                clear_manually_removed_bookmark(account, jid.bare_jid);
                set_autojoin(account, (!) continuing_stream, jid,
                    pending_join.bookmark_nick ?? (!) res.nick,
                    pending_join.bookmark_password);
            }
            activate_joined_conversation(account, jid, (!) res.nick);
            resume_unsent_muc_messages_after_join.begin(account,
                jid.bare_jid);

            // Feature discovery and the actual catch-up share the same
            // per-account queue.  This prevents a just-joined unknown room
            // from racing a reconnect catch-up or another room's completion.
            start_or_defer_muc_mam_sync(account, jid, mam_sync_mode);
        } else {
            // Join failed
            clear_initial_presence_sync(account, jid.bare_jid);
            if (res.muc_error != null) {
                enter_errors[jid] = res.muc_error;
            }
        }

        pending_join.complete(res);
        finish_pending_join(account, jid, pending_join, owns_side_effects);

        debug("MUC join [%s]: total %" + int64.FORMAT + " ms (nick=%s)",
                jid.to_string(), (GLib.get_monotonic_time() - t_start) / 1000, res.nick ?? "FAILED");
        return res;
    }

    private Conversation activate_joined_conversation(Account account, Jid jid, string nick) {
        ConversationManager conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        Conversation joined_conversation = conversation_manager.create_conversation(jid, account, Conversation.Type.GROUPCHAT);
        joined_conversation.nickname = nick;
        conversation_manager.start_conversation(joined_conversation);
        if (!mucs_joined.has_key(account)) {
            mucs_joined[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        try {
            mucs_joined[account].add(jid.bare_jid.with_resource(nick));
        } catch (Xmpp.InvalidJidError e) {
            warning("Failed to add MUC JID to joined list: %s", e.message);
        }
        // Observers must see the committed joined state synchronously. In
        // particular, moderation and encryption readiness checks consult
        // is_joined() from this signal.
        joined(account, jid.bare_jid);
        return joined_conversation;
    }

    /**
     * Same-stream recovery and an explicitly confirmed XEP-0198 resume may
     * complete buffered MUC work.  SM transfers the exact MUC Flag object to
     * the replacement stream; object identity is the session authority and
     * avoids accepting an unrelated fresh stream merely by account/JID.
     */
    private XmppStream? get_retained_muc_stream(Account account,
            XmppStream original_stream) {
        if (stream_interactor.connection_manager
                .is_current_or_provisionally_retained_stream(account,
                    original_stream)) return original_stream;

        XmppStream? current_stream = stream_interactor.get_stream(account);
        if (current_stream == null) return null;
        Xep.StreamManagement.Flag? sm_flag = ((!) current_stream).get_flag<
            Xep.StreamManagement.Flag>(Xep.StreamManagement.Flag.IDENTITY);
        Xep.Muc.Flag? original_muc_flag = original_stream.get_flag<
            Xep.Muc.Flag>(Xep.Muc.Flag.IDENTITY);
        if (sm_flag == null || !((!) sm_flag).resumed ||
                original_muc_flag == null) return null;

        foreach (XmppStreamFlag candidate in ((!) current_stream).flags) {
            if (candidate == original_muc_flag) return current_stream;
        }
        return null;
    }

    private async void run_muc_mam_sync(Account account, Jid jid,
            MucMamSyncMode mode, Conversation? conversation) {
        if (stream_interactor.get_stream(account) == null) {
            defer_muc_mam_sync(account, jid, mode);
            return;
        }

        if (mucs_sync_cancellables.has_key(account) &&
                mucs_sync_cancellables[account].has_key(jid.bare_jid)) return;

        var history_sync = stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).history_sync;
        bool custom_period = conversation != null &&
            ((!) conversation).muc_history_days > 0;
        if (custom_period && mode != MucMamSyncMode.RELOAD) mode = MucMamSyncMode.FULL;
        uint cursor_generation = history_sync.get_live_cursor_generation(
            account, jid.bare_jid);
        Cancellable sync_cancellable = new Cancellable();
        var fetch_cancellation = new HistorySync.FetchCancellation(
            sync_cancellable);
        if (mode == MucMamSyncMode.RELOAD && manual_history_reports.has_key(account)) {
            fetch_cancellation.reload_report = manual_history_reports[account][jid.bare_jid];
        }
        set_muc_mam_sync_owner(account, jid, sync_cancellable, mode);

        HistorySync.FetchResult fetch_result;
        DateTime fetch_from_time = custom_period
            ? new DateTime.now_utc().add_days(-((!) conversation).muc_history_days)
            : history_sync.sync_not_before;
        DateTime? panic_floor = history_sync.panic_sync_not_before;
        if (panic_floor != null &&
                ((!) panic_floor).compare(fetch_from_time) > 0) {
            fetch_from_time = (!) panic_floor;
        }
        if (conversation != null) {
            if (!custom_period && mode == MucMamSyncMode.FULL) {
                DateTime visit_floor = ((!) conversation)
                    .active_last_changed.add(-TimeSpan.DAY * 5);
                if (visit_floor.compare(fetch_from_time) > 0) {
                    fetch_from_time = visit_floor;
                }
            }
            DateTime? clear_floor = ((!) conversation).history_cleared_at;
            if (clear_floor != null &&
                    ((!) clear_floor).compare(fetch_from_time) > 0) {
                fetch_from_time = (!) clear_floor;
            }
            if (((!) conversation).message_expiry_seconds > 0) {
                DateTime expiry_floor = new DateTime.now_utc().add_seconds(
                    -((!) conversation).message_expiry_seconds);
                if (expiry_floor.compare(fetch_from_time) > 0) {
                    fetch_from_time = expiry_floor;
                }
            }
        }

        if ((!custom_period && mode == MucMamSyncMode.LATEST_ONLY) || conversation == null) {
            // We never joined the conversation before - fetch the latest page
            // asynchronously, but still expose one exact owner so reconnect
            // cancellation and serialized resume cannot overlap it.
            yield history_sync.fetch_latest_page(account, jid.bare_jid, null,
                fetch_from_time, fetch_cancellation,
                out fetch_result);
        } else {
            // Fill the visit gap, bounded by panic/clear/expiry restrictions.
            fetch_result = yield history_sync.fetch_everything(account,
                jid.bare_jid, fetch_cancellation, fetch_from_time);
        }

        bool room_visit_current = history_sync.get_live_cursor_generation(
            account, jid.bare_jid) == cursor_generation;
        if (!finish_muc_mam_sync(account, jid, sync_cancellable)) return;
        // Cancellation of an older visit must release its exact owner without
        // reinstating its retry intent or changing the new visit's retry state.
        if (!room_visit_current) return;
        if (fetch_result == HistorySync.FetchResult.SUCCESS) {
            clear_muc_mam_retry(account, jid);
            if (mode == MucMamSyncMode.RELOAD && conversation != null) {
                var report = fetch_cancellation.reload_report;
                history_refresh_finished((!) conversation,
                    report != null && ((!) report).has_omemo_failures
                        ? HistorySync.FetchResult.SUCCESS_WITH_OMEMO_FAILURES
                        : fetch_result);
                // A synchronous observer may already have started a newer
                // request for this room. Never remove that request's report.
                if (manual_history_reports.has_key(account) &&
                        manual_history_reports[account][jid.bare_jid] == report) {
                    clear_manual_history_report(account, jid);
                }
            }
            return;
        }
        if (mode == MucMamSyncMode.RELOAD && conversation != null) {
            history_refresh_finished((!) conversation, fetch_result);
        }
        if (!is_joined(jid, account)) return;

        // IQ errors and cancellations must not turn an already dequeued room
        // into a lost intent.  A provisional disconnect has usually requeued
        // it before cancelling the owner; exact-owner fencing above prevents
        // stale completions from duplicating that work.
        defer_muc_mam_sync(account, jid, mode);
        if (stream_interactor.get_stream(account) != null) {
            schedule_muc_mam_retry(account, jid);
        }
    }

    private void set_muc_mam_sync_owner(Account account, Jid jid,
            Cancellable cancellable,
            MucMamSyncMode mode = MucMamSyncMode.FULL) {
        if (!mucs_sync_cancellables.has_key(account)) {
            mucs_sync_cancellables[account] =
                new HashMap<Jid, Cancellable>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        mucs_sync_cancellables[account][jid.bare_jid] = cancellable;
        if (!active_muc_mam_sync_modes.has_key(account)) {
            active_muc_mam_sync_modes[account] =
                new HashMap<Jid, MucMamSyncMode>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        active_muc_mam_sync_modes[account][jid.bare_jid] = mode;
    }

    internal bool finish_muc_mam_sync(Account account, Jid jid,
            Cancellable expected_owner) {
        if (!mucs_sync_cancellables.has_key(account) ||
                !mucs_sync_cancellables[account].has_key(jid.bare_jid) ||
                mucs_sync_cancellables[account][jid.bare_jid] !=
                    expected_owner) return false;
        mucs_sync_cancellables[account].unset(jid.bare_jid);
        if (mucs_sync_cancellables[account].is_empty) {
            mucs_sync_cancellables.unset(account);
        }
        if (active_muc_mam_sync_modes.has_key(account)) {
            active_muc_mam_sync_modes[account].unset(jid.bare_jid);
            if (active_muc_mam_sync_modes[account].is_empty) {
                active_muc_mam_sync_modes.unset(account);
            }
        }
        if (pending_muc_mam_syncs.has_key(account) &&
                stream_interactor.get_stream(account) != null) {
            resume_deferred_muc_mam_syncs(account);
        }
        return true;
    }

    internal void set_muc_mam_sync_owner_for_tests(Account account, Jid jid,
            Cancellable cancellable) {
        set_muc_mam_sync_owner(account, jid, cancellable);
    }

    internal bool is_muc_mam_sync_owner_for_tests(Account account, Jid jid,
            Cancellable cancellable) {
        return mucs_sync_cancellables.has_key(account) &&
            mucs_sync_cancellables[account].has_key(jid.bare_jid) &&
            mucs_sync_cancellables[account][jid.bare_jid] == cancellable;
    }

    private void start_or_defer_muc_mam_sync(Account account, Jid jid,
            MucMamSyncMode mode) {
        // Fresh autojoins and reconnect catch-up share one per-account serial
        // queue, so large rooms cannot start concurrent MAM result pipelines.
        defer_muc_mam_sync(account, jid, mode);
        if (stream_interactor.get_stream(account) != null) {
            resume_deferred_muc_mam_syncs(account);
        }
    }

    private bool is_durable_muc_history_target(Conversation conversation) {
        if (database == null) return false;
        Database db = (!) database;
        if (conversation.type_ != Conversation.Type.GROUPCHAT ||
                !conversation.counterpart.is_bare() ||
                conversation.account.id <= 0 ||
                !conversation.matches_persisted_identity(db)) return false;

        // Compare durable rows directly rather than the account/JID caches:
        // stale dialogs must not write after account deletion or row reuse.
        if (db.account.select()
                .with(db.account.id, "=", conversation.account.id)
                .with(db.account.bare_jid, "=",
                    conversation.account.bare_jid.to_string()).count() != 1) {
            return false;
        }
        return db.conversation.select()
            .with(db.conversation.id, "=", conversation.id)
            .with(db.conversation.account_id, "=", conversation.account.id)
            .with(db.conversation.type_, "=", (int) Conversation.Type.GROUPCHAT)
            .join_with(db.jid, db.conversation.jid_id, db.jid.id)
            .with(db.jid.bare_jid, "=", conversation.counterpart.to_string())
            .count() == 1;
    }

    public bool set_muc_history_days(Conversation conversation, int days) {
        if (days < 0 || days > 365 ||
                !is_durable_muc_history_target(conversation)) return false;
        int expected_id = conversation.id;
        int expected_account_id = conversation.account.id;
        Account expected_account = conversation.account;
        // Resolve the original owner before a property notification can
        // rebind a dialog clone to another room/account.
        Conversation? canonical = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY)
                .get_conversation(conversation.counterpart,
                    expected_account, Conversation.Type.GROUPCHAT);
        conversation.muc_history_days = days;
        if (conversation.id != expected_id ||
                conversation.account != expected_account ||
                conversation.account.id != expected_account_id ||
                !is_durable_muc_history_target(conversation)) return false;
        if (canonical != null && canonical != conversation &&
                ((!) canonical).id == expected_id &&
                ((!) canonical).account.id == expected_account_id &&
                is_durable_muc_history_target((!) canonical)) {
            ((!) canonical).muc_history_days = days;
        }
        // Saving an offline preference must not issue IQs or join a room.
        return true;
    }

    public MucHistoryRefreshResult request_muc_history_refresh(
            Conversation conversation) {
        if (!is_durable_muc_history_target(conversation)) {
            return MucHistoryRefreshResult.UNAVAILABLE;
        }
        Account account = conversation.account;
        Jid room = conversation.counterpart.bare_jid;
        if (!account.enabled || stream_interactor.get_stream(account) == null ||
                !is_joined(room, account)) {
            // The persisted period applies to the next normal join. This
            // action itself never sends join/leave presence.
            return MucHistoryRefreshResult.PENDING_JOIN;
        }
        HistorySync history = stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).history_sync;
        if (!history.is_account_ready(account)) {
            return MucHistoryRefreshResult.UNAVAILABLE;
        }
        DateTime requested_at = new DateTime.now_utc();
        remove_pending_muc_mam_sync(account, room);
        cancel_sync(account, room);
        if (!stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY).prepare_history_restore(
                    conversation, requested_at) ||
                !is_durable_muc_history_target(conversation) ||
                conversation.account != account ||
                !conversation.counterpart.equals_bare(room)) {
            return MucHistoryRefreshResult.UNAVAILABLE;
        }
        history.reset_muc_history_coverage(account, room);
        if (database != null) {
            if (!manual_history_reports.has_key(account)) {
                manual_history_reports[account] = new HashMap<Jid, HistorySync.ReloadReport>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
            }
            manual_history_reports[account][room] = new HistorySync.ReloadReport(conversation);
        }
        defer_muc_mam_sync(account, room, MucMamSyncMode.RELOAD);
        resume_deferred_muc_mam_syncs(account);
        return MucHistoryRefreshResult.QUEUED;
    }

    private void remove_pending_muc_mam_sync(Account account, Jid jid,
            bool clear_retry_state = true) {
        bump_muc_mam_intent_generation(account, jid.bare_jid);
        if (pending_muc_mam_syncs.has_key(account)) {
            pending_muc_mam_syncs[account].remove(jid.bare_jid);
            if (pending_muc_mam_syncs[account].is_empty) {
                pending_muc_mam_syncs.unset(account);
            }
        }
        if (pending_muc_mam_sync_modes.has_key(account)) {
            pending_muc_mam_sync_modes[account].unset(jid.bare_jid);
            if (pending_muc_mam_sync_modes[account].is_empty) {
                pending_muc_mam_sync_modes.unset(account);
            }
        }
        if (clear_retry_state) {
            clear_muc_mam_retry(account, jid);
            clear_manual_history_report(account, jid);
        }
    }

    private void clear_manual_history_report(Account account, Jid room) {
        if (!manual_history_reports.has_key(account)) return;
        manual_history_reports[account].unset(room.bare_jid);
        if (manual_history_reports[account].is_empty) manual_history_reports.unset(account);
    }

    private void finish_unavailable_muc_mam_sync(Account account, Jid room) {
        bool manual_reload = manual_history_reports.has_key(account) &&
            manual_history_reports[account].has_key(room.bare_jid);
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(
            ConversationManager.IDENTITY).get_conversation(room.bare_jid, account,
                Conversation.Type.GROUPCHAT);
        // Retire this intent before notifying observers: a completion handler
        // may immediately start a replacement request for the same room.
        remove_pending_muc_mam_sync(account, room);
        if (manual_reload && conversation != null) {
            history_refresh_finished((!) conversation, HistorySync.FetchResult.UNAVAILABLE);
        }
    }

    private void defer_muc_mam_sync(Account account, Jid jid,
            MucMamSyncMode mode = MucMamSyncMode.FULL) {
        Jid bare = jid.bare_jid;
        bool was_pending = pending_muc_mam_syncs.has_key(account) &&
            pending_muc_mam_syncs[account].contains(bare);
        MucMamSyncMode existing = mode;
        if (pending_muc_mam_sync_modes.has_key(account) &&
                pending_muc_mam_sync_modes[account].has_key(bare)) {
            existing = pending_muc_mam_sync_modes[account][bare];
        }
        MucMamSyncMode merged = existing > mode ? existing : mode;

        if (!pending_muc_mam_syncs.has_key(account)) {
            pending_muc_mam_syncs[account] = new HashSet<Jid>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        pending_muc_mam_syncs[account].add(bare);
        if (!pending_muc_mam_sync_modes.has_key(account)) {
            pending_muc_mam_sync_modes[account] =
                new HashMap<Jid, MucMamSyncMode>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        // Explicit RELOAD retains the whole requested window; normal FULL
        // catch-up may use the visit floor. Both subsume LATEST_ONLY.
        pending_muc_mam_sync_modes[account][bare] = merged;
        if (!was_pending || merged != existing) {
            bump_muc_mam_intent_generation(account, bare);
        }
    }

    private uint get_muc_mam_intent_generation(Account account, Jid jid) {
        return muc_mam_intent_generations.has_key(account) &&
            muc_mam_intent_generations[account].has_key(jid.bare_jid)
                ? muc_mam_intent_generations[account][jid.bare_jid] : 0;
    }

    private uint bump_muc_mam_intent_generation(Account account, Jid jid) {
        if (!muc_mam_intent_generations.has_key(account)) {
            muc_mam_intent_generations[account] = new HashMap<Jid, uint>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        uint next = get_muc_mam_intent_generation(account, jid) + 1;
        if (next == 0) next = 1;
        muc_mam_intent_generations[account][jid.bare_jid] = next;
        return next;
    }

    private bool is_current_muc_mam_intent(Account account, Jid jid,
            uint expected_generation) {
        return pending_muc_mam_syncs.has_key(account) &&
            pending_muc_mam_syncs[account].contains(jid.bare_jid) &&
            get_muc_mam_intent_generation(account, jid) ==
                expected_generation;
    }

    private uint next_muc_mam_feature_request_generation(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!muc_mam_feature_request_generations.has_key(account)) {
            muc_mam_feature_request_generations[account] =
                new HashMap<Jid, uint>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        uint current = muc_mam_feature_request_generations[account]
            .has_key(bare)
            ? muc_mam_feature_request_generations[account][bare] : 0;
        uint next = current + 1;
        if (next == 0) next = 1;
        muc_mam_feature_request_generations[account][bare] = next;
        return next;
    }

    private bool is_current_muc_mam_feature_request(Account account, Jid jid,
            uint expected_intent_generation,
            uint expected_feature_request_generation,
            XmppStream expected_stream, uint expected_pause_generation,
            uint expected_runtime_generation) {
        return is_current_muc_mam_intent(account, jid,
                expected_intent_generation) &&
            muc_mam_feature_request_generations.has_key(account) &&
            muc_mam_feature_request_generations[account].has_key(
                jid.bare_jid) &&
            muc_mam_feature_request_generations[account][jid.bare_jid] ==
                expected_feature_request_generation &&
            stream_interactor.get_stream(account) == expected_stream &&
            get_muc_transport_pause_generation(account) ==
                expected_pause_generation &&
            get_muc_runtime_generation(account) ==
                expected_runtime_generation &&
            is_joined(jid, account);
    }

    private void defer_active_muc_mam_syncs(Account account) {
        if (!mucs_sync_cancellables.has_key(account)) return;
        foreach (Jid syncing_room in mucs_sync_cancellables[account].keys) {
            MucMamSyncMode mode = MucMamSyncMode.FULL;
            if (active_muc_mam_sync_modes.has_key(account) &&
                    active_muc_mam_sync_modes[account].has_key(
                        syncing_room.bare_jid)) {
                mode = active_muc_mam_sync_modes[account][
                    syncing_room.bare_jid];
            }
            defer_muc_mam_sync(account, syncing_room.bare_jid, mode);
        }
    }

    private void schedule_muc_mam_retry(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!pending_muc_mam_syncs.has_key(account) ||
                !pending_muc_mam_syncs[account].contains(bare) ||
                stream_interactor.get_stream(account) == null ||
                !is_joined(bare, account)) return;
        if (muc_mam_retry_sources.has_key(account) &&
                muc_mam_retry_sources[account].has_key(bare)) return;
        if (muc_mam_retry_exhausted.has_key(account) &&
                muc_mam_retry_exhausted[account].contains(bare)) return;

        if (!muc_mam_retry_attempts.has_key(account)) {
            muc_mam_retry_attempts[account] = new HashMap<Jid, uint>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        uint attempt = muc_mam_retry_attempts[account].has_key(bare)
            ? muc_mam_retry_attempts[account][bare] + 1 : 1;
        if (attempt > MUC_MAM_RETRY_MAX_ATTEMPTS) {
            if (!muc_mam_retry_exhausted.has_key(account)) {
                muc_mam_retry_exhausted[account] = new HashSet<Jid>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
            }
            muc_mam_retry_exhausted[account].add(bare);
            return;
        }
        muc_mam_retry_attempts[account][bare] = attempt;

        if (!muc_mam_retry_sources.has_key(account)) {
            muc_mam_retry_sources[account] = new HashMap<Jid, uint>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        uint delay_seconds = 1U << (attempt - 1);
        uint source_id = Timeout.add_seconds(delay_seconds, () => {
            if (muc_mam_retry_sources.has_key(account)) {
                muc_mam_retry_sources[account].unset(bare);
                if (muc_mam_retry_sources[account].is_empty) {
                    muc_mam_retry_sources.unset(account);
                }
            }
            if (pending_muc_mam_syncs.has_key(account) &&
                    pending_muc_mam_syncs[account].contains(bare) &&
                    stream_interactor.get_stream(account) != null &&
                    is_joined(bare, account)) {
                resume_deferred_muc_mam_syncs(account);
            }
            return Source.REMOVE;
        });
        muc_mam_retry_sources[account][bare] = source_id;
    }

    private void wake_muc_mam_retry_now(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        clear_muc_mam_retry(account, bare);
        if (!pending_muc_mam_syncs.has_key(account) ||
                !pending_muc_mam_syncs[account].contains(bare)) return;
        Idle.add(() => {
            if (stream_interactor.get_stream(account) != null &&
                    is_joined(bare, account)) {
                resume_deferred_muc_mam_syncs(account);
            }
            return Source.REMOVE;
        });
    }

    private void clear_muc_mam_retry_source(Account account, Jid jid) {
        if (!muc_mam_retry_sources.has_key(account) ||
                !muc_mam_retry_sources[account].has_key(jid.bare_jid)) return;
        uint source_id = muc_mam_retry_sources[account][jid.bare_jid];
        muc_mam_retry_sources[account].unset(jid.bare_jid);
        if (source_id != 0) Source.remove(source_id);
        if (muc_mam_retry_sources[account].is_empty) {
            muc_mam_retry_sources.unset(account);
        }
    }

    private void clear_muc_mam_retry(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        clear_muc_mam_retry_source(account, bare);
        if (muc_mam_retry_attempts.has_key(account)) {
            muc_mam_retry_attempts[account].unset(bare);
            if (muc_mam_retry_attempts[account].is_empty) {
                muc_mam_retry_attempts.unset(account);
            }
        }
        if (muc_mam_retry_exhausted.has_key(account)) {
            muc_mam_retry_exhausted[account].remove(bare);
            if (muc_mam_retry_exhausted[account].is_empty) {
                muc_mam_retry_exhausted.unset(account);
            }
        }
    }

    private void clear_all_muc_mam_retries(Account account) {
        if (muc_mam_retry_sources.has_key(account)) {
            var source_ids = new ArrayList<uint>();
            source_ids.add_all(muc_mam_retry_sources[account].values);
            muc_mam_retry_sources.unset(account);
            foreach (uint source_id in source_ids) {
                if (source_id != 0) Source.remove(source_id);
            }
        }
        muc_mam_retry_attempts.unset(account);
        muc_mam_retry_exhausted.unset(account);
    }

    private void resume_deferred_muc_mam_syncs(Account account) {
        if (!pending_muc_mam_syncs.has_key(account)) return;
        if (muc_mam_resume_active.contains(account)) {
            muc_mam_resume_requested.add(account);
            return;
        }
        muc_mam_resume_active.add(account);
        resume_deferred_muc_mam_syncs_serial.begin(account, (_, result) => {
            resume_deferred_muc_mam_syncs_serial.end(result);
            muc_mam_resume_active.remove(account);
            bool retry_requested = muc_mam_resume_requested.remove(account);
            if (retry_requested && pending_muc_mam_syncs.has_key(account) &&
                    stream_interactor.get_stream(account) != null) {
                Idle.add(() => {
                    resume_deferred_muc_mam_syncs(account);
                    return Source.REMOVE;
                });
            }
        });
    }

    private async void resume_deferred_muc_mam_syncs_serial(
            Account account) {
        if (!pending_muc_mam_syncs.has_key(account)) return;
        var rooms = new ArrayList<Jid>(Jid.equals_bare_func);
        rooms.add_all(pending_muc_mam_syncs[account]);
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        uint expected_pause_generation =
            get_muc_transport_pause_generation(account);
        if (expected_stream == null) return;
        foreach (Jid room in rooms) {
            if (stream_interactor.get_stream(account) != expected_stream ||
                    get_muc_transport_pause_generation(account) !=
                        expected_pause_generation) return;
            yield resume_deferred_muc_mam_sync(account, room,
                (!) expected_stream, expected_pause_generation);
        }
    }

    private async void resume_deferred_muc_mam_sync(Account account,
            Jid room, XmppStream expected_stream,
            uint expected_pause_generation) {
        if (!is_joined(room, account) ||
                !pending_muc_mam_syncs.has_key(account) ||
                !pending_muc_mam_syncs[account].contains(room.bare_jid)) {
            return;
        }
        uint expected_intent_generation =
            get_muc_mam_intent_generation(account, room);
        if (muc_mam_retry_sources.has_key(account) &&
                muc_mam_retry_sources[account].has_key(room.bare_jid)) {
            return;
        }
        if (muc_mam_retry_exhausted.has_key(account) &&
                muc_mam_retry_exhausted[account].contains(room.bare_jid)) {
            return;
        }
        EntityInfo entity_info = stream_interactor.get_module<EntityInfo>(
            EntityInfo.IDENTITY);
        bool can_do_mam = entity_info.has_feature_offline(account, room,
            Xmpp.MessageArchiveManagement.NS_URI);
        if (!can_do_mam) {
            FeatureRefreshResult refreshed = yield
                refresh_mam_support_after_join(entity_info, account, room,
                    expected_intent_generation);
            if (refreshed == FeatureRefreshResult.STALE ||
                    !is_current_muc_mam_intent(account, room,
                        expected_intent_generation)) return;
            if (refreshed == FeatureRefreshResult.INDETERMINATE) {
                schedule_muc_mam_retry(account, room);
                return;
            }
            can_do_mam = refreshed == FeatureRefreshResult.AVAILABLE;
        }
        if (stream_interactor.get_stream(account) != expected_stream ||
                get_muc_transport_pause_generation(account) !=
                    expected_pause_generation ||
                !is_joined(room, account) ||
                !is_current_muc_mam_intent(account, room,
                    expected_intent_generation)) return;
        if (!can_do_mam) {
            finish_unavailable_muc_mam_sync(account, room);
            return;
        }
        MucMamSyncMode mode = MucMamSyncMode.FULL;
        if (pending_muc_mam_sync_modes.has_key(account) &&
                pending_muc_mam_sync_modes[account].has_key(room.bare_jid)) {
            mode = pending_muc_mam_sync_modes[account][room.bare_jid];
        }
        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY)
                .get_conversation(room, account, Conversation.Type.GROUPCHAT);
        if (mucs_sync_cancellables.has_key(account) &&
                mucs_sync_cancellables[account].has_key(room.bare_jid)) return;
        remove_pending_muc_mam_sync(account, room, false);
        yield run_muc_mam_sync(account, room, mode, conversation);
    }

    public bool set_mam_archiving_enabled(DataForms.DataForm data_form, bool enabled) {
        bool found = false;
        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (!is_mam_archiving_config_field(field.var)) continue;

            found = true;
            if (field.type_ == DataForms.DataForm.Type.BOOLEAN) {
                ((DataForms.DataForm.BooleanField) field).value = enabled;
            } else {
                field.set_value_string(enabled ? "1" : "0");
            }
        }
        return found;
    }

    private bool is_mam_archiving_config_field(string? field_var) {
        switch (field_var) {
            case "mam": // ejabberd community
            case "muc#roomconfig_mam": // ejabberd SaaS / compatible services
            case "muc#roomconfig_enablearchiving": // Prosody mod_muc_mam
                return true;
            default:
                return false;
        }
    }

    private enum FeatureRefreshResult {
        AVAILABLE,
        UNAVAILABLE,
        INDETERMINATE,
        STALE
    }

    private async FeatureRefreshResult refresh_mam_support_after_join(
            EntityInfo entity_info, Account account, Jid jid,
            uint expected_intent_generation) {
        int64 t_mam_start = GLib.get_monotonic_time();
        XmppStream? expected_stream = stream_interactor.get_stream(account);
        if (expected_stream == null ||
                !is_current_muc_mam_intent(account, jid,
                    expected_intent_generation)) {
            return FeatureRefreshResult.STALE;
        }
        uint expected_pause_generation =
            get_muc_transport_pause_generation(account);
        uint expected_runtime_generation =
            get_muc_runtime_generation(account);
        uint expected_feature_request_generation =
            next_muc_mam_feature_request_generation(account, jid);
        FeatureRefreshResult result = yield refresh_feature_with_timeout(
            entity_info, account, jid, Xmpp.MessageArchiveManagement.NS_URI,
            expected_intent_generation,
            expected_feature_request_generation, (!) expected_stream,
            expected_pause_generation, expected_runtime_generation);
        debug("MUC join [%s]: post-join MAM check took %" + int64.FORMAT +
                " ms (result=%s)", jid.to_string(),
                (GLib.get_monotonic_time() - t_mam_start) / 1000,
                result.to_string());
        return result;
    }

    private async FeatureRefreshResult refresh_feature_with_timeout(
            EntityInfo entity_info, Account account, Jid jid,
            string feature, uint expected_intent_generation,
            uint expected_feature_request_generation,
            XmppStream expected_stream, uint expected_pause_generation,
            uint expected_runtime_generation) {
        var promise = new Promise<FeatureRefreshResult>();
        bool completed = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(MAM_FEATURE_TIMEOUT_SECONDS, () => {
            if (!completed) {
                completed = true;
                debug("MUC join [%s]: feature check timed out for %s", jid.to_string(), feature);
                bool current = is_current_muc_mam_feature_request(account,
                    jid, expected_intent_generation,
                    expected_feature_request_generation, expected_stream,
                    expected_pause_generation, expected_runtime_generation);
                promise.set_value(current
                    ? FeatureRefreshResult.INDETERMINATE
                    : FeatureRefreshResult.STALE);
                if (current) schedule_muc_mam_retry(account, jid);
            }
            timeout_id = 0;
            return false;
        });

        entity_info.refresh_features.begin(account, jid, (_, res) => {
            bool refreshed = entity_info.refresh_features.end(res);
            bool current = is_current_muc_mam_feature_request(account, jid,
                expected_intent_generation,
                expected_feature_request_generation, expected_stream,
                expected_pause_generation, expected_runtime_generation);
            if (completed) {
                // A valid disco result that arrives after our UI-safe timeout
                // still resolves the queued intent.  Do not wait for another
                // network transition merely because the IQ was slow.
                if (current && refreshed) {
                    if (entity_info.has_feature_offline(account, jid,
                            feature)) {
                        wake_muc_mam_retry_now(account, jid);
                    } else {
                        finish_unavailable_muc_mam_sync(account, jid);
                    }
                }
                return;
            }

            completed = true;
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            if (!current) {
                promise.set_value(FeatureRefreshResult.STALE);
            } else if (!refreshed) {
                promise.set_value(FeatureRefreshResult.INDETERMINATE);
            } else {
                promise.set_value(entity_info.has_feature_offline(account,
                        jid, feature)
                    ? FeatureRefreshResult.AVAILABLE
                    : FeatureRefreshResult.UNAVAILABLE);
            }
        });

        try {
            return yield promise.future.wait_async();
        } catch (FutureError e) {
            return is_current_muc_mam_feature_request(account, jid,
                    expected_intent_generation,
                    expected_feature_request_generation, expected_stream,
                    expected_pause_generation, expected_runtime_generation)
                ? FeatureRefreshResult.INDETERMINATE
                : FeatureRefreshResult.STALE;
        }
    }

    public void part(Account account, Jid jid) {
        bool timing_enabled = Environment.get_variable("DINOX_UI_TIMING") != null;
        int64 timing_start = timing_enabled ? GLib.get_monotonic_time() : 0;
        Jid bare = jid.bare_jid;
        mark_leave(account, bare);
        remove_queued_autojoin_candidate(account, bare);
        cancel_pending_join(account, bare, true);
        next_autojoin_write_generation(account, bare);

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(bare, account, Conversation.Type.GROUPCHAT);
        int64 timing_after_markers = timing_enabled ? GLib.get_monotonic_time() : 0;

        remove_joined_muc(account, bare);
        int64 timing_after_room_state = timing_enabled ? GLib.get_monotonic_time() : 0;
        clear_muc_self_ping(account, bare);
        clear_initial_presence_sync(account, bare);
        int64 timing_after_occupants = timing_enabled ? GLib.get_monotonic_time() : 0;

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            unset_autojoin(account, stream, bare, true);
            stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).exit(stream, bare, get_muc_exit_nick(account, bare, conversation));
        }
        int64 timing_after_presence = timing_enabled ? GLib.get_monotonic_time() : 0;

        if (conversation != null) stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).close_conversation(conversation);

        if (timing_enabled) {
            int64 timing_end = GLib.get_monotonic_time();
            GLib.message("UI-TIMING MucManager.part: room=%s markers=%" + int64.FORMAT + " ms room_state=%" + int64.FORMAT + " ms occupants=%" + int64.FORMAT + " ms presence=%" + int64.FORMAT + " ms close=%" + int64.FORMAT + " ms total=%" + int64.FORMAT + " ms",
                bare.to_string(),
                (timing_after_markers - timing_start) / 1000,
                (timing_after_room_state - timing_after_markers) / 1000,
                (timing_after_occupants - timing_after_room_state) / 1000,
                (timing_after_presence - timing_after_occupants) / 1000,
                (timing_end - timing_after_presence) / 1000,
                (timing_end - timing_start) / 1000);
        }
    }

    public async void leave_permanently(Account account, Jid jid) throws GLib.Error {
        bool timing_enabled = Environment.get_variable("DINOX_UI_TIMING") != null;
        int64 timing_start = timing_enabled ? GLib.get_monotonic_time() : 0;
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) throw new GLib.IOError.NOT_CONNECTED("No active stream for account");

        Jid bare = jid.bare_jid;
        debug("leave_permanently: Starting for %s", bare.to_string());
        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY).get_conversation(
                bare, account, Conversation.Type.GROUPCHAT);
        bool existing_intent = is_permanent_leave_marked(account, bare) ||
            is_pending_permanent_bookmark_removal(account, bare);
        bool local_lifecycle_active = is_joined(bare, account) ||
            (conversation != null && ((!) conversation).active);
        if (existing_intent && !local_lifecycle_active) {
            if (is_pending_permanent_bookmark_removal(account, bare)) {
                queue_permanent_bookmark_removal(account, stream, bare);
            }
            debug("leave_permanently: Reusing existing removal intent for %s",
                bare.to_string());
            return;
        }
        Conference? hidden_metadata = get_desired_manual_bookmark(account,
            bare);
        string? cached_name = bookmark_names.has_key(account)
            ? bookmark_names[account].get(bare)
            : null;
        if (hidden_metadata == null) {
            remember_desired_manual_bookmark(account, new Conference() {
                jid=bare,
                nick=conversation != null ? ((!) conversation).nickname : null,
                name=cached_name,
                autojoin=true
            });
        } else if (((!) hidden_metadata).name == null &&
                cached_name != null) {
            Conference enriched = clone_bookmark_conference(
                (!) hidden_metadata);
            enriched.name = cached_name;
            remember_desired_manual_bookmark(account, enriched);
        }
        clear_stale_bookmark_remove_echo_fence(account, bare);
        clear_manual_bookmark_removal_notification(account, bare);
        mark_permanent_leave(account, bare);
        remove_queued_autojoin_candidate(account, bare);
        cancel_pending_join(account, bare, true);
        uint generation = next_autojoin_write_generation(account, bare);
        // Commit the durable intent before exposing the local leave. A crash
        // after the presence/close transition must not resurrect the bookmark
        // and autojoin it on the next startup.
        mark_pending_permanent_bookmark_removal(account, bare);
        int64 timing_after_markers = timing_enabled ? GLib.get_monotonic_time() : 0;

        remove_joined_muc(account, bare);
        int64 timing_after_room_state = timing_enabled ? GLib.get_monotonic_time() : 0;
        clear_muc_self_ping(account, bare);
        clear_initial_presence_sync(account, bare);
        int64 timing_after_occupants = timing_enabled ? GLib.get_monotonic_time() : 0;

        stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).exit(stream, bare, get_muc_exit_nick(account, bare, conversation));
        int64 timing_after_presence = timing_enabled ? GLib.get_monotonic_time() : 0;

        if (conversation != null) {
            stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).close_conversation(conversation);
        }

        if (bookmark_names.has_key(account)) {
            bookmark_names[account].unset(bare);
        }
        remove_bookmarks2_cache_entry(account, bare);
        conference_removed(account, bare);

        // The visible room lifecycle is complete before any bookmark backend
        // can yield. The generation-fenced per-room queue owns the already
        // persisted server-side intent and its retries across reconnects.
        queue_permanent_bookmark_removal(account, stream, bare, generation);
        debug("leave_permanently: Local leave complete for %s; bookmark removal queued",
            bare.to_string());
        if (timing_enabled) {
            int64 timing_end = GLib.get_monotonic_time();
            GLib.message("UI-TIMING MucManager.leave_permanently: room=%s markers=%" + int64.FORMAT + " ms room_state=%" + int64.FORMAT + " ms occupants=%" + int64.FORMAT + " ms presence=%" + int64.FORMAT + " ms close_queue=%" + int64.FORMAT + " ms total=%" + int64.FORMAT + " ms",
                bare.to_string(),
                (timing_after_markers - timing_start) / 1000,
                (timing_after_room_state - timing_after_markers) / 1000,
                (timing_after_occupants - timing_after_room_state) / 1000,
                (timing_after_presence - timing_after_occupants) / 1000,
                (timing_end - timing_after_presence) / 1000,
                (timing_end - timing_start) / 1000);
        }
    }

    public void left(Account account, Jid jid, bool close_chat = true) {
        remove_joined_muc(account, jid);
        clear_muc_self_ping(account, jid);
        clear_initial_presence_sync(account, jid);

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(jid, account, Conversation.Type.GROUPCHAT);
        if (close_chat && conversation != null) stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).close_conversation(conversation);

        left_signal(account, jid);
    }

    private void cancel_sync(Account account, Jid jid) {
        if (mucs_sync_cancellables.has_key(account) && mucs_sync_cancellables[account].has_key(jid.bare_jid) && !mucs_sync_cancellables[account][jid.bare_jid].is_cancelled()) {
            mucs_sync_cancellables[account][jid.bare_jid].cancel();
        }
    }

    private void remove_joined_muc(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).history_sync.invalidate_live_cursor(
                account, bare);
        complete_pending_muc_room_info_waiters(account, bare, false);
        cancel_private_muc_snapshot_request(account, bare);
        clear_private_muc_room_info_ready(account, bare);
        forget_room_private_message_peer_identities(account, bare);
        remove_pending_muc_mam_sync(account, bare);
        cancel_sync(account, bare);
        if (!mucs_joined.has_key(account)) return;

        Gee.List<Jid> to_remove = new ArrayList<Jid>(Jid.equals_func);
        foreach (Jid joined_jid in mucs_joined[account]) {
            if (joined_jid.bare_jid.equals(bare)) {
                to_remove.add(joined_jid);
            }
        }
        foreach (Jid joined_jid in to_remove) {
            mucs_joined[account].remove(joined_jid);
        }
    }

    private void cancel_pending_join(Account account, Jid jid, bool exit_on_late_success = false) {
        Jid bare = jid.bare_jid;
        if (exit_on_late_success) {
            mark_cancelled_join_should_exit(account, bare);
        }
        bool had_join = false;
        if (pending_muc_joins.has_key(account) && pending_muc_joins[account].has_key(bare)) {
            had_join = true;
            PendingMucJoin pending = pending_muc_joins[account][bare];
            Cancellable? cancellable = pending.owner_cancellable;
            if (cancellable != null && !cancellable.is_cancelled()) {
                cancellable.cancel();
            }
            pending.complete(null);
            pending_muc_joins[account].unset(bare);
            if (pending_muc_joins[account].is_empty) {
                pending_muc_joins.unset(account);
            }
        }
        if (mucs_joining.has_key(account)) {
            if (mucs_joining[account].contains(bare)) {
                had_join = true;
            }
            mucs_joining[account].remove(bare);
            if (mucs_joining[account].is_empty) {
                mucs_joining.unset(account);
            }
        }
        if (had_join || exit_on_late_success) {
            cancel_muc_enter(account, bare);
        }
    }

    private void cancel_muc_enter(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;
        stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).cancel_enter(stream, jid.bare_jid);
    }

    private void mark_cancelled_join_should_exit(Account account, Jid jid) {
        if (!muc_cancelled_joins_should_exit.has_key(account)) {
            muc_cancelled_joins_should_exit[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        muc_cancelled_joins_should_exit[account].add(jid.bare_jid);
    }

    private bool consume_cancelled_join_exit(Account account, Jid jid) {
        if (!muc_cancelled_joins_should_exit.has_key(account)) return false;
        Jid bare = jid.bare_jid;
        bool ret = muc_cancelled_joins_should_exit[account].contains(bare);
        muc_cancelled_joins_should_exit[account].remove(bare);
        if (muc_cancelled_joins_should_exit[account].is_empty) {
            muc_cancelled_joins_should_exit.unset(account);
        }
        return ret;
    }

    private void cancel_all_pending_joins(Account account) {
        if (pending_muc_joins.has_key(account)) {
            foreach (PendingMucJoin pending in pending_muc_joins[account].values) {
                Cancellable? cancellable = pending.owner_cancellable;
                if (cancellable != null && !((!) cancellable).is_cancelled()) {
                    ((!) cancellable).cancel();
                }
                pending.complete(null);
            }
            pending_muc_joins.unset(account);
        }
        mucs_joining.unset(account);
    }

    private void cancel_private_muc_snapshot_request(Account account,
            Jid room) {
        Jid bare = room.bare_jid;
        if (!pending_private_muc_snapshots.has_key(account) ||
                !pending_private_muc_snapshots[account].has_key(bare)) {
            return;
        }

        PendingPrivateMucSnapshot pending =
            pending_private_muc_snapshots[account][bare];
        pending_private_muc_snapshots[account].unset(bare);
        if (pending_private_muc_snapshots[account].is_empty) {
            pending_private_muc_snapshots.unset(account);
        }
        pending.complete(null);
    }

    private void cancel_all_private_muc_snapshot_requests(Account account) {
        if (!pending_private_muc_snapshots.has_key(account)) return;

        var pending_requests = new ArrayList<PendingPrivateMucSnapshot>();
        pending_requests.add_all(
            pending_private_muc_snapshots[account].values);
        pending_private_muc_snapshots.unset(account);
        foreach (PendingPrivateMucSnapshot pending in pending_requests) {
            pending.complete(null);
        }
    }

    private bool has_private_muc_room_info_ready(Account account, Jid room) {
        return private_muc_room_info_ready.has_key(account) &&
            private_muc_room_info_ready[account].contains(room.bare_jid);
    }

    public bool has_failed_muc_room_info(Account account, Jid room) {
        return private_muc_room_info_failed.has_key(account) &&
            private_muc_room_info_failed[account].contains(room.bare_jid);
    }

    private void mark_private_muc_room_info_ready(Account account, Jid room) {
        if (!private_muc_room_info_ready.has_key(account)) {
            private_muc_room_info_ready[account] = new HashSet<Jid>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        private_muc_room_info_ready[account].add(room.bare_jid);
        if (private_muc_room_info_failed.has_key(account)) {
            private_muc_room_info_failed[account].remove(room.bare_jid);
            if (private_muc_room_info_failed[account].is_empty) {
                private_muc_room_info_failed.unset(account);
            }
        }
    }

    private void mark_private_muc_room_info_failed(Account account,
            Jid room) {
        if (!private_muc_room_info_failed.has_key(account)) {
            private_muc_room_info_failed[account] = new HashSet<Jid>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        private_muc_room_info_failed[account].add(room.bare_jid);
    }

    private void clear_private_muc_room_info_ready(Account account,
            Jid room) {
        Jid bare = room.bare_jid;
        if (private_muc_room_info_ready.has_key(account)) {
            private_muc_room_info_ready[account].remove(bare);
            if (private_muc_room_info_ready[account].is_empty) {
                private_muc_room_info_ready.unset(account);
            }
        }
        if (private_muc_room_info_failed.has_key(account)) {
            private_muc_room_info_failed[account].remove(bare);
            if (private_muc_room_info_failed[account].is_empty) {
                private_muc_room_info_failed.unset(account);
            }
        }
        if (private_muc_snapshot_fingerprints.has_key(account)) {
            private_muc_snapshot_fingerprints[account].unset(bare);
            if (private_muc_snapshot_fingerprints[account].is_empty) {
                private_muc_snapshot_fingerprints.unset(account);
            }
        }
        if (private_muc_unsent_resumes_in_flight.has_key(account)) {
            private_muc_unsent_resumes_in_flight[account].remove(bare);
            if (private_muc_unsent_resumes_in_flight[account].is_empty) {
                private_muc_unsent_resumes_in_flight.unset(account);
            }
        }
    }

    private void clear_all_initial_presence_sync(Account account) {
        if (!muc_initial_presence_sync_timeouts.has_key(account)) return;

        foreach (uint timeout_id in muc_initial_presence_sync_timeouts[account].values) {
            if (timeout_id != 0) Source.remove(timeout_id);
        }
        muc_initial_presence_sync_timeouts.unset(account);
    }

    private void cancel_all_muc_sync(Account account) {
        if (!mucs_sync_cancellables.has_key(account)) {
            active_muc_mam_sync_modes.unset(account);
            return;
        }

        foreach (Cancellable cancellable in mucs_sync_cancellables[account].values) {
            if (!cancellable.is_cancelled()) {
                cancellable.cancel();
            }
        }
        mucs_sync_cancellables.unset(account);
        active_muc_mam_sync_modes.unset(account);
    }

    private void clear_transient_muc_runtime_state(Account account) {
        complete_all_bookmark_write_attempts(account, false);
        bump_muc_runtime_generation(account);
        bump_muc_self_ping_generation(account);
        cancel_muc_occupant_account(account);
        cancel_all_pending_joins(account);
        complete_all_pending_muc_room_info_waiters(account);
        cancel_all_private_muc_snapshot_requests(account);
        private_muc_snapshot_revisions.unset(account);
        private_muc_snapshot_fingerprints.unset(account);
        private_muc_unsent_resumes_in_flight.unset(account);
        private_muc_room_info_ready.unset(account);
        private_muc_room_info_failed.unset(account);
        cancel_all_muc_sync(account);
        pending_muc_mam_syncs.unset(account);
        pending_muc_mam_sync_modes.unset(account);
        manual_history_reports.unset(account);
        clear_all_muc_mam_retries(account);
        // Runtime generation was bumped above, so any late feature callback is
        // already fenced before these per-room counters are released.
        muc_mam_intent_generations.unset(account);
        muc_mam_feature_request_generations.unset(account);
        muc_mam_resume_requested.remove(account);
        clear_all_initial_presence_sync(account);
        muc_self_pings_in_flight.unset(account);
        muc_cancelled_joins_should_exit.unset(account);
        mucs_joined.unset(account);
        current_pm_peer_identities.unset(account);
        current_pm_peer_identity_aliases.unset(account);
        clear_scheduled_autojoin_queue(account);
        autojoin_queue_active.remove(account);
        autojoin_queues.unset(account);
        pending_autojoin_bookmark_writes.unset(account);
        active_autojoin_bookmark_writes.unset(account);
        active_manual_bookmark_removals.unset(account);
        stale_bookmark_remove_echo_fences.unset(account);
    }

    private void clear_all_muc_runtime_state(Account account) {
        clear_transient_muc_runtime_state(account);
        if (foreground_autojoin_account != null && ((!) foreground_autojoin_account).equals(account)) {
            foreground_autojoin_account = null;
            foreground_autojoin_room = null;
        }
        if (visible_muc_account != null && ((!) visible_muc_account).equals(account)) {
            visible_muc_account = null;
            visible_muc_room = null;
        }
        remove_muc_occupant_generations(account.id);
        leave_markers.unset(account);
        permanent_leave_markers.unset(account);
        pending_permanent_bookmark_removals.unset(account);
        restored_pending_bookmark_removal_accounts.remove(account.id);
        manually_removed_bookmarks.unset(account);
        manual_bookmark_removal_notified.unset(account);
        bookmark_write_completions.unset(account);
        active_manual_bookmark_removals.unset(account);
        stale_bookmark_remove_echo_fences.unset(account);
        autojoin_write_generations.unset(account);
        pending_autojoin_bookmark_writes.unset(account);
        active_autojoin_bookmark_writes.unset(account);
        bookmarks_provider.unset(account);
        invites.unset(account);
        bool had_default_muc_server = default_muc_server.unset(account);
        if (had_default_muc_server) {
            default_muc_server_changed(account, null);
        }
        own_occupant_ids.unset(account);
        current_pm_peer_identities.unset(account);
        current_pm_peer_identity_aliases.unset(account);
        room_real_jid_visibility_generations.unset(account);
        muc_transport_pause_generations.unset(account.id);
        muc_provisional_disconnect_streams.unset(account);
        bookmark_names.unset(account);
        desired_manual_bookmarks.unset(account);
    }

    private uint get_muc_runtime_generation(Account account) {
        return muc_runtime_generations.has_key(account) ? muc_runtime_generations[account] : 0;
    }

    private void bump_muc_runtime_generation(Account account) {
        uint next = get_muc_runtime_generation(account) + 1;
        if (next == 0) next = 1;
        muc_runtime_generations[account] = next;
    }

    private uint get_muc_transport_pause_generation(Account account) {
        return muc_transport_pause_generations.has_key(account.id)
            ? muc_transport_pause_generations[account.id] : 0;
    }

    private void bump_muc_transport_pause_generation(Account account) {
        uint next = get_muc_transport_pause_generation(account) + 1;
        if (next == 0) next = 1;
        muc_transport_pause_generations[account.id] = next;
    }

    private void mark_permanent_leave(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!permanent_leave_markers.has_key(account)) {
            permanent_leave_markers[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        permanent_leave_markers[account].add(bare);
    }

    private void mark_pending_permanent_bookmark_removal(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!pending_permanent_bookmark_removals.has_key(account)) {
            pending_permanent_bookmark_removals[account] = new HashSet<Jid>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (pending_permanent_bookmark_removals[account].add(bare)) {
            persist_pending_permanent_bookmark_removals(account);
        }
    }

    private void clear_pending_permanent_bookmark_removal(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        bool changed = false;
        if (pending_permanent_bookmark_removals.has_key(account)) {
            changed = pending_permanent_bookmark_removals[account].remove(bare);
            if (pending_permanent_bookmark_removals[account].is_empty) {
                pending_permanent_bookmark_removals.unset(account);
            }
        }
        if (changed) persist_pending_permanent_bookmark_removals(account);
    }

    private bool is_pending_permanent_bookmark_removal(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        return pending_permanent_bookmark_removals.has_key(account) &&
            pending_permanent_bookmark_removals[account].contains(bare);
    }

    private void persist_pending_permanent_bookmark_removals(Account account) {
        if (database == null) return;
        Database db = (!) database;
        StringBuilder serialized = new StringBuilder();
        if (pending_permanent_bookmark_removals.has_key(account)) {
            foreach (Jid room in pending_permanent_bookmark_removals[account]) {
                serialized.append(room.bare_jid.to_string());
                serialized.append_c('\n');
            }
        }

        if (serialized.len == 0) {
            db.account_settings.delete()
                .with(db.account_settings.account_id, "=", account.id)
                .with(db.account_settings.key, "=",
                    PENDING_BOOKMARK_REMOVALS_ACCOUNT_SETTING)
                .perform();
            return;
        }
        db.account_settings.upsert()
            .value(db.account_settings.account_id, account.id, true)
            .value(db.account_settings.key,
                PENDING_BOOKMARK_REMOVALS_ACCOUNT_SETTING, true)
            .value(db.account_settings.value, serialized.str)
            .perform();
    }

    private void restore_pending_permanent_bookmark_removals(Account account) {
        if (database == null ||
                restored_pending_bookmark_removal_accounts.contains(
                    account.id)) return;
        restored_pending_bookmark_removal_accounts.add(account.id);
        string? serialized = ((!) database).account_settings.get_value(
            account.id, PENDING_BOOKMARK_REMOVALS_ACCOUNT_SETTING);
        if (serialized == null || ((!) serialized).strip() == "") return;

        bool malformed = false;
        foreach (string line in ((!) serialized).split("\n")) {
            if (line == "") continue;
            try {
                Jid room = new Jid(line).bare_jid;
                if (!pending_permanent_bookmark_removals.has_key(account)) {
                    pending_permanent_bookmark_removals[account] =
                        new HashSet<Jid>(Jid.hash_bare_func,
                            Jid.equals_bare_func);
                }
                pending_permanent_bookmark_removals[account].add(room);
                mark_permanent_leave(account, room);
            } catch (InvalidJidError e) {
                malformed = true;
                warning("Ignoring persisted MUC bookmark removal with invalid JID: %s",
                    e.message);
            }
        }
        if (malformed) persist_pending_permanent_bookmark_removals(account);
    }

    private void clear_resolved_pending_bookmark_removals(Account account,
            Set<Conference> conferences) {
        if (!pending_permanent_bookmark_removals.has_key(account) ||
                pending_permanent_bookmark_removals[account].is_empty) return;
        var remote_rooms = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        foreach (Conference conference in conferences) {
            if (conference.jid != null) {
                remote_rooms.add(((!) conference.jid).bare_jid);
            }
        }
        var resolved = new ArrayList<Jid>();
        foreach (Jid room in pending_permanent_bookmark_removals[account]) {
            bool active_remove = false;
            if (active_autojoin_bookmark_writes.has_key(account) &&
                    active_autojoin_bookmark_writes[account].has_key(room)) {
                AutojoinBookmarkWrite active =
                    active_autojoin_bookmark_writes[account][room];
                active_remove = active.remove_bookmark &&
                    is_current_autojoin_write_generation(account, room,
                        active.generation);
                if (active_remove && !remote_rooms.contains(room)) {
                    active.remove_echo_seen = true;
                }
            }
            if (!remote_rooms.contains(room) && !active_remove) {
                resolved.add(room);
            }
        }
        if (resolved.is_empty) return;
        foreach (Jid room in resolved) {
            pending_permanent_bookmark_removals[account].remove(room);
        }
        if (pending_permanent_bookmark_removals[account].is_empty) {
            pending_permanent_bookmark_removals.unset(account);
        }
        persist_pending_permanent_bookmark_removals(account);
    }

    private void mark_leave(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!leave_markers.has_key(account)) {
            leave_markers[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        leave_markers[account].add(bare);
    }

    private void mark_manually_removed_bookmark(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!manually_removed_bookmarks.has_key(account)) {
            manually_removed_bookmarks[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        manually_removed_bookmarks[account].add(bare);
    }

    private void clear_manually_removed_bookmark(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (manually_removed_bookmarks.has_key(account)) {
            manually_removed_bookmarks[account].remove(bare);
            if (manually_removed_bookmarks[account].is_empty) {
                manually_removed_bookmarks.unset(account);
            }
        }
    }

    private void clear_leave_marker(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (leave_markers.has_key(account)) {
            leave_markers[account].remove(bare);
        }
    }

    private void clear_permanent_leave_marker(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (permanent_leave_markers.has_key(account)) {
            permanent_leave_markers[account].remove(bare);
        }
    }

    private void set_stale_bookmark_remove_echo_fence(Account account,
            Jid jid, uint removed_generation) {
        Jid bare = jid.bare_jid;
        uint desired_generation = get_current_autojoin_write_generation(
            account, bare);
        if (desired_generation == 0 || desired_generation ==
                removed_generation || is_permanent_leave_marked(account,
                    bare) || is_pending_permanent_bookmark_removal(account,
                    bare) || is_manually_removed_bookmark(account, bare)) return;
        AutojoinBookmarkWrite? repair_write = null;
        Conference? desired = get_desired_manual_bookmark(account, bare);
        if (desired != null) {
            Conference current = (!) desired;
            repair_write = new AutojoinBookmarkWrite(current.autojoin,
                current.nick, current.password, false, desired_generation, 0,
                false, false, current.name);
        } else if (pending_autojoin_bookmark_writes.has_key(account) &&
                pending_autojoin_bookmark_writes[account].has_key(bare)) {
            AutojoinBookmarkWrite pending =
                pending_autojoin_bookmark_writes[account][bare];
            if (pending.generation == desired_generation &&
                    !pending.remove_bookmark &&
                    (pending.autojoin || pending.recreate_if_missing)) {
                repair_write = new AutojoinBookmarkWrite(pending.autojoin,
                    pending.nick, pending.password,
                    pending.allow_leave_marker, pending.generation, 0, false,
                    pending.recreate_if_missing, pending.name);
            }
        }
        if (repair_write == null) return;
        if (!stale_bookmark_remove_echo_fences.has_key(account)) {
            stale_bookmark_remove_echo_fences[account] =
                new HashMap<Jid, AutojoinBookmarkWrite>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        stale_bookmark_remove_echo_fences[account][bare] = (!) repair_write;
    }

    private void remember_pending_bookmark_remove_echo(Account account,
            Jid jid, AutojoinBookmarkWrite remove_write) {
        Jid bare = jid.bare_jid;
        if (!stale_bookmark_remove_echo_fences.has_key(account)) {
            stale_bookmark_remove_echo_fences[account] =
                new HashMap<Jid, AutojoinBookmarkWrite>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        stale_bookmark_remove_echo_fences[account][bare] = remove_write;
    }

    private void retarget_stale_bookmark_remove_echo_fence(Account account,
            Jid jid, uint desired_generation,
            AutojoinBookmarkWrite? exact_intent = null) {
        Jid bare = jid.bare_jid;
        if (stale_bookmark_remove_echo_fences.has_key(account) &&
                stale_bookmark_remove_echo_fences[account].has_key(bare)) {
            if (exact_intent != null) {
                stale_bookmark_remove_echo_fences[account][bare] =
                    (!) exact_intent;
                return;
            }
            AutojoinBookmarkWrite repair =
                stale_bookmark_remove_echo_fences[account][bare];
            repair.generation = desired_generation;
            Conference? desired = get_desired_manual_bookmark(account, bare);
            if (desired != null) {
                Conference current = (!) desired;
                stale_bookmark_remove_echo_fences[account][bare] =
                    new AutojoinBookmarkWrite(
                    current.autojoin, current.nick, current.password, false,
                    desired_generation, 0, false, false, current.name);
            }
        }
    }

    private void clear_stale_bookmark_remove_echo_fence(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!stale_bookmark_remove_echo_fences.has_key(account)) return;
        stale_bookmark_remove_echo_fences[account].unset(bare);
        if (stale_bookmark_remove_echo_fences[account].is_empty) {
            stale_bookmark_remove_echo_fences.unset(account);
        }
    }

    private bool consume_stale_bookmark_remove_echo_fence(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!stale_bookmark_remove_echo_fences.has_key(account) ||
                !stale_bookmark_remove_echo_fences[account].has_key(bare)) {
            return false;
        }
        AutojoinBookmarkWrite repair =
            stale_bookmark_remove_echo_fences[account][bare];
        clear_stale_bookmark_remove_echo_fence(account, bare);
        if (!is_current_autojoin_write_generation(account, bare,
                repair.generation)) return false;
        if (repair.remove_bookmark) return true;
        if (
                is_permanent_leave_marked(account, bare) ||
                is_pending_permanent_bookmark_removal(account, bare) ||
                is_manually_removed_bookmark(account, bare)) {
            return false;
        }
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !bookmarks_provider.has_key(account)) {
            return false;
        }
        Conference? desired = get_desired_manual_bookmark(account, bare);
        if (desired != null && !is_leave_marked(account, bare)) {
            repair_desired_manual_bookmark(account, (!) stream, bare,
                "stale-remove-echo");
        } else if (repair.recreate_if_missing &&
                is_leave_marked(account, bare)) {
            queue_autojoin_bookmark_write(account, (!) stream, bare,
                repair.autojoin, repair.nick, repair.password,
                repair.allow_leave_marker, repair.generation, 0,
                false, true, repair.name);
        } else {
            return false;
        }
        return true;
    }

    private void clear_manual_bookmark_removal_notification(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!manual_bookmark_removal_notified.has_key(account)) return;
        manual_bookmark_removal_notified[account].remove(bare);
        if (manual_bookmark_removal_notified[account].is_empty) {
            manual_bookmark_removal_notified.unset(account);
        }
    }

    private bool mark_manual_bookmark_removal_notification(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        if (!manual_bookmark_removal_notified.has_key(account)) {
            manual_bookmark_removal_notified[account] = new HashSet<Jid>(
                Jid.hash_bare_func, Jid.equals_bare_func);
        }
        return manual_bookmark_removal_notified[account].add(bare);
    }

    private void track_active_manual_bookmark_removal(Account account,
            Jid jid, AutojoinBookmarkWrite write) {
        Jid bare = jid.bare_jid;
        if (!active_manual_bookmark_removals.has_key(account)) {
            active_manual_bookmark_removals[account] =
                new HashMap<Jid, AutojoinBookmarkWrite>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        active_manual_bookmark_removals[account][bare] = write;
    }

    private void clear_active_manual_bookmark_removal(Account account,
            Jid jid, AutojoinBookmarkWrite write) {
        Jid bare = jid.bare_jid;
        if (!active_manual_bookmark_removals.has_key(account) ||
                !active_manual_bookmark_removals[account].has_key(bare) ||
                active_manual_bookmark_removals[account][bare] != write) {
            return;
        }
        active_manual_bookmark_removals[account].unset(bare);
        if (active_manual_bookmark_removals[account].is_empty) {
            active_manual_bookmark_removals.unset(account);
        }
    }

    private bool is_leave_marked(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        return leave_markers.has_key(account) && leave_markers[account].contains(bare);
    }

    private bool is_permanent_leave_marked(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        return permanent_leave_markers.has_key(account) && permanent_leave_markers[account].contains(bare);
    }

    private bool is_manually_removed_bookmark(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        return manually_removed_bookmarks.has_key(account) && manually_removed_bookmarks[account].contains(bare);
    }

    private Set<Conference> filter_manually_removed_conferences(Account account, Set<Conference> conferences) {
        bool has_manual_removals = manually_removed_bookmarks.has_key(account) &&
            !manually_removed_bookmarks[account].is_empty;
        bool has_permanent_leaves = permanent_leave_markers.has_key(account) &&
            !permanent_leave_markers[account].is_empty;
        bool has_pending_removals =
            pending_permanent_bookmark_removals.has_key(account) &&
            !pending_permanent_bookmark_removals[account].is_empty;
        if (!has_manual_removals && !has_permanent_leaves &&
                !has_pending_removals) return conferences;

        var filtered = new HashSet<Conference>(Conference.hash_func, Conference.equals_func);
        bool filtered_any = false;
        foreach (Conference conference in conferences) {
            if (conference.jid != null &&
                    (is_manually_removed_bookmark(account,
                        ((!) conference.jid).bare_jid) ||
                     is_permanent_leave_marked(account,
                        ((!) conference.jid).bare_jid) ||
                     is_pending_permanent_bookmark_removal(account,
                        ((!) conference.jid).bare_jid))) {
                filtered_any = true;
                continue;
            }
            filtered.add(conference);
        }
        return filtered_any ? filtered : conferences;
    }

    private void remove_bookmarks2_cache_entry(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        Xep.Bookmarks2.Flag? bm_flag = stream.get_flag(Xep.Bookmarks2.Flag.IDENTITY);
        if (bm_flag != null) {
            bm_flag.conferences.unset(jid.bare_jid);
        }
    }

    private Conference clone_bookmark_conference(Conference conference) {
        return new Conference() {
            jid=conference.jid != null ? ((!) conference.jid).bare_jid : null,
            nick=conference.nick,
            name=conference.name,
            password=conference.password,
            autojoin=conference.autojoin
        };
    }

    private void remember_desired_manual_bookmark(Account account, Conference conference) {
        if (conference.jid == null) return;
        if (!desired_manual_bookmarks.has_key(account)) {
            desired_manual_bookmarks[account] = new HashMap<Jid, Conference>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        desired_manual_bookmarks[account][((!) conference.jid).bare_jid] = clone_bookmark_conference(conference);
    }

    private Conference? get_desired_manual_bookmark(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!desired_manual_bookmarks.has_key(account) || !desired_manual_bookmarks[account].has_key(bare)) return null;
        return desired_manual_bookmarks[account][bare];
    }

    private void forget_desired_manual_bookmark(Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!desired_manual_bookmarks.has_key(account)) return;
        desired_manual_bookmarks[account].unset(bare);
        if (desired_manual_bookmarks[account].is_empty) {
            desired_manual_bookmarks.unset(account);
        }
    }

    private void repair_desired_manual_bookmark(Account account, XmppStream stream, Jid jid, string reason) {
        if (is_leave_blocked(account, jid)) return;
        Conference? desired = get_desired_manual_bookmark(account, jid);
        if (desired == null) return;
        Conference current = (!) desired;
        uint generation = get_current_autojoin_write_generation(account, jid);
        if (generation == 0) {
            generation = next_autojoin_write_generation(account, jid);
        }
        queue_autojoin_bookmark_write(account, stream, jid,
            current.autojoin, current.nick, current.password, false,
            generation, 0, false, true, current.name);
    }

    private bool is_leave_blocked(Account account, Jid jid) {
        return is_leave_marked(account, jid) ||
            is_permanent_leave_marked(account, jid) ||
            is_pending_permanent_bookmark_removal(account, jid);
    }

    private string? get_muc_exit_nick(Account account, Jid jid, Conversation? conversation = null) {
        Jid bare = jid.bare_jid;
        Jid? own_jid = get_own_jid(bare, account);
        if (own_jid != null && own_jid.resourcepart != null && own_jid.resourcepart != "") {
            return own_jid.resourcepart;
        }
        if (conversation != null && conversation.nickname != null && conversation.nickname != "") {
            return conversation.nickname;
        }
        return account.localpart ?? account.domainpart;
    }

    public async DataForms.DataForm? get_config_form(Account account, Jid jid) {
        MucOwnerMutationContext? maybe_context =
            capture_owner_mutation_context(account, jid);
        if (maybe_context == null) return null;
        return yield get_config_form_in_context(account, (!) maybe_context);
    }

    public async DataForms.DataForm? get_config_form_in_context(Account account,
            MucOwnerMutationContext context) {
        if (!is_current_owner_mutation_context(account, context)) return null;
        DataForms.DataForm? form = yield context.stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).get_config_form(
                context.stream, context.room);
        if (!is_current_owner_mutation_context(account, context)) return null;
        return form;
    }

    private MucOwnerMutationContext? capture_muc_mutation_context(
            Account account, Jid room) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        Jid bare_room = room.bare_jid;
        Jid? own_jid = get_own_jid(bare_room, account);
        if (own_jid == null) return null;

        string logical_key = muc_occupant_room_key(account.id,
            bare_room.to_string());
        uint? room_generation = null;
        if (muc_occupant_room_generations.has_key(logical_key)) {
            room_generation = muc_occupant_room_generations[logical_key];
        }
        return new MucOwnerMutationContext((!) stream, bare_room,
            (!) own_jid, get_muc_runtime_generation(account), room_generation);
    }

    private MucOwnerMutationContext? capture_owner_mutation_context(
            Account account, Jid room) {
        MucOwnerMutationContext? context = capture_muc_mutation_context(account,
            room);
        if (context == null) return null;
        Xep.Muc.Affiliation affiliation;
        if (!get_known_current_affiliation(account, ((!) context).room,
                ((!) context).own_jid, out affiliation) ||
                affiliation != Xep.Muc.Affiliation.OWNER) return null;
        return context;
    }

    public MucOwnerMutationContext? capture_current_owner_context(
            Account account, Jid room) {
        return capture_owner_mutation_context(account, room);
    }

    /** Capture the exact joined-room lifecycle used by a long-lived UI. */
    public MucOwnerMutationContext? capture_current_muc_context(
            Account account, Jid room) {
        return capture_muc_mutation_context(account, room);
    }

    private bool is_current_owner_mutation_lifecycle(Account account,
            MucOwnerMutationContext context) {
        if (stream_interactor.get_stream(account) != context.stream ||
                get_muc_runtime_generation(account) !=
                    context.runtime_generation) return false;

        string logical_key = muc_occupant_room_key(account.id,
            context.room.to_string());
        if (context.room_generation != null) {
            if (!muc_occupant_room_generations.has_key(logical_key) ||
                    muc_occupant_room_generations[logical_key] !=
                        (!) context.room_generation) return false;
        } else if (muc_occupant_room_generations.has_key(logical_key)) {
            // A MucManager-owned lifecycle appeared after a MUJI/no-worker
            // context was captured; the old continuation cannot own it.
            return false;
        }
        return true;
    }

    private bool has_current_muc_join_identity(Account account,
            MucOwnerMutationContext context) {
        Jid? own_jid = get_own_jid(context.room, account);
        return own_jid != null && ((!) own_jid).equals(context.own_jid);
    }

    private bool is_current_muc_mutation_context(Account account,
            MucOwnerMutationContext context) {
        return is_current_owner_mutation_lifecycle(account, context) &&
            has_current_muc_join_identity(account, context);
    }

    private bool is_current_owner_mutation_context(Account account,
            MucOwnerMutationContext context) {
        if (!is_current_muc_mutation_context(account, context)) return false;

        Xep.Muc.Affiliation affiliation;
        return get_known_current_affiliation(account, context.room,
                context.own_jid, out affiliation) &&
            affiliation == Xep.Muc.Affiliation.OWNER;
    }

    public bool is_current_owner_context(Account account,
            MucOwnerMutationContext context) {
        return is_current_owner_mutation_context(account, context);
    }

    public bool is_current_muc_context(Account account,
            MucOwnerMutationContext context) {
        return is_current_muc_mutation_context(account, context);
    }

    private static string muc_avatar_mutation_key(Account account, Jid room) {
        return "%d\x1f%s".printf(account.id, room.bare_jid.to_string());
    }

    public bool try_begin_muc_avatar_mutation(Account account, Jid room) {
        return active_muc_avatar_mutations.add(
            muc_avatar_mutation_key(account, room));
    }

    public void finish_muc_avatar_mutation(Account account, Jid room) {
        active_muc_avatar_mutations.remove(
            muc_avatar_mutation_key(account, room));
    }

    private static void throw_if_muc_iq_error(Iq.Stanza result,
            string context) throws GLib.Error {
        if (!result.is_error()) return;
        ErrorStanza? stanza_error = result.get_error();
        string detail = "unknown stanza error";
        if (stanza_error != null) {
            detail = ((!) stanza_error).condition;
            if (((!) stanza_error).text != null &&
                    ((!) stanza_error).text != "") {
                detail += ": " + ((!) stanza_error).text;
            }
        }
        throw new GLib.IOError.FAILED(
            "Server rejected %s: %s".printf(context, detail));
    }

    private static void require_muc_iq_sender(Iq.Stanza result, Jid room,
            string context) throws GLib.Error {
        string? result_from = result.stanza.get_attribute("from");
        if (result_from != null) {
            try {
                if (new Jid((!) result_from).equals(room.bare_jid)) return;
            } catch (InvalidJidError e) {
                // Malformed and unexpected senders fail identically below.
            }
        }
        throw new GLib.IOError.FAILED(
            "Ignoring %s result from an unexpected room sender".printf(
                context));
    }

    public async Xep.VCard.VCardInfo? fetch_muc_vcard_in_owner_context(
            Account account, MucOwnerMutationContext context)
            throws GLib.Error {
        if (!is_current_owner_mutation_context(account, context)) {
            throw new GLib.IOError.PERMISSION_DENIED(
                "Room owner permission is no longer available");
        }
        const string VCARD_TEMP_NS = "vcard-temp";
        Iq.Stanza request = new Iq.Stanza.get(new StanzaNode.build(
            "vCard", VCARD_TEMP_NS).add_self_xmlns()) {
                to = context.room
            };
        Iq.Stanza result = yield context.stream.get_module<Iq.Module>(
            Iq.Module.IDENTITY).send_iq_async(context.stream, request);
        if (!is_current_owner_mutation_context(account, context)) {
            throw new GLib.IOError.CANCELLED(
                "Room lifecycle changed during avatar query");
        }
        require_muc_iq_sender(result, context.room, "room avatar query");
        if (result.is_error()) {
            ErrorStanza? stanza_error = result.get_error();
            // XEP-0054 explicitly permits item-not-found when no vCard has
            // been stored yet.  XEP-0486 then expects the owner to publish a
            // complete vCard with IQ-set, so this is an empty baseline rather
            // than a failed room-avatar operation.
            if (stanza_error != null && ((!) stanza_error).condition ==
                    ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
                return null;
            }
            throw_if_muc_iq_error(result, "room avatar query");
        }
        StanzaNode? vcard_node = result.stanza.get_subnode("vCard",
            VCARD_TEMP_NS);
        return vcard_node != null
            ? Xep.VCard.VCardInfo.from_node((!) vcard_node)
            : null;
    }

    public async void publish_muc_vcard_in_owner_context(Account account,
            MucOwnerMutationContext context, Xep.VCard.VCardInfo vcard)
            throws GLib.Error {
        if (!is_current_owner_mutation_context(account, context)) {
            throw new GLib.IOError.PERMISSION_DENIED(
                "Room owner permission is no longer available");
        }
        Iq.Stanza request = new Iq.Stanza.set(
            vcard.to_node().add_self_xmlns()) { to = context.room };
        Iq.Stanza result = yield context.stream.get_module<Iq.Module>(
            Iq.Module.IDENTITY).send_iq_async(context.stream, request);
        if (!is_current_owner_mutation_context(account, context)) {
            throw new GLib.IOError.CANCELLED(
                "Room lifecycle changed during avatar update");
        }
        throw_if_muc_iq_error(result, "room avatar update");
        require_muc_iq_sender(result, context.room, "room avatar update");
    }

    private bool is_current_bookmark_provider(Account account,
            BookmarksProvider provider) {
        return bookmarks_provider.has_key(account) &&
            bookmarks_provider[account] == provider;
    }

    public static bool? get_members_only_config_value(DataForms.DataForm data_form) {
        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var != "muc#roomconfig_membersonly") continue;

            switch (field.get_value_string().down()) {
                case "1":
                case "true":
                    return true;
                case "0":
                case "false":
                    return false;
                default:
                    warning("Invalid members-only value in MUC configuration form");
                    return null;
            }
        }
        return null;
    }

    public async bool set_config_form(Account account, Jid jid,
            DataForms.DataForm data_form, bool? original_members_only) {
        MucConfigSaveResult result = yield set_config_form_detailed(account,
            jid, data_form, original_members_only);
        return result == MucConfigSaveResult.APPLIED ||
            result == MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING;
    }

    public async MucConfigSaveResult set_config_form_detailed(Account account,
            Jid jid, DataForms.DataForm data_form,
            bool? original_members_only) {
        return yield set_config_form_detailed_internal(account, jid,
            data_form, original_members_only, null);
    }

    public async MucConfigSaveResult set_config_form_detailed_in_context(
            Account account, MucOwnerMutationContext context,
            DataForms.DataForm data_form, bool? original_members_only) {
        string[] confirmed_presence_broadcast_roles;
        bool presence_broadcast_changed = try_get_changed_config_values(
            data_form, "muc#roomconfig_presencebroadcast",
            out confirmed_presence_broadcast_roles);
        bool? confirmed_hats_enabled = get_changed_config_boolean(data_form,
            "muc#roomconfig_enable_hats");
        string[] confirmed_whois_values;
        bool whois_changed = try_get_changed_config_values(data_form,
            "muc#roomconfig_whois", out confirmed_whois_values);
        bool refresh_occupant_projection =
            config_changes_occupant_projection(
                data_form.get_changed_field_vars());
        MucConfigSaveResult result = yield set_config_form_detailed_internal(
            account, context.room, data_form, original_members_only,
            context);
        if ((refresh_occupant_projection || whois_changed) &&
                is_applied_config_result(result) &&
                is_current_owner_mutation_context(account, context)) {
            Xep.Muc.Module module = context.stream.get_module<Xep.Muc.Module>(
                Xep.Muc.Module.IDENTITY);
            // Local removal is allowed only after the owner-form readback
            // verified the effective values. A merely acknowledged SET is not
            // enough authority to hide occupants or clear their Hats.
            if (result != MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED) {
                if (presence_broadcast_changed) {
                    module.apply_confirmed_presence_broadcast_roles(
                        context.stream, context.room,
                        confirmed_presence_broadcast_roles);
                    // The UI projection can already be stale even when the
                    // protocol cache had no matching row left to remove.
                    // Always invalidate it after a verified restriction.
                    room_occupant_projection_changed(account, context.room);
                }
                if (confirmed_hats_enabled != null &&
                        !((!) confirmed_hats_enabled)) {
                    module.clear_confirmed_room_hats(context.stream,
                        context.room);
                }
                if (whois_changed) {
                    // A successful disco refresh has already applied the same
                    // value, making this a no-op. A failed disco refresh is
                    // repaired from the verified owner-form readback.
                    refresh_occupant_projection =
                        module.apply_confirmed_room_whois(context.stream,
                            context.room, confirmed_whois_values) ||
                        refresh_occupant_projection;
                }
            } else if (whois_changed) {
                // The SET may still have been applied. A replay is merge-only
                // and can safely pick up whatever state the room now exposes.
                refresh_occupant_projection = true;
            }
            // XEP-0045 allows an already joined client to request a replay by
            // sending another tagged join presence. This is best-effort and
            // merge-only: never erase valid occupant state before a server
            // which only SHOULD answer has actually sent updated presences.
            if (refresh_occupant_projection) {
                module.request_occupant_presence_resync(context.stream,
                    context.room);
            }
        }
        return result;
    }

    private static bool config_changes_occupant_projection(
            Gee.List<string> changed_fields) {
        foreach (string field in changed_fields) {
            switch (field) {
                case "muc#roomconfig_presencebroadcast":
                case "muc#roomconfig_enable_hats":
                case "muc#roomconfig_moderatedroom":
                    return true;
            }
        }
        return false;
    }

    private static bool try_get_changed_config_values(
            DataForms.DataForm data_form, string var_name,
            out string[] values) {
        values = new string[0];
        if (!data_form.has_changed_field(var_name)) return false;
        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var != var_name) continue;
            values = field.get_values().to_array();
            return true;
        }
        return false;
    }

    private static bool? get_changed_config_boolean(
            DataForms.DataForm data_form, string var_name) {
        string[] values;
        if (!try_get_changed_config_values(data_form, var_name, out values)) {
            return null;
        }
        if (values.length == 0) return false;
        string value = values[0].down();
        if (value == "1" || value == "true") return true;
        if (value == "0" || value == "false" || value == "") return false;
        return null;
    }

    private static bool is_applied_config_result(MucConfigSaveResult result) {
        return result == MucConfigSaveResult.APPLIED ||
            result == MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
            result == MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED;
    }

    private async MucConfigSaveResult set_config_form_detailed_internal(
            Account account, Jid jid, DataForms.DataForm data_form,
            bool? original_members_only,
            MucOwnerMutationContext? expected_context) {
        MucOwnerMutationContext? maybe_context = expected_context != null
            ? expected_context
            : capture_owner_mutation_context(account, jid);
        if (maybe_context == null) {
            warning("Refusing to configure %s without a current joined Owner context",
                jid.bare_jid.to_string());
            return MucConfigSaveResult.REJECTED;
        }
        MucOwnerMutationContext context = (!) maybe_context;
        if (!context.room.equals_bare(jid) ||
                !is_current_owner_mutation_context(account, context)) {
            debug("Refusing stale room configuration for %s",
                jid.bare_jid.to_string());
            return MucConfigSaveResult.REJECTED;
        }
        XmppStream stream = context.stream;
        bool was_private_room = is_private_room(account, context.room);
        Gee.List<DataForms.DataForm.Field> missing_required =
            data_form.get_missing_required_fields();
        if (!missing_required.is_empty) {
            warning("Refusing incomplete MUC configuration with %d missing required field(s)",
                missing_required.size);
            return MucConfigSaveResult.REJECTED;
        }
        Gee.List<string> changed_config_fields =
            data_form.get_changed_field_vars();

        // Extract room name, password and check for membersonly change
        string? new_room_name = null;
        string? new_password = null;
        bool room_name_field_found = false;
        bool password_field_found = false;
        bool room_name_server_verified = false;
        bool password_server_verified = false;
        bool safeguarding_members_only = false;
        bool? requested_members_only = get_members_only_config_value(data_form);
        // The XEP-0004 submit contains only changed optional fields.  Run the
        // occupant-preservation preflight only for an actual false -> true
        // transition; an unrelated edit in an already members-only room must
        // never be blocked by affiliation queries or unresolved real JIDs.
        safeguarding_members_only = requested_members_only != null &&
            (!) requested_members_only &&
            ((original_members_only != null &&
                !((!) original_members_only)) ||
             data_form.has_changed_field("muc#roomconfig_membersonly"));

        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var == "muc#roomconfig_roomname" &&
                    data_form.has_changed_field((!) field.var)) {
                room_name_field_found = true;
                new_room_name = field.get_value_string();
                // Treat empty string as null (no custom name)
                if (new_room_name != null && new_room_name.strip() == "") {
                    new_room_name = null;
                }
            } else if (field.var == "muc#roomconfig_roomsecret" &&
                    data_form.has_changed_field((!) field.var)) {
                password_field_found = true;
                new_password = field.get_value_string();
                debug("MUC config: Found password field, value length = %d", new_password != null ? new_password.length : 0);
                // Treat empty string as null (no password)
                if (new_password != null && new_password.strip() == "") {
                    new_password = null;
                }
            }
        }

        // If enabling members-only, add all current occupants as members first
        // This prevents them from being kicked out (Status Code 322)
        Gee.List<Jid> preflight_added_members = new ArrayList<Jid>(
            Jid.equals_bare_func);
        if (safeguarding_members_only) {
            try {
                preflight_added_members = yield add_occupants_as_members(
                    account, jid, context);
            } catch (MucConfigPreflightError.MEMBERS_PRESERVED e) {
                warning("Could not make all current occupants members before enabling members-only: %s",
                    e.message);
                return MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED;
            } catch (GLib.Error e) {
                warning("Could not make current occupants members before enabling members-only: %s", e.message);
                return MucConfigSaveResult.REJECTED;
            }
        }

        if (!is_current_owner_mutation_context(account, context)) {
            bool rollback_complete = rollback_preflight_members(
                preflight_added_members);
            if (!rollback_complete && preflight_added_members.size > 0) {
                warning("MUC configuration context changed and preflight membership rollback is incomplete for %s",
                    jid.bare_jid.to_string());
            }
            return preflight_added_members.size > 0
                ? MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED
                : MucConfigSaveResult.REJECTED;
        }

        bool saved = yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).set_config_form(stream, jid, data_form);
        if (!saved) {
            bool rollback_complete = rollback_preflight_members(
                preflight_added_members);
            if (!rollback_complete && preflight_added_members.size > 0) {
                warning("MUC configuration was rejected and preflight membership rollback is incomplete for %s",
                    jid.bare_jid.to_string());
            }
            return preflight_added_members.size > 0
                ? MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED
                : MucConfigSaveResult.REJECTED;
        }

        // A successful owner IQ may already have changed the room. Continue
        // bookmark/password synchronization after a mere demotion, but stop
        // if the stream or join lifecycle changed. Never remove preflight
        // members from a room that may now be members-only.
        if (!is_current_owner_mutation_lifecycle(account, context)) {
            return MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED;
        }

        // An empty IQ result acknowledges the transaction, not the effective
        // values. Re-read the owner form and verify every changed field before
        // DinoX adopts the local form as its new baseline. A failed/mismatched
        // readback is a synchronization warning, never a blind retry: the SET
        // may already have changed part of the room configuration.
        bool server_state_verified = false;
        DataForms.DataForm? confirmed_form = yield stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).get_config_form(stream,
                context.room);
        if (!is_current_owner_mutation_lifecycle(account, context)) {
            return MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED;
        }
        if (confirmed_form != null && data_form.matches_field_values(
                (!) confirmed_form, changed_config_fields)) {
            server_state_verified = true;
            data_form.accept_server_roundtrip((!) confirmed_form);
        } else {
            warning("MUC configuration SET was acknowledged, but the changed server values could not be confirmed for %s",
                context.room.to_string());
        }
        if (confirmed_form != null && room_name_field_found) {
            var room_name_field = new ArrayList<string>();
            room_name_field.add("muc#roomconfig_roomname");
            room_name_server_verified = data_form.matches_field_values(
                (!) confirmed_form, room_name_field);
        }
        if (confirmed_form != null && password_field_found) {
            var password_field = new ArrayList<string>();
            password_field.add("muc#roomconfig_roomsecret");
            password_server_verified = data_form.matches_field_values(
                (!) confirmed_form, password_field);
        }
        if (room_name_field_found && !room_name_server_verified) {
            warning("Skipping unconfirmed MUC bookmark name synchronization for %s",
                context.room.to_string());
            room_name_field_found = false;
        }
        if (password_field_found && !password_server_verified) {
            warning("Skipping unconfirmed MUC bookmark password synchronization for %s",
                context.room.to_string());
            password_field_found = false;
        }
        MucConfigSaveResult applied_warning_result = server_state_verified
            ? MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING
            : MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED;
        bool local_sync_warning = false;

        // Refresh the live MUC feature flag synchronously. Its room-info signal
        // refreshes EntityInfo in the background, so a second disco request
        // here would only duplicate network traffic.
        bool room_info_refreshed = yield stream.get_module<Xep.Muc.Module>(
            Xep.Muc.Module.IDENTITY).query_room_info(stream, context.room);
        if (!is_current_owner_mutation_lifecycle(account, context)) {
            return applied_warning_result;
        }
        if (!room_info_refreshed) {
            warning("MUC configuration was applied, but refreshed room information could not be confirmed for %s",
                context.room.to_string());
            local_sync_warning = true;
        }

        if (room_info_refreshed) {
            bool is_private_room_now = is_private_room(account, context.room);

            // Notify only when the effective DinoX privacy state changed.
            // members-only alone is not private: the room must also be
            // non-anonymous (whois=anyone) for OMEMO membership identity.
            // Note: These are sent to all clients, so we keep them in English
            if (was_private_room && !is_private_room_now &&
                    has_current_muc_join_identity(account, context)) {
                // Room switched from private to public
                string notification = "⚠️ This room is now PUBLIC. OMEMO encryption has been disabled. Messages are no longer end-to-end encrypted.";
                send_room_notification(account, jid, notification);
            } else if (!was_private_room && is_private_room_now &&
                    has_current_muc_join_identity(account, context)) {
                // Room switched from public to private
                string notification = "🔒 This room is now PRIVATE (members-only). OMEMO encryption is now available.";
                send_room_notification(account, jid, notification);
            }
        }
        
        // Update bookmark with new room name or password if changed. An
        // unavailable backend is not a clean save: the room may already have
        // accepted the owner form, but DinoX could not persist the credentials
        // needed for the next join.
        if (room_name_field_found || password_field_found) {
            if (!bookmarks_provider.has_key(account)) {
                warning("No MUC bookmark backend while syncing configuration for %s",
                    jid.bare_jid.to_string());
                return applied_warning_result;
            }
            BookmarksProvider provider = bookmarks_provider[account];
            if (!is_current_owner_mutation_lifecycle(account, context) ||
                    !is_current_bookmark_provider(account, provider)) {
                return applied_warning_result;
            }
            Set<Conference>? conferences = yield provider.get_conferences(stream);
            if (!is_current_owner_mutation_lifecycle(account, context) ||
                    !is_current_bookmark_provider(account, provider)) {
                return applied_warning_result;
            }
            if (conferences == null) {
                warning("Failed to read MUC bookmarks while syncing configuration for %s",
                    jid.bare_jid.to_string());
                return applied_warning_result;
            }
            foreach (Conference conference in (!) conferences) {
                    if (conference.jid != null &&
                            ((!) conference.jid).equals_bare(jid)) {
                        // Check if name actually changed (treat null and empty as equivalent)
                        string? old_name = (conference.name != null && conference.name.strip() != "") ? conference.name : null;
                        string? old_password = (conference.password != null && conference.password.strip() != "") ? conference.password : null;
                        
                        // Use new values if field was found, otherwise keep old values
                        string? final_name = room_name_field_found ? new_room_name : old_name;
                        string? final_password = password_field_found ? new_password : old_password;
                        
                        bool name_changed = (old_name != final_name);
                        bool password_changed = (old_password != final_password);
                        
                        if (name_changed || password_changed) {
                            Conference new_conference = new Conference() { 
                                jid=jid, 
                                nick=conference.nick, 
                                name=final_name,
                                password=final_password, 
                                autojoin=conference.autojoin 
                            };
                            
                            if (!is_current_owner_mutation_lifecycle(account,
                                    context) || !is_current_bookmark_provider(
                                        account, provider)) {
                                return applied_warning_result;
                            }
                            bool bookmark_updated = yield provider.replace_conference(
                                stream, jid.bare_jid, new_conference);
                            if (!is_current_owner_mutation_lifecycle(account,
                                    context) || !is_current_bookmark_provider(
                                        account, provider)) {
                                return applied_warning_result;
                            }
                            if (!bookmark_updated) {
                                warning("Failed to update MUC bookmark details for %s", jid.to_string());
                                return applied_warning_result;
                            }

                            // Commit the local cache only after the bookmark
                            // backend confirmed the replacement.
                            if (name_changed) {
                                if (!bookmark_names.has_key(account)) {
                                    bookmark_names[account] = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
                                }
                                if (final_name != null) {
                                    bookmark_names[account][jid.bare_jid] = final_name;
                                } else {
                                    bookmark_names[account].unset(jid.bare_jid);
                                }
                            }
                            
                            // Trigger room_info_updated to refresh UI with new bookmark name
                            room_info_updated(account, jid);
                            
                            if (password_changed) {
                                debug("MUC password updated in bookmark for %s", jid.to_string());
                            }
                        }
                        break;
                    }
                }
        }
        
        if (!server_state_verified) {
            return MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED;
        }
        return local_sync_warning
            ? MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING
            : MucConfigSaveResult.APPLIED;
    }

    public void change_subject_checked(Account account, Jid jid,
            string subject) throws GLib.Error {
        MucOwnerMutationContext? maybe_context =
            capture_muc_mutation_context(account, jid);
        if (maybe_context == null) {
            throw new IOError.NOT_CONNECTED(
                "No current joined room context for account");
        }
        change_subject_checked_in_context(account, (!) maybe_context,
            subject);
    }

    /**
     * Change the subject only for the exact joined-room lifecycle in which a
     * long-lived UI row was created. A reconnect or same-stream rejoin must
     * not let that old row address the replacement room session.
     */
    public void change_subject_checked_in_context(Account account,
            MucOwnerMutationContext context, string subject)
            throws GLib.Error {
        if (!is_current_muc_mutation_context(account, context)) {
            throw new IOError.CANCELLED(
                "The joined MUC lifecycle changed before the subject change");
        }
        if (!can_change_subject_in_context(account, context)) {
            throw new IOError.PERMISSION_DENIED(
                "Current MUC role state does not authorize changing the subject");
        }

        // XEP-0045 changes the subject with a groupchat message rather than a
        // result-bearing IQ. Freeze and validate the current join immediately
        // before handing that message to the stream.
        context.stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
            .change_subject(context.stream, context.room, subject);
    }

    private bool can_change_subject_in_context(Account account,
            MucOwnerMutationContext context) {
        Xep.Muc.Role? role = get_role(context.own_jid, account);
        if (role == Xep.Muc.Role.MODERATOR) return true;
        if (role == null || role == Xep.Muc.Role.NONE) return false;

        Xep.Muc.Flag? flag = context.stream.get_flag(Xep.Muc.Flag.IDENTITY);
        return flag != null &&
            ((!) flag).get_occupants_may_change_subject(context.room) == true;
    }

    public bool can_change_subject(Account account, Jid jid) {
        MucOwnerMutationContext? context = capture_muc_mutation_context(
            account, jid);
        return context != null &&
            is_current_muc_mutation_context(account, (!) context) &&
            can_change_subject_in_context(account, (!) context);
    }

    public void change_subject(Account account, Jid jid, string subject) {
        try {
            change_subject_checked(account, jid, subject);
        } catch (GLib.Error e) {
            warning("Refusing to change MUC subject: %s", e.message);
        }
    }

    // Send a notification message to a MUC room (visible to all participants)
    private void send_room_notification(Account account, Jid room_jid, string message) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;
        
        MessageStanza stanza = new MessageStanza();
        stanza.to = room_jid.bare_jid;
        stanza.type_ = MessageStanza.TYPE_GROUPCHAT;
        stanza.body = message;
        
        stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY).send_message.begin(stream, stanza);
    }

    public async void change_nick(Conversation conversation, string new_nick) {
        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) return;

        // Check if this would be a valid nick
        try {
            conversation.counterpart.with_resource(new_nick);
        } catch (InvalidJidError error) { return; }

        stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).change_nick(stream, conversation.counterpart, new_nick);

        conversation.nickname = new_nick;

        if (mucs_joined.has_key(conversation.account)) {
            mucs_joined[conversation.account].remove(conversation.counterpart);
            try {
                mucs_joined[conversation.account].add(conversation.counterpart.with_resource(new_nick));
            } catch (Xmpp.InvalidJidError e) {
                warning("Failed to update MUC JID with new nick: %s", e.message);
            }
        }

        // Update nick in bookmark
        Set<Conference>? conferences = yield bookmarks_provider[conversation.account].get_conferences(stream);
        if (conferences == null) return;
        foreach (Conference conference in conferences) {
            if (conference.jid.equals(conversation.counterpart)) {
                Conference new_conference = new Conference() { jid=conversation.counterpart, nick=new_nick, name=conference.name, password=conference.password, autojoin=conference.autojoin };
                BookmarksProvider provider = bookmarks_provider[conversation.account];
                provider.replace_conference.begin(stream, conversation.counterpart, new_conference, (_, res) => {
                    bool ok = provider.replace_conference.end(res);
                    if (!ok) {
                        warning("Failed to update MUC bookmark nick for %s", conversation.counterpart.to_string());
                    }
                });
                break;
            }
        }
    }

    public async MucInviteSendResult invite(Account account, Jid muc, Jid invitee, string? reason = null, MucInviteDelivery delivery = MucInviteDelivery.MEDIATED) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return new MucInviteSendResult(delivery, false, "account-not-connected");

        switch (delivery) {
            case MucInviteDelivery.MEDIATED:
                if (stream_interactor.get_stream(account) != stream ||
                        !is_joined(muc.bare_jid, account)) {
                    return new MucInviteSendResult(delivery, false,
                        "not-joined");
                }
                if (!mediated_invite_possible(account, muc)) {
                    return new MucInviteSendResult(delivery, false,
                        "not-allowed");
                }
                var muc_module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
                if (muc_module == null) return new MucInviteSendResult(delivery, false, "muc-module-missing");
                try {
                    yield muc_module.invite(stream, muc.bare_jid, invitee.bare_jid, reason);
                    return new MucInviteSendResult(delivery, true);
                } catch (IOError e) {
                    return new MucInviteSendResult(delivery, false, "send-failed");
                }
            case MucInviteDelivery.DIRECT:
                var direct_module = stream.get_module<Xep.DirectMucInvitations.Module>(Xep.DirectMucInvitations.Module.IDENTITY);
                if (direct_module == null) return new MucInviteSendResult(delivery, false, "direct-invite-module-missing");
                try {
                    yield direct_module.invite(stream, muc.bare_jid, invitee.bare_jid, null, reason);
                    return new MucInviteSendResult(delivery, true);
                } catch (IOError e) {
                    return new MucInviteSendResult(delivery, false, "send-failed");
                }
        }

        return new MucInviteSendResult(delivery, false, "unknown-delivery-method");
    }

    public bool is_current_occupant(Account account, Jid room, Jid occupant) {
        if (!occupant.is_full() || !occupant.bare_jid.equals(room.bare_jid) ||
                !is_joined(room, account)) return false;
        return stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY)
            .has_presence(occupant, account);
    }

    /** Resolve the long-lived XEP-0045 affiliation identity for a row. */
    public Jid? get_affiliation_target(Account account, Jid room, Jid selected) {
        if (!selected.is_full()) return selected.bare_jid;
        if (!selected.bare_jid.equals(room.bare_jid)) return null;
        Jid? real_jid = get_real_jid(selected, account);
        return real_jid != null ? ((!) real_jid).bare_jid : null;
    }

    /**
     * Resolve a live private-MUC occupant to the server-disclosed real JID.
     * Nick-only identities are never sufficient for persistent read state.
     */
    public Jid? get_verified_private_muc_participant(Account account,
            Jid room, Jid occupant) {
        Jid bare_room = room.bare_jid;
        if (!has_live_private_room_features(account, bare_room) ||
                !is_current_occupant(account, bare_room, occupant)) {
            return null;
        }

        Jid? real_jid = get_real_jid(occupant, account);
        return real_jid != null ? ((!) real_jid).bare_jid : null;
    }

    /**
     * Resolve the identity currently owning a room/nick PM address. A real
     * bare JID is preferred, then XEP-0421, and finally a local presence
     * generation. The last fallback intentionally changes after leave,
     * reconnect, or process restart so a reused nick cannot inherit history.
     */
    public string? get_private_message_peer_identity(Account account,
            Jid occupant) {
        if (!occupant.is_full() ||
                !is_current_occupant(account, occupant.bare_jid, occupant)) {
            return null;
        }
        if (current_pm_peer_identities.has_key(account) &&
                current_pm_peer_identities[account].has_key(occupant)) {
            return current_pm_peer_identities[account][occupant];
        }
        Jid? real_jid = get_real_jid(occupant, account);
        if (real_jid != null && !((!) real_jid).equals(occupant)) {
            string identity = "jid:" + ((!) real_jid).bare_jid.to_string();
            remember_private_message_peer_identity(account, occupant,
                identity);
            return identity;
        }
        return null;
    }

    /**
     * A presence session may gain stronger identity evidence while the same
     * room/nick remains continuously available (session -> XEP-0421 -> real
     * bare JID). Those aliases denote one peer and must not wipe its thread.
     */
    public bool private_message_peer_identity_matches(Account account,
            Jid occupant, string identity) {
        string? current = get_private_message_peer_identity(account, occupant);
        if (current == null) return false;
        if ((!) current == identity) return true;
        return current_pm_peer_identity_aliases.has_key(account) &&
            current_pm_peer_identity_aliases[account].has_key(occupant) &&
            current_pm_peer_identity_aliases[account][occupant].contains(
                identity);
    }

    private bool peer_identity_matches_occupant_db_id(Account account,
            Jid occupant, string identity, int occupant_db_id) {
        const string PREFIX = "occupant-id:";
        if (!identity.has_prefix(PREFIX) ||
                identity.length <= PREFIX.length) return false;
        string raw_occupant_id = identity.substring(PREFIX.length);
        return stream_interactor.get_module<OccupantIdStore>(
            OccupantIdStore.IDENTITY).matches_occupant_db_id(account,
                raw_occupant_id, occupant.bare_jid, occupant_db_id);
    }

    /**
     * Bind an action attached to a historical groupchat message to the same
     * person who currently owns its room/nick. Nick equality alone is never
     * sufficient because another occupant may reuse it after a leave.
     */
    public bool current_occupant_matches_message_identity(Account account,
            Jid room, Jid occupant, Entities.Message message) {
        if (!is_current_occupant(account, room, occupant)) return false;

        bool has_stable_identity = false;
        if (message.real_jid != null) {
            has_stable_identity = true;
            Jid? current_real_jid = get_real_jid(occupant, account);
            if (current_real_jid == null ||
                    !((!) current_real_jid).equals_bare(
                        ((!) message.real_jid).bare_jid)) return false;
        }

        if (message.occupant_db_id != -1) {
            has_stable_identity = true;
            string? current = get_private_message_peer_identity(account,
                occupant);
            bool matches = current != null &&
                peer_identity_matches_occupant_db_id(account, occupant,
                    (!) current, message.occupant_db_id);
            if (!matches && current_pm_peer_identity_aliases.has_key(account) &&
                    current_pm_peer_identity_aliases[account].has_key(
                        occupant)) {
                foreach (string alias in
                        current_pm_peer_identity_aliases[account][occupant]) {
                    if (peer_identity_matches_occupant_db_id(account,
                            occupant, alias, message.occupant_db_id)) {
                        matches = true;
                        break;
                    }
                }
            }
            if (!matches) return false;
        }

        return has_stable_identity;
    }

    private static int private_message_peer_identity_rank(string identity) {
        if (identity.has_prefix("jid:")) return 3;
        if (identity.has_prefix("occupant-id:")) return 2;
        if (identity.has_prefix("session:")) return 1;
        return 0;
    }

    private void remember_private_message_peer_identity(Account account,
            Jid occupant, string identity) {
        if (!occupant.is_full()) return;
        if (!current_pm_peer_identities.has_key(account)) {
            current_pm_peer_identities[account] =
                new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
        }
        if (!current_pm_peer_identity_aliases.has_key(account)) {
            current_pm_peer_identity_aliases[account] =
                new HashMap<Jid, HashSet<string>>(Jid.hash_func,
                    Jid.equals_func);
        }

        string? previous = current_pm_peer_identities[account][occupant];
        if (previous == null) {
            var aliases = new HashSet<string>();
            aliases.add(identity);
            current_pm_peer_identity_aliases[account][occupant] = aliases;
            current_pm_peer_identities[account][occupant] = identity;
            return;
        }

        int previous_rank = private_message_peer_identity_rank((!) previous);
        int new_rank = private_message_peer_identity_rank(identity);
        if (previous_rank == new_rank && (!) previous != identity) {
            // Conflicting evidence of equal strength is a peer boundary, not
            // an upgrade. Do not carry aliases across it.
            var replacement_aliases = new HashSet<string>();
            replacement_aliases.add(identity);
            current_pm_peer_identity_aliases[account][occupant] =
                replacement_aliases;
            current_pm_peer_identities[account][occupant] = identity;
            return;
        }

        HashSet<string> aliases;
        if (current_pm_peer_identity_aliases[account].has_key(occupant)) {
            aliases = current_pm_peer_identity_aliases[account][occupant];
        } else {
            aliases = new HashSet<string>();
            current_pm_peer_identity_aliases[account][occupant] = aliases;
        }
        // Only one identity of a given strength can describe a live nick at
        // a time. In particular, a new XEP-0421 occupant-id replaces an older
        // occupant-id even if a stronger real-JID remains the primary key.
        // Keeping both would let a later nick owner inherit historical actions.
        var conflicting_aliases = new ArrayList<string>();
        foreach (string alias in aliases) {
            if (alias != identity &&
                    private_message_peer_identity_rank(alias) == new_rank) {
                conflicting_aliases.add(alias);
            }
        }
        foreach (string alias in conflicting_aliases) aliases.remove(alias);
        aliases.add((!) previous);
        aliases.add(identity);
        if (new_rank > previous_rank) {
            current_pm_peer_identities[account][occupant] = identity;
        }
    }

    private void forget_private_message_peer_identity(Account account,
            Jid occupant) {
        if (current_pm_peer_identities.has_key(account)) {
            current_pm_peer_identities[account].unset(occupant);
        }
        if (current_pm_peer_identity_aliases.has_key(account)) {
            current_pm_peer_identity_aliases[account].unset(occupant);
        }
    }

    /**
     * Remove privacy-sensitive real-JID evidence without discarding a stable
     * XEP-0421 occupant identity or the current presence-session boundary.
     * This is used when a room becomes semi-anonymous or an authoritative MUC
     * presence no longer discloses the occupant JID.
     */
    private void forget_private_message_real_jid(Account account,
            Jid occupant) {
        HashSet<string>? aliases = null;
        if (current_pm_peer_identity_aliases.has_key(account) &&
                current_pm_peer_identity_aliases[account].has_key(occupant)) {
            aliases = current_pm_peer_identity_aliases[account][occupant];
            var disclosed_jids = new ArrayList<string>();
            foreach (string alias in (!) aliases) {
                if (private_message_peer_identity_rank(alias) == 3) {
                    disclosed_jids.add(alias);
                }
            }
            foreach (string disclosed_jid in disclosed_jids) {
                ((!) aliases).remove(disclosed_jid);
            }
        }

        if (!current_pm_peer_identities.has_key(account) ||
                !current_pm_peer_identities[account].has_key(occupant) ||
                private_message_peer_identity_rank(
                    current_pm_peer_identities[account][occupant]) != 3) {
            return;
        }

        string? replacement = null;
        if (aliases != null) {
            foreach (string alias in (!) aliases) {
                if (replacement == null || private_message_peer_identity_rank(
                        alias) > private_message_peer_identity_rank(
                            (!) replacement)) {
                    replacement = alias;
                }
            }
        }
        if (replacement == null) {
            // The occupant is still present, but no longer exposes a durable
            // identifier. Keep a process-local session boundary so this live
            // PM thread survives the privacy transition without becoming
            // attachable to a later user of the same nick.
            replacement = "session:%u:%s".printf(
                get_muc_runtime_generation(account),
                GLib.get_monotonic_time().to_string());
            if (aliases == null) {
                aliases = new HashSet<string>();
                if (!current_pm_peer_identity_aliases.has_key(account)) {
                    current_pm_peer_identity_aliases[account] =
                        new HashMap<Jid, HashSet<string>>(Jid.hash_func,
                            Jid.equals_func);
                }
                current_pm_peer_identity_aliases[account][occupant] =
                    (!) aliases;
            }
            ((!) aliases).add((!) replacement);
        }
        current_pm_peer_identities[account][occupant] = (!) replacement;

        // We have authoritative evidence that this is the same continuously
        // present occupant. Demote an already-open PM thread in place instead
        // of letting ConversationManager interpret the privacy change as nick
        // reuse and erase its history.
        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY).get_conversation(
                occupant, account, Conversation.Type.GROUPCHAT_PM);
        if (conversation != null) {
            ((!) conversation).muc_pm_peer_identity = (!) replacement;
        }
    }

    private void forget_room_private_message_real_jids(Account account,
            Jid room) {
        var occupants = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        if (current_pm_peer_identities.has_key(account)) {
            foreach (Jid occupant in current_pm_peer_identities[account].keys) {
                if (occupant.is_full() && occupant.equals_bare(room)) {
                    occupants.add(occupant);
                }
            }
        }
        if (current_pm_peer_identity_aliases.has_key(account)) {
            foreach (Jid occupant in
                    current_pm_peer_identity_aliases[account].keys) {
                if (occupant.is_full() && occupant.equals_bare(room)) {
                    occupants.add(occupant);
                }
            }
        }
        foreach (Jid occupant in occupants) {
            forget_private_message_real_jid(account, occupant);
        }
    }

    private void forget_room_private_message_peer_identities(Account account,
            Jid room) {
        var occupants = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        if (current_pm_peer_identities.has_key(account)) {
            foreach (Jid occupant in current_pm_peer_identities[account].keys) {
                if (occupant.is_full() && occupant.equals_bare(room)) {
                    occupants.add(occupant);
                }
            }
        }
        if (current_pm_peer_identity_aliases.has_key(account)) {
            foreach (Jid occupant in
                    current_pm_peer_identity_aliases[account].keys) {
                if (occupant.is_full() && occupant.equals_bare(room)) {
                    occupants.add(occupant);
                }
            }
        }
        foreach (Jid occupant in occupants) {
            forget_private_message_peer_identity(account, occupant);
        }
    }

    private void bump_room_real_jid_visibility_generation(Account account,
            Jid room) {
        if (!room_real_jid_visibility_generations.has_key(account)) {
            room_real_jid_visibility_generations[account] =
                new HashMap<Jid, uint64?>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        Jid bare = room.bare_jid;
        uint64 current = room_real_jid_visibility_generations[account]
            .has_key(bare)
            ? (!) room_real_jid_visibility_generations[account][bare]
            : 0;
        uint64 next = current + 1;
        if (next == 0) next = 1;
        room_real_jid_visibility_generations[account][bare] = next;
    }

    public uint64 get_room_real_jid_visibility_generation(Account account,
            Jid room) {
        if (!room_real_jid_visibility_generations.has_key(account) ||
                !room_real_jid_visibility_generations[account].has_key(
                    room.bare_jid)) return 0;
        return (!) room_real_jid_visibility_generations[account][room.bare_jid];
    }

    public Xep.Muc.RealJidVisibility get_room_real_jid_visibility(
            Account account, Jid room) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        return flag != null
            ? ((!) flag).get_real_jid_visibility(room.bare_jid)
            : Xep.Muc.RealJidVisibility.UNKNOWN;
    }

    internal void remember_private_message_peer_identity_for_tests(
            Account account, Jid occupant, string identity) {
        remember_private_message_peer_identity(account, occupant, identity);
    }

    internal void forget_private_message_real_jid_for_tests(Account account,
            Jid occupant) {
        forget_private_message_real_jid(account, occupant);
    }

    internal void forget_room_private_message_real_jids_for_tests(
            Account account, Jid room) {
        forget_room_private_message_real_jids(account, room);
    }

    internal void forget_room_private_message_peer_identities_for_tests(
            Account account, Jid room) {
        forget_room_private_message_peer_identities(account, room);
    }

    internal string? get_remembered_private_message_peer_identity_for_tests(
            Account account, Jid occupant) {
        if (!current_pm_peer_identities.has_key(account) ||
                !current_pm_peer_identities[account].has_key(occupant)) {
            return null;
        }
        return current_pm_peer_identities[account][occupant];
    }

    public async void kick_checked(Account account, Jid room, string nick,
            string? reason = null) throws GLib.Error {
        yield change_role_checked(account, room, nick, "none", reason);
    }

    public async void change_role_checked(Account account, Jid room, string nick,
            string role, string? reason = null) throws GLib.Error {
        MucOwnerMutationContext? maybe_context =
            capture_muc_mutation_context(account, room);
        if (maybe_context == null) {
            throw new IOError.NOT_CONNECTED(
                "No current joined room context for account");
        }
        yield change_role_checked_in_context(account, (!) maybe_context, nick,
            role, reason);
    }

    /** Apply a role change only to the room lifecycle captured by its UI. */
    public async void change_role_checked_in_context(Account account,
            MucOwnerMutationContext context, string nick, string role,
            string? reason = null) throws GLib.Error {
        if (nick.strip() == "") throw new IOError.INVALID_ARGUMENT("A live room nickname is required");
        if (role != "none" && role != "visitor" && role != "participant" && role != "moderator") {
            throw new IOError.INVALID_ARGUMENT("Invalid MUC role");
        }
        Jid occupant;
        try {
            occupant = context.room.with_resource(nick);
        } catch (InvalidJidError e) {
            throw new IOError.INVALID_ARGUMENT("Invalid live room nickname");
        }

        if (!is_current_muc_mutation_context(account, context)) {
            throw new IOError.CANCELLED(
                "The joined MUC lifecycle changed before the role change");
        }
        bool authorized = role == "none"
            ? kick_possible(account, occupant)
            : voice_change_possible(account, occupant, role);
        if (!authorized ||
                !is_current_muc_mutation_context(account, context)) {
            throw new IOError.PERMISSION_DENIED(
                "Current MUC role state does not authorize this change");
        }

        yield context.stream.get_module<Xep.Muc.Module>(
            Xep.Muc.Module.IDENTITY).change_role(context.stream,
                context.room, nick, role, reason);

        // The IQ result confirms the server mutation. Request-state consumers
        // can settle now; display membership follows the mandatory updated
        // room presence and the normal live-delta path.
        // If a leave/rejoin raced the IQ result, the old mutation is still
        // applied and must not be reported as a failure. Do not project its
        // confirmation into the replacement room lifecycle, though.
        if (!is_current_muc_mutation_context(account, context)) return;
        Xep.Muc.Role confirmed_role;
        switch (role) {
            case "moderator":
                confirmed_role = Xep.Muc.Role.MODERATOR;
                break;
            case "participant":
                confirmed_role = Xep.Muc.Role.PARTICIPANT;
                break;
            case "visitor":
                confirmed_role = Xep.Muc.Role.VISITOR;
                break;
            case "none":
            default:
                confirmed_role = Xep.Muc.Role.NONE;
                break;
        }
        occupant_role_change_confirmed(account, occupant, confirmed_role);
    }

    public async void set_affiliation_checked(Account account, Jid room,
            Jid target, string affiliation, string? reason = null) throws GLib.Error {
        yield set_affiliation_checked_internal(account, room, target,
            affiliation, reason, true);
    }

    /**
     * Apply an administration-dialog mutation only to the room lifecycle in
     * which that dialog was opened. A same-stream rejoin must not let an old
     * dialog mutate the newly joined room instance.
     */
    public async void set_affiliation_checked_in_context(Account account,
            MucOwnerMutationContext context, Jid target, string affiliation,
            string? reason = null) throws GLib.Error {
        yield set_affiliation_checked_internal(account, context.room, target,
            affiliation, reason, true, context);
    }

    private async void set_affiliation_checked_internal(Account account, Jid room,
            Jid target, string affiliation, string? reason,
            bool invalidate_existing_timed_ban,
            MucOwnerMutationContext? expected_context = null) throws GLib.Error {
        if (target.is_full()) throw new IOError.INVALID_ARGUMENT("A bare JID is required for a MUC affiliation");
        Xep.Muc.Affiliation? requested =
            protocol_affiliation_from_string(affiliation);
        if (requested == null) {
            throw new IOError.INVALID_ARGUMENT("Invalid MUC affiliation");
        }
        Jid bare_target = target.bare_jid;
        if (bare_target.equals_bare(account.bare_jid)) {
            throw new IOError.PERMISSION_DENIED(
                "The current account cannot change its own MUC affiliation");
        }

        MucOwnerMutationContext? maybe_context = expected_context != null
            ? expected_context : capture_muc_mutation_context(account, room);
        if (maybe_context == null) {
            throw new IOError.NOT_CONNECTED(
                "No current joined room context for account");
        }
        MucOwnerMutationContext context = (!) maybe_context;
        if (!context.room.equals_bare(room) ||
                !is_current_muc_mutation_context(account, context)) {
            throw new IOError.CANCELLED(
                "The joined MUC lifecycle changed before the affiliation change");
        }
        Xep.Muc.Affiliation actor_affiliation;
        if (!get_known_current_affiliation(account, context.room,
                context.own_jid, out actor_affiliation)) {
            throw new IOError.PERMISSION_DENIED(
                "Current MUC actor affiliation is unknown");
        }
        Xep.Muc.Affiliation? source_affiliation =
            get_known_affiliation_for_target(account, context.room,
                bare_target);
        if (source_affiliation == null &&
                actor_affiliation == Xep.Muc.Affiliation.OWNER) {
            // Owners may add a brand-new offline JID. They may also alter
            // another owner's affiliation, so an unknown source is safely
            // equivalent to NONE for the owner permission matrix.
            source_affiliation = Xep.Muc.Affiliation.NONE;
        } else if (source_affiliation == null &&
                actor_affiliation == Xep.Muc.Affiliation.ADMIN) {
            // An admin may add offline members/outcasts, but must first prove
            // that an unknown JID is not an owner or admin. Fail closed if
            // either authoritative list cannot be read.
            if (!is_current_muc_mutation_context(account, context)) {
                throw new IOError.CANCELLED(
                    "MUC lifecycle changed before affiliation verification");
            }
            Gee.List<Jid>? owners = yield context.stream.get_module<
                Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                    context.stream, context.room, "owner",
                    () => is_current_muc_mutation_context(account, context));
            if (!is_current_muc_mutation_context(account, context)) {
                throw new IOError.CANCELLED(
                    "MUC lifecycle changed during affiliation verification");
            }
            Gee.List<Jid>? admins = yield context.stream.get_module<
                Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                    context.stream, context.room, "admin",
                    () => is_current_muc_mutation_context(account, context));
            if (!is_current_muc_mutation_context(account, context)) {
                throw new IOError.CANCELLED(
                    "MUC lifecycle changed during affiliation verification");
            }
            if (owners == null || admins == null) {
                throw new IOError.PERMISSION_DENIED(
                    "Could not verify whether the target is a room owner or admin");
            }
            if (jid_list_contains_bare((!) owners, bare_target)) {
                source_affiliation = Xep.Muc.Affiliation.OWNER;
            } else if (jid_list_contains_bare((!) admins, bare_target)) {
                source_affiliation = Xep.Muc.Affiliation.ADMIN;
            } else {
                source_affiliation = Xep.Muc.Affiliation.NONE;
            }
        }
        if (source_affiliation == null ||
                !can_request_affiliation_change(actor_affiliation,
                    source_affiliation, (!) requested) ||
                !is_current_muc_mutation_context(account, context)) {
            throw new IOError.PERMISSION_DENIED(
                "Current MUC affiliation state does not authorize this change");
        }

        yield context.stream.get_module<Xep.Muc.Module>(
            Xep.Muc.Module.IDENTITY).change_affiliation(context.stream,
                context.room, bare_target, null, affiliation, reason);
        // A successful manual affiliation change supersedes any older timed
        // ban for the same room/user.  This also prevents an expired old timer
        // from undoing a newer permanent ban.
        if (invalidate_existing_timed_ban) {
            cancel_timed_ban(timed_ban_key(account, room, target));
        }
    }

    public async void ban_checked(Account account, Jid room, Jid target,
            string? reason = null) throws GLib.Error {
        yield set_affiliation_checked(account, room, target.bare_jid, "outcast", reason);
    }

    public async void ban_for_minutes_checked(Account account, Jid room,
            Jid target, int minutes) throws GLib.Error {
        if (minutes <= 0) throw new IOError.INVALID_ARGUMENT("Timed ban duration must be positive");
        if (minutes > (int.MAX / 60)) throw new IOError.INVALID_ARGUMENT("Timed ban duration is too large");
        yield ban_for_seconds_checked(account, room, target,
            (uint) minutes * 60U, "Banned for %d minutes".printf(minutes));
    }

    private async void ban_for_seconds_checked(Account account, Jid room,
            Jid target, uint duration_seconds, string reason) throws GLib.Error {
        if (duration_seconds == 0) throw new IOError.INVALID_ARGUMENT("Timed ban duration must be positive");
        Jid bare_target = target.bare_jid;
        Xep.Muc.Affiliation? current = get_known_affiliation_for_target(
            account, room, bare_target);
        if (current == null) {
            throw new IOError.PENDING("The current room affiliation is not known yet");
        }
        if (current == Xep.Muc.Affiliation.OUTCAST) {
            throw new IOError.INVALID_ARGUMENT("The user is already banned");
        }
        string restore_affiliation = affiliation_to_protocol_string(current);
        yield ban_checked(account, room, bare_target, reason);

        string key = timed_ban_key(account, room, bare_target);
        cancel_timed_ban(key);
        int64 expires_at = new DateTime.now_utc().to_unix() + duration_seconds;
        PendingTimedBan pending = new PendingTimedBan(account, room, bare_target,
            restore_affiliation, expires_at);
        pending_timed_bans[key] = pending;
        persist_timed_bans(account);
        arm_timed_ban(key, pending, duration_seconds);
    }

    internal async void ban_for_seconds_for_tests(Account account, Jid room,
            Jid target, uint duration_seconds) throws GLib.Error {
        yield ban_for_seconds_checked(account, room, target, duration_seconds,
            "DinoX timed-ban regression test");
    }

    internal bool has_pending_timed_ban_for_tests(Account account, Jid room,
            Jid target) {
        return pending_timed_bans.has_key(timed_ban_key(account, room, target));
    }

    internal async void expire_timed_ban_for_tests(Account account, Jid room,
            Jid target) {
        string key = timed_ban_key(account, room, target);
        if (!pending_timed_bans.has_key(key)) return;
        PendingTimedBan pending = pending_timed_bans[key];
        pending.expires_at = new DateTime.now_utc().to_unix() - 1;
        yield expire_timed_ban(key, pending);
    }

    internal uint timed_ban_retry_count_for_tests(Account account, Jid room,
            Jid target) {
        string key = timed_ban_key(account, room, target);
        return pending_timed_bans.has_key(key)
            ? pending_timed_bans[key].retry_count
            : 0;
    }

    public void kick(Account account, Jid jid, string nick, string? reason = null) {
        kick_checked.begin(account, jid, nick, reason, (_, res) => {
            try {
                kick_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to kick occupant: %s", e.message);
            }
        });
    }

    public void ban(Account account, Jid muc_jid, Jid occupant_jid, string? reason = null) {
        Jid? target = get_affiliation_target(account, muc_jid, occupant_jid);
        if (target == null) {
            warning("Cannot ban occupant without a known bare JID");
            return;
        }
        ban_checked.begin(account, muc_jid, (!) target, reason, (_, res) => {
            try {
                ban_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to ban occupant: %s", e.message);
            }
        });
    }

    public void change_role(Account account, Jid jid, string nick, string role) {
        change_role_checked.begin(account, jid, nick, role, null, (_, res) => {
            try {
                change_role_checked.end(res);
            } catch (GLib.Error e) {
                warning("Failed to change occupant role: %s", e.message);
            }
        });
    }

    public async Gee.List<Jid>? get_affiliations_in_context(Account account,
            MucOwnerMutationContext context, string affiliation) {
        if (!is_current_muc_mutation_context(account, context)) return null;
        Gee.List<Jid>? result = yield context.stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                context.stream, context.room, affiliation,
                () => is_current_muc_mutation_context(account, context));
        if (!is_current_muc_mutation_context(account, context)) return null;
        return result;
    }

    public async Gee.List<Jid>? get_affiliations(Account account, Jid muc_jid,
            string affiliation) {
        MucOwnerMutationContext? context = capture_muc_mutation_context(
            account, muc_jid);
        if (context == null) return null;
        return yield get_affiliations_in_context(account, (!) context,
            affiliation);
    }

    public void set_affiliation(Account account, Jid muc_jid, Jid user_jid, string affiliation) {
        set_affiliation_checked.begin(account, muc_jid, user_jid.bare_jid,
            affiliation, null, (_, res) => {
                try {
                    set_affiliation_checked.end(res);
                } catch (GLib.Error e) {
                    warning("Failed to set occupant affiliation: %s", e.message);
                }
            });
    }

    private static string affiliation_to_protocol_string(Xep.Muc.Affiliation? affiliation) {
        switch (affiliation) {
            case Xep.Muc.Affiliation.MEMBER: return "member";
            case Xep.Muc.Affiliation.ADMIN: return "admin";
            case Xep.Muc.Affiliation.OWNER: return "owner";
            default: return "none";
        }
    }

    private static Xep.Muc.Affiliation? protocol_affiliation_from_string(
            string affiliation) {
        switch (affiliation) {
            case "none": return Xep.Muc.Affiliation.NONE;
            case "member": return Xep.Muc.Affiliation.MEMBER;
            case "admin": return Xep.Muc.Affiliation.ADMIN;
            case "owner": return Xep.Muc.Affiliation.OWNER;
            case "outcast": return Xep.Muc.Affiliation.OUTCAST;
            default: return null;
        }
    }

    private static bool jid_list_contains_bare(Gee.List<Jid> jids,
            Jid target) {
        foreach (Jid jid in jids) {
            if (jid.equals_bare(target)) return true;
        }
        return false;
    }

    private Xep.Muc.Affiliation? get_known_affiliation_for_target(
            Account account, Jid room, Jid target) {
        if (has_affiliation(room, target, account)) {
            return get_affiliation(room, target, account);
        }

        // Live occupant presence carries the authoritative affiliation, but
        // actions address the long-lived affiliation by bare real JID.
        Gee.List<Jid>? occupants = get_occupants(room, account);
        if (occupants == null) return null;
        foreach (Jid occupant in (!) occupants) {
            Jid? real_jid = get_real_jid(occupant, account);
            if (real_jid == null || !((!) real_jid).equals_bare(target) ||
                    !has_affiliation(room, occupant, account)) continue;
            return get_affiliation(room, occupant, account);
        }
        return null;
    }

    private static string timed_ban_key(Account account, Jid room, Jid target) {
        return "%d\x1f%s\x1f%s".printf(account.id,
            room.bare_jid.to_string(), target.bare_jid.to_string());
    }

    private void arm_timed_ban(string key, PendingTimedBan pending, uint delay_seconds) {
        if (pending.source_id != 0) Source.remove(pending.source_id);
        pending.source_id = Timeout.add_seconds(delay_seconds, () => {
            pending.source_id = 0;
            expire_timed_ban.begin(key, pending, (_, res) => {
                expire_timed_ban.end(res);
            });
            return Source.REMOVE;
        });
    }

    private async void expire_timed_ban(string key, PendingTimedBan pending) {
        if (!pending_timed_bans.has_key(key) || pending_timed_bans[key] != pending) return;

        int64 remaining = pending.expires_at - new DateTime.now_utc().to_unix();
        if (remaining > 0) {
            arm_timed_ban(key, pending, (uint) remaining);
            return;
        }

        Xep.Muc.Affiliation? current = get_known_affiliation_for_target(
            pending.account, pending.room, pending.target);
        if (current == null) {
            // Reconnect can leave the affiliation cache temporarily empty.
            // Restoring blindly could undo a newer permanent ban or another
            // owner's change. Keep the persisted operation and retry without
            // sending a mutation IQ until current state is known again.
            pending.retry_count++;
            uint retry_seconds = uint.min(300, 15U * pending.retry_count);
            warning("Cannot verify expired timed MUC ban for %s; retrying in %u seconds without changing affiliation",
                pending.target.to_string(), retry_seconds);
            arm_timed_ban(key, pending, retry_seconds);
            return;
        }
        if (current != Xep.Muc.Affiliation.OUTCAST) {
            pending_timed_bans.unset(key);
            persist_timed_bans(pending.account);
            return;
        }

        try {
            yield set_affiliation_checked_internal(pending.account,
                pending.room, pending.target, pending.restore_affiliation,
                null, false);
            pending_timed_bans.unset(key);
            persist_timed_bans(pending.account);
        } catch (GLib.Error e) {
            // Keep the unban owned by MucManager, not by a stale popover.
            // A temporary disconnect therefore postpones rather than loses it.
            pending.retry_count++;
            uint retry_seconds = uint.min(300, 15U * pending.retry_count);
            warning("Failed to expire timed MUC ban for %s: %s; retrying in %u seconds",
                pending.target.to_string(), e.message, retry_seconds);
            arm_timed_ban(key, pending, retry_seconds);
        }
    }

    private void cancel_timed_ban(string key) {
        if (!pending_timed_bans.has_key(key)) return;
        PendingTimedBan pending = pending_timed_bans[key];
        if (pending.source_id != 0) Source.remove(pending.source_id);
        pending.source_id = 0;
        pending_timed_bans.unset(key);
        persist_timed_bans(pending.account);
    }

    private void detach_timed_bans_for_account(Account account) {
        Gee.List<string> keys = new ArrayList<string>();
        foreach (var entry in pending_timed_bans.entries) {
            if (entry.value.account.equals(account)) keys.add(entry.key);
        }
        foreach (string key in keys) {
            PendingTimedBan pending = pending_timed_bans[key];
            if (pending.source_id != 0) Source.remove(pending.source_id);
            pending.source_id = 0;
            pending_timed_bans.unset(key);
        }
        restored_timed_ban_accounts.remove(account.id);
    }

    private void persist_timed_bans(Account account) {
        if (database == null) return;
        Database db = (!) database;
        StringBuilder serialized = new StringBuilder();
        foreach (PendingTimedBan pending in pending_timed_bans.values) {
            if (!pending.account.equals(account)) continue;
            serialized.append(pending.room.bare_jid.to_string());
            serialized.append_c('\t');
            serialized.append(pending.target.bare_jid.to_string());
            serialized.append_c('\t');
            serialized.append(pending.restore_affiliation);
            serialized.append_c('\t');
            serialized.append_printf("%" + int64.FORMAT, pending.expires_at);
            serialized.append_c('\n');
        }

        if (serialized.len == 0) {
            db.account_settings.delete()
                .with(db.account_settings.account_id, "=", account.id)
                .with(db.account_settings.key, "=", TIMED_BANS_ACCOUNT_SETTING)
                .perform();
            return;
        }
        db.account_settings.upsert()
            .value(db.account_settings.account_id, account.id, true)
            .value(db.account_settings.key, TIMED_BANS_ACCOUNT_SETTING, true)
            .value(db.account_settings.value, serialized.str)
            .perform();
    }

    private void restore_persisted_timed_bans(Account account) {
        if (database == null || restored_timed_ban_accounts.contains(account.id)) return;
        restored_timed_ban_accounts.add(account.id);
        string? serialized = ((!) database).account_settings.get_value(
            account.id, TIMED_BANS_ACCOUNT_SETTING);
        if (serialized == null || ((!) serialized).strip() == "") return;

        foreach (string line in ((!) serialized).split("\n")) {
            if (line == "") continue;
            string[] fields = line.split("\t");
            if (fields.length != 4) {
                warning("Ignoring malformed persisted timed MUC ban");
                continue;
            }
            int64 expires_at = 0;
            if (!int64.try_parse(fields[3], out expires_at)) {
                warning("Ignoring persisted timed MUC ban with invalid expiry");
                continue;
            }
            try {
                Jid room = new Jid(fields[0]).bare_jid;
                Jid target = new Jid(fields[1]).bare_jid;
                string affiliation = fields[2];
                if (affiliation != "none" && affiliation != "member" &&
                        affiliation != "admin" && affiliation != "owner") {
                    warning("Ignoring persisted timed MUC ban with invalid affiliation");
                    continue;
                }
                string key = timed_ban_key(account, room, target);
                PendingTimedBan pending = new PendingTimedBan(account, room,
                    target, affiliation, expires_at);
                pending_timed_bans[key] = pending;
                int64 remaining = expires_at - new DateTime.now_utc().to_unix();
                arm_timed_ban(key, pending, remaining > 0 ? (uint) remaining : 1U);
            } catch (InvalidJidError e) {
                warning("Ignoring persisted timed MUC ban with invalid JID: %s", e.message);
            }
        }
    }

    // Add all current occupants as members to prevent them from being kicked
    // when the room switches to members-only mode
    private async Gee.List<Jid> add_occupants_as_members(Account account,
            Jid muc_jid,
            MucOwnerMutationContext context) throws GLib.Error {
        XmppStream stream = context.stream;
        // Get current members to avoid duplicates
        Gee.List<Jid>? existing_members = yield stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                stream, muc_jid, "member",
                () => is_current_owner_mutation_context(account, context));
        if (!is_current_owner_mutation_context(account, context)) {
            throw new IOError.CANCELLED("MUC Owner context changed during affiliation preflight");
        }
        Gee.List<Jid>? existing_admins = yield stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                stream, muc_jid, "admin",
                () => is_current_owner_mutation_context(account, context));
        if (!is_current_owner_mutation_context(account, context)) {
            throw new IOError.CANCELLED("MUC Owner context changed during affiliation preflight");
        }
        Gee.List<Jid>? existing_owners = yield stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).query_affiliation_guarded(
                stream, muc_jid, "owner",
                () => is_current_owner_mutation_context(account, context));
        if (!is_current_owner_mutation_context(account, context)) {
            throw new IOError.CANCELLED("MUC Owner context changed during affiliation preflight");
        }
        if (existing_members == null || existing_admins == null ||
                existing_owners == null) {
            throw new IOError.FAILED(
                "Could not verify all existing room affiliations");
        }

        var existing_affiliations = new Gee.HashSet<string>();
        foreach (Jid j in (!) existing_members) existing_affiliations.add(j.bare_jid.to_string());
        foreach (Jid j in (!) existing_admins) existing_affiliations.add(j.bare_jid.to_string());
        foreach (Jid j in (!) existing_owners) existing_affiliations.add(j.bare_jid.to_string());
        // Never demote our currently authorized Owner identity even if a
        // broken server omitted it from the affiliation query response.
        Jid? own_real_jid = get_real_jid(context.own_jid, account);
        Jid own_affiliation_jid = own_real_jid != null
            ? ((!) own_real_jid).bare_jid
            : account.bare_jid;
        existing_affiliations.add(own_affiliation_jid.to_string());

        // Get all current occupants
        Gee.List<Jid>? occupants = get_occupants(muc_jid, account);
        var added_members = new ArrayList<Jid>(Jid.equals_bare_func);
        if (occupants == null || occupants.size == 0) {
            throw new IOError.FAILED(
                "Could not verify the current room occupants");
        }

        // Validate the complete live set before sending the first mutation.
        // In a members-only transition, silently skipping one unresolved
        // occupant would make the server remove exactly that person with
        // status 322 once the owner form is accepted.
        var live_real_jids = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Jid occupant_jid in occupants) {
            Jid? real_jid = get_real_jid(occupant_jid, account);
            if (real_jid == null && occupant_jid.equals(context.own_jid)) {
                // Our account identity is authoritative for our current
                // room/nick even when a semi-anonymous room omits item@jid.
                real_jid = account.bare_jid;
            }
            if (real_jid == null) {
                throw new IOError.FAILED(
                    "Could not resolve current occupant %s to a bare JID".printf(
                        occupant_jid.to_string()));
            }
            Jid bare_real_jid = ((!) real_jid).bare_jid;
            if (!live_real_jids.contains(bare_real_jid)) {
                live_real_jids.add(bare_real_jid);
            }
        }

        try {
            foreach (Jid bare_real_jid in live_real_jids) {
                // Skip if already has a persistent affiliation.
                if (existing_affiliations.contains(
                        bare_real_jid.to_string())) continue;

                if (!is_current_owner_mutation_context(account, context)) {
                    throw new IOError.CANCELLED(
                        "MUC Owner context changed before affiliation mutation");
                }
                yield stream.get_module<Xep.Muc.Module>(
                    Xep.Muc.Module.IDENTITY).change_affiliation(stream,
                        muc_jid.bare_jid, bare_real_jid, null, "member");
                added_members.add(bare_real_jid);
            }
        } catch (GLib.Error e) {
            bool rollback_complete = rollback_preflight_members(added_members);
            if (!rollback_complete && added_members.size > 0) {
                throw new MucConfigPreflightError.MEMBERS_PRESERVED(
                    "Affiliation preflight stopped after preserving %d member grant(s): %s".printf(
                        added_members.size, e.message));
            }
            throw e;
        }
        return added_members;
    }

    private bool rollback_preflight_members(Gee.List<Jid> added_members) {
        // XEP-0045 affiliation changes have no compare-and-set token. Once a
        // member grant has succeeded, a later affiliation=none cannot prove
        // that it is undoing our grant rather than a concurrent owner's grant.
        // Preserve the safer membership instead of performing a destructive,
        // ambiguous compensation.
        foreach (Jid added_member in added_members) {
            warning("Preserving preflight membership for %s because XEP-0045 cannot safely compare-and-set a rollback",
                added_member.to_string());
        }
        return added_members.size == 0;
    }

    public string? request_voice(Account account, Jid jid,
            string? correlation_id = null) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        return ((!) stream).get_module<Xep.Muc.Module>(
            Xep.Muc.Module.IDENTITY).request_voice((!) stream,
                jid.bare_jid, correlation_id);
    }

    private static int muc_affiliation_rank(Xep.Muc.Affiliation affiliation) {
        switch (affiliation) {
            case Xep.Muc.Affiliation.OWNER: return 3;
            case Xep.Muc.Affiliation.ADMIN: return 2;
            case Xep.Muc.Affiliation.MEMBER: return 1;
            case Xep.Muc.Affiliation.NONE: return 0;
            default: return -1;
        }
    }

    public static bool can_configure_room_affiliation(
            Xep.Muc.Affiliation? affiliation) {
        return affiliation == Xep.Muc.Affiliation.OWNER;
    }

    public static bool can_administer_room_affiliations(
            Xep.Muc.Affiliation? affiliation) {
        return affiliation == Xep.Muc.Affiliation.OWNER ||
            affiliation == Xep.Muc.Affiliation.ADMIN;
    }

    public static bool can_manage_affiliation_list(
            Xep.Muc.Affiliation? actor_affiliation,
            Xep.Muc.Affiliation list_affiliation) {
        if (actor_affiliation == Xep.Muc.Affiliation.OWNER) {
            return list_affiliation == Xep.Muc.Affiliation.OWNER ||
                list_affiliation == Xep.Muc.Affiliation.ADMIN ||
                list_affiliation == Xep.Muc.Affiliation.MEMBER ||
                list_affiliation == Xep.Muc.Affiliation.OUTCAST;
        }
        return actor_affiliation == Xep.Muc.Affiliation.ADMIN &&
            (list_affiliation == Xep.Muc.Affiliation.MEMBER ||
             list_affiliation == Xep.Muc.Affiliation.OUTCAST);
    }

    public static bool can_request_affiliation_change(
            Xep.Muc.Affiliation? actor_affiliation,
            Xep.Muc.Affiliation? source_affiliation,
            Xep.Muc.Affiliation requested_affiliation) {
        if (actor_affiliation == Xep.Muc.Affiliation.OWNER) {
            return requested_affiliation == Xep.Muc.Affiliation.NONE ||
                requested_affiliation == Xep.Muc.Affiliation.OWNER ||
                requested_affiliation == Xep.Muc.Affiliation.ADMIN ||
                requested_affiliation == Xep.Muc.Affiliation.MEMBER ||
                requested_affiliation == Xep.Muc.Affiliation.OUTCAST;
        }
        if (actor_affiliation != Xep.Muc.Affiliation.ADMIN) return false;

        // XEP-0045 admins may manage members and outcasts, but cannot alter
        // owner/admin affiliations through this path.
        if (source_affiliation == Xep.Muc.Affiliation.OWNER ||
                source_affiliation == Xep.Muc.Affiliation.ADMIN) return false;
        if (requested_affiliation == Xep.Muc.Affiliation.MEMBER ||
                requested_affiliation == Xep.Muc.Affiliation.OUTCAST) {
            return true;
        }
        return requested_affiliation == Xep.Muc.Affiliation.NONE &&
            (source_affiliation == Xep.Muc.Affiliation.MEMBER ||
             source_affiliation == Xep.Muc.Affiliation.OUTCAST);
    }

    private bool get_known_current_affiliation(Account account, Jid room,
            Jid occupant, out Xep.Muc.Affiliation affiliation) {
        affiliation = Xep.Muc.Affiliation.NONE;
        if (!has_affiliation(room, occupant, account)) return false;
        Xep.Muc.Affiliation? value = get_affiliation(room, occupant, account);
        if (value == null) return false;
        affiliation = (!) value;
        return true;
    }

    public bool kick_possible(Account account, Jid occupant) {
        Jid room = occupant.bare_jid;
        if (!is_current_occupant(account, room, occupant)) return false;
        Jid? own_jid = get_own_jid(room, account);
        if (own_jid == null || ((!) own_jid).equals(occupant) ||
                get_role((!) own_jid, account) != Xep.Muc.Role.MODERATOR) return false;

        Xep.Muc.Affiliation actor_affiliation = Xep.Muc.Affiliation.NONE;
        Xep.Muc.Affiliation target_affiliation = Xep.Muc.Affiliation.NONE;
        bool actor_affiliation_known = get_known_current_affiliation(account,
            room, (!) own_jid, out actor_affiliation);
        bool target_affiliation_known = get_known_current_affiliation(account,
            room, occupant, out target_affiliation);
        if (!actor_affiliation_known || !target_affiliation_known) return false;
        if (muc_affiliation_rank(actor_affiliation) <
                muc_affiliation_rank(target_affiliation)) return false;

        Xep.Muc.Role? target_role = get_role(occupant, account);
        if (target_role == Xep.Muc.Role.PARTICIPANT ||
                target_role == Xep.Muc.Role.VISITOR) return true;
        return target_role == Xep.Muc.Role.MODERATOR &&
            (actor_affiliation == Xep.Muc.Affiliation.ADMIN ||
             actor_affiliation == Xep.Muc.Affiliation.OWNER);
    }

    public bool voice_change_possible(Account account, Jid occupant,
            string new_role) {
        Jid room = occupant.bare_jid;
        if (!is_current_occupant(account, room, occupant)) return false;
        Jid? own_jid = get_own_jid(room, account);
        if (own_jid == null || ((!) own_jid).equals(occupant) ||
                get_role((!) own_jid, account) != Xep.Muc.Role.MODERATOR) return false;

        Xep.Muc.Affiliation actor_affiliation = Xep.Muc.Affiliation.NONE;
        Xep.Muc.Affiliation target_affiliation = Xep.Muc.Affiliation.NONE;
        bool actor_affiliation_known = get_known_current_affiliation(account,
            room, (!) own_jid, out actor_affiliation);
        bool target_affiliation_known = get_known_current_affiliation(account,
            room, occupant, out target_affiliation);
        if (!actor_affiliation_known || !target_affiliation_known) return false;
        Xep.Muc.Role? target_role = get_role(occupant, account);

        if (new_role == "participant" && target_role == Xep.Muc.Role.VISITOR) {
            // Granting voice has no affiliation-hierarchy restriction in
            // XEP-0045 Section 8.3. The server still confirms the IQ.
            return true;
        }
        if (new_role == "visitor" && target_role == Xep.Muc.Role.PARTICIPANT) {
            return target_affiliation != Xep.Muc.Affiliation.ADMIN &&
                target_affiliation != Xep.Muc.Affiliation.OWNER &&
                muc_affiliation_rank(actor_affiliation) >
                    muc_affiliation_rank(target_affiliation);
        }
        if (new_role == "moderator" && target_role != Xep.Muc.Role.MODERATOR) {
            return (actor_affiliation == Xep.Muc.Affiliation.ADMIN ||
                    actor_affiliation == Xep.Muc.Affiliation.OWNER) &&
                target_affiliation != Xep.Muc.Affiliation.ADMIN &&
                target_affiliation != Xep.Muc.Affiliation.OWNER;
        }
        if (new_role == "participant" && target_role == Xep.Muc.Role.MODERATOR) {
            return (actor_affiliation == Xep.Muc.Affiliation.ADMIN ||
                    actor_affiliation == Xep.Muc.Affiliation.OWNER) &&
                target_affiliation != Xep.Muc.Affiliation.ADMIN &&
                target_affiliation != Xep.Muc.Affiliation.OWNER;
        }
        return false;
    }

    public bool ban_possible(Account account, Jid occupant) {
        Jid room = occupant.bare_jid;
        if (!is_current_occupant(account, room, occupant)) return false;
        Jid? own_jid = get_own_jid(room, account);
        if (own_jid == null || ((!) own_jid).equals(occupant)) return false;

        Xep.Muc.Affiliation actor_affiliation = Xep.Muc.Affiliation.NONE;
        Xep.Muc.Affiliation target_affiliation = Xep.Muc.Affiliation.NONE;
        bool actor_affiliation_known = get_known_current_affiliation(account,
            room, (!) own_jid, out actor_affiliation);
        bool target_affiliation_known = get_known_current_affiliation(account,
            room, occupant, out target_affiliation);
        if (!actor_affiliation_known || !target_affiliation_known ||
                get_affiliation_target(account, room, occupant) == null) return false;
        if (actor_affiliation == Xep.Muc.Affiliation.OWNER) return true;
        return actor_affiliation == Xep.Muc.Affiliation.ADMIN &&
            (target_affiliation == Xep.Muc.Affiliation.MEMBER ||
             target_affiliation == Xep.Muc.Affiliation.NONE);
    }

    public async void destroy_room(Account account, Jid jid,
            string? reason = null) throws GLib.Error {
        yield destroy_room_detailed(account, jid, reason);
    }

    internal RoomDestructionContext? prepare_administrative_room_destruction(Account account, Jid room) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        string key = muc_occupant_room_key(account.id, room.bare_jid.to_string());
        var context = new RoomDestructionContext();
        context.stream = stream;
        context.room = room.bare_jid;
        context.runtime_generation = get_muc_runtime_generation(account);
        context.room_generation = muc_occupant_room_generations.has_key(key)
            ? (uint?) muc_occupant_room_generations[key] : null;
        context.bookmark_generation = get_current_autojoin_write_generation(account, room.bare_jid);
        context.desired_bookmark = get_desired_manual_bookmark(account, room.bare_jid);
        return context;
    }

    internal void complete_administrative_room_destruction(Account account, RoomDestructionContext context) {
        if (stream_interactor.get_stream(account) != context.stream ||
                get_muc_runtime_generation(account) != context.runtime_generation) return;
        string key = muc_occupant_room_key(account.id, context.room.to_string());
        if (context.room_generation != null) {
            if (!muc_occupant_room_generations.has_key(key) ||
                    muc_occupant_room_generations[key] != (!) context.room_generation) return;
        } else if (muc_occupant_room_generations.has_key(key)) return;
        if (get_current_autojoin_write_generation(account, context.room) != context.bookmark_generation) {
            Conference? desired = get_desired_manual_bookmark(account, context.room);
            if (desired != null && desired != context.desired_bookmark) return;
        }
        commit_room_destruction(account, context.stream, context.room, true, true);
    }

    // A destroyed room is not an ordinary leave. Retire its archive coverage
    // and persist bookmark removal so reconnect cannot recreate it. Local
    // messages and the deletion boundary remain under the user's control.
    private uint commit_room_destruction(Account account, XmppStream stream,
            Jid room, bool send_exit, bool queue_bookmark_removal) {
        Jid bare = room.bare_jid;
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(
            ConversationManager.IDENTITY).get_conversation(bare, account, Conversation.Type.GROUPCHAT);
        // Even an already-left/bookmark-free room can still have old coverage.
        stream_interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY)
            .history_sync.reset_muc_history_coverage(account, bare);
        if (is_permanent_leave_marked(account, bare) && !is_joined(bare, account) &&
                (conversation == null || !((!) conversation).active)) {
            return get_current_autojoin_write_generation(account, bare);
        }
        clear_stale_bookmark_remove_echo_fence(account, bare);
        clear_manual_bookmark_removal_notification(account, bare);
        forget_desired_manual_bookmark(account, bare);
        remove_queued_autojoin_candidate(account, bare);
        cancel_pending_join(account, bare, true);
        mark_permanent_leave(account, bare);
        uint generation = next_autojoin_write_generation(account, bare);
        mark_pending_permanent_bookmark_removal(account, bare);
        remove_joined_muc(account, bare);
        clear_muc_self_ping(account, bare);
        clear_initial_presence_sync(account, bare);
        if (send_exit) {
            stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).exit(stream,
                bare, get_muc_exit_nick(account, bare, conversation));
        }
        if (conversation != null) stream_interactor.get_module<ConversationManager>(
            ConversationManager.IDENTITY).close_conversation((!) conversation);
        if (bookmark_names.has_key(account)) bookmark_names[account].unset(bare);
        remove_bookmarks2_cache_entry(account, bare);
        conference_removed(account, bare);
        if (queue_bookmark_removal) queue_permanent_bookmark_removal(account, stream, bare, generation);
        return generation;
    }

    public async MucDestroyResult destroy_room_detailed(Account account,
            Jid jid, string? reason = null) throws GLib.Error {
        return yield destroy_room_detailed_internal(account, jid, reason,
            null);
    }

    public async MucDestroyResult destroy_room_detailed_in_context(
            Account account, MucOwnerMutationContext context,
            string? reason = null) throws GLib.Error {
        return yield destroy_room_detailed_internal(account, context.room,
            reason, context);
    }

    private async MucDestroyResult destroy_room_detailed_internal(
            Account account, Jid jid, string? reason,
            MucOwnerMutationContext? expected_context) throws GLib.Error {
        Jid bare = jid.bare_jid;
        MucOwnerMutationContext? maybe_context = expected_context != null
            ? expected_context
            : capture_owner_mutation_context(account, bare);
        if (maybe_context == null) {
            throw new GLib.IOError.PERMISSION_DENIED(
                "A current joined room Owner context is required");
        }
        MucOwnerMutationContext context = (!) maybe_context;
        if (!context.room.equals_bare(bare)) {
            throw new GLib.IOError.CANCELLED(
                "Room Owner context does not belong to this room");
        }
        XmppStream stream = context.stream;
        Conference? desired_bookmark_before_destroy =
            get_desired_manual_bookmark(account, bare);
        uint state_generation_before_destroy =
            get_current_autojoin_write_generation(account, bare);
        debug("destroy_room: Starting for %s", bare.to_string());
        if (!is_current_owner_mutation_context(account, context)) {
            throw new GLib.IOError.PERMISSION_DENIED(
                "Room Owner context changed before destruction");
        }

        // The server transaction comes first. Until its result is confirmed,
        // bookmarks, autojoin state, leave markers, joins and conversations are
        // left untouched so an IQ rejection needs no local rollback.
        debug("destroy_room: Sending destroy IQ for %s", bare.to_string());
        yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).destroy_room(stream, bare, reason, null);
        debug("destroy_room: Destroy IQ succeeded for %s", bare.to_string());

        // The confirmed server result belongs to the frozen stream/join only.
        // A reconnect or same-stream rejoin may already own a newly-created
        // room with the same address and must remain untouched.
        if (!is_current_owner_mutation_lifecycle(account, context)) {
            debug("destroy_room: Keeping newer stream/join state for %s after confirmed destroy",
                bare.to_string());
            return MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING;
        }

        // Preserve a new explicit add-bookmark intent. Generation changes
        // caused only by part()/remove-bookmark do not retain a new desired
        // bookmark and must not leave the destroyed room bookmarked.
        if (get_current_autojoin_write_generation(account, bare) !=
                state_generation_before_destroy) {
            Conference? current_desired = get_desired_manual_bookmark(account,
                bare);
            if (current_desired != null &&
                    current_desired != desired_bookmark_before_destroy) {
                debug("destroy_room: Keeping newer bookmark intent for %s after confirmed destroy",
                    bare.to_string());
                return MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING;
            }
        }

        // Commit teardown without another yield. This continuation still owns
        // the frozen stream/join, so it can never close a replacement join that
        // appears while bookmark removal is in flight.
        uint generation = commit_room_destruction(account, stream, bare, true, false);
        // The server may have sent the destruction presence before the IQ
        // result. Its identical teardown can already have removed the bookmark.
        if (!is_pending_permanent_bookmark_removal(account, bare)) return MucDestroyResult.APPLIED;

        bool bookmark_sync_ok = true;
        string? bookmark_sync_error = null;
        XmppStream? bookmark_stream = stream_interactor.get_stream(account);
        if (bookmark_stream == null || !bookmarks_provider.has_key(account)) {
            bookmark_sync_ok = false;
            bookmark_sync_error = "No active bookmark backend after room destruction";
        } else {
            XmppStream active_bookmark_stream = (!) bookmark_stream;
            debug("destroy_room: Removing bookmark for %s after confirmed destroy",
                bare.to_string());
            bool removed = yield queue_permanent_bookmark_removal_and_wait(
                account, active_bookmark_stream, bare, generation);

            if (!is_permanent_leave_marked(account, bare) ||
                    !is_current_autojoin_write_generation(account, bare,
                        generation)) {
                return MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING;
            }

            if (!removed) {
                bookmark_sync_ok = false;
                bookmark_sync_error =
                    "Server rejected bookmark removal after room destruction";
            } else {
                debug("destroy_room: Bookmark removal confirmed for %s",
                    bare.to_string());
            }
        }

        // A replacement stream/join can appear while bookmark removal yields.
        // Its local bookmark projection belongs to that newer lifecycle.
        if (is_current_owner_mutation_lifecycle(account, context)) {
            if (bookmark_names.has_key(account)) {
                bookmark_names[account].unset(bare);
            }
            XmppStream? current_stream = stream_interactor.get_stream(account);
            if (current_stream != null) {
                Xep.Bookmarks2.Flag? bm_flag = ((!) current_stream).get_flag(
                    Xep.Bookmarks2.Flag.IDENTITY);
                if (bm_flag != null) ((!) bm_flag).conferences.unset(bare);
            }
        }

        if (!bookmark_sync_ok) {
            warning("destroy_room: %s for %s",
                bookmark_sync_error ?? "Bookmark synchronization failed",
                bare.to_string());
            return MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING;
        }

        debug("destroy_room: Complete for %s", bare.to_string());
        return MucDestroyResult.APPLIED;
    }

    //the term `private room` is a short hand for members-only+non-anonymous rooms
    public bool is_private_room(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (flag == null || ((!) flag).get_real_jid_visibility(jid) !=
                    Xep.Muc.RealJidVisibility.ANYONE) return false;
            if (((!) flag).knows_room_features(jid)) {
                return flag.has_room_feature(jid, Xep.Muc.Feature.MEMBERS_ONLY) &&
                        flag.has_room_feature(jid, Xep.Muc.Feature.NON_ANONYMOUS);
            }
            return false;
        }

        var entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        return entity_info.has_feature_offline(account, jid, "muc_membersonly") && entity_info.has_feature_offline(account, jid, "muc_nonanonymous");
    }

    public bool has_live_private_room_features(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null ||
                !((!) flag).has_current_room_features(jid)) return false;

        return ((!) flag).has_room_feature(jid, Xep.Muc.Feature.MEMBERS_ONLY) &&
            ((!) flag).has_room_feature(jid, Xep.Muc.Feature.NON_ANONYMOUS) &&
            ((!) flag).get_real_jid_visibility(jid) ==
                Xep.Muc.RealJidVisibility.ANYONE;
    }

    internal bool has_current_room_features(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        Xep.Muc.Flag? flag = ((!) stream).get_flag(Xep.Muc.Flag.IDENTITY);
        return flag != null && ((!) flag).has_current_room_features(jid);
    }

    public bool has_complete_private_muc_affiliation_snapshot(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null || !has_live_private_room_features(account, jid)) return false;

        return ((!) flag).has_complete_member_affiliation_snapshot(jid);
    }

    public Gee.List<Jid>? get_private_muc_member_affiliation_snapshot(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;

        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null || !has_live_private_room_features(account, jid)) return null;

        return ((!) flag).get_complete_member_affiliation_snapshot(jid);
    }

    public uint get_private_muc_affiliation_snapshot_revision(Account account,
            Jid jid) {
        Jid bare = jid.bare_jid;
        return private_muc_snapshot_revisions.has_key(account) &&
            private_muc_snapshot_revisions[account].has_key(bare)
            ? private_muc_snapshot_revisions[account][bare] : 0;
    }

    private uint ensure_private_muc_affiliation_snapshot_revision(
            Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        uint current = get_private_muc_affiliation_snapshot_revision(account,
            bare);
        if (current != 0) return current;
        if (!private_muc_snapshot_revisions.has_key(account)) {
            private_muc_snapshot_revisions[account] =
                new HashMap<Jid, uint>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        private_muc_snapshot_revisions[account][bare] = 1;
        return 1;
    }

    private uint advance_private_muc_affiliation_snapshot_revision(
            Account account, Jid jid) {
        Jid bare = jid.bare_jid;
        if (!private_muc_snapshot_revisions.has_key(account)) {
            private_muc_snapshot_revisions[account] =
                new HashMap<Jid, uint>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        uint next = get_private_muc_affiliation_snapshot_revision(account,
            bare) + 1;
        if (next == 0) next = 1;
        private_muc_snapshot_revisions[account][bare] = next;
        return next;
    }

    private static string private_muc_member_snapshot_fingerprint(
            Gee.Collection<Jid> members) {
        var normalized = new ArrayList<string>();
        var seen = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        foreach (Jid member in members) {
            Jid bare = member.bare_jid;
            if (seen.add(bare)) normalized.add(bare.to_string());
        }
        normalized.sort((left, right) => left.collate(right));
        var fingerprint = new StringBuilder();
        foreach (string member in normalized) {
            fingerprint.append_printf("%u:%s;", member.length, member);
        }
        return fingerprint.str;
    }

    private void publish_private_muc_affiliation_snapshot_change(
            Account account, Jid room) {
        Jid bare = room.bare_jid;
        if (!has_live_private_room_features(account, bare) ||
                !has_complete_private_muc_affiliation_snapshot(account,
                    bare)) return;
        Gee.List<Jid>? members =
            get_private_muc_member_affiliation_snapshot(account, bare);
        if (members == null) return;

        string fingerprint = private_muc_member_snapshot_fingerprint(
            (!) members);
        string? previous = null;
        if (private_muc_snapshot_fingerprints.has_key(account) &&
                private_muc_snapshot_fingerprints[account].has_key(bare)) {
            previous = private_muc_snapshot_fingerprints[account][bare];
        }
        if (previous != null && (!) previous == fingerprint) return;

        if (!private_muc_snapshot_fingerprints.has_key(account)) {
            private_muc_snapshot_fingerprints[account] =
                new HashMap<Jid, string>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        private_muc_snapshot_fingerprints[account][bare] = fingerprint;
        uint revision = previous == null
            ? ensure_private_muc_affiliation_snapshot_revision(account, bare)
            : advance_private_muc_affiliation_snapshot_revision(account, bare);
        private_muc_affiliation_snapshot_changed(account, bare, revision);
    }

    private void resume_unsent_muc_messages_for_private_snapshot(
            Account account, Jid room, uint revision) {
        Jid bare = room.bare_jid;
        MucOwnerMutationContext? maybe_context =
            capture_muc_mutation_context(account, bare);
        if (maybe_context == null) return;
        MucOwnerMutationContext context = (!) maybe_context;
        if (!is_current_private_muc_snapshot_context(account, context) ||
                !has_live_private_room_features(account, bare) ||
                !has_complete_private_muc_affiliation_snapshot(account,
                    bare) ||
                get_private_muc_affiliation_snapshot_revision(account,
                    bare) != revision) return;

        if (private_muc_unsent_resumes_in_flight.has_key(account) &&
                private_muc_unsent_resumes_in_flight[account].contains(
                    bare)) return;
        if (!private_muc_unsent_resumes_in_flight.has_key(account)) {
            private_muc_unsent_resumes_in_flight[account] =
                new HashSet<Jid>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        // Mark before entering MessageProcessor: synchronous pipeline
        // callbacks may re-enter MUC state and must not dispatch the same
        // persisted row twice. This is deliberately only an in-flight guard:
        // a later stream resume in the same snapshot revision must still be
        // able to retry rows that became UNSENT after this dispatch.
        private_muc_unsent_resumes_in_flight[account].add(bare);
        stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).send_unsent_muc_messages(account,
                bare);
        if (private_muc_unsent_resumes_in_flight.has_key(account)) {
            private_muc_unsent_resumes_in_flight[account].remove(bare);
            if (private_muc_unsent_resumes_in_flight[account].is_empty) {
                private_muc_unsent_resumes_in_flight.unset(account);
            }
        }
    }

    private void clear_private_muc_snapshot_fingerprint(Account account,
            Jid room) {
        if (!private_muc_snapshot_fingerprints.has_key(account)) return;
        private_muc_snapshot_fingerprints[account].unset(room.bare_jid);
        if (private_muc_snapshot_fingerprints[account].is_empty) {
            private_muc_snapshot_fingerprints.unset(account);
        }
    }

    public bool has_pending_muc_room_info(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;
        Xep.Muc.Flag? flag = ((!) stream).get_flag(
            Xep.Muc.Flag.IDENTITY);
        return flag != null &&
            ((!) flag).has_pending_room_info_query(jid.bare_jid);
    }

    /**
     * Wait for the current room-info query without starting or superseding it.
     *
     * MUC enter starts disco and presence in parallel. Historical messages can
     * therefore reach the message pipeline after self-presence but before the
     * disco result has established whether the room is private. Security-
     * sensitive consumers join that exact query flight through this method.
     */
    public async bool wait_for_pending_muc_room_info(Account account,
            Jid room) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return false;

        Jid bare = room.bare_jid;
        Xep.Muc.Flag? flag = ((!) stream).get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null) return false;
        if (((!) flag).has_current_room_features(bare)) return true;
        if (!((!) flag).has_pending_room_info_query(bare)) return false;

        if (!pending_muc_room_info_waiters.has_key(account)) {
            pending_muc_room_info_waiters[account] =
                new HashMap<Jid, ArrayList<PendingMucRoomInfoWaiter>>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (!pending_muc_room_info_waiters[account].has_key(bare)) {
            pending_muc_room_info_waiters[account][bare] =
                new ArrayList<PendingMucRoomInfoWaiter>();
        }

        var waiter = new PendingMucRoomInfoWaiter(
            wait_for_pending_muc_room_info.callback);
        pending_muc_room_info_waiters[account][bare].add(waiter);
        yield;

        return waiter.result &&
            stream_interactor.get_stream(account) == stream &&
            has_current_room_features(account, bare);
    }

    private void complete_pending_muc_room_info_waiters(Account account,
            Jid room, bool succeeded) {
        Jid bare = room.bare_jid;
        if (!pending_muc_room_info_waiters.has_key(account) ||
                !pending_muc_room_info_waiters[account].has_key(bare)) {
            return;
        }

        var waiters = new ArrayList<PendingMucRoomInfoWaiter>();
        waiters.add_all(pending_muc_room_info_waiters[account][bare]);
        pending_muc_room_info_waiters[account].unset(bare);
        if (pending_muc_room_info_waiters[account].is_empty) {
            pending_muc_room_info_waiters.unset(account);
        }
        foreach (PendingMucRoomInfoWaiter waiter in waiters) {
            waiter.complete(succeeded);
        }
    }

    private void complete_all_pending_muc_room_info_waiters(Account account) {
        if (!pending_muc_room_info_waiters.has_key(account)) return;

        var waiters = new ArrayList<PendingMucRoomInfoWaiter>();
        foreach (ArrayList<PendingMucRoomInfoWaiter> room_waiters in
                pending_muc_room_info_waiters[account].values) {
            waiters.add_all(room_waiters);
        }
        pending_muc_room_info_waiters.unset(account);
        foreach (PendingMucRoomInfoWaiter waiter in waiters) {
            waiter.complete(false);
        }
    }

    private bool is_current_private_muc_snapshot_context(Account account,
            MucOwnerMutationContext context) {
        return is_current_muc_mutation_context(account, context) &&
            is_joined(context.room, account);
    }

    private bool has_pending_private_muc_snapshot(Account account,
            Jid room) {
        return pending_private_muc_snapshots.has_key(account) &&
            pending_private_muc_snapshots[account].has_key(room.bare_jid);
    }

    private bool is_current_private_muc_snapshot_operation(Account account,
            MucOwnerMutationContext context,
            PendingPrivateMucSnapshot pending) {
        Jid bare = context.room.bare_jid;
        return pending_private_muc_snapshots.has_key(account) &&
            pending_private_muc_snapshots[account].has_key(bare) &&
            pending_private_muc_snapshots[account][bare] == pending &&
            is_current_private_muc_snapshot_context(account, context);
    }

    private bool may_commit_private_muc_snapshot_operation(Account account,
            MucOwnerMutationContext context,
            PendingPrivateMucSnapshot pending) {
        return is_current_private_muc_snapshot_operation(account, context,
                pending) &&
            has_live_private_room_features(account, context.room);
    }

    private async Gee.List<Jid>? query_private_muc_affiliation_snapshot_in_context(
            Account account, MucOwnerMutationContext context,
            PendingPrivateMucSnapshot pending) {
        if (!is_current_private_muc_snapshot_operation(account, context,
                pending)) {
            return null;
        }

        Xep.Muc.Module? muc_module = context.stream.get_module<
            Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        if (muc_module == null) return null;
        if (!may_commit_private_muc_snapshot_operation(account, context,
                pending)) {
            return null;
        }

        bool complete = yield ((!) muc_module)
            .query_member_affiliation_snapshot_guarded(context.stream,
                context.room, pending.force_refresh, () => {
                    return may_commit_private_muc_snapshot_operation(account,
                        context, pending);
                });
        if (!complete ||
                !may_commit_private_muc_snapshot_operation(account,
                    context, pending)) return null;

        if (!has_complete_private_muc_affiliation_snapshot(account,
                context.room)) return null;
        return get_private_muc_member_affiliation_snapshot(account,
            context.room);
    }

    private PendingPrivateMucSnapshot begin_private_muc_snapshot_operation(
            Account account, MucOwnerMutationContext context,
            bool force_refresh = false) {
        Jid bare = context.room.bare_jid;
        if (!private_muc_snapshot_revisions.has_key(account)) {
            private_muc_snapshot_revisions[account] =
                new HashMap<Jid, uint>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        uint current_revision =
            get_private_muc_affiliation_snapshot_revision(account, bare);
        if (force_refresh || current_revision == 0) {
            uint next = current_revision + 1;
            if (next == 0) next = 1;
            private_muc_snapshot_revisions[account][bare] = next;
        }
        if (!pending_private_muc_snapshots.has_key(account)) {
            pending_private_muc_snapshots[account] =
                new HashMap<Jid, PendingPrivateMucSnapshot>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        var pending = new PendingPrivateMucSnapshot(context, force_refresh);
        pending_private_muc_snapshots[account][bare] = pending;
        run_private_muc_snapshot_operation.begin(account, context, pending);
        return pending;
    }

    private async void run_private_muc_snapshot_operation(Account account,
            MucOwnerMutationContext context,
            PendingPrivateMucSnapshot pending) {
        Jid bare = context.room.bare_jid;
        Gee.List<Jid>? result = yield
            query_private_muc_affiliation_snapshot_in_context(account,
                context, pending);
        bool request_still_current =
            pending_private_muc_snapshots.has_key(account) &&
            pending_private_muc_snapshots[account].has_key(bare) &&
            pending_private_muc_snapshots[account][bare] == pending;
        if (!request_still_current) {
            result = null;
        } else if (result != null) {
            // The XMPP flag now owns the successful complete snapshot. Remove
            // this wrapper before resuming waiters so later callers use the
            // cache instead of a completed operation object.
            pending_private_muc_snapshots[account].unset(bare);
            if (pending_private_muc_snapshots[account].is_empty) {
                pending_private_muc_snapshots.unset(account);
            }
            publish_private_muc_affiliation_snapshot_change(account, bare);
            // Wake the encrypted outbox for every successful authoritative
            // operation, even when a forced retry proves the same member set
            // and therefore emits no UI snapshot-change signal.
            resume_unsent_muc_messages_for_private_snapshot(account, bare,
                get_private_muc_affiliation_snapshot_revision(account,
                    bare));
        }
        // A current failure remains in the map as the authoritative result
        // until an explicit readiness request replaces it with one forced
        // retry. This prevents automatic callers from spinning new triplets.
        pending.complete(result);
    }

    public async Gee.List<Jid>? query_private_muc_affiliation_snapshot(Account account, Jid muc_jid) {
        Jid bare = muc_jid.bare_jid;
        MucOwnerMutationContext? maybe_context =
            capture_muc_mutation_context(account, bare);
        if (maybe_context == null || !is_joined(bare, account)) return null;
        MucOwnerMutationContext context = (!) maybe_context;

        if (has_complete_private_muc_affiliation_snapshot(account, bare)) {
            publish_private_muc_affiliation_snapshot_change(account, bare);
            return get_private_muc_member_affiliation_snapshot(account,
                bare);
        }

        // Do not register an affiliation operation until a current room-info
        // response has established the private-room precondition. The
        // low-level room-info hook starts the authoritative operation first;
        // this caller then joins that exact flight.
        if (!has_private_muc_room_info_ready(account, bare) ||
                !has_live_private_room_features(account, bare)) {
            Xep.Muc.Module? module = context.stream.get_module<
                Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
            Xep.Muc.Flag? flag = context.stream.get_flag(
                Xep.Muc.Flag.IDENTITY);
            if (flag != null &&
                    ((!) flag).has_pending_room_info_query(bare)) {
                // enter() owns the current room-info request. Do not
                // supersede it from an early UI activation; its completion
                // signal will retry readiness against that exact result.
                return null;
            }
            if (has_failed_muc_room_info(account, bare)) {
                // A settled failure is terminal for this automatic readiness
                // pass. Do not turn the UI recheck into an unbounded disco
                // retry loop; a later explicit room-info refresh or rejoin
                // clears/replaces this state.
                return null;
            }
            if (module == null ||
                    !(yield ((!) module).query_room_info(context.stream,
                        bare)) ||
                    !is_current_private_muc_snapshot_context(account,
                        context) ||
                    !has_live_private_room_features(account, bare)) {
                return null;
            }
        }

        if (has_pending_private_muc_snapshot(account, bare)) {
            PendingPrivateMucSnapshot existing =
                pending_private_muc_snapshots[account][bare];
            if (is_current_private_muc_snapshot_context(account,
                    existing.context)) {
                return yield existing.wait_for_result();
            }
            cancel_private_muc_snapshot_request(account, bare);
        }

        PendingPrivateMucSnapshot pending =
            begin_private_muc_snapshot_operation(account, context);
        return yield pending.wait_for_result();
    }

    public async Gee.List<Jid>? ensure_private_muc_affiliation_snapshot(
            Account account, Jid muc_jid) {
        if (has_complete_private_muc_affiliation_snapshot(account,
                muc_jid)) {
            publish_private_muc_affiliation_snapshot_change(account,
                muc_jid);
            return get_private_muc_member_affiliation_snapshot(account,
                muc_jid);
        }

        if (!has_pending_private_muc_snapshot(account, muc_jid)) {
            // This may attach to the initial join flight, but never turns its
            // failure into an automatic retry in the same continuation.
            return yield query_private_muc_affiliation_snapshot(account,
                muc_jid);
        }

        Jid bare = muc_jid.bare_jid;
        PendingPrivateMucSnapshot pending =
            pending_private_muc_snapshots[account][bare];
        if (!pending.is_completed()) {
            return yield pending.wait_for_result();
        }
        if (pending.has_succeeded()) {
            return yield pending.wait_for_result();
        }
        if (!is_current_private_muc_snapshot_context(account,
                pending.context) ||
                !has_live_private_room_features(account, bare)) {
            return null;
        }

        // Replace the stable failed result synchronously before yielding.
        // A second caller therefore observes and coalesces with this one
        // forced retry instead of launching a second triplet.
        MucOwnerMutationContext context = pending.context;
        cancel_private_muc_snapshot_request(account, bare);
        PendingPrivateMucSnapshot retry =
            begin_private_muc_snapshot_operation(account, context, true);
        return yield retry.wait_for_result();
    }

    private void handle_private_muc_room_info_updated(Account account,
            Jid room, bool force_refresh) {
        Jid bare = room.bare_jid;
        if (!has_live_private_room_features(account, bare)) {
            // A response proving that the room is no longer private
            // supersedes every affiliation query that was authorized by the
            // previous room state. Its operation guard prevents a late IQ
            // from committing after this cancellation.
            cancel_private_muc_snapshot_request(account, bare);
            clear_private_muc_snapshot_fingerprint(account, bare);
            return;
        }
        // A self-presence can make the XMPP flag look joined before
        // activate_joined_conversation() has installed the Dino lifecycle.
        // Wait for that activation; its deferred resend/ensure path will
        // start the snapshot if this signal arrived first.
        if (!mucs_joined.has_key(account) ||
                !mucs_joined[account].contains(bare)) return;

        // The first room-info result joins the three affiliation IQs already
        // started by self-presence. Any later explicit room-info result is a
        // configuration boundary and must supersede that older operation.
        cancel_private_muc_snapshot_request(account, bare);
        MucOwnerMutationContext? context = capture_muc_mutation_context(
            account, bare);
        if (context == null ||
                !is_current_private_muc_snapshot_context(account,
                    (!) context)) return;
        begin_private_muc_snapshot_operation(account, (!) context,
            force_refresh);
    }

    private async void resume_unsent_muc_messages_after_join(Account account,
            Jid room) {
        // Let the room-info continuation that accompanied the join register
        // its affiliation refresh before the resend path consults it. This
        // also avoids racing the low-level room-info signal reentrantly.
        SourceFunc resume = resume_unsent_muc_messages_after_join.callback;
        Idle.add((owned) resume);
        yield;

        MucOwnerMutationContext? maybe_context =
            capture_muc_mutation_context(account, room);
        if (maybe_context == null) return;
        MucOwnerMutationContext context = (!) maybe_context;
        Xep.Muc.Flag? flag = context.stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null) return;

        if (!has_private_muc_room_info_ready(account, context.room) ||
                !((!) flag).has_current_room_features(context.room)) {
            // enter() already owns the one authoritative room-info query.
            // Do not race it with a duplicate disco request. Preserve the
            // historical immediate resend only for plaintext rows; every
            // encrypted row remains UNSENT until room-info and any required
            // recipient proof are available. Persisted rows can contain a mix
            // independent of the conversation's current encryption mode.
            stream_interactor.get_module<MessageProcessor>(
                MessageProcessor.IDENTITY).send_unsent_plaintext_muc_messages(
                    account, context.room);
            return;
        }

        if (has_live_private_room_features(account, context.room)) {
            Gee.List<Jid>? members = yield
                query_private_muc_affiliation_snapshot(account,
                    context.room);
            if (members == null ||
                    !is_current_muc_mutation_context(account, context)) {
                return;
            }
            resume_unsent_muc_messages_for_private_snapshot(account,
                context.room,
                get_private_muc_affiliation_snapshot_revision(account,
                    context.room));
            return;
        }
        if (!is_current_muc_mutation_context(account, context)) return;
        stream_interactor.get_module<MessageProcessor>(
            MessageProcessor.IDENTITY).send_unsent_muc_messages(account,
                context.room);
    }

    public bool is_moderated_room(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) {
            return false;
        }
        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (flag == null) {
            return false;
        }
        return flag.has_room_feature(jid, Xep.Muc.Feature.MODERATED);
    }

    public bool is_public_room(Account account, Jid jid) {
        return is_groupchat(jid, account) && !is_private_room(account, jid);
    }

    public Gee.List<Jid>? get_occupants(Jid jid, Account account) {
        if (is_groupchat(jid, account)) {
            Gee.List<Jid> ret = new ArrayList<Jid>(Jid.equals_func);
            Gee.List<Jid>? full_jids = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(jid, account);
            if (full_jids != null) {
                ret.add_all(full_jids);
                // Remove eventual presence from bare jid
                ret.remove(jid);
            }
            return ret;
        }
        return null;
    }

    public Gee.List<Jid>? get_other_occupants(Jid jid, Account account) {
        Gee.List<Jid>? occupants = get_occupants(jid, account);
        Jid? own_jid = get_own_jid(jid, account);
        if (occupants != null && own_jid != null) {
            occupants.remove(own_jid);
        }
        return occupants;
    }

    public bool is_groupchat(Jid jid, Account account) {
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(jid, account, Conversation.Type.GROUPCHAT);
        return !jid.is_full() && conversation != null;
    }

    public bool might_be_groupchat(Jid jid, Account account) {
        if (mucs_joining.has_key(account) && mucs_joining[account].contains(jid)) return true;
        return is_groupchat(jid, account);
    }

    public bool is_groupchat_occupant(Jid jid, Account account) {
        return is_groupchat(jid.bare_jid, account) && jid.resourcepart != null;
    }

    public async Set<Conference>? get_bookmarks(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !bookmarks_provider.has_key(account)) return null;

        Set<Conference>? conferences = yield bookmarks_provider[account].get_conferences(stream);
        if (conferences == null) return null;
        return filter_manually_removed_conferences(account, conferences);
    }

    public async bool add_bookmark(Account account, Conference conference) {
        clear_leave_marker(account, conference.jid);
        clear_permanent_leave_marker(account, conference.jid);
        clear_pending_permanent_bookmark_removal(account, conference.jid);
        clear_manually_removed_bookmark(account, conference.jid);
        clear_manual_bookmark_removal_notification(account, conference.jid);
        remember_desired_manual_bookmark(account, conference);
        uint generation = next_autojoin_write_generation(account,
            conference.jid);
        retarget_stale_bookmark_remove_echo_fence(account, conference.jid,
            generation);
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !bookmarks_provider.has_key(account)) {
            forget_desired_manual_bookmark(account, conference.jid);
            return false;
        }
        BookmarksProvider provider = bookmarks_provider[account];
        bool ok = yield provider.add_conference(stream, conference);
        if (stream_interactor.get_stream(account) != stream ||
                !is_current_bookmark_provider(account, provider)) {
            if (stream_interactor.get_stream(account) == stream &&
                    is_current_autojoin_write_generation(account,
                        conference.jid, generation)) {
                requeue_current_bookmark_intent(account, stream,
                    conference.jid);
            }
            return false;
        }
        if (!is_current_autojoin_write_generation(account, conference.jid,
                generation)) return false;
        if (!ok) {
            forget_desired_manual_bookmark(account, conference.jid);
            warning("Failed to add MUC bookmark for %s during manual-add-bookmark", ((!) conference.jid).to_string());
            return false;
        }
        conference_added(account, conference);
        return true;
    }

    public async bool remove_bookmark(Account account, Conference conference) {
        if (conference.jid == null) return false;
        Jid bare = ((!) conference.jid).bare_jid;
        clear_stale_bookmark_remove_echo_fence(account, bare);
        clear_manual_bookmark_removal_notification(account, bare);
        forget_desired_manual_bookmark(account, bare);
        mark_manually_removed_bookmark(account, bare);
        remove_queued_autojoin_candidate(account, bare);
        cancel_pending_join(account, bare, true);
        uint generation = next_autojoin_write_generation(account, bare);
        AutojoinBookmarkWrite remove_write = new AutojoinBookmarkWrite(false,
            null, null, true, generation, 0, true);
        track_active_manual_bookmark_removal(account, bare, remove_write);
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !bookmarks_provider.has_key(account)) {
            clear_active_manual_bookmark_removal(account, bare, remove_write);
            clear_manually_removed_bookmark(account, bare);
            clear_manual_bookmark_removal_notification(account, bare);
            return false;
        }

        BookmarksProvider provider = bookmarks_provider[account];
        Conference remove_conference = new Conference() { jid=bare };
        bool ok = yield provider.remove_conference(stream, remove_conference);
        if (stream_interactor.get_stream(account) != stream ||
                !is_current_bookmark_provider(account, provider)) {
            clear_active_manual_bookmark_removal(account, bare, remove_write);
            if (ok && stream_interactor.get_stream(account) == stream &&
                    !is_current_autojoin_write_generation(account, bare,
                        generation)) {
                if (!remove_write.remove_echo_seen) {
                    set_stale_bookmark_remove_echo_fence(account, bare,
                        generation);
                }
                requeue_current_bookmark_intent(account, stream, bare);
            } else if (is_current_autojoin_write_generation(account, bare,
                    generation)) {
                clear_manually_removed_bookmark(account, bare);
            }
            return false;
        }
        if (!is_current_autojoin_write_generation(account, bare,
                generation)) {
            clear_active_manual_bookmark_removal(account, bare, remove_write);
            if (ok) {
                if (!remove_write.remove_echo_seen) {
                    set_stale_bookmark_remove_echo_fence(account, bare,
                        generation);
                }
                requeue_current_bookmark_intent(account, stream, bare);
            }
            return false;
        }
        if (!ok) {
            clear_active_manual_bookmark_removal(account, bare, remove_write);
            clear_manually_removed_bookmark(account, bare);
            warning("Failed to remove MUC bookmark for %s during manual-remove-bookmark", bare.to_string());
            return false;
        }

        if (!remove_write.remove_echo_seen) {
            remember_pending_bookmark_remove_echo(account, bare,
                remove_write);
        }
        clear_active_manual_bookmark_removal(account, bare, remove_write);
        if (bookmark_names.has_key(account)) {
            bookmark_names[account].unset(bare);
        }
        remove_bookmarks2_cache_entry(account, bare);
        if (mark_manual_bookmark_removal_notification(account, bare)) {
            conference_removed(account, bare);
        }
        return true;
    }

    public string? get_room_name(Account account, Jid jid) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_room_name(jid);
        }
        return null;
    }

    public string? get_bookmark_name(Account account, Jid jid) {
        if (bookmark_names.has_key(account)) {
            return bookmark_names[account].get(jid);
        }
        return null;
    }

    public string? get_groupchat_subject(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_muc_subject(jid.bare_jid);
        }
        return null;
    }

    public Jid? get_real_jid(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_real_jid(jid);
        }
        return null;
    }

    public Jid? get_occupant_jid(Account account, Jid room, Jid occupant_real_jid) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_occupant_jid(occupant_real_jid, room);
        }
        return null;
    }

    public Jid? get_occupant_jid_exact(Account account, Jid room,
            Jid occupant_real_full_jid) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return ((!) flag).get_occupant_jid_exact(
                occupant_real_full_jid, room);
        }
        return null;
    }

    public Xep.Muc.Role? get_role(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_occupant_role(jid);
        }
        return null;
    }

    public bool has_role(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        return flag != null && ((!) flag).has_occupant_role(jid);
    }

    public Gee.List<Xep.Muc.Hat> get_hats(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_occupant_hats(jid);
        }
        return new ArrayList<Xep.Muc.Hat>();
    }

    public async Xep.AdHocCommands.Command? execute_hats_command(Account account, Jid room_jid, string node) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        return yield stream.get_module<Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY).execute(stream, room_jid.bare_jid, node);
    }

    public bool request_room_occupant_presence_resync(Account account,
            Jid room_jid) {
        MucOwnerMutationContext? context = capture_muc_mutation_context(
            account, room_jid);
        if (context == null) return false;
        if (!is_current_muc_mutation_context(account, (!) context)) {
            return false;
        }
        return ((!) context).stream.get_module<Xep.Muc.Module>(
            Xep.Muc.Module.IDENTITY).request_occupant_presence_resync(
                ((!) context).stream, ((!) context).room);
    }

    public async Xep.AdHocCommands.Command? complete_hats_command(Account account, Jid room_jid, Xep.AdHocCommands.Command command) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || command.node == null || command.sessionid == null) return null;
        string action = command.execute_action ?? (command.actions.contains("complete") ? "complete" : "");
        return yield stream.get_module<Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY).proceed(stream, room_jid.bare_jid, command.node, command.sessionid, action, command.form);
    }

    public string? get_last_hats_command_error(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        return stream.get_module<Xep.AdHocCommands.Module>(Xep.AdHocCommands.Module.IDENTITY).last_error;
    }

    public Xep.Muc.Role? get_own_role(Conversation conversation) {
        Xmpp.Jid? own_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account);
        if (own_jid == null) return null;

        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_role(own_jid, conversation.account);
    }

    public Xep.Muc.Affiliation? get_affiliation(Jid muc_jid, Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_affiliation(muc_jid, jid);
        }
        return null;
    }

    public bool has_affiliation(Jid muc_jid, Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.has_affiliation(muc_jid, jid);
        }
        return false;
    }

    public Gee.List<Jid>? get_offline_members(Jid jid, Account account) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag != null) {
            return flag.get_offline_members(jid);
        }
        return null;
    }

     public Gee.List<Jid>? get_other_offline_members(Jid jid, Account account) {
        Gee.List<Jid>? occupants = get_offline_members(jid, account);
        if (occupants != null) {
            occupants.remove(account.bare_jid);
        }
        return occupants;
    }

    public Jid? get_own_jid(Jid muc_jid, Account account) {
        try {
            Xep.Muc.Flag? flag = get_muc_flag(account);
            if (flag != null) {
                string? nick  = flag.get_muc_nick(muc_jid);
                if (nick != null) return muc_jid.with_resource(nick);
            }
        } catch (InvalidJidError e) {
            warning("Joined MUC with invalid Jid: %s", e.message);
        }
        return null;
    }

    public bool is_own_muc_jid(Jid full_jid, Account account) {
        if (!is_groupchat(full_jid.bare_jid, account)) return false;
        Jid? own_jid = get_own_jid(full_jid, account);
        return own_jid != null && own_jid.equals(full_jid);
    }

    private Xep.Muc.Flag? get_muc_flag(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            return stream.get_flag(Xep.Muc.Flag.IDENTITY);
        }
        return null;
    }

    public bool is_joined(Jid jid, Account account) {
        return get_own_jid(jid, account) != null;
    }

    /**
     * Apply the effective occupant-invitation policy advertised by the room.
     * ejabberd keeps owner/admin affiliation privileges when the option is
     * disabled and extends it to all occupants when enabled. A missing policy
     * stays server-authoritative instead of inventing a local denial.
     */
    public static bool mediated_invite_possible_for_state(
            Xep.Muc.Affiliation? affiliation,
            bool? occupants_may_invite) {
        if (affiliation == Xep.Muc.Affiliation.OWNER ||
                affiliation == Xep.Muc.Affiliation.ADMIN) return true;
        return occupants_may_invite == null || (!) occupants_may_invite;
    }

    public bool mediated_invite_possible(Account account, Jid room) {
        Jid bare_room = room.bare_jid;
        Jid? own_jid = get_own_jid(bare_room, account);
        if (own_jid == null) return false;

        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag == null) return false;
        Xep.Muc.Affiliation? affiliation = ((!) flag).get_affiliation(
            bare_room, (!) own_jid);
        // A failed or superseded disco refresh invalidates the policy's
        // freshness. In that case let the room remain authoritative instead
        // of hiding the action from a stale local denial.
        bool? occupants_may_invite = ((!) flag).has_current_room_features(
            bare_room) ? ((!) flag).get_occupants_may_invite(bare_room) : null;
        return mediated_invite_possible_for_state(affiliation,
            occupants_may_invite);
    }

    public bool is_joined_or_joining(Jid jid, Account account) {
        return is_joined(jid, account) ||
            (mucs_joining.has_key(account) && mucs_joining[account].contains(jid.bare_jid));
    }

    public bool is_initial_presence_sync(Account account, Jid jid) {
        return muc_initial_presence_sync_timeouts.has_key(account) &&
            muc_initial_presence_sync_timeouts[account].has_key(jid.bare_jid);
    }

    public string? get_own_occupant_id(Account account, Jid muc_jid) {
        if (own_occupant_ids.has_key(account) && own_occupant_ids[account].has_key(muc_jid)) {
            return own_occupant_ids[account][muc_jid];
        }
        return null;
    }

    internal static bool is_dinox_timed_ban_reason(string? reason) {
        if (reason == null) return false;
        const string prefix = "Banned for ";
        const string suffix = " minutes";
        string value = (!) reason;
        if (!value.has_prefix(prefix) || !value.has_suffix(suffix)) {
            return false;
        }

        int number_length = value.length - prefix.length - suffix.length;
        if (number_length <= 0) return false;
        string number = value.substring(prefix.length, number_length);
        int minutes = 0;
        return int.try_parse(number, out minutes) && minutes > 0;
    }

    private void on_account_added(Account account) {
        Xep.Muc.Module muc_module = stream_interactor.module_manager.get_module<Xep.Muc.Module>(
            account, Xep.Muc.Module.IDENTITY);
        muc_module.room_destroyed.connect((stream, room, reason) => {
            if (!is_tracked_account_stream(account, stream)) return;
            commit_room_destruction(account, stream, room, false, true);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).self_removed_from_room.connect( (stream, jid, code, reason) => {
            if (!is_tracked_account_stream(account, stream)) return;

            debug("self_removed_from_room code=%d reason='%s'", (int)code, reason != null ? reason : "null");

            // A timed ban is a DinoX extension encoded in the reason text;
            // XEP-0045 itself only defines affiliation=outcast. Match only the
            // exact format DinoX emits. A loose "min" substring even matched
            // unrelated words such as "admin" and kept removed rooms alive.
            bool timed_ban = code == Xep.Muc.StatusCode.BANNED &&
                is_dinox_timed_ban_reason(reason);
            bool close = !timed_ban;
            debug("Closing conversation after self removal: %s (DinoX timed ban: %s)",
                close.to_string(), timed_ban.to_string());

            left(account, jid, close);
            self_removed(account, jid, code, reason);
            if (code == Xep.Muc.StatusCode.REMOVED_SHUTDOWN && bookmarks_provider.has_key(account)) {
                Conference c = new Conference();
                c.jid = jid.bare_jid;
                remove_conference_checked(account, stream, c, "room-shutdown");
            }
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).removed_from_room.connect( (stream, jid, code) => {
            if (!is_tracked_account_stream(account, stream)) return;
            forget_private_message_peer_identity(account, jid);
            occupant_removed(account, jid.bare_jid, jid, code);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).received_occupant_affiliation.connect( (stream, jid, affiliation) => {
            if (!is_tracked_account_stream(account, stream)) return;
            if (affiliation != null &&
                    !defer_occupant_compatibility_signal(account, jid)) {
                occupant_affiliation_updated(account, jid.bare_jid, jid, affiliation);
            }
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).subject_set.connect( (stream, subject, jid) => {
            if (!is_tracked_account_stream(account, stream)) return;
            subject_set(account, jid, subject);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).invite_received_with_context.connect( (stream, room_jid, from_jid, password, reason, continue_thread, thread) => {
            if (!is_tracked_account_stream(account, stream)) return;
            on_invite_received(account, room_jid, from_jid, password, reason, continue_thread, thread, MucInviteSource.MEDIATED);
        });
        muc_module.invite_failed.connect((stream, room_jid, invitee_jid,
                condition, text) => {
            if (!is_tracked_account_stream(account, stream)) return;
            invite_failed(account, room_jid, invitee_jid, condition, text);
        });
        stream_interactor.module_manager.get_module<Xep.DirectMucInvitations.Module>(account, Xep.DirectMucInvitations.Module.IDENTITY).invite_received_with_context.connect( (stream, room_jid, from_jid, password, reason, continue_thread, thread) => {
            if (!is_tracked_account_stream(account, stream)) return;
            on_invite_received(account, room_jid, from_jid, password, reason, continue_thread, thread, MucInviteSource.DIRECT);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).voice_request_received.connect( (stream, room_jid, from_jid, nick, stanza_id) => {
            if (!is_tracked_account_stream(account, stream)) return;
            voice_request_received(account, room_jid, from_jid, nick,
                stanza_id);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account,
                Xep.Muc.Module.IDENTITY).voice_request_sent.connect(
                (stream, room_jid, correlation_id) => {
            if (!is_tracked_account_stream(account, stream)) return;
            voice_request_sent(account, room_jid, correlation_id);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account,
                Xep.Muc.Module.IDENTITY).voice_request_failed.connect(
                (stream, room_jid, correlation_id, condition, text) => {
            if (!is_tracked_account_stream(account, stream)) return;
            voice_request_failed(account, room_jid, correlation_id,
                condition, text);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account,
                Xep.Muc.Module.IDENTITY).voice_request_response_failed.connect(
                (stream, room_jid, correlation_id, condition, text) => {
            if (!is_tracked_account_stream(account, stream)) return;
            voice_request_response_failed(account, room_jid,
                correlation_id, condition, text);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account,
                Xep.Muc.Module.IDENTITY).voice_request_response_settled.connect(
                (stream, room_jid, correlation_id) => {
            if (!is_tracked_account_stream(account, stream)) return;
            voice_request_response_settled(account, room_jid,
                correlation_id);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).received_occupant_role.connect( (stream, from_jid, role) => {
            if (!is_tracked_account_stream(account, stream)) return;
            if (!defer_occupant_compatibility_signal(account, from_jid) ||
                    is_current_own_muc_jid(account, from_jid)) {
                received_occupant_role(account, from_jid, role);
            }
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).received_occupant_hats.connect( (stream, from_jid, hats) => {
            if (!is_tracked_account_stream(account, stream)) return;
            if (!defer_occupant_compatibility_signal(account, from_jid)) {
                received_occupant_hats(account, from_jid, hats);
            }
        });
        muc_module.received_occupant_presence.connect((stream, event) => {
            on_muc_occupant_presence(account, stream, event);
        });
        muc_module.room_avatar_info_received.connect((stream, muc_jid,
                info) => {
            if (!is_tracked_account_stream(account, stream)) return;
            room_avatar_info_updated(account, muc_jid.bare_jid, info);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).room_info_updated.connect( (stream, muc_jid) => {
            if (!is_tracked_account_stream(account, stream)) return;
            resolve_pending_occupant_ids(account, muc_jid);
            stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).refresh_features.begin(account, muc_jid);
            bool force_private_snapshot_refresh =
                has_private_muc_room_info_ready(account, muc_jid);
            mark_private_muc_room_info_ready(account, muc_jid);
            handle_private_muc_room_info_updated(account, muc_jid,
                force_private_snapshot_refresh);
            room_info_updated(account, muc_jid);
            complete_pending_muc_room_info_waiters(account, muc_jid, true);
            if (is_joined(muc_jid, account)) {
                resume_unsent_muc_messages_after_join.begin(account,
                    muc_jid);
            }
        });
        muc_module.room_info_query_finished.connect((stream, muc_jid,
                succeeded) => {
            if (!is_tracked_account_stream(account, stream) || succeeded) {
                return;
            }
            mark_private_muc_room_info_failed(account, muc_jid);
            room_info_query_failed(account, muc_jid.bare_jid);
            complete_pending_muc_room_info_waiters(account, muc_jid, false);
        });
        muc_module.room_real_jid_visibility_revoked.connect((stream,
                room_jid) => {
            if (!is_tracked_account_stream(account, stream)) return;
            set_muc_real_jid_retention_authority(account, room_jid,
                MucRealJidRetentionAuthority.DENIED);
            scrub_room_snapshot_real_jids(account, room_jid);
            bump_room_real_jid_visibility_generation(account, room_jid);
            forget_room_private_message_real_jids(account, room_jid);
            room_real_jid_visibility_revoked(account, room_jid);
        });
        muc_module.room_real_jid_visibility_changed.connect((stream,
                room_jid, visibility) => {
            if (!is_tracked_account_stream(account, stream)) return;
            refresh_muc_real_jid_retention_authority(account, room_jid,
                stream);
            room_real_jid_visibility_changed(account, room_jid.bare_jid,
                visibility);
        });
        stream_interactor.module_manager.get_module<Xep.Muc.Module>(account, Xep.Muc.Module.IDENTITY).received_occupant_jid.connect( (stream, room, occupant) => {
            if (!is_tracked_account_stream(account, stream)) return;
            // PM real-JID identity is committed only by the generation-fenced
            // occupant-presence path while its worker is active. The guarded
            // fallback below is needed only after worker rejection/degraded
            // fallback; unlike the old unconditional write it cannot recreate
            // an identity after leave because the room/nick must still be a
            // currently available occupant of a joined room.
            bool current_occupant = is_current_occupant(account,
                room.bare_jid, room);
            MucOccupantRoom? binding = get_muc_occupant_room(account,
                room.bare_jid);
            bool worker_owns_identity = binding != null &&
                is_current_muc_occupant_room((!) binding,
                    ((!) binding).worker_key);
            if (current_occupant && !worker_owns_identity) {
                if (occupant != null) {
                    remember_private_message_peer_identity(account, room,
                        "jid:" + ((!) occupant).bare_jid.to_string());
                } else {
                    forget_private_message_real_jid(account, room);
                }
            }
            if (current_occupant &&
                    is_private_room(account, room.bare_jid) &&
                    !defer_occupant_compatibility_signal(account, room)) {
                private_room_occupant_updated(account, room, occupant);
            }
        });
        stream_interactor.module_manager.get_module<Xep.OccupantIds.Module>(account, Xep.OccupantIds.Module.IDENTITY).received_own_occupant_id.connect( (stream, jid, occupant_id) => {
            if (!is_tracked_account_stream(account, stream)) return;
            record_current_occupant_id(account, jid, occupant_id, true);
        });
        stream_interactor.module_manager.get_module<Xep.OccupantIds.Module>(account, Xep.OccupantIds.Module.IDENTITY).received_occupant_id.connect( (stream, jid, occupant_id) => {
            if (!is_tracked_account_stream(account, stream)) return;
            record_current_occupant_id(account, jid, occupant_id, false);
        });
    }

    private bool is_tracked_account_stream(Account account,
            XmppStream stream) {
        return stream_interactor.connection_manager
            .is_current_or_provisionally_retained_stream(account, stream);
    }

    private void start_search_default_muc_server(Account account) {
        search_default_muc_server.begin(account, (_, res) => {
            search_default_muc_server.end(res);
        });
    }

    private async void search_default_muc_server(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;
        XmppStream expected_stream = (!) stream;

        ServiceDiscovery.ItemsResult? items_result = yield expected_stream
            .get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY)
            .request_items(expected_stream, expected_stream.remote_name);
        if (stream_interactor.get_stream(account) != expected_stream) return;
        if (items_result == null) {
            default_muc_server_changed(account, null);
            return;
        }

        for (int i = 0; i < 2; i++) {
            foreach (Xep.ServiceDiscovery.Item item in items_result.items) {

                // First try the promising items and only afterwards all the others
                bool promising_upload_item = item.jid.to_string().has_prefix("conference") ||
                        item.jid.to_string().has_prefix("muc") ||
                        item.jid.to_string().has_prefix("chat");
                if ((i == 0 && !promising_upload_item) || (i == 1) && promising_upload_item) continue;

                Gee.Set<Xep.ServiceDiscovery.Identity> identities = yield stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).get_identities(account, item.jid);
                if (stream_interactor.get_stream(account) != expected_stream) return;
                if (identities == null) {
                    default_muc_server_changed(account, null);
                    return;
                }

                foreach (Xep.ServiceDiscovery.Identity identity in identities) {
                    if (identity.category == Xep.ServiceDiscovery.Identity.CATEGORY_CONFERENCE) {
                        default_muc_server[account] = item.jid;
                        debug("[%s] Default MUC: %s", account.bare_jid.to_string(), item.jid.to_string());
                        default_muc_server_changed(account, item.jid);
                        return;
                    }
                }
            }
        }
        default_muc_server_changed(account, null);
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        handle_stream_negotiated.begin(account, stream, (_, res) => {
            handle_stream_negotiated.end(res);
        });
    }

    private void on_account_removed(Account account) {
        detach_timed_bans_for_account(account);
        remove_room_observers_for_account(account.id);
        clear_all_muc_runtime_state(account);
    }

    private void on_connection_state_changed(Account account,
            ConnectionManager.ConnectionState state) {
        if (state == ConnectionManager.ConnectionState.DISCONNECTED) {
            clear_all_muc_mam_retries(account);
            XmppStream? retained = stream_interactor.connection_manager
                .get_provisionally_retained_stream(account);
            bool replacement_pending = stream_interactor.connection_manager
                .is_stream_replacement_pending(account);
            if (retained == null && !replacement_pending) {
                muc_provisional_disconnect_streams.unset(account);
                clear_transient_muc_runtime_state(account);
                return;
            }
            // An IQ started on the transport before an outage may never own a
            // useful completion after resume. Release only its de-duplication
            // marker; the resumable room/worker projection stays intact.
            bump_muc_self_ping_generation(account);
            bump_muc_transport_pause_generation(account);
            muc_self_pings_in_flight.unset(account);
            // Stream management or the retained transport owns delivery for
            // idle rooms. Restart only MAM work that this pause interrupted;
            // joins completed while paused add their own explicit intent.
            defer_active_muc_mam_syncs(account);
            cancel_all_muc_sync(account);
            if (retained != null) {
                muc_provisional_disconnect_streams[account] = (!) retained;
            } else {
                // Preserve the projection for a possible XEP-0198 resume, but
                // never accept callbacks from the abandoned transport.
                muc_provisional_disconnect_streams.unset(account);
            }
        } else if (state == ConnectionManager.ConnectionState.CONNECTED &&
                muc_provisional_disconnect_streams.has_key(account) &&
                stream_interactor.get_stream(account) ==
                    muc_provisional_disconnect_streams[account]) {
            muc_provisional_disconnect_streams.unset(account);
            replay_resumed_muc_side_effects(account);
            self_ping(account);
        }
    }

    private void on_stream_resumed(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;
        muc_provisional_disconnect_streams.unset(account);
        replay_resumed_muc_side_effects(account);
        self_ping(account);
    }

    private void replay_resumed_muc_side_effects(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        if (pending_autojoin_bookmark_writes.has_key(account)) {
            var pending_rooms = new ArrayList<Jid>();
            pending_rooms.add_all(
                pending_autojoin_bookmark_writes[account].keys);
            foreach (Jid room in pending_rooms) {
                process_next_autojoin_bookmark_write(account, (!) stream,
                    room);
            }
        }

        resume_deferred_muc_mam_syncs(account);

        if (!mucs_joined.has_key(account)) return;
        var joined_rooms = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Jid joined_jid in mucs_joined[account]) {
            if (!joined_rooms.contains(joined_jid.bare_jid)) {
                joined_rooms.add(joined_jid.bare_jid);
            }
        }
        foreach (Jid room in joined_rooms) {
            resume_unsent_muc_messages_after_join.begin(account, room);
        }
    }

    private async void handle_stream_negotiated(Account account, XmppStream stream) {
        muc_provisional_disconnect_streams.unset(account);
        clear_transient_muc_runtime_state(account);
        restore_persisted_timed_bans(account);
        restore_pending_permanent_bookmark_removals(account);

        yield initialize_bookmarks_provider(account, stream);
        if (stream_interactor.get_stream(account) != stream || !bookmarks_provider.has_key(account)) return;

        BookmarksProvider provider = bookmarks_provider[account];
        Set<Conference>? conferences = yield provider.get_conferences(stream);
        if (stream_interactor.get_stream(account) != stream ||
                !is_current_bookmark_provider(account, provider)) return;

        if (conferences == null) {
            if (pending_permanent_bookmark_removals.has_key(account)) {
                var pending_rooms = new ArrayList<Jid>();
                pending_rooms.add_all(
                    pending_permanent_bookmark_removals[account]);
                foreach (Jid room in pending_rooms) {
                    queue_permanent_bookmark_removal(account, stream, room);
                }
            }
            join_all_active(account);
        } else {
            if (!bookmark_names.has_key(account)) {
                bookmark_names[account] = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
            }
            var names = bookmark_names[account];
            names.clear();
            foreach (var conf in conferences) {
                if (conf.name != null && conf.name != "") {
                    names[conf.jid] = conf.name;
                }
            }

            sync_autojoin_active(account, conferences);
            bookmarks_updated(account,
                filter_manually_removed_conferences(account, conferences));
        }

        if (!default_muc_server.has_key(account)) {
            start_search_default_muc_server(account);
        }
    }

    private async void initialize_bookmarks_provider(Account account, XmppStream stream) {
        if (bookmarks_provider.has_key(account)) return;

        // Use PEP native bookmarks (urn:xmpp:bookmarks:1) if conversion is available, legacy bookmarks (storage:bookmarks) otherwise.
        bool has_feature = yield stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).has_feature(account, account.bare_jid, Xep.Bookmarks2.NS_URI_COMPAT);
        if (stream_interactor.get_stream(account) != stream) return;
        BookmarksProvider provider;
        if (has_feature) {
            debug("[%s] Using PEP native bookmarks (urn:xmpp:bookmarks:1)", account.bare_jid.to_string());
            provider = stream_interactor.module_manager.get_module<Xep.Bookmarks2.Module>(account, Xep.Bookmarks2.Module.IDENTITY);
        } else {
            debug("[%s] Using legacy bookmarks (storage:bookmarks)", account.bare_jid.to_string());
            provider = stream_interactor.module_manager.get_module<Xep.Bookmarks.Module>(account, Xep.Bookmarks.Module.IDENTITY);
        }
        bookmarks_provider[account] = provider;

        provider.received_conferences.connect( (event_stream, conferences) => {
            if (stream_interactor.get_stream(account) != event_stream ||
                    !is_current_bookmark_provider(account, provider)) return;
            if (!bookmark_names.has_key(account)) {
                bookmark_names[account] = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
            }
            Set<Conference> visible_conferences = filter_manually_removed_conferences(account, conferences);
            var names = bookmark_names[account];
            names.clear();
            foreach (var conf in visible_conferences) {
                if (conf.name != null && conf.name != "") {
                    names[conf.jid] = conf.name;
                }
            }

            sync_autojoin_active(account, conferences);
            bookmarks_updated(account, visible_conferences);
        });
        provider.conference_added.connect( (event_stream, conference) => {
            if (stream_interactor.get_stream(account) != event_stream ||
                    !is_current_bookmark_provider(account, provider)) return;
            if (!bookmark_names.has_key(account)) {
                bookmark_names[account] = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
            }
            if (conference.name != null && conference.name != "") {
                bookmark_names[account][conference.jid] = conference.name;
            } else {
                bookmark_names[account].unset(conference.jid);
            }

            on_conference_added(account, conference);
        });
        provider.conference_removed.connect( (event_stream, jid) => {
            if (stream_interactor.get_stream(account) != event_stream ||
                    !is_current_bookmark_provider(account, provider)) return;
            if (bookmark_names.has_key(account)) {
                bookmark_names[account].unset(jid);
            }

            on_conference_removed(account, jid);
        });
    }

    internal async void handle_stream_negotiated_for_tests(Account account,
            XmppStream stream) {
        yield handle_stream_negotiated(account, stream);
    }

    private void on_invite_received(Account account, Jid room_jid, Jid from_jid, string? password, string? reason, bool continue_thread = false, string? thread = null, MucInviteSource source = MucInviteSource.MEDIATED) {
        if (!invites.has_key(account)) {
            invites[account] = new LinkedList<Jid>(Jid.equals_func);
        }
        if (invites[account].contains(room_jid)) {
            if (source == MucInviteSource.MEDIATED) {
                invite_received_with_source(account, room_jid, from_jid, password, reason, continue_thread, thread, source);
            }
            return;
        }
        invites[account].add(room_jid);

        invite_received(account, room_jid, from_jid, password, reason);
        invite_received_with_context(account, room_jid, from_jid, password, reason, continue_thread, thread);
        invite_received_with_source(account, room_jid, from_jid, password, reason, continue_thread, thread, source);

        Timeout.add_seconds(5, () => {
            // We don't want to show the same invite (direct+mediated) twice, but a distinct invite is fine
            if (invites.has_key(account)) {
                invites[account].remove(room_jid);
                if (invites[account].is_empty) {
                    invites.unset(account);
                }
            }
            return false;
        });
    }

    private void join_all_active(Account account) {
        var candidates = new ArrayList<Conference>();
        var candidate_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        Gee.List<Conversation> conversations = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations(account);
        foreach (Conversation conversation in conversations) {
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                Conference conference = new Conference() {
                    jid=conversation.counterpart.bare_jid,
                    nick=conversation.nickname,
                    autojoin=true
                };
                add_autojoin_candidate(candidates, candidate_jids, conference);
            }
        }
        queue_autojoin_candidates(account, candidates, AutojoinPriority.ACTIVE);
    }

    private void sync_autojoin_active(Account account, Set<Conference> conferences) {
        clear_resolved_pending_bookmark_removals(account, conferences);
        Gee.List<Conversation> active_conversations = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations(account);
        var candidates = new ArrayList<Conference>();
        var candidate_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);

        // Active local MUC conversations are the user's current UI state. Put
        // them before bookmark-only rooms so the visible/restored chat does not
        // wait behind background autojoins.
        foreach (Conversation conversation in active_conversations) {
            if (conversation.type_ != Conversation.Type.GROUPCHAT) continue;

            if (!is_joined(conversation.counterpart, account) &&
                    !(mucs_joining.has_key(account) && mucs_joining[account].contains(conversation.counterpart))) {
                Conference conference = new Conference() {
                    jid=conversation.counterpart.bare_jid,
                    nick=conversation.nickname,
                    autojoin=true
                };
                add_autojoin_candidate(candidates, candidate_jids, conference);
            }
        }

        queue_autojoin_candidates(account, candidates, AutojoinPriority.ACTIVE);
        candidates = new ArrayList<Conference>();
        candidate_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);

        // Join auto-join MUCs
        foreach (Conference conference in conferences) {
            if (is_manually_removed_bookmark(account, conference.jid)) {
                remove_queued_autojoin_candidate(account, conference.jid);
                continue;
            }
            if (is_permanent_leave_marked(account, conference.jid) ||
                    is_pending_permanent_bookmark_removal(account,
                        conference.jid)) {
                remove_queued_autojoin_candidate(account, conference.jid);
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream != null && bookmarks_provider.has_key(account)) {
                    mark_pending_permanent_bookmark_removal(account,
                        conference.jid);
                    queue_permanent_bookmark_removal(account, stream,
                        conference.jid);
                }
                continue;
            }
            if (is_leave_marked(account, conference.jid)) {
                remove_queued_autojoin_candidate(account, conference.jid);
                if (conference.autojoin) {
                    XmppStream? stream = stream_interactor.get_stream(account);
                    if (stream != null) {
                        unset_autojoin(account, stream, conference.jid, true);
                    }
                }
                continue;
            }
            if (!conference.autojoin && !has_active_queued_autojoin_candidate(account, conference.jid)) {
                remove_queued_autojoin_candidate(account, conference.jid);
                continue;
            }

            bool is_active = false;
            foreach (Conversation conversation in active_conversations) {
                if (conference.jid.equals(conversation.counterpart)) {
                    is_active = true;
                }
            }
            if (!is_active) {
                Conversation? existing = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(conference.jid, account, Conversation.Type.GROUPCHAT);
                if (existing != null && !existing.active) {
                    continue;
                }
            }
            if (!is_active || !is_joined_or_joining(conference.jid, account)) {
                add_autojoin_candidate(candidates, candidate_jids, conference);
            }
        }

        queue_autojoin_candidates(account, candidates, AutojoinPriority.BACKGROUND);
    }

    private void add_autojoin_candidate(ArrayList<Conference> candidates, HashSet<Jid> candidate_jids, Conference conference) {
        if (conference.jid == null) return;
        Jid bare_jid = conference.jid.bare_jid;
        if (candidate_jids.contains(bare_jid)) return;

        candidate_jids.add(bare_jid);
        candidates.add(conference);
    }

    private void queue_autojoin_candidates(Account account, ArrayList<Conference> candidates, AutojoinPriority priority = AutojoinPriority.BACKGROUND) {
        if (candidates.is_empty) {
            return;
        }

        if (!autojoin_queues.has_key(account)) {
            autojoin_queues[account] = new ArrayList<AutojoinCandidate>();
        }
        foreach (Conference conference in candidates) {
            if (conference.jid != null && is_manually_removed_bookmark(account, ((!) conference.jid).bare_jid)) {
                continue;
            }
            merge_autojoin_candidate(account, conference, priority);
        }
        ensure_foreground_autojoin_first(account);

        debug("MUC autojoin queue [%s]: queued %d room(s)", account.bare_jid.to_string(), autojoin_queues[account].size);
        clear_scheduled_autojoin_queue(account);
        schedule_autojoin_queue(account, autojoin_delay_for_next(account, AUTOJOIN_QUEUE_INITIAL_DELAY_MS));
    }

    private void merge_autojoin_candidate(Account account, Conference conference, AutojoinPriority priority) {
        AutojoinCandidate? existing = find_queued_autojoin_candidate(account, conference.jid);
        if (existing != null) {
            existing.conference = merge_autojoin_conferences(existing.conference, conference);
            if (priority == AutojoinPriority.ACTIVE) existing.priority = AutojoinPriority.ACTIVE;
            reposition_autojoin_candidate(account, (!) existing);
            return;
        }

        AutojoinCandidate candidate = new AutojoinCandidate(conference, priority);
        if (is_foreground_autojoin_candidate(account, candidate) || priority == AutojoinPriority.ACTIVE) {
            autojoin_queues[account].insert(0, candidate);
        } else {
            autojoin_queues[account].add(candidate);
        }
    }

    private AutojoinCandidate? find_queued_autojoin_candidate(Account account, Jid jid) {
        if (!autojoin_queues.has_key(account)) return null;

        Jid bare_jid = jid.bare_jid;
        foreach (AutojoinCandidate candidate in autojoin_queues[account]) {
            if (candidate.conference.jid != null && candidate.conference.jid.bare_jid.equals(bare_jid)) {
                return candidate;
            }
        }
        return null;
    }

    private bool has_active_queued_autojoin_candidate(Account account, Jid jid) {
        AutojoinCandidate? candidate = find_queued_autojoin_candidate(account, jid);
        return candidate != null && ((!) candidate).priority == AutojoinPriority.ACTIVE;
    }

    private Conference merge_autojoin_conferences(Conference old_conference, Conference new_conference) {
        return new Conference() {
            jid=old_conference.jid ?? new_conference.jid,
            nick=new_conference.nick ?? old_conference.nick,
            name=new_conference.name ?? old_conference.name,
            password=new_conference.password ?? old_conference.password,
            autojoin=old_conference.autojoin || new_conference.autojoin
        };
    }

    private void reposition_autojoin_candidate(Account account, AutojoinCandidate candidate) {
        if (!autojoin_queues.has_key(account)) return;

        autojoin_queues[account].remove(candidate);
        if (is_foreground_autojoin_candidate(account, candidate) || candidate.priority == AutojoinPriority.ACTIVE) {
            autojoin_queues[account].insert(0, candidate);
        } else {
            autojoin_queues[account].add(candidate);
        }
    }

    /**
     * Give the currently visible MUC precedence over background autojoins.
     *
     * This is only a queue-order hint. It never starts a second join, creates a
     * bookmark, or drops the password stored on an existing queued candidate.
     * If bookmark discovery has not produced the candidate yet, the hint is
     * retained and applied when that candidate is queued.
     */
    public void prioritize_conversation_autojoin(Conversation? conversation) {
        update_visible_muc_conversation(conversation);
        Account? previous_account = foreground_autojoin_account;
        foreground_autojoin_account = null;
        foreground_autojoin_room = null;
        if (previous_account != null) {
            reschedule_autojoin_after_foreground_change((!) previous_account);
        }

        if (conversation == null || ((!) conversation).type_ != Conversation.Type.GROUPCHAT) return;

        Conversation selected = (!) conversation;
        Account account = selected.account;
        Jid room = selected.counterpart.bare_jid;
        if (is_joined_or_joining(room, account) ||
                is_leave_blocked(account, room) ||
                is_manually_removed_bookmark(account, room)) return;

        foreground_autojoin_account = account;
        foreground_autojoin_room = room;

        AutojoinCandidate? candidate = find_queued_autojoin_candidate(account, room);
        if (candidate != null) {
            if (((!) candidate).priority == AutojoinPriority.BACKGROUND) {
                ((!) candidate).priority = AutojoinPriority.ACTIVE;
            }
            reposition_autojoin_candidate(account, (!) candidate);
        }

        if (!autojoin_queue_active.contains(account) &&
                autojoin_queues.has_key(account) &&
                !autojoin_queues[account].is_empty) {
            clear_scheduled_autojoin_queue(account);
            schedule_autojoin_queue(account, autojoin_delay_for_next(account, AUTOJOIN_QUEUE_INITIAL_DELAY_MS));
        }
        debug("MUC autojoin queue [%s]: foreground room %s queued=%s",
            account.bare_jid.to_string(), room.to_string(), (candidate != null).to_string());
    }

    private void update_visible_muc_conversation(Conversation? conversation) {
        visible_muc_account = null;
        visible_muc_room = null;
        if (conversation == null ||
                ((!) conversation).type_ != Conversation.Type.GROUPCHAT) return;

        Conversation selected = (!) conversation;
        visible_muc_account = selected.account;
        visible_muc_room = selected.counterpart.bare_jid;
        MucOccupantRoom? binding = get_muc_occupant_room(selected.account,
            selected.counterpart);
        if (binding != null) reprioritize_pending_muc_live_flush((!) binding);
    }

    private bool is_visible_muc_room(Account account, Jid room) {
        return visible_muc_account != null && visible_muc_room != null &&
            ((!) visible_muc_account).equals(account) &&
            ((!) visible_muc_room).equals_bare(room);
    }

    private bool is_foreground_autojoin_candidate(Account account, AutojoinCandidate candidate) {
        return foreground_autojoin_account != null && foreground_autojoin_room != null &&
            ((!) foreground_autojoin_account).equals(account) &&
            candidate.conference.jid != null &&
            ((!) candidate.conference.jid).bare_jid.equals((!) foreground_autojoin_room);
    }

    private void ensure_foreground_autojoin_first(Account account) {
        if (foreground_autojoin_account == null || foreground_autojoin_room == null ||
                !((!) foreground_autojoin_account).equals(account)) return;

        AutojoinCandidate? candidate = find_queued_autojoin_candidate(account, (!) foreground_autojoin_room);
        if (candidate != null) reposition_autojoin_candidate(account, (!) candidate);
    }

    private uint autojoin_delay_for_next(Account account, uint fallback_delay_ms) {
        if (!autojoin_queues.has_key(account) || autojoin_queues[account].is_empty) {
            return fallback_delay_ms;
        }
        return is_foreground_autojoin_candidate(account, autojoin_queues[account][0])
            ? 0
            : fallback_delay_ms;
    }

    private int autojoin_source_priority_for_next(Account account) {
        if (!autojoin_queues.has_key(account) || autojoin_queues[account].is_empty) {
            return GLib.Priority.LOW;
        }
        return is_foreground_autojoin_candidate(account, autojoin_queues[account][0])
            ? GLib.Priority.DEFAULT
            : GLib.Priority.LOW;
    }

    private void reschedule_autojoin_after_foreground_change(Account account) {
        if (autojoin_queue_active.contains(account) ||
                !autojoin_queues.has_key(account) ||
                autojoin_queues[account].is_empty) return;

        clear_scheduled_autojoin_queue(account);
        schedule_autojoin_queue(account, AUTOJOIN_QUEUE_INITIAL_DELAY_MS);
    }

    private void remove_queued_autojoin_candidate(Account account, Jid jid) {
        if (!autojoin_queues.has_key(account)) return;

        Jid bare_jid = jid.bare_jid;
        for (int i = autojoin_queues[account].size - 1; i >= 0; i--) {
            AutojoinCandidate candidate = autojoin_queues[account][i];
            if (candidate.conference.jid != null && candidate.conference.jid.bare_jid.equals(bare_jid)) {
                autojoin_queues[account].remove_at(i);
            }
        }
        if (autojoin_queues[account].is_empty) {
            autojoin_queues.unset(account);
        }
    }

    private void clear_scheduled_autojoin_queue(Account account) {
        if (!autojoin_queue_source_ids.has_key(account)) return;

        Source.remove(autojoin_queue_source_ids[account]);
        autojoin_queue_source_ids.unset(account);
    }

    private void schedule_autojoin_queue(Account account, uint delay_ms) {
        if (autojoin_queue_active.contains(account)) return;
        if (!autojoin_queues.has_key(account) || autojoin_queues[account].is_empty) return;
        if (autojoin_queue_source_ids.has_key(account)) return;

        int source_priority = autojoin_source_priority_for_next(account);
        debug("MUC autojoin queue [%s]: scheduling delay=%u priority=%d",
            account.bare_jid.to_string(), delay_ms, source_priority);
        autojoin_queue_source_ids[account] = Timeout.add_full(source_priority, delay_ms, () => {
            autojoin_queue_source_ids.unset(account);
            process_next_autojoin.begin(account);
            return false;
        });
    }

    private AutojoinCandidate? pop_next_autojoin_candidate(Account account) {
        if (!autojoin_queues.has_key(account)) return null;

        while (!autojoin_queues[account].is_empty) {
            AutojoinCandidate candidate = autojoin_queues[account].remove_at(0);
            if (candidate.conference.jid == null) continue;
            return candidate;
        }

        autojoin_queues.unset(account);
        return null;
    }

    private async void process_next_autojoin(Account account) {
        if (autojoin_queue_active.contains(account)) return;
        if (stream_interactor.get_stream(account) == null) {
            schedule_autojoin_queue(account, AUTOJOIN_QUEUE_NEXT_DELAY_MS);
            return;
        }
        uint runtime_generation = get_muc_runtime_generation(account);
        uint transport_pause_generation =
            get_muc_transport_pause_generation(account);

        AutojoinCandidate? queued_candidate = pop_next_autojoin_candidate(account);
        if (queued_candidate == null) return;
        AutojoinCandidate candidate = (!) queued_candidate;

        autojoin_queue_active.add(account);
        if (stream_interactor.get_stream(account) == null) {
            requeue_autojoin_candidate(account, candidate);
        } else if (should_start_queued_autojoin(account, candidate.conference)) {
            debug("MUC autojoin queue [%s]: joining %s", account.bare_jid.to_string(), candidate.conference.jid.to_string());
            Muc.JoinResult? result = yield join(account,
                candidate.conference.jid, candidate.conference.nick,
                candidate.conference.password, true);
            bool transport_paused_during_join = transport_pause_generation !=
                get_muc_transport_pause_generation(account);
            bool retryable_join_failure = result == null ||
                (((!) result).nick == null && ((!) result).muc_error == null &&
                    ((!) result).stanza_error ==
                        Xmpp.ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT);
            if (transport_paused_during_join && retryable_join_failure &&
                    runtime_generation == get_muc_runtime_generation(account) &&
                    should_retry_queued_autojoin(account,
                        candidate.conference)) {
                requeue_autojoin_candidate(account, candidate);
            }
        }
        if (runtime_generation != get_muc_runtime_generation(account)) return;
        autojoin_queue_active.remove(account);

        schedule_autojoin_queue(account, autojoin_delay_for_next(account, AUTOJOIN_QUEUE_NEXT_DELAY_MS));
    }

    private void requeue_autojoin_candidate(Account account, AutojoinCandidate candidate) {
        if (!autojoin_queues.has_key(account)) {
            autojoin_queues[account] = new ArrayList<AutojoinCandidate>();
        }
        if (is_foreground_autojoin_candidate(account, candidate) ||
                candidate.priority == AutojoinPriority.ACTIVE) {
            autojoin_queues[account].insert(0, candidate);
        } else {
            autojoin_queues[account].add(candidate);
        }
    }

    private bool should_start_queued_autojoin(Account account, Conference conference) {
        if (conference.jid == null) return false;
        if (!conference.autojoin) return false;
        if (is_manually_removed_bookmark(account, conference.jid)) return false;
        if (is_leave_blocked(account, conference.jid)) return false;
        if (stream_interactor.get_stream(account) == null) return false;
        if (mucs_joining.has_key(account) && mucs_joining[account].contains(conference.jid.bare_jid)) return false;

        return true;
    }

    private bool should_retry_queued_autojoin(Account account,
            Conference conference) {
        if (conference.jid == null || !conference.autojoin) return false;
        return !is_manually_removed_bookmark(account, conference.jid) &&
            !is_leave_blocked(account, conference.jid) &&
            !is_joined_or_joining(conference.jid, account);
    }

    private void set_autojoin(Account account, XmppStream stream, Jid jid, string? nick, string? password) {
        if (is_leave_blocked(account, jid)) return;
        clear_manual_bookmark_removal_notification(account, jid);
        Conference? previous = get_desired_manual_bookmark(account, jid);
        string? name = bookmark_names.has_key(account)
            ? bookmark_names[account].get(jid.bare_jid)
            : null;
        if (name == null && previous != null) name = ((!) previous).name;
        string? effective_password = password ??
            (previous != null ? ((!) previous).password : null);
        remember_desired_manual_bookmark(account, new Conference() {
            jid=jid.bare_jid, nick=nick, name=name,
            password=effective_password,
            autojoin=true
        });
        uint generation = next_autojoin_write_generation(account, jid);
        retarget_stale_bookmark_remove_echo_fence(account, jid, generation);
        queue_autojoin_bookmark_write(account, stream, jid, true, nick,
            effective_password, false, generation, 0, false, false, name);
    }

    private void unset_autojoin(Account account, XmppStream stream, Jid jid, bool allow_leave_marker = false) {
        if (is_permanent_leave_marked(account, jid)) return;
        if (!allow_leave_marker && is_leave_marked(account, jid)) return;
        Conference? desired = get_desired_manual_bookmark(account, jid);
        string? name = bookmark_names.has_key(account)
            ? bookmark_names[account].get(jid.bare_jid)
            : null;
        if (name == null && desired != null) name = ((!) desired).name;
        bool recreate_if_missing = desired != null;
        forget_desired_manual_bookmark(account, jid);
        uint generation = next_autojoin_write_generation(account, jid);
        AutojoinBookmarkWrite exact_intent = new AutojoinBookmarkWrite(false,
            desired != null ? ((!) desired).nick : null,
            desired != null ? ((!) desired).password : null,
            allow_leave_marker, generation, 0, false,
            recreate_if_missing, name);
        retarget_stale_bookmark_remove_echo_fence(account, jid, generation,
            exact_intent);
        queue_autojoin_bookmark_write(account, stream, jid, false,
            desired != null ? ((!) desired).nick : null,
            desired != null ? ((!) desired).password : null,
            allow_leave_marker, generation, 0, false,
            recreate_if_missing, name);
    }

    private void queue_autojoin_bookmark_write(Account account,
            XmppStream stream, Jid jid, bool autojoin, string? nick,
            string? password, bool allow_leave_marker, uint generation,
            int attempts = 0, bool remove_bookmark = false,
            bool recreate_if_missing = false, string? name = null) {
        if (!bookmarks_provider.has_key(account)) return;
        bool retained_transport_pause =
            stream_interactor.get_stream(account) == null &&
            muc_provisional_disconnect_streams.has_key(account) &&
            muc_provisional_disconnect_streams[account] == stream &&
            stream_interactor.connection_manager
                .get_provisionally_retained_stream(account) == stream;
        if (stream_interactor.get_stream(account) != stream &&
                !retained_transport_pause) return;
        Jid bare = jid.bare_jid;
        if (!pending_autojoin_bookmark_writes.has_key(account)) {
            pending_autojoin_bookmark_writes[account] = new HashMap<Jid, AutojoinBookmarkWrite>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (pending_autojoin_bookmark_writes[account].has_key(bare)) {
            AutojoinBookmarkWrite displaced =
                pending_autojoin_bookmark_writes[account][bare];
            if (displaced.generation != generation) {
                complete_bookmark_write_attempt(account, bare,
                    displaced.generation, false);
            }
        }
        pending_autojoin_bookmark_writes[account][bare] =
            new AutojoinBookmarkWrite(autojoin, nick, password,
                allow_leave_marker, generation, attempts, remove_bookmark,
                recreate_if_missing, name);
        if (!retained_transport_pause) {
            process_next_autojoin_bookmark_write(account, stream, bare);
        }
    }

    private void queue_permanent_bookmark_removal(Account account,
            XmppStream stream, Jid jid, uint generation = 0,
            int attempts = 0) {
        Jid bare = jid.bare_jid;
        uint effective_generation = generation;
        if (effective_generation == 0) {
            effective_generation = get_current_autojoin_write_generation(
                account, bare);
            if (effective_generation == 0) {
                effective_generation = next_autojoin_write_generation(
                    account, bare);
            }
        }
        queue_autojoin_bookmark_write(account, stream, bare, false, null,
            null, true, effective_generation, attempts, true);
    }

    private void register_bookmark_write_completion(Account account, Jid jid,
            BookmarkWriteCompletion completion) {
        Jid bare = jid.bare_jid;
        if (!bookmark_write_completions.has_key(account)) {
            bookmark_write_completions[account] =
                new HashMap<Jid, ArrayList<BookmarkWriteCompletion>>(
                    Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (!bookmark_write_completions[account].has_key(bare)) {
            bookmark_write_completions[account][bare] =
                new ArrayList<BookmarkWriteCompletion>();
        }
        bookmark_write_completions[account][bare].add(completion);
    }

    private void complete_bookmark_write_attempt(Account account, Jid jid,
            uint generation, bool result) {
        Jid bare = jid.bare_jid;
        if (!bookmark_write_completions.has_key(account) ||
                !bookmark_write_completions[account].has_key(bare)) return;
        var completed = new ArrayList<BookmarkWriteCompletion>();
        foreach (BookmarkWriteCompletion completion in
                bookmark_write_completions[account][bare]) {
            if (completion.generation == generation) {
                completed.add(completion);
            }
        }
        foreach (BookmarkWriteCompletion completion in completed) {
            bookmark_write_completions[account][bare].remove(completion);
            completion.complete(result);
        }
        if (bookmark_write_completions[account][bare].is_empty) {
            bookmark_write_completions[account].unset(bare);
        }
        if (bookmark_write_completions[account].is_empty) {
            bookmark_write_completions.unset(account);
        }
    }

    private void complete_all_bookmark_write_attempts(Account account,
            bool result) {
        if (!bookmark_write_completions.has_key(account)) return;
        var completions = new ArrayList<BookmarkWriteCompletion>();
        foreach (ArrayList<BookmarkWriteCompletion> room_completions in
                bookmark_write_completions[account].values) {
            completions.add_all(room_completions);
        }
        bookmark_write_completions.unset(account);
        foreach (BookmarkWriteCompletion completion in completions) {
            completion.complete(result);
        }
    }

    private async bool queue_permanent_bookmark_removal_and_wait(
            Account account, XmppStream stream, Jid jid, uint generation) {
        if (stream_interactor.get_stream(account) != stream ||
                !bookmarks_provider.has_key(account)) return false;
        BookmarkWriteCompletion completion = new BookmarkWriteCompletion(
            generation,
            queue_permanent_bookmark_removal_and_wait.callback);
        register_bookmark_write_completion(account, jid, completion);
        queue_permanent_bookmark_removal(account, stream, jid, generation);
        yield;
        return completion.result;
    }

    private void process_next_autojoin_bookmark_write(Account account, XmppStream stream, Jid jid) {
        if (!bookmarks_provider.has_key(account)) return;
        if (stream_interactor.get_stream(account) != stream) return;
        Jid bare = jid.bare_jid;
        if (active_autojoin_bookmark_writes.has_key(account) &&
                active_autojoin_bookmark_writes[account].has_key(bare)) return;
        if (!pending_autojoin_bookmark_writes.has_key(account) || !pending_autojoin_bookmark_writes[account].has_key(bare)) return;

        AutojoinBookmarkWrite write = pending_autojoin_bookmark_writes[account][bare];
        pending_autojoin_bookmark_writes[account].unset(bare);
        if (pending_autojoin_bookmark_writes[account].size == 0) {
            pending_autojoin_bookmark_writes.unset(account);
        }

        if (!should_continue_autojoin_bookmark_write(account, bare, write)) {
            complete_bookmark_write_attempt(account, bare, write.generation,
                false);
            return;
        }

        if (!active_autojoin_bookmark_writes.has_key(account)) {
            active_autojoin_bookmark_writes[account] =
                new HashMap<Jid, AutojoinBookmarkWrite>(Jid.hash_bare_func,
                    Jid.equals_bare_func);
        }
        active_autojoin_bookmark_writes[account][bare] = write;

        BookmarksProvider provider = bookmarks_provider[account];
        if (write.remove_bookmark) {
            Conference remove_conference = new Conference() { jid=bare };
            provider.remove_conference.begin(stream, remove_conference,
                    (_, res) => {
                bool ok = provider.remove_conference.end(res);
                if (!is_current_bookmark_write_context(account, stream,
                        provider, bare, write)) {
                    handle_invalid_bookmark_write_context(account, stream,
                        bare, write);
                    return;
                }
                if (!should_continue_autojoin_bookmark_write(account, bare,
                        write)) {
                    if (ok && !write.remove_echo_seen) {
                        set_stale_bookmark_remove_echo_fence(account, bare,
                            write.generation);
                    }
                    complete_bookmark_write_attempt(account, bare,
                        write.generation, false);
                    requeue_current_bookmark_intent(account, stream, bare);
                    finish_autojoin_bookmark_write(account, stream, bare,
                        write);
                    return;
                }
                if (ok) {
                    if (!write.remove_echo_seen) {
                        remember_pending_bookmark_remove_echo(account, bare,
                            write);
                    }
                    clear_pending_permanent_bookmark_removal(account, bare);
                    if (is_permanent_leave_marked(account, bare) &&
                            !is_manually_removed_bookmark(account, bare)) {
                        forget_desired_manual_bookmark(account, bare);
                    }
                    if (bookmark_names.has_key(account)) {
                        bookmark_names[account].unset(bare);
                    }
                    remove_bookmarks2_cache_entry(account, bare);
                } else {
                    retry_or_warn_autojoin_bookmark_write(account, bare,
                        write, "remove");
                }
                complete_bookmark_write_attempt(account, bare,
                    write.generation, ok);
                finish_autojoin_bookmark_write(account, stream, bare, write);
            });
            return;
        }

        provider.get_conferences.begin(stream, (_, res) => {
            Set<Conference>? conferences = provider.get_conferences.end(res);
            if (!is_current_bookmark_write_context(account, stream, provider,
                    bare, write)) {
                handle_invalid_bookmark_write_context(account, stream, bare,
                    write);
                return;
            }
            if (!should_continue_autojoin_bookmark_write(account, bare, write)) {
                requeue_current_bookmark_intent(account, stream, bare);
                finish_autojoin_bookmark_write(account, stream, bare, write);
                return;
            }
            if (conferences == null) {
                if (write.autojoin) {
                    Conference changed = new Xep.Bookmarks.Bookmarks1Conference(
                        bare) { nick=write.nick, name=write.name,
                            password=write.password, autojoin=true };
                    add_conference_checked(account, stream, changed, "autojoin-create-fallback", bare, write);
                } else {
                    retry_or_warn_autojoin_bookmark_write(account, bare, write, "read");
                    finish_autojoin_bookmark_write(account, stream, bare,
                        write);
                }
                return;
            }

            foreach (Conference conference in conferences) {
                if (conference.jid.equals(bare)) {
                    bool should_replace = conference.autojoin != write.autojoin ||
                        (write.nick != null && conference.nick != write.nick) ||
                        (write.password != null && conference.password != write.password);
                    if (should_replace) {
                        Conference new_conference = new Conference() { jid=bare, nick=write.nick ?? conference.nick, name=conference.name, password=write.password ?? conference.password, autojoin=write.autojoin };
                        new_conference.name = write.name ?? conference.name;
                        replace_conference_checked(account, stream, bare, new_conference, write);
                    } else {
                        finish_autojoin_bookmark_write(account, stream, bare,
                            write);
                    }
                    return;
                }
            }

            if (write.autojoin || write.recreate_if_missing) {
                Conference changed = new Xep.Bookmarks.Bookmarks1Conference(
                    bare) { nick=write.nick, name=write.name,
                        password=write.password, autojoin=write.autojoin };
                add_conference_checked(account, stream, changed, "autojoin-create", bare, write);
            } else {
                finish_autojoin_bookmark_write(account, stream, bare, write);
            }
        });
    }

    private bool should_continue_autojoin_bookmark_write(Account account, Jid jid, AutojoinBookmarkWrite write) {
        if (!is_current_autojoin_write_generation(account, jid, write.generation)) return false;
        if (write.remove_bookmark) {
            return is_pending_permanent_bookmark_removal(account, jid) ||
                is_manually_removed_bookmark(account, jid);
        }
        if (write.autojoin) {
            return !is_leave_blocked(account, jid);
        }
        if (is_permanent_leave_marked(account, jid) ||
                is_pending_permanent_bookmark_removal(account, jid)) {
            return false;
        }
        if (!write.allow_leave_marker && is_leave_marked(account, jid)) return false;
        return true;
    }

    private bool is_active_autojoin_bookmark_write(Account account, Jid jid,
            AutojoinBookmarkWrite write) {
        Jid bare = jid.bare_jid;
        return active_autojoin_bookmark_writes.has_key(account) &&
            active_autojoin_bookmark_writes[account].has_key(bare) &&
            active_autojoin_bookmark_writes[account][bare] == write;
    }

    private bool is_current_bookmark_write_context(Account account,
            XmppStream stream, BookmarksProvider provider, Jid jid,
            AutojoinBookmarkWrite write) {
        return stream_interactor.get_stream(account) == stream &&
            is_current_bookmark_provider(account, provider) &&
            is_active_autojoin_bookmark_write(account, jid, write);
    }

    private void finish_autojoin_bookmark_write(Account account,
            XmppStream stream, Jid jid, AutojoinBookmarkWrite write) {
        Jid bare = jid.bare_jid;
        if (!is_active_autojoin_bookmark_write(account, bare, write)) return;
        active_autojoin_bookmark_writes[account].unset(bare);
        if (active_autojoin_bookmark_writes[account].size == 0) {
            active_autojoin_bookmark_writes.unset(account);
        }
        if (stream_interactor.get_stream(account) == stream) {
            process_next_autojoin_bookmark_write(account, stream, bare);
        }
    }

    private void retry_or_warn_autojoin_bookmark_write(Account account, Jid jid, AutojoinBookmarkWrite write, string phase) {
        if (!should_continue_autojoin_bookmark_write(account, jid, write)) return;
        if (write.attempts < 2) {
            uint next_attempt = (uint) (write.attempts + 1);
            Timeout.add_seconds(5U * next_attempt, () => {
                XmppStream? retry_stream = stream_interactor.get_stream(account);
                if (retry_stream != null && bookmarks_provider.has_key(account) && should_continue_autojoin_bookmark_write(account, jid, write)) {
                    queue_autojoin_bookmark_write(account, retry_stream, jid,
                        write.autojoin, write.nick, write.password,
                        write.allow_leave_marker, write.generation,
                        write.attempts + 1, write.remove_bookmark,
                        write.recreate_if_missing, write.name);
                }
                return false;
            });
            return;
        }
        warning("Failed to sync MUC bookmark %s for %s during %s",
            write.remove_bookmark ? "removal" :
                "autojoin=" + write.autojoin.to_string(),
            jid.to_string(), phase);
    }

    private bool requeue_current_bookmark_intent(Account account,
            XmppStream stream, Jid jid) {
        if (stream_interactor.get_stream(account) != stream ||
                !bookmarks_provider.has_key(account)) return false;
        Jid bare = jid.bare_jid;
        uint generation = get_current_autojoin_write_generation(account,
            bare);
        if (generation == 0) {
            generation = next_autojoin_write_generation(account, bare);
        }
        if (pending_autojoin_bookmark_writes.has_key(account) &&
                pending_autojoin_bookmark_writes[account].has_key(bare) &&
                pending_autojoin_bookmark_writes[account][bare].generation ==
                    generation) return true;
        if (is_permanent_leave_marked(account, bare) ||
                is_pending_permanent_bookmark_removal(account, bare) ||
                is_manually_removed_bookmark(account, bare)) {
            queue_permanent_bookmark_removal(account, stream, bare,
                generation);
            return true;
        }
        if (is_leave_marked(account, bare)) {
            queue_autojoin_bookmark_write(account, stream, bare, false, null,
                null, true, generation);
            return true;
        }
        Conference? desired = get_desired_manual_bookmark(account, bare);
        if (desired != null) {
            Conference current = (!) desired;
            queue_autojoin_bookmark_write(account, stream, bare,
                current.autojoin, current.nick, current.password, false,
                generation, 0, false, true, current.name);
            return true;
        }
        return false;
    }

    private void handle_invalid_bookmark_write_context(Account account,
            XmppStream stream, Jid jid, AutojoinBookmarkWrite write) {
        Jid bare = jid.bare_jid;
        bool still_active = is_active_autojoin_bookmark_write(account, bare,
            write);
        bool requeued = false;
        if (still_active && stream_interactor.get_stream(account) == stream &&
                bookmarks_provider.has_key(account)) {
            requeued = requeue_current_bookmark_intent(account, stream,
                bare);
        }
        if (!requeued) {
            complete_bookmark_write_attempt(account, bare, write.generation,
                false);
        }
        finish_autojoin_bookmark_write(account, stream, bare, write);
    }

    private void add_conference_checked(Account account, XmppStream stream, Conference conference, string reason, Jid? autojoin_jid = null, AutojoinBookmarkWrite? autojoin_write = null) {
        if (!bookmarks_provider.has_key(account)) return;
        BookmarksProvider provider = bookmarks_provider[account];
        provider.add_conference.begin(stream, conference, (_, res) => {
            bool ok = provider.add_conference.end(res);
            if (autojoin_jid != null && autojoin_write != null) {
                Jid bare = ((!) autojoin_jid).bare_jid;
                AutojoinBookmarkWrite write = (!) autojoin_write;
                if (!is_current_bookmark_write_context(account, stream,
                        provider, bare, write)) {
                    handle_invalid_bookmark_write_context(account, stream,
                        bare, write);
                    return;
                }
                if (!should_continue_autojoin_bookmark_write(account, bare, write)) {
                    if (ok) requeue_current_bookmark_intent(account, stream,
                        bare);
                    finish_autojoin_bookmark_write(account, stream, bare,
                        write);
                    return;
                }
                if (!ok) retry_or_warn_autojoin_bookmark_write(account, bare, write, reason);
                finish_autojoin_bookmark_write(account, stream, bare, write);
                return;
            }
            if (stream_interactor.get_stream(account) != stream ||
                    !is_current_bookmark_provider(account, provider)) return;
            if (!ok && conference.jid != null) {
                warning("Failed to add MUC bookmark for %s during %s", ((!) conference.jid).to_string(), reason);
            }
        });
    }

    private void replace_conference_checked(Account account, XmppStream stream, Jid jid, Conference conference, AutojoinBookmarkWrite write) {
        BookmarksProvider provider = bookmarks_provider[account];
        provider.replace_conference.begin(stream, jid, conference, (_, res) => {
            bool ok = provider.replace_conference.end(res);
            if (!is_current_bookmark_write_context(account, stream, provider,
                    jid, write)) {
                handle_invalid_bookmark_write_context(account, stream, jid,
                    write);
                return;
            }
            if (!should_continue_autojoin_bookmark_write(account, jid, write)) {
                if (ok) requeue_current_bookmark_intent(account, stream, jid);
                finish_autojoin_bookmark_write(account, stream, jid, write);
                return;
            }
            if (!ok) retry_or_warn_autojoin_bookmark_write(account, jid, write, "replace");
            finish_autojoin_bookmark_write(account, stream, jid, write);
        });
    }

    private void remove_conference_checked(Account account, XmppStream stream,
            Conference conference, string reason) {
        if (!bookmarks_provider.has_key(account)) return;
        BookmarksProvider provider = bookmarks_provider[account];
        provider.remove_conference.begin(stream, conference, (_, res) => {
            bool ok = provider.remove_conference.end(res);
            if (stream_interactor.get_stream(account) != stream ||
                    !is_current_bookmark_provider(account, provider)) return;
            if (conference.jid == null) return;

            Jid bare = ((!) conference.jid).bare_jid;
            if (!ok) warning("Failed to remove MUC bookmark for %s during %s",
                bare.to_string(), reason);
        });
    }

    private uint next_autojoin_write_generation(Account account, Jid jid) {
        if (!autojoin_write_generations.has_key(account)) {
            autojoin_write_generations[account] = new HashMap<Jid, uint>(Jid.hash_bare_func, Jid.equals_bare_func);
        }

        Jid bare = jid.bare_jid;
        uint next = autojoin_write_generations[account].has_key(bare) ? autojoin_write_generations[account][bare] + 1 : 1;
        if (next == 0) next = 1;
        autojoin_write_generations[account][bare] = next;
        return next;
    }

    private uint get_current_autojoin_write_generation(Account account, Jid jid) {
        if (!autojoin_write_generations.has_key(account)) return 0;
        Jid bare = jid.bare_jid;
        return autojoin_write_generations[account].has_key(bare) ? autojoin_write_generations[account][bare] : 0;
    }

    private bool is_current_autojoin_write_generation(Account account, Jid jid, uint generation) {
        if (!autojoin_write_generations.has_key(account)) return false;
        Jid bare = jid.bare_jid;
        return autojoin_write_generations[account].has_key(bare) &&
            autojoin_write_generations[account][bare] == generation;
    }

    private void on_conference_added(Account account, Xmpp.Conference conference) {
        if (is_manually_removed_bookmark(account, conference.jid)) {
            clear_manually_removed_bookmark(account, conference.jid);
            remove_bookmarks2_cache_entry(account, conference.jid);
            remove_queued_autojoin_candidate(account, conference.jid);
            if (mark_manual_bookmark_removal_notification(account,
                    conference.jid)) {
                conference_removed(account, conference.jid);
            }
            return;
        }
        if (is_permanent_leave_marked(account, conference.jid) ||
                is_pending_permanent_bookmark_removal(account,
                    conference.jid)) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null && bookmarks_provider.has_key(account)) {
                mark_pending_permanent_bookmark_removal(account,
                    conference.jid);
                queue_permanent_bookmark_removal(account, stream,
                    conference.jid);
            }
            remove_queued_autojoin_candidate(account, conference.jid);
            return;
        }
        if (is_leave_marked(account, conference.jid)) {
            if (conference.autojoin) {
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream != null && bookmarks_provider.has_key(account)) {
                    unset_autojoin(account, stream, conference.jid, true);
                }
            }
            conference_added(account, conference);
            return;
        }

        clear_manual_bookmark_removal_notification(account, conference.jid);

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(conference.jid, account, Conversation.Type.GROUPCHAT);
        bool should_queue_autojoin = false;
        if (conversation != null) {
            if (!conversation.active && conference.autojoin) {
                should_queue_autojoin = false;
            }
        } else if (conference.autojoin) {
            should_queue_autojoin = true;
        }
        if (should_queue_autojoin) {
            var candidates = new ArrayList<Conference>();
            var candidate_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
            add_autojoin_candidate(candidates, candidate_jids, conference);
            queue_autojoin_candidates(account, candidates, AutojoinPriority.BACKGROUND);
        }
        conference_added(account, conference);
    }

    private void on_conference_removed(Account account, Jid jid) {
        // Removing a bookmark is not the same operation as leaving an active room.
        // UI paths that intentionally leave call part() explicitly before removing.
        remove_queued_autojoin_candidate(account, jid);
        Jid bare = jid.bare_jid;
        if (active_manual_bookmark_removals.has_key(account) &&
                active_manual_bookmark_removals[account].has_key(bare)) {
            AutojoinBookmarkWrite manual =
                active_manual_bookmark_removals[account][bare];
            manual.remove_echo_seen = true;
            if (!is_current_autojoin_write_generation(account, bare,
                    manual.generation)) return;
        }
        if (active_autojoin_bookmark_writes.has_key(account) &&
                active_autojoin_bookmark_writes[account].has_key(bare)) {
            AutojoinBookmarkWrite active =
                active_autojoin_bookmark_writes[account][bare];
            if (active.remove_bookmark &&
                    (is_permanent_leave_marked(account, bare) ||
                     is_pending_permanent_bookmark_removal(account, bare) ||
                     !is_current_autojoin_write_generation(account, bare,
                        active.generation))) {
                active.remove_echo_seen = true;
                return;
            }
        }
        if (consume_stale_bookmark_remove_echo_fence(account, bare)) return;
        if (is_permanent_leave_marked(account, bare) ||
                is_pending_permanent_bookmark_removal(account, bare)) return;
        if (is_manually_removed_bookmark(account, bare) ||
                (manual_bookmark_removal_notified.has_key(account) &&
                 manual_bookmark_removal_notified[account].contains(bare))) {
            if (mark_manual_bookmark_removal_notification(account, bare)) {
                conference_removed(account, bare);
            }
            return;
        }
        conference_removed(account, jid);
    }

    internal void handle_conference_added_for_tests(Account account, Xmpp.Conference conference) {
        on_conference_added(account, conference);
    }

    internal void handle_conference_removed_for_tests(Account account, Jid jid) {
        on_conference_removed(account, jid);
    }

    internal void handle_bookmark_snapshot_for_tests(Account account,
            Set<Conference> conferences) {
        sync_autojoin_active(account, conferences);
    }

    internal void set_bookmarks_provider_for_tests(Account account,
            BookmarksProvider provider) {
        bookmarks_provider[account] = provider;
    }

    internal bool is_permanent_leave_marked_for_tests(Account account,
            Jid room) {
        return is_permanent_leave_marked(account, room);
    }

    internal bool is_pending_permanent_bookmark_removal_for_tests(
            Account account, Jid room) {
        return is_pending_permanent_bookmark_removal(account, room);
    }

    internal void set_muc_occupant_room_generation_for_tests(Account account,
            Jid room, uint generation) {
        muc_occupant_room_generations[muc_occupant_room_key(account.id,
            room.bare_jid.to_string())] = generation;
    }

    internal void advance_muc_occupant_room_generation_for_tests(
            Account account, Jid room) {
        string key = muc_occupant_room_key(account.id,
            room.bare_jid.to_string());
        uint next = muc_occupant_room_generations.has_key(key)
            ? muc_occupant_room_generations[key] + 1
            : 1;
        if (next == 0) next = 1;
        muc_occupant_room_generations[key] = next;
    }

    internal void reject_muc_occupant_worker_starts_for_tests() {
        muc_occupant_worker.shutdown();
    }

    internal void queue_autojoin_candidate_for_tests(Account account, Conference conference, bool active) {
        var candidates = new ArrayList<Conference>();
        candidates.add(conference);
        queue_autojoin_candidates(account, candidates,
            active ? AutojoinPriority.ACTIVE : AutojoinPriority.BACKGROUND);
    }

    internal Jid? peek_autojoin_candidate_for_tests(Account account) {
        if (!autojoin_queues.has_key(account) || autojoin_queues[account].is_empty) return null;
        Jid? jid = autojoin_queues[account][0].conference.jid;
        return jid != null ? ((!) jid).bare_jid : null;
    }

    internal async void process_next_autojoin_for_tests(Account account) {
        clear_scheduled_autojoin_queue(account);
        yield process_next_autojoin(account);
    }

    internal uint autojoin_delay_for_tests(Account account, uint fallback_delay_ms) {
        return autojoin_delay_for_next(account, fallback_delay_ms);
    }

    internal int autojoin_source_priority_for_tests(Account account) {
        return autojoin_source_priority_for_next(account);
    }

    internal void clear_transient_muc_runtime_state_for_tests(Account account) {
        clear_transient_muc_runtime_state(account);
    }

    internal bool has_joined_runtime_for_tests(Account account, Jid room) {
        if (!mucs_joined.has_key(account)) return false;
        foreach (Jid joined_jid in mucs_joined[account]) {
            if (joined_jid.equals_bare(room)) return true;
        }
        return false;
    }

    internal bool has_pending_muc_mam_sync_for_tests(Account account,
            Jid room) {
        return pending_muc_mam_syncs.has_key(account) &&
            pending_muc_mam_syncs[account].contains(room.bare_jid);
    }

    internal bool has_muc_mam_retry_scheduled_for_tests(Account account,
            Jid room) {
        return muc_mam_retry_sources.has_key(account) &&
            muc_mam_retry_sources[account].has_key(room.bare_jid);
    }

    internal void clear_autojoin_queue_for_tests(Account account) {
        clear_scheduled_autojoin_queue(account);
        autojoin_queue_active.remove(account);
        autojoin_queues.unset(account);
        if (foreground_autojoin_account != null && ((!) foreground_autojoin_account).equals(account)) {
            foreground_autojoin_account = null;
            foreground_autojoin_room = null;
        }
    }

    internal async Muc.JoinResult? force_rejoin_for_tests(Account account, Jid jid, string? nick, string? password = null) {
        return yield join_internal(account, jid, nick, password, true, null, true);
    }

    private void on_build_message_stanza(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            Xmpp.Xep.Muc.add_muc_pm_message_stanza_x_node(message_stanza);            
        }
        if (conversation.type_ == Conversation.Type.GROUPCHAT && message.body != null) {
            Gee.List<Jid>? occupants = get_occupants(conversation.counterpart, conversation.account);
            if (occupants != null) {
                foreach (Jid occupant in occupants) {
                    if (occupant.resourcepart == null || occupant.resourcepart == "") continue;
                    int start, end;
                    if (!MessageMentions.find_nickname_in_message(message,
                            (!) occupant.resourcepart, out start, out end)) continue;

                    var reference = new Xmpp.Xep.References.Reference();
                    reference.type_ = "mention";
                    Jid? real_jid = get_real_jid(occupant, conversation.account);
                    reference.uri = MessageMentions.reference_uri(real_jid != null
                        ? ((!) real_jid).bare_jid : occupant);
                    reference.begin = start.to_string();
                    reference.end = end.to_string();
                    Xmpp.Xep.References.add_reference(message_stanza, reference);
                }
            }
        }
    }

    private void self_ping(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        if (!mucs_joined.has_key(account)) return;

        var joined_snapshot = new ArrayList<Jid>(Jid.equals_func);
        foreach (Jid jid in mucs_joined[account]) {
            joined_snapshot.add(jid);
        }

        foreach (Jid joined_jid in joined_snapshot) {
            if (!mucs_joined.has_key(account) || !mucs_joined[account].contains(joined_jid)) continue;
            if (!mark_muc_self_ping_started(account, joined_jid)) continue;

            check_muc_self_ping.begin(account, stream, joined_jid,
                get_muc_self_ping_generation(account));
        }
    }

    private async void check_muc_self_ping(Account account, XmppStream stream,
            Jid jid, uint generation) {
        Xmpp.Xep.MucSelfPing.JoinState join_state = yield Xmpp.Xep.MucSelfPing.get_join_state(stream, jid);
        if (generation != get_muc_self_ping_generation(account)) return;
        clear_muc_self_ping(account, jid);
        if (join_state == Xmpp.Xep.MucSelfPing.JoinState.JOINED) return;
        if (!mucs_joined.has_key(account) || !mucs_joined[account].contains(jid)) return;
        if (stream_interactor.get_stream(account) != stream) return;
        Jid? current_jid = null;
        foreach (Jid joined_jid in mucs_joined[account]) {
            if (joined_jid.equals_bare(jid)) {
                current_jid = joined_jid;
                break;
            }
        }
        if (current_jid == null || ((!) current_jid).resourcepart != jid.resourcepart) {
            debug("Ignoring stale MUC self-ping result for %s on %s", jid.to_string(), account.bare_jid.to_string());
            return;
        }
        if (join_state == Xmpp.Xep.MucSelfPing.JoinState.UNKNOWN) {
            debug("MUC self-ping returned unknown state for %s on %s; keeping local joined state", jid.to_string(), account.bare_jid.to_string());
            return;
        }

        join_internal.begin(account, jid.bare_jid, ((!) current_jid).resourcepart, null, true, null, true);
    }

    private uint get_muc_self_ping_generation(Account account) {
        return muc_self_ping_generations.has_key(account.id)
            ? muc_self_ping_generations[account.id]
            : 0;
    }

    private void bump_muc_self_ping_generation(Account account) {
        uint next = get_muc_self_ping_generation(account) + 1;
        if (next == 0) next = 1;
        muc_self_ping_generations[account.id] = next;
    }

    private bool mark_muc_self_ping_started(Account account, Jid jid) {
        if (!muc_self_pings_in_flight.has_key(account)) {
            muc_self_pings_in_flight[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (muc_self_pings_in_flight[account].contains(jid)) return false;
        muc_self_pings_in_flight[account].add(jid);
        return true;
    }

    private void clear_muc_self_ping(Account account, Jid jid) {
        if (!muc_self_pings_in_flight.has_key(account)) return;
        muc_self_pings_in_flight[account].remove(jid);
        if (muc_self_pings_in_flight[account].is_empty) muc_self_pings_in_flight.unset(account);
    }

    private string muc_occupant_room_key(int account_id, string room_bare_jid) {
        return account_id.to_string() + "\n" + room_bare_jid;
    }

    private bool start_muc_occupant_room(Account account, Jid room,
            bool interactive_priority, bool allow_leave_block_override) {
        if (muc_occupant_shutdown) return false;

        Jid bare_room = room.bare_jid;
        string logical_key = muc_occupant_room_key(account.id, bare_room.to_string());
        MucOccupantRoom? previous = muc_occupant_rooms[logical_key];

        uint room_generation = muc_occupant_room_generations.has_key(logical_key)
            ? muc_occupant_room_generations[logical_key] + 1
            : 1;
        if (room_generation == 0) room_generation = 1;

        var worker_key = new MucRoomKey(account.id, account.bare_jid.to_string(),
            bare_room.to_string(), (uint64) get_muc_runtime_generation(account),
            (uint64) room_generation);
        var binding = new MucOccupantRoom(account, bare_room, worker_key,
            interactive_priority, allow_leave_block_override,
            can_retain_room_real_jids(account, bare_room)
                ? MucRealJidRetentionAuthority.ALLOWED
                : MucRealJidRetentionAuthority.DENIED);

        // The worker command is the transaction's prepare step. Until it is
        // accepted, retain the old binding, snapshot, Presence projection and
        // public generation unchanged.
        if (!muc_occupant_worker.start_room(worker_key)) {
            warning("MUC occupant worker rejected room start for %s", bare_room.to_string());
            return false;
        }

        if (previous != null) remove_muc_occupant_room((!) previous, false);
        muc_occupant_snapshots.unset(logical_key);
        muc_occupant_room_generations[logical_key] = room_generation;
        muc_occupant_rooms[logical_key] = binding;
        room_initial_sync_started(account, bare_room);
        muc_occupant_worker.start();
        update_muc_occupant_event_capture(account);
        return true;
    }

    private MucOccupantRoom? get_muc_occupant_room(Account account, Jid room) {
        return muc_occupant_rooms[muc_occupant_room_key(account.id,
            room.bare_jid.to_string())];
    }

    private bool finish_muc_occupant_room(MucRoomKey expected_key,
            bool degraded_partial) {
        string logical_key = muc_occupant_room_key(expected_key.account_id,
            expected_key.room_bare_jid);
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null || !((!) binding).worker_key.matches(expected_key) ||
                ((!) binding).finish_requested) return false;

        ShadowMucAggregate? comparison = shadow_muc_stats_enabled
            ? capture_shadow_muc_aggregate((!) binding)
            : null;
        if (muc_occupant_worker.finish_room(expected_key, degraded_partial)) {
            ((!) binding).comparison = comparison;
            ((!) binding).finish_requested = true;
            return true;
        }
        return false;
    }

    private ShadowMucAggregate capture_shadow_muc_aggregate(MucOccupantRoom binding) {
        var result = new ShadowMucAggregate();
        Gee.List<Jid>? direct_occupants = get_occupants(binding.room, binding.account);
        if (direct_occupants == null) return result;

        result.occupants = (uint) ((!) direct_occupants).size;
        foreach (Jid occupant in (!) direct_occupants) {
            if (has_affiliation(binding.room, occupant, binding.account)) {
                result.affiliations++;
            }
            if (has_role(occupant, binding.account)) result.roles++;
            if (get_real_jid(occupant, binding.account) != null) result.real_jids++;
            if (!get_hats(occupant, binding.account).is_empty) result.hats++;
        }
        return result;
    }

    private void remove_muc_occupant_room(MucOccupantRoom binding,
            bool remove_snapshot) {
        string logical_key = muc_occupant_room_key(binding.account.id,
            binding.room.to_string());
        MucOccupantRoom? current = muc_occupant_rooms[logical_key];
        if (current == null || ((!) current) != binding) return;

        if (binding.commit_source_id != 0) {
            Source.remove(binding.commit_source_id);
            binding.commit_source_id = 0;
        }
        if (binding.live_flush_source_id != 0) {
            Source.remove(binding.live_flush_source_id);
            binding.live_flush_source_id = 0;
        }
        binding.live_flush_pending = false;
        muc_occupant_rooms.unset(logical_key);
        if (remove_snapshot) muc_occupant_snapshots.unset(logical_key);
        update_muc_occupant_event_capture(binding.account);
        if (!muc_occupant_shutdown) {
            muc_occupant_worker.cancel_room(binding.worker_key);
        }
    }

    private void cancel_muc_occupant_room(Account account, Jid room,
            bool remove_snapshot = true) {
        string logical_key = muc_occupant_room_key(account.id,
            room.bare_jid.to_string());
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding != null) remove_muc_occupant_room((!) binding, remove_snapshot);
        else if (remove_snapshot) muc_occupant_snapshots.unset(logical_key);
    }

    private void cancel_muc_occupant_account(Account account) {
        var remove_keys = new ArrayList<string>();
        foreach (var entry in muc_occupant_rooms.entries) {
            if (entry.value.account.id == account.id) remove_keys.add(entry.key);
        }
        foreach (string remove_key in remove_keys) {
            MucOccupantRoom? binding = muc_occupant_rooms[remove_key];
            if (binding != null && ((!) binding).commit_source_id != 0) {
                Source.remove(((!) binding).commit_source_id);
                ((!) binding).commit_source_id = 0;
            }
            if (binding != null && ((!) binding).live_flush_source_id != 0) {
                Source.remove(((!) binding).live_flush_source_id);
                ((!) binding).live_flush_source_id = 0;
            }
            muc_occupant_rooms.unset(remove_key);
        }

        string prefix = account.id.to_string() + "\n";
        var snapshot_keys = new ArrayList<string>();
        foreach (string key in muc_occupant_snapshots.keys) {
            if (key.has_prefix(prefix)) snapshot_keys.add(key);
        }
        foreach (string key in snapshot_keys) muc_occupant_snapshots.unset(key);

        update_muc_occupant_event_capture(account);
        if (!muc_occupant_shutdown) {
            muc_occupant_worker.cancel_account(account.id, account.bare_jid.to_string());
        }
    }

    private void remove_muc_occupant_generations(int account_id) {
        string prefix = account_id.to_string() + "\n";
        var remove_keys = new ArrayList<string>();
        foreach (string key in muc_occupant_room_generations.keys) {
            if (key.has_prefix(prefix)) remove_keys.add(key);
        }
        foreach (string remove_key in remove_keys) {
            muc_occupant_room_generations.unset(remove_key);
        }
    }

    private void update_muc_occupant_event_capture(Account account) {
        bool enabled = false;
        foreach (MucOccupantRoom binding in muc_occupant_rooms.values) {
            if (binding.account.equals(account)) {
                enabled = true;
                break;
            }
        }
        Xep.Muc.Module muc_module = stream_interactor.module_manager.get_module<Xep.Muc.Module>(
            account, Xep.Muc.Module.IDENTITY);
        muc_module.occupant_presence_events_enabled = enabled;
    }

    private bool defer_occupant_compatibility_signal(Account account,
            Jid occupant) {
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            occupant.bare_jid);
        return binding != null && (!((!) binding).initial_commit_complete ||
            ((!) binding).live_batching_enabled);
    }

    private bool is_current_own_muc_jid(Account account, Jid occupant) {
        Jid? own_jid = get_own_jid(occupant.bare_jid, account);
        return own_jid != null && ((!) own_jid).equals(occupant);
    }

    private MucOccupantRoom? get_current_occupant_id_binding(Account account,
            Jid occupant) {
        if (!occupant.is_full()) return null;
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            occupant.bare_jid);
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) return null;
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return null;
        Presence.Flag presence_flag = ((!) stream).get_flag(
            Presence.Flag.IDENTITY);
        if (presence_flag.get_presence(occupant) == null) return null;
        return binding;
    }

    private void record_current_occupant_id(Account account, Jid occupant,
            string occupant_id, bool own_occupant) {
        MucOccupantRoom? binding = get_current_occupant_id_binding(account,
            occupant);
        if (binding == null) return;
        if (own_occupant && !is_current_own_muc_jid(account, occupant)) return;

        ((!) binding).pending_occupant_ids[occupant] = occupant_id;
        if (own_occupant) {
            ((!) binding).pending_own_occupant_jid = occupant;
            ((!) binding).pending_own_occupant_id = occupant_id;
        }
        resolve_pending_occupant_ids(account, occupant.bare_jid);
    }

    private void resolve_pending_occupant_ids(Account account, Jid room) {
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            room.bare_jid);
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) return;

        Xep.Muc.Flag? flag = get_muc_flag(account);
        if (flag == null || !((!) flag).has_current_room_features(room)) {
            // The matching discovery query is still in flight. Keep the IDs
            // only inside this generation-bound binding until proof arrives.
            return;
        }

        if (((!) flag).has_room_feature(room,
                Xep.Muc.Feature.OCCUPANT_ID)) {
            var pending = new ArrayList<Jid>(Jid.equals_func);
            pending.add_all(((!) binding).pending_occupant_ids.keys);
            foreach (Jid occupant in pending) {
                if (get_current_occupant_id_binding(account, occupant) ==
                        binding) {
                    remember_private_message_peer_identity(account, occupant,
                        "occupant-id:" +
                            ((!) binding).pending_occupant_ids[occupant]);
                }
            }
            if (((!) binding).pending_own_occupant_jid != null &&
                    ((!) binding).pending_own_occupant_id != null &&
                    is_current_own_muc_jid(account,
                        (!) ((!) binding).pending_own_occupant_jid)) {
                if (!own_occupant_ids.has_key(account)) {
                    own_occupant_ids[account] = new HashMap<Jid, string>(
                        Jid.hash_bare_func, Jid.equals_bare_func);
                }
                own_occupant_ids[account][
                    (!) ((!) binding).pending_own_occupant_jid] =
                    (!) ((!) binding).pending_own_occupant_id;
            }
        }

        // A current negative feature result is authoritative too: XEP-0421
        // requires ignoring unadvertised occupant-id elements.
        ((!) binding).pending_occupant_ids.clear();
        ((!) binding).pending_own_occupant_jid = null;
        ((!) binding).pending_own_occupant_id = null;
    }

    /** Current privacy authority for a natively authenticated sender mapping. */
    public bool may_retain_authenticated_message_real_jid(Account account, Jid room) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        return flag != null && ((!) flag).has_current_room_features(room.bare_jid) &&
            muc_flag_can_retain_room_real_jids((!) flag, room.bare_jid);
    }

    private bool can_retain_room_real_jids(Account account, Jid room) {
        Xep.Muc.Flag? flag = get_muc_flag(account);
        return flag != null && muc_flag_can_retain_room_real_jids((!) flag,
            room);
    }

    private bool muc_flag_can_retain_room_real_jids(Xep.Muc.Flag flag,
            Jid room) {
        switch (flag.get_real_jid_visibility(room)) {
            case Xep.Muc.RealJidVisibility.ANYONE:
                return true;
            case Xep.Muc.RealJidVisibility.MODERATORS:
                string? own_nick = flag.get_muc_nick(room);
                if (own_nick == null) return false;
                try {
                    Jid own_jid = room.bare_jid.with_resource((!) own_nick);
                    return flag.has_occupant_role(own_jid) &&
                        flag.get_occupant_role(own_jid) ==
                            Xep.Muc.Role.MODERATOR;
                } catch (InvalidJidError e) {
                    return false;
                }
            case Xep.Muc.RealJidVisibility.NOBODY:
            case Xep.Muc.RealJidVisibility.UNKNOWN:
            default:
                return false;
        }
    }

    private void set_muc_real_jid_retention_authority(Account account,
            Jid room, MucRealJidRetentionAuthority authority) {
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            room.bare_jid);
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) return;
        ((!) binding).real_jid_retention_authority = authority;
    }

    private void refresh_muc_real_jid_retention_authority(Account account,
            Jid room, XmppStream? retained_stream = null) {
        // A missing live stream means transport pause, not a new privacy
        // decision. Keep the last generation-scoped authority until either a
        // current stream updates it or fresh-stream teardown removes binding.
        Xep.Muc.Flag? flag = retained_stream != null
            ? ((!) retained_stream).get_flag(Xep.Muc.Flag.IDENTITY)
            : get_muc_flag(account);
        if (flag == null) return;
        set_muc_real_jid_retention_authority(account, room,
            muc_flag_can_retain_room_real_jids((!) flag, room)
                ? MucRealJidRetentionAuthority.ALLOWED
                : MucRealJidRetentionAuthority.DENIED);
    }

    private bool binding_can_retain_room_real_jids(MucOccupantRoom binding) {
        if (stream_interactor.get_stream(binding.account) != null) {
            binding.real_jid_retention_authority =
                can_retain_room_real_jids(binding.account, binding.room)
                    ? MucRealJidRetentionAuthority.ALLOWED
                    : MucRealJidRetentionAuthority.DENIED;
        }
        return binding.real_jid_retention_authority ==
            MucRealJidRetentionAuthority.ALLOWED;
    }

    private MucOccupantSnapshot without_snapshot_real_jid(
            MucOccupantSnapshot snapshot) {
        if (snapshot.real_bare_jid == null) return snapshot;
        return new MucOccupantSnapshot(snapshot.occupant_full_jid,
            snapshot.room_bare_jid, snapshot.nick, null,
            snapshot.affiliation, snapshot.affiliation_known, snapshot.role,
            snapshot.role_known, snapshot.dup_hat_uris(),
            snapshot.dup_hat_titles(), snapshot.avatar_hash,
            snapshot.available, snapshot.last_seen_monotonic_us,
            snapshot.dup_hat_hues());
    }

    /**
     * Worker output may have been queued before a room privacy transition.
     * Sanitize it again on the main-context authority boundary so an old FIFO
     * delta can never repopulate a display snapshot after access was revoked.
     */
    private MucRoomDelta sanitize_room_delta_real_jids(
            MucOccupantRoom binding, MucRoomDelta delta) {
        if (binding_can_retain_room_real_jids(binding)) {
            return delta;
        }

        bool changed_any = false;
        var changed = new ArrayList<MucOccupantSnapshot>();
        var changed_flags = new ArrayList<int>();
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot before = delta.changed_at(i);
            MucOccupantSnapshot after = without_snapshot_real_jid(before);
            changed_any = changed_any || after != before;
            changed.add(after);
            changed_flags.add((int) delta.changed_flags_at(i));
        }
        if (!changed_any) return delta;

        return new MucRoomDelta(delta.room, delta.revision,
            delta.initial_sync_started, delta.initial_snapshot_ready,
            delta.initial_sync_finished, delta.degraded_partial,
            delta.full_snapshot, delta.occupant_count, changed.to_array(),
            delta.dup_removed_occupant_full_jids(),
            changed_flags.to_array());
    }

    private void scrub_room_snapshot_real_jids(Account account, Jid room) {
        string logical_key = muc_occupant_room_key(account.id,
            room.bare_jid.to_string());
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) {
            muc_occupant_snapshots.unset(logical_key);
            return;
        }

        var occupant_ids = new ArrayList<string>();
        occupant_ids.add_all(((!) binding).stable_occupants.keys);
        bool changed = false;
        foreach (string occupant_id in occupant_ids) {
            MucOccupantSnapshot before =
                ((!) binding).stable_occupants[occupant_id];
            MucOccupantSnapshot after = without_snapshot_real_jid(before);
            if (after == before) continue;
            ((!) binding).stable_occupants[occupant_id] = after;
            changed = true;
        }
        if (!changed) return;

        ((!) binding).materialized_snapshot = null;
        muc_occupant_snapshots.unset(logical_key);
    }

    /** Display snapshot only; never use this as an OMEMO membership proof. */
    public MucRoomDelta? get_room_occupants_snapshot(Account account, Jid room) {
        string logical_key = muc_occupant_room_key(account.id,
            room.bare_jid.to_string());
        MucRoomDelta? snapshot = muc_occupant_snapshots[logical_key];
        if (snapshot != null) return snapshot;

        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null || !((!) binding).initial_snapshot_committed ||
                !is_current_muc_occupant_room((!) binding,
                    ((!) binding).worker_key)) return null;
        if (((!) binding).materialized_snapshot != null) {
            return ((!) binding).materialized_snapshot;
        }

        var occupant_ids = new ArrayList<string>();
        occupant_ids.add_all(((!) binding).stable_occupants.keys);
        occupant_ids.sort((left, right) => strcmp(left, right));
        var occupants = new ArrayList<MucOccupantSnapshot>();
        foreach (string occupant_id in occupant_ids) {
            occupants.add(((!) binding).stable_occupants[occupant_id]);
        }
        var materialized = new MucRoomDelta(((!) binding).worker_key,
            ((!) binding).stable_revision, true, true, true, false, true,
            (uint) occupants.size, occupants.to_array());
        ((!) binding).materialized_snapshot = materialized;
        muc_occupant_snapshots[logical_key] = materialized;
        return materialized;
    }

    /**
     * Current display-worker lifecycle for one room. UI caches may only be
     * reused while both generations still match this immutable key. A null
     * result means that no current lifecycle can vouch for cached rows.
     */
    public MucRoomKey? get_room_occupant_generation(Account account,
            Jid room) {
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            room.bare_jid);
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) return null;
        return ((!) binding).worker_key;
    }

    private void on_muc_occupant_presence(Account account, XmppStream stream,
            Xep.Muc.OccupantPresenceEvent event) {
        if (muc_occupant_shutdown ||
                !is_tracked_account_stream(account, stream)) return;

        string logical_key = muc_occupant_room_key(account.id,
            event.room_bare_jid);
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null) return;
        if (!is_current_muc_occupant_room((!) binding,
                ((!) binding).worker_key)) return;
        refresh_muc_real_jid_retention_authority(account, ((!) binding).room,
            stream);
        bool collecting_initial = !((!) binding).finish_requested;

        // Canonicalize all normal occupant nicknames on the main context from
        // the already parsed full JID.  Only an unavailable 303 transition may
        // use the separate <item nick='...'> value, and that replacement must
        // pass JID resourceprep before a data-only string crosses the worker
        // boundary.  Bare room service presences are rejected here as well.
        string? canonical_nick = event.nick;
        Jid? peer = null;
        if (event.kind == Xep.Muc.OccupantPresenceKind.AVAILABLE ||
                event.kind == Xep.Muc.OccupantPresenceKind.UNAVAILABLE) {
            try {
                Jid occupant = new Jid(event.occupant_full_jid);
                if (!occupant.is_full() ||
                        !((!) binding).room.equals_bare(occupant) ||
                        occupant.resourcepart == null) return;
                canonical_nick = occupant.resourcepart;
                peer = occupant;
            } catch (InvalidJidError e) {
                return;
            }
        }
        int[] status_codes = event.dup_status_codes();
        bool is_self_presence = event.is_self_presence;
        bool nickname_transition = false;
        foreach (int status_code in status_codes) {
            if (status_code == (int) Xep.Muc.StatusCode.ROOM_NICKNAME) {
                nickname_transition = true;
            }
            if (status_code == (int) Xep.Muc.StatusCode.SELF_PRESENCE) {
                is_self_presence = true;
            }
        }
        bool self_boundary = is_self_presence;
        if (event.kind == Xep.Muc.OccupantPresenceKind.UNAVAILABLE &&
                nickname_transition) {
            canonical_nick = null;
            if (event.nick != null && ((!) event.nick).length > 0) {
                try {
                    Jid replacement = ((!) binding).room.with_resource(
                        (!) event.nick);
                    canonical_nick = replacement.resourcepart;
                } catch (InvalidJidError e) {
                    // Keep the old occupant removal, but never materialize an
                    // invalid replacement identity in the display snapshot.
                }
            }
        }

        uint64 sequence;
        if (!take_muc_occupant_sequence((!) binding, out sequence)) return;

        var envelope = new MucPresenceEnvelope(((!) binding).worker_key, sequence,
            map_muc_presence_kind(event.kind), event.occupant_full_jid,
            canonical_nick, event.real_bare_jid,
            map_muc_affiliation(event.affiliation, event.affiliation_known),
            event.affiliation_known,
            map_muc_role(event.role, event.role_known), event.role_known,
            event.dup_hat_uris(), event.dup_hat_titles(), event.avatar_hash,
            status_codes, event.is_self_presence,
            event.received_monotonic_us, event.real_jid_known,
            event.dup_hat_hues(), self_boundary);
        if (!muc_occupant_worker.enqueue(envelope)) {
            if (((!) binding).initial_snapshot_committed) {
                disable_live_occupant_batching((!) binding, event);
            }
            return;
        }

        // Bind a private-MUC thread only after the event passed the current
        // stream, room and join-generation fences and entered the worker FIFO.
        // Leave boundaries remove every identity for the room, so a reused
        // nick can never inherit the previous occupant's PM session.
        if (peer != null) {
            if (event.kind == Xep.Muc.OccupantPresenceKind.AVAILABLE) {
                if (event.real_bare_jid != null) {
                    remember_private_message_peer_identity(account, (!) peer,
                        "jid:" + (!) event.real_bare_jid);
                } else {
                    // An authoritative MUC <item/> without jid revokes a
                    // previously disclosed real JID. Do this only here,
                    // after the current generation accepted the event.
                    if (event.real_jid_known) {
                        forget_private_message_real_jid(account, (!) peer);
                    }
                    if (!current_pm_peer_identities.has_key(account) ||
                            !current_pm_peer_identities[account].has_key(
                                (!) peer)) {
                        remember_private_message_peer_identity(account,
                            (!) peer, "session:%u:%s".printf(
                                get_muc_runtime_generation(account),
                                event.received_monotonic_us.to_string()));
                    }
                }
            } else if (event.kind ==
                    Xep.Muc.OccupantPresenceKind.UNAVAILABLE) {
                forget_private_message_peer_identity(account, (!) peer);
            }
        }
        track_enqueued_muc_membership((!) binding, envelope);

        if (collecting_initial && self_boundary) {
            reconcile_muc_occupants_at_self_boundary((!) binding);
        }
        if (collecting_initial && self_boundary && finish_muc_occupant_room(
                ((!) binding).worker_key, false)) {
            update_muc_occupant_event_capture(account);
            return;
        }
        if (!collecting_initial) {
            // Privacy CONTROL updates can fan out to every occupant. Let the
            // normal short live batch coalesce them into one UI delta instead
            // of flushing once per occupant in a large room.
            bool immediate = envelope.kind != MucWorkerPresenceKind.CONTROL &&
                (envelope.kind != MucWorkerPresenceKind.AVAILABLE ||
                 envelope.is_self_presence || envelope.status_code_count > 0);
            schedule_muc_live_flush((!) binding, immediate);
        }
    }

    private void schedule_muc_live_flush(MucOccupantRoom binding,
            bool immediate) {
        if (!is_current_muc_occupant_room(binding, binding.worker_key)) return;

        binding.live_flush_pending = true;
        if (!binding.initial_commit_complete) return;

        if (immediate) {
            if (binding.live_flush_source_id != 0) {
                Source.remove(binding.live_flush_source_id);
                binding.live_flush_source_id = 0;
            }
            flush_muc_live_batch(binding);
            return;
        }
        if (binding.live_flush_source_id != 0) return;

        bool interactive = binding.interactive_priority ||
            is_visible_muc_room(binding.account, binding.room);
        uint delay = interactive
            ? MUC_LIVE_BATCH_VISIBLE_DELAY_MS
            : MUC_LIVE_BATCH_BACKGROUND_DELAY_MS;
        int priority = interactive ? Priority.DEFAULT : Priority.LOW;
        WeakRef manager_weak = WeakRef(this);
        uint source_id = 0;
        source_id = Timeout.add_full(priority, delay, () => {
            MucManager? manager = (MucManager?) manager_weak.get();
            if (manager == null) return Source.REMOVE;
            if (binding.live_flush_source_id != source_id) return Source.REMOVE;
            binding.live_flush_source_id = 0;
            ((!) manager).flush_muc_live_batch(binding);
            return Source.REMOVE;
        });
        binding.live_flush_source_id = source_id;
    }

    private void flush_muc_live_batch(MucOccupantRoom binding) {
        if (!binding.live_flush_pending ||
                !is_current_muc_occupant_room(binding, binding.worker_key)) {
            return;
        }
        binding.live_flush_pending = false;
        if (!muc_occupant_worker.flush_room(binding.worker_key)) {
            disable_live_occupant_batching(binding, null);
        }
    }

    private void reprioritize_pending_muc_live_flush(
            MucOccupantRoom binding) {
        if (!binding.live_flush_pending || !binding.initial_commit_complete) return;
        if (binding.live_flush_source_id != 0) {
            Source.remove(binding.live_flush_source_id);
            binding.live_flush_source_id = 0;
        }
        schedule_muc_live_flush(binding, false);
    }

    private void disable_live_occupant_batching(MucOccupantRoom binding,
            Xep.Muc.OccupantPresenceEvent? event,
            MucRoomDelta? failed_delta = null) {
        binding.live_batching_enabled = false;

        if (event != null) {
            try {
                Jid occupant = new Jid(((!) event).occupant_full_jid);

                if (((!) event).affiliation_known) {
                    occupant_affiliation_updated(binding.account, binding.room,
                        occupant, ((!) event).affiliation);
                }
                if (((!) event).role_known &&
                        !is_current_own_muc_jid(binding.account, occupant)) {
                    received_occupant_role(binding.account, occupant,
                        ((!) event).role);
                }
                received_occupant_hats(binding.account, occupant,
                    get_hats(occupant, binding.account));
                if (((!) event).real_bare_jid != null &&
                        is_private_room(binding.account, binding.room)) {
                    private_room_occupant_updated(binding.account, binding.room,
                        occupant);
                }
            } catch (InvalidJidError e) {
                // The parsed event tap normally guarantees a valid full JID.
                // Even if that invariant is violated, still publish the
                // degraded room-level fallback below instead of leaving UI
                // consumers attached to an invalidated worker snapshot.
            }
        }

        uint64 revision = failed_delta != null
            ? ((!) failed_delta).revision
            : binding.stable_revision;
        MucRoomDelta fallback_delta;
        if (failed_delta != null && ((!) failed_delta).degraded_partial) {
            fallback_delta = (!) failed_delta;
        } else {
            fallback_delta = new MucRoomDelta(binding.worker_key, revision,
                true, true, true, true, false,
                (uint) binding.stable_occupants.size);
        }
        Account account = binding.account;
        Jid room = binding.room;
        remove_muc_occupant_room(binding, true);
        // Display consumers must rebuild from PresenceManager after any
        // bounded-queue loss. This signal is never an OMEMO membership proof.
        room_occupants_changed_batch(account, room, fallback_delta);
    }

    public bool has_live_occupant_batching(Account account, Jid room) {
        MucOccupantRoom? binding = get_muc_occupant_room(account,
            room.bare_jid);
        return binding != null && ((!) binding).initial_snapshot_committed &&
            ((!) binding).live_batching_enabled;
    }

    private bool take_muc_occupant_sequence(MucOccupantRoom binding,
            out uint64 sequence) {
        sequence = binding.next_sequence++;
        if (binding.next_sequence != 0) return true;

        cancel_muc_occupant_room(binding.account, binding.room);
        return false;
    }

    private void track_enqueued_muc_membership(MucOccupantRoom binding,
            MucPresenceEnvelope envelope) {
        if (envelope.kind == MucWorkerPresenceKind.AVAILABLE) {
            binding.enqueued_occupant_ids.add(envelope.occupant_full_jid);
            return;
        }
        if (envelope.kind != MucWorkerPresenceKind.UNAVAILABLE) return;

        binding.enqueued_occupant_ids.remove(envelope.occupant_full_jid);
        if (envelope.has_status_code((int) Xep.Muc.StatusCode.ROOM_NICKNAME) &&
                envelope.nick != null && ((!) envelope.nick).length > 0) {
            binding.enqueued_occupant_ids.add(binding.room.to_string() + "/" +
                ((!) envelope.nick));
        }
    }

    /**
     * PresenceManager is the live display-membership authority on the main
     * context. A platform/event-ordering edge can make it contain a few room
     * resources that never reached the optional parsed MUC event tap. Seed
     * only those missing identities before the FIFO FINISH_ROOM command so
     * the immutable worker snapshot cannot erase already-live occupants.
     */
    private void reconcile_muc_occupants_at_self_boundary(
            MucOccupantRoom binding) {
        Gee.List<Jid>? live_occupants = get_occupants(binding.room,
            binding.account);
        if (live_occupants == null) return;

        foreach (Jid occupant in (!) live_occupants) {
            string occupant_full_jid = occupant.to_string();
            if (!occupant.is_full() ||
                    binding.enqueued_occupant_ids.contains(occupant_full_jid)) {
                continue;
            }

            uint64 sequence;
            if (!take_muc_occupant_sequence(binding, out sequence)) return;

            bool affiliation_known = has_affiliation(binding.room, occupant,
                binding.account);
            Xep.Muc.Affiliation? affiliation = get_affiliation(binding.room,
                occupant, binding.account);
            bool role_known = has_role(occupant, binding.account);
            Xep.Muc.Role? role = role_known
                ? get_role(occupant, binding.account)
                : null;
            Jid? real_jid = get_real_jid(occupant, binding.account);
            Gee.List<Xep.Muc.Hat> hats = get_hats(occupant, binding.account);
            string[] hat_uris = new string[hats.size];
            string[] hat_titles = new string[hats.size];
            string[] hat_hues = new string[hats.size];
            for (int i = 0; i < hats.size; i++) {
                hat_uris[i] = hats[i].uri;
                hat_titles[i] = hats[i].title;
                hat_hues[i] = hats[i].hue ?? "";
            }

            var envelope = new MucPresenceEnvelope(binding.worker_key,
                sequence, MucWorkerPresenceKind.AVAILABLE,
                occupant_full_jid, occupant.resourcepart,
                real_jid != null ? ((!) real_jid).bare_jid.to_string() : null,
                affiliation != null
                    ? map_muc_affiliation((!) affiliation, affiliation_known)
                    : MucWorkerAffiliationState.UNKNOWN,
                affiliation_known && affiliation != null,
                role != null ? map_muc_role((!) role, role_known)
                    : MucWorkerRoleState.UNKNOWN,
                role_known && role != null, hat_uris, hat_titles, null, null, false,
                GLib.get_monotonic_time(), true, hat_hues);
            if (!muc_occupant_worker.enqueue(envelope)) continue;
            track_enqueued_muc_membership(binding, envelope);
            binding.boundary_reconciled++;
        }
    }

    private MucWorkerPresenceKind map_muc_presence_kind(
            Xep.Muc.OccupantPresenceKind kind) {
        switch (kind) {
            case Xep.Muc.OccupantPresenceKind.AVAILABLE:
                return MucWorkerPresenceKind.AVAILABLE;
            case Xep.Muc.OccupantPresenceKind.UNAVAILABLE:
                return MucWorkerPresenceKind.UNAVAILABLE;
            case Xep.Muc.OccupantPresenceKind.ERROR:
                return MucWorkerPresenceKind.ERROR;
            case Xep.Muc.OccupantPresenceKind.CONTROL:
            default:
                return MucWorkerPresenceKind.CONTROL;
        }
    }

    private MucWorkerAffiliationState map_muc_affiliation(
            Xep.Muc.Affiliation affiliation, bool known) {
        if (!known) return MucWorkerAffiliationState.UNKNOWN;
        switch (affiliation) {
            case Xep.Muc.Affiliation.NONE:
                return MucWorkerAffiliationState.NONE;
            case Xep.Muc.Affiliation.MEMBER:
                return MucWorkerAffiliationState.MEMBER;
            case Xep.Muc.Affiliation.ADMIN:
                return MucWorkerAffiliationState.ADMIN;
            case Xep.Muc.Affiliation.OWNER:
                return MucWorkerAffiliationState.OWNER;
            case Xep.Muc.Affiliation.OUTCAST:
            default:
                return MucWorkerAffiliationState.OUTCAST;
        }
    }

    private MucWorkerRoleState map_muc_role(Xep.Muc.Role role, bool known) {
        if (!known) return MucWorkerRoleState.UNKNOWN;
        switch (role) {
            case Xep.Muc.Role.NONE:
                return MucWorkerRoleState.NONE;
            case Xep.Muc.Role.VISITOR:
                return MucWorkerRoleState.VISITOR;
            case Xep.Muc.Role.PARTICIPANT:
                return MucWorkerRoleState.PARTICIPANT;
            case Xep.Muc.Role.MODERATOR:
            default:
                return MucWorkerRoleState.MODERATOR;
        }
    }

    private Xep.Muc.Role? map_worker_role(MucWorkerRoleState role) {
        switch (role) {
            case MucWorkerRoleState.NONE:
                return Xep.Muc.Role.NONE;
            case MucWorkerRoleState.VISITOR:
                return Xep.Muc.Role.VISITOR;
            case MucWorkerRoleState.PARTICIPANT:
                return Xep.Muc.Role.PARTICIPANT;
            case MucWorkerRoleState.MODERATOR:
                return Xep.Muc.Role.MODERATOR;
            case MucWorkerRoleState.UNKNOWN:
            default:
                return null;
        }
    }

    private bool is_current_muc_occupant_room(MucOccupantRoom binding,
            MucRoomKey expected_key) {
        string logical_key = muc_occupant_room_key(expected_key.account_id,
            expected_key.room_bare_jid);
        MucOccupantRoom? current = muc_occupant_rooms[logical_key];
        return current != null && ((!) current) == binding &&
            binding.worker_key.matches(expected_key) &&
            (uint64) get_muc_runtime_generation(binding.account) ==
                expected_key.stream_generation &&
            (binding.allow_leave_block_override ||
             !is_leave_blocked(binding.account, binding.room));
    }

    private void on_muc_occupant_delta(MucRoomDelta input_delta) {
        string logical_key = muc_occupant_room_key(
            input_delta.room.account_id, input_delta.room.room_bare_jid);
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                input_delta.room)) {
            shadow_muc_stale_outputs++;
            return;
        }
        MucRoomDelta delta = sanitize_room_delta_real_jids((!) binding,
            input_delta);
        if (!delta.initial_sync_finished) return;

        if (!((!) binding).initial_snapshot_committed) {
            if (!delta.full_snapshot) return;

            bool structurally_complete = delta.changed_count ==
                delta.occupant_count;
            ((!) binding).stable_occupants.clear();
            for (uint i = 0; i < delta.changed_count; i++) {
                MucOccupantSnapshot occupant = delta.changed_at(i);
                if (!occupant.available || occupant.room_bare_jid !=
                        delta.room.room_bare_jid) {
                    structurally_complete = false;
                    continue;
                }
                ((!) binding).stable_occupants[occupant.occupant_full_jid] =
                    occupant;
            }
            if (((!) binding).stable_occupants.size !=
                    (int) delta.occupant_count) structurally_complete = false;

            ((!) binding).stable_revision = delta.revision;
            ((!) binding).materialized_snapshot = delta;
            ((!) binding).live_batching_enabled =
                structurally_complete && !delta.degraded_partial;
            muc_occupant_snapshots[logical_key] = delta;
            ((!) binding).initial_snapshot_committed = true;
            compare_shadow_muc_snapshot((!) binding, delta);
            room_occupants_snapshot_ready(((!) binding).account,
                ((!) binding).room, delta);

            if (!is_current_muc_occupant_room((!) binding, delta.room) ||
                    muc_occupant_snapshots[logical_key] != delta) return;
            schedule_initial_roster_commit((!) binding, delta);
            return;
        }

        if (delta.full_snapshot ||
                delta.revision <= ((!) binding).stable_revision) return;
        if (delta.degraded_partial) {
            emit_live_occupant_compatibility_signals((!) binding, delta);
            disable_live_occupant_batching((!) binding, null, delta);
            return;
        }

        bool structurally_complete = true;
        for (uint i = 0; i < delta.removed_count; i++) {
            ((!) binding).stable_occupants.unset(delta.removed_at(i));
        }
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot occupant = delta.changed_at(i);
            if (!occupant.available || occupant.room_bare_jid !=
                    delta.room.room_bare_jid) {
                structurally_complete = false;
                break;
            }
            ((!) binding).stable_occupants[occupant.occupant_full_jid] =
                occupant;
        }
        if (((!) binding).stable_occupants.size !=
                (int) delta.occupant_count) structurally_complete = false;
        if (!structurally_complete) {
            disable_live_occupant_batching((!) binding, null, delta);
            return;
        }

        ((!) binding).stable_revision = delta.revision;
        ((!) binding).materialized_snapshot = null;
        muc_occupant_snapshots.unset(logical_key);
        room_occupants_changed_batch(((!) binding).account,
            ((!) binding).room, delta);
        if (!is_current_muc_occupant_room((!) binding, delta.room)) return;
        emit_live_occupant_compatibility_signals((!) binding, delta);
    }

    private void on_muc_occupant_room_flushed(MucRoomKey room) {
        string logical_key = muc_occupant_room_key(room.account_id,
            room.room_bare_jid);
        MucOccupantRoom? binding = muc_occupant_rooms[logical_key];
        if (binding == null || !is_current_muc_occupant_room((!) binding,
                room)) {
            shadow_muc_stale_outputs++;
        }
    }

    private void emit_live_occupant_compatibility_signals(
            MucOccupantRoom binding, MucRoomDelta delta) {
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot snapshot = delta.changed_at(i);
            MucOccupantChange flags = delta.changed_flags_at(i);
            Jid occupant;
            try {
                occupant = new Jid(snapshot.occupant_full_jid);
            } catch (InvalidJidError e) {
                continue;
            }

            if ((flags & MucOccupantChange.AFFILIATION) != 0 &&
                    has_affiliation(binding.room, occupant, binding.account)) {
                Xep.Muc.Affiliation? affiliation = get_affiliation(
                    binding.room, occupant, binding.account);
                if (affiliation != null) {
                    occupant_affiliation_updated(binding.account, binding.room,
                        occupant, (!) affiliation);
                }
            }
            if ((flags & MucOccupantChange.ROLE) != 0 &&
                    !is_current_own_muc_jid(binding.account, occupant) &&
                    snapshot.role_known) {
                Xep.Muc.Role? role = map_worker_role(snapshot.role);
                if (role != null) {
                    received_occupant_role(binding.account, occupant, role);
                }
            }
            if ((flags & MucOccupantChange.HATS) != 0) {
                received_occupant_hats(binding.account, occupant,
                    get_hats(occupant, binding.account));
            }
            if ((flags & MucOccupantChange.REAL_JID) != 0 &&
                    is_private_room(binding.account, binding.room)) {
                Jid? real_jid = get_real_jid(occupant, binding.account);
                if (real_jid != null) {
                    private_room_occupant_real_jid_ready(binding.account,
                        binding.room, occupant, (!) real_jid);
                }
            }
        }
    }

    private void compare_shadow_muc_snapshot(MucOccupantRoom binding,
            MucRoomDelta delta) {
        ShadowMucAggregate? direct = binding.comparison;
        if (direct == null) return;
        binding.comparison = null;

        uint worker_affiliations = 0;
        uint worker_roles = 0;
        uint worker_real_jids = 0;
        uint worker_hats = 0;
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot occupant = delta.changed_at(i);
            // Xep.Muc.Flag stores only non-NONE affiliations. The worker keeps
            // explicit NONE distinct from UNKNOWN, so compare the equivalent
            // non-NONE subset without weakening the snapshot semantics.
            if (occupant.affiliation_known &&
                    occupant.affiliation != MucWorkerAffiliationState.NONE) {
                worker_affiliations++;
            }
            if (occupant.role_known) worker_roles++;
            if (occupant.real_bare_jid != null) worker_real_jids++;
            if (occupant.hat_count > 0) worker_hats++;
        }

        bool matched = !delta.degraded_partial &&
            ((!) direct).occupants == delta.occupant_count &&
            ((!) direct).affiliations == worker_affiliations &&
            ((!) direct).roles == worker_roles &&
            ((!) direct).real_jids == worker_real_jids &&
            ((!) direct).hats == worker_hats;
        shadow_muc_compared++;
        if (matched) shadow_muc_matched++;
        else shadow_muc_mismatched++;

        if (shadow_muc_stats_enabled) {
            debug("MUC occupant shadow room=%s generation=%" + uint64.FORMAT +
                " direct=%u worker=%u affiliation=%u/%u role=%u/%u real-jid=%u/%u hats=%u/%u reconciled=%u degraded=%s match=%s",
                delta.room.room_bare_jid, delta.room.room_generation,
                ((!) direct).occupants, delta.occupant_count,
                ((!) direct).affiliations, worker_affiliations,
                ((!) direct).roles, worker_roles,
                ((!) direct).real_jids, worker_real_jids,
                ((!) direct).hats, worker_hats, binding.boundary_reconciled,
                delta.degraded_partial.to_string(),
                matched.to_string());
        }
    }

    private void schedule_initial_roster_commit(MucOccupantRoom binding,
            MucRoomDelta delta) {
        binding.commit_index = 0;
        if (delta.changed_count == 0) {
            complete_initial_roster_commit(binding, delta);
            return;
        }

        WeakRef manager_weak = WeakRef(this);
        binding.commit_source_id = Idle.add_full(Priority.DEFAULT, () => {
            MucManager? manager = (MucManager?) manager_weak.get();
            if (manager == null) return Source.REMOVE;
            return ((!) manager).commit_initial_roster_batch(binding, delta);
        });
    }

    private bool commit_initial_roster_batch(MucOccupantRoom binding,
            MucRoomDelta delta) {
        if (!is_current_muc_occupant_room(binding, delta.room)) {
            binding.commit_source_id = 0;
            return Source.REMOVE;
        }

        int64 deadline_us = GLib.get_monotonic_time() +
            MUC_INITIAL_ROSTER_COMMIT_BUDGET_US;
        uint committed = 0;
        while (binding.commit_index < delta.changed_count &&
                committed < MUC_INITIAL_ROSTER_COMMIT_BATCH &&
                GLib.get_monotonic_time() < deadline_us) {
            MucOccupantSnapshot snapshot = delta.changed_at(binding.commit_index++);
            commit_initial_occupant_compatibility_signals(binding, snapshot);
            committed++;
        }

        if (binding.commit_index < delta.changed_count) return Source.CONTINUE;
        binding.commit_source_id = 0;
        complete_initial_roster_commit(binding, delta);
        return Source.REMOVE;
    }

    private void commit_initial_occupant_compatibility_signals(
            MucOccupantRoom binding, MucOccupantSnapshot snapshot) {
        Jid occupant;
        try {
            occupant = new Jid(snapshot.occupant_full_jid);
        } catch (InvalidJidError e) {
            return;
        }

        Xep.Muc.Affiliation? affiliation = get_affiliation(binding.room,
            occupant, binding.account);
        if (has_affiliation(binding.room, occupant, binding.account) &&
                affiliation != null) {
            occupant_affiliation_updated(binding.account, binding.room,
                occupant, (!) affiliation);
        }

        Jid? own_jid = get_own_jid(binding.room, binding.account);
        Xep.Muc.Role? role = has_role(occupant, binding.account)
            ? get_role(occupant, binding.account)
            : null;
        if (role != null && (own_jid == null || !((!) own_jid).equals(occupant))) {
            received_occupant_role(binding.account, occupant, role);
        }

        Gee.List<Xep.Muc.Hat> hats = get_hats(occupant, binding.account);
        if (!hats.is_empty) received_occupant_hats(binding.account, occupant, hats);

        if (snapshot.real_bare_jid != null &&
                is_private_room(binding.account, binding.room)) {
            try {
                Jid real_jid = new Jid((!) snapshot.real_bare_jid);
                private_room_occupant_real_jid_ready(binding.account,
                    binding.room, occupant, real_jid);
            } catch (InvalidJidError e) {
                // Parsed MUC real JIDs are validated before entering the
                // worker; keep the compatibility commit fail-soft regardless.
            }
        }
    }

    private void complete_initial_roster_commit(MucOccupantRoom binding,
            MucRoomDelta delta) {
        if (!is_current_muc_occupant_room(binding, delta.room)) return;

        remove_initial_presence_sync_marker(binding.account, binding.room);
        room_initial_sync_finished(binding.account, binding.room);
        binding.initial_commit_complete = true;
        if (!binding.live_batching_enabled) {
            remove_muc_occupant_room(binding, true);
            return;
        }
        if (binding.live_flush_pending) schedule_muc_live_flush(binding, false);
    }

    public void shutdown() {
        if (muc_occupant_shutdown) return;
        muc_occupant_shutdown = true;
        foreach (MucOccupantRoom binding in muc_occupant_rooms.values) {
            if (binding.commit_source_id != 0) {
                Source.remove(binding.commit_source_id);
                binding.commit_source_id = 0;
            }
            if (binding.live_flush_source_id != 0) {
                Source.remove(binding.live_flush_source_id);
                binding.live_flush_source_id = 0;
            }
        }
        muc_occupant_rooms.clear();
        foreach (PendingTimedBan pending in pending_timed_bans.values) {
            if (pending.source_id != 0) {
                Source.remove(pending.source_id);
                pending.source_id = 0;
            }
        }
        pending_timed_bans.clear();
        restored_timed_ban_accounts.clear();
        pending_permanent_bookmark_removals.clear();
        restored_pending_bookmark_removal_accounts.clear();
        foreach (Account account in stream_interactor.get_accounts()) {
            Xep.Muc.Module muc_module = stream_interactor.module_manager.get_module<Xep.Muc.Module>(
                account, Xep.Muc.Module.IDENTITY);
            muc_module.occupant_presence_events_enabled = false;
        }
        muc_occupant_worker.shutdown();
        if (shadow_muc_stats_enabled) {
            MucOccupantWorkerStats stats = muc_occupant_worker.get_stats();
            debug("MUC occupant shadow summary compared=%" + uint64.FORMAT +
                " matched=%" + uint64.FORMAT + " mismatched=%" + uint64.FORMAT +
                " stale-output=%" + uint64.FORMAT + " accepted=%" + uint64.FORMAT +
                " dropped=%" + uint64.FORMAT + " evicted=%" + uint64.FORMAT +
                " stale-worker=%" + uint64.FORMAT,
                shadow_muc_compared, shadow_muc_matched, shadow_muc_mismatched,
                shadow_muc_stale_outputs, stats.accepted_envelopes,
                stats.dropped_available, stats.evicted_available,
                stats.stale_commands);
        }
        muc_occupant_room_generations.clear();
        muc_occupant_snapshots.clear();
    }

    private bool mark_initial_presence_sync(Account account, Jid jid,
            uint seconds, bool interactive_priority = false,
            bool allow_leave_block_override = false) {
        Jid bare_jid = jid.bare_jid;
        MucOccupantRoom? existing_binding = get_muc_occupant_room(account,
            bare_jid);
        if (seconds == MUC_INITIAL_PRESENCE_SYNC_SETTLE_SECONDS &&
                ((existing_binding != null && ((!) existing_binding).finish_requested) ||
                 get_room_occupants_snapshot(account, bare_jid) != null)) {
            return true;
        }

        if (seconds == MUC_INITIAL_PRESENCE_SYNC_MAX_SECONDS) {
            if (!start_muc_occupant_room(account, bare_jid,
                interactive_priority || is_visible_muc_room(account, bare_jid),
                allow_leave_block_override)) {
                return false;
            }
        }
        MucOccupantRoom? binding = get_muc_occupant_room(account, bare_jid);
        MucRoomKey? expected_worker_key = binding != null
            ? ((!) binding).worker_key
            : null;
        if (!muc_initial_presence_sync_timeouts.has_key(account)) {
            muc_initial_presence_sync_timeouts[account] = new HashMap<Jid, uint>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        if (muc_initial_presence_sync_timeouts[account].has_key(bare_jid)) {
            uint previous_timeout = muc_initial_presence_sync_timeouts[account][bare_jid];
            if (previous_timeout != 0) Source.remove(previous_timeout);
        }

        uint timeout_id = 0;
        timeout_id = Timeout.add_seconds(seconds, () => {
            if (muc_initial_presence_sync_timeouts.has_key(account) &&
                    muc_initial_presence_sync_timeouts[account].has_key(bare_jid) &&
                    muc_initial_presence_sync_timeouts[account][bare_jid] == timeout_id) {
                bool waiting_for_commit = false;
                if (expected_worker_key != null) {
                    MucOccupantRoom? current = get_muc_occupant_room(account,
                        bare_jid);
                    if (current != null && ((!) current).worker_key.matches(
                            (!) expected_worker_key)) {
                        waiting_for_commit = ((!) current).finish_requested ||
                            finish_muc_occupant_room((!) expected_worker_key, true);
                        if (waiting_for_commit) {
                            update_muc_occupant_event_capture(account);
                        }
                    }
                }
                if (waiting_for_commit) {
                    muc_initial_presence_sync_timeouts[account][bare_jid] = 0;
                } else {
                    muc_initial_presence_sync_timeouts[account].unset(bare_jid);
                    if (muc_initial_presence_sync_timeouts[account].is_empty) {
                        muc_initial_presence_sync_timeouts.unset(account);
                    }
                }
            }
            return false;
        });
        muc_initial_presence_sync_timeouts[account][bare_jid] = timeout_id;
        return true;
    }

    private void remove_initial_presence_sync_marker(Account account, Jid jid) {
        Jid bare_jid = jid.bare_jid;
        if (!muc_initial_presence_sync_timeouts.has_key(account) ||
                !muc_initial_presence_sync_timeouts[account].has_key(bare_jid)) {
            return;
        }
        uint timeout_id = muc_initial_presence_sync_timeouts[account][bare_jid];
        if (timeout_id != 0) Source.remove(timeout_id);
        muc_initial_presence_sync_timeouts[account].unset(bare_jid);
        if (muc_initial_presence_sync_timeouts[account].is_empty) {
            muc_initial_presence_sync_timeouts.unset(account);
        }
    }

    private void clear_initial_presence_sync(Account account, Jid jid) {
        Jid bare_jid = jid.bare_jid;
        remove_initial_presence_sync_marker(account, bare_jid);
        cancel_muc_occupant_room(account, bare_jid);
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ };
        public override string action_group { get { return "MUC"; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private StreamInteractor stream_interactor;

        public ReceivedMessageListener(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (conversation.type_ != Conversation.Type.GROUPCHAT) return false;
            XmppStream stream = stream_interactor.get_stream(conversation.account);
            if (stream == null) return false;
            Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (flag == null) return false;

            var mam = Xmpp.MessageArchiveManagement.MessageFlag.get_flag(stanza);
            bool historical = mam != null ||
                Xep.DelayedDelivery.MessageFlag.get_flag(stanza) != null ||
                stanza.stanza.get_subnode("delay", Xep.DelayedDelivery.NS_URI) != null;
            if (historical) {
                // MAM's delay normally belongs to the forwarded wrapper, not
                // the inner message. A room nickname may now denote another
                // person; never import today's presence identity into history.
                message.real_jid = null;
                MucManager manager = stream_interactor.get_module<MucManager>(
                    MucManager.IDENTITY);
                if (mam != null && message.account.equals(conversation.account) &&
                        message.account.id == conversation.account.id &&
                        message.type_ == Entities.Message.Type.GROUPCHAT &&
                        stanza.type_ == Xmpp.MessageStanza.TYPE_GROUPCHAT &&
                        stanza.from != null && ((!) stanza.from).is_full() &&
                        ((!) stanza.from).equals_bare(conversation.counterpart) &&
                        message.from != null && ((!) message.from).equals((!) stanza.from) &&
                        ((!) mam).sender_jid.is_bare() &&
                        ((!) mam).sender_jid.equals(conversation.counterpart.bare_jid) &&
                        ((!) mam).query_id != null && ((!) mam).query_id != "" &&
                        ((!) flag).has_current_room_features(conversation.counterpart) &&
                        manager.can_retain_room_real_jids(conversation.account,
                            conversation.counterpart)) {
                    // The typed MAM flag is set only after the XMPP layer has
                    // authenticated its query/origin. XEP-0313 room archives
                    // strip user-supplied MUC extensions and provide the
                    // original publisher JID when disclosure is authorized.
                    StanzaNode? item = stanza.stanza.get_deep_subnode(
                        "http://jabber.org/protocol/muc#user:x",
                        "http://jabber.org/protocol/muc#user:item");
                    string? original = item != null ? ((!) item).get_attribute("jid") : null;
                    if (original != null) {
                        try {
                            Jid jid = new Jid((!) original);
                            if (jid.localpart != null && !jid.equals_bare(conversation.counterpart)) {
                                message.real_jid = jid.bare_jid;
                            }
                        } catch (InvalidJidError error) {
                            debug("Ignoring invalid archived MUC sender identity");
                        }
                    }
                }
            } else {
                // Live message: resolve real JID from current occupant table
                Jid? real_jid = flag.get_real_jid(message.counterpart);
                if (real_jid != null && !real_jid.equals(message.counterpart)) {
                    message.real_jid = real_jid.bare_jid;
                }
            }

            string? occupant_id = Xep.OccupantIds.get_occupant_id(stanza.stanza);
            if (occupant_id != null) {
                message.occupant_db_id = stream_interactor.get_module<OccupantIdStore>(OccupantIdStore.IDENTITY)
                        .cache_occupant_id(conversation.account, occupant_id, message.from);
            }

            Jid? own_muc_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(message.counterpart.bare_jid, conversation.account);
            if (message.stanza_id != null && own_muc_jid != null && message.from.equals(own_muc_jid)) {
                // Servers may rewrite the outer stanza id while preserving
                // our XEP-0359 origin-id. MessageProcessor already normalized
                // that sender reference into message.stanza_id.
                Entities.Message? m = stream_interactor.get_module<MessageStorage>(MessageStorage.IDENTITY).get_message_by_stanza_id((!) message.stanza_id, conversation);
                if (m != null) {
                    // For own messages from this device (msg is a duplicate)
                    m.marked = Message.Marked.RECEIVED;
                    string? server_id = Xep.UniqueStableStanzaIDs.get_stanza_id(stanza, m.counterpart.bare_jid);
                    if (server_id != null) {
                        m.server_id = server_id;
                    }
                }
                // For own messages from other devices (msg is not a duplicate msg)
                message.marked = Message.Marked.RECEIVED;
            }

            return false;
        }
    }
}

}
