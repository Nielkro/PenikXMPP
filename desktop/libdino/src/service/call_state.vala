using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino {

internal delegate bool GroupCallRejoinValidity();

public enum ParticipantInviteAvailability {
    AVAILABLE,
    NOT_CONNECTED,
    CONVERTING,
    ENGINE_UNSUPPORTED,
    PEER_UNSUPPORTED,
    NO_MUC_SERVICE,
    NO_INVITE_PERMISSION,
    CALL_FULL,
    ENDED,
    CONTACT_UNSUPPORTED
}

internal class MujiInviteAttempt : Object {
    public Jid invitee { get; private set; }
    public uint64 generation { get; private set; }
    public uint timeout_source_id { get; set; default = 0; }
    public uint cleanup_retry_source_id { get; set; default = 0; }
    public uint cleanup_failures { get; set; default = 0; }
    public bool retract_sent { get; set; default = false; }
    public bool ready_joined { get; private set; default = false; }
    public Xep.Muji.GroupCall? group_call { get; set; default = null; }
    public XmppStream? stream { get; set; default = null; }
    // Stable conference identity and one XEP-0482 invitation are different
    // lifetimes: a re-invite must not replay its predecessor's message ID.
    public string? call_id { get; set; default = null; }
    public string proposal_id { get; private set; }

    public MujiInviteAttempt(Jid invitee, uint64 generation) {
        this.invitee = invitee.bare_jid;
        this.generation = generation;
        this.proposal_id = Xmpp.random_uuid();
    }

    internal void mark_ready_joined() { ready_joined = true; }
}

/**
 * Owns one current invitation attempt per bare JID. Replacing an attempt
 * synchronously cancels both its join timeout and any pending cleanup retry,
 * so a re-invite can invalidate all older work before its first await.
 */
internal class MujiInviteAttemptRegistry : Object {
    internal const uint MAX_CLEANUP_RETRIES = 3;

    private HashMap<Jid, MujiInviteAttempt> attempts =
        new HashMap<Jid, MujiInviteAttempt>(Jid.hash_bare_func,
            Jid.equals_bare_func);
    private uint64 generation_counter = 0;

    public bool has_current(Jid invitee) {
        return attempts.has_key(invitee.bare_jid);
    }

    public MujiInviteAttempt begin(Jid invitee) {
        Jid bare_invitee = invitee.bare_jid;
        if (attempts.has_key(bare_invitee)) {
            cancel_sources(attempts[bare_invitee]);
        }

        MujiInviteAttempt attempt = new MujiInviteAttempt(bare_invitee,
            ++generation_counter);
        attempts[bare_invitee] = attempt;
        return attempt;
    }

    public bool is_current(MujiInviteAttempt attempt) {
        return attempts.has_key(attempt.invitee) &&
            attempts[attempt.invitee] == attempt;
    }

    public MujiInviteAttempt? get_current(Jid invitee) {
        return attempts.get(invitee.bare_jid);
    }

    public bool complete_ready_peer(MujiInviteAttempt attempt, Jid real_jid,
            Xep.Muji.GroupCall group_call, XmppStream stream, string? call_id) {
        if (!is_current(attempt) || attempt.group_call != group_call ||
                attempt.stream != stream || attempt.call_id != call_id ||
                group_call.left || !real_jid.is_full() ||
                !real_jid.equals_bare(attempt.invitee)) return false;
        foreach (Jid occupant in group_call.peers) {
            Jid? current_real = group_call.real_jids.get(occupant);
            if (group_call.has_muji_participant(occupant) &&
                    current_real != null && ((!) current_real).equals(real_jid)) {
                // Ready membership is independent of a later media failure.
                // Retire the invitation once, not when its 60s timer happens
                // to inspect the transient set of media PeerState objects.
                // This cancels future work, not an affiliation IQ already sent.
                attempt.mark_ready_joined();
                release(attempt);
                return true;
            }
        }
        return false;
    }

    public bool complete_if_ready(MujiInviteAttempt attempt,
            Xep.Muji.GroupCall group_call, XmppStream stream, string? call_id) {
        foreach (Jid occupant in group_call.peers) {
            Jid? real_jid = group_call.real_jids.get(occupant);
            if (real_jid != null && complete_ready_peer(attempt, (!) real_jid,
                    group_call, stream, call_id)) return true;
        }
        return false;
    }

    public void release(MujiInviteAttempt attempt) {
        if (!is_current(attempt)) return;
        cancel_sources(attempt);
        attempts.unset(attempt.invitee);
    }

    /**
     * Records one failed cleanup. Returns true while another bounded retry is
     * owned by this attempt and supplies its delay. Exhaustion releases the
     * attempt so failed server cleanup cannot leave an immortal local lease.
     */
    public bool register_cleanup_failure(MujiInviteAttempt attempt,
            out uint retry_delay_seconds) {
        retry_delay_seconds = 0;
        if (!is_current(attempt)) return false;

        attempt.cleanup_failures++;
        if (attempt.cleanup_failures > MAX_CLEANUP_RETRIES) {
            release(attempt);
            return false;
        }

        switch (attempt.cleanup_failures) {
            case 1: retry_delay_seconds = 2; break;
            case 2: retry_delay_seconds = 5; break;
            default: retry_delay_seconds = 10; break;
        }
        return true;
    }

    public void clear() {
        foreach (MujiInviteAttempt attempt in attempts.values) {
            cancel_sources(attempt);
        }
        attempts.clear();
    }

    private static void cancel_sources(MujiInviteAttempt attempt) {
        if (attempt.timeout_source_id != 0) {
            Source.remove(attempt.timeout_source_id);
            attempt.timeout_source_id = 0;
        }
        if (attempt.cleanup_retry_source_id != 0) {
            Source.remove(attempt.cleanup_retry_source_id);
            attempt.cleanup_retry_source_id = 0;
        }
    }
}

/** De-duplicates UI invites that arrive while private-room setup is pending. */
internal class PendingMujiInviteRegistry : Object {
    private HashSet<Jid> invitees = new HashSet<Jid>(Jid.hash_bare_func,
        Jid.equals_bare_func);

    internal int size { get { return invitees.size; } }

    internal void add(Jid invitee) {
        invitees.add(invitee.bare_jid);
    }

    internal ArrayList<Jid> drain(Jid? exclude = null) {
        var drained = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Jid invitee in invitees) {
            if (exclude == null || !invitee.equals_bare((!) exclude)) {
                drained.add(invitee);
            }
        }
        invitees.clear();
        return drained;
    }

    internal void clear() {
        invitees.clear();
    }
}

/** Main-context latest-wins state for one call's asynchronous effect requests. */
internal class VideoEffectLatestWinsQueue : Object {
    private uint64 generation = 1;
    private bool processing = false;
    private Plugins.JmiVideoEffectSelection? pending = null;

    internal bool in_flight { get { return processing; } }
    internal bool has_pending { get { return pending != null; } }

    internal void enqueue(Plugins.JmiVideoEffectSelection selection) {
        pending = selection;
    }

    internal uint64 begin_processing() {
        if (processing) return 0;
        processing = true;
        return generation;
    }

    internal Plugins.JmiVideoEffectSelection? take(uint64 processing_generation) {
        if (!processing || processing_generation != generation || pending == null) return null;
        Plugins.JmiVideoEffectSelection selection = (!) pending;
        pending = null;
        return selection;
    }

    internal bool is_current(uint64 processing_generation) {
        return processing && processing_generation == generation;
    }

    /**
     * Completes one in-flight generation. A replacement queued while an old
     * PeerState session returned CANCELLED remains owned and requests restart.
     */
    internal bool finish(uint64 processing_generation) {
        processing = false;
        if (processing_generation != generation) {
            pending = null;
            return false;
        }
        return pending != null;
    }

    internal void invalidate() {
        generation++;
        pending = null;
    }
}

/**
 * Monotone ownership token for asynchronous call work.  Ending a call or
 * superseding an operation invalidates every continuation which captured an
 * older token before its first await.
 */
internal class CallLifecycleGeneration : Object {
    private uint64 generation = 1;
    private bool closed = false;

    internal uint64 capture() {
        return generation;
    }

    internal bool is_current(uint64 token) {
        return !closed && token == generation;
    }

    internal void supersede() {
        generation++;
        if (generation == 0) generation++;
    }

    internal bool close() {
        if (closed) return false;
        closed = true;
        supersede();
        return true;
    }
}

/** Atomic publication boundary for one asynchronous MUJI join. */
internal class GroupJoinPublicationTransaction : Object {
    private CallLifecycleGeneration lifecycle;
    internal uint64 generation { get; private set; }
    internal bool committed { get; private set; default=false; }
    internal uint published_events { get; private set; default=0; }

    internal GroupJoinPublicationTransaction(
            CallLifecycleGeneration lifecycle) {
        this.lifecycle = lifecycle;
        this.generation = lifecycle.capture();
    }

    internal bool try_commit(bool joined_group_call_live = true) {
        if (committed || !joined_group_call_live ||
                !lifecycle.is_current(generation)) return false;
        committed = true;
        return true;
    }

    internal bool try_publish_event() {
        if (!committed || !lifecycle.is_current(generation)) return false;
        published_events++;
        return true;
    }
}

/**
 * Owns the accept side of one incoming MUJI invitation.  Source-room policy
 * is supplied by CallState at every asynchronous boundary; once either that
 * policy or the call lifecycle becomes stale, neither the joined room nor an
 * accept stanza can be published.
 */
internal class IncomingGroupAcceptTransaction : Object {
    private CallLifecycleGeneration lifecycle;
    private uint64 generation;
    private bool invalidated = false;
    internal bool join_published { get; private set; default=false; }
    internal bool accept_claimed { get; private set; default=false; }

    internal IncomingGroupAcceptTransaction(
            CallLifecycleGeneration lifecycle) {
        this.lifecycle = lifecycle;
        this.generation = lifecycle.capture();
    }

    internal bool may_continue(bool source_room_current) {
        if (invalidated || !source_room_current ||
                !lifecycle.is_current(generation)) {
            invalidated = true;
            return false;
        }
        return true;
    }

    internal bool try_publish_join(bool source_room_current) {
        if (join_published || !may_continue(source_room_current)) return false;
        join_published = true;
        return true;
    }

    internal bool try_claim_accept(bool source_room_current) {
        if (!join_published || accept_claimed ||
                !may_continue(source_room_current)) return false;
        accept_claimed = true;
        return true;
    }

    internal void invalidate() {
        invalidated = true;
    }
}

/**
 * A Direct-to-MUJI proposal is speculative until the room and group owner are
 * published. Before that boundary a failed join may reject only the proposal;
 * it must not consume the already active direct-call lifecycle.
 */
internal class DirectMujiAdoptionTransaction : Object {
    internal bool group_published { get; private set; default=false; }
    private bool rollback_claimed = false;
    private bool response_claimed = false;

    internal void mark_group_published() {
        group_published = true;
    }

    internal bool try_claim_direct_rollback(bool lifecycle_current,
            bool direct_peer_owned) {
        if (rollback_claimed || group_published || !lifecycle_current ||
                !direct_peer_owned) return false;
        rollback_claimed = true;
        return true;
    }

    internal bool try_claim_reject() {
        if (!rollback_claimed || response_claimed) return false;
        response_claimed = true;
        return true;
    }
}

/**
 * Fences one outgoing PeerState capability lookup against call teardown and
 * XMPP stream replacement before it may create a session or send a proposal.
 */
internal class PeerCallInitiationTransaction : Object {
    private CallLifecycleGeneration lifecycle;
    private uint64 generation;
    private Object expected_stream;
    internal uint session_start_claims { get; private set; default=0; }
    internal uint proposal_claims { get; private set; default=0; }

    internal PeerCallInitiationTransaction(
            CallLifecycleGeneration lifecycle, Object expected_stream) {
        this.lifecycle = lifecycle;
        this.generation = lifecycle.capture();
        this.expected_stream = expected_stream;
    }

    internal bool may_continue(Object? current_stream) {
        return current_stream == expected_stream &&
            lifecycle.is_current(generation);
    }

    internal bool try_claim_session_start(Object? current_stream) {
        if (!may_continue(current_stream) || session_start_claims != 0) {
            return false;
        }
        session_start_claims++;
        return true;
    }

    internal bool try_claim_proposal(Object? current_stream) {
        if (!may_continue(current_stream) || proposal_claims != 0) {
            return false;
        }
        proposal_claims++;
        return true;
    }
}

internal enum MujiPublishedRoomExitAction {
    NONE,
    LEAVE
}

/**
 * A published MUJI room is decentralized.  Local creator status is retained
 * for auditability, but normal terminal ownership can only claim one leave;
 * it can never authorize destroying the room for the remaining participants.
 */
internal class MujiPublishedRoomLifecycle : Object {
    internal bool locally_created { get; private set; }
    internal bool published { get; private set; default=false; }
    private bool terminal_exit_claimed = false;

    internal MujiPublishedRoomLifecycle(bool locally_created) {
        this.locally_created = locally_created;
    }

    internal void mark_published() {
        published = true;
    }

    internal MujiPublishedRoomExitAction claim_terminal_exit() {
        if (!published || terminal_exit_claimed) {
            return MujiPublishedRoomExitAction.NONE;
        }
        terminal_exit_claimed = true;
        return MujiPublishedRoomExitAction.LEAVE;
    }

    internal bool should_wait_for_preparing_peer(int connected_peers) {
        return published && !terminal_exit_claimed && connected_peers == 0;
    }

    internal bool can_manage_invites(bool private_config_committed) {
        return locally_created && published && !terminal_exit_claimed &&
            private_config_committed;
    }
}

/** Single claimant for all terminal resource ownership. */
internal class TerminalTeardownGate : Object {
    internal bool claimed { get; private set; default=false; }

    internal bool try_claim() {
        if (claimed) return false;
        claimed = true;
        return true;
    }
}

internal enum CimTerminalSignalAction {
    NONE,
    REJECT,
    RETRACT,
    LEFT
}

internal enum CimRejectDisposition {
    IGNORE,
    FINISH_LOCAL,
    REMOVE_DIRECT_TARGET
}

internal enum CimLeftDisposition {
    IGNORE,
    FINISH_LOCAL,
    REMOVE_DIRECT_PARTICIPANT
}

/**
 * Owns the point at which a MUJI presence event has actually published a
 * media peer into CallState.  Merely seeing <preparing/> is not sufficient to
 * disarm the empty-room watchdog: engine expectation can still fail before a
 * PeerState exists.
 */
internal class MujiPeerJoinPublication : Object {
    private bool peer_published = false;
    private bool timeout_cancel_claimed = false;

    internal void mark_peer_published() {
        peer_published = true;
    }

    internal bool claim_empty_timeout_cancel() {
        if (!peer_published || timeout_cancel_claimed) return false;
        timeout_cancel_claimed = true;
        return true;
    }
}

/** Separates local UI acceptance from an accept stanza published on wire. */
internal class CimAcceptPublication : Object {
    internal bool published { get; private set; default=false; }
    private bool terminal_signal_claimed = false;

    internal void mark_published() {
        published = true;
    }

    internal CimTerminalSignalAction terminal_action(
            bool direction, Call.State state) {
        if (direction == Call.DIRECTION_INCOMING && !published) {
            return CimTerminalSignalAction.REJECT;
        }
        if (state == Call.State.IN_PROGRESS ||
                state == Call.State.ESTABLISHING) {
            return CimTerminalSignalAction.LEFT;
        }
        if (direction == Call.DIRECTION_OUTGOING &&
                state == Call.State.RINGING) {
            return CimTerminalSignalAction.RETRACT;
        }
        return CimTerminalSignalAction.NONE;
    }

    internal CimTerminalSignalAction claim_terminal_action(
            bool direction, Call.State state) {
        if (terminal_signal_claimed) return CimTerminalSignalAction.NONE;
        CimTerminalSignalAction action = terminal_action(direction, state);
        if (action != CimTerminalSignalAction.NONE) {
            terminal_signal_claimed = true;
        }
        return action;
    }
}

/** Transactional proof that an owned MUJI room is safe to advertise. */
internal class PrivateMujiConversionTransaction : Object {
    internal bool room_joined { get; private set; default=false; }
    internal bool private_config_applied { get; private set; default=false; }
    internal bool rolled_back { get; private set; default=false; }
    internal bool proposal_claimed { get; private set; default=false; }
    internal Jid? staged_occupant { get; private set; }
    internal Xep.Muc.Flag? staged_muc_flag { get; private set; }
    internal MucManager.MucOwnerMutationContext? staged_owner_context { get; private set; }
    internal Xmpp.Presence.Stanza? staged_self_presence { get; private set; }
    private bool staged_room_created = false;
    private bool muji_join_started = false;
    private bool stage_cleanup_claimed = false;

    internal void record_staged_occupancy(Jid occupant, Xep.Muc.Flag flag,
            bool newly_created = false, MucManager.MucOwnerMutationContext? owner_context = null,
            Xmpp.Presence.Stanza? self_presence = null) {
        if (staged_occupant != null) return;
        staged_occupant = occupant;
        staged_muc_flag = flag;
        staged_room_created = newly_created;
        staged_owner_context = owner_context;
        staged_self_presence = self_presence;
    }

    internal void mark_muji_join_started() {
        muji_join_started = true;
    }

    internal bool try_claim_unpublished_room_cleanup(bool owner_current, bool alone) {
        if (!staged_room_created || staged_owner_context == null || !owner_current ||
                !alone || muji_join_started || proposal_claimed || stage_cleanup_claimed) return false;
        stage_cleanup_claimed = true;
        return true;
    }

    internal bool owns_staged_occupancy(XmppStream stream) {
        Xep.Muc.Flag? current = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        return staged_occupant != null && staged_muc_flag == current && current != null &&
            current.get_muc_nick(staged_occupant.bare_jid) == staged_occupant.resourcepart;
    }

    internal void mark_room_joined() {
        if (!rolled_back) room_joined = true;
    }

    internal void mark_private_config_applied() {
        if (!rolled_back && room_joined) private_config_applied = true;
    }

    internal void rollback() {
        rolled_back = true;
        private_config_applied = false;
    }

    internal bool may_propose() {
        return room_joined && private_config_applied && !rolled_back;
    }

    internal bool try_claim_proposal() {
        if (proposal_claimed || !may_propose()) return false;
        proposal_claimed = true;
        return true;
    }
}

internal class CimTarget : Object {
    internal Jid jid { get; private set; }
    internal string message_type { get; private set; }
    private string? bound_reference_id = null;

    internal CimTarget(Jid jid, string message_type) {
        this.message_type = message_type;
        this.jid = message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT
            ? jid.bare_jid : jid;
    }

    internal bool bind_groupchat_reference(string reference_id) {
        if (message_type != Xmpp.MessageStanza.TYPE_GROUPCHAT ||
                reference_id.strip() == "") return false;
        if (bound_reference_id == null) {
            bound_reference_id = reference_id;
            return true;
        }
        return bound_reference_id == reference_id;
    }

    internal bool bind_direct_reference(string reference_id) {
        if (message_type != Xmpp.MessageStanza.TYPE_CHAT ||
                reference_id.strip() == "" || bound_reference_id != null) return false;
        bound_reference_id = reference_id;
        return true;
    }

    private bool matches_sender(Jid sender) {
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return jid.equals(sender.bare_jid);
        }
        return jid.is_bare() ? jid.equals_bare(sender) : jid.equals(sender);
    }

    internal bool matches_reference(string reference_id,
            string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        if (bound_reference_id == reference_id) return true;
        if (bound_reference_id != null ||
                message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT &&
                !allow_groupchat_fallback) return false;
        return fallback_reference_id == reference_id;
    }

    internal bool matches_action(Jid sender, string action_message_type,
            string reference_id, string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        return message_type == action_message_type &&
            matches_sender(sender) &&
            matches_reference(reference_id, fallback_reference_id,
                allow_groupchat_fallback);
    }

    internal bool matches_destination(Jid destination,
            string action_message_type, string reference_id,
            string? fallback_reference_id, bool allow_groupchat_fallback) {
        return message_type == action_message_type &&
            matches_sender(destination) &&
            matches_reference(reference_id, fallback_reference_id,
                allow_groupchat_fallback);
    }

    internal string? resolve_reference(string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        if (bound_reference_id != null) return bound_reference_id;
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT &&
                !allow_groupchat_fallback) return null;
        return fallback_reference_id;
    }
}

