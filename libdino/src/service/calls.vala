using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

    public enum CallCapabilityStatus {
        UNAVAILABLE,
        PENDING,
        AVAILABLE
    }

    public enum CallCapabilityReason {
        NONE,
        UNSUPPORTED_CONVERSATION,
        DISCONNECTED,
        SELF_CHAT,
        CONTACT_OFFLINE,
        ENGINE_UNAVAILABLE,
        ROOM_NOT_JOINED,
        ROOM_INFO_PENDING,
        ROOM_INFO_FAILED,
        ROOM_NOT_PRIVATE,
        MUC_SERVICE_PENDING
    }

    internal enum CallAcceptedRoute {
        IGNORE,
        OWN_RESOURCE,
        GOOGLE_WAIT_FOR_MUJI,
        GOOGLE_MUJI_OWNED,
        LEGACY_RESOURCE
    }

    /**
     * Fail-closed selector for a Carboned action sent by another own resource.
     * Such an action can only answer an incoming proposal.  Call IDs are not
     * globally unique, so more than one eligible CallState is ambiguous.
     */
    internal class CimOwnActionCandidateSelection : Object {
        private int eligible_count = 0;

        internal bool consider(bool incoming_call,
                bool destination_matches) {
            if (!incoming_call || !destination_matches) return false;
            eligible_count++;
            return eligible_count == 1;
        }

        internal bool has_unique_match {
            get { return eligible_count == 1; }
        }

        internal bool is_ambiguous {
            get { return eligible_count > 1; }
        }
    }

    internal class DeferredCimGroupchatTerminal : Object {
        internal Account account { get; private set; }
        internal Jid room { get; private set; }
        internal string provisional_id { get; private set; }
        internal CimTerminalSignalAction action { get; private set; }
        internal uint timeout_source_id { get; set; default=0; }

        internal DeferredCimGroupchatTerminal(Account account, Jid room,
                string provisional_id, CimTerminalSignalAction action) {
            this.account = account;
            this.room = room.bare_jid;
            this.provisional_id = provisional_id;
            this.action = action;
        }

        internal bool matches(Account candidate_account, Jid candidate_room,
                string candidate_provisional_id) {
            return account.equals(candidate_account) &&
                room.equals(candidate_room.bare_jid) &&
                provisional_id == candidate_provisional_id;
        }
    }

    /**
     * Holds a terminal GROUPCHAT action until the room echoes our invite with
     * its authoritative XEP-0359 stanza-id. Entries are account- and room-
     * scoped and expire instead of ever falling back to message@id.
     */
    internal class DeferredCimGroupchatTerminalRegistry : Object {
        private ArrayList<DeferredCimGroupchatTerminal> entries =
            new ArrayList<DeferredCimGroupchatTerminal>();

        internal int size { get { return entries.size; } }

        internal void defer(Account account, Jid room, string provisional_id,
                CimTerminalSignalAction action) {
            if (provisional_id.strip() == "" ||
                    action == CimTerminalSignalAction.NONE) return;
            foreach (DeferredCimGroupchatTerminal entry in entries) {
                if (entry.matches(account, room, provisional_id)) return;
            }

            var entry = new DeferredCimGroupchatTerminal(account, room,
                provisional_id, action);
            entries.add(entry);
            entry.timeout_source_id = Timeout.add_seconds(120, () => {
                entry.timeout_source_id = 0;
                entries.remove(entry);
                return Source.REMOVE;
            });
        }

        internal CimTerminalSignalAction take(Account account, Jid room,
                string provisional_id) {
            DeferredCimGroupchatTerminal? matched = null;
            foreach (DeferredCimGroupchatTerminal entry in entries) {
                if (entry.matches(account, room, provisional_id)) {
                    matched = entry;
                    break;
                }
            }
            if (matched == null) return CimTerminalSignalAction.NONE;
            entries.remove((!) matched);
            if (((!) matched).timeout_source_id != 0) {
                Source.remove(((!) matched).timeout_source_id);
                ((!) matched).timeout_source_id = 0;
            }
            return ((!) matched).action;
        }

        internal void clear_account(Account account) {
            var remove_entries = new ArrayList<DeferredCimGroupchatTerminal>();
            foreach (DeferredCimGroupchatTerminal entry in entries) {
                if (entry.account.equals(account)) remove_entries.add(entry);
            }
            foreach (DeferredCimGroupchatTerminal entry in remove_entries) {
                entries.remove(entry);
                if (entry.timeout_source_id != 0) {
                    Source.remove(entry.timeout_source_id);
                    entry.timeout_source_id = 0;
                }
            }
        }
    }

    internal class CimInviteReplayEntry : Object {
        internal Account account { get; private set; }
        internal Jid sender { get; private set; }
        internal string message_type { get; private set; }
        internal string reference_id { get; private set; }
        internal uint timeout_source_id { get; set; default=0; }

        internal CimInviteReplayEntry(Account account, Jid sender,
                string message_type, string reference_id) {
            this.account = account;
            this.message_type = message_type;
            this.sender = message_type == MessageStanza.TYPE_GROUPCHAT
                ? sender.bare_jid : sender;
            this.reference_id = reference_id;
        }

        internal bool matches(Account candidate_account, Jid candidate_sender,
                string candidate_message_type,
                string candidate_reference_id) {
            Jid normalized_sender = candidate_message_type ==
                    MessageStanza.TYPE_GROUPCHAT
                ? candidate_sender.bare_jid : candidate_sender;
            return account.equals(candidate_account) &&
                message_type == candidate_message_type &&
                sender.equals(normalized_sender) &&
                reference_id == candidate_reference_id;
        }
    }

    /** Bounded live-delivery tombstones for already handled XEP-0482 invites. */
    internal class CimInviteReplayRegistry : Object {
        private const int MAX_ENTRIES = 512;
        private const uint RETENTION_SECONDS = 30 * 60;
        private ArrayList<CimInviteReplayEntry> entries =
            new ArrayList<CimInviteReplayEntry>();

        internal int size { get { return entries.size; } }

        internal bool try_claim(Account account, Jid sender,
                string message_type, string reference_id) {
            if ((message_type != MessageStanza.TYPE_CHAT &&
                    message_type != MessageStanza.TYPE_GROUPCHAT) ||
                    reference_id.strip() == "") return false;
            foreach (CimInviteReplayEntry entry in entries) {
                if (entry.matches(account, sender, message_type,
                        reference_id)) return false;
            }
            while (entries.size >= MAX_ENTRIES) {
                remove_entry(entries[0]);
            }

            var entry = new CimInviteReplayEntry(account, sender,
                message_type, reference_id);
            entries.add(entry);
            entry.timeout_source_id = Timeout.add_seconds(RETENTION_SECONDS,
                () => {
                    entry.timeout_source_id = 0;
                    entries.remove(entry);
                    return Source.REMOVE;
                });
            return true;
        }

        private void remove_entry(CimInviteReplayEntry entry) {
            entries.remove(entry);
            if (entry.timeout_source_id != 0) {
                Source.remove(entry.timeout_source_id);
                entry.timeout_source_id = 0;
            }
        }

        internal void clear() {
            var snapshot = new ArrayList<CimInviteReplayEntry>();
            snapshot.add_all(entries);
            foreach (CimInviteReplayEntry entry in snapshot) {
                remove_entry(entry);
            }
        }
    }

    public class ConversationCallCapabilities : Object {
        public CallCapabilityStatus audio { get; private set; }
        public CallCapabilityStatus video { get; private set; }
        public CallCapabilityReason reason { get; private set; }
        public bool visible { get; private set; }

        public ConversationCallCapabilities(
                CallCapabilityStatus audio,
                CallCapabilityStatus video,
                CallCapabilityReason reason,
                bool visible) {
            this.audio = audio;
            this.video = video;
            this.reason = reason;
            this.visible = visible;
        }

        public bool any_available() {
            return audio == CallCapabilityStatus.AVAILABLE ||
                video == CallCapabilityStatus.AVAILABLE;
        }
    }

    /** Passive, actionable proposal recovered after successful MAM catch-up. */
    internal class RecoveredJmiProposal : Object {
        internal Call call { get; private set; }
        internal PeerState peer_state { get; private set; }
        internal Jid proposal_source { get; private set; }
        internal Jid proposal_target { get; private set; }
        internal string sid { get; private set; }
        internal bool video_requested { get; private set; }
        internal Gee.List<StanzaNode> descriptions { get; private set; }
        internal DateTime expires_at { get; private set; }

        internal RecoveredJmiProposal(Call call, PeerState peer_state,
                Jid proposal_source, Jid proposal_target, string sid,
                bool video_requested, Gee.List<StanzaNode> descriptions,
                DateTime expires_at) {
            this.call = call;
            this.peer_state = peer_state;
            this.proposal_source = proposal_source;
            this.proposal_target = proposal_target;
            this.sid = sid;
            this.video_requested = video_requested;
            var copy = new ArrayList<StanzaNode>();
            copy.add_all(descriptions);
            this.descriptions = copy;
            this.expires_at = expires_at;
        }
    }

    /** Runtime-only address of a previous group; never retains its media owner. */
    public class GroupCallRejoinTicket : Object {
        public Account account { get; private set; }
        public Conversation source { get; private set; }
        public Jid room { get; private set; }
        public int previous_call_id { get; private set; }
        public bool video { get; private set; }
        internal XmppStream stream { get; private set; }
        private string source_room;

        internal GroupCallRejoinTicket(Conversation source, Jid room,
                int previous_call_id, bool video, XmppStream stream) {
            this.account = source.account;
            this.source = source;
            this.source_room = source.counterpart.bare_jid.to_string();
            this.room = room.bare_jid;
            this.previous_call_id = previous_call_id;
            this.video = video;
            this.stream = stream;
        }

        internal bool matches_current_scope(Conversation candidate,
                XmppStream? current_stream) {
            return source == candidate && account == candidate.account &&
                candidate.active && candidate.type_ == Conversation.Type.GROUPCHAT &&
                candidate.counterpart.bare_jid.to_string() == source_room &&
                current_stream == stream && previous_call_id > 0;
        }
    }

    /** Actual MUJI frames received during one MucManager-owned room occupancy. */
    internal class ObservedMujiRoom : Object {
        internal XmppStream stream;
        internal Jid room;
        internal MucManager.MucOwnerMutationContext? context;
        internal Presence.Flag? presence_flag;
        internal Xep.Muc.Flag? muc_flag;
        internal bool collecting_initial_roster;
        internal bool initial_roster_complete = false;
        internal HashMap<Jid, Presence.Stanza> frames =
            new HashMap<Jid, Presence.Stanza>(Jid.hash_func, Jid.equals_func);

        internal ObservedMujiRoom(XmppStream stream, Jid room,
                bool collecting_initial_roster = false) {
            this.stream = stream;
            this.room = room.bare_jid;
            this.presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
            this.muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            this.collecting_initial_roster = collecting_initial_roster;
        }

        internal bool observe(Presence.Stanza presence) {
            if (!presence.from.is_full() || !presence.from.equals_bare(room)) return false;
            if (presence.type_ == Presence.Stanza.TYPE_AVAILABLE &&
                    presence.stanza.get_subnode("muji", Xep.Muji.NS_URI) != null) {
                frames[presence.from] = presence;
                return true;
            }
            return frames.unset(presence.from);
        }
    }

    /** Owns every Calls-side signal closure attached to one CallState. */
    internal class CallStateSignalLease : Object {
        internal ulong deferred_terminal_handler_id { get; set; default=0; }
        internal ulong terminal_persist_handler_id { get; set; default=0; }
        internal ulong terminated_handler_id { get; set; default=0; }
        internal ulong group_rejoin_handler_id { get; set; default=0; }
        internal ulong group_rejoin_state_handler_id { get; set; default=0; }
        private weak CallState? group_request_owner;
        private Account? group_request_account;
        private Cancellable? group_request_cancellable;
        private ulong group_request_cancel_handler_id = 0;
        private bool disconnected = false;

        internal void bind_group_request(CallState owner, Cancellable request,
                ulong handler_id) {
            release_group_request();
            group_request_owner = owner;
            group_request_account = owner.call.account;
            group_request_cancellable = request;
            group_request_cancel_handler_id = handler_id;
        }

        internal bool matches_group_request(CallState owner, Cancellable request) {
            return !disconnected && group_request_owner == owner &&
                group_request_account == owner.call.account &&
                group_request_cancellable == request && group_request_cancel_handler_id != 0;
        }

        internal void release_group_request() {
            Cancellable? request = group_request_cancellable;
            ulong handler_id = group_request_cancel_handler_id;
            group_request_owner = null;
            group_request_account = null;
            group_request_cancellable = null;
            group_request_cancel_handler_id = 0;
            if (request != null) disconnect_handler(request, handler_id);
        }

        internal void disconnect_all(CallState call_state) {
            if (disconnected) return;
            disconnected = true;
            release_group_request();
            disconnect_handler(call_state, deferred_terminal_handler_id);
            disconnect_handler(call_state, terminal_persist_handler_id);
            disconnect_handler(call_state, terminated_handler_id);
            disconnect_handler(call_state, group_rejoin_handler_id);
            disconnect_handler(call_state.call, group_rejoin_state_handler_id);
            deferred_terminal_handler_id = 0;
            terminal_persist_handler_id = 0;
            terminated_handler_id = 0;
            group_rejoin_handler_id = 0;
            group_rejoin_state_handler_id = 0;
        }

        private static void disconnect_handler(Object call_state,
                ulong handler_id) {
            if (handler_id != 0 &&
                    SignalHandler.is_connected(call_state, handler_id)) {
                call_state.disconnect(handler_id);
            }
        }
    }

    public class Calls : StreamInteractionModule, Object {
        private const string GOOGLE_WEBRTC_CALL_DEBUG_ENV = "DINOX_GOOGLE_WEBRTC_CALL_DEBUG";
        private const uint DIRECT_JMI_SETUP_TIMEOUT_SECONDS = 30;

        public signal void call_incoming(Call call, CallState state, Conversation conversation, bool video, bool multiparty);
        public signal void call_outgoing(Call call, CallState state, Conversation conversation);

        public signal void call_terminated(Call call, string? reason_name, string? reason_text);
        public signal void conference_info_received(Call call, Xep.Coin.ConferenceInfo conference_info);
        public signal void conversation_call_capabilities_changed(
            Account account, Jid? counterpart);

        public static ModuleIdentity<Calls> IDENTITY = new ModuleIdentity<Calls>("calls");
        public string id { get { return IDENTITY.id; } }

        private StreamInteractor stream_interactor;
        private Database db;
        private bool muc_manager_signals_bound = false;
        private DeferredCimGroupchatTerminalRegistry
            deferred_cim_groupchat_terminals =
                new DeferredCimGroupchatTerminalRegistry();
        private CimInviteReplayRegistry cim_invite_replays =
            new CimInviteReplayRegistry();
        private JmiLiveSessionRegistry jmi_live_sessions =
            new JmiLiveSessionRegistry();
        private JmiArchiveReplayRegistry jmi_archive_replays =
            new JmiArchiveReplayRegistry();
        private JmiRecoveredProposalStore recovered_jmi_store;
        private HashMap<Account, uint> jmi_archive_expiry_timeouts =
            new HashMap<Account, uint>(Account.hash_func,
                Account.equals_func);
        private HashSet<Call> pending_own_jmi_mirrors =
            new HashSet<Call>(Call.hash_func, Call.equals_func);
        private HashMap<Call, uint> pending_own_jmi_timeouts =
            new HashMap<Call, uint>(Call.hash_func, Call.equals_func);
        private HashMap<Call, RecoveredJmiProposal> recovered_jmi_proposals =
            new HashMap<Call, RecoveredJmiProposal>(Call.hash_func,
                Call.equals_func);
        private HashMap<Call, CallStateSignalLease> call_state_signal_leases =
            new HashMap<Call, CallStateSignalLease>(Call.hash_func,
                Call.equals_func);
        private HashMap<Call, Conversation> group_call_sources =
            new HashMap<Call, Conversation>(Call.hash_func, Call.equals_func);
        private HashMap<Conversation, GroupCallRejoinTicket> group_rejoin_tickets =
            new HashMap<Conversation, GroupCallRejoinTicket>();
        private HashMap<GroupCallRejoinTicket, CallState> pending_group_rejoins =
            new HashMap<GroupCallRejoinTicket, CallState>();
        private HashMap<Account, HashMap<Jid, ObservedMujiRoom>> observed_muji_rooms =
            new HashMap<Account, HashMap<Jid, ObservedMujiRoom>>();

        private static bool google_webrtc_call_debug_enabled() {
            string? enabled = Environment.get_variable(GOOGLE_WEBRTC_CALL_DEBUG_ENV);
            return enabled == "1" || enabled == "true" || enabled == "yes";
        }

        internal static void trace_muji_control(string detail) {
            if (!google_webrtc_call_debug_enabled()) return;
            GLib.log("google-webrtc", LogLevelFlags.LEVEL_DEBUG,
                "MUJI control: %s", detail);
        }

//        public HashMap<Account, CallState> current_jmi_request_call = new HashMap<Account, CallState>(Account.hash_func, Account.equals_func);
        public HashMap<Call, PeerState> jmi_request_peer = new HashMap<Call, PeerState>(Call.hash_func, Call.equals_func);
        public HashMap<Call, CallState> call_states = new HashMap<Call, CallState>(Call.hash_func, Call.equals_func);

        public static void start(StreamInteractor stream_interactor, Database db) {
            Calls m = new Calls(stream_interactor, db);
            stream_interactor.add_module(m);
            MucManager? muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            if (muc_manager != null) m.bind_muc_manager((!) muc_manager);
        }

        private Calls(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            this.recovered_jmi_store = new JmiRecoveredProposalStore(db);

            stream_interactor.account_added.connect(on_account_added);
            stream_interactor.account_removed.connect((account) => {
                observed_muji_rooms.unset(account);
                forget_group_rejoins_for_account(account);
                discard_pending_own_jmi_mirrors(account);
                discard_recovered_jmi_proposals(account);
                recovered_jmi_store.remove_account(account);
                jmi_live_sessions.forget_account(account);
                clear_jmi_archive_expiry_timeout(account);
                jmi_archive_replays.clear_account(account);
            });

            stream_interactor.stream_negotiated.connect((account, stream) => {
                observed_muji_rooms.unset(account);
                forget_group_rejoins_for_account(account);
                clear_jmi_archive_expiry_timeout(account);
                suspend_recovered_jmi_proposals(account);
                jmi_archive_replays.begin_stream(account, stream);
                rebind_recovered_jmi_proposals(account);
            });
            stream_interactor.stream_resumed.connect((account, stream) => {
                // XEP-0198 retains room presence. Rebind only the exact flags
                // and occupancy after the MucManager resume handler settles.
                Idle.add(() => {
                    rebind_observed_muji_rooms_after_resume(account, stream);
                    return Source.REMOVE;
                });
                forget_group_rejoins_for_account(account);
                clear_jmi_archive_expiry_timeout(account);
                suspend_recovered_jmi_proposals(account);
                jmi_archive_replays.begin_stream(account, stream);
                rebind_recovered_jmi_proposals(account);
            });
            stream_interactor.get_module<MessageProcessor>(
                MessageProcessor.IDENTITY).history_sync
                    .account_archive_sync_finished.connect(
                        on_jmi_archive_sync_finished);

            // MucManager is normally registered after Calls. Its start method
            // binds these signals once the module is actually available.

            // End active calls when the connection drops (no ICE restart support)
            stream_interactor.connection_manager.connection_state_changed.connect((account, state) => {
                conversation_call_capabilities_changed(account, null);
                if (state == ConnectionManager.ConnectionState.DISCONNECTED) {
                    on_connection_lost(account);
                }
            });
        }

        internal void bind_muc_manager(MucManager muc_manager) {
            if (muc_manager_signals_bound) return;
            muc_manager_signals_bound = true;
            ConversationManager? conversation_manager = stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY);
            if (conversation_manager != null) {
                ((!) conversation_manager).conversation_deactivated.connect((conversation) => {
                    forget_group_rejoin(conversation);
                });
            }

            muc_manager.room_info_updated.connect((account, room) => {
                invalidate_group_rejoins_for_room(account, room, false);
                foreach (var entry in group_call_sources.entries) {
                    CallState? state = call_states[entry.key];
                    if (state != null && entry.key.account == account &&
                            ((!) state).group_call != null &&
                            ((!) ((!) state).group_call).muc_jid.equals_bare(room)) {
                        remember_group_call((!) state, entry.value);
                    }
                }
                conversation_call_capabilities_changed(account, room.bare_jid);
            });
            muc_manager.room_info_query_failed.connect((account, room) => {
                invalidate_group_rejoins_for_room(account, room, true);
                conversation_call_capabilities_changed(account, room.bare_jid);
            });
            muc_manager.joined.connect((account, room) => {
                ObservedMujiRoom? observed = get_observed_muji_room(account, room);
                if (observed != null && observed.stream == stream_interactor.get_stream(account)) {
                    observed.context = muc_manager.capture_current_muc_context(account, room);
                    if (observed.context != null && observed.collecting_initial_roster) {
                        observed.initial_roster_complete = true;
                    }
                }
                conversation_call_capabilities_changed(account, room.bare_jid);
            });
            muc_manager.room_initial_sync_started.connect((account, room) => {
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream == null) return;
                if (!observed_muji_rooms.has_key(account)) {
                    observed_muji_rooms[account] = new HashMap<Jid, ObservedMujiRoom>(
                        Jid.hash_bare_func, Jid.equals_bare_func);
                }
                observed_muji_rooms[account][room.bare_jid] = new ObservedMujiRoom((!) stream, room, true);
                conversation_call_capabilities_changed(account, room.bare_jid);
            });
            muc_manager.left_signal.connect((account, room) => {
                forget_observed_muji_room(account, room);
                forget_group_rejoins_for_source_room(account, room);
                conversation_call_capabilities_changed(account, room.bare_jid);
            });
            muc_manager.room_real_jid_visibility_changed.connect(
                (account, room, visibility) => {
                    if (visibility != Xep.Muc.RealJidVisibility.ANYONE) {
                        forget_group_rejoins_for_source_room(account, room);
                    }
                    conversation_call_capabilities_changed(account,
                        room.bare_jid);
                });
            muc_manager.room_real_jid_visibility_revoked.connect(
                (account, room) => {
                    forget_group_rejoins_for_source_room(account, room);
                    conversation_call_capabilities_changed(account,
                        room.bare_jid);
                });
            muc_manager.default_muc_server_changed.connect(
                (account, server) => {
                    conversation_call_capabilities_changed(account, null);
                });
        }

        private ObservedMujiRoom? get_observed_muji_room(Account account, Jid room) {
            var rooms = observed_muji_rooms[account];
            return rooms != null ? rooms[room.bare_jid] : null;
        }

        private void forget_observed_muji_room(Account account, Jid room) {
            var rooms = observed_muji_rooms[account];
            if (rooms != null) rooms.unset(room.bare_jid);
        }

        private void rebind_observed_muji_rooms_after_resume(Account account, XmppStream stream) {
            var rooms = observed_muji_rooms[account];
            if (rooms == null || stream_interactor.get_stream(account) != stream) return;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var discard = new ArrayList<Jid>();
            foreach (ObservedMujiRoom observed in rooms.values) {
                MucManager.MucOwnerMutationContext? current = muc.capture_current_muc_context(account, observed.room);
                var previous = observed.context;
                bool same_flags = observed.presence_flag != null && observed.muc_flag != null &&
                    observed.presence_flag == stream.get_flag(Presence.Flag.IDENTITY) &&
                    observed.muc_flag == stream.get_flag(Xep.Muc.Flag.IDENTITY);
                if (same_flags && previous != null && current != null &&
                        previous.runtime_generation == current.runtime_generation &&
                        previous.room_generation == current.room_generation &&
                        previous.own_jid.equals(current.own_jid) &&
                        muc.is_current_muc_context(account, current)) {
                    observed.stream = stream;
                    observed.context = current;
                } else if (same_flags && previous == null && current == null &&
                        observed.collecting_initial_roster && !observed.initial_roster_complete &&
                        observed.muc_flag.get_enter_id(observed.room) != null) {
                    // A resumed, still outstanding initial room join has no
                    // committed occupancy yet. Keep its collector dormant;
                    // only the real joined signal may complete the snapshot.
                    observed.stream = stream;
                } else {
                    discard.add(observed.room);
                }
            }
            foreach (Jid room in discard) rooms.unset(room);
            conversation_call_capabilities_changed(account, null);
        }

        private void observe_muji_presence(Account account, XmppStream stream,
                Presence.Stanza presence) {
            ObservedMujiRoom? observed = get_observed_muji_room(account, presence.from.bare_jid);
            if (observed == null || observed.stream != stream ||
                    stream_interactor.get_stream(account) != stream) return;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (observed.context != null &&
                    !muc.is_current_muc_context(account, (!) observed.context)) return;
            if (observed.observe(presence)) {
                conversation_call_capabilities_changed(account, observed.room);
            }
        }

        private Gee.List<Presence.Stanza> get_current_group_call_participants(Conversation source) {
            var peers = new ArrayList<Presence.Stanza>();
            if (!group_rejoin_source_is_available(source)) return peers;
            ObservedMujiRoom? observed = get_observed_muji_room(source.account, source.counterpart);
            XmppStream? stream = stream_interactor.get_stream(source.account);
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (observed == null || stream == null || observed.stream != stream ||
                    observed.context == null ||
                    !muc.is_current_muc_context(source.account, (!) observed.context)) return peers;
            Presence.Flag? presence_flag = stream.get_flag(Presence.Flag.IDENTITY);
            Xep.Muc.Flag? muc_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (presence_flag == null || muc_flag == null) return peers;
            string? own_nick = muc_flag.get_muc_nick(source.counterpart);
            if (own_nick == null) return peers;
            foreach (Presence.Stanza frame in observed.frames.values) {
                if (presence_flag.get_presence(frame.from) == frame &&
                        Xep.Muji.Module.is_existing_call_peer(frame, source.counterpart,
                            (!) own_nick, muc_flag.get_real_jid(frame.from))) peers.add(frame);
            }
            return peers;
        }

        public bool has_current_group_call_participants(Conversation source) {
            return !get_current_group_call_participants(source).is_empty;
        }

        public bool can_start_new_group_call(Conversation source) {
            if (!group_rejoin_source_is_available(source)) return false;
            ObservedMujiRoom? observed = get_observed_muji_room(source.account, source.counterpart);
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (observed == null || !observed.initial_roster_complete || observed.context == null ||
                    observed.stream != stream_interactor.get_stream(source.account) ||
                    !muc.is_current_muc_context(source.account, observed.context) || observed.presence_flag == null) return false;
            foreach (Presence.Stanza frame in observed.frames.values) {
                if (frame.from.equals(observed.context.own_jid)) continue;
                if (observed.presence_flag.get_presence(frame.from) == frame &&
                        Xep.Muji.Module.has_call_advertisement(frame)) return false;
            }
            return true;
        }

        public bool current_group_call_has_video(Conversation source) {
            foreach (Presence.Stanza frame in get_current_group_call_participants(source)) {
                StanzaNode muji = frame.stanza.get_subnode("muji", Xep.Muji.NS_URI);
                // Preparing has not frozen its media yet; negotiate video as optional.
                if (muji.get_subnode("preparing", Xep.Muji.NS_URI) != null) return true;
                foreach (StanzaNode content in muji.get_subnodes("content", Xep.Muji.NS_URI)) {
                    StanzaNode? description = content.get_subnode("description", Xep.JingleRtp.NS_URI);
                    if (description != null && description.get_attribute("media") == "video" &&
                            description.get_subnode("payload-type", Xep.JingleRtp.NS_URI) != null) return true;
                }
            }
            return false;
        }

        public async CallState? initiate_call(Conversation conversation, bool video,
                Cancellable? group_request_cancellable = null) {
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                return yield start_or_join_source_group_call(conversation, video, true,
                    group_request_cancellable);
            }
            // Direct calls retain their existing JMI/RTP route and timeout.
            if (is_call_in_progress()) {
                warning("Not initiating call — another call is already in progress");
                return null;
            }
            if (conversation.type_ != Conversation.Type.CHAT) {
                warning("Not initiating call - unsupported conversation type");
                return null;
            }
            CallMediaBackend media_backend = CallMediaBackend.LEGACY_RTP;
            Plugins.JmiCallEnginePlugin? selected_jmi_engine = get_google_webrtc_jmi_call_engine(
                conversation.account, video);
            Plugins.MujiCallEnginePlugin? selected_muji_engine = null;
            if (selected_jmi_engine != null) {
                media_backend = CallMediaBackend.GOOGLE_WEBRTC;
                selected_muji_engine = get_matching_muji_call_engine(
                    (!) selected_jmi_engine, conversation.account, video);
            } else if (!can_we_do_rtp_calls(conversation.account)) {
                warning("Not initiating call - no capable call engine");
                return null;
            }
            Call call = new Call();
            call.direction = Call.DIRECTION_OUTGOING;
            call.account = conversation.account;
            call.counterpart = conversation.counterpart;
            call.ourpart = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account) ?? conversation.account.full_jid;
            call.time = call.local_time = call.end_time = new DateTime.now_utc();
            call.encryption = Encryption.UNKNOWN;
            call.state = Call.State.RINGING;
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY).add_call(call, conversation);
            var call_state = new CallState(call, stream_interactor,
                media_backend, selected_jmi_engine, selected_muji_engine);
            connect_call_state_signals(call_state);
            call_state.we_should_send_video = video;
            call_state.we_should_send_audio = true;
            call.add_peer(conversation.counterpart);
            PeerState peer_state = call_state.set_first_peer(conversation.counterpart);
            jmi_request_peer[call] = peer_state;
            yield peer_state.initiate_call(conversation.counterpart);
            if (!call_states.has_key(call)) return null;
            call_state.start_establishing_timeout(30);
            call_outgoing(call, call_state, conversation);
            return call_state;
        }

        /** First participation in a current room call needs no remembered invite or old owner. */
        public async CallState? join_current_group_call(Conversation source, bool video,
                Cancellable? request_cancellable = null) {
            return yield start_or_join_source_group_call(source, video, false, request_cancellable);
        }

        private bool is_current_source_group_request(Conversation source, Account account,
                Jid room, MucManager.MucOwnerMutationContext context) {
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            return source.account == account && source.counterpart.equals_bare(room) &&
                group_rejoin_source_is_available(source) &&
                stream_interactor.get_stream(account) == context.stream &&
                muc.is_current_muc_context(account, context);
        }

        /** Keep menu cancellation armed until its exact result owns a visible call window. */
        private bool bind_group_request_cancellation(CallState state, Cancellable? request) {
            if (request == null) return call_states[state.call] == state;
            CallStateSignalLease? lease = call_state_signal_leases[state.call];
            if (lease == null || call_states[state.call] != state) return false;
            Account account = state.call.account;
            ulong handler_id = request.cancelled.connect(() => {
                if (call_states[state.call] == state && state.call.account == account) {
                    state.end("Group call request cancelled before its window opened");
                }
            });
            lease.bind_group_request(state, request, handler_id);
            if (request.is_cancelled()) state.end("Group call request cancelled before its window opened");
            return call_states[state.call] == state;
        }

        public bool acknowledge_group_call_handoff(CallState state, Cancellable request) {
            CallStateSignalLease? lease = call_state_signal_leases[state.call];
            if (call_states[state.call] != state || lease == null ||
                    !lease.matches_group_request(state, request)) return false;
            if (request.is_cancelled() || state.group_call == null || state.group_call.left) {
                state.end("Group call window handoff cancelled");
                return false;
            }
            lease.release_group_request();
            return true;
        }

        public bool abort_group_call_handoff(CallState state, Cancellable request) {
            CallStateSignalLease? lease = call_state_signal_leases[state.call];
            if (call_states[state.call] != state || lease == null ||
                    !lease.matches_group_request(state, request)) return false;
            state.end("Group call cancelled before opening its window");
            return true;
        }

        private async CallState? start_or_join_source_group_call(Conversation source, bool video,
                bool start_new, Cancellable? request_cancellable) {
            if (is_call_in_progress() || !group_rejoin_source_is_available(source) ||
                    (request_cancellable != null && request_cancellable.is_cancelled())) return null;
            Account account = source.account;
            Jid room = source.counterpart.bare_jid;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            MucManager.MucOwnerMutationContext? context = muc.capture_current_muc_context(account, room);
            if (context == null) return null;
            bool exists = yield context.stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                .query_room_info(context.stream, room);
            if (!exists || !is_current_source_group_request(source, account, room, (!) context) ||
                    is_call_in_progress() ||
                    (request_cancellable != null && request_cancellable.is_cancelled())) return null;
            bool other_call = has_current_group_call_participants(source);
            if (start_new ? !can_start_new_group_call(source) : !other_call) return null;
            Plugins.JmiCallEnginePlugin? jmi_engine;
            Plugins.MujiCallEnginePlugin? muji_engine;
            if (!try_select_group_engines(account, video, out jmi_engine, out muji_engine)) return null;
            Call call = new Call();
            call.direction = Call.DIRECTION_OUTGOING;
            call.account = account;
            call.counterpart = room;
            call.ourpart = context.own_jid;
            call.time = call.local_time = call.end_time = new DateTime.now_utc();
            call.encryption = Encryption.UNKNOWN;
            call.state = Call.State.RINGING;
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY).add_call(call, source);
            var state = new CallState(call, stream_interactor, CallMediaBackend.GOOGLE_WEBRTC,
                jmi_engine, muji_engine);
            state.we_should_send_audio = true;
            state.we_should_send_video = video;
            connect_call_state_signals(state, source);
            if (!bind_group_request_cancellation(state, request_cancellable)) {
                state.end("Group call request no longer owns its state");
                discard_unpublished_call(call);
                return null;
            }
            GroupCallRejoinValidity may_continue = () => {
                return is_current_source_group_request(source, account, room, (!) context) &&
                    call_states[call] == state &&
                    (request_cancellable == null || !request_cancellable.is_cancelled());
            };
            bool joined;
            if (start_new) {
                joined = yield state.initiate_groupchat_call(room, may_continue, () => {
                    return can_start_new_group_call(source);
                });
            } else {
                joined = yield state.join_current_room_group_call(room, may_continue, () => {
                    return has_current_group_call_participants(source);
                });
            }
            if (!joined || !may_continue()) {
                state.end("The group call room is no longer available");
                discard_unpublished_call(call);
                return null;
            }
            remember_group_call(state, source);
            call_outgoing(call, state, source);
            return state;
        }

        private bool group_rejoin_source_is_available(Conversation source) {
            if (!source.active || source.type_ != Conversation.Type.GROUPCHAT ||
                    stream_interactor.connection_manager.get_state(source.account) !=
                        ConnectionManager.ConnectionState.CONNECTED) return false;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            return muc.is_joined(source.counterpart, source.account) &&
                muc.has_live_private_room_features(source.account, source.counterpart);
        }

        public GroupCallRejoinTicket? get_group_call_rejoin_ticket(Conversation source) {
            GroupCallRejoinTicket? ticket = group_rejoin_tickets[source];
            if (ticket == null || !((!) ticket).matches_current_scope(source,
                    stream_interactor.get_stream(source.account)) ||
                    !group_rejoin_source_is_available(source)) return null;
            return ticket;
        }

        public CallState? get_current_group_call(Conversation source) {
            if (!group_rejoin_source_is_available(source)) return null;
            foreach (var entry in group_call_sources.entries) {
                if (entry.value != source || entry.key.account != source.account) continue;
                CallState? state = call_states[entry.key];
                if (state != null && ((!) state).group_call != null &&
                        !((!) ((!) state).group_call).left &&
                        (entry.key.state == Call.State.RINGING ||
                         entry.key.state == Call.State.ESTABLISHING ||
                         entry.key.state == Call.State.IN_PROGRESS)) return state;
            }
            return null;
        }

        private void remember_group_call(CallState state, Conversation source) {
            // The old ticket remains the join transaction's identity until publication commits.
            foreach (CallState pending in pending_group_rejoins.values) {
                if (pending == state) return;
            }
            XmppStream? stream = stream_interactor.get_stream(source.account);
            if (state.call.state != Call.State.IN_PROGRESS ||
                    state.call.account != source.account || stream == null ||
                    state.group_call == null || ((!) state.group_call).left ||
                    !group_rejoin_source_is_available(source)) return;
            Jid room = ((!) state.group_call).muc_jid;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (!muc.has_live_private_room_features(source.account, room)) return;
            GroupCallRejoinTicket? old = group_rejoin_tickets[source];
            if (old != null && ((!) old).previous_call_id == state.call.id &&
                    ((!) old).room.equals(room)) return;
            group_rejoin_tickets[source] = new GroupCallRejoinTicket(source,
                room, state.call.id, state.we_should_send_video &&
                    ((!) state.group_call).video_available, (!) stream);
            conversation_call_capabilities_changed(source.account, source.counterpart);
        }

        private void forget_group_rejoin(Conversation source) {
            GroupCallRejoinTicket? ticket = group_rejoin_tickets[source];
            if (ticket == null) return;
            group_rejoin_tickets.unset(source);
            CallState? pending = pending_group_rejoins[ticket];
            pending_group_rejoins.unset(ticket);
            if (pending != null) ((!) pending).end("Group rejoin context changed");
            conversation_call_capabilities_changed(source.account, source.counterpart);
        }

        private void forget_group_rejoins_for_account(Account account) {
            var sources = new ArrayList<Conversation>();
            foreach (var entry in group_rejoin_tickets.entries) {
                if (entry.value.account == account) sources.add(entry.key);
            }
            foreach (Conversation source in sources) forget_group_rejoin(source);
        }

        private void forget_group_rejoins_for_source_room(Account account, Jid room) {
            var sources = new ArrayList<Conversation>();
            foreach (var entry in group_rejoin_tickets.entries) {
                if (entry.value.account == account &&
                        entry.key.counterpart.equals_bare(room)) sources.add(entry.key);
            }
            foreach (Conversation source in sources) forget_group_rejoin(source);
        }

        private void invalidate_group_rejoins_for_room(Account account, Jid room,
                bool failed) {
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var sources = new ArrayList<Conversation>();
            foreach (var entry in group_rejoin_tickets.entries) {
                if (entry.value.account != account ||
                        (!entry.key.counterpart.equals_bare(room) &&
                         !entry.value.room.equals_bare(room))) continue;
                if (failed || (muc.has_current_room_features(account, room) &&
                        !muc.has_live_private_room_features(account, room))) sources.add(entry.key);
            }
            foreach (Conversation source in sources) forget_group_rejoin(source);
        }

        private bool group_rejoin_attempt_is_current(GroupCallRejoinTicket ticket,
                MucManager.MucOwnerMutationContext source_context) {
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            return group_rejoin_tickets[ticket.source] == ticket &&
                ticket.matches_current_scope(ticket.source,
                    stream_interactor.get_stream(ticket.account)) &&
                group_rejoin_source_is_available(ticket.source) &&
                muc.has_live_private_room_features(ticket.account, ticket.room) &&
                muc.is_current_muc_context(ticket.account, source_context);
        }

        public async CallState? rejoin_group_call(Conversation source,
                GroupCallRejoinTicket ticket, Cancellable? request_cancellable = null) {
            if ((request_cancellable != null && ((!) request_cancellable).is_cancelled()) ||
                    is_call_in_progress() || get_group_call_rejoin_ticket(source) != ticket) return null;
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            MucManager.MucOwnerMutationContext? context = muc.capture_current_muc_context(
                source.account, source.counterpart);
            if (context == null) return null;
            XmppStream stream = ticket.stream;
            bool exists = yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY)
                .query_room_info(stream, ticket.room);
            if (request_cancellable != null && ((!) request_cancellable).is_cancelled()) return null;
            if (!exists || !group_rejoin_attempt_is_current(ticket, (!) context) ||
                    !muc.has_live_private_room_features(ticket.account, ticket.room)) {
                if (group_rejoin_tickets[source] == ticket) forget_group_rejoin(source);
                return null;
            }
            // Another call may have won while authoritative room discovery was in flight.
            if (is_call_in_progress()) return null;
            Plugins.JmiCallEnginePlugin? jmi_engine;
            Plugins.MujiCallEnginePlugin? muji_engine;
            if (!try_select_group_engines(ticket.account, ticket.video,
                    out jmi_engine, out muji_engine)) return null;
            if (request_cancellable != null && ((!) request_cancellable).is_cancelled()) return null;
            Call call = new Call();
            call.direction = Call.DIRECTION_OUTGOING;
            call.account = ticket.account;
            call.counterpart = source.counterpart;
            call.ourpart = muc.get_own_jid(source.counterpart, ticket.account) ?? ticket.account.full_jid;
            call.time = call.local_time = call.end_time = new DateTime.now_utc();
            call.encryption = Encryption.UNKNOWN;
            call.state = Call.State.RINGING;
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY).add_call(call, source);
            var state = new CallState(call, stream_interactor, CallMediaBackend.GOOGLE_WEBRTC,
                jmi_engine, muji_engine);
            state.we_should_send_audio = true;
            state.we_should_send_video = ticket.video;
            connect_call_state_signals(state, source);
            pending_group_rejoins[ticket] = state;
            if (!bind_group_request_cancellation(state, request_cancellable)) {
                if (pending_group_rejoins[ticket] == state) pending_group_rejoins.unset(ticket);
                state.end("Group rejoin request no longer owns its state");
                discard_unpublished_call(call);
                return null;
            }
            bool joined = yield state.rejoin_existing_group_call(ticket.room, () => {
                return group_rejoin_attempt_is_current(ticket, (!) context) &&
                    call_states[call] == state &&
                    (request_cancellable == null || !((!) request_cancellable).is_cancelled());
            });
            if (pending_group_rejoins[ticket] == state) pending_group_rejoins.unset(ticket);
            if (!joined || !call_states.has_key(call) ||
                    !group_rejoin_attempt_is_current(ticket, (!) context) ||
                    (request_cancellable != null && ((!) request_cancellable).is_cancelled())) {
                state.end("The previous group call is no longer available");
                discard_unpublished_call(call);
                if ((request_cancellable == null || !((!) request_cancellable).is_cancelled()) &&
                        group_rejoin_tickets[source] == ticket) forget_group_rejoin(source);
                return null;
            }
            remember_group_call(state, source);
            call_outgoing(call, state, source);
            return state;
        }

        public bool can_we_do_calls(Account account) {
            return can_we_do_audio_calls(account) || can_we_do_video_calls(account);
        }

        public bool can_we_do_call(Account account, bool video, bool multiparty = false) {
            if (multiparty) {
                Plugins.JmiCallEnginePlugin? jmi_engine;
                Plugins.MujiCallEnginePlugin? muji_engine;
                return try_select_group_engines(account, video,
                    out jmi_engine, out muji_engine);
            }
            return video ? can_we_do_video_calls(account) : can_we_do_audio_calls(account);
        }

        public bool can_we_do_audio_calls(Account account) {
            if (can_we_do_rtp_calls(account)) return true;
            return get_google_webrtc_jmi_call_engine(account, false) != null;
        }

        public bool can_we_do_video_calls(Account account) {
            if (can_we_do_rtp_calls(account)) return true;
            return get_google_webrtc_jmi_call_engine(account, true) != null;
        }

        private bool can_we_do_rtp_calls(Account account) {
            Plugins.VideoCallPlugin? plugin = Application.get_default().plugin_registry.video_call_plugin;
            if (plugin == null) return false;

            return plugin.supported();
        }

        public Plugins.JmiCallEnginePlugin? get_google_webrtc_jmi_call_engine(Account account, bool video_requested) {
            Plugins.JmiCallEnginePlugin? engine = Application.get_default().plugin_registry.jmi_call_engine_plugin;
            if (engine == null) return null;
            if (!((!) engine).runtime_enabled()) return null;
            if (video_requested) {
                if (!((!) engine).can_start_video(account)) return null;
            } else if (!((!) engine).can_start_audio_only(account)) {
                return null;
            }

            return engine;
        }

        public Plugins.MujiCallEnginePlugin? get_google_webrtc_muji_call_engine(
                Account account, bool video_requested) {
            Plugins.MujiCallEnginePlugin? engine = Application.get_default()
                .plugin_registry.muji_call_engine_plugin;
            if (engine == null || !((!) engine).runtime_enabled()) return null;
            if (video_requested) {
                if (!((!) engine).can_start_group_video(account)) return null;
            } else if (!((!) engine).can_start_group_audio(account)) {
                return null;
            }
            return engine;
        }

        private Plugins.JmiCallEnginePlugin? get_matching_jmi_call_engine(
                Plugins.MujiCallEnginePlugin muji_engine, Account account,
                bool video_requested) {
            Plugins.JmiCallEnginePlugin? engine = Application.get_default()
                .plugin_registry.jmi_call_engine_plugin;
            if (engine == null || !((!) engine).runtime_enabled()) return null;
            if (video_requested) {
                if (!((!) engine).can_start_video(account)) return null;
            } else if (!((!) engine).can_start_audio_only(account)) {
                return null;
            }
            return ((!) engine).engine_id == muji_engine.group_engine_id
                ? engine : null;
        }

        private Plugins.MujiCallEnginePlugin? get_matching_muji_call_engine(
                Plugins.JmiCallEnginePlugin jmi_engine, Account account,
                bool video_requested) {
            Plugins.MujiCallEnginePlugin? engine = Application.get_default()
                .plugin_registry.muji_call_engine_plugin;
            if (engine == null || !((!) engine).runtime_enabled()) return null;
            if (video_requested) {
                if (!((!) engine).can_start_group_video(account)) return null;
            } else if (!((!) engine).can_start_group_audio(account)) {
                return null;
            }
            return ((!) engine).group_engine_id == jmi_engine.engine_id
                ? engine : null;
        }

        private bool try_select_group_engines(Account account,
                bool video_requested,
                out Plugins.JmiCallEnginePlugin? jmi_engine,
                out Plugins.MujiCallEnginePlugin? muji_engine) {
            jmi_engine = null;
            muji_engine = get_google_webrtc_muji_call_engine(account,
                video_requested);
            if (muji_engine == null) return false;
            jmi_engine = get_matching_jmi_call_engine((!) muji_engine, account,
                video_requested);
            if (jmi_engine == null) {
                muji_engine = null;
                return false;
            }
            return true;
        }

        private bool maybe_attach_google_webrtc_jmi_incoming_engine(
                Account account,
                PeerState peer_state,
                Jid from,
                string sid,
                Gee.List<StanzaNode> descriptions,
                bool video_requested,
                Plugins.JmiCallEnginePlugin engine) {

            if (from.resourcepart == null) {
                warning("Ignoring Google/libwebrtc JMI incoming proposal without full peer JID");
                return false;
            }

            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) {
                warning("Cannot create Google/libwebrtc JMI incoming session without an XMPP stream");
                return false;
            }

            try {
                peer_state.set_google_webrtc_jmi_call_engine_session(engine.create_incoming_session(
                    (!) stream,
                    account.full_jid,
                    from,
                    sid,
                    peer_state.call.id > 0 ? (uint64) peer_state.call.id : 0,
                    descriptions));
                debug(
                    "Created Google/libwebrtc incoming JMI %s session sid=%s peer=%s",
                    video_requested ? "audio-video" : "audio",
                    sid,
                    from.to_string());
                if (google_webrtc_call_debug_enabled()) {
                    message(
                        "Google/libwebrtc call: Calls attached incoming %s session sid=%s account=%s peer=%s path=libwebrtc-jmi rtp-gstreamer=not-started",
                        video_requested ? "audio-video" : "audio",
                        sid,
                        account.bare_jid.to_string(),
                        from.to_string());
                }
                return true;
            } catch (Error e) {
                warning("Failed to create Google/libwebrtc incoming JMI session: %s", e.message);
                peer_state.discard_google_webrtc_jmi_call_engine_session();
                return false;
            }
        }

        public async bool can_conversation_do_calls(Conversation conversation) {
            return get_conversation_call_capabilities(conversation)
                .any_available();
        }

        public ConversationCallCapabilities get_conversation_call_capabilities(
                Conversation conversation) {
            if (!is_supported_call_conversation_type(conversation.type_)) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityReason.UNSUPPORTED_CONVERSATION, false);
            }
            bool connected = stream_interactor.connection_manager.get_state(
                conversation.account) == ConnectionManager.ConnectionState.CONNECTED;
            if (!connected) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityReason.DISCONNECTED, false);
            }

            if (conversation.type_ == Conversation.Type.CHAT) {
                if (conversation.counterpart.equals_bare(
                        conversation.account.bare_jid)) {
                    return new ConversationCallCapabilities(
                        CallCapabilityStatus.UNAVAILABLE,
                        CallCapabilityStatus.UNAVAILABLE,
                        CallCapabilityReason.SELF_CHAT, false);
                }
                Gee.List<Jid>? full_jids = stream_interactor.get_module<
                    PresenceManager>(PresenceManager.IDENTITY).get_full_jids(
                        conversation.counterpart, conversation.account);
                if (full_jids == null || ((!) full_jids).is_empty) {
                    return new ConversationCallCapabilities(
                        CallCapabilityStatus.UNAVAILABLE,
                        CallCapabilityStatus.UNAVAILABLE,
                        CallCapabilityReason.CONTACT_OFFLINE, false);
                }
                bool audio_engine = can_we_do_audio_calls(conversation.account);
                bool video_engine = can_we_do_video_calls(conversation.account);
                return new ConversationCallCapabilities(
                    audio_engine ? CallCapabilityStatus.AVAILABLE :
                        CallCapabilityStatus.UNAVAILABLE,
                    video_engine ? CallCapabilityStatus.AVAILABLE :
                        CallCapabilityStatus.UNAVAILABLE,
                    audio_engine || video_engine ? CallCapabilityReason.NONE :
                        CallCapabilityReason.ENGINE_UNAVAILABLE,
                    audio_engine || video_engine);
            }

            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            bool audio_engine = can_we_do_call(conversation.account, false, true);
            bool video_engine = can_we_do_call(conversation.account, true, true);
            ConversationCallCapabilities result = evaluate_group_call_capabilities(
                connected,
                audio_engine,
                video_engine,
                muc_manager.is_joined(conversation.counterpart,
                    conversation.account),
                muc_manager.has_pending_muc_room_info(conversation.account,
                    conversation.counterpart),
                muc_manager.has_failed_muc_room_info(conversation.account,
                    conversation.counterpart),
                muc_manager.has_live_private_room_features(
                    conversation.account, conversation.counterpart),
                true);
            if (result.any_available() && get_current_group_call(conversation) == null &&
                    !has_current_group_call_participants(conversation) &&
                    !can_start_new_group_call(conversation)) {
                return pending_group_capabilities(audio_engine, video_engine,
                    CallCapabilityReason.ROOM_INFO_PENDING);
            }
            return result;
        }

        internal static ConversationCallCapabilities
                evaluate_group_call_capabilities(
                    bool connected,
                    bool audio_engine,
                    bool video_engine,
                    bool joined,
                    bool room_info_pending,
                    bool room_info_failed,
                    bool private_room,
                    bool has_muc_service) {
            if (!connected) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityReason.DISCONNECTED, false);
            }
            if (!audio_engine && !video_engine) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityReason.ENGINE_UNAVAILABLE, false);
            }
            if (!joined) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityReason.ROOM_NOT_JOINED, false);
            }
            if (room_info_pending) {
                return pending_group_capabilities(audio_engine, video_engine,
                    CallCapabilityReason.ROOM_INFO_PENDING);
            }
            if (!private_room) {
                return new ConversationCallCapabilities(
                    CallCapabilityStatus.UNAVAILABLE,
                    CallCapabilityStatus.UNAVAILABLE,
                    room_info_failed ? CallCapabilityReason.ROOM_INFO_FAILED :
                        CallCapabilityReason.ROOM_NOT_PRIVATE,
                    false);
            }
            if (!has_muc_service) {
                return pending_group_capabilities(audio_engine, video_engine,
                    CallCapabilityReason.MUC_SERVICE_PENDING);
            }
            return new ConversationCallCapabilities(
                audio_engine ? CallCapabilityStatus.AVAILABLE :
                    CallCapabilityStatus.UNAVAILABLE,
                video_engine ? CallCapabilityStatus.AVAILABLE :
                    CallCapabilityStatus.UNAVAILABLE,
                CallCapabilityReason.NONE, true);
        }

        internal static bool requested_call_is_available(
                ConversationCallCapabilities capabilities,
                bool video_requested) {
            return (video_requested ? capabilities.video : capabilities.audio) ==
                CallCapabilityStatus.AVAILABLE;
        }

        internal static bool is_supported_call_conversation_type(
                Conversation.Type conversation_type) {
            return conversation_type == Conversation.Type.CHAT ||
                conversation_type == Conversation.Type.GROUPCHAT;
        }

        internal static bool call_invite_source_allowed(string message_type,
                bool source_is_known_muc) {
            return !(message_type == MessageStanza.TYPE_CHAT &&
                source_is_known_muc);
        }

        internal static bool existing_call_blocks_new_muji(
                Call.State state, bool convertible_direct_call) {
            bool active = state == Call.State.RINGING ||
                state == Call.State.ESTABLISHING ||
                state == Call.State.IN_PROGRESS;
            return active && !convertible_direct_call;
        }

        internal static bool group_engine_facets_match(
                string? group_engine_id,
                string? media_engine_id) {
            return group_engine_id != null && media_engine_id != null &&
                group_engine_id == media_engine_id;
        }

        internal static CallAcceptedRoute select_call_accepted_route(
                bool own_resource, CallMediaBackend backend,
                bool muji_presence_seen, bool has_legacy_request_peer) {
            if (own_resource) return CallAcceptedRoute.OWN_RESOURCE;
            if (backend == CallMediaBackend.GOOGLE_WEBRTC) {
                // Before and after MUJI presence, <accept/> is signaling only.
                // Native peer ownership starts exclusively from MUJI/JMI.
                return muji_presence_seen
                    ? CallAcceptedRoute.GOOGLE_MUJI_OWNED
                    : CallAcceptedRoute.GOOGLE_WAIT_FOR_MUJI;
            }
            return has_legacy_request_peer
                ? CallAcceptedRoute.LEGACY_RESOURCE
                : CallAcceptedRoute.IGNORE;
        }

        private static ConversationCallCapabilities pending_group_capabilities(
                bool audio_engine,
                bool video_engine,
                CallCapabilityReason reason) {
            return new ConversationCallCapabilities(
                audio_engine ? CallCapabilityStatus.PENDING :
                    CallCapabilityStatus.UNAVAILABLE,
                video_engine ? CallCapabilityStatus.PENDING :
                    CallCapabilityStatus.UNAVAILABLE,
                reason, true);
        }

        public bool can_initiate_groupcall(Account account) {
            return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).default_muc_server[account] != null;
        }

        public async Gee.List<Jid> get_call_resources(Account account, Jid counterpart) {
            ArrayList<Jid> ret = new ArrayList<Jid>();

            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return ret;

            Gee.List<Jid>? full_jids = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(counterpart, account);
            if (full_jids == null) return ret;

            foreach (Jid full_jid in full_jids) {
                var module = stream.get_module<Xep.JingleRtp.Module>(Xep.JingleRtp.Module.IDENTITY);
                if (module == null) return ret;
                bool supports_rtc = yield module.is_available(stream, full_jid);
                if (!supports_rtc) continue;
                ret.add(full_jid);
            }
            return ret;
        }

        public async bool contains_jmi_resources(Account account, Gee.List<Jid> full_jids) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return false;

            foreach (Jid full_jid in full_jids) {
                bool does_jmi = yield stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY).has_feature(account, full_jid, Xep.JingleMessageInitiation.NS_URI);
                if (does_jmi) return true;
            }
            return false;
        }

        /**
         * ABI compatibility wrapper for plugins built against libdino.so.0.
         * New code must use has_jmi_resources_for_account() so cached caps
         * cannot cross account boundaries.
         */
        public bool has_jmi_resources(Jid counterpart) {
            return db.entity.select()
                    .with(db.entity.jid_id, "=", db.get_jid_id(counterpart))
                    .join_with(db.entity_feature, db.entity.caps_hash,
                        db.entity_feature.entity)
                    .with(db.entity_feature.feature, "=",
                        Xep.JingleMessageInitiation.NS_URI)
                    .count() > 0;
        }

        internal bool has_jmi_resources_for_account(Account account,
                Jid counterpart) {
            return stream_interactor.get_module<EntityInfo>(
                EntityInfo.IDENTITY).has_any_resource_feature_offline(account,
                    counterpart, Xep.JingleMessageInitiation.NS_URI);
        }

        public bool is_call_in_progress() {
            foreach (Call call in call_states.keys) {
                if (call.state == Call.State.IN_PROGRESS || call.state == Call.State.RINGING || call.state == Call.State.ESTABLISHING) {
                    return true;
                }
            }
            return false;
        }

        private void on_incoming_call(Account account, Xep.Jingle.Session session) {
            Jid? muji_room = session.muji_room;
            bool counterpart_wants_video = false;
            debug("on_incoming_call: sid=%s from=%s contents=%d", session.sid, session.peer_full_jid.to_string(), session.contents.size);
            if (!can_we_do_rtp_calls(account)) {
                warning("[%s] Rejecting incoming RTP session without a legacy media backend",
                    account.bare_jid.to_string());
                reject_incoming_rtp_contents(session);
                return;
            }
            foreach (Xep.Jingle.Content content in session.contents) {
                Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
                debug("  content '%s' senders=%s rtp=%s media=%s", content.content_name,
                      content.senders.to_string(),
                      (rtp_content_parameter != null).to_string(),
                      rtp_content_parameter != null ? rtp_content_parameter.media : "n/a");
                if (rtp_content_parameter == null) continue;
                if (rtp_content_parameter.media == "video" && session.senders_include_us(content.senders)) {
                    counterpart_wants_video = true;
                }
            }
            debug("on_incoming_call: counterpart_wants_video=%s", counterpart_wants_video.to_string());

            // Check if this comes from a MUJI MUC => accept
            if (muji_room != null) {
                debug("[%s] Incoming call from %s from MUJI muc %s", account.bare_jid.to_string(), session.peer_full_jid.to_string(), muji_room.to_string());

                foreach (CallState call_state in call_states.values) {
                    if (call_state.call.account.equals(account) && call_state.group_call != null && call_state.group_call.muc_jid.equals(muji_room)) {
                        if (call_state.media_backend ==
                                CallMediaBackend.GOOGLE_WEBRTC) {
                            warning("[%s] Rejecting legacy RTP inside a Google/libwebrtc MUJI call",
                                account.bare_jid.to_string());
                            reject_incoming_rtp_contents(session);
                            return;
                        }
                        if (call_state.peers.keys.contains(session.peer_full_jid)) {
                            PeerState peer_state = call_state.peers[session.peer_full_jid];
                            debug("[%s] Incoming call, we know the peer. Expected %s", account.bare_jid.to_string(), peer_state.waiting_for_inbound_muji_connection.to_string());
                            if (!peer_state.waiting_for_inbound_muji_connection) return;

                            peer_state.set_session(session);
                            debug(@"[%s] Accepting incoming MUJI call from %s", account.bare_jid.to_string(), session.peer_full_jid.to_string());
                            peer_state.accept();
                        } else {
                            debug(@"[%s] Incoming call, but didn't see peer in MUC yet", account.bare_jid.to_string());
                            PeerState peer_state = new PeerState(session.peer_full_jid, call_state.call, call_state, stream_interactor);
                            peer_state.set_session(session);
                            call_state.add_peer(peer_state);
                        }
                        return;
                    }
                }
                return;
            }

            debug(@"[%s] Incoming call from %s", account.bare_jid.to_string(), session.peer_full_jid.to_string());

            // Check if we already got this call via Jingle Message Initiation => accept
            // PeerState.accept() checks if the call was accepted and ensures that we don't accidentally send video
            PeerState? peer_state = get_peer_by_sid(account, session.sid, session.peer_full_jid);
            if (peer_state != null) {
                if (call_states[peer_state.call].media_backend ==
                        CallMediaBackend.GOOGLE_WEBRTC) {
                    warning("[%s] Rejecting RTP fallback for an immutable Google/libwebrtc call",
                        account.bare_jid.to_string());
                    reject_incoming_rtp_contents(session);
                    return;
                }
                debug("on_incoming_call: JMI peer found, we_should_send_video=%s counterpart_wants_video=%s",
                      call_states[peer_state.call].we_should_send_video.to_string(), counterpart_wants_video.to_string());
                // Update video flag if the actual session has video but JMI didn't indicate it
                if (counterpart_wants_video && !call_states[peer_state.call].we_should_send_video) {
                    debug("on_incoming_call: upgrading we_should_send_video to true (session has video content)");
                    call_states[peer_state.call].we_should_send_video = true;
                    peer_state.we_should_send_video = true;
                }
                peer_state.set_session(session);
                peer_state.accept();
                jmi_request_peer.unset(peer_state.call);
                return;
            }

            // This is a direct call without prior JMI. Ask user.
            if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(session.peer_full_jid.bare_jid, account)) return;
            peer_state = create_received_call(account, session.peer_full_jid, account.full_jid, counterpart_wants_video);
            peer_state.set_session(session);
            Conversation conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(peer_state.call.counterpart.bare_jid, account, Conversation.Type.CHAT);
            call_incoming(peer_state.call, peer_state.call_state, conversation, counterpart_wants_video, false);

            stream_interactor.module_manager.get_module<Xep.JingleRtp.Module>(account, Xep.JingleRtp.Module.IDENTITY).session_info_type.send_ringing(session);
        }

        private static void reject_incoming_rtp_contents(
                Xep.Jingle.Session session) {
            foreach (Xep.Jingle.Content content in session.contents) {
                if (content.content_params is Xep.JingleRtp.Parameters) {
                    content.reject();
                }
            }
        }

        private void reject_jmi_proposal(Account account, Jid proposer,
                string sid) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return;
            Xep.JingleMessageInitiation.Module module = ((!) stream).get_module<
                Xep.JingleMessageInitiation.Module>(
                    Xep.JingleMessageInitiation.Module.IDENTITY);
            module.send_session_reject_to_peer((!) stream, proposer, sid);
            module.send_session_reject_to_self((!) stream, sid);
        }

        private PeerState create_received_call(
                Account account,
                Jid from,
                Jid to,
                bool video_requested,
                Plugins.JmiCallEnginePlugin? selected_jmi_engine = null,
                bool force_direct_jmi_backend = false,
                Jid? local_full_jid = null) {
            Call call = new Call();
            if (from.equals_bare(account.bare_jid)) {
                // Call requested by another of our devices
                call.direction = Call.DIRECTION_OUTGOING;
                call.ourpart = from;
                call.state = Call.State.OTHER_DEVICE;
                call.counterpart = to;
            } else {
                call.direction = Call.DIRECTION_INCOMING;
                call.ourpart = local_full_jid ?? account.full_jid;
                call.state = Call.State.RINGING;
                call.counterpart = from;
            }
            call.add_peer(call.counterpart);
            call.account = account;
            call.time = call.local_time = call.end_time = new DateTime.now_utc();
            call.encryption = Encryption.UNKNOWN;

            Conversation conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).create_conversation(call.counterpart.bare_jid, account, Conversation.Type.CHAT);
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY).add_call(call, conversation);

            Plugins.MujiCallEnginePlugin? selected_muji_engine =
                selected_jmi_engine != null ? get_matching_muji_call_engine(
                    (!) selected_jmi_engine, account, video_requested) : null;
            CallMediaBackend media_backend = selected_jmi_engine != null
                ? CallMediaBackend.GOOGLE_WEBRTC
                : force_direct_jmi_backend
                    ? CallMediaBackend.GOOGLE_WEBRTC
                    : CallMediaBackend.LEGACY_RTP;
            var call_state = new CallState(call, stream_interactor,
                media_backend, selected_jmi_engine, selected_muji_engine);
            connect_call_state_signals(call_state);
            if (force_direct_jmi_backend &&
                    from.equals_bare(account.bare_jid)) {
                pending_own_jmi_mirrors.add(call);
                start_pending_own_jmi_timeout(call);
            }
            call_state.we_should_send_video = video_requested;
            call_state.we_should_send_audio = true;
            PeerState peer_state = call_state.set_first_peer(call.counterpart);

            return peer_state;
        }

        private CallState? get_call_state_for_cim_action(Account account,
                Jid sender, string message_type, string call_id) {
            foreach (CallState call_state in call_states.values) {
                if (call_state.call.account.equals(account) &&
                        call_state.has_cim_action_target(sender, message_type,
                            call_id)) return call_state;
            }
            return null;
        }

        private CallState? get_call_state_for_own_cim_action(Account account,
                Jid destination, string message_type, string call_id) {
            var selection = new CimOwnActionCandidateSelection();
            CallState? candidate = null;
            foreach (CallState call_state in call_states.values) {
                bool destination_matches =
                    call_state.call.account.equals(account) &&
                    call_state.has_cim_destination(destination, message_type,
                        call_id);
                if (selection.consider(
                        call_state.call.direction == Call.DIRECTION_INCOMING,
                        destination_matches)) {
                    candidate = call_state;
                }
            }
            if (selection.is_ambiguous) {
                warning("[%s] Ignoring ambiguous own-resource call action %s to %s",
                    account.bare_jid.to_string(), call_id,
                    destination.to_string());
            }
            return selection.has_unique_match ? candidate : null;
        }

        private CallState? get_outgoing_groupchat_call_by_provisional(
                Account account, Jid room, string provisional_id) {
            foreach (CallState call_state in call_states.values) {
                if (call_state.call.account.equals(account) &&
                        call_state.matches_outgoing_groupchat_provisional(room,
                            provisional_id)) return call_state;
            }
            return null;
        }

        private bool claim_cim_invite_once(Account account, Jid sender,
                string message_type, string call_id) {
            if (cim_invite_replays.try_claim(account, sender, message_type,
                    call_id)) return true;
            debug("[%s] Ignoring replayed call invite %s from %s",
                account.bare_jid.to_string(), call_id, sender.to_string());
            return false;
        }

        private Jid? current_cim_invite_recipient(Account account,
                XmppStream source_stream, Jid recipient) {
            XmppStream? stream = stream_interactor
                .get_connected_stream_for_action(account);
            if (stream == null || ((!) stream) != source_stream) return null;
            Bind.Flag? bind = ((!) stream).get_flag(Bind.Flag.IDENTITY);
            if (bind == null || !((!) bind).finished ||
                    ((!) bind).my_jid == null) return null;
            Jid local = (!) ((!) bind).my_jid;
            if (!local.is_full() || !recipient.equals_bare(local) ||
                    (recipient.is_full() && !recipient.equals(local))) {
                return null;
            }
            // The configured account resource can differ from the resource
            // assigned by the server. Accept the account's bare destination
            // or this connection's exact bound destination, never another
            // device or a stale configured full JID.
            return local;
        }

        private PeerState? get_peer_by_sid(Account account, string sid, Jid jid1, Jid? jid2 = null) {
            Jid relevant_jid = jid1.equals_bare(account.bare_jid) && jid2 != null ? jid2 : jid1;

            foreach (CallState call_state in call_states.values) {
                if (!call_state.call.account.equals(account)) continue;

                foreach (PeerState peer_state in call_state.peers.values) {
                    if (peer_state.sid != sid) continue;
                    if (peer_state.jid.equals_bare(relevant_jid)) {
                        return peer_state;
                    }
                }
            }
            return null;
        }

        private CallState? create_recv_muji_call(
                Account account,
                Jid local_full_jid,
                string call_id,
                Jid inviter_jid,
                Jid muc_jid,
                string message_type,
                bool video_requested,
                MucManager.MucOwnerMutationContext?
                    source_room_context = null,
                Jid? source_inviter_occupant = null,
                Jid? source_inviter_real_jid = null) {
            debug("[%s] Muji call received from %s for MUC %s, type %s", account.bare_jid.to_string(), inviter_jid.to_string(), muc_jid.to_string(), message_type);

            // Arbitrate against every active local call before selecting the
            // one-peer Direct->MUJI conversion path below. In particular, an
            // already published 2+-peer group must not create a second
            // CallState with the same account/call-id/room.
            foreach (Call existing_call in call_states.keys) {
                if (!existing_call.account.equals(account)) continue;
                CallState existing_state = call_states[existing_call];
                bool same_direct_counterpart = false;
                if (existing_call.counterparts.size == 1) {
                    foreach (Jid counterpart in existing_call.counterparts) {
                        same_direct_counterpart =
                            counterpart.equals_bare(inviter_jid);
                    }
                }
                bool convertible = same_direct_counterpart &&
                    existing_state.can_accept_direct_group_conversion(
                        call_id);
                if (existing_call_blocks_new_muji(existing_call.state,
                        convertible)) {
                    debug("[%s] Rejecting MUJI invite while another call lifecycle owns the account",
                        account.bare_jid.to_string());
                    reject_muji_invite(account, inviter_jid, call_id,
                        message_type);
                    return null;
                }
            }

            foreach (Call call in call_states.keys) {
                if (!call.account.equals(account)) continue;

                CallState call_state = call_states[call];

                bool same_direct_counterpart = false;
                if (call.counterparts.size == 1) {
                    foreach (Jid counterpart in call.counterparts) {
                        same_direct_counterpart =
                            counterpart.equals_bare(inviter_jid);
                    }
                }
                if (same_direct_counterpart && call_state.accepted) {
                    // A call is converted into a group call.
                    bool effective_video;
                    if (!call_state.can_accept_direct_group_conversion(
                            call_id) ||
                            !call_state.can_use_selected_muji_engine(
                            video_requested) ||
                            !CallState.direct_to_muji_media_allowed(
                                call_state.we_should_send_video,
                                video_requested, out effective_video)) {
                        debug("[%s] Rejecting duplicate, stale or unavailable MUJI conversion without changing the live call",
                            account.bare_jid.to_string());
                        reject_muji_invite(account, inviter_jid, call_id,
                            message_type);
                        return null;
                    }
                    Jid target = message_type == MessageStanza.TYPE_GROUPCHAT
                        ? inviter_jid.bare_jid : inviter_jid;
                    if (source_room_context != null) {
                        call_state.configure_incoming_group_source(
                            (!) source_room_context,
                            source_inviter_occupant,
                            source_inviter_real_jid);
                    }
                    call_state.accept_direct_group_conversion.begin(call_id,
                        inviter_jid, target, message_type, muc_jid,
                        video_requested, (_, result) => {
                            call_state.accept_direct_group_conversion.end(
                                result);
                        });
                    return null;
                }
            }

            Plugins.JmiCallEnginePlugin? selected_jmi_engine;
            Plugins.MujiCallEnginePlugin? selected_muji_engine;
            if (!try_select_group_engines(account, video_requested,
                    out selected_jmi_engine, out selected_muji_engine)) {
                debug("[%s] Ignoring MUJI invite without a matching media-engine facet",
                    account.bare_jid.to_string());
                return null;
            }

            Call call = new Call();
            call.direction = Call.DIRECTION_INCOMING;
            call.ourpart = local_full_jid;
            call.counterpart = inviter_jid;
            call.account = account;
            call.time = call.local_time = call.end_time = new DateTime.now_utc();
            call.encryption = Encryption.UNKNOWN;
            call.state = Call.State.RINGING;

            ConversationManager conversation_manager = stream_interactor
                .get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            Conversation? conversation = source_room_context != null
                ? conversation_manager.get_conversation(
                    ((!) source_room_context).room, account,
                    Conversation.Type.GROUPCHAT)
                : conversation_manager.create_conversation(
                    inviter_jid.bare_jid, account,
                    Conversation.Type.CHAT);
            if (conversation == null) return null;
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY).add_call(call, conversation);

            CallState call_state = new CallState(call, stream_interactor,
                CallMediaBackend.GOOGLE_WEBRTC, selected_jmi_engine,
                selected_muji_engine);
            connect_call_state_signals(call_state, conversation);
            call_state.invited_to_group_call = muc_jid;
            call_state.configure_cim_invite(call_id, inviter_jid,
                message_type == MessageStanza.TYPE_GROUPCHAT
                    ? inviter_jid.bare_jid : inviter_jid,
                message_type);
            if (source_room_context != null) {
                call_state.configure_incoming_group_source(
                    (!) source_room_context,
                    source_inviter_occupant,
                    source_inviter_real_jid);
            }

            debug("[%s] on_muji_call_received accepting", account.bare_jid.to_string());

            return call_state;
        }

        private void reject_muji_invite(Account account, Jid inviter_jid,
                string call_id, string message_type) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return;
            ((!) stream).get_module<Xep.CallInvites.Module>(
                Xep.CallInvites.Module.IDENTITY).send_reject((!) stream,
                    message_type == MessageStanza.TYPE_GROUPCHAT
                        ? inviter_jid.bare_jid : inviter_jid,
                    call_id, message_type);
        }

        private void send_deferred_cim_groupchat_terminal(Account account,
                Jid room, string call_id, CimTerminalSignalAction action) {
            XmppStream? maybe_stream = stream_interactor.get_stream(account);
            if (maybe_stream == null) return;
            XmppStream stream = (!) maybe_stream;
            Xep.CallInvites.Module module = stream.get_module<
                Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY);
            switch (action) {
                case CimTerminalSignalAction.REJECT:
                    module.send_reject(stream, room.bare_jid, call_id,
                        MessageStanza.TYPE_GROUPCHAT);
                    break;
                case CimTerminalSignalAction.RETRACT:
                    module.send_retract(stream, room.bare_jid, call_id,
                        MessageStanza.TYPE_GROUPCHAT);
                    break;
                case CimTerminalSignalAction.LEFT:
                    module.send_left(stream, room.bare_jid, call_id,
                        MessageStanza.TYPE_GROUPCHAT);
                    break;
                default:
                    break;
            }
        }

        private void remove_call_from_datastructures(Call call) {
            PeerState? jmi_peer = jmi_request_peer[call];
            if (jmi_peer != null) {
                jmi_live_sessions.remove_owner((!) jmi_peer);
            }
            CallState? call_state = call_states[call];
            if (call_state != null) {
                foreach (PeerState peer_state in
                        ((!) call_state).peers.values) {
                    jmi_live_sessions.remove_owner(peer_state);
                }
                disconnect_call_state_signals((!) call_state);
            }
            jmi_request_peer.unset(call);
            group_call_sources.unset(call);
            call_states.unset(call);
        }

        private void disconnect_call_state_signals(CallState call_state) {
            CallStateSignalLease? lease =
                call_state_signal_leases[call_state.call];
            if (lease == null) return;
            call_state_signal_leases.unset(call_state.call);
            ((!) lease).disconnect_all(call_state);
        }

        private void start_pending_own_jmi_timeout(Call call) {
            clear_pending_own_jmi_timeout(call);
            uint source_id = Timeout.add_seconds(
                (uint) JmiArchiveReplayRegistry.DEFAULT_RETENTION_SECONDS,
                () => {
                    pending_own_jmi_timeouts.unset(call);
                    discard_pending_own_jmi_mirror(call);
                    return Source.REMOVE;
                });
            pending_own_jmi_timeouts[call] = source_id;
        }

        private void clear_pending_own_jmi_timeout(Call call) {
            if (!pending_own_jmi_timeouts.has_key(call)) return;
            uint source_id = pending_own_jmi_timeouts[call];
            pending_own_jmi_timeouts.unset(call);
            if (source_id != 0) Source.remove(source_id);
        }

        private void discard_pending_own_jmi_mirror(Call call) {
            if (!pending_own_jmi_mirrors.remove(call)) return;
            clear_pending_own_jmi_timeout(call);
            discard_unpublished_call(call);
        }

        private void discard_unpublished_call(Call call) {
            CallState? call_state = call_states[call];
            if (call_state != null) {
                foreach (PeerState peer in ((!) call_state).peers.values) {
                    peer.cleanup_signal_handlers();
                    if (!peer.discard_google_webrtc_jmi_call_engine_session()) {
                        peer.release_objects();
                    }
                }
            }
            remove_call_from_datastructures(call);
            stream_interactor.get_module<CallStore>(CallStore.IDENTITY)
                .remove_unpublished_call(call);
        }

        private void discard_pending_own_jmi_mirrors(Account account) {
            var pending = new ArrayList<Call>();
            foreach (Call call in pending_own_jmi_mirrors) {
                if (call.account.equals(account)) pending.add(call);
            }
            foreach (Call call in pending) {
                discard_pending_own_jmi_mirror(call);
            }
        }

        private void discard_recovered_jmi_proposals(Account account) {
            var recovered = new ArrayList<RecoveredJmiProposal>();
            foreach (RecoveredJmiProposal proposal in
                    recovered_jmi_proposals.values) {
                if (proposal.call.account.equals(account)) {
                    recovered.add(proposal);
                }
            }
            foreach (RecoveredJmiProposal proposal in recovered) {
                CallState? call_state = call_states[proposal.call];
                if (call_state != null) {
                    ((!) call_state).cancel_establishing_timeout();
                    foreach (PeerState peer in
                            ((!) call_state).peers.values) {
                        peer.cleanup_signal_handlers();
                        if (!peer.discard_google_webrtc_jmi_call_engine_session()) {
                            peer.release_objects();
                        }
                    }
                }
                recovered_jmi_proposals.unset(proposal.call);
                remove_call_from_datastructures(proposal.call);
            }
        }

        /** Keep the passive call visible but impossible to accept until MAM settles. */
        private void suspend_recovered_jmi_proposals(Account account) {
            foreach (RecoveredJmiProposal proposal in
                    recovered_jmi_proposals.values) {
                if (!proposal.call.account.equals(account)) continue;
                CallState? call_state = call_states[proposal.call];
                if (call_state == null) continue;
                ((!) call_state).set_archive_recovery_pending(true);
                ((!) call_state).cancel_establishing_timeout();
            }
        }

        private void rebind_recovered_jmi_proposals(Account account) {
            var recovered = new ArrayList<RecoveredJmiProposal>();
            foreach (RecoveredJmiProposal proposal in
                    recovered_jmi_proposals.values) {
                if (proposal.call.account.equals(account)) {
                    recovered.add(proposal);
                }
            }
            foreach (RecoveredJmiProposal proposal in recovered) {
                if (!call_states.has_key(proposal.call) ||
                        !jmi_incoming_is_authorized(account,
                            proposal.proposal_source)) {
                    CallState? rejected = call_states[proposal.call];
                    if (rejected != null) {
                        ((!) rejected).finish_remote_jmi(
                            proposal.proposal_source,
                            Xep.Jingle.ReasonElement.EXPIRED,
                            "Recovered proposal is no longer authorised");
                    }
                    continue;
                }
                JmiLiveSessionEntry? entry =
                    jmi_live_sessions.register_recovered(account,
                        proposal.proposal_source, proposal.sid,
                        proposal.proposal_source,
                        proposal.proposal_target, proposal.peer_state);
                if (entry == null) {
                    call_states[proposal.call].finish_remote_jmi(
                        proposal.proposal_source,
                        Xep.Jingle.ReasonElement.EXPIRED,
                        "Recovered proposal lost lifecycle ownership");
                    continue;
                }
                ((!) entry).set_incoming_proposal_details(
                    proposal.descriptions, proposal.video_requested);
            }
        }

        /** Make rebound proposals actionable only after authoritative catch-up. */
        private void activate_recovered_jmi_proposals(Account account,
                XmppStream stream) {
            DateTime now = new DateTime.now_utc();
            var recovered = new ArrayList<RecoveredJmiProposal>();
            foreach (RecoveredJmiProposal proposal in
                    recovered_jmi_proposals.values) {
                if (proposal.call.account.equals(account)) {
                    recovered.add(proposal);
                }
            }

            foreach (RecoveredJmiProposal proposal in recovered) {
                CallState? call_state = call_states[proposal.call];
                if (call_state == null ||
                        !recovered_jmi_store.owns(proposal.call,
                            proposal.sid)) continue;
                if (proposal.expires_at.compare(now) <= 0 ||
                        !jmi_incoming_is_authorized(account,
                            proposal.proposal_source)) {
                    ((!) call_state).finish_remote_jmi(
                        proposal.proposal_source,
                        Xep.Jingle.ReasonElement.EXPIRED,
                        "Recovered proposal expired during archive catch-up");
                    continue;
                }
                if (!jmi_archive_replays.permits_persisted_recovery(account,
                        stream, proposal.proposal_source, proposal.sid,
                        now)) {
                    ((!) call_state).set_archive_recovery_pending(true);
                    ((!) call_state).start_recovered_jmi_timeout(
                        proposal.peer_state, proposal.sid,
                        (uint) int64.min(uint.MAX, int64.max(1,
                            proposal.expires_at.to_unix() - now.to_unix())));
                    continue;
                }
                Plugins.JmiCallEnginePlugin? selected =
                    ((!) call_state).get_selected_jmi_call_engine();
                Plugins.JmiCallEnginePlugin? available =
                    get_google_webrtc_jmi_call_engine(account,
                        proposal.video_requested);
                if (selected == null || available == null ||
                        (!) selected != (!) available) {
                    // Preserve the bounded record; a later reconnect may make
                    // the exact immutable backend available again.
                    continue;
                }
                JmiLiveSessionEntry? entry =
                    jmi_live_sessions.find_by_owner(proposal.peer_state);
                if (entry == null) {
                    entry = jmi_live_sessions.register_recovered(account,
                        proposal.proposal_source, proposal.sid,
                        proposal.proposal_source,
                        proposal.proposal_target, proposal.peer_state);
                }
                if (entry == null) {
                    ((!) call_state).finish_remote_jmi(
                        proposal.proposal_source,
                        Xep.Jingle.ReasonElement.EXPIRED,
                        "Recovered proposal lost lifecycle ownership");
                    continue;
                }
                ((!) entry).set_incoming_proposal_details(
                    proposal.descriptions, proposal.video_requested);
                ((!) call_state).set_archive_recovery_pending(false);
                ((!) call_state).start_recovered_jmi_timeout(
                    proposal.peer_state, proposal.sid,
                    (uint) int64.min(uint.MAX, int64.max(1,
                        proposal.expires_at.to_unix() - now.to_unix())));
            }
        }

        /** Keep an uncertain proposal passive while retaining its age bound. */
        private void arm_pending_recovered_jmi_expiry(Account account) {
            DateTime now = new DateTime.now_utc();
            var recovered = new ArrayList<RecoveredJmiProposal>();
            foreach (RecoveredJmiProposal proposal in
                    recovered_jmi_proposals.values) {
                if (proposal.call.account.equals(account)) {
                    recovered.add(proposal);
                }
            }
            foreach (RecoveredJmiProposal proposal in recovered) {
                CallState? call_state = call_states[proposal.call];
                if (call_state == null) continue;
                ((!) call_state).set_archive_recovery_pending(true);
                if (proposal.expires_at.compare(now) <= 0) {
                    ((!) call_state).finish_remote_jmi(
                        proposal.proposal_source,
                        Xep.Jingle.ReasonElement.EXPIRED,
                        "Recovered proposal expired without authoritative archive catch-up");
                    continue;
                }
                ((!) call_state).start_recovered_jmi_timeout(
                    proposal.peer_state, proposal.sid,
                    (uint) int64.min(uint.MAX, int64.max(1,
                        proposal.expires_at.to_unix() - now.to_unix())));
            }
        }

        /** Restore only proposals whose dedicated restart record is intact. */
        private void restore_persisted_jmi_proposals(Account account,
                XmppStream stream) {
            DateTime now = new DateTime.now_utc();
            ConversationManager conversation_manager =
                stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            CallStore call_store = stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY);

            foreach (JmiRecoveredProposalRecord record in
                    recovered_jmi_store.load(account)) {
                bool already_loaded = false;
                foreach (RecoveredJmiProposal proposal in
                        recovered_jmi_proposals.values) {
                    if (proposal.call.id == record.call_id) {
                        already_loaded = true;
                        break;
                    }
                }
                if (already_loaded) continue;

                Conversation? conversation = conversation_manager
                    .get_conversation_by_id(record.conversation_id);
                if (conversation == null ||
                        !((!) conversation).account.equals(account) ||
                        ((!) conversation).type_ != Conversation.Type.CHAT) {
                    recovered_jmi_store.remove_call_id(record.call_id);
                    continue;
                }
                Call? call = call_store.get_call_by_id(record.call_id,
                    (!) conversation);
                if (call == null || !((!) call).account.equals(account)) {
                    recovered_jmi_store.remove_call_id(record.call_id);
                    continue;
                }

                Jid proposal_source;
                Jid proposal_target;
                try {
                    proposal_source = new Jid(record.proposal_source);
                    proposal_target = new Jid(record.proposal_target);
                } catch (InvalidJidError error) {
                    terminalize_persisted_jmi_proposal((!) call, now,
                        Call.State.MISSED);
                    continue;
                }

                DateTime started_at = new DateTime.from_unix_utc(
                    record.started_at);
                DateTime expires_at = new DateTime.from_unix_utc(
                    record.expires_at);
                if (expires_at.compare(now) <= 0) {
                    terminalize_persisted_jmi_proposal((!) call, expires_at,
                        Call.State.MISSED);
                    continue;
                }
                if (proposal_source.resourcepart == null ||
                        !proposal_source.equals_bare(((!) call).counterpart) ||
                        !proposal_target.equals_bare(account.bare_jid) ||
                        (!record.audio_requested &&
                            !record.video_requested) ||
                        !jmi_incoming_is_authorized(account,
                            proposal_source) ||
                        jmi_peer_is_muc(account, proposal_source)) {
                    terminalize_persisted_jmi_proposal((!) call, now,
                        Call.State.MISSED);
                    continue;
                }
                Call? sid_owner = call_store.get_call_by_jmi_sid(account,
                    record.sid, (!) conversation);
                if (sid_owner == null || ((!) sid_owner).id != record.call_id) {
                    terminalize_persisted_jmi_proposal((!) call, now,
                        Call.State.FAILED);
                    continue;
                }
                if (!jmi_archive_replays.permits_persisted_recovery(account,
                        stream, proposal_source, record.sid, now)) {
                    continue;
                }
                if (get_google_webrtc_jmi_call_engine(account,
                        record.video_requested) == null) {
                    // Keep the bounded restart record. A later reconnect may
                    // make the exact selected backend available again.
                    continue;
                }

                var replay = new JmiArchiveReplayResult(account,
                    proposal_source.bare_jid, proposal_source,
                    proposal_target, record.sid,
                    Call.DIRECTION_INCOMING, record.video_requested,
                    Call.State.RINGING, started_at, expires_at, null, false,
                    null, true, record.build_descriptions());
                if (!recover_jmi_archive_proposal(replay, (!) call,
                        (!) conversation, true)) {
                    JmiProposalDisposition disposition =
                        jmi_live_sessions.inspect_proposal(account,
                            proposal_source, record.sid, proposal_source);
                    if (disposition == JmiProposalDisposition.TERMINAL ||
                            disposition ==
                                JmiProposalDisposition.CONFLICT) {
                        terminalize_persisted_jmi_proposal((!) call, now,
                            Call.State.MISSED);
                    }
                }
            }
        }

        private void terminalize_persisted_jmi_proposal(Call call,
                DateTime ended_at, Call.State state) {
            recovered_jmi_store.remove(call);
            call.end_time = ended_at;
            call.state = state;
        }

        // End all active calls for an account when the connection is lost.
        // Without ICE restart support, media can't recover even if SM resumes
        // the XMPP session — the UDP paths are dead.
        private void on_connection_lost(Account account) {
            forget_group_rejoins_for_account(account);
            discard_pending_own_jmi_mirrors(account);
            jmi_live_sessions.clear_account(account);
            suspend_recovered_jmi_proposals(account);
            clear_jmi_archive_expiry_timeout(account);
            jmi_archive_replays.clear_account(account);
            var active = new ArrayList<CallState>();
            foreach (var entry in call_states.entries) {
                if (!entry.key.account.equals(account)) continue;
                if (recovered_jmi_proposals.has_key(entry.key)) continue;
                Call.State s = entry.key.state;
                if (s == Call.State.IN_PROGRESS || s == Call.State.ESTABLISHING || s == Call.State.RINGING) {
                    active.add(entry.value);
                }
            }
            if (active.size == 0) {
                deferred_cim_groupchat_terminals.clear_account(account);
                return;
            }
            debug("[%s] Connection lost — ending %d active call(s)", account.bare_jid.to_string(), active.size);
            foreach (CallState cs in active) {
                cs.end("Connection lost");
            }
            deferred_cim_groupchat_terminals.clear_account(account);
        }

        private void connect_call_state_signals(CallState call_state,
                Conversation? group_source = null) {
            CallState? previous_state = call_states[call_state.call];
            if (previous_state != null) {
                disconnect_call_state_signals((!) previous_state);
            }
            call_states[call_state.call] = call_state;
            var signal_lease = new CallStateSignalLease();
            call_state_signal_leases[call_state.call] = signal_lease;
            if (group_source != null &&
                    ((!) group_source).type_ == Conversation.Type.GROUPCHAT) {
                Conversation source = (!) group_source;
                group_call_sources[call_state.call] = source;
                signal_lease.group_rejoin_handler_id = call_state.notify["group-call"].connect(() => {
                    remember_group_call(call_state, source);
                });
                signal_lease.group_rejoin_state_handler_id = call_state.call.notify["state"].connect(() => {
                    remember_group_call(call_state, source);
                });
            }

            signal_lease.deferred_terminal_handler_id =
                call_state.cim_groupchat_terminal_deferred.connect(
                    (room, provisional_id, action) => {
                        deferred_cim_groupchat_terminals.defer(
                            call_state.call.account, room, provisional_id,
                            action);
                    });

            signal_lease.terminal_persist_handler_id =
                call_state.terminal_state_will_persist.connect(() => {
                    recovered_jmi_store.remove(call_state.call);
                    recovered_jmi_proposals.unset(call_state.call);
                });

            signal_lease.terminated_handler_id = call_state.terminated.connect((who_terminated, reason_name, reason_text) => {
                // Idempotent safety net; the pre-terminal signal above owns
                // crash ordering, this also covers any future terminal path.
                recovered_jmi_store.remove(call_state.call);
                recovered_jmi_proposals.unset(call_state.call);
                foreach (string sid in
                        call_state.call.snapshot_jmi_sids()) {
                    jmi_archive_replays.forget(call_state.call.account,
                        call_state.call.counterpart, sid);
                }
                // XEP-0353 expects both active endpoints to publish finish.
                // The live entry owns a one-shot target, so a remote finish
                // or Jingle terminate can never recurse into duplicates.
                publish_jmi_finish(call_state.call, reason_name);
                if (pending_own_jmi_mirrors.remove(call_state.call)) {
                    clear_pending_own_jmi_timeout(call_state.call);
                    Conversation conversation = stream_interactor.get_module<
                        ConversationManager>(ConversationManager.IDENTITY)
                            .create_conversation(
                                call_state.call.counterpart.bare_jid,
                                call_state.call.account,
                                Conversation.Type.CHAT);
                    stream_interactor.get_module<ContentItemStore>(
                        ContentItemStore.IDENTITY).insert_replayed_call(
                            call_state.call, conversation);
                }
                foreach (PeerState peer_state in call_state.peers.values) {
                    peer_state.discard_google_webrtc_jmi_call_engine_session();
                }
                remove_call_from_datastructures(call_state.call);
                call_terminated(call_state.call, reason_name, reason_text);
            });
        }

        private void on_jmi_event(Account account, XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event) {
            XmppStream? current_stream = stream_interactor.get_stream(account);
            if (current_stream == null || ((!) current_stream) != stream) {
                debug("[%s] Ignoring JMI action from a stale stream",
                    account.bare_jid.to_string());
                return;
            }
            if (event.delivery == Xep.JingleMessageInitiation.Delivery.MAM ||
                    event.delivery ==
                        Xep.JingleMessageInitiation.Delivery.DELAYED) {
                on_jmi_archive_event(account, stream, event);
                return;
            }
            if (event.delivery == Xep.JingleMessageInitiation.Delivery.LIVE &&
                    event.timestamp != null) {
                debug("[%s] Deferring delayed JMI action %s sid=%s",
                    account.bare_jid.to_string(), event.action.to_string(),
                    event.sid);
                return;
            }

            reconcile_jmi_archive_followup(account, stream, event);

            switch (event.action) {
                case Xep.JingleMessageInitiation.Action.PROPOSE:
                    on_jmi_proposed(account, stream, event);
                    break;
                case Xep.JingleMessageInitiation.Action.RINGING:
                    on_jmi_ringing(account, event);
                    break;
                case Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT:
                    on_jmi_legacy_accept(account, event);
                    break;
                case Xep.JingleMessageInitiation.Action.PROCEED:
                    on_jmi_proceeded(account, event);
                    break;
                case Xep.JingleMessageInitiation.Action.REJECT:
                    on_jmi_rejected(account, event);
                    break;
                case Xep.JingleMessageInitiation.Action.RETRACT:
                    on_jmi_retracted(account, event);
                    break;
                case Xep.JingleMessageInitiation.Action.FINISH:
                    on_jmi_finished(account, event);
                    break;
            }
        }

        private void on_jmi_archive_event(Account account, XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event) {
            if (event.timestamp == null) return;
            Jid? peer = jmi_event_peer(account, event);
            if (peer == null || ((!) peer).equals_bare(account.bare_jid) ||
                    jmi_peer_is_muc(account, (!) peer)) return;

            bool video_requested = false;
            if (event.action ==
                    Xep.JingleMessageInitiation.Action.PROPOSE) {
                bool from_own = event.from.equals_bare(account.bare_jid);
                if (event.from.resourcepart == null ||
                        (!from_own && !jmi_incoming_is_authorized(account,
                            event.from))) return;
                bool audio_requested = event.descriptions.any_match(
                    (description) =>
                        description.ns_uri == Xep.JingleRtp.NS_URI &&
                        description.get_attribute("media") == "audio");
                video_requested = event.descriptions.any_match(
                    (description) =>
                        description.ns_uri == Xep.JingleRtp.NS_URI &&
                        description.get_attribute("media") == "video");
                if (!audio_requested && !video_requested) return;
            }

            if (event.delivery ==
                    Xep.JingleMessageInitiation.Delivery.MAM) {
                jmi_archive_replays.observe_archive(account, stream,
                    event.from, event.to, event.sid, event.action,
                    (!) event.timestamp, video_requested, event.reason,
                    event.tie_break, event.migrated_to_sid,
                    event.descriptions);
                return;
            }

            foreach (JmiArchiveReplayResult replay in
                    jmi_archive_replays.observe_delayed(account, stream,
                        event.from, event.to, event.sid, event.action,
                        (!) event.timestamp, new DateTime.now_utc(),
                        video_requested, event.reason, event.tie_break,
                        event.migrated_to_sid, event.descriptions)) {
                publish_jmi_archive_result(replay);
            }
            schedule_jmi_archive_expiry(account, stream);
        }

        private void on_jmi_archive_sync_finished(Account account,
                XmppStream stream, HistorySync.FetchResult result) {
            XmppStream? current_stream = stream_interactor.get_stream(account);
            if (current_stream == null || ((!) current_stream) != stream) return;
            if (result == HistorySync.FetchResult.SUCCESS) {
                foreach (JmiArchiveReplayResult replay in
                        jmi_archive_replays.settle_success(account, stream,
                            new DateTime.now_utc())) {
                    publish_jmi_archive_result(replay);
                }
                activate_recovered_jmi_proposals(account, stream);
                restore_persisted_jmi_proposals(account, stream);
                schedule_jmi_archive_expiry(account, stream);
            } else if (result == HistorySync.FetchResult.ERROR ||
                    result == HistorySync.FetchResult.UNAVAILABLE) {
                // A partial failed page cannot authoritatively describe a call.
                clear_jmi_archive_expiry_timeout(account);
                jmi_archive_replays.settle_failed(account, stream);
                arm_pending_recovered_jmi_expiry(account);
            }
            // CANCELLED is retryable on the same stream. Its bounded partial
            // state is retained and merged into the next successful catch-up.
        }

        private void reconcile_jmi_archive_followup(Account account,
                XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event) {
            if (event.action == Xep.JingleMessageInitiation.Action.PROPOSE ||
                    event.action == Xep.JingleMessageInitiation.Action.RINGING ||
                    event.timestamp != null) return;
            JmiArchiveReplayResult? replay =
                jmi_archive_replays.observe_live_followup(account, stream,
                    event.from, event.to, event.sid, event.action,
                    new DateTime.now_utc(), event.reason, event.tie_break,
                    event.migrated_to_sid);
            if (replay != null) {
                publish_jmi_archive_result((!) replay);
                schedule_jmi_archive_expiry(account, stream);
            }
        }

        private void schedule_jmi_archive_expiry(Account account,
                XmppStream stream) {
            clear_jmi_archive_expiry_timeout(account);
            int64 delay_seconds =
                jmi_archive_replays.next_expiry_delay_seconds(account, stream,
                    new DateTime.now_utc());
            if (delay_seconds < 0) return;

            uint bounded_delay = (uint) int64.min(uint.MAX,
                int64.max(1, delay_seconds));
            uint source_id = Timeout.add_seconds(bounded_delay, () => {
                    jmi_archive_expiry_timeouts.unset(account);
                    XmppStream? current_stream =
                        stream_interactor.get_stream(account);
                    if (current_stream == null ||
                            ((!) current_stream) != stream) {
                        return Source.REMOVE;
                    }
                    foreach (JmiArchiveReplayResult replay in
                            jmi_archive_replays.expire_settled(account, stream,
                                new DateTime.now_utc())) {
                        publish_jmi_archive_result(replay);
                    }
                    schedule_jmi_archive_expiry(account, stream);
                    return Source.REMOVE;
                });
            jmi_archive_expiry_timeouts[account] = source_id;
        }

        private void clear_jmi_archive_expiry_timeout(Account account) {
            if (!jmi_archive_expiry_timeouts.has_key(account)) return;
            uint source_id = jmi_archive_expiry_timeouts[account];
            jmi_archive_expiry_timeouts.unset(account);
            if (source_id != 0) Source.remove(source_id);
        }

        private static Jid? jmi_event_peer(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            bool from_own = event.from.equals_bare(account.bare_jid);
            bool to_own = event.to.equals_bare(account.bare_jid);
            if (from_own == to_own) return null;
            return (from_own ? event.to : event.from).bare_jid;
        }

        private void publish_jmi_archive_result(
                JmiArchiveReplayResult replay) {
            Conversation conversation = stream_interactor.get_module<
                ConversationManager>(ConversationManager.IDENTITY)
                    .create_conversation(replay.peer, replay.account,
                        Conversation.Type.CHAT);
            CallStore call_store = stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY);
            Call? sid_call = call_store.get_call_by_jmi_sid(replay.account,
                replay.sid, conversation);
            Call? migrated_call = replay.migrated_to_sid != null
                ? call_store.get_call_by_jmi_sid(replay.account,
                    (!) replay.migrated_to_sid, conversation) : null;
            if (sid_call != null && migrated_call != null &&
                    ((!) sid_call).id != ((!) migrated_call).id) {
                warning("[%s] Ignoring conflicting archived JMI migration %s -> %s",
                    replay.account.bare_jid.to_string(), replay.sid,
                    (!) replay.migrated_to_sid);
                return;
            }
            Call? call = sid_call ?? migrated_call;
            if (call != null && (!((!) call).account.equals(replay.account) ||
                    !((!) call).counterpart.equals_bare(replay.peer))) {
                warning("[%s] Ignoring archived JMI SID %s with conflicting peer ownership",
                    replay.account.bare_jid.to_string(), replay.sid);
                return;
            }

            if (replay.actionable) {
                recover_jmi_archive_proposal(replay, call, conversation);
                return;
            }
            publish_jmi_archive_terminal(replay, call, conversation);
        }

        private bool claim_jmi_archive_identities(Call call,
                JmiArchiveReplayResult replay) {
            return stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY).claim_jmi_sids(call,
                    jmi_archive_identities(replay));
        }

        private ArrayList<string> jmi_archive_identities(
                JmiArchiveReplayResult replay) {
            var sids = new ArrayList<string>();
            sids.add(replay.sid);
            if (replay.migrated_to_sid != null) {
                sids.add((!) replay.migrated_to_sid);
            }
            return sids;
        }

        /**
         * Recreate only signaling/UI ownership. No call signal, ringtone,
         * notification or native session is allocated until the user accepts.
         */
        private bool recover_jmi_archive_proposal(
                JmiArchiveReplayResult replay, Call? existing_call,
                Conversation conversation, bool rebind_persisted = false) {
            DateTime now = new DateTime.now_utc();
            int64 remaining_seconds = replay.ended_at.to_unix() -
                now.to_unix();
            if (replay.direction != Call.DIRECTION_INCOMING ||
                    replay.state != Call.State.RINGING ||
                    replay.proposal_source.resourcepart == null ||
                    !replay.proposal_source.equals_bare(replay.peer) ||
                    !replay.proposal_target.equals_bare(
                        replay.account.bare_jid) ||
                    replay.descriptions.is_empty || remaining_seconds <= 0 ||
                    !jmi_incoming_is_authorized(replay.account,
                        replay.proposal_source) ||
                    jmi_peer_is_muc(replay.account, replay.peer)) return false;

            bool video_requested = replay.video_requested;
            Plugins.JmiCallEnginePlugin? selected_jmi_engine =
                get_google_webrtc_jmi_call_engine(replay.account,
                    video_requested);
            if (selected_jmi_engine == null) return false;

            JmiProposalDisposition disposition =
                jmi_live_sessions.inspect_proposal(replay.account,
                    replay.peer, replay.sid, replay.proposal_source);
            bool persisted_rebind_is_proven = rebind_persisted &&
                existing_call != null && recovered_jmi_store.owns(
                    (!) existing_call, replay.sid);
            bool disposition_allowed = !rebind_persisted
                ? disposition == JmiProposalDisposition.NEW
                : persisted_rebind_is_proven &&
                    disposition != JmiProposalDisposition.CONFLICT &&
                    disposition != JmiProposalDisposition.DUPLICATE;
            if (!disposition_allowed) {
                if (disposition == JmiProposalDisposition.CONFLICT) {
                    warning("[%s] Ignoring recovered JMI proposal %s with live ownership conflict",
                        replay.account.bare_jid.to_string(), replay.sid);
                }
                return false;
            }

            Call call;
            bool created = existing_call == null;
            if (created) {
                call = new Call();
                call.account = replay.account;
                call.direction = Call.DIRECTION_INCOMING;
                call.counterpart = replay.proposal_source;
                call.ourpart = replay.account.full_jid;
                call.time = call.local_time = replay.started_at;
                call.end_time = replay.ended_at;
                call.encryption = Encryption.UNKNOWN;
                call.state = Call.State.RINGING;
                stream_interactor.get_module<CallStore>(CallStore.IDENTITY)
                    .add_call(call, conversation);
            } else {
                call = (!) existing_call;
                if (call_states.has_key(call) ||
                        !recovered_jmi_store.owns(call, replay.sid)) {
                    return false;
                }
            }

            var previous_sids = new HashSet<string>();
            previous_sids.add_all(call.snapshot_jmi_sids());

            bool audio_requested = replay.descriptions.any_match(
                (description) =>
                    description.ns_uri == Xep.JingleRtp.NS_URI &&
                    description.get_attribute("media") == "audio");
            if (!recovered_jmi_store.save_with_sids(call, conversation,
                    replay.sid,
                    replay.proposal_source, replay.proposal_target,
                    replay.started_at, replay.ended_at, audio_requested,
                    video_requested, jmi_archive_identities(replay))) {
                if (created) {
                    stream_interactor.get_module<CallStore>(
                        CallStore.IDENTITY).remove_unpublished_call(call);
                }
                return false;
            }

            if (!created) {
                call.direction = Call.DIRECTION_INCOMING;
                call.counterpart = replay.proposal_source;
                call.ourpart = replay.account.full_jid;
                if (replay.started_at.compare(call.time) < 0) {
                    call.time = call.local_time = replay.started_at;
                }
                call.end_time = replay.ended_at;
                call.encryption = Encryption.UNKNOWN;
            }

            Plugins.MujiCallEnginePlugin? selected_muji_engine =
                get_matching_muji_call_engine((!) selected_jmi_engine,
                    replay.account, video_requested);
            var call_state = new CallState(call, stream_interactor,
                CallMediaBackend.GOOGLE_WEBRTC, selected_jmi_engine,
                selected_muji_engine);
            call_state.we_should_send_video = video_requested;
            call_state.we_should_send_audio = true;
            PeerState peer_state = call_state.set_first_peer(
                replay.proposal_source);
            peer_state.sid = replay.sid;

            JmiLiveSessionEntry? entry = rebind_persisted
                ? jmi_live_sessions.register_recovered(replay.account,
                    replay.peer, replay.sid, replay.proposal_source,
                    replay.proposal_target, peer_state)
                : jmi_live_sessions.register(replay.account,
                    replay.peer, replay.sid, replay.proposal_source,
                    replay.proposal_target, true, peer_state);
            if (entry == null) {
                recovered_jmi_store.remove(call);
                rollback_new_jmi_identities(call, previous_sids);
                peer_state.cleanup_signal_handlers();
                if (!peer_state.discard_google_webrtc_jmi_call_engine_session()) {
                    peer_state.release_objects();
                }
                if (created) {
                    stream_interactor.get_module<CallStore>(
                        CallStore.IDENTITY).remove_unpublished_call(call);
                } else {
                    call.end_time = now;
                    call.state = Call.State.MISSED;
                }
                return false;
            }
            ((!) entry).set_incoming_proposal_details(replay.descriptions,
                video_requested);

            connect_call_state_signals(call_state);
            jmi_request_peer[call] = peer_state;
            recovered_jmi_proposals[call] = new RecoveredJmiProposal(call,
                peer_state, replay.proposal_source, replay.proposal_target,
                replay.sid, video_requested, replay.descriptions,
                replay.ended_at);
            // Publish CallState ownership before notifying an already rendered
            // historical widget that this lifecycle is actionable again.
            if (!created) call.state = Call.State.RINGING;

            stream_interactor.get_module<ContentItemStore>(
                ContentItemStore.IDENTITY).insert_replayed_call(call,
                    conversation);
            call_state.start_recovered_jmi_timeout(peer_state, replay.sid,
                (uint) int64.min(uint.MAX,
                    int64.max(1, remaining_seconds)));
            return true;
        }

        private void rollback_new_jmi_identities(Call call,
                Gee.Set<string> previous_sids) {
            var current_sids = new ArrayList<string>();
            current_sids.add_all(call.snapshot_jmi_sids());
            CallStore call_store = stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY);
            foreach (string sid in current_sids) {
                if (!previous_sids.contains(sid)) {
                    call_store.release_jmi_sid(call, sid);
                }
            }
        }

        private void publish_jmi_archive_terminal(
                JmiArchiveReplayResult replay, Call? existing_call,
                Conversation conversation) {
            Call call;
            if (existing_call == null) {
                call = new Call();
                call.account = replay.account;
                call.direction = replay.direction;
                call.counterpart = replay.direction ==
                        Call.DIRECTION_OUTGOING
                    ? replay.proposal_target : replay.proposal_source;
                call.ourpart = replay.direction == Call.DIRECTION_OUTGOING
                    ? replay.proposal_source : replay.proposal_target;
                call.add_peer(replay.peer);
                call.time = call.local_time = replay.started_at;
                call.end_time = replay.ended_at;
                call.encryption = Encryption.UNKNOWN;
                call.state = replay.state;
                CallStore call_store = stream_interactor.get_module<
                    CallStore>(CallStore.IDENTITY);
                call_store.add_call(call, conversation);
                if (!claim_jmi_archive_identities(call, replay)) {
                    call_store.remove_unpublished_call(call);
                    return;
                }
                stream_interactor.get_module<ContentItemStore>(
                    ContentItemStore.IDENTITY).insert_replayed_call(call,
                        conversation);
                return;
            }

            call = (!) existing_call;
            if (!claim_jmi_archive_identities(call, replay)) {
                warning("[%s] Ignoring archived JMI terminal %s with conflicting SID ownership",
                    replay.account.bare_jid.to_string(), replay.sid);
                return;
            }
            if (replay.started_at.compare(call.time) < 0) {
                call.time = call.local_time = replay.started_at;
            }

            CallState? call_state = call_states[call];
            PeerState? peer_state = jmi_request_peer[call];
            JmiLiveSessionEntry? live_entry = peer_state != null
                ? jmi_live_sessions.find_by_owner((!) peer_state) : null;
            if (call_state != null && live_entry != null &&
                    ((!) live_entry).sid != replay.sid) {
                // An old migrated SID ending must not terminate the current
                // replacement leg. The stable SID mapping above is sufficient.
                return;
            }
            recovered_jmi_store.remove(call);
            if (call_state != null) {
                if (peer_state != null) {
                    jmi_live_sessions.remove_owner((!) peer_state);
                }
                recovered_jmi_proposals.unset(call);
                ((!) call_state).finish_replayed_jmi(replay.state,
                    replay.peer, replay.ended_at,
                    replay.reason != null ? ((!) replay.reason).condition
                        : null,
                    replay.reason != null ? ((!) replay.reason).text : null);
                return;
            }

            call.end_time = replay.ended_at;
            call.state = replay.state;
            stream_interactor.get_module<ContentItemStore>(
                ContentItemStore.IDENTITY).insert_replayed_call(call,
                    conversation);
        }

        private bool jmi_peer_is_muc(Account account, Jid peer) {
            if (peer.equals_bare(account.bare_jid)) return false;
            return stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY).might_be_groupchat(peer.bare_jid,
                    account);
        }

        private PeerState? live_peer_for_entry(
                JmiLiveSessionEntry? entry) {
            if (entry == null) return null;
            PeerState? peer_state = ((!) entry).owner as PeerState;
            if (peer_state == null ||
                    !call_states.has_key(((!) peer_state).call)) {
                if (peer_state != null) {
                    jmi_live_sessions.remove_owner((!) peer_state);
                }
                return null;
            }
            return peer_state;
        }

        private bool jmi_incoming_is_authorized(Account account, Jid peer) {
            bool blocked = stream_interactor.get_module<BlockingManager>(
                BlockingManager.IDENTITY).is_blocked(account, peer.bare_jid);
            Roster.Item? roster_item = stream_interactor.get_module<
                RosterManager>(RosterManager.IDENTITY).get_roster_item(account,
                    peer.bare_jid);
            return JmiIncomingAuthorization.is_allowed(blocked,
                roster_item != null ? ((!) roster_item).subscription : null);
        }

        internal bool ensure_google_webrtc_jmi_incoming_session(
                PeerState peer_state) {
            if (peer_state.uses_google_webrtc_jmi_call_engine_session()) {
                return true;
            }
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_by_owner(peer_state);
            if (entry == null || !((!) entry).incoming ||
                    !((!) entry).has_incoming_descriptions() ||
                    !((!) entry).proposal_source.equals(peer_state.jid) ||
                    peer_state.call.direction != Call.DIRECTION_INCOMING ||
                    !call_states.has_key(peer_state.call)) return false;
            CallState call_state = call_states[peer_state.call];
            Plugins.JmiCallEnginePlugin? engine =
                call_state.get_selected_jmi_call_engine();
            if (engine == null) return false;
            bool attached = maybe_attach_google_webrtc_jmi_incoming_engine(
                peer_state.call.account, peer_state,
                ((!) entry).proposal_source, ((!) entry).sid,
                ((!) entry).copy_incoming_descriptions(),
                ((!) entry).incoming_video_requested, (!) engine);
            if (attached) {
                recovered_jmi_store.remove(peer_state.call);
                recovered_jmi_proposals.unset(peer_state.call);
            }
            return attached;
        }

        internal bool reserve_jmi_local_proceed(PeerState peer_state,
                Jid peer_full_jid, Jid local_full_jid) {
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_by_owner(peer_state);
            return entry != null &&
                ((!) entry).reserve_local_proceed(peer_full_jid,
                    local_full_jid);
        }

        internal bool commit_jmi_local_proceed(PeerState peer_state,
                Jid peer_full_jid, Jid local_full_jid) {
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_by_owner(peer_state);
            if (entry == null ||
                    !((!) entry).commit_local_proceed(peer_full_jid,
                        local_full_jid)) return false;
            jmi_archive_replays.forget(peer_state.call.account,
                peer_state.jid, ((!) entry).sid);
            CallState? call_state = call_states[peer_state.call];
            if (call_state != null) {
                ((!) call_state).start_direct_jmi_setup_timeout(peer_state,
                    ((!) entry).sid, DIRECT_JMI_SETUP_TIMEOUT_SECONDS);
            }
            return true;
        }

        internal void rollback_jmi_local_proceed(PeerState peer_state,
                Jid peer_full_jid, Jid local_full_jid) {
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_by_owner(peer_state);
            if (entry != null) {
                ((!) entry).rollback_local_proceed(peer_full_jid,
                    local_full_jid);
            }
        }

        private static string normalize_jmi_finish_reason(
                string? reason_name) {
            switch (reason_name) {
                case Xep.Jingle.ReasonElement.EXPIRED:
                    return Xep.Jingle.ReasonElement.EXPIRED;
                case Xep.Jingle.ReasonElement.CONNECTIVITY_ERROR:
                case Xep.Jingle.ReasonElement.FAILED_TRANSPORT:
                    return Xep.Jingle.ReasonElement.CONNECTIVITY_ERROR;
                case Xep.Jingle.ReasonElement.FAILED_APPLICATION:
                case Xep.Jingle.ReasonElement.UNSUPPORTED_APPLICATIONS:
                case Xep.Jingle.ReasonElement.GENERAL_ERROR:
                    return Xep.Jingle.ReasonElement.FAILED_APPLICATION;
                default:
                    return Xep.Jingle.ReasonElement.SUCCESS;
            }
        }

        private void publish_jmi_finish(Call call, string? reason_name) {
            PeerState? peer_state = jmi_request_peer[call];
            if (peer_state == null) return;
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_by_owner((!) peer_state);
            if (entry == null) return;
            Jid? target = ((!) entry).claim_outgoing_finish_target();
            if (target == null) return;
            XmppStream? stream = stream_interactor.get_stream(call.account);
            if (stream == null) return;
            ((!) stream).get_module<Xep.JingleMessageInitiation.Module>(
                Xep.JingleMessageInitiation.Module.IDENTITY)
                    .send_session_finish_to_peer((!) stream, (!) target,
                        ((!) entry).sid,
                        normalize_jmi_finish_reason(reason_name));
        }

        private JmiLiveSessionEntry? find_sent_carbon_incoming_owner(
                Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            if (event.delivery !=
                    Xep.JingleMessageInitiation.Delivery.CARBON_SENT ||
                    !event.from.equals_bare(account.bare_jid) ||
                    event.from.equals(account.full_jid) ||
                    event.from.resourcepart == null ||
                    event.to.resourcepart == null ||
                    event.to.equals_bare(account.bare_jid) ||
                    jmi_peer_is_muc(account, event.to)) return null;
            JmiLiveSessionEntry? entry = jmi_live_sessions.find(account,
                event.to, event.sid);
            return entry != null && ((!) entry).incoming &&
                ((!) entry).proposal_source.equals(event.to) &&
                ((!) entry).own_incoming_response_matches(event.from,
                    event.to)
                    ? entry : null;
        }

        private void send_jmi_tie_break_reject(XmppStream stream, Jid target,
                string sid) {
            stream.get_module<Xep.JingleMessageInitiation.Module>(
                Xep.JingleMessageInitiation.Module.IDENTITY)
                    .send_session_reject_with_reason_to_peer(stream, target,
                        sid, Xep.Jingle.ReasonElement.EXPIRED, "Tie-Break",
                        true);
        }

        private void send_jmi_tie_break_retract(XmppStream stream, Jid target,
                string sid) {
            stream.get_module<Xep.JingleMessageInitiation.Module>(
                Xep.JingleMessageInitiation.Module.IDENTITY)
                    .send_session_retract_with_reason_to_peer(stream, target,
                        sid, Xep.Jingle.ReasonElement.EXPIRED, "Tie-Break",
                        true);
        }

        /**
         * Resolve a second unaccepted proposal before any new call or worker is
         * allocated. Returns true only when the incoming proposal may continue.
         */
        private bool resolve_jmi_competing_proposal(Account account,
                XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event,
                JmiLiveSessionEntry existing, out bool replaces_owner) {
            replaces_owner = false;
            if (existing.matches(account, event.from, event.sid) &&
                    existing.same_proposal_source(event.from)) return true;

            PeerState? maybe_peer = live_peer_for_entry(existing);
            if (maybe_peer == null) {
                replaces_owner = true;
                return true;
            }
            PeerState peer_state = (!) maybe_peer;
            Call call = peer_state.call;
            if (call.state == Call.State.ESTABLISHING ||
                    call.state == Call.State.IN_PROGRESS) {
                if (try_migrate_active_jmi_session(account, stream, event,
                        existing, peer_state)) return false;
                if (event.delivery ==
                        Xep.JingleMessageInitiation.Delivery.LIVE) {
                    reject_jmi_proposal(account, event.from, event.sid);
                    jmi_live_sessions.remember_terminal(account, event.from,
                        event.sid, event.from);
                }
                return false;
            }
            if (!existing.incoming &&
                    !existing.proposal_source.equals(account.full_jid)) {
                // Another own resource owns this proposal and performs the
                // wire tie-break. This mirror waits for its Carboned terminal.
                return false;
            }

            int incoming_order = JmiTieBreak.compare(event.sid, event.from,
                existing.sid, existing.proposal_source);
            if (incoming_order >= 0) {
                send_jmi_tie_break_reject(stream, event.from, event.sid);
                jmi_live_sessions.remember_terminal(account, event.from,
                    event.sid, event.from);
                return false;
            }

            if (existing.incoming) {
                send_jmi_tie_break_reject(stream, existing.proposal_source,
                    existing.sid);
            } else {
                send_jmi_tie_break_retract(stream, event.from, existing.sid);
            }
            call_states[call].finish_jmi_tie_break_superseded(event.from);
            replaces_owner = true;
            return true;
        }

        /**
         * Stage a signaling-only replacement, then swap the single native leg.
         * MUJI and legacy RTP never enter this path.
         */
        private bool try_migrate_active_jmi_session(Account account,
                XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event,
                JmiLiveSessionEntry existing, PeerState peer_state) {
            CallState call_state = call_states[peer_state.call];
            bool direct_lifecycle = peer_state.group_call == null &&
                call_state.group_call == null;
            if (!JmiActiveMigrationPolicy.may_stage(direct_lifecycle,
                    call_state.media_backend,
                    peer_state.uses_google_webrtc_jmi_call_engine_session(),
                    peer_state.call.state, event.delivery, event.from,
                    existing.peer_bare_jid) ||
                    !peer_state.can_replace_active_direct_jmi_session()) {
                return false;
            }

            bool video_requested = event.descriptions.any_match(
                (description) =>
                    description.ns_uri == Xep.JingleRtp.NS_URI &&
                    description.get_attribute("media") == "video");
            Plugins.JmiCallEnginePlugin? selected_engine =
                call_state.get_selected_jmi_call_engine();
            Plugins.JmiCallEnginePlugin? available_engine =
                get_google_webrtc_jmi_call_engine(account, video_requested);
            Jid? previous_target = existing.selected_peer_for_migration();
            Jid? previous_local = existing.selected_local_for_migration();
            if (selected_engine == null || available_engine == null ||
                    (!) selected_engine != (!) available_engine ||
                    previous_target == null || previous_local == null ||
                    !((!) previous_local).equals(account.full_jid)) {
                return false;
            }

            CallStore call_store = stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY);
            bool sid_was_owned = peer_state.call.owns_jmi_sid(event.sid);
            if (!call_store.claim_jmi_sid(peer_state.call, event.sid)) {
                warning("[%s] Refusing JMI migration sid=%s with conflicting database ownership",
                    account.bare_jid.to_string(), event.sid);
                return false;
            }

            Plugins.JmiCallEngineSession replacement;
            try {
                replacement = ((!) selected_engine).create_incoming_session(
                    stream, account.full_jid, event.from, event.sid,
                    peer_state.call.id > 0
                        ? (uint64) peer_state.call.id : 0,
                    event.descriptions);
            } catch (Error e) {
                if (!sid_was_owned) {
                    call_store.release_jmi_sid(peer_state.call, event.sid);
                }
                warning("[%s] Could not stage JMI migration sid=%s: %s",
                    account.bare_jid.to_string(), event.sid, e.message);
                return false;
            }

            string previous_sid = existing.sid;
            JmiLiveSessionEntry? replacement_entry =
                jmi_live_sessions.replace_for_migration(existing, event.sid,
                    event.from, event.to, peer_state);
            if (replacement_entry == null) {
                replacement.discard();
                if (!sid_was_owned) {
                    call_store.release_jmi_sid(peer_state.call, event.sid);
                }
                return false;
            }
            ((!) replacement_entry).set_incoming_proposal_details(
                event.descriptions, video_requested);
            if (!((!) replacement_entry).reserve_local_proceed(event.from,
                    account.full_jid)) {
                replacement.discard();
                call_state.fail_local(Xep.Jingle.ReasonElement.GENERAL_ERROR,
                    "Could not reserve the migrated JMI endpoints");
                return true;
            }

            if (!peer_state.replace_active_direct_jmi_session(replacement,
                    event.from, event.sid, video_requested)) {
                ((!) replacement_entry).rollback_local_proceed(event.from,
                    account.full_jid);
                replacement.discard();
                call_state.fail_local(Xep.Jingle.ReasonElement.GENERAL_ERROR,
                    "Could not transfer the active JMI media owner");
                return true;
            }

            stream.get_module<Xep.JingleMessageInitiation.Module>(
                Xep.JingleMessageInitiation.Module.IDENTITY)
                    .send_session_finish_to_peer(stream, (!) previous_target,
                        previous_sid, Xep.Jingle.ReasonElement.EXPIRED,
                        "Session migrated", event.sid);

            if (peer_state.we_should_send_video) {
                Plugins.MediaDevice? video_device =
                    call_state.get_video_device();
                if (video_device != null) {
                    call_state.set_video_device((!) video_device);
                }
            }
            if (!peer_state.accept_replacement_direct_jmi_session()) {
                ((!) replacement_entry).rollback_local_proceed(event.from,
                    account.full_jid);
                peer_state.reject();
                call_state.fail_local(
                    Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                    "Could not proceed with the migrated JMI session");
                return true;
            }
            if (!((!) replacement_entry).commit_local_proceed(event.from,
                    account.full_jid)) {
                peer_state.reject();
                call_state.fail_local(Xep.Jingle.ReasonElement.GENERAL_ERROR,
                    "Could not commit the migrated JMI endpoints");
                return true;
            }
            call_state.start_jmi_migration_timeout(peer_state, event.sid, 30);

            debug("[%s] Migrated active JMI session %s -> %s peer=%s",
                account.bare_jid.to_string(), previous_sid, event.sid,
                event.from.to_string());
            return true;
        }

        internal bool claim_outgoing_jmi_session(PeerState peer_state) {
            string sid = peer_state.ensure_sid();
            CallStore call_store = stream_interactor.get_module<CallStore>(
                CallStore.IDENTITY);
            bool sid_was_owned = peer_state.call.owns_jmi_sid(sid);
            if (!call_store.claim_jmi_sid(peer_state.call, sid)) return false;
            JmiLiveSessionEntry? existing = jmi_live_sessions.find(
                peer_state.call.account, peer_state.jid, sid);
            if (existing != null) {
                bool owned = ((!) existing).owner == peer_state &&
                    !((!) existing).incoming &&
                    ((!) existing).same_proposal_source(
                        peer_state.call.account.full_jid);
                if (!owned && !sid_was_owned) {
                    call_store.release_jmi_sid(peer_state.call, sid);
                }
                return owned;
            }
            bool registered = jmi_live_sessions.register(
                peer_state.call.account,
                peer_state.jid, sid, peer_state.call.account.full_jid,
                peer_state.jid, false, peer_state) != null;
            if (!registered && !sid_was_owned) {
                call_store.release_jmi_sid(peer_state.call, sid);
            }
            return registered;
        }

        private JmiLiveSessionEntry? find_external_jmi_owner(
                Account account, Xep.JingleMessageInitiation.JmiEvent event) {
            if (event.from.equals_bare(account.bare_jid) ||
                    !event.to.equals_bare(account.bare_jid) ||
                    jmi_peer_is_muc(account, event.from)) return null;
            return jmi_live_sessions.find(account, event.from, event.sid);
        }

        private void on_jmi_proposed(Account account, XmppStream stream,
                Xep.JingleMessageInitiation.JmiEvent event) {
            bool from_own_account =
                event.from.equals_bare(account.bare_jid);
            if (from_own_account && event.from.equals(account.full_jid)) {
                return;
            }
            if (!from_own_account &&
                    !event.to.equals_bare(account.bare_jid)) return;

            Jid peer = from_own_account ? event.to : event.from;
            if (peer.equals_bare(account.bare_jid) ||
                    jmi_peer_is_muc(account, peer)) return;

            // A fresh live proposal takes ownership away from a passive MAM
            // projection of the same lifecycle before any UI or media exists.
            jmi_archive_replays.forget(account, peer, event.sid);

            bool audio_requested = event.descriptions.any_match(
                (description) =>
                    description.ns_uri == Xep.JingleRtp.NS_URI &&
                    description.get_attribute("media") == "audio");
            bool video_requested = event.descriptions.any_match(
                (description) =>
                    description.ns_uri == Xep.JingleRtp.NS_URI &&
                    description.get_attribute("media") == "video");
            if (!audio_requested && !video_requested) return;

            if (!from_own_account && (event.from.resourcepart == null ||
                    !jmi_incoming_is_authorized(account, event.from))) {
                jmi_live_sessions.remember_terminal(account, event.from,
                    event.sid, event.from);
                return;
            }

            JmiProposalDisposition disposition =
                jmi_live_sessions.inspect_proposal(account, peer,
                    event.sid, event.from);
            if (disposition == JmiProposalDisposition.DUPLICATE) {
                debug("[%s] Ignoring duplicate JMI proposal sid=%s from=%s",
                    account.bare_jid.to_string(), event.sid,
                    event.from.to_string());
                return;
            }
            if (disposition == JmiProposalDisposition.TERMINAL) {
                debug("[%s] Ignoring terminal JMI replay sid=%s from=%s",
                    account.bare_jid.to_string(), event.sid,
                    event.from.to_string());
                return;
            }

            bool replaces_owner = false;
            if (!from_own_account &&
                    disposition == JmiProposalDisposition.CONFLICT) {
                JmiLiveSessionEntry? competing =
                    jmi_live_sessions.find_by_peer(account, peer);
                if (competing == null ||
                        !resolve_jmi_competing_proposal(account, stream, event,
                            (!) competing, out replaces_owner)) return;
            }
            if (disposition == JmiProposalDisposition.CONFLICT &&
                    !replaces_owner) {
                warning("[%s] Ignoring conflicting JMI proposal sid=%s from=%s",
                    account.bare_jid.to_string(), event.sid,
                    event.from.to_string());
                return;
            }

            Plugins.JmiCallEnginePlugin? selected_jmi_engine =
                get_google_webrtc_jmi_call_engine(account, video_requested);
            if (!from_own_account && selected_jmi_engine == null &&
                    !can_we_do_rtp_calls(account)) {
                if (event.delivery ==
                        Xep.JingleMessageInitiation.Delivery.LIVE) {
                    warning("[%s] Rejecting JMI proposal without a capable media backend",
                        account.bare_jid.to_string());
                    reject_jmi_proposal(account, event.from, event.sid);
                }
                jmi_live_sessions.remember_terminal(account, event.from,
                    event.sid, event.from);
                return;
            }

            PeerState peer_state = create_received_call(account, event.from,
                event.to, video_requested, selected_jmi_engine,
                from_own_account);
            peer_state.sid = event.sid;
            CallState call_state = call_states[peer_state.call];
            if (!stream_interactor.get_module<CallStore>(CallStore.IDENTITY)
                    .claim_jmi_sid(peer_state.call, event.sid)) {
                warning("[%s] Ignoring JMI proposal %s with conflicting persisted SID owner",
                    account.bare_jid.to_string(), event.sid);
                if (pending_own_jmi_mirrors.contains(peer_state.call)) {
                    discard_pending_own_jmi_mirror(peer_state.call);
                } else {
                    discard_unpublished_call(peer_state.call);
                }
                return;
            }
            JmiLiveSessionEntry? entry = replaces_owner
                ? jmi_live_sessions.register_after_tie_break(account, peer,
                    event.sid, event.from, event.to, !from_own_account,
                    peer_state)
                : jmi_live_sessions.register(account, peer, event.sid,
                    event.from, event.to, !from_own_account, peer_state);
            if (entry == null) {
                if (pending_own_jmi_mirrors.contains(peer_state.call)) {
                    discard_pending_own_jmi_mirror(peer_state.call);
                    return;
                }
                call_state.fail_local(Xep.Jingle.ReasonElement.GENERAL_ERROR,
                    "Lost JMI session ownership while creating the call");
                return;
            }
            if (!from_own_account) {
                ((!) entry).set_incoming_proposal_details(event.descriptions,
                    video_requested);
            }

            // Publish the owner before any engine operation can fail and
            // synchronously terminate the CallState. Terminal cleanup then
            // always has a stable PeerState handle even after peers was cleared.
            jmi_request_peer[peer_state.call] = peer_state;

            // A received Carbon mirrors signaling and UI only. The native
            // libwebrtc session is created lazily if this device is selected.
            if (!from_own_account && selected_jmi_engine != null &&
                    JmiIncomingEnginePolicy.attach_on_proposal(
                        from_own_account, event.delivery) &&
                    !maybe_attach_google_webrtc_jmi_incoming_engine(account,
                        peer_state, event.from, event.sid,
                        event.descriptions, video_requested,
                        (!) selected_jmi_engine)) {
                call_state.reject();
                return;
            }

            if (!from_own_account && event.delivery ==
                        Xep.JingleMessageInitiation.Delivery.LIVE &&
                    event.from.resourcepart != null &&
                    ((!) entry).claim_outgoing_ringing()) {
                stream.get_module<Xep.JingleMessageInitiation.Module>(
                    Xep.JingleMessageInitiation.Module.IDENTITY)
                        .send_session_ringing_to_peer(stream, event.from,
                            event.sid);
            }

            Conversation conversation = stream_interactor.get_module<
                ConversationManager>(ConversationManager.IDENTITY)
                    .get_conversation(call_state.call.counterpart.bare_jid,
                        account, Conversation.Type.CHAT);
            if (call_state.call.direction == Call.DIRECTION_INCOMING) {
                call_incoming(call_state.call, call_state, conversation,
                    video_requested, false);
            } else if (!pending_own_jmi_mirrors.contains(call_state.call)) {
                call_outgoing(call_state.call, call_state, conversation);
            }
        }

        private void on_jmi_ringing(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            JmiLiveSessionEntry? entry = find_external_jmi_owner(account,
                event);
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null ||
                    ((!) peer_state).call.direction !=
                        Call.DIRECTION_OUTGOING ||
                    !((!) entry).pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.RINGING,
                        event.from, event.to) ||
                    !((!) entry).claim_action_from_source(
                        Xep.JingleMessageInitiation.Action.RINGING,
                        event.from)) return;
            ((!) peer_state).info_received(
                Xep.JingleRtp.CallSessionInfo.RINGING);
        }

        private void on_jmi_legacy_accept(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            if (!event.from.equals_bare(account.bare_jid) ||
                    event.from.equals(account.full_jid) ||
                    !event.to.equals_bare(account.bare_jid)) return;
            bool ambiguous;
            JmiLiveSessionEntry? entry =
                jmi_live_sessions.find_unique_by_sid(account, event.sid,
                    true, out ambiguous);
            if (ambiguous) {
                warning("[%s] Ignoring ambiguous own-resource JMI accept sid=%s",
                    account.bare_jid.to_string(), event.sid);
                return;
            }
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null ||
                    !((!) entry).claim_action_once(
                        Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT)) {
                return;
            }
            call_states[((!) peer_state).call].finish_on_other_device(
                event.from);
        }

        private void on_jmi_proceeded(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            JmiLiveSessionEntry? sent_entry =
                find_sent_carbon_incoming_owner(account, event);
            PeerState? sent_peer = live_peer_for_entry(sent_entry);
            if (sent_entry != null && sent_peer != null) {
                if (((!) sent_entry).claim_action_once(
                        Xep.JingleMessageInitiation.Action.PROCEED)) {
                    call_states[((!) sent_peer).call].finish_on_other_device(
                        event.from);
                }
                return;
            }

            JmiLiveSessionEntry? entry = find_external_jmi_owner(account,
                event);
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null) return;
            PeerState owner = (!) peer_state;
            Call call = owner.call;

            if (call.direction != Call.DIRECTION_OUTGOING) return;

            if (event.delivery ==
                    Xep.JingleMessageInitiation.Delivery.CARBON_RECEIVED) {
                if (!call.ourpart.equals(account.full_jid) &&
                        event.to.equals(call.ourpart) &&
                        ((!) entry).pre_proceed_external_action_matches(
                            Xep.JingleMessageInitiation.Action.PROCEED,
                            event.from, event.to) &&
                        ((!) entry).claim_action_once(
                            Xep.JingleMessageInitiation.Action.PROCEED)) {
                    call_states[call].finish_on_other_device(event.to);
                }
                return;
            }

            Jid? maybe_validated_to = JmiProceedRouting.select_destination(
                account, event.from, event.to, event.delivery,
                call.ourpart.equals(account.full_jid));
            if (maybe_validated_to == null) return;
            Jid validated_to = (!) maybe_validated_to;

            if (!((!) entry).pre_proceed_external_action_matches(
                    Xep.JingleMessageInitiation.Action.PROCEED,
                    event.from, event.to) ||
                    !((!) entry).claim_action_once(
                        Xep.JingleMessageInitiation.Action.PROCEED) ||
                    !jmi_request_peer.has_key(call) ||
                    !((!) entry).reserve_local_proceed(event.from,
                        validated_to)) return;
            CallState call_state = call_states[call];
            call_state.rename_peer(jmi_request_peer[call].jid, event.from);
            if (call_state.media_backend == CallMediaBackend.LEGACY_RTP) {
                if (!((!) entry).commit_local_proceed(event.from,
                        validated_to)) {
                    call_state.fail_local(
                        Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                        "Could not commit JMI proceed ownership");
                    return;
                }
                jmi_archive_replays.forget(account, owner.jid, event.sid);
                owner.call_resource.begin(event.from);
                return;
            }
            if (!jmi_request_peer[call]
                    .handle_google_webrtc_jmi_call_engine_proceed(
                        event.from, validated_to, event.sid)) {
                ((!) entry).rollback_local_proceed(event.from,
                    validated_to);
                call_state.fail_local(
                    Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                    "Could not route JMI proceed to Google/libwebrtc");
                return;
            }
            if (!commit_jmi_local_proceed(owner, event.from,
                    validated_to)) {
                call_state.fail_local(
                    Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                    "Could not commit JMI proceed ownership");
            }
        }

        private void on_jmi_rejected(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            JmiLiveSessionEntry? entry =
                find_sent_carbon_incoming_owner(account, event);
            PeerState? carbon_peer = live_peer_for_entry(entry);
            if (entry != null && carbon_peer != null) {
                if (((!) entry).claim_action_once(
                        Xep.JingleMessageInitiation.Action.REJECT)) {
                    call_states[((!) carbon_peer).call].finish_remote_reject(
                        event.from);
                }
                return;
            }

            if (event.from.equals_bare(account.bare_jid)) {
                if (event.from.equals(account.full_jid) ||
                        !event.to.equals_bare(account.bare_jid)) return;
                bool ambiguous;
                entry = jmi_live_sessions.find_unique_by_sid(account,
                    event.sid, true, out ambiguous);
                if (ambiguous) {
                    warning("[%s] Ignoring ambiguous own-resource JMI reject sid=%s",
                        account.bare_jid.to_string(), event.sid);
                    return;
                }
                if (entry == null ||
                        !((!) entry).legacy_own_self_reject_matches(
                            event.from, event.to)) return;
            } else {
                entry = find_external_jmi_owner(account, event);
                if (entry == null || ((!) entry).incoming ||
                        !((!) entry).pre_proceed_external_action_matches(
                            Xep.JingleMessageInitiation.Action.REJECT,
                            event.from, event.to)) return;
            }
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null) return;
            Call call = ((!) peer_state).call;
            if (((!) entry).incoming !=
                    (call.direction == Call.DIRECTION_INCOMING)) return;
            if (!((!) entry).claim_action_once(
                    Xep.JingleMessageInitiation.Action.REJECT)) return;
            call_states[call].finish_remote_reject(event.from);
        }

        private void on_jmi_retracted(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            JmiLiveSessionEntry? entry;
            if (event.from.equals_bare(account.bare_jid)) {
                if (event.from.equals(account.full_jid) ||
                        event.to.equals_bare(account.bare_jid) ||
                        jmi_peer_is_muc(account, event.to)) return;
                entry = jmi_live_sessions.find(account, event.to,
                    event.sid);
                if (entry == null || ((!) entry).incoming ||
                        !((!) entry).own_proposal_action_matches(event.from,
                            event.to)) return;
            } else {
                entry = find_external_jmi_owner(account, event);
                if (entry == null || !((!) entry).incoming ||
                        !((!) entry).pre_proceed_external_action_matches(
                            Xep.JingleMessageInitiation.Action.RETRACT,
                            event.from, event.to)) return;
            }
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null) return;
            Call call = ((!) peer_state).call;
            if (((!) entry).incoming !=
                    (call.direction == Call.DIRECTION_INCOMING)) return;
            if (!((!) entry).claim_action_once(
                    Xep.JingleMessageInitiation.Action.RETRACT)) return;
            call_states[call].finish_remote_retract(event.from);
        }

        private void on_jmi_finished(Account account,
                Xep.JingleMessageInitiation.JmiEvent event) {
            JmiLiveSessionEntry? entry =
                find_sent_carbon_incoming_owner(account, event);
            bool own_action = event.from.equals_bare(account.bare_jid);
            if (own_action && event.from.equals(account.full_jid)) return;
            if (entry == null && !own_action) {
                entry = find_external_jmi_owner(account, event);
            } else if (entry == null &&
                    !event.from.equals(account.full_jid) &&
                    !event.to.equals_bare(account.bare_jid) &&
                    !jmi_peer_is_muc(account, event.to)) {
                entry = jmi_live_sessions.find(account, event.to,
                    event.sid);
            }
            PeerState? peer_state = live_peer_for_entry(entry);
            if (entry == null || peer_state == null) return;

            bool endpoints_match;
            if (own_action) {
                endpoints_match = ((!) entry).has_committed_proceed()
                    ? ((!) entry).selected_own_action_matches(event.from,
                        event.to)
                    : (((!) entry).incoming
                        ? ((!) entry).own_incoming_response_matches(
                            event.from, event.to)
                        : ((!) entry).own_proposal_action_matches(event.from,
                            event.to));
            } else {
                endpoints_match = ((!) entry).has_committed_proceed()
                    ? ((!) entry).selected_external_action_matches(
                        event.from, event.to)
                    : ((!) entry).pre_proceed_external_action_matches(
                        Xep.JingleMessageInitiation.Action.FINISH,
                        event.from, event.to);
            }
            if (!endpoints_match ||
                    !((!) entry).claim_action_from_source(
                        Xep.JingleMessageInitiation.Action.FINISH,
                        event.from)) return;

            Call call = ((!) peer_state).call;
            if (own_action) {
                call_states[call].finish_on_other_device(event.from);
            } else if (pending_own_jmi_mirrors.contains(call)) {
                call_states[call].finish_on_other_device(call.ourpart);
            } else {
                call_states[call].finish_remote_jmi(event.from,
                    event.reason != null ? ((!) event.reason).condition : null,
                    event.reason != null ? ((!) event.reason).text : null);
            }
        }

        private void on_account_added(Account account) {
            Presence.Module presence_module = stream_interactor.module_manager
                .get_module<Presence.Module>(account, Presence.Module.IDENTITY);
            presence_module.received_available.connect((stream, presence) => {
                observe_muji_presence(account, stream, presence);
            });
            presence_module.received_unavailable.connect((stream, presence) => {
                observe_muji_presence(account, stream, presence);
            });
            Xep.Jingle.Module jingle_module = stream_interactor.module_manager.get_module<Xep.Jingle.Module>(account, Xep.Jingle.Module.IDENTITY);
            jingle_module.session_initiate_received.connect((stream, session) => {
                foreach (Xep.Jingle.Content content in session.contents) {
                    Xep.JingleRtp.Parameters? rtp_content_parameter = content.content_params as Xep.JingleRtp.Parameters;
                    if (rtp_content_parameter != null) {
                        on_incoming_call(account, session);
                        break;
                    }
                }
            });

            Xep.JingleMessageInitiation.Module mi_module =
                stream_interactor.module_manager.get_module<
                    Xep.JingleMessageInitiation.Module>(account,
                        Xep.JingleMessageInitiation.Module.IDENTITY);
            mi_module.event_received.connect((stream, event) => {
                on_jmi_event(account, stream, event);
            });

            Xep.CallInvites.Module call_invites_module = stream_interactor.module_manager.get_module<Xep.CallInvites.Module>(account, Xep.CallInvites.Module.IDENTITY);
            call_invites_module.call_proposed.connect((source_stream, from_jid, to_jid, call_id, video_requested, join_methods, message_stanza) => {
                if (message_stanza.type_ != MessageStanza.TYPE_CHAT &&
                        message_stanza.type_ != MessageStanza.TYPE_GROUPCHAT) {
                    return;
                }
                Jid? local_full_jid = current_cim_invite_recipient(account,
                    source_stream, to_jid);
                if (local_full_jid == null) return;
                if (from_jid.equals_bare(account.bare_jid)) return;
                MucManager muc_manager = stream_interactor.get_module<
                    MucManager>(MucManager.IDENTITY);
                if (muc_manager.is_own_muc_jid(from_jid, account)) {
                    if (message_stanza.type_ ==
                            MessageStanza.TYPE_GROUPCHAT) {
                        string? provisional_id = Xep.CallInvites.Module
                            .get_outgoing_invite_correlation_id(
                                message_stanza);
                        if (provisional_id != null) {
                            CallState? outgoing_call =
                                get_outgoing_groupchat_call_by_provisional(
                                    account, from_jid.bare_jid,
                                    (!) provisional_id);
                            if (outgoing_call != null) {
                                ((!) outgoing_call)
                                    .bind_outgoing_groupchat_cim_reference(
                                        from_jid.bare_jid,
                                        (!) provisional_id, call_id);
                            } else {
                                CimTerminalSignalAction deferred_action =
                                    deferred_cim_groupchat_terminals.take(
                                        account, from_jid.bare_jid,
                                        (!) provisional_id);
                                if (deferred_action !=
                                        CimTerminalSignalAction.NONE) {
                                    send_deferred_cim_groupchat_terminal(
                                        account, from_jid.bare_jid, call_id,
                                        deferred_action);
                                }
                            }
                        }
                    }
                    return;
                }
                if (!call_invite_source_allowed(message_stanza.type_,
                        muc_manager.might_be_groupchat(
                            from_jid.bare_jid, account))) {
                    warning("[%s] Ignoring call invite from MUC private-message source %s",
                        account.bare_jid.to_string(), from_jid.to_string());
                    return;
                }
                if (message_stanza.type_ == MessageStanza.TYPE_CHAT &&
                        (!from_jid.is_full() || stream_interactor
                            .get_module<BlockingManager>(
                                BlockingManager.IDENTITY).is_blocked(account,
                                    from_jid.bare_jid))) {
                    return;
                }
                MucManager.MucOwnerMutationContext?
                    source_room_context = null;
                Jid? source_inviter_occupant = null;
                Jid? source_inviter_real_jid = null;
                if (message_stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
                    source_room_context =
                        muc_manager.capture_current_muc_context(account,
                            from_jid.bare_jid);
                }
                if (message_stanza.type_ == MessageStanza.TYPE_GROUPCHAT &&
                        (!muc_manager.is_joined(from_jid.bare_jid, account) ||
                        !muc_manager.has_live_private_room_features(account,
                            from_jid.bare_jid) ||
                        source_room_context == null)) {
                    warning("[%s] Ignoring MUJI proposal from a non-live/private source room %s",
                        account.bare_jid.to_string(),
                        from_jid.bare_jid.to_string());
                    return;
                }

                bool multiparty = false;
                CallState? call_state = null;

                foreach (StanzaNode join_method_node in join_methods) {
                    if (join_method_node.name == "muji" && join_method_node.ns_uri == Xep.Muji.NS_URI) {
                        // This is a MUJI invite

                        // Disregard calls from muc history
                        DateTime? delay;
                        delay = Xep.DelayedDelivery.get_time_for_message(message_stanza, from_jid.bare_jid);
                        if (delay != null) return;

                        string? room_jid_str = join_method_node.get_attribute("room");
                        if (room_jid_str == null) return;
                        Jid room_jid;
                        try {
                            room_jid = new Jid(room_jid_str).bare_jid;
                        } catch (Xmpp.InvalidJidError e) {
                            warning("Invalid room JID in MUJI invite: %s", e.message);
                            continue;
                        }
                        if (message_stanza.type_ == MessageStanza.TYPE_CHAT &&
                                muc_manager.is_joined(room_jid, account)) {
                            MucManager.MucOwnerMutationContext?
                                direct_room_context =
                                    muc_manager.capture_current_muc_context(
                                        account, room_jid);
                            if (!muc_manager.has_live_private_room_features(
                                    account, room_jid) ||
                                    direct_room_context == null) {
                                warning("[%s] Ignoring direct MUJI invite for a joined room without a live private lifecycle: %s",
                                    account.bare_jid.to_string(),
                                    room_jid.to_string());
                                return;
                            }
                            if (!from_jid.is_full()) {
                                warning("[%s] Ignoring direct MUJI invite without a full-JID room participant: %s",
                                    account.bare_jid.to_string(),
                                    from_jid.to_string());
                                return;
                            }
                            Jid? inviter_occupant = muc_manager
                                .get_occupant_jid_exact(account, room_jid,
                                    from_jid);
                            Jid? disclosed_real_jid = inviter_occupant != null
                                ? muc_manager.get_real_jid(
                                    (!) inviter_occupant, account) : null;
                            if (inviter_occupant == null ||
                                    disclosed_real_jid == null ||
                                    !((!) disclosed_real_jid).equals(
                                        from_jid) ||
                                    !muc_manager.is_current_occupant(account,
                                        room_jid, (!) inviter_occupant)) {
                                warning("[%s] Ignoring direct MUJI invite from %s without a live occupant in %s",
                                    account.bare_jid.to_string(),
                                    from_jid.to_string(),
                                    room_jid.to_string());
                                return;
                            }
                            source_room_context = direct_room_context;
                            source_inviter_occupant = inviter_occupant;
                            source_inviter_real_jid = disclosed_real_jid;
                        }
                        // This is DinoX's local call-admission policy, shared
                        // with direct JMI. A stored chat alone is not consent
                        // to receive calls. A proven live private-room source
                        // has its separate exact occupant/resource checks.
                        if (message_stanza.type_ == MessageStanza.TYPE_CHAT &&
                                source_room_context == null &&
                                !jmi_incoming_is_authorized(account,
                                    from_jid)) return;
                        if (!claim_cim_invite_once(account, from_jid,
                                message_stanza.type_, call_id)) return;
                        call_state = create_recv_muji_call(account,
                            (!) local_full_jid, call_id,
                            from_jid, room_jid, message_stanza.type_,
                            video_requested, source_room_context,
                            source_inviter_occupant,
                            source_inviter_real_jid);

                        multiparty = true;
                        break;

                    } else if (join_method_node.name == "jingle" && join_method_node.ns_uri == Xep.CallInvites.NS_URI) {
                        // This is an invite for a direct Jingle session

                        if (message_stanza.type_ != MessageStanza.TYPE_CHAT ||
                                !jmi_incoming_is_authorized(account,
                                    from_jid)) return;
                        if (stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(from_jid.bare_jid, account)) return;
                        if (!claim_cim_invite_once(account, from_jid,
                                message_stanza.type_, call_id)) return;

                        if (!can_we_do_rtp_calls(account)) {
                            XmppStream? stream = stream_interactor.get_stream(
                                account);
                            if (stream != null) {
                                call_invites_module.send_reject((!) stream,
                                    from_jid, call_id,
                                    message_stanza.type_);
                            }
                            return;
                        }

                        string? sid = join_method_node.get_attribute("sid");
                        if (sid == null) return;

                        PeerState peer_state = create_received_call(account,
                            from_jid, (!) local_full_jid, video_requested,
                            null, false, (!) local_full_jid);
                        peer_state.sid = sid;

                        call_state = call_states[peer_state.call];

                        jmi_request_peer[call_state.call] = peer_state;
                        break;
                    }
                }


                if (call_state == null) return;

                call_state.we_should_send_audio = true;
                call_state.we_should_send_video = video_requested;

                call_state.configure_cim_invite(call_id, from_jid,
                    message_stanza.type_ == MessageStanza.TYPE_GROUPCHAT
                        ? from_jid.bare_jid : from_jid,
                    message_stanza.type_);

                ConversationManager conversation_manager = stream_interactor
                    .get_module<ConversationManager>(
                        ConversationManager.IDENTITY);
                Conversation? conversation = source_room_context != null
                    ? conversation_manager.get_conversation(
                        ((!) source_room_context).room, account,
                        Conversation.Type.GROUPCHAT)
                    : conversation_manager.approx_conversation_for_stanza(
                        from_jid, to_jid, account, message_stanza.type_);
                if (conversation == null) return;

                if (call_state.call.direction == Call.DIRECTION_INCOMING) {
                    call_incoming(call_state.call, call_state, conversation, video_requested, multiparty);
                } else {
                    call_outgoing(call_state.call, call_state, conversation);
                }
            });
            call_invites_module.call_accepted.connect((from_jid, to_jid, call_id, message_type) => {
                // Carboned message from our account
                if (from_jid.equals_bare(account.bare_jid)) {
                    // Ignore carbon from ourselves
                    if (from_jid.equals(account.full_jid)) return;

                    CallState? call_state =
                        get_call_state_for_own_cim_action(account, to_jid,
                            message_type, call_id);
                    if (call_state == null) return;

                    // We accepted the call from another device
                    call_state.finish_on_other_device(from_jid);
                    return;
                }

                CallState? call_state = get_call_state_for_cim_action(account,
                    from_jid, message_type, call_id);
                if (message_type == MessageStanza.TYPE_GROUPCHAT) {
                    trace_muji_control("accept from=%s invite=%s matched=%s".printf(
                        from_jid.to_string(), call_id,
                        (call_state != null).to_string()));
                }
                if (call_state == null) return;
                Call call = call_state.call;

                // We proposed the call. This is a message from our peer.
                if (call.direction == Call.DIRECTION_OUTGOING &&
                        to_jid.equals(account.full_jid)) {
                    CallAcceptedRoute route = select_call_accepted_route(false,
                        call_state.media_backend,
                        call_state.group_call != null,
                        jmi_request_peer.has_key(call));
                    if (route != CallAcceptedRoute.LEGACY_RESOURCE) return;
                    // We know the full jid of our peer now
                    call_state.rename_peer(jmi_request_peer[call].jid, from_jid);
                    jmi_request_peer[call].call_resource.begin(from_jid);
                }
            });
            call_invites_module.call_retracted.connect((from_jid, to_jid, call_id, message_type) => {
                if (from_jid.equals_bare(account.bare_jid)) return;

                // The call was retracted by the counterpart
                CallState? call_state = get_call_state_for_cim_action(account,
                    from_jid, message_type, call_id);
                if (call_state == null) return;

                if (!CallState.call_invite_retractable(
                        call_state.call.state)) {
                    debug("%s tried to retract a call that's in state %s. Ignoring.", from_jid.to_string(), call_state.call.state.to_string());
                    return;
                }

                // Only the call initiator may retract
                if (!call_state.is_cim_proposer(from_jid, message_type)) {
                    debug("%s tried to retract a call initiated by %s. Ignoring.",
                        from_jid.to_string(),
                        call_state.cim_counterpart != null
                            ? ((!) call_state.cim_counterpart).to_string()
                            : "an unknown proposer");
                    return;
                }
                call_state.finish_remote_retract(from_jid);
            });
            call_invites_module.call_rejected.connect((from_jid, to_jid, call_id, message_type) => {
                bool from_own_account =
                    from_jid.equals_bare(account.bare_jid);
                CallState? call_state = from_own_account
                    ? get_call_state_for_own_cim_action(account, to_jid,
                        message_type, call_id)
                    : get_call_state_for_cim_action(account, from_jid,
                        message_type, call_id);
                if (call_state == null) return;
                CimRejectDisposition disposition =
                    CallState.select_cim_reject_disposition(
                        from_own_account,
                        from_jid.equals(account.full_jid),
                        call_state.call.direction ==
                            Call.DIRECTION_OUTGOING,
                        call_state.has_cim_action_target(from_jid,
                            message_type, call_id),
                        call_state.group_call != null, message_type);
                switch (disposition) {
                    case CimRejectDisposition.FINISH_LOCAL:
                        call_state.finish_remote_reject(from_jid);
                        return;
                    case CimRejectDisposition.REMOVE_DIRECT_TARGET:
                        call_state.remove_cim_action_target(from_jid,
                            message_type, call_id);
                        debug(@"[%s] %s rejected our direct MUJI invite",
                            account.bare_jid.to_string(),
                            from_jid.to_string());
                        return;
                    default:
                        debug(@"[%s] Ignoring shared-room MUJI reject from %s",
                            account.bare_jid.to_string(),
                            from_jid.to_string());
                        return;
                }
            });
            call_invites_module.call_left.connect((from_jid, to_jid,
                    call_id, message_type) => {
                bool from_own_account =
                    from_jid.equals_bare(account.bare_jid);
                CallState? call_state = from_own_account
                    ? get_call_state_for_own_cim_action(account, to_jid,
                        message_type, call_id)
                    : get_call_state_for_cim_action(account, from_jid,
                        message_type, call_id);
                if (call_state == null) return;
                CimLeftDisposition disposition =
                    CallState.select_cim_left_disposition(
                        from_own_account,
                        from_jid.equals(account.full_jid),
                        call_state.call.direction ==
                            Call.DIRECTION_OUTGOING,
                        call_state.has_cim_action_target(from_jid,
                            message_type, call_id),
                        call_state.group_call != null, message_type);
                switch (disposition) {
                    case CimLeftDisposition.FINISH_LOCAL:
                        call_state.finish_remote_left(from_jid);
                        return;
                    case CimLeftDisposition.REMOVE_DIRECT_PARTICIPANT:
                        call_state.finish_remote_group_participant_left(
                            from_jid, message_type, call_id);
                        return;
                    default:
                        debug(@"[%s] Ignoring unowned/shared-room CIM left from %s",
                            account.bare_jid.to_string(),
                            from_jid.to_string());
                        return;
                }
            });

            stream_interactor.module_manager.get_module<Xep.Coin.Module>(account, Xep.Coin.Module.IDENTITY).coin_info_received.connect((jid, info) => {
                foreach (Call call in call_states.keys) {
                    if (call.counterparts[0].equals_bare(jid)) {
                        conference_info_received(call, info);
                        return;
                    }
                }
            });
        }
    }
}