/** Exact signaling destinations with their current Call Invites references. */
internal class CimTargetRegistry : Object {
    private ArrayList<CimTarget> targets = new ArrayList<CimTarget>();

    internal int size { get { return targets.size; } }

    internal void add(Jid jid, string message_type) {
        Jid normalized = message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT
            ? jid.bare_jid : jid;
        foreach (CimTarget target in targets) {
            if (target.message_type == message_type &&
                    target.jid.equals(normalized)) return;
        }
        targets.add(new CimTarget(normalized, message_type));
    }

    /**
     * Publish a new direct invitation, without changing the conference/room
     * reference. A bare-JID invitation supersedes older resource targets for
     * that participant too (including the initial 1:1 conversion target).
     * Replace objects rather than mutating snapshots held by older work.
     */
    internal bool replace_direct_reference(Jid jid, string reference_id) {
        var replacement = new CimTarget(jid, Xmpp.MessageStanza.TYPE_CHAT);
        if (!replacement.bind_direct_reference(reference_id)) return false;
        var superseded = new ArrayList<CimTarget>();
        foreach (CimTarget target in targets) {
            if (target.message_type == Xmpp.MessageStanza.TYPE_CHAT &&
                    (jid.is_bare() ? target.jid.equals_bare(jid)
                        : target.jid.equals(jid))) superseded.add(target);
        }
        foreach (CimTarget target in superseded) targets.remove(target);
        targets.add(replacement);
        return true;
    }

    internal bool contains(Jid jid, string message_type) {
        Jid normalized = message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT
            ? jid.bare_jid : jid;
        foreach (CimTarget target in targets) {
            if (target.message_type == message_type &&
                    target.jid.equals(normalized)) return true;
        }
        return false;
    }

    internal bool bind_groupchat_reference(Jid room,
            string reference_id) {
        Jid normalized = room.bare_jid;
        foreach (CimTarget target in targets) {
            if (target.message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT &&
                    target.jid.equals(normalized)) {
                return target.bind_groupchat_reference(reference_id);
            }
        }
        return false;
    }

    internal bool matches_reference(string reference_id,
            string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        foreach (CimTarget target in targets) {
            if (target.matches_reference(reference_id,
                    fallback_reference_id,
                    allow_groupchat_fallback)) return true;
        }
        return false;
    }

    internal bool matches_action(Jid sender, string message_type,
            string reference_id, string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        foreach (CimTarget target in targets) {
            if (target.matches_action(sender, message_type, reference_id,
                    fallback_reference_id,
                    allow_groupchat_fallback)) return true;
        }
        return false;
    }

    internal bool matches_destination(Jid destination, string message_type,
            string reference_id, string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        foreach (CimTarget target in targets) {
            if (target.matches_destination(destination, message_type,
                    reference_id, fallback_reference_id,
                    allow_groupchat_fallback)) return true;
        }
        return false;
    }

    internal bool remove_action_target(Jid sender, string message_type,
            string reference_id, string? fallback_reference_id,
            bool allow_groupchat_fallback) {
        CimTarget? remove_target = null;
        foreach (CimTarget target in targets) {
            if (target.matches_action(sender, message_type, reference_id,
                    fallback_reference_id, allow_groupchat_fallback)) {
                remove_target = target;
                break;
            }
        }
        if (remove_target == null) return false;
        targets.remove((!) remove_target);
        return true;
    }

    internal bool remove(Jid jid, string message_type) {
        Jid normalized = message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT
            ? jid.bare_jid : jid;
        CimTarget? remove_target = null;
        foreach (CimTarget target in targets) {
            if (target.message_type == message_type &&
                    target.jid.equals(normalized)) {
                remove_target = target;
                break;
            }
        }
        if (remove_target == null) return false;
        targets.remove((!) remove_target);
        return true;
    }

    /** A groupchat rejection is from one occupant, not from the room target. */
    internal bool remove_rejected_participant(Jid jid,
            string message_type) {
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) return false;
        CimTarget? remove_target = null;
        foreach (CimTarget target in targets) {
            if (target.message_type == message_type &&
                    (target.jid.is_bare()
                        ? target.jid.equals_bare(jid)
                        : target.jid.equals(jid))) {
                remove_target = target;
                break;
            }
        }
        if (remove_target == null) return false;
        targets.remove((!) remove_target);
        return true;
    }

    internal bool contains_participant(Jid jid, string message_type) {
        foreach (CimTarget target in targets) {
            if (target.message_type != message_type) continue;
            if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
                if (target.jid.equals(jid.bare_jid)) return true;
            } else if (target.jid.is_bare()
                    ? target.jid.equals_bare(jid)
                    : target.jid.equals(jid)) {
                return true;
            }
        }
        return false;
    }

    internal ArrayList<CimTarget> snapshot() {
        var copy = new ArrayList<CimTarget>();
        copy.add_all(targets);
        return copy;
    }

    internal void restore(ArrayList<CimTarget> snapshot) {
        targets.clear();
        targets.add_all(snapshot);
    }

    internal void clear() {
        targets.clear();
    }
}

}

public enum Dino.CallMediaBackend {
    LEGACY_RTP,
    GOOGLE_WEBRTC
}

internal enum Dino.MujiMediaPolicyAction {
    NONE,
    DOWNGRADE_TO_AUDIO,
    END_CALL
}

private enum Dino.TerminalPeerAction {
    DISCARD,
    REJECT,
    CANCEL
}

public class Dino.CallState : Object {

    public const int MAX_MUJI_PEERS = 4;
    public const string CALL_FULL_REASON = "call-full";
    internal const string MUJI_INVITEE_AFFILIATION = "member";

    public signal void terminated(Jid who_terminated, string? reason_name, string? reason_text);
    internal signal void terminal_state_will_persist();
    public signal void peer_joined(Jid jid, PeerState peer_state);
    internal signal void cim_groupchat_terminal_deferred(Jid room,
        string provisional_id, CimTerminalSignalAction action);
    public signal void peer_left(Jid jid, PeerState peer_state, string? reason_name, string? reason_text);
    public signal void video_effect_status_changed(Plugins.JmiVideoEffectStatus status);
    public signal void accept_capability_changed();
    public signal void participant_invite_availability_changed();

    public StreamInteractor stream_interactor;
    public Plugins.VideoCallPlugin? call_plugin = Dino.Application.get_default().plugin_registry.video_call_plugin;
    public Call call;
    public CallMediaBackend media_backend { get; private set; }
    public Jid? invited_to_group_call = null;
    public bool accepted { get; private set; default=false; }

    public bool use_cim = false;
    public string? cim_call_id = null;
    public Jid? cim_counterpart = null;
    private string? cim_counterpart_message_type = null;
    private CimTargetRegistry cim_targets = new CimTargetRegistry();

    public Xep.Muji.GroupCall? group_call { get; set; }
    public bool we_should_send_audio { get; set; default=false; }
    public bool we_should_send_video { get; set; default=false; }
    public bool can_invite_group_participants {
        get; private set; default=false;
    }

    public HashMap<Jid, PeerState> peers = new HashMap<Jid, PeerState>(Jid.hash_func, Jid.equals_func);

    private HashMap<Jid, ArrayList<Binding>> peer_bindings = new HashMap<Jid, ArrayList<Binding>>(Jid.hash_func, Jid.equals_func);
    private HashMap<Jid, ulong> peer_stream_created_handler_ids = new HashMap<Jid, ulong>(Jid.hash_func, Jid.equals_func);
    private HashMap<Jid, ulong> peer_session_terminated_handler_ids = new HashMap<Jid, ulong>(Jid.hash_func, Jid.equals_func);
    private HashMap<Jid, ulong> peer_video_effect_handler_ids = new HashMap<Jid, ulong>(Jid.hash_func, Jid.equals_func);
    private MujiInviteAttemptRegistry invite_attempts =
        new MujiInviteAttemptRegistry();
    private PendingMujiInviteRegistry pending_muji_invites =
        new PendingMujiInviteRegistry();
    private uint establishing_timeout_id = 0;
    private uint muji_empty_muc_timeout_id = 0;
    private bool _group_call_converting = false;
    private bool group_call_converting {
        get { return _group_call_converting; }
        set {
            if (_group_call_converting == value) return;
            _group_call_converting = value;
            participant_invite_availability_changed();
        }
    }
    private bool _group_call_joining = false;
    private bool group_call_joining {
        get { return _group_call_joining; }
        set {
            if (_group_call_joining == value) return;
            _group_call_joining = value;
            participant_invite_availability_changed();
        }
    }
    private Cancellable? pending_muji_join_cancellable = null;
    private bool teardown_started = false;
    private bool termination_emitted = false;
    private bool archive_recovery_pending = false;
    private bool group_video_permanently_disabled = false;
    private CallLifecycleGeneration lifecycle = new CallLifecycleGeneration();
    private TerminalTeardownGate terminal_teardown =
        new TerminalTeardownGate();
    private PrivateMujiConversionTransaction? private_group_conversion = null;
    private bool groupchat_preparing_claimed = false;
    private bool groupchat_proposal_claimed = false;
    private CimAcceptPublication cim_accept_publication =
        new CimAcceptPublication();
    private MucManager.MucOwnerMutationContext?
        incoming_group_source_context = null;
    private Jid? incoming_group_inviter_occupant = null;
    private Jid? incoming_group_inviter_real_jid = null;
    private IncomingGroupAcceptTransaction?
        active_incoming_group_accept = null;
    private MujiPublishedRoomLifecycle? active_muji_room_lifecycle = null;
    private XmppStream? active_muji_stream = null;
    internal bool video_effects_group_gate_active { get; private set; default=false; }
    private VideoEffectLatestWinsQueue video_effect_requests =
        new VideoEffectLatestWinsQueue();
    private VideoEffectLatestWinsQueue group_video_effect_requests =
        new VideoEffectLatestWinsQueue();
    private weak Plugins.MujiCallEngineGroupSession? group_video_effect_queue_owner;
    private weak Xep.Muji.GroupCall? group_video_effect_queue_room;
    private Plugins.JmiVideoEffectStatus cached_video_effect_status =
        unavailable_video_effect_status(Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);

    private Plugins.MediaDevice selected_microphone_device;
    private Plugins.MediaDevice selected_speaker_device;
    private Plugins.MediaDevice selected_video_device;
    private Plugins.JmiCallEnginePlugin? selected_jmi_call_engine;
    private Plugins.MujiCallEnginePlugin? selected_muji_call_engine;
    private Plugins.MujiCallEngineGroupSession? muji_engine_group_session;
    private ulong muji_engine_incoming_peer_handler_id = 0;
    private ulong muji_engine_incoming_peer_failed_handler_id = 0;
    private ulong muji_engine_video_effect_handler_id = 0;
    private Xep.Muji.GroupCall? observed_group_call = null;
    private ulong group_call_peer_joined_handler_id = 0;
    private ulong group_call_peer_left_handler_id = 0;
    private ulong group_call_codecs_changed_handler_id = 0;
    private ulong group_call_media_availability_handler_id = 0;

    public CallState(
            Call call,
            StreamInteractor stream_interactor,
            CallMediaBackend media_backend = CallMediaBackend.LEGACY_RTP,
            Plugins.JmiCallEnginePlugin? selected_jmi_call_engine = null,
            Plugins.MujiCallEnginePlugin? selected_muji_call_engine = null) {
        this.call = call;
        this.stream_interactor = stream_interactor;
        this.media_backend = media_backend;
        this.selected_jmi_call_engine = selected_jmi_call_engine;
        this.selected_muji_call_engine = selected_muji_call_engine;

        if (call.direction == Call.DIRECTION_OUTGOING &&
                call.state != Call.State.OTHER_DEVICE) {
            accepted = true;
            // Timeout is started separately per call type (1:1 or MUJI)
        }
        this.notify["group-call"].connect(on_video_effect_call_shape_changed);
        this.notify["can-invite-group-participants"].connect(() => {
            participant_invite_availability_changed();
        });
    }

    internal void configure_cim_invite(string call_id, Jid proposer,
            Jid target, string message_type) {
        use_cim = true;
        cim_call_id = call_id;
        cim_counterpart = proposer;
        cim_counterpart_message_type = message_type;
        add_cim_target(target, message_type);
    }

    internal void add_cim_target(Jid target, string message_type) {
        cim_targets.add(target, message_type);
    }

    internal void remove_cim_target(Jid target, string message_type) {
        cim_targets.remove(target, message_type);
    }

    internal bool remove_rejected_cim_target(Jid rejector,
            string message_type) {
        return cim_targets.remove_rejected_participant(rejector,
            message_type);
    }

    internal bool remove_cim_action_target(Jid sender, string message_type,
            string call_id) {
        return cim_targets.remove_action_target(sender, message_type, call_id,
            cim_call_id, call.direction != Call.DIRECTION_OUTGOING);
    }

    internal bool has_cim_target(Jid target, string message_type) {
        return cim_targets.contains(target, message_type);
    }

    internal bool has_cim_participant(Jid participant,
            string message_type) {
        return cim_targets.contains_participant(participant, message_type);
    }

    internal bool has_cim_action_target(Jid sender, string message_type,
            string call_id) {
        return cim_targets.matches_action(sender, message_type, call_id,
            cim_call_id, call.direction != Call.DIRECTION_OUTGOING);
    }

    internal bool has_cim_destination(Jid destination, string message_type,
            string call_id) {
        return cim_targets.matches_destination(destination, message_type,
            call_id, cim_call_id,
            call.direction != Call.DIRECTION_OUTGOING);
    }

    internal bool matches_cim_call_id(string call_id) {
        return cim_targets.matches_reference(call_id, cim_call_id,
            call.direction != Call.DIRECTION_OUTGOING);
    }

    internal bool matches_outgoing_groupchat_provisional(Jid room,
            string provisional_id) {
        return call.direction == Call.DIRECTION_OUTGOING && use_cim &&
            !teardown_started && cim_call_id == provisional_id &&
            cim_targets.contains(room, Xmpp.MessageStanza.TYPE_GROUPCHAT);
    }

    internal bool bind_outgoing_groupchat_cim_reference(Jid room,
            string provisional_id, string room_reference_id) {
        if (call.direction != Call.DIRECTION_OUTGOING || !use_cim ||
                teardown_started || cim_call_id != provisional_id ||
                !cim_targets.contains(room,
                    Xmpp.MessageStanza.TYPE_GROUPCHAT)) return false;
        return cim_targets.bind_groupchat_reference(room,
            room_reference_id);
    }

    private string? cim_reference_for_target(CimTarget target) {
        return target.resolve_reference(cim_call_id,
            call.direction != Call.DIRECTION_OUTGOING);
    }

    internal bool is_cim_proposer(Jid candidate, string message_type) {
        if (cim_counterpart == null ||
                cim_counterpart_message_type != message_type) return false;
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return candidate.equals((!) cim_counterpart);
        }
        return candidate.equals_bare((!) cim_counterpart);
    }

    internal void configure_incoming_group_source(
            MucManager.MucOwnerMutationContext source_context,
            Jid? inviter_occupant = null,
            Jid? inviter_real_jid = null) {
        incoming_group_source_context = source_context;
        incoming_group_inviter_occupant = inviter_occupant;
        incoming_group_inviter_real_jid = inviter_real_jid;
    }

    internal static bool call_invite_retractable(Call.State state) {
        return state == Call.State.RINGING ||
            state == Call.State.ESTABLISHING;
    }

    internal static CimRejectDisposition select_cim_reject_disposition(
            bool from_own_account, bool from_own_full_resource,
            bool outgoing_call, bool expected_direct_target,
            bool has_group_call, string message_type) {
        if (from_own_account) {
            return from_own_full_resource
                ? CimRejectDisposition.IGNORE
                : CimRejectDisposition.FINISH_LOCAL;
        }
        // Reject is a response to a proposal we own. A foreign participant
        // must never close an incoming invitation, even if it knows the shared
        // room call id and sends a forged private type=chat response.
        if (!outgoing_call) return CimRejectDisposition.IGNORE;
        // One occupant's response to a broadcast room invitation must never
        // close another recipient's still-ringing local invitation or remove
        // the shared bare-room signaling target.
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return CimRejectDisposition.IGNORE;
        }
        if (!expected_direct_target) return CimRejectDisposition.IGNORE;
        return has_group_call
            ? CimRejectDisposition.REMOVE_DIRECT_TARGET
            : CimRejectDisposition.FINISH_LOCAL;
    }

    internal static CimLeftDisposition select_cim_left_disposition(
            bool from_own_account, bool from_own_full_resource,
            bool outgoing_call, bool expected_direct_target,
            bool has_group_call, string message_type) {
        if (from_own_account) {
            return from_own_full_resource
                ? CimLeftDisposition.IGNORE
                : CimLeftDisposition.FINISH_LOCAL;
        }
        // A GROUPCHAT left is one occupant's broadcast response. It must not
        // terminate the shared call on every other recipient. MUJI presence
        // owns participant removal in that room.
        if (message_type == Xmpp.MessageStanza.TYPE_GROUPCHAT) {
            return CimLeftDisposition.IGNORE;
        }
        if (!expected_direct_target) {
            return CimLeftDisposition.IGNORE;
        }
        if (has_group_call) {
            return CimLeftDisposition.REMOVE_DIRECT_PARTICIPANT;
        }
        return outgoing_call
            ? CimLeftDisposition.FINISH_LOCAL
            : CimLeftDisposition.IGNORE;
    }

    internal bool can_accept_direct_group_conversion(
            string incoming_call_id) {
        return direct_group_conversion_allowed(accepted, teardown_started,
            group_call != null, group_call_joining, group_call_converting,
            active_incoming_group_accept != null, call.state, cim_call_id,
            incoming_call_id);
    }

    internal static bool direct_group_conversion_allowed(bool accepted,
            bool teardown_started, bool has_group_call, bool joining,
            bool converting, bool accept_in_flight, Call.State state,
            string? current_call_id, string incoming_call_id) {
        if (!accepted || teardown_started || has_group_call || joining ||
                converting || accept_in_flight) return false;
        if (state != Call.State.ESTABLISHING &&
                state != Call.State.IN_PROGRESS) return false;
        return current_call_id == null ||
            current_call_id == incoming_call_id;
    }

    /** A direct media leg must not move while any MUJI owner is in flight. */
    internal bool can_migrate_active_direct_jmi() {
        return direct_jmi_migration_allowed(teardown_started,
            group_call != null, group_call_joining, group_call_converting,
            active_incoming_group_accept != null,
            muji_engine_group_session != null,
            private_group_conversion != null,
            active_muji_room_lifecycle != null, use_cim);
    }

    internal static bool direct_jmi_migration_allowed(bool teardown,
            bool has_group_call, bool joining, bool converting,
            bool incoming_accept_in_flight, bool has_muji_engine_owner,
            bool has_private_conversion, bool has_room_lifecycle,
            bool uses_cim) {
        return !teardown && !has_group_call && !joining && !converting &&
            !incoming_accept_in_flight && !has_muji_engine_owner &&
            !has_private_conversion && !has_room_lifecycle && !uses_cim;
    }

    internal PeerCallInitiationTransaction? begin_peer_call_initiation(
            XmppStream? expected_stream) {
        if (expected_stream == null ||
                !is_live_generation(lifecycle.capture(), expected_stream)) {
            return null;
        }
        return new PeerCallInitiationTransaction(lifecycle,
            (!) expected_stream);
    }

    internal bool peer_call_initiation_is_current(
            PeerCallInitiationTransaction transaction,
            XmppStream? current_stream) {
        return transaction.may_continue(current_stream) &&
            is_live_generation(lifecycle.capture(), current_stream);
    }

    internal static bool direct_to_muji_media_allowed(
            bool current_video, bool requested_video,
            out bool effective_video) {
        // An already negotiated 1:1 leg can only be adopted when its media set
        // exactly matches the room presence. Escalation would open a camera
        // without consent; downgrade would leave an unadvertised live video
        // content on the adopted Jingle session.
        effective_video = current_video && requested_video;
        return current_video == requested_video;
    }

    internal static MujiMediaPolicyAction muji_media_policy_action(
            string media, Xep.Muji.CodecAvailability availability) {
        if (media == "audio" && availability ==
                Xep.Muji.CodecAvailability.REQUIRED_UNAVAILABLE) {
            return MujiMediaPolicyAction.END_CALL;
        }
        if (media == "video" && availability ==
                Xep.Muji.CodecAvailability.OPTIONAL_UNAVAILABLE) {
            return MujiMediaPolicyAction.DOWNGRADE_TO_AUDIO;
        }
        return MujiMediaPolicyAction.NONE;
    }

    internal async bool accept_direct_group_conversion(string call_id,
            Jid proposer, Jid target, string message_type, Jid room_jid,
            bool requested_video) {
        bool effective_video;
        bool offer_audio;
        bool offer_video;
        if (!try_get_direct_offer_media(out offer_audio, out offer_video) || !offer_audio ||
                !direct_to_muji_media_allowed(offer_video,
                requested_video, out effective_video)) return false;

        bool previous_use_cim = use_cim;
        string? previous_call_id = cim_call_id;
        Jid? previous_counterpart = cim_counterpart;
        string? previous_message_type = cim_counterpart_message_type;
        ArrayList<CimTarget> previous_targets = cim_targets.snapshot();
        Jid? previous_invited_room = invited_to_group_call;
        bool previous_group_video_disabled =
            group_video_permanently_disabled;
        bool previous_effect_gate = video_effects_group_gate_active;
        var adoption = new DirectMujiAdoptionTransaction();

        configure_cim_invite(call_id, proposer, target, message_type);
        invited_to_group_call = room_jid;
        uint64 operation_generation = lifecycle.capture();
        var accept_transaction = new IncomingGroupAcceptTransaction(
            lifecycle);
        active_incoming_group_accept = accept_transaction;
        if (!incoming_group_accept_may_continue(accept_transaction)) {
            fail_stale_incoming_group_accept(
                "The source room changed before accepting the group call");
            return false;
        }
        bool joined = yield join_group_call(room_jid, false,
            accept_transaction);
        if (!is_live_generation(operation_generation)) return false;
        XmppStream? stream = stream_interactor.get_stream(call.account);
        if (!joined || group_call == null || stream == null) {
            if (adoption.try_claim_direct_rollback(
                    is_live_generation(operation_generation),
                    !peers.is_empty && group_call == null)) {
                rollback_failed_direct_group_adoption(adoption,
                    accept_transaction, previous_use_cim,
                    previous_call_id, previous_counterpart,
                    previous_message_type, previous_targets,
                    previous_invited_room,
                    previous_group_video_disabled, previous_effect_gate,
                    target, message_type, call_id,
                    "Could not join the proposed group-call room");
                return false;
            }
            fail_local(Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                "Could not convert the direct call into a group call");
            return false;
        }
        adoption.mark_group_published();
        if (!accept_transaction.try_claim_accept(
                is_current_incoming_group_source())) {
            fail_stale_incoming_group_accept(
                "The source room changed while accepting the group call");
            return false;
        }
        foreach (CimTarget invite_target in cim_targets.snapshot()) {
            string? target_call_id =
                cim_reference_for_target(invite_target);
            if (target_call_id == null) continue;
            ((!) stream).get_module<Xep.CallInvites.Module>(
                Xep.CallInvites.Module.IDENTITY).send_muji_accept(
                    (!) stream, invite_target.jid, (!) target_call_id,
                    room_jid,
                    invite_target.message_type);
        }
        cim_accept_publication.mark_published();
        if (active_incoming_group_accept == accept_transaction) {
            active_incoming_group_accept = null;
        }
        return true;
    }

    private void rollback_failed_direct_group_adoption(
            DirectMujiAdoptionTransaction adoption,
            IncomingGroupAcceptTransaction accept_transaction,
            bool previous_use_cim, string? previous_call_id,
            Jid? previous_counterpart, string? previous_message_type,
            ArrayList<CimTarget> previous_targets,
            Jid? previous_invited_room,
            bool previous_group_video_disabled, bool previous_effect_gate,
            Jid failed_target, string failed_message_type,
            string failed_call_id,
            string reason) {
        accept_transaction.invalidate();
        if (active_incoming_group_accept == accept_transaction) {
            active_incoming_group_accept = null;
        }

        if (adoption.try_claim_reject()) {
            XmppStream? maybe_stream = stream_interactor.get_stream(
                call.account);
            if (maybe_stream != null) {
                ((!) maybe_stream).get_module<Xep.CallInvites.Module>(
                    Xep.CallInvites.Module.IDENTITY).send_reject(
                        (!) maybe_stream, failed_target, failed_call_id,
                        failed_message_type);
            }
        }

        use_cim = previous_use_cim;
        cim_call_id = previous_call_id;
        cim_counterpart = previous_counterpart;
        cim_counterpart_message_type = previous_message_type;
        cim_targets.restore(previous_targets);
        invited_to_group_call = previous_invited_room;
        incoming_group_source_context = null;
        incoming_group_inviter_occupant = null;
        incoming_group_inviter_real_jid = null;

        // Preparation no longer changes the original call's camera mute.
        // Keep any camera choice made by the user while the join was pending.
        group_video_permanently_disabled = previous_group_video_disabled;
        video_effects_group_gate_active = previous_effect_gate;
        if (!previous_effect_gate) {
            PeerState? direct_peer = single_video_effect_peer();
            if (direct_peer != null) {
                cached_video_effect_status = ((!) direct_peer)
                    .get_google_webrtc_jmi_video_effect_status();
                video_effect_status_changed(cached_video_effect_status);
            }
        }
        warning("[%s] Rejected failed MUJI adoption while preserving the direct call: %s",
            call.account.bare_jid.to_string(), reason);
    }

    private bool is_live_generation(uint64 generation,
            XmppStream? expected_stream = null) {
        if (!lifecycle.is_current(generation) || teardown_started) return false;
        if (expected_stream != null &&
                stream_interactor.get_stream(call.account) != expected_stream) {
            return false;
        }
        return call.state == Call.State.RINGING ||
            call.state == Call.State.ESTABLISHING ||
            call.state == Call.State.IN_PROGRESS;
    }

    private bool is_current_incoming_group_source() {
        if (incoming_group_source_context == null) return true;
        MucManager.MucOwnerMutationContext context =
            (!) incoming_group_source_context;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        bool room_is_current =
            stream_interactor.get_stream(call.account) == context.stream &&
            muc_manager.is_current_muc_context(call.account, context) &&
            muc_manager.is_joined(context.room, call.account) &&
            muc_manager.has_live_private_room_features(call.account,
                context.room);
        if (!room_is_current) return false;

        Jid? actual_real_jid = incoming_group_inviter_occupant != null
            ? muc_manager.get_real_jid(
                (!) incoming_group_inviter_occupant, call.account)
            : null;
        bool occupant_is_current = incoming_group_inviter_occupant != null &&
            muc_manager.is_current_occupant(call.account, context.room,
                (!) incoming_group_inviter_occupant);
        return incoming_group_inviter_is_current(
            incoming_group_inviter_occupant,
            incoming_group_inviter_real_jid,
            actual_real_jid, occupant_is_current);
    }

    internal static bool incoming_group_inviter_is_current(
            Jid? expected_occupant, Jid? expected_real_jid,
            Jid? actual_real_jid, bool occupant_is_current) {
        if (expected_occupant == null && expected_real_jid == null) {
            return true;
        }
        return expected_occupant != null && expected_real_jid != null &&
            actual_real_jid != null && occupant_is_current &&
            ((!) actual_real_jid).equals((!) expected_real_jid);
    }

    private bool incoming_group_accept_may_continue(
            IncomingGroupAcceptTransaction? transaction) {
        return transaction == null ||
            ((!) transaction).may_continue(
                is_current_incoming_group_source());
    }

    private void fail_stale_incoming_group_accept(string reason) {
        if (teardown_started) return;
        fail_local(Xep.Jingle.ReasonElement.CONNECTIVITY_ERROR, reason);
    }

    private bool begin_teardown() {
        if (!terminal_teardown.try_claim()) return false;
        if (pending_muji_join_cancellable != null) {
            ((!) pending_muji_join_cancellable).cancel();
            pending_muji_join_cancellable = null;
        }
        if (active_incoming_group_accept != null) {
            ((!) active_incoming_group_accept).invalidate();
            active_incoming_group_accept = null;
        }
        lifecycle.close();
        teardown_started = true;
        can_invite_group_participants = false;
        group_call_converting = false;
        group_call_joining = false;
        if (private_group_conversion != null) {
            ((!) private_group_conversion).rollback();
        }
        // Persisted passive-proposal ownership must be removed before any
        // terminal Call state can reach the database. Otherwise a crash in
        // between could resurrect an already finished proposal on restart.
        terminal_state_will_persist();
        return true;
    }

    private void emit_terminated_once(Jid who_terminated,
            string? reason_name, string? reason_text) {
        if (termination_emitted) return;
        termination_emitted = true;
        terminated(who_terminated, reason_name, reason_text);
    }

    internal async bool initiate_groupchat_call(Jid muc,
            GroupCallRejoinValidity may_continue,
            GroupCallRejoinValidity may_start_new) {
        if (group_call != null || !peers.is_empty || !may_continue() || !may_start_new()) return false;
        use_cim = true;
        if (cim_call_id == null) cim_call_id = Xmpp.random_uuid();
        add_cim_target(muc, MessageStanza.TYPE_GROUPCHAT);
        bool joined = yield join_group_call(muc, false, null, false, may_continue,
            true, (preparing_group) => {
                if (groupchat_preparing_claimed || !may_continue() || !may_start_new() ||
                        !preparing_group.reuses_muc_occupancy ||
                        !preparing_group.muc_jid.equals(muc.bare_jid)) {
                    throw new IOError.CANCELLED("The group call changed before its preparing intent");
                }
                // This is the NEW intent's claim. Later participants may legitimately join it.
                groupchat_preparing_claimed = true;
            });
        if (!joined || group_call == null || !may_continue()) return false;
        XmppStream? stream = stream_interactor.get_stream(call.account);
        if (stream == null || !is_current_groupchat_invite_context((!) group_call,
                (!) stream, cim_call_id) || groupchat_proposal_claimed) return false;
        groupchat_proposal_claimed = true;
        Calls.trace_muji_control("invite-send call=%d invite=%s source=%s target=%s video=%s".printf(
            call.id, cim_call_id ?? "none", muc.to_string(), muc.to_string(),
            we_should_send_video.to_string()));
        stream.get_module<Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY)
            .send_muji_propose(stream, cim_call_id, muc, muc,
                we_should_send_video, MessageStanza.TYPE_GROUPCHAT);
        return true;
    }

    /** An explicit first JOIN uses the current room without inventing an invite reference. */
    internal async bool join_current_room_group_call(Jid muc,
            GroupCallRejoinValidity may_continue,
            GroupCallRejoinValidity has_current_peers) {
        if (group_call != null || !peers.is_empty || !may_continue() || !has_current_peers()) return false;
        accepted = true;
        call.state = Call.State.ESTABLISHING;
        return yield join_group_call(muc, false, null, true, may_continue, true,
            (preparing_group) => {
                if (!may_continue() || !has_current_peers()) {
                    throw new IOError.CANCELLED("The current group call is no longer available");
                }
            }, has_current_peers);
    }

    private bool is_current_groupchat_invite_context(
            Xep.Muji.GroupCall expected_group_call, XmppStream expected_stream,
            string? expected_call_id) {
        return (call.state == Call.State.RINGING || call.state == Call.State.ESTABLISHING ||
                call.state == Call.State.IN_PROGRESS) &&
            this.group_call == expected_group_call &&
            stream_interactor.get_stream(call.account) == expected_stream &&
            cim_call_id == expected_call_id;
    }

    internal PeerState set_first_peer(Jid peer) {
        var peer_state = new PeerState(peer, call, this, stream_interactor);
        peer_state.first_peer = true;
        peer_state.we_should_send_video = this.we_should_send_video;
        peer_state.we_should_send_audio = this.we_should_send_audio;
        add_peer(peer_state);
        return peer_state;
    }

    internal void add_peer(PeerState peer) {
        call.add_peer(peer.jid.bare_jid);
        connect_peer_signals(peer);
        peer_joined(peer.jid, peer);
    }

    public bool uses_google_webrtc_jmi_call_engine() {
        return media_backend == CallMediaBackend.GOOGLE_WEBRTC;
    }

    public Plugins.JmiCallEnginePlugin? get_selected_jmi_call_engine() {
        return selected_jmi_call_engine;
    }

    public Plugins.MujiCallEnginePlugin? get_selected_muji_call_engine() {
        return selected_muji_call_engine;
    }

    internal void set_archive_recovery_pending(bool pending) {
        if (archive_recovery_pending == pending) return;
        archive_recovery_pending = pending;
        accept_capability_changed();
    }

    /**
     * Check the immutable media backend selected for this call.  In
     * particular, a recovered JMI proposal must never become actionable just
     * because the unrelated legacy RTP plugin happens to be available.
     */
    public bool can_accept_selected_media_backend(bool video_requested,
            bool multiparty) {
        if (archive_recovery_pending) return false;
        if (media_backend == CallMediaBackend.LEGACY_RTP) {
            return call_plugin != null && ((!) call_plugin).supported();
        }

        Plugins.JmiCallEnginePlugin? jmi_engine = selected_jmi_call_engine;
        if (jmi_engine == null || !((!) jmi_engine).runtime_enabled()) {
            return false;
        }
        if (video_requested) {
            if (!((!) jmi_engine).can_start_video(call.account)) return false;
        } else if (!((!) jmi_engine).can_start_audio_only(call.account)) {
            return false;
        }
        if (!multiparty) return true;

        Plugins.MujiCallEnginePlugin? muji_engine = selected_muji_call_engine;
        if (muji_engine == null || !((!) muji_engine).runtime_enabled() ||
                ((!) muji_engine).group_engine_id !=
                    ((!) jmi_engine).engine_id) {
            return false;
        }
        return video_requested
            ? ((!) muji_engine).can_start_group_video(call.account)
            : ((!) muji_engine).can_start_group_audio(call.account);
    }

    public bool can_use_selected_muji_engine(bool video_requested) {
        if (media_backend != CallMediaBackend.GOOGLE_WEBRTC ||
                selected_muji_call_engine == null ||
                !((!) selected_muji_call_engine).runtime_enabled()) {
            return false;
        }
        return video_requested
            ? ((!) selected_muji_call_engine).can_start_group_video(call.account)
            : ((!) selected_muji_call_engine).can_start_group_audio(call.account);
    }

    internal Plugins.MujiCallEngineGroupSession? get_muji_engine_group_session() {
        return muji_engine_group_session;
    }

    public Plugins.JmiVideoEffectCapabilities get_video_effect_capabilities() {
        if (group_call != null) {
            Plugins.MujiCallEngineGroupSession? engine = current_group_video_effect_owner();
            if (engine == null) return Plugins.JmiVideoEffectCapabilities.unavailable(
                Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED);
            if (!has_video_media()) return Plugins.JmiVideoEffectCapabilities.unavailable(
                Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY);
            return engine.get_video_effect_capabilities();
        }
        if (video_effects_group_gate_active || peers.size != 1) {
            return Plugins.JmiVideoEffectCapabilities.unavailable(
                video_effects_group_gate_active
                    ? Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL
                    : Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
        }
        foreach (PeerState peer_state in peers.values) {
            return peer_state.get_google_webrtc_jmi_video_effect_capabilities();
        }
        return Plugins.JmiVideoEffectCapabilities.unavailable(
            Plugins.JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
    }

    public Plugins.JmiVideoEffectStatus get_video_effect_status() {
        if (group_call != null) {
            Plugins.MujiCallEngineGroupSession? engine = current_group_video_effect_owner();
            if (engine == null) return unavailable_video_effect_status(Plugins.JmiVideoEffectUnavailableReason.CALL_ENDED);
            if (!has_video_media()) return unavailable_video_effect_status(Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY);
            return cached_video_effect_status;
        }
        if (video_effects_group_gate_active) {
            return unavailable_video_effect_status(Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        }
        return cached_video_effect_status;
    }

    /** Event-driven barrier: accept concealment before an image import/stage starts. */
    public async void wait_for_video_background_concealment(Cancellable cancellable) throws Error {
        while (true) {
            if (cancellable.is_cancelled()) throw new IOError.CANCELLED("Background image loading was cancelled");
            Plugins.JmiVideoEffectStatus state = get_video_effect_status();
            if (state.accepted_revision > 0 && state.selection.background_mode != Plugins.JmiVideoBackgroundMode.NONE)
                return;
            if (state.state == Plugins.JmiVideoEffectApplyState.UNAVAILABLE ||
                    state.state == Plugins.JmiVideoEffectApplyState.FAILED)
                throw new IOError.NOT_SUPPORTED("Background concealment was not accepted by this call");
            SourceFunc continuation = wait_for_video_background_concealment.callback;
            MainContext context = MainContext.ref_thread_default();
            Mutex completion_mutex = Mutex();
            bool scheduled = false;
            bool ended = false;
            SourceFunc wake = () => {
                completion_mutex.lock();
                bool attach = !scheduled; scheduled = true;
                completion_mutex.unlock();
                if (attach) {
                    var source = new IdleSource();
                    source.set_callback((owned) continuation); source.attach(context);
                }
                return false;
            };
            ulong state_handler = video_effect_status_changed.connect((value) => { wake(); });
            ulong ended_handler = terminated.connect((peer, reason, text) => { ended = true; wake(); });
            ulong cancelled_handler = cancellable.cancelled.connect(() => { wake(); });
            // Catch an acceptance/cancellation which preceded signal installation.
            state = get_video_effect_status();
            if ((state.accepted_revision > 0 && state.selection.background_mode != Plugins.JmiVideoBackgroundMode.NONE) ||
                    state.state == Plugins.JmiVideoEffectApplyState.UNAVAILABLE ||
                    state.state == Plugins.JmiVideoEffectApplyState.FAILED || cancellable.is_cancelled()) wake();
            yield;
            disconnect(state_handler); disconnect(ended_handler); cancellable.disconnect(cancelled_handler);
            if (ended) throw new IOError.CANCELLED("The video call has ended");
        }
    }

    public async void release_video_background(uint asset_id) throws Error {
        if (group_call != null) {
            Plugins.MujiCallEngineGroupSession? engine = current_group_video_effect_owner();
            if (engine != null) yield ((!) engine).release_video_background(asset_id);
        } else {
            PeerState? peer = single_video_effect_peer();
            if (peer != null) yield ((!) peer).release_google_webrtc_jmi_video_background(asset_id);
        }
    }

    public async uint stage_video_background(uint builtin_choice,
            Plugins.JmiVideoBackgroundImage? image = null) throws Error {
        if (!has_video_media()) throw new IOError.NOT_SUPPORTED("A video call is required");
        if (group_call != null) {
            Plugins.MujiCallEngineGroupSession? engine = current_group_video_effect_owner();
            if (engine == null) throw new IOError.CANCELLED("The group call has ended");
            uint asset = yield ((!) engine).stage_video_background(builtin_choice, image);
            if (current_group_video_effect_owner() != engine) {
                try { yield ((!) engine).release_video_background(asset); } catch (Error ignored) { }
                throw new IOError.CANCELLED("The group call owner changed");
            }
            return asset;
        }
        PeerState? peer = single_video_effect_peer();
        if (video_effects_group_gate_active || peer == null)
            throw new IOError.NOT_SUPPORTED("No direct video call is available");
        uint asset = yield ((!) peer).stage_google_webrtc_jmi_video_background(builtin_choice, image);
        if (video_effects_group_gate_active || single_video_effect_peer() != peer) {
            try { yield ((!) peer).release_google_webrtc_jmi_video_background(asset); } catch (Error ignored) { }
            throw new IOError.CANCELLED("The direct call owner changed");
        }
        return asset;
    }

    /** Latest-wins UI entry point: one request in flight and one replaceable pending choice. */
    public void request_video_effect(Plugins.JmiVideoEffectSelection selection) {
        Plugins.JmiVideoEffectCapabilities capabilities = get_video_effect_capabilities();
        if (!capabilities.supports_selection(selection)) {
            // Rejected controls never change the active pipeline. Keep the
            // last real backend state instead of falsely reporting effects off.
            debug("Ignoring an invalid or unsupported video-effect selection");
            return;
        }
        if (group_call != null) {
            group_video_effect_requests.enqueue(selection);
            if (!group_video_effect_requests.in_flight) process_pending_group_video_effects.begin();
            return;
        }
        video_effect_requests.enqueue(selection);
        if (!video_effect_requests.in_flight) process_pending_video_effects.begin();
    }

    private async void process_pending_video_effects() {
        uint64 generation = video_effect_requests.begin_processing();
        if (generation == 0) return;
        while (true) {
            Plugins.JmiVideoEffectSelection? pending =
                video_effect_requests.take(generation);
            if (pending == null) break;
            Plugins.JmiVideoEffectSelection selection = (!) pending;
            PeerState? peer_state = single_video_effect_peer();
            if (peer_state == null || video_effects_group_gate_active) break;
            try {
                yield ((!) peer_state).select_google_webrtc_jmi_video_effect(selection);
            } catch (IOError.CANCELLED e) {
                break;
            } catch (Error e) {
                if (!video_effect_requests.is_current(generation)) break;
                cached_video_effect_status = new Plugins.JmiVideoEffectStatus(
                    selection,
                    Plugins.JmiVideoEffectApplyState.FAILED,
                    0,
                    0,
                    Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE);
                video_effect_status_changed(cached_video_effect_status);
            }
        }
        bool restart = video_effect_requests.finish(generation);
        if (restart && !video_effects_group_gate_active && single_video_effect_peer() != null) {
            process_pending_video_effects.begin();
        }
    }

    private PeerState? single_video_effect_peer() {
        if (peers.size != 1) return null;
        foreach (PeerState peer_state in peers.values) {
            if (peer_state.uses_google_webrtc_jmi_call_engine_session()) return peer_state;
        }
        return null;
    }

    private Plugins.MujiCallEngineGroupSession? current_group_video_effect_owner() {
        if (group_call == null || group_call.left || muji_engine_group_session == null || active_muji_stream == null) return null;
        return is_current_group_call_context(group_call, muji_engine_group_session,
            lifecycle.capture(), active_muji_stream) ? muji_engine_group_session : null;
    }

    private async void process_pending_group_video_effects() {
        VideoEffectLatestWinsQueue requests = group_video_effect_requests;
        uint64 generation = requests.begin_processing();
        if (generation == 0) return;
        Plugins.MujiCallEngineGroupSession? engine = current_group_video_effect_owner();
        Xep.Muji.GroupCall? room = group_call;
        XmppStream? stream = active_muji_stream;
        uint64 call_generation = lifecycle.capture();
        while (engine != null && room != null && stream != null && has_video_media() &&
                is_current_group_call_context(room, engine, call_generation, stream)) {
            Plugins.JmiVideoEffectSelection? selection = requests.take(generation);
            if (selection == null) break;
            try {
                yield engine.select_video_effect(selection);
            } catch (IOError.CANCELLED e) {
                break;
            } catch (Error e) {
                if (!requests.is_current(generation) ||
                        !is_current_group_call_context(room, engine, call_generation, stream)) break;
                cached_video_effect_status = new Plugins.JmiVideoEffectStatus(selection,
                    Plugins.JmiVideoEffectApplyState.FAILED, 0, 0,
                    Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE);
                video_effect_status_changed(cached_video_effect_status);
            }
            if (!requests.is_current(generation)) break;
        }
        bool restart = requests.finish(generation);
        if (restart && group_video_effect_requests == requests && has_video_media() &&
                current_group_video_effect_owner() != null) {
            process_pending_group_video_effects.begin();
        }
    }

    private void on_video_effect_call_shape_changed() {
        video_effect_requests.invalidate();
        Plugins.MujiCallEngineGroupSession? current_owner = current_group_video_effect_owner();
        bool owner_changed = group_video_effect_queue_room != group_call ||
            group_video_effect_queue_owner != current_owner;
        if (owner_changed) {
            group_video_effect_requests.invalidate();
            group_video_effect_requests = new VideoEffectLatestWinsQueue();
            group_video_effect_queue_room = group_call;
            group_video_effect_queue_owner = current_owner;
        }
        if (group_call != null) {
            video_effects_group_gate_active = true;
            // This is a backend gate, not just a disabled UI control. It is
            // synchronous at the Vala boundary: new/direct requests fail from
            // this point on, queued choices are cancelled, and pipeline
            // destruction/detach is prioritized on each control worker.
            foreach (PeerState peer_state in peers.values) {
                peer_state.disable_google_webrtc_jmi_video_effects_for_group_call();
            }
            if (owner_changed) {
                cached_video_effect_status = current_owner != null ? current_owner.get_video_effect_status() :
                    unavailable_video_effect_status(Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
            }
            video_effect_status_changed(cached_video_effect_status);
        }
    }

    /**
     * Establishes the hard backend boundary before joining the MUJI room.
     * New PeerState sessions observe the gate synchronously and are born with
     * effects disabled; existing sessions are awaited through their native
     * pipeline-destroy ordering barrier without blocking the main context.
     */
    private async void fence_video_effects_before_group_call() {
        video_effects_group_gate_active = true;
        video_effect_requests.invalidate();
        cached_video_effect_status = unavailable_video_effect_status(
            Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        video_effect_status_changed(cached_video_effect_status);

        var peers_to_fence = new ArrayList<PeerState>();
        peers_to_fence.add_all(peers.values);
        foreach (PeerState peer_state in peers_to_fence) {
            yield peer_state.fence_google_webrtc_jmi_video_effects_for_group_call();
        }
    }

    private static Plugins.JmiVideoEffectStatus unavailable_video_effect_status(
            Plugins.JmiVideoEffectUnavailableReason reason) {
        return new Plugins.JmiVideoEffectStatus(
            new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF),
            Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
            0,
            0,
            reason);
    }

    internal void on_peer_stream_created(PeerState peer, string media) {
        if (uses_google_webrtc_jmi_call_engine()) return;
        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null) {
            warning("[%s] Ignoring legacy RTP stream without a VideoCallPlugin",
                call.account.bare_jid.to_string());
            return;
        }

        if (media == "audio") {
            var mic = get_microphone_device();
            var spk = get_speaker_device();
            debug("on_peer_stream_created audio: mic=%s spk=%s stream=%s",
                  mic != null ? mic.display_name : "NULL",
                  spk != null ? spk.display_name : "NULL",
                  peer.get_audio_stream() != null ? "ok" : "NULL");
            if (mic != null) ((!) legacy_call_plugin).set_device(peer.get_audio_stream(), mic);
            if (spk != null) ((!) legacy_call_plugin).set_device(peer.get_audio_stream(), spk);
        } else if (media == "video") {
            ((!) legacy_call_plugin).set_device(peer.get_video_stream(), get_video_device());
        }
    }

    public void accept() {
        if (teardown_started || accepted || archive_recovery_pending) return;
        accepted = true;
        call.state = Call.State.ESTABLISHING;
        cancel_all_timeouts();

        if (use_cim) {
            if (invited_to_group_call != null) {
                uint64 operation_generation = lifecycle.capture();
                var accept_transaction =
                    new IncomingGroupAcceptTransaction(lifecycle);
                active_incoming_group_accept = accept_transaction;
                finish_incoming_group_accept.begin((!) invited_to_group_call,
                    operation_generation, accept_transaction);
                return;
            } else if (peers.size == 1) {
                XmppStream? stream = stream_interactor.get_stream(call.account);
                if (stream == null) {
                    fail_local(
                        Xep.Jingle.ReasonElement.CONNECTIVITY_ERROR,
                        "Connection lost before accepting the call");
                    return;
                }
                string? sid = null;
                foreach (PeerState peer_state in peers.values) {
                    sid = peer_state.sid;
                    break;
                }
                if (sid == null) {
                    fail_local(
                        Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                        "Call invite has no media session");
                    return;
                }
                foreach (CimTarget target in cim_targets.snapshot()) {
                    string? target_call_id =
                        cim_reference_for_target(target);
                    if (target_call_id == null) continue;
                    ((!) stream).get_module<Xep.CallInvites.Module>(
                        Xep.CallInvites.Module.IDENTITY).send_jingle_accept(
                            (!) stream, target.jid, (!) target_call_id, sid,
                            target.message_type);
                }
                cim_accept_publication.mark_published();
            }
        } else {
            var peers_cpy = new ArrayList<PeerState>();
            peers_cpy.add_all(peers.values);
            foreach (PeerState peer in peers_cpy) {
                peer.accept();
            }
        }
    }

    private async void finish_incoming_group_accept(Jid room_jid,
            uint64 operation_generation,
            IncomingGroupAcceptTransaction accept_transaction) {
        if (!incoming_group_accept_may_continue(accept_transaction)) {
            fail_stale_incoming_group_accept(
                "The source room changed before accepting the group call");
            return;
        }
        bool joined = yield join_group_call(room_jid, false,
            accept_transaction);
        if (!is_live_generation(operation_generation) || teardown_started) {
            return;
        }
        XmppStream? stream = stream_interactor.get_stream(call.account);
        if (!joined || group_call == null || stream == null) {
            fail_local(
                Xep.Jingle.ReasonElement.FAILED_APPLICATION,
                "Could not join the group call");
            return;
        }
        if (!accept_transaction.try_claim_accept(
                is_current_incoming_group_source())) {
            fail_stale_incoming_group_accept(
                "The source room changed while accepting the group call");
            return;
        }
        foreach (CimTarget target in cim_targets.snapshot()) {
            string? target_call_id = cim_reference_for_target(target);
            if (target_call_id == null) continue;
            ((!) stream).get_module<Xep.CallInvites.Module>(
                Xep.CallInvites.Module.IDENTITY).send_muji_accept(
                    (!) stream, target.jid, (!) target_call_id, room_jid,
                    target.message_type);
        }
        cim_accept_publication.mark_published();
        if (active_incoming_group_accept == accept_transaction) {
            active_incoming_group_accept = null;
        }
    }

    public void reject() {
        if (use_cim) {
            XmppStream? stream = stream_interactor.get_stream(call.account);
            if (stream != null) {
                foreach (CimTarget target in cim_targets.snapshot()) {
                    string? target_call_id =
                        cim_reference_for_target(target);
                    if (target_call_id == null) continue;
                    ((!) stream).get_module<Xep.CallInvites.Module>(
                        Xep.CallInvites.Module.IDENTITY).send_reject(
                            (!) stream, target.jid, (!) target_call_id,
                            target.message_type);
                }
            }
        }
        finish_terminal_state(Call.State.DECLINED, call.account.bare_jid,
            Xep.Jingle.ReasonElement.DECLINE, null,
            TerminalPeerAction.REJECT);
    }

    internal void finish_on_other_device(Jid own_resource) {
        call.ourpart = own_resource;
        finish_terminal_state(Call.State.OTHER_DEVICE, own_resource, null,
            "Call handled on another device", TerminalPeerAction.DISCARD);
    }

    internal void finish_remote_retract(Jid proposer) {
        finish_terminal_state(Call.State.MISSED, proposer,
            Xep.Jingle.ReasonElement.CANCEL, "Call invite retracted",
            TerminalPeerAction.DISCARD);
    }

    internal void finish_remote_reject(Jid rejector) {
        finish_terminal_state(Call.State.DECLINED, rejector,
            Xep.Jingle.ReasonElement.DECLINE, "Call rejected",
            TerminalPeerAction.DISCARD);
    }

    internal void finish_jmi_tie_break_superseded(Jid peer) {
        finish_terminal_state(Call.State.ENDED, peer,
            Xep.Jingle.ReasonElement.EXPIRED,
            "Superseded by a simultaneous call",
            TerminalPeerAction.DISCARD);
    }

    internal void finish_remote_left(Jid leaver) {
        finish_terminal_state(Call.State.ENDED, leaver,
            Xep.Jingle.ReasonElement.SUCCESS, "Call left",
            TerminalPeerAction.DISCARD);
    }

    internal void finish_remote_jmi(Jid leaver, string? reason_name,
            string? reason_text) {
        Call.State final_state;
        if (call.state == Call.State.ESTABLISHING ||
                call.state == Call.State.IN_PROGRESS) {
            final_state = Call.State.ENDED;
        } else if (call.state == Call.State.RINGING) {
            final_state = Call.State.MISSED;
        } else {
            return;
        }
        finish_terminal_state(final_state, leaver,
            reason_name ?? Xep.Jingle.ReasonElement.SUCCESS, reason_text,
            TerminalPeerAction.DISCARD);
    }

    /** Apply an authoritative passive replay without sending wire actions. */
    internal void finish_replayed_jmi(Call.State final_state, Jid leaver,
            DateTime ended_at, string? reason_name, string? reason_text) {
        if (final_state != Call.State.ENDED &&
                final_state != Call.State.DECLINED &&
                final_state != Call.State.MISSED) return;
        finish_terminal_state(final_state, leaver,
            reason_name ?? Xep.Jingle.ReasonElement.SUCCESS, reason_text,
            TerminalPeerAction.DISCARD, ended_at);
    }

    /**
     * Applies a direct-chat CIM left to one MUJI participant only.  A left may
     * arrive before media presence, in which case removing the pending target
     * is the complete state transition and the rest of the group remains live.
     */
    internal bool finish_remote_group_participant_left(Jid leaver,
            string message_type, string call_id) {
        if (message_type != Xmpp.MessageStanza.TYPE_CHAT) return false;
        bool target_removed = remove_cim_action_target(leaver,
            message_type, call_id);
        if (!target_removed) return false;

        PeerState? matching_peer = null;
        foreach (PeerState peer in peers.values) {
            if (leaver.is_bare()
                    ? peer.jid.equals_bare(leaver)
                    : peer.jid.equals(leaver)) {
                matching_peer = peer;
                break;
            }
        }
        if (matching_peer == null) return target_removed;
        handle_peer_left((!) matching_peer, false,
            Xep.Jingle.ReasonElement.SUCCESS, "Participant left the call");
        return true;
    }

    internal void fail_local(string reason_name, string? reason_text) {
        reject_pending_cim_accept_if_owned();
        finish_terminal_state(Call.State.FAILED, call.account.bare_jid,
            reason_name, reason_text, TerminalPeerAction.CANCEL);
    }

    private void finish_terminal_state(Call.State final_state,
            Jid who_terminated, string? reason_name, string? reason_text,
            TerminalPeerAction peer_action, DateTime? ended_at = null) {
        if (!begin_teardown()) return;
        cancel_all_timeouts();
        video_effect_requests.invalidate();

        Xep.Muji.GroupCall? active_group_call = group_call;
        disconnect_group_call_signals();
        group_call = null;

        // XEP-0272 leaves a conference by withdrawing the MUJI presence
        // before terminating the pairwise Jingle sessions. For a borrowed
        // chat-room occupancy this updates presence without leaving the MUC.
        XmppStream? stream = stream_interactor.get_stream(call.account);
        if (active_group_call != null) {
            leave_published_muji_room((!) active_group_call, stream);
        }

        var peers_to_finish = new ArrayList<PeerState>();
        peers_to_finish.add_all(peers.values);
        foreach (PeerState peer in peers_to_finish) {
            switch (peer_action) {
                case TerminalPeerAction.REJECT:
                    peer.reject();
                    break;
                case TerminalPeerAction.CANCEL:
                    peer.end(Xep.Jingle.ReasonElement.CANCEL, reason_text);
                    break;
                default:
                    peer.cleanup_signal_handlers();
                    if (!peer.discard_google_webrtc_jmi_call_engine_session()) {
                        peer.release_objects();
                    }
                    break;
            }
        }
        close_muji_engine_group_session();
        clear_peer_ownership();
        cim_targets.clear();

        if (active_group_call != null) {
            close_muji_conversation((!) active_group_call);
        }

        call.end_time = ended_at ?? new DateTime.now_utc();
        // CallWidget reacts to state changes and reads end_time immediately.
        // Publish the timestamp first so it never renders a stale duration.
        call.state = final_state;
        if (media_backend == CallMediaBackend.LEGACY_RTP) {
            dispose_legacy_rtp_pipeline_later();
        }
        emit_terminated_once(who_terminated, reason_name, reason_text);
    }

    private void close_muji_conversation(Xep.Muji.GroupCall active_group_call) {
        if (active_group_call.reuses_muc_occupancy) return;
        Conversation? conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY).get_conversation(
                active_group_call.muc_jid, call.account,
                Conversation.Type.GROUPCHAT);
        if (conversation != null) {
            stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY).close_conversation(
                    (!) conversation);
        }
    }

    /** Published MUJI rooms are decentralized and are never destroyed here. */
    private void leave_published_muji_room(
            Xep.Muji.GroupCall active_group_call,
            XmppStream? current_stream) {
        MujiPublishedRoomLifecycle? room_lifecycle =
            active_muji_room_lifecycle;
        active_muji_room_lifecycle = null;
        XmppStream? owner_stream = active_muji_stream;
        active_muji_stream = null;

        MujiPublishedRoomExitAction action = room_lifecycle != null
            ? ((!) room_lifecycle).claim_terminal_exit()
            : MujiPublishedRoomExitAction.LEAVE;
        if (action != MujiPublishedRoomExitAction.LEAVE ||
                owner_stream == null) return;

        // The publishing stream owns Flag.calls even after it disconnects.
        // Only send wire actions while that exact stream is still current;
        // local ownership must be released in either case.
        active_group_call.leave((!) owner_stream,
            current_stream == owner_stream);
    }

    private void send_cim_terminal_action(
            CimTerminalSignalAction action) {
        if (!use_cim || action == CimTerminalSignalAction.NONE) return;
        XmppStream? maybe_stream = stream_interactor.get_stream(call.account);
        if (maybe_stream == null) return;
        XmppStream stream = (!) maybe_stream;
        foreach (CimTarget target in cim_targets.snapshot()) {
            string? target_call_id = cim_reference_for_target(target);
            if (target_call_id == null) {
                if (call.direction == Call.DIRECTION_OUTGOING &&
                        target.message_type ==
                            Xmpp.MessageStanza.TYPE_GROUPCHAT &&
                        cim_call_id != null) {
                    cim_groupchat_terminal_deferred(target.jid,
                        (!) cim_call_id, action);
                }
                continue;
            }
            switch (action) {
                case CimTerminalSignalAction.REJECT:
                    stream.get_module<Xep.CallInvites.Module>(
                        Xep.CallInvites.Module.IDENTITY).send_reject(stream,
                            target.jid, (!) target_call_id,
                            target.message_type);
                    break;
                case CimTerminalSignalAction.RETRACT:
                    stream.get_module<Xep.CallInvites.Module>(
                        Xep.CallInvites.Module.IDENTITY).send_retract(stream,
                            target.jid, (!) target_call_id,
                            target.message_type);
                    break;
                case CimTerminalSignalAction.LEFT:
                    stream.get_module<Xep.CallInvites.Module>(
                        Xep.CallInvites.Module.IDENTITY).send_left(stream,
                            target.jid, (!) target_call_id,
                            target.message_type);
                    break;
                default:
                    break;
            }
        }
    }

    private void reject_pending_cim_accept_if_owned() {
        if (!use_cim || call.direction != Call.DIRECTION_INCOMING ||
                cim_accept_publication.published) return;
        CimTerminalSignalAction action =
            cim_accept_publication.claim_terminal_action(call.direction,
                call.state);
        if (action == CimTerminalSignalAction.REJECT) {
            send_cim_terminal_action(action);
        }
    }

    public void end(string? reason_text = null) {
        Call.State final_state;
        if (call.state == Call.State.IN_PROGRESS ||
                call.state == Call.State.ESTABLISHING) {
            final_state = Call.State.ENDED;
        } else if (call.state == Call.State.RINGING) {
            final_state = Call.State.MISSED;
        } else {
            return;
        }
        if (!begin_teardown()) return;
        // Cancel all pending timeouts
        cancel_all_timeouts();
        video_effect_requests.invalidate();

        bool used_google_webrtc_jmi_call_engine = uses_google_webrtc_jmi_call_engine();
        var peers_cpy = new ArrayList<PeerState>();
        peers_cpy.add_all(peers.values);

        // Capture group_call ref before nulling — prevents double-leave
        // from handle_peer_left() which is triggered by peer.end() below.
        Xep.Muji.GroupCall? gc = this.group_call;
        disconnect_group_call_signals();
        this.group_call = null;

        XmppStream? stream = stream_interactor.get_stream(call.account);

        // XEP-0272 withdraws the MUJI presence before any pairwise Jingle
        // session is terminated. A shared private-MUC occupancy stays joined.
        if (gc != null) leave_published_muji_room((!) gc, stream);

        // Local session ownership must be released even after the XMPP stream
        // disappeared. Only protocol messages and room IQs depend on a stream.
        if (call.state == Call.State.IN_PROGRESS ||
                call.state == Call.State.ESTABLISHING) {
            foreach (PeerState peer in peers_cpy) {
                peer.end(Xep.Jingle.ReasonElement.SUCCESS, reason_text);
            }
        } else if (call.state == Call.State.RINGING) {
            foreach (PeerState peer in peers_cpy) {
                peer.end(Xep.Jingle.ReasonElement.CANCEL, reason_text);
            }
        }

        // Call.State.ESTABLISHING begins at the UI click, before an incoming
        // MUJI accept is actually on wire. Signal terminal ownership from
        // the explicit publication boundary, not from that optimistic state.
        send_cim_terminal_action(
            cim_accept_publication.claim_terminal_action(call.direction,
                call.state));

        // Peer sessions were ended above. Now release the immutable group
        // owner and its router expectations before dropping PeerState refs.
        close_muji_engine_group_session();

        clear_peer_ownership();
        cim_targets.clear();

        // Published MUJI calls are decentralized.  Even their local creator
        // only leaves; destroying the room would terminate other participants.
        if (gc != null) close_muji_conversation((!) gc);

        call.state = final_state;
        call.end_time = new DateTime.now_utc();

        // Safety net: force-destroy the GStreamer pipeline in case any
        // zombie streams survived (e.g. from async call_resource() that
        // completed after end() ran).  Scheduled as idle so that any
        // pending close_stream() calls from session.terminate() above
        // finish first.
        if (!used_google_webrtc_jmi_call_engine) {
            dispose_legacy_rtp_pipeline_later();
        }

        emit_terminated_once(call.account.bare_jid, null, reason_text);
    }

    private void clear_peer_ownership() {
        foreach (var entry in peer_bindings.entries) {
            foreach (Binding binding in entry.value) binding.unbind();
        }
        peer_bindings.clear();

        foreach (var entry in peer_stream_created_handler_ids.entries) {
            PeerState? peer = peers[entry.key];
            if (peer != null && entry.value != 0 &&
                    SignalHandler.is_connected((!) peer, entry.value)) {
                ((!) peer).disconnect(entry.value);
            }
        }
        foreach (var entry in peer_session_terminated_handler_ids.entries) {
            PeerState? peer = peers[entry.key];
            if (peer != null && entry.value != 0 &&
                    SignalHandler.is_connected((!) peer, entry.value)) {
                ((!) peer).disconnect(entry.value);
            }
        }
        foreach (var entry in peer_video_effect_handler_ids.entries) {
            PeerState? peer = peers[entry.key];
            if (peer != null && entry.value != 0 &&
                    SignalHandler.is_connected((!) peer, entry.value)) {
                ((!) peer).disconnect(entry.value);
            }
        }
        peer_stream_created_handler_ids.clear();
        peer_session_terminated_handler_ids.clear();
        peer_video_effect_handler_ids.clear();

        var peer_snapshot = new ArrayList<PeerState>();
        peer_snapshot.add_all(peers.values);
        foreach (PeerState peer in peer_snapshot) {
            peer.cleanup_signal_handlers();
            peer.release_objects();
        }
        peers.clear();
        selected_microphone_device = null;
        selected_speaker_device = null;
        selected_video_device = null;
    }

    public void mute_own_audio(bool mute) {
        we_should_send_audio = !mute;
        foreach (PeerState peer in peers.values) {
            peer.we_should_send_audio = !mute;
            peer.mute_own_audio(mute);
        }
    }

    public void mute_own_video(bool mute) {
        if (!mute && group_video_permanently_disabled) return;
        we_should_send_video = !mute;
        foreach (PeerState peer in peers.values) {
            peer.we_should_send_video = !mute;
            peer.mute_own_video(mute);
        }
    }

    public bool should_we_send_video() {
        return we_should_send_video;
    }

    /** Video content remains negotiated when only the local camera is muted. */
    public bool has_video_media() {
        if (group_call != null) return group_call.video_available && !group_video_permanently_disabled;
        bool audio;
        bool video;
        return try_get_direct_offer_media(out audio, out video) && video;
    }

    public bool is_group_video_permanently_disabled() {
        return group_video_permanently_disabled;
    }

    private async ParticipantInviteAvailability get_invitee_muji_capability(Jid invitee) {
        var presence = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        Gee.List<Jid>? online = presence.get_full_jids(invitee, call.account);
        // Offline/undiscovered devices may receive a normal pending invitation.
        if (online == null || online.is_empty) return ParticipantInviteAvailability.AVAILABLE;
        var checked_resources = new ArrayList<Jid>(Jid.equals_func);
        checked_resources.add_all(online);
        var entity_info = stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY);
        XmppStream? stream = stream_interactor.get_stream(call.account);
        uint64 generation = lifecycle.capture();
        Xmpp.Presence.Flag? flag = stream != null ? stream.get_flag(Xmpp.Presence.Flag.IDENTITY) : null;
        var unsupported = new HashMap<Jid, Xmpp.Presence.Stanza>(Jid.hash_func, Jid.equals_func);
        foreach (Jid resource in checked_resources) {
            Xmpp.Presence.Stanza? observed = flag != null ? flag.get_presence(resource) : null;
            bool? support = yield entity_info.get_feature_support(call.account, resource, Xep.Muji.NS_URI);
            if (!is_live_generation(generation, stream)) return ParticipantInviteAvailability.ENDED;
            if (!presence.has_presence(resource, call.account)) continue;
            if (support == true) return ParticipantInviteAvailability.AVAILABLE;
            if (support == false && observed != null && flag.get_presence(resource) == observed) {
                unsupported[resource] = observed;
            }
        }
        online = presence.get_full_jids(invitee, call.account);
        if (online == null || online.is_empty) return ParticipantInviteAvailability.AVAILABLE;
        foreach (Jid resource in online) {
            // Decide only over devices that remain online after discovery.
            // A newly appeared or undiscovered device is not a known negative.
            if (!unsupported.has_key(resource) || flag == null ||
                    flag.get_presence(resource) != unsupported[resource]) return ParticipantInviteAvailability.AVAILABLE;
        }
        return ParticipantInviteAvailability.CONTACT_UNSUPPORTED;
    }

    public async ParticipantInviteAvailability invite_to_call(Jid invitee) {
        Jid bare_invitee = invitee.bare_jid;
        // The local room owner is already authorized; never downgrade or retract it.
        if (bare_invitee.equals(call.account.bare_jid)) return ParticipantInviteAvailability.AVAILABLE;

        // Check the added contact before moving the working 1:1 call into a room.
        // Only successful discovery of all current devices can reject support.
        ParticipantInviteAvailability capability = yield get_invitee_muji_capability(bare_invitee);
        if (capability != ParticipantInviteAvailability.AVAILABLE) return capability;

        if (group_call_converting) {
            pending_muji_invites.add(bare_invitee);
            return ParticipantInviteAvailability.CONVERTING;
        }
        ParticipantInviteAvailability availability = yield get_participant_invite_availability();
        if (availability != ParticipantInviteAvailability.AVAILABLE) {
            debug("[%s] Participant invitation is no longer available", call.account.bare_jid.to_string());
            return availability;
        }
        if (group_call != null && !can_invite_group_participants) {
            debug("[%s] Refusing MUJI invite without local creator ownership",
                call.account.bare_jid.to_string());
            return ParticipantInviteAvailability.NO_INVITE_PERMISSION;
        }

        // Don't invite if call is already at capacity
        if (!is_live_call_for_muji_invite() || peers.size >= MAX_MUJI_PEERS) {
            debug("[%s] Not inviting %s — call already at max peers (%d/%d)", call.account.bare_jid.to_string(), invitee.to_string(), peers.size, MAX_MUJI_PEERS);
            return peers.size >= MAX_MUJI_PEERS ? ParticipantInviteAvailability.CALL_FULL : ParticipantInviteAvailability.ENDED;
        }

        // A re-invite must supersede its old timeout and cleanup generation
        // before the first await. If no MUJI room exists yet and there is no
        // older attempt, conversion may run first; a concurrent invite that
        // appears while conversion is pending wins instead of being replaced.
        MujiInviteAttempt? attempt = null;
        if (this.group_call != null || invite_attempts.has_current(bare_invitee)) {
            attempt = invite_attempts.begin(bare_invitee);
        }

        if (this.group_call == null) {
            if (!(yield convert_into_group_call())) {
                pending_muji_invites.clear();
                if (attempt != null) invite_attempts.release((!) attempt);
                return ParticipantInviteAvailability.NOT_CONNECTED;
            }
            foreach (Jid pending_invitee in
                    pending_muji_invites.drain(bare_invitee)) {
                invite_to_call.begin(pending_invitee);
            }
        }
        if (attempt != null && !invite_attempts.is_current((!) attempt)) return ParticipantInviteAvailability.CONVERTING;
        if (this.group_call == null || !is_live_call_for_muji_invite() ||
                !current_group_room_ready_for_invites()) {
            if (attempt != null) invite_attempts.release((!) attempt);
            return ParticipantInviteAvailability.ENDED;
        }
        if (attempt == null) {
            if (invite_attempts.has_current(bare_invitee)) return ParticipantInviteAvailability.CONVERTING;
            attempt = invite_attempts.begin(bare_invitee);
        }

        Xep.Muji.GroupCall active_group_call = (!) this.group_call;
        XmppStream? maybe_stream = stream_interactor.get_stream(call.account);
        if (maybe_stream == null) {
            invite_attempts.release((!) attempt);
            return ParticipantInviteAvailability.NOT_CONNECTED;
        }
        XmppStream stream = (!) maybe_stream;
        ((!) attempt).group_call = active_group_call;
        ((!) attempt).stream = stream;
        ((!) attempt).call_id = cim_call_id;

        debug("[%s] Inviting to muji call %s", call.account.bare_jid.to_string(), bare_invitee.to_string());
        if (!is_current_muji_invite_context((!) attempt)) return ParticipantInviteAvailability.ENDED;
        // An already-ready participant needs neither a new membership grant
        // nor a fresh proposal/never-joined timeout (including re-invites).
        if (complete_muji_invite_if_ready((!) attempt)) return ParticipantInviteAvailability.AVAILABLE;
        try {
            yield stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .set_affiliation_checked(call.account, active_group_call.muc_jid.bare_jid,
                    bare_invitee, MUJI_INVITEE_AFFILIATION);
        } catch (GLib.Error e) {
            if (((!) attempt).ready_joined) return completed_muji_invite_result((!) attempt);
            warning("[%s] Could not authorize %s for MUJI room %s: %s",
                call.account.bare_jid.to_string(), bare_invitee.to_string(),
                active_group_call.muc_jid.to_string(), e.message);
            invite_attempts.release((!) attempt);
            return ParticipantInviteAvailability.NO_INVITE_PERMISSION;
        }
        if (!is_current_muji_invite_context((!) attempt)) return completed_muji_invite_result((!) attempt);
        if (complete_muji_invite_if_ready((!) attempt)) return ParticipantInviteAvailability.AVAILABLE;
        if (!cim_targets.replace_direct_reference(bare_invitee,
                ((!) attempt).proposal_id)) {
            invite_attempts.release((!) attempt);
            return ParticipantInviteAvailability.ENDED;
        }
        stream.get_module<Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY)
            .send_muji_propose(stream, ((!) attempt).proposal_id, bare_invitee,
                active_group_call.muc_jid, active_group_call.video_requested, "chat");
        if (!is_current_muji_invite_context((!) attempt)) return completed_muji_invite_result((!) attempt);

        // If the peer hasn't joined within 60s, retract the invite and remove affiliation
        ((!) attempt).timeout_source_id = Timeout.add_seconds(60, () => {
            ((!) attempt).timeout_source_id = 0;
            if (!is_current_muji_invite_context((!) attempt)) {
                invite_attempts.release((!) attempt);
                return Source.REMOVE;
            }

            if (!has_muji_peer(bare_invitee)) {
                retract_group_call_invite.begin((!) attempt, (obj, res) => {
                        retract_group_call_invite.end(res);
                    });
            } else {
                invite_attempts.release((!) attempt);
            }
            return Source.REMOVE;
        });
        return ParticipantInviteAvailability.AVAILABLE;
    }

    private bool is_live_call_for_muji_invite() {
        return call.state == Call.State.RINGING ||
            call.state == Call.State.ESTABLISHING ||
            call.state == Call.State.IN_PROGRESS;
    }

    private bool has_muji_peer(Jid invitee) {
        foreach (Jid peer in peers.keys) {
            if (peer.equals_bare(invitee)) return true;
        }
        return false;
    }

    private bool is_current_muji_invite_context(MujiInviteAttempt attempt) {
        return invite_attempts.is_current(attempt) &&
            matches_muji_invite_call_context(attempt);
    }

    private bool matches_muji_invite_call_context(MujiInviteAttempt attempt) {
        return is_live_call_for_muji_invite() &&
            current_group_room_ready_for_invites() &&
            attempt.group_call != null && this.group_call == attempt.group_call &&
            attempt.stream != null &&
            stream_interactor.get_stream(call.account) == attempt.stream &&
            cim_call_id == attempt.call_id;
    }

    private bool complete_muji_invite_if_ready(MujiInviteAttempt attempt) {
        return is_current_muji_invite_context(attempt) &&
            invite_attempts.complete_if_ready(attempt, (!) attempt.group_call,
                (!) attempt.stream, cim_call_id);
    }

    private ParticipantInviteAvailability completed_muji_invite_result(MujiInviteAttempt attempt) {
        // Ready may retire this attempt while the membership grant is awaiting
        // its reply. Do not send a new proposal or re-arm its timeout then.
        // An affiliation IQ already dispatched cannot be recalled here.
        return attempt.ready_joined && matches_muji_invite_call_context(attempt)
            ? ParticipantInviteAvailability.AVAILABLE : ParticipantInviteAvailability.ENDED;
    }

    internal static bool private_room_ready_for_invites(
            bool conversion_in_progress, bool locally_created,
            PrivateMujiConversionTransaction? conversion) {
        if (conversion_in_progress) return false;
        return !locally_created ||
            (conversion != null && ((!) conversion).may_propose());
    }

    private bool current_group_room_ready_for_invites() {
        bool locally_created = active_muji_room_lifecycle != null &&
            ((!) active_muji_room_lifecycle).locally_created;
        return private_room_ready_for_invites(group_call_converting,
            locally_created, private_group_conversion);
    }

    private async void retract_group_call_invite(MujiInviteAttempt attempt) {
        if (!is_current_muji_invite_context(attempt)) {
            invite_attempts.release(attempt);
            return;
        }
        if (has_muji_peer(attempt.invitee)) {
            invite_attempts.release(attempt);
            return;
        }

        XmppStream current_stream = (!) attempt.stream;
        Xep.Muji.GroupCall expected_group_call = (!) attempt.group_call;
        debug("[%s] Retracting invite to %s from %s",
            call.account.bare_jid.to_string(), expected_group_call.muc_jid.to_string(),
            attempt.invitee.to_string());
        if (!attempt.retract_sent) {
            if (!is_current_muji_invite_context(attempt)) return;
            // Retire only this proposal before dispatch can re-enter. A late
            // timeout must not remove a replacement for the same participant.
            remove_cim_action_target(attempt.invitee,
                MessageStanza.TYPE_CHAT, attempt.proposal_id);
            attempt.retract_sent = true;
            current_stream.get_module<Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY)
                .send_retract(current_stream, attempt.invitee, attempt.proposal_id,
                    "chat");
        }

        if (!is_current_muji_invite_context(attempt)) return;
        try {
            yield stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .set_affiliation_checked(call.account,
                    expected_group_call.muc_jid.bare_jid,
                    attempt.invitee, "none");
            if (!is_current_muji_invite_context(attempt)) return;
            invite_attempts.release(attempt);
        } catch (GLib.Error e) {
            warning("[%s] Could not remove expired MUJI invite affiliation for %s: %s",
                call.account.bare_jid.to_string(), attempt.invitee.to_string(),
                e.message);
            if (!is_current_muji_invite_context(attempt)) {
                invite_attempts.release(attempt);
                return;
            }

            uint retry_delay_seconds;
            if (invite_attempts.register_cleanup_failure(attempt,
                    out retry_delay_seconds)) {
                schedule_muji_invite_cleanup_retry(attempt,
                    retry_delay_seconds);
            } else {
                warning("[%s] Giving up MUJI invite affiliation cleanup for %s after %u retries",
                    call.account.bare_jid.to_string(), attempt.invitee.to_string(),
                    MujiInviteAttemptRegistry.MAX_CLEANUP_RETRIES);
            }
        }
    }

    private void schedule_muji_invite_cleanup_retry(MujiInviteAttempt attempt,
            uint delay_seconds) {
        if (!is_current_muji_invite_context(attempt)) {
            invite_attempts.release(attempt);
            return;
        }
        if (attempt.cleanup_retry_source_id != 0) {
            Source.remove(attempt.cleanup_retry_source_id);
        }
        attempt.cleanup_retry_source_id = Timeout.add_seconds(delay_seconds, () => {
            attempt.cleanup_retry_source_id = 0;
            if (!is_current_muji_invite_context(attempt)) {
                invite_attempts.release(attempt);
                return Source.REMOVE;
            }
            retract_group_call_invite.begin(attempt, (obj, res) => {
                retract_group_call_invite.end(res);
            });
            return Source.REMOVE;
        });
    }

    public Plugins.MediaDevice? get_microphone_device() {
        if (uses_google_webrtc_jmi_call_engine()) return selected_microphone_device;
        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null) return null;
        if (selected_microphone_device == null) {
            string saved = ((Dino.Application) GLib.Application.get_default()).settings.call_audio_input_device;
            if (saved != "") {
                selected_microphone_device = Plugins.MediaDeviceSelection.find(
                    ((!) legacy_call_plugin).get_devices("audio", false), saved);
            }
            if (selected_microphone_device == null && !peers.is_empty) {
                foreach (PeerState peer_state in peers.values) {
                    var audio_stream = peer_state.get_audio_stream();
                    selected_microphone_device = ((!) legacy_call_plugin).get_device(audio_stream, false);
                    break;
                }
            }
            if (selected_microphone_device == null) {
                selected_microphone_device = ((!) legacy_call_plugin).get_preferred_device("audio", false);
            }
        }
        return selected_microphone_device;
    }

    public Plugins.MediaDevice? get_speaker_device() {
        if (uses_google_webrtc_jmi_call_engine()) return selected_speaker_device;
        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null) return null;
        if (selected_speaker_device == null) {
            string saved = ((Dino.Application) GLib.Application.get_default()).settings.call_audio_output_device;
            if (saved != "") {
                selected_speaker_device = Plugins.MediaDeviceSelection.find(
                    ((!) legacy_call_plugin).get_devices("audio", true), saved);
            }
            if (selected_speaker_device == null && !peers.is_empty) {
                foreach (PeerState peer_state in peers.values) {
                    var audio_stream = peer_state.get_audio_stream();
                    selected_speaker_device = ((!) legacy_call_plugin).get_device(audio_stream, true);
                    break;
                }
            }
            if (selected_speaker_device == null) {
                selected_speaker_device = ((!) legacy_call_plugin).get_preferred_device("audio", true);
            }
        }
        return selected_speaker_device;
    }

    public Plugins.MediaDevice? get_video_device() {
        if (uses_google_webrtc_jmi_call_engine()) {
            Plugins.JmiCallEnginePlugin? jmi_call_engine =
                selected_jmi_call_engine;
            if (jmi_call_engine == null) return null;

            if (selected_video_device == null) {
                string saved = ((Dino.Application) GLib.Application.get_default()).settings.call_video_device;
                if (saved != "") {
                    selected_video_device = Plugins.MediaDeviceSelection.find(
                        ((!) jmi_call_engine).get_video_devices(), saved);
                }
                if (selected_video_device == null) {
                    selected_video_device = ((!) jmi_call_engine).get_preferred_video_device();
                }
            }
            return selected_video_device;
        }

        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null) return null;
        if (selected_video_device == null) {
            string saved = ((Dino.Application) GLib.Application.get_default()).settings.call_video_device;
            if (saved != "") {
                selected_video_device = Plugins.MediaDeviceSelection.find(
                    ((!) legacy_call_plugin).get_devices("video", false), saved);
            }
            if (selected_video_device == null && !peers.is_empty) {
                foreach (PeerState peer_state in peers.values) {
                    var video_stream = peer_state.get_video_stream();
                    selected_video_device = ((!) legacy_call_plugin).get_device(video_stream, false);
                    break;
                }
            }
            if (selected_video_device == null) {
                selected_video_device = ((!) legacy_call_plugin).get_preferred_device("video", false);
            }
        }
        return selected_video_device;
    }

    public void set_audio_device(Plugins.MediaDevice? device) {
        if (uses_google_webrtc_jmi_call_engine()) return;
        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null || device == null) return;

        if (((!) device).incoming) {
            selected_speaker_device = device;
        } else {
            selected_microphone_device = device;
        }
        foreach (PeerState peer_state in peers.values) {
            ((!) legacy_call_plugin).set_device(peer_state.get_audio_stream(), device);
        }
    }

    public void set_video_device(Plugins.MediaDevice? device) {
        if (uses_google_webrtc_jmi_call_engine()) {
            selected_video_device = device;
            if (device == null) return;
            if (muji_engine_group_session != null) {
                try {
                    set_muji_group_video_device_once(
                        (!) muji_engine_group_session, (!) device);
                } catch (Error e) {
                    warning("[%s] Could not select the MUJI group video device: %s",
                        call.account.bare_jid.to_string(), e.message);
                }
                return;
            }
            foreach (PeerState peer_state in peers.values) {
                peer_state.set_google_webrtc_jmi_video_device((!) device);
            }
            return;
        }

        Plugins.VideoCallPlugin? legacy_call_plugin = call_plugin;
        if (legacy_call_plugin == null) return;
        selected_video_device = device;
        foreach (PeerState peer_state in peers.values) {
            ((!) legacy_call_plugin).set_device(peer_state.get_video_stream(), device);
        }
    }

    internal static void set_muji_group_video_device_once(
            Plugins.MujiCallEngineGroupSession group_session,
            Plugins.MediaDevice device) throws Error {
        group_session.set_video_device(device);
    }

    internal static bool inherit_selected_muji_group_video_device(
            Plugins.MujiCallEngineGroupSession group_session,
            Plugins.MediaDevice? selected_device,
            bool video_enabled) throws Error {
        if (!video_enabled || selected_device == null) return false;
        set_muji_group_video_device_once(group_session,
            (!) selected_device);
        return true;
    }

    internal void rename_peer(Jid from_jid, Jid to_jid) {
        debug("[%s] Renaming %s to %s exists %s", call.account.bare_jid.to_string(), from_jid.to_string(), to_jid.to_string(), peers.has_key(from_jid).to_string());
        PeerState? peer_state = peers[from_jid];
        if (peer_state == null) return;

        // Adjust the internal mapping of this `PeerState` object
        peers.unset(from_jid);
        peers[to_jid] = peer_state;
        rekey_peer_handler_id(peer_stream_created_handler_ids, from_jid, to_jid);
        rekey_peer_handler_id(peer_session_terminated_handler_ids, from_jid, to_jid);
        rekey_peer_handler_id(peer_video_effect_handler_ids, from_jid, to_jid);
        if (peer_bindings.has_key(from_jid)) {
            ArrayList<Binding> bindings = peer_bindings[from_jid];
            peer_bindings.unset(from_jid);
            peer_bindings[to_jid] = bindings;
        }
        peer_state.jid = to_jid;
    }

    /** Keep lifecycle-handler ownership aligned with a Bare-to-Full JID rename. */
    internal static void rekey_peer_handler_id(
            HashMap<Jid, ulong> handler_ids,
            Jid from_jid,
            Jid to_jid) {
        if (!handler_ids.has_key(from_jid)) return;
        ulong handler_id = handler_ids[from_jid];
        handler_ids.unset(from_jid);
        handler_ids[to_jid] = handler_id;
    }

    /** Removes and returns the handler owned by the current peer key. */
    internal static ulong take_peer_handler_id(
            HashMap<Jid, ulong> handler_ids,
            Jid jid) {
        if (!handler_ids.has_key(jid)) return 0;
        ulong handler_id = handler_ids[jid];
        handler_ids.unset(jid);
        return handler_id;
    }

    private void on_call_terminated(Jid who_terminated, bool we_terminated,
            string? reason_name, string? reason_text) {
        if (!begin_teardown()) return;
        // Cancel any pending timeouts (establishing, MUJI empty MUC, invite)
        cancel_all_timeouts();
        video_effect_requests.invalidate();
        Xep.Muji.GroupCall? active_group_call = group_call;
        disconnect_group_call_signals();
        group_call = null;
        if (active_group_call != null) {
            leave_published_muji_room((!) active_group_call,
                stream_interactor.get_stream(call.account));
        }
        close_muji_engine_group_session();
        clear_peer_ownership();
        cim_targets.clear();

        // Release cached device references so that the RTP plugin's
        // Gst.Device / GstDeviceProvider (and its PipeWire connection)
        // can be finalized after destroy_call_pipe().
        selected_microphone_device = null;
        selected_speaker_device = null;
        selected_video_device = null;

        if (call.state == Call.State.RINGING || call.state == Call.State.IN_PROGRESS || call.state == Call.State.ESTABLISHING) {
            call.end_time = new DateTime.now_utc();
        }
        if (call.state == Call.State.IN_PROGRESS) {
            call.state = Call.State.ENDED;
        } else if (call.state == Call.State.RINGING || call.state == Call.State.ESTABLISHING) {
            if (reason_name == Xep.Jingle.ReasonElement.DECLINE) {
                call.state = Call.State.DECLINED;
            } else {
                call.state = Call.State.FAILED;
            }
        }

        // Preserve the legacy cleanup safety net when the RTP plugin is
        // available. Package builds that only ship Google/libwebrtc have no
        // VideoCallPlugin, so the nullable helper deliberately becomes a no-op.
        if (media_backend == CallMediaBackend.LEGACY_RTP) {
            dispose_legacy_rtp_pipeline_later();
        }

        emit_terminated_once(who_terminated, reason_name, reason_text);
    }

    private void dispose_legacy_rtp_pipeline_later() {
        Plugins.VideoCallPlugin? legacy_call_plugin =
            Dino.Application.get_default().plugin_registry.video_call_plugin;
        if (legacy_call_plugin == null) return;

        // Keep the plugin alive until pending close_stream() work has finished.
        Idle.add(() => {
            ((!) legacy_call_plugin).dispose_pipeline();
            return Source.REMOVE;
        });
    }

    private void connect_peer_signals(PeerState peer_state) {
        peers[peer_state.jid] = peer_state;

        var bindings = new ArrayList<Binding>();
        bindings.add(this.bind_property("we-should-send-audio", peer_state, "we-should-send-audio", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL));
        bindings.add(this.bind_property("we-should-send-video", peer_state, "we-should-send-video", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL));
        bindings.add(this.bind_property("group-call", peer_state, "group-call", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL));
        peer_bindings[peer_state.jid] = bindings;

        peer_stream_created_handler_ids[peer_state.jid] = peer_state.stream_created.connect((peer, media) => { on_peer_stream_created(peer, media); });
        peer_session_terminated_handler_ids[peer_state.jid] = peer_state.session_terminated.connect((we_terminated, reason_name, reason_text) => {
            debug("[%s] Peer left %s: %s %s (%i peers remaining)", call.account.bare_jid.to_string(), reason_text ?? "", reason_name ?? "", peer_state.jid.to_string(), peers.size);
            handle_peer_left(peer_state, we_terminated, reason_name, reason_text);
        });
        peer_video_effect_handler_ids[peer_state.jid] =
            peer_state.google_webrtc_jmi_video_effect_status_changed.connect((status) => {
                if (!peers.has_key(peer_state.jid) ||
                        video_effects_group_gate_active || peers.size != 1) return;
                if (status.accepted_revision < cached_video_effect_status.accepted_revision ||
                        status.applied_revision < cached_video_effect_status.applied_revision) return;
                cached_video_effect_status = status;
                video_effect_status_changed(status);
            });
    }

    private ParticipantInviteAvailability participant_invite_prerequisites() {
        if (teardown_started || call.state == Call.State.ENDED ||
                call.state == Call.State.MISSED || call.state == Call.State.DECLINED ||
                call.state == Call.State.FAILED || call.state == Call.State.OTHER_DEVICE) {
            return ParticipantInviteAvailability.ENDED;
        }
        if (group_call_converting || group_call_joining) return ParticipantInviteAvailability.CONVERTING;
        if (call.state != Call.State.IN_PROGRESS ||
                stream_interactor.get_stream(call.account) == null ||
                stream_interactor.connection_manager.get_state(call.account) !=
                    ConnectionManager.ConnectionState.CONNECTED) {
            return ParticipantInviteAvailability.NOT_CONNECTED;
        }
        bool offer_audio = true;
        bool offer_video = group_call != null && group_call.video_requested;
        if (group_call == null && peers.size != 1) {
            return ParticipantInviteAvailability.NOT_CONNECTED;
        }
        if (group_call == null && (!try_get_direct_offer_media(out offer_audio, out offer_video) || !offer_audio)) {
            return ParticipantInviteAvailability.ENGINE_UNSUPPORTED;
        }
        if (!can_use_selected_muji_engine(offer_video)) {
            return ParticipantInviteAvailability.ENGINE_UNSUPPORTED;
        }
        if (peers.size >= MAX_MUJI_PEERS) return ParticipantInviteAvailability.CALL_FULL;
        if (group_call != null) {
            var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (group_call.left) return ParticipantInviteAvailability.ENDED;
            if (!can_invite_group_participants || !current_group_room_ready_for_invites() ||
                    !muc.has_live_private_room_features(call.account, group_call.muc_jid) ||
                    muc.capture_current_owner_context(call.account, group_call.muc_jid) == null) {
                return ParticipantInviteAvailability.NO_INVITE_PERMISSION;
            }
            return ParticipantInviteAvailability.AVAILABLE;
        }
        if (!stream_interactor.get_module<Calls>(Calls.IDENTITY).can_initiate_groupcall(call.account)) {
            return ParticipantInviteAvailability.NO_MUC_SERVICE;
        }
        return ParticipantInviteAvailability.AVAILABLE;
    }

    public async ParticipantInviteAvailability get_participant_invite_availability() {
        ParticipantInviteAvailability status = participant_invite_prerequisites();
        if (status != ParticipantInviteAvailability.AVAILABLE || group_call != null) return status;
        XmppStream? stream = stream_interactor.get_stream(call.account);
        uint64 generation = lifecycle.capture();
        PeerState? first = null;
        foreach (PeerState candidate in peers.values) first = candidate;
        if (first == null || !first.jid.is_full() ||
                first.get_google_webrtc_call_engine_session() == null) {
            return ParticipantInviteAvailability.NOT_CONNECTED;
        }
        Jid peer = first.jid;
        bool supports_muji = yield stream_interactor.get_module<EntityInfo>(EntityInfo.IDENTITY)
            .has_feature(call.account, peer, Xep.Muji.NS_URI);
        if (!is_live_generation(generation, stream) || group_call != null || peers[peer] != first) {
            return ParticipantInviteAvailability.ENDED;
        }
        status = participant_invite_prerequisites();
        if (status != ParticipantInviteAvailability.AVAILABLE) return status;
        return supports_muji ? ParticipantInviteAvailability.AVAILABLE :
            ParticipantInviteAvailability.PEER_UNSUPPORTED;
    }

    public async bool can_convert_into_groupcall() {
        if (group_call != null) return false;
        return (yield get_participant_invite_availability()) == ParticipantInviteAvailability.AVAILABLE;
    }

    private bool try_get_direct_offer_media(out bool audio, out bool video) {
        audio = false;
        video = false;
        if (peers.size != 1) return false;
        foreach (PeerState peer in peers.values) {
            Plugins.JmiCallEngineSession? session = peer.get_google_webrtc_call_engine_session();
            return session != null && session.try_get_initial_offer_media(out audio, out video);
        }
        return false;
    }

    private bool direct_conversion_is_current(uint64 generation, XmppStream stream,
            PeerState first_peer, Plugins.JmiCallEngineSession first_session, Jid service) {
        Jid? current_service = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .default_muc_server[call.account];
        return is_live_generation(generation, stream) && group_call == null &&
            peers.size == 1 && peers[first_peer.jid] == first_peer &&
            first_peer.get_google_webrtc_call_engine_session() == first_session &&
            stream_interactor.connection_manager.get_state(call.account) ==
                ConnectionManager.ConnectionState.CONNECTED &&
            current_service != null && current_service.equals(service);
    }

    /** Configure an owned temporary MUC before any direct media leg is moved. */
    private async bool prepare_private_conversion_room(XmppStream stream, Jid room,
            PeerState first_peer, Plugins.JmiCallEngineSession first_session,
            Jid service, uint64 generation, PrivateMujiConversionTransaction conversion) {
        Xep.Muc.Module module = stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY);
        Xep.Muc.JoinResult? result = null;
        string nick = "";
        for (int attempt = 0; attempt < 3; attempt++) {
            if (!direct_conversion_is_current(generation, stream, first_peer, first_session, service)) return false;
            Xep.Muc.Flag flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            if (flag.is_occupant(room)) return false;
            nick = "%08x".printf(Random.next_int());
            result = yield module.enter(stream, room, nick, null, null, false, null);
            if (result != null && result.muc_error == null && result.stanza_error == null &&
                    result.nick != null && flag.get_muc_nick(room) == result.nick) {
                try {
                    var owner_context = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                        .capture_current_owner_context(call.account, room);
                    Jid staged_occupant = room.with_resource(result.nick);
                    Xmpp.Presence.Flag? presence_flag = stream.get_flag(Xmpp.Presence.Flag.IDENTITY);
                    conversion.record_staged_occupancy(staged_occupant, flag,
                        result.newly_created, owner_context,
                        presence_flag != null ? presence_flag.get_presence(staged_occupant) : null);
                } catch (InvalidJidError e) {
                    return false;
                }
            }
            if (!direct_conversion_is_current(generation, stream, first_peer, first_session, service)) return false;
            if (result != null && result.muc_error == Xep.Muc.MucEnterError.NICK_CONFLICT) continue;
            break;
        }
        if (result == null || result.muc_error != null || result.stanza_error != null ||
                result.nick == null || !result.newly_created) return false;
        conversion.mark_room_joined();
        var muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? room_context = muc_manager.capture_current_owner_context(call.account, room);
        if (room_context == null) return false;
        Xep.DataForms.DataForm? data_form = yield muc_manager.get_config_form_in_context(call.account, room_context);
        if (data_form == null || !direct_conversion_is_current(generation, stream,
                first_peer, first_session, service)) return false;
        bool? original_members_only = MucManager.get_members_only_config_value(data_form);

        bool members_only_field = false;
        bool whois_field = false;
        bool temporary_room_field = false;
        foreach (Xep.DataForms.DataForm.Field field in data_form.fields) {
            switch (field.var) {
                case "muc#roomconfig_allowinvites":
                    if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                        ((Xep.DataForms.DataForm.BooleanField) field).value = true;
                    }
                    break;
                case "muc#roomconfig_persistentroom":
                    if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                        ((Xep.DataForms.DataForm.BooleanField) field).value = false;
                        temporary_room_field = true;
                    }
                    break;
                case "muc#roomconfig_membersonly":
                    if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                        ((Xep.DataForms.DataForm.BooleanField) field).value = true;
                        members_only_field = true;
                    }
                    break;
                case "muc#roomconfig_whois":
                    if (field.type_ == Xep.DataForms.DataForm.Type.LIST_SINGLE) {
                        ((Xep.DataForms.DataForm.ListSingleField) field).value = "anyone";
                        whois_field = true;
                    }
                    break;
            }
        }
        if (!members_only_field || !whois_field || !temporary_room_field) {
            warning("[%s] MUJI room lacks required temporary/private-room configuration fields",
                call.account.bare_jid.to_string());
            return false;
        }
        MucConfigSaveResult config_result = yield muc_manager.set_config_form_detailed_in_context(
            call.account, room_context, data_form, original_members_only);
        if (!direct_conversion_is_current(generation, stream, first_peer, first_session, service) ||
                (config_result != MucConfigSaveResult.APPLIED &&
                 config_result != MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING)) return false;
        bool room_exists = yield module.query_room_info(stream, room);
        if (!room_exists || !direct_conversion_is_current(generation, stream,
                first_peer, first_session, service) ||
                !muc_manager.is_current_owner_context(call.account, room_context) ||
                !muc_manager.has_live_private_room_features(call.account, room)) return false;
        Xep.Muc.Flag? confirmed_flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        if (confirmed_flag == null || !confirmed_flag.has_room_feature(room, Xep.Muc.Feature.TEMPORARY) ||
                confirmed_flag.has_room_feature(room, Xep.Muc.Feature.PERSISTENT)) return false;
        // The account that owns this new room must never be downgraded to member.
        if (!first_peer.jid.equals_bare(call.account.bare_jid)) {
            try {
                yield muc_manager.set_affiliation_checked(call.account, room,
                    first_peer.jid.bare_jid, MUJI_INVITEE_AFFILIATION);
            } catch (Error e) {
                debug("MUJI first-peer authorization failed: %s", e.message);
                return false;
            }
        }
        if (!direct_conversion_is_current(generation, stream, first_peer, first_session, service) ||
                !muc_manager.is_current_owner_context(call.account, room_context) ||
                !muc_manager.has_live_private_room_features(call.account, room)) return false;
        conversion.mark_private_config_applied();
        return true;
    }

    private async void cleanup_unpublished_conversion_room(XmppStream stream, Jid room,
            PrivateMujiConversionTransaction conversion) {
        if (stream_interactor.get_stream(call.account) != stream ||
                !conversion.owns_staged_occupancy(stream)) return;
        var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        var owner = conversion.staged_owner_context;
        Jid? staged_occupant = conversion.staged_occupant;
        Xmpp.Presence.Flag? presence = stream.get_flag(Xmpp.Presence.Flag.IDENTITY);
        if (presence == null || staged_occupant == null || conversion.staged_self_presence == null ||
                presence.get_presence(staged_occupant) != conversion.staged_self_presence) return;
        bool alone = presence != null;
        if (presence != null) {
            foreach (Xmpp.Presence.Stanza occupant in presence.get_presences(room)) {
                if (!occupant.from.equals(staged_occupant)) {
                    alone = false;
                    break;
                }
            }
        }
        // No MUJI preparation or invitation has been published. A confirmed
        // new room whose configuration failed may otherwise retain server defaults.
        if (conversion.try_claim_unpublished_room_cleanup(
                owner != null && muc.is_current_owner_context(call.account, owner), alone)) {
            try {
                yield stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).destroy_room(stream, room);
            } catch (Error e) {
                warning("[%s] Could not remove unpublished call room %s: %s",
                    call.account.bare_jid.to_string(), room.to_string(), e.message);
            }
        }
        // The destroy acknowledgement can arrive after a different join began.
        if (stream_interactor.get_stream(call.account) == stream &&
                conversion.owns_staged_occupancy(stream) &&
                presence.get_presence(staged_occupant) == conversion.staged_self_presence &&
                (owner == null || muc.is_current_owner_context(call.account, owner))) {
            stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).exit(stream, room);
        }
    }

    public async bool convert_into_group_call() {
        if (!(yield can_convert_into_groupcall()) || group_call_converting ||
                group_call != null || teardown_started) return false;
        XmppStream? stream = stream_interactor.get_stream(call.account);
        var muc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        Jid? service = muc.default_muc_server[call.account];
        PeerState? first_peer = null;
        foreach (PeerState peer in peers.values) first_peer = peer;
        Plugins.JmiCallEngineSession? first_session = first_peer != null
            ? first_peer.get_google_webrtc_call_engine_session() : null;
        if (stream == null || service == null || first_peer == null || first_session == null) return false;
        group_call_converting = true;
        uint64 generation = lifecycle.capture();
        var conversion = new PrivateMujiConversionTransaction();
        Jid room;
        try {
            room = new Jid("%08x@".printf(Random.next_int()) + service.to_string());
        } catch (InvalidJidError e) {
            group_call_converting = false;
            return false;
        }
        bool staged = yield prepare_private_conversion_room(stream, room, first_peer,
            first_session, service, generation, conversion);
        if (!staged) {
            conversion.rollback();
            // No native group or original SID has been touched yet.
            yield cleanup_unpublished_conversion_room(stream, room, conversion);
            group_call_converting = false;
            return false;
        }
        conversion.mark_muji_join_started();
        bool joined = yield join_group_call(room, true, null, false, () => {
            return direct_conversion_is_current(generation, stream, first_peer, first_session, service) &&
                conversion.may_propose() && muc.has_live_private_room_features(call.account, room) &&
                muc.capture_current_owner_context(call.account, room) != null;
        }, true, null, null, true);
        if (!joined || group_call == null) {
            conversion.rollback();
            if (group_call == null && stream_interactor.get_stream(call.account) == stream &&
                    conversion.owns_staged_occupancy(stream)) {
                stream.get_module<Xep.Muc.Module>(Xep.Muc.Module.IDENTITY).exit(stream, room);
            }
            group_call_converting = false;
            return false;
        }
        // Adoption has committed synchronously. Do not close its group as a fake direct-call rollback.
        private_group_conversion = conversion;
        group_call_converting = false;
        can_invite_group_participants = active_muji_room_lifecycle != null &&
            active_muji_room_lifecycle.can_manage_invites(conversion.may_propose());
        if (!is_live_generation(generation, stream) || group_call.left ||
                !conversion.try_claim_proposal()) return false;
        use_cim = true;
        cim_call_id = Xmpp.random_uuid();
        // Member permission was checked before adoption. Target the exact original resource.
        add_cim_target(first_peer.jid, MessageStanza.TYPE_CHAT);
        stream.get_module<Xep.CallInvites.Module>(Xep.CallInvites.Module.IDENTITY)
            .send_muji_propose(stream, cim_call_id, first_peer.jid,
                room, group_call.video_requested, MessageStanza.TYPE_CHAT);
        return true;
    }

    /** Rejoin uses a fresh local owner and never configures or invites into the room. */
    internal async bool rejoin_existing_group_call(Jid muc_jid,
            GroupCallRejoinValidity may_continue) {
        if (group_call != null || !peers.is_empty || teardown_started ||
                !may_continue()) return false;
        accepted = true;
        call.state = Call.State.ESTABLISHING;
        return yield join_group_call(muc_jid, false, null, true,
            may_continue);
    }

    private async bool join_group_call(Jid muc_jid,
            bool locally_created = false,
            IncomingGroupAcceptTransaction? incoming_accept = null,
            bool require_existing_call = false,
            GroupCallRejoinValidity? rejoin_validity = null,
            bool require_joined_room = false,
            Xep.Muji.PreparingPresenceCommit? preparing_commit = null,
            GroupCallRejoinValidity? ready_validity = null,
            bool take_joined_occupancy = false) {
        Calls.trace_muji_control("join-begin call=%d room=%s created=%s".printf(
            call.id, muc_jid.to_string(), locally_created.to_string()));
        debug("[%s] Joining group call %s", call.account.bare_jid.to_string(), muc_jid.to_string());
        if (group_call_joining || teardown_started) return false;
        group_call_joining = true;
        var publication = new GroupJoinPublicationTransaction(lifecycle);
        var room_lifecycle = new MujiPublishedRoomLifecycle(
            locally_created);
        uint64 operation_generation = publication.generation;
        XmppStream stream = stream_interactor.get_stream(call.account);
        if (stream == null) {
            group_call_joining = false;
            return false;
        }
        if (!incoming_group_accept_may_continue(incoming_accept) ||
                (rejoin_validity != null && !((!) rejoin_validity)())) {
            group_call_joining = false;
            return false;
        }

        if (media_backend != CallMediaBackend.GOOGLE_WEBRTC ||
                selected_muji_call_engine == null) {
            warning("[%s] Cannot join MUJI without the selected Google/libwebrtc group engine",
                call.account.bare_jid.to_string());
            group_call_joining = false;
            return false;
        }
        if (muji_engine_group_session != null) {
            warning("[%s] Refusing to replace an active MUJI media-engine group",
                call.account.bare_jid.to_string());
            group_call_joining = false;
            return false;
        }
        Xmpp.Bind.Flag? bind_flag = stream.get_flag(Xmpp.Bind.Flag.IDENTITY);
        if (bind_flag == null || ((!) bind_flag).my_jid == null || call.id <= 0) {
            warning("[%s] Cannot create MUJI engine group without a bound full JID and persisted call id",
                call.account.bare_jid.to_string());
            group_call_joining = false;
            return false;
        }

        // The old 1:1 peer becomes the first MUJI peer. Finish every native
        // effect request and the worker's pipeline-destroy barrier before the
        // room join can publish group_call or any MUJI peer lifecycle event.
        yield fence_video_effects_before_group_call();
        if (!is_live_generation(operation_generation, stream) ||
                !incoming_group_accept_may_continue(incoming_accept) ||
                (rejoin_validity != null && !((!) rejoin_validity)())) {
            group_call_joining = false;
            return false;
        }
        bool conference_video = we_should_send_video;
        if (!peers.is_empty) {
            bool offer_audio;
            if (!try_get_direct_offer_media(out offer_audio, out conference_video) || !offer_audio) {
                group_call_joining = false;
                return false;
            }
        }
        Plugins.MujiCallEngineGroupSession active_engine_group;
        try {
            active_engine_group = ((!) selected_muji_call_engine)
                .create_group_session(stream, ((!) bind_flag).my_jid,
                    muc_jid.bare_jid, (uint64) call.id,
                    conference_video);
        } catch (Error e) {
            warning("[%s] Couldn't create MUJI media-engine group: %s",
                call.account.bare_jid.to_string(), e.message);
            group_call_joining = false;
            return false;
        }
        active_engine_group.defer_incoming_peer_session_delivery();
        try {
            active_engine_group.set_local_video_enabled(we_should_send_video);
        } catch (Error e) {
            close_unpublished_muji_engine_group(active_engine_group, 0);
            group_call_joining = false;
            return false;
        }

        // A promoted live 1:1 leg already has an immutable Jingle offer map.
        // Seed the room presence from that exact map so adoption preserves
        // both the existing media and XEP-0272 conference identity.
        foreach (PeerState existing_peer in peers.values) {
            if (!existing_peer.first_peer) continue;
            Plugins.JmiCallEngineSession? existing_session =
                existing_peer.get_google_webrtc_call_engine_session();
            if (existing_session == null ||
                    existing_peer.jid.resourcepart == null) {
                warning("[%s] Cannot prepare MUJI promotion without a live full-JID Google/libwebrtc first peer",
                    call.account.bare_jid.to_string());
                close_unpublished_muji_engine_group(
                    active_engine_group, 0);
                group_call_joining = false;
                return false;
            }
            try {
                active_engine_group.prepare_peer_adoption(
                    existing_peer.jid, (!) existing_session);
            } catch (Error e) {
                warning("[%s] Couldn't seed MUJI media from the first peer: %s",
                    call.account.bare_jid.to_string(), e.message);
                close_unpublished_muji_engine_group(
                    active_engine_group, 0);
                group_call_joining = false;
                return false;
            }
        }

        Gee.Map<string, string> preferred_names;
        Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
            preferred_payloads;
        bool has_preferred_media =
            active_engine_group.copy_preferred_conference_media(
                out preferred_names, out preferred_payloads);

        ulong unpublished_incoming_peer_handler_id =
            active_engine_group.incoming_peer_session.connect(
                (peer_full_jid, sid, engine_session) => {
                    if (muji_engine_group_session != active_engine_group ||
                            group_call == null ||
                            !active_engine_group.room_jid.equals(
                                ((!) group_call).muc_jid) ||
                            !publication.try_publish_event()) {
                        engine_session.discard();
                        return;
                    }
                    PeerState? peer_state = peers[peer_full_jid];
                    if (peer_state == null ||
                            !((!) peer_state).waiting_for_inbound_muji_connection) {
                        warning("[%s] Discarding unexpected MUJI peer session from %s",
                            call.account.bare_jid.to_string(),
                            peer_full_jid.to_string());
                        engine_session.discard();
                        return;
                    }
                    ((!) peer_state).accept_google_webrtc_muji_peer_session(
                        sid, engine_session);
                });
        ulong unpublished_incoming_peer_failed_handler_id =
            active_engine_group.incoming_peer_session_failed.connect(
                (peer_full_jid, sid, message) => {
                    if (muji_engine_group_session != active_engine_group ||
                            group_call == null ||
                            !active_engine_group.room_jid.equals(
                                ((!) group_call).muc_jid) ||
                            !publication.try_publish_event()) {
                        return;
                    }
                    PeerState? peer_state = peers[peer_full_jid];
                    if (peer_state == null ||
                            !((!) peer_state)
                                .waiting_for_inbound_muji_connection) {
                        return;
                    }
                    warning("[%s] Incoming MUJI peer session from %s failed: %s",
                        call.account.bare_jid.to_string(),
                        peer_full_jid.to_string(), message);
                    ((!) peer_state)
                        .fail_waiting_google_webrtc_muji_peer_session(
                            sid, message);
                });

        var join_cancellable = new Cancellable();
        pending_muji_join_cancellable = join_cancellable;
        Xep.Muji.GroupCall? joined_group_call = yield stream.get_module<Xep.Muji.Module>(
            Xep.Muji.Module.IDENTITY).join_call(stream, muc_jid,
                conference_video, active_engine_group.codec_provider,
                has_preferred_media ? preferred_names : null,
                has_preferred_media ? preferred_payloads : null,
                (ready_group_call) => {
                    if (!is_live_generation(operation_generation, stream) ||
                            !incoming_group_accept_may_continue(
                                incoming_accept) ||
                            (rejoin_validity != null && !((!) rejoin_validity)()) ||
                            (ready_validity != null && !((!) ready_validity)())) {
                        throw new IOError.CANCELLED(
                            "MUJI join changed before ready presence");
                    }
                    if (!ready_group_call.video_available) {
                        if (conference_video && !peers.is_empty) {
                            throw new IOError.NOT_SUPPORTED(
                                "The group cannot preserve the original video content");
                        }
                        active_engine_group.disable_video_for_codec_downgrade();
                    }
                    active_engine_group.configure_conference_media(
                        ready_group_call.copy_content_names_by_media(),
                        ready_group_call.copy_payload_types_by_media());
                    foreach (Jid peer_jid in
                            ready_group_call.peers_to_wait_for) {
                        if (peers.has_key(peer_jid)) continue;
                        active_engine_group.expect_incoming_peer_session(
                            peer_jid,
                            conference_video &&
                                ready_group_call.peer_supports_video(peer_jid));
                    }
                }, join_cancellable, require_existing_call, require_joined_room,
                preparing_commit, take_joined_occupancy);
        Calls.trace_muji_control("join-result call=%d room=%s joined=%s".printf(
            call.id, muc_jid.to_string(),
            (joined_group_call != null).to_string()));
        if (pending_muji_join_cancellable == join_cancellable) {
            pending_muji_join_cancellable = null;
        }
        if (!is_live_generation(operation_generation, stream) ||
                !incoming_group_accept_may_continue(incoming_accept) ||
                (rejoin_validity != null && !((!) rejoin_validity)())) {
            if (joined_group_call != null) ((!) joined_group_call).leave(stream);
            close_unpublished_muji_engine_group(active_engine_group,
                unpublished_incoming_peer_handler_id,
                unpublished_incoming_peer_failed_handler_id);
            group_call_joining = false;
            return false;
        }
        if (joined_group_call == null || ((!) joined_group_call).left) {
            warning("[%s] Couldn't join a live MUJI MUC",
                call.account.bare_jid.to_string());
            close_unpublished_muji_engine_group(active_engine_group,
                unpublished_incoming_peer_handler_id,
                unpublished_incoming_peer_failed_handler_id);
            group_call_joining = false;
            return false;
        }

        int initial_peer_count = joined_group_call.peers_to_connect_to.size +
            joined_group_call.peers_to_wait_for.size;
        if (initial_peer_count > MAX_MUJI_PEERS) {
            joined_group_call.leave(stream);
            close_unpublished_muji_engine_group(active_engine_group,
                unpublished_incoming_peer_handler_id, unpublished_incoming_peer_failed_handler_id);
            group_call_joining = false;
            return false;
        }

        // Mute may change while preparing; never enable the camera during adoption.
        try {
            active_engine_group.set_local_video_enabled(we_should_send_video);
        } catch (Error e) {
            joined_group_call.leave(stream);
            close_unpublished_muji_engine_group(active_engine_group,
                unpublished_incoming_peer_handler_id, unpublished_incoming_peer_failed_handler_id);
            group_call_joining = false;
            return false;
        }

        // Validate and claim publication before the synchronous native adoption.
        // A successful adoption must never be followed by an unpublished-group
        // close that would terminate the unchanged original direct SID.
        if (!is_live_generation(operation_generation, stream) ||
                !incoming_group_accept_may_continue(incoming_accept) ||
                (rejoin_validity != null && !((!) rejoin_validity)()) ||
                !publication.try_commit(!((!) joined_group_call).left) ||
                (incoming_accept != null &&
                    !((!) incoming_accept).try_publish_join(
                        is_current_incoming_group_source()))) {
            ((!) joined_group_call).leave(stream);
            close_unpublished_muji_engine_group(active_engine_group,
                unpublished_incoming_peer_handler_id,
                unpublished_incoming_peer_failed_handler_id);
            group_call_joining = false;
            return false;
        }

        // A direct Google/libwebrtc leg remains the first mesh edge when a
        // 1:1 call is promoted. The group owner adopts that exact live leg;
        // it must never create a second connection or switch media backend.
        foreach (PeerState existing_peer in peers.values) {
            if (!existing_peer.first_peer) continue;
            Plugins.JmiCallEngineSession? existing_session =
                existing_peer.get_google_webrtc_call_engine_session();
            if (existing_session == null ||
                    existing_peer.jid.resourcepart == null) {
                warning("[%s] Cannot promote the first peer without a live full-JID Google/libwebrtc session",
                    call.account.bare_jid.to_string());
                ((!) joined_group_call).leave(stream);
                close_unpublished_muji_engine_group(active_engine_group,
                    unpublished_incoming_peer_handler_id,
                    unpublished_incoming_peer_failed_handler_id);
                group_call_joining = false;
                return false;
            }
            try {
                active_engine_group.adopt_peer_session(existing_peer.jid,
                    (!) existing_session);
            } catch (Error e) {
                warning("[%s] Couldn't adopt first peer into MUJI: %s",
                    call.account.bare_jid.to_string(), e.message);
                ((!) joined_group_call).leave(stream);
                close_unpublished_muji_engine_group(active_engine_group,
                    unpublished_incoming_peer_handler_id,
                    unpublished_incoming_peer_failed_handler_id);
                group_call_joining = false;
                return false;
            }
        }

        muji_engine_group_session = active_engine_group;
        muji_engine_incoming_peer_handler_id =
            unpublished_incoming_peer_handler_id;
        muji_engine_incoming_peer_failed_handler_id =
            unpublished_incoming_peer_failed_handler_id;
        room_lifecycle.mark_published();
        active_muji_room_lifecycle = room_lifecycle;
        active_muji_stream = stream;
        observed_group_call = (!) joined_group_call;
        muji_engine_video_effect_handler_id = active_engine_group.video_effect_status_changed.connect((status) => {
            if (!is_current_group_call_context(joined_group_call, active_engine_group,
                    operation_generation, stream) || joined_group_call.left) return;
            cached_video_effect_status = status;
            video_effect_status_changed(status);
        });
        this.group_call = (!) joined_group_call;
        if (!is_current_group_call_context(joined_group_call, active_engine_group,
                operation_generation, stream)) {
            // A reentrant UI hangup is normal committed-owner teardown.
            group_call_joining = false;
            return false;
        }

        // The direct-call camera selection may have changed while join_call()
        // was suspended. Transfer the latest cached device exactly once to
        // the group owner before it becomes visible, including 0-peer joins.
        try {
            if (inherit_selected_muji_group_video_device(
                    active_engine_group, selected_video_device,
                    conference_video)) {
                debug("[%s] Inherited the selected camera for the MUJI group",
                    call.account.bare_jid.to_string());
            }
        } catch (Error e) {
            warning("[%s] Could not inherit the selected camera for the MUJI group: %s",
                call.account.bare_jid.to_string(), e.message);
        }



        if (!is_current_group_call_context(joined_group_call, active_engine_group,
                operation_generation, stream)) {
            group_call_joining = false;
            return false;
        }
        group_call_peer_joined_handler_id = ((!) joined_group_call).peer_joined.connect((jid) => {
            if (!is_current_group_call_context((!) joined_group_call,
                    active_engine_group, operation_generation, stream) ||
                    !publication.try_publish_event()) return;
            MujiInviteAttempt? invite_attempt = invite_attempts.get_current(jid);
            if (invite_attempt != null && is_current_muji_invite_context((!) invite_attempt)) {
                invite_attempts.complete_ready_peer((!) invite_attempt, jid,
                    (!) joined_group_call, stream, cim_call_id);
            }
            debug("[%s] Group call peer joined: %s", call.account.bare_jid.to_string(), jid.to_string());
            var peer_publication = new MujiPeerJoinPublication();

            bool peer_video_requested = conference_video &&
                ((!) joined_group_call).peer_supports_video(jid);
            bool initiate_outgoing = ((!) joined_group_call)
                .peer_should_initiate_outgoing(jid);
            Calls.trace_muji_control(
                "peer-ready call=%d room=%s peer=%s outgoing=%s video=%s".printf(
                    call.id, muc_jid.to_string(), jid.to_string(),
                    initiate_outgoing.to_string(), peer_video_requested.to_string()));

            // Both initial and late peers use the same nick-based election.
            // An adopted direct-call leg remains owned by the original session.
            if (peers.has_key(jid)) {
                if (!peers[jid].first_peer) {
                    peers[jid].accept();
                }
                // else: Connection to first peer already active
                if (peers.has_key(jid)) {
                    peer_publication.mark_peer_published();
                }
            } else {
                if (peers.size >= MAX_MUJI_PEERS) {
                    debug("[%s] Ignoring MUJI peer %s at capacity",
                        call.account.bare_jid.to_string(), jid.to_string());
                    return;
                }
                var peer_state = new PeerState(jid, call, this, stream_interactor);
                peer_state.we_should_send_audio = we_should_send_audio;
                peer_state.we_should_send_video = we_should_send_video && peer_video_requested;
                bool defer_outgoing = initiate_outgoing &&
                    !((!) joined_group_call).outgoing_connections_ready;
                try {
                    if (initiate_outgoing && !defer_outgoing) {
                        peer_state.start_google_webrtc_muji_peer_session(
                            active_engine_group, jid,
                            peer_video_requested);
                    } else if (!initiate_outgoing) {
                        peer_state.waiting_for_inbound_muji_connection = true;
                        active_engine_group.expect_incoming_peer_session(
                            jid, peer_video_requested);
                    }
                } catch (Error e) {
                    warning("[%s] Couldn't create MUJI peer leg for %s: %s",
                        call.account.bare_jid.to_string(), jid.to_string(),
                        e.message);
                    peer_state.release_objects();
                    return;
                }
                debug(initiate_outgoing
                    ? "[%s] Calling %s after the MUJI nick election"
                    : "[%s] Waiting for call from %s",
                    call.account.bare_jid.to_string(), jid.to_string());
                add_peer(peer_state);
                if (defer_outgoing) {
                    start_muji_peer_after_ready.begin(peer_state,
                        (!) joined_group_call, active_engine_group,
                        operation_generation, stream, peer_video_requested);
                }
                if (peers.has_key(jid)) {
                    peer_publication.mark_peer_published();
                }
            }

            // Only a successfully owned PeerState disarms the watchdog. An
            // expect-incoming failure leaves a zero-peer published call and
            // therefore deliberately keeps the bounded timeout armed.
            if (peer_publication.claim_empty_timeout_cancel() &&
                    muji_empty_muc_timeout_id != 0) {
                Source.remove(muji_empty_muc_timeout_id);
                muji_empty_muc_timeout_id = 0;
            }
        });

        group_call_peer_left_handler_id = ((!) joined_group_call).peer_left.connect((jid) => {
            if (!is_current_group_call_context((!) joined_group_call,
                    active_engine_group, operation_generation, stream) ||
                    !publication.try_publish_event()) return;
            debug("[%s] Group call peer left: %s", call.account.bare_jid.to_string(), jid.to_string());
            active_engine_group.cancel_expected_incoming_peer_session(jid);
            PeerState? peer_state = peers[jid];
            if (peer_state == null) return;
            peer_state.end(Xep.Jingle.ReasonElement.CANCEL, "Peer left the MUJI MUC");
            handle_peer_left(peer_state, false, Xep.Jingle.ReasonElement.CANCEL, "Peer left the MUJI MUC");
        });

        group_call_codecs_changed_handler_id = ((!) joined_group_call).codecs_changed.connect((payload_types) => {
            if (!is_current_group_call_context((!) joined_group_call,
                    active_engine_group, operation_generation, stream) ||
                    !publication.try_publish_event()) return;
            if (payload_types.is_empty) {
                warning("[%s] MUJI codec intersection is now EMPTY — no common codecs with all peers", call.account.bare_jid.to_string());
            } else {
                var codec_names = new Gee.ArrayList<string>();
                foreach (var pt in payload_types) {
                    codec_names.add(pt.name ?? "unknown");
                }
                debug("[%s] MUJI codec intersection updated: %s", call.account.bare_jid.to_string(), join_strings(", ", codec_names));
            }
        });

        group_call_media_availability_handler_id = ((!) joined_group_call)
            .media_availability_changed.connect((media, availability,
                    payload_types) => {
                if (!is_current_group_call_context((!) joined_group_call,
                        active_engine_group, operation_generation, stream) ||
                        !publication.try_publish_event()) {
                    return;
                }
                apply_muji_media_policy(media, availability,
                    active_engine_group);
            });

        foreach (var media_entry in ((!) joined_group_call)
                .current_media_availability.entries) {
            if (!apply_muji_media_policy(media_entry.key,
                    media_entry.value, active_engine_group)) {
                group_call_joining = false;
                return false;
            }
        }

        Calls.trace_muji_control(
            "join-published call=%d room=%s outgoing=%d waiting=%d".printf(
                call.id, muc_jid.to_string(), group_call.peers_to_connect_to.size,
                group_call.peers_to_wait_for.size));
        foreach (Jid peer_jid in group_call.peers_to_connect_to) {
            // Don't establish connection if we have one already (the person that invited us to the call)
            if (peers.has_key(peer_jid)) continue;
            if (!publication.try_publish_event()) {
                group_call_joining = false;
                return false;
            }

            debug("[%s] Calling %s after the MUJI nick election", call.account.bare_jid.to_string(), peer_jid.to_string());

            PeerState peer_state = new PeerState(peer_jid, call, this, stream_interactor);
            peer_state.we_should_send_audio = we_should_send_audio;
            bool peer_video_requested = conference_video && group_call.peer_supports_video(peer_jid);
            peer_state.we_should_send_video = we_should_send_video && peer_video_requested;
            bool defer_outgoing = !group_call.outgoing_connections_ready;
            try {
                if (!defer_outgoing) {
                    peer_state.start_google_webrtc_muji_peer_session(
                        active_engine_group, peer_jid,
                        peer_video_requested);
                }
            } catch (Error e) {
                warning("[%s] Couldn't start MUJI peer session for %s: %s",
                    call.account.bare_jid.to_string(), peer_jid.to_string(),
                    e.message);
                peer_state.release_objects();
                continue;
            }
            add_peer(peer_state);
            if (defer_outgoing) {
                start_muji_peer_after_ready.begin(peer_state,
                    (!) joined_group_call, active_engine_group,
                    operation_generation, stream, peer_video_requested);
            }
        }

        // The smaller nick waits for the other participant's initiate.
        // Register those exact incoming legs before considering the room empty.
        foreach (Jid peer_jid in group_call.peers_to_wait_for) {
            if (peers.has_key(peer_jid)) continue;
            if (!publication.try_publish_event()) {
                group_call_joining = false;
                return false;
            }

            PeerState peer_state = new PeerState(
                peer_jid, call, this, stream_interactor);
            peer_state.we_should_send_audio = we_should_send_audio;
            bool peer_video_requested = conference_video && group_call.peer_supports_video(peer_jid);
            peer_state.we_should_send_video = we_should_send_video && peer_video_requested;
            peer_state.waiting_for_inbound_muji_connection = true;
            try {
                active_engine_group.expect_incoming_peer_session(
                    peer_jid, peer_video_requested);
            } catch (Error e) {
                warning("[%s] Couldn't expect incoming MUJI peer session for %s: %s",
                    call.account.bare_jid.to_string(), peer_jid.to_string(),
                    e.message);
                peer_state.release_objects();
                continue;
            }
            debug("[%s] Waiting for %s after the MUJI nick election",
                call.account.bare_jid.to_string(), peer_jid.to_string());
            add_peer(peer_state);
        }

        // Ready presence was published only after the engine had registered
        // every exact initial inbound leg. Any IQ that raced the async Core
        // continuation was claimed and held by the group until these PeerState
        // owners existed.
        active_engine_group.release_deferred_incoming_peer_sessions();

        // Start MUJI empty-MUC timeout: if no peers appear, end the call
        // Initiator gets more time (90s) because peers need to receive invite + join
        // Receiver gets 30s — if MUC is empty, the initiator probably left
        if (muji_initial_peer_timeout_required(call.state, peers.size,
                group_call != null)) {
            uint muji_timeout = (call.direction == Call.DIRECTION_OUTGOING) ? 90 : 30;
            start_muji_empty_muc_timeout(muji_timeout);
        }

        debug("[%s] Finished joining MUJI muc %s", call.account.bare_jid.to_string(), muc_jid.to_string());
        group_call_joining = false;
        return true;
    }

    private async void start_muji_peer_after_ready(PeerState peer_state,
            Xep.Muji.GroupCall joined_group_call,
            Plugins.MujiCallEngineGroupSession active_engine_group,
            uint64 operation_generation, XmppStream stream,
            bool peer_video_requested) {
        // Publish the group and inbound expectations normally while only the
        // elected outgoing legs wait. Existing adopted direct sessions keep running.
        if (!(yield joined_group_call.wait_for_own_ready())) return;
        if (!is_current_group_call_context(joined_group_call, active_engine_group,
                operation_generation, stream) || joined_group_call.left ||
                peers.get(peer_state.jid) != peer_state ||
                !joined_group_call.peer_should_initiate_outgoing(peer_state.jid) ||
                peer_state.uses_google_webrtc_jmi_call_engine_session()) return;
        try {
            peer_state.start_google_webrtc_muji_peer_session(active_engine_group,
                peer_state.jid, peer_video_requested);
        } catch (Error e) {
            warning("[%s] Couldn't start MUJI peer session after ready echo for %s: %s",
                call.account.bare_jid.to_string(), peer_state.jid.to_string(), e.message);
            peer_state.release_objects();
            handle_peer_left(peer_state, true,
                Xep.Jingle.ReasonElement.FAILED_APPLICATION, e.message);
        }
    }

    private bool apply_muji_media_policy(string media,
            Xep.Muji.CodecAvailability availability,
            Plugins.MujiCallEngineGroupSession active_engine_group) {
        switch (muji_media_policy_action(media, availability)) {
            case MujiMediaPolicyAction.DOWNGRADE_TO_AUDIO:
                group_video_effect_requests.invalidate();
                group_video_permanently_disabled = true;
                active_engine_group.disable_video_for_codec_downgrade();
                try {
                    active_engine_group.set_local_video_enabled(false);
                } catch (Error e) {
                    warning("[%s] Could not disable MUJI group video after codec downgrade: %s",
                        call.account.bare_jid.to_string(), e.message);
                }
                mute_own_video(true);
                return true;
            case MujiMediaPolicyAction.END_CALL:
                warning("[%s] Ending MUJI call without a common audio codec",
                    call.account.bare_jid.to_string());
                end("No common audio codec");
                return false;
            default:
                return true;
        }
    }

    private bool is_current_group_call_context(
            Xep.Muji.GroupCall expected_group_call,
            Plugins.MujiCallEngineGroupSession expected_engine_group,
            uint64 operation_generation,
            XmppStream expected_stream) {
        return is_live_generation(operation_generation, expected_stream) &&
            observed_group_call == expected_group_call &&
            group_call == expected_group_call &&
            muji_engine_group_session == expected_engine_group;
    }

    private void disconnect_group_call_signals() {
        if (observed_group_call != null) {
            Xep.Muji.GroupCall old_group_call = (!) observed_group_call;
            if (group_call_peer_joined_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_peer_joined_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_peer_joined_handler_id);
            }
            if (group_call_peer_left_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_peer_left_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_peer_left_handler_id);
            }
            if (group_call_codecs_changed_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_codecs_changed_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_codecs_changed_handler_id);
            }
            if (group_call_media_availability_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_media_availability_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_media_availability_handler_id);
            }
        }
        group_call_peer_joined_handler_id = 0;
        group_call_peer_left_handler_id = 0;
        group_call_codecs_changed_handler_id = 0;
        group_call_media_availability_handler_id = 0;
        observed_group_call = null;
    }

    private static void close_unpublished_muji_engine_group(
            Plugins.MujiCallEngineGroupSession engine_group,
            ulong incoming_peer_handler_id,
            ulong incoming_peer_failed_handler_id = 0) {
        if (incoming_peer_handler_id != 0 &&
                SignalHandler.is_connected(engine_group,
                    incoming_peer_handler_id)) {
            engine_group.disconnect(incoming_peer_handler_id);
        }
        if (incoming_peer_failed_handler_id != 0 &&
                SignalHandler.is_connected(engine_group,
                    incoming_peer_failed_handler_id)) {
            engine_group.disconnect(incoming_peer_failed_handler_id);
        }
        engine_group.close();
    }

    private void close_muji_engine_group_session() {
        group_video_effect_requests.invalidate();
        if (muji_engine_group_session == null) {
            muji_engine_incoming_peer_handler_id = 0;
            muji_engine_incoming_peer_failed_handler_id = 0;
            muji_engine_video_effect_handler_id = 0;
            return;
        }
        Plugins.MujiCallEngineGroupSession engine_group =
            (!) muji_engine_group_session;
        if (muji_engine_video_effect_handler_id != 0 &&
                SignalHandler.is_connected(engine_group, muji_engine_video_effect_handler_id)) {
            engine_group.disconnect(muji_engine_video_effect_handler_id);
        }
        muji_engine_video_effect_handler_id = 0;
        if (muji_engine_incoming_peer_handler_id != 0 &&
                SignalHandler.is_connected(engine_group,
                    muji_engine_incoming_peer_handler_id)) {
            engine_group.disconnect(muji_engine_incoming_peer_handler_id);
        }
        muji_engine_incoming_peer_handler_id = 0;
        if (muji_engine_incoming_peer_failed_handler_id != 0 &&
                SignalHandler.is_connected(engine_group,
                    muji_engine_incoming_peer_failed_handler_id)) {
            engine_group.disconnect(
                muji_engine_incoming_peer_failed_handler_id);
        }
        muji_engine_incoming_peer_failed_handler_id = 0;
        muji_engine_group_session = null;
        engine_group.close();
    }

    // --- Timeout management: 1:1 and MUJI are completely separate ---

    public void start_establishing_timeout(uint seconds) {
        cancel_establishing_timeout();
        establishing_timeout_id = Timeout.add_seconds(seconds, () => {
            if (call.state == Call.State.ESTABLISHING || call.state == Call.State.RINGING) {
                debug("[%s] Establishing timeout (%us) expired", call.account.bare_jid.to_string(), seconds);
                establishing_timeout_id = 0;
                reject_pending_cim_accept_if_owned();
                finish_terminal_state(Call.State.MISSED,
                    call.account.bare_jid, Xep.Jingle.ReasonElement.TIMEOUT,
                    "Call setup timed out", TerminalPeerAction.CANCEL);
                return Source.REMOVE;
            }
            establishing_timeout_id = 0;
            return Source.REMOVE;
        });
    }

    internal void start_jmi_migration_timeout(PeerState expected_peer,
            string expected_sid, uint seconds) {
        cancel_establishing_timeout();
        uint64 expected_generation = lifecycle.capture();
        establishing_timeout_id = Timeout.add_seconds(seconds, () => {
            establishing_timeout_id = 0;
            PeerState? current_peer = peers[expected_peer.jid];
            if (!is_live_generation(expected_generation) ||
                    current_peer == null || ((!) current_peer) != expected_peer ||
                    expected_peer.sid != expected_sid ||
                    call.state != Call.State.ESTABLISHING) {
                return Source.REMOVE;
            }
            debug("[%s] Migrated JMI setup timeout (%us) expired for sid=%s",
                call.account.bare_jid.to_string(), seconds, expected_sid);
            finish_terminal_state(Call.State.FAILED,
                call.account.bare_jid, Xep.Jingle.ReasonElement.TIMEOUT,
                "Migrated call setup timed out", TerminalPeerAction.CANCEL);
            return Source.REMOVE;
        });
    }

    /** Bound the interval between JMI proceed and the incoming Jingle leg. */
    internal void start_direct_jmi_setup_timeout(PeerState expected_peer,
            string expected_sid, uint seconds) {
        cancel_establishing_timeout();
        if (!direct_jmi_setup_timeout_allowed(media_backend,
                expected_peer.group_call != null, group_call != null,
                expected_peer.sid, expected_sid, call.state)) return;

        uint64 expected_generation = lifecycle.capture();
        establishing_timeout_id = Timeout.add_seconds(uint.max(1, seconds),
            () => {
                establishing_timeout_id = 0;
                PeerState? current_peer = peers[expected_peer.jid];
                if (!is_live_generation(expected_generation) ||
                        current_peer == null ||
                        ((!) current_peer) != expected_peer ||
                        expected_peer.sid != expected_sid ||
                        expected_peer.group_call != null ||
                        group_call != null ||
                        call.state != Call.State.ESTABLISHING) {
                    return Source.REMOVE;
                }
                debug("[%s] Direct JMI setup timeout (%us) expired for sid=%s",
                    call.account.bare_jid.to_string(), seconds,
                    expected_sid);
                finish_terminal_state(Call.State.FAILED,
                    call.account.bare_jid, Xep.Jingle.ReasonElement.TIMEOUT,
                    "Call setup timed out", TerminalPeerAction.CANCEL);
                return Source.REMOVE;
            });
    }

    internal static bool direct_jmi_setup_timeout_allowed(
            CallMediaBackend backend, bool peer_has_group_call,
            bool call_has_group_call, string current_sid,
            string expected_sid, Call.State state) {
        return backend == CallMediaBackend.GOOGLE_WEBRTC &&
            !peer_has_group_call && !call_has_group_call &&
            current_sid == expected_sid &&
            state == Call.State.ESTABLISHING;
    }

    /**
     * A current proposal reconstructed after MAM catch-up is actionable but
     * passive: it owns no media session and must expire without sending a
     * synthetic reject/retract to a peer which may already be offline.
     */
    internal void start_recovered_jmi_timeout(PeerState expected_peer,
            string expected_sid, uint seconds) {
        cancel_establishing_timeout();
        uint64 expected_generation = lifecycle.capture();
        establishing_timeout_id = Timeout.add_seconds(uint.max(1, seconds),
            () => {
                establishing_timeout_id = 0;
                PeerState? current_peer = peers[expected_peer.jid];
                if (!is_live_generation(expected_generation) ||
                        current_peer == null ||
                        ((!) current_peer) != expected_peer ||
                        expected_peer.sid != expected_sid ||
                        call.state != Call.State.RINGING) {
                    return Source.REMOVE;
                }
                finish_terminal_state(Call.State.MISSED,
                    expected_peer.jid, Xep.Jingle.ReasonElement.EXPIRED,
                    "Archived call proposal expired",
                    TerminalPeerAction.DISCARD);
                return Source.REMOVE;
            });
    }

    internal void cancel_establishing_timeout() {
        if (establishing_timeout_id == 0) return;
        Source.remove(establishing_timeout_id);
        establishing_timeout_id = 0;
    }

    internal static bool muji_initial_peer_timeout_required(
            Call.State state, int media_peers, bool has_group_call) {
        return has_group_call && media_peers == 0 &&
            (state == Call.State.RINGING || state == Call.State.ESTABLISHING);
    }

    private void start_muji_empty_muc_timeout(uint seconds) {
        if (muji_empty_muc_timeout_id != 0) Source.remove(muji_empty_muc_timeout_id);
        muji_empty_muc_timeout_id = Timeout.add_seconds(seconds, () => {
            if (muji_initial_peer_timeout_required(call.state, peers.size,
                    group_call != null)) {
                debug("[%s] MUJI empty MUC timeout (%us) expired", call.account.bare_jid.to_string(), seconds);
                end("No participants joined the group call");
            }
            muji_empty_muc_timeout_id = 0;
            return false;
        });
    }

    private void cancel_all_timeouts() {
        cancel_establishing_timeout();
        if (muji_empty_muc_timeout_id != 0) {
            Source.remove(muji_empty_muc_timeout_id);
            muji_empty_muc_timeout_id = 0;
        }
        invite_attempts.clear();
        pending_muji_invites.clear();
    }

    private void handle_peer_left(PeerState peer_state, bool we_terminated, string? reason_name, string? reason_text) {
        if (!peers.has_key(peer_state.jid)) return;
        peers.unset(peer_state.jid);

        // Disconnect signal handlers to break closure reference cycles
        ulong stream_handler_id = take_peer_handler_id(
            peer_stream_created_handler_ids, peer_state.jid);
        if (stream_handler_id != 0 && SignalHandler.is_connected(peer_state, stream_handler_id)) {
            peer_state.disconnect(stream_handler_id);
        }
        ulong session_handler_id = take_peer_handler_id(
            peer_session_terminated_handler_ids, peer_state.jid);
        if (session_handler_id != 0 && SignalHandler.is_connected(peer_state, session_handler_id)) {
            peer_state.disconnect(session_handler_id);
        }
        ulong video_effect_handler_id = take_peer_handler_id(
            peer_video_effect_handler_ids, peer_state.jid);
        if (video_effect_handler_id != 0 && SignalHandler.is_connected(peer_state, video_effect_handler_id)) {
            peer_state.disconnect(video_effect_handler_id);
        }

        // Unbind property bindings to break the bidirectional reference cycle
        if (peer_bindings.has_key(peer_state.jid)) {
            foreach (Binding binding in peer_bindings[peer_state.jid]) {
                binding.unbind();
            }
            peer_bindings.unset(peer_state.jid);
        }

        // Clean up PeerState's internal signal handlers (content/session closures)
        peer_state.cleanup_signal_handlers();

        // Release heavyweight Jingle/GStreamer objects from the PeerState
        peer_state.release_objects();

        if (peers.is_empty) {
            if (group_call != null) {
                // An established MUJI participant remains in the published
                // room until local hangup, even after the last peer leaves.
                if (call.state == Call.State.IN_PROGRESS) {
                    if (muji_empty_muc_timeout_id != 0) {
                        Source.remove(muji_empty_muc_timeout_id);
                        muji_empty_muc_timeout_id = 0;
                    }
                    peer_left(peer_state.jid, peer_state, reason_name,
                        reason_text);
                    return;
                }
                // Presence can already contain a participant in <preparing/>
                // while its media PeerState does not exist yet. Keep the
                // published room and engine alive for that participant and
                // let peer_joined cancel this bounded empty-room timeout.
                bool wait_for_preparing_peer =
                    muji_initial_peer_timeout_required(call.state,
                        peers.size, true) &&
                    (active_muji_room_lifecycle == null ||
                     ((!) active_muji_room_lifecycle)
                        .should_wait_for_preparing_peer(peers.size));
                if (wait_for_preparing_peer) {
                    uint timeout = call.direction == Call.DIRECTION_OUTGOING
                        ? 90 : 30;
                    start_muji_empty_muc_timeout(timeout);
                    peer_left(peer_state.jid, peer_state, reason_name,
                        reason_text);
                    return;
                }
                on_call_terminated(peer_state.jid, we_terminated,
                    reason_name, reason_text);
            } else {
                on_call_terminated(peer_state.jid, we_terminated, reason_name,
                    reason_text);
            }
        } else {
            peer_left(peer_state.jid, peer_state, reason_name, reason_text);
        }
    }
}
