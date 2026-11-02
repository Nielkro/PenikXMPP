using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino {

internal enum JmiProposalDisposition {
    NEW,
    DUPLICATE,
    CONFLICT,
    TERMINAL
}

/** Pure policy used before an incoming proposal may allocate UI or media. */
internal class JmiIncomingAuthorization : Object {
    internal static bool is_allowed(bool blocked, string? subscription) {
        return !blocked && MessageResponsePolicy.allows_roster_subscription(
            subscription);
    }
}

internal class JmiIncomingEnginePolicy : Object {
    internal static bool attach_on_proposal(bool from_own_account,
            Xep.JingleMessageInitiation.Delivery delivery) {
        return !from_own_account &&
            delivery == Xep.JingleMessageInitiation.Delivery.LIVE;
    }
}

/** Preconditions for replacing one active direct JMI media leg. */
internal class JmiActiveMigrationPolicy : Object {
    internal static bool may_stage(bool direct_lifecycle,
            CallMediaBackend media_backend, bool has_engine_session,
            Entities.Call.State call_state,
            Xep.JingleMessageInitiation.Delivery delivery,
            Jid proposal_source, Jid peer) {
        return direct_lifecycle &&
            media_backend == CallMediaBackend.GOOGLE_WEBRTC &&
            has_engine_session &&
            (call_state == Entities.Call.State.ESTABLISHING ||
                call_state == Entities.Call.State.IN_PROGRESS) &&
            (delivery == Xep.JingleMessageInitiation.Delivery.LIVE ||
                delivery ==
                    Xep.JingleMessageInitiation.Delivery.CARBON_RECEIVED) &&
            proposal_source.resourcepart != null &&
            proposal_source.equals_bare(peer);
    }
}

/** XEP-0353 uses bytewise i;octet ordering for proposal tie-breaking. */
internal class JmiTieBreak : Object {
    internal static int compare(string first_sid, Jid first_jid,
            string second_sid, Jid second_jid) {
        int sid_order = compare_octets(first_sid, second_sid);
        if (sid_order != 0) return sid_order;
        return compare_octets(first_jid.to_string(), second_jid.to_string());
    }

    private static int compare_octets(string first, string second) {
        int common = int.min(first.length, second.length);
        for (int i = 0; i < common; i++) {
            uint8 first_octet = (uint8) first[i];
            uint8 second_octet = (uint8) second[i];
            if (first_octet < second_octet) return -1;
            if (first_octet > second_octet) return 1;
        }
        if (first.length < second.length) return -1;
        if (first.length > second.length) return 1;
        return 0;
    }
}

internal class JmiProceedRouting : Object {
    /**
     * Select the local full JID without ever weakening peer-resource binding.
     *
     * XEP-0353 0.8 requires full-JID responses. Older peers can still address
     * proceed to our bare JID; that shape is safe only when it arrived as the
     * direct live delivery for the process which owns the outgoing call.
     */
    internal static Jid? select_destination(Account account, Jid from,
            Jid to, Xep.JingleMessageInitiation.Delivery delivery,
            bool local_call_owner) {
        if (!local_call_owner || from.resourcepart == null ||
                delivery != Xep.JingleMessageInitiation.Delivery.LIVE) {
            return null;
        }
        if (to.equals(account.full_jid)) return account.full_jid;
        if (to.resourcepart == null &&
                to.equals_bare(account.bare_jid)) {
            return account.full_jid;
        }
        return null;
    }
}

/**
 * Account-scoped owner for one live one-to-one XEP-0353 session.
 *
 * This class deliberately contains no UI, media or XMPP side effects. Calls
 * owns those transitions; the registry only makes SID routing and duplicate
 * suppression deterministic.
 */
internal class JmiLiveSessionEntry : Object {
    internal Account account { get; private set; }
    internal Jid peer_bare_jid { get; private set; }
    internal string sid { get; private set; }
    internal Jid proposal_source { get; private set; }
    internal Jid proposal_target { get; private set; }
    internal bool incoming { get; private set; }
    internal Object owner { get; private set; }
    internal bool incoming_video_requested { get; private set; default=false; }

    private bool outgoing_ringing_claimed = false;
    private bool local_proceed_claimed = false;
    private bool outgoing_finish_claimed = false;
    private Jid? reserved_peer_full_jid = null;
    private Jid? reserved_local_full_jid = null;
    private Jid? selected_peer_full_jid = null;
    private Jid? selected_local_full_jid = null;
    private HashSet<string> action_claims = new HashSet<string>();
    private HashSet<string> source_action_claims = new HashSet<string>();
    private ArrayList<StanzaNode> incoming_descriptions =
        new ArrayList<StanzaNode>();

    internal JmiLiveSessionEntry(Account account, Jid peer_bare_jid,
            string sid, Jid proposal_source, Jid proposal_target,
            bool incoming, Object owner) {
        this.account = account;
        this.peer_bare_jid = peer_bare_jid.bare_jid;
        this.sid = sid;
        this.proposal_source = proposal_source;
        this.proposal_target = proposal_target;
        this.incoming = incoming;
        this.owner = owner;
    }

    internal bool matches(Account candidate_account, Jid candidate_peer,
            string candidate_sid) {
        return account.equals(candidate_account) &&
            peer_bare_jid.equals(candidate_peer.bare_jid) &&
            sid == candidate_sid;
    }

    internal bool matches_peer(Account candidate_account, Jid candidate_peer) {
        return account.equals(candidate_account) &&
            peer_bare_jid.equals(candidate_peer.bare_jid);
    }

    internal bool has_sid(Account candidate_account, string candidate_sid) {
        return account.equals(candidate_account) && sid == candidate_sid;
    }

    internal bool same_proposal_source(Jid candidate_source) {
        return proposal_source.equals(candidate_source);
    }

    internal void set_incoming_proposal_details(
            Gee.List<StanzaNode> descriptions, bool video_requested) {
        if (!incoming) return;
        incoming_descriptions.clear();
        incoming_descriptions.add_all(descriptions);
        incoming_video_requested = video_requested;
    }

    internal Gee.List<StanzaNode> copy_incoming_descriptions() {
        var copy = new ArrayList<StanzaNode>();
        copy.add_all(incoming_descriptions);
        return copy;
    }

    internal bool has_incoming_descriptions() {
        return !incoming_descriptions.is_empty;
    }

    internal bool claim_outgoing_ringing() {
        if (outgoing_ringing_claimed) return false;
        outgoing_ringing_claimed = true;
        return true;
    }

    internal bool claim_action_once(
            Xep.JingleMessageInitiation.Action action) {
        string key = ((int) action).to_string();
        if (action_claims.contains(key)) return false;
        action_claims.add(key);
        return true;
    }

    internal bool claim_action_from_source(
            Xep.JingleMessageInitiation.Action action, Jid source) {
        string key = "%d|%s".printf((int) action, source.to_string());
        if (source_action_claims.contains(key)) return false;
        source_action_claims.add(key);
        return true;
    }

    /** Reserve exact endpoints while the media engine publishes proceed. */
    internal bool reserve_local_proceed(Jid peer_full_jid,
            Jid local_full_jid) {
        if (peer_full_jid.resourcepart == null ||
                !peer_full_jid.equals_bare(peer_bare_jid) ||
                local_full_jid.resourcepart == null ||
                !local_full_jid.equals_bare(account.bare_jid)) return false;
        if (local_proceed_claimed) {
            return selected_peer_full_jid != null &&
                selected_local_full_jid != null &&
                ((!) selected_peer_full_jid).equals(peer_full_jid) &&
                ((!) selected_local_full_jid).equals(local_full_jid);
        }
        if (reserved_peer_full_jid != null ||
                reserved_local_full_jid != null) {
            return reserved_peer_full_jid != null &&
                reserved_local_full_jid != null &&
                ((!) reserved_peer_full_jid).equals(peer_full_jid) &&
                ((!) reserved_local_full_jid).equals(local_full_jid);
        }
        reserved_peer_full_jid = peer_full_jid;
        reserved_local_full_jid = local_full_jid;
        return true;
    }

    internal bool commit_local_proceed(Jid peer_full_jid,
            Jid local_full_jid) {
        if (local_proceed_claimed) {
            return selected_peer_full_jid != null &&
                selected_local_full_jid != null &&
                ((!) selected_peer_full_jid).equals(peer_full_jid) &&
                ((!) selected_local_full_jid).equals(local_full_jid);
        }
        if (reserved_peer_full_jid == null ||
                reserved_local_full_jid == null ||
                !((!) reserved_peer_full_jid).equals(peer_full_jid) ||
                !((!) reserved_local_full_jid).equals(local_full_jid)) {
            return false;
        }
        selected_peer_full_jid = peer_full_jid;
        selected_local_full_jid = local_full_jid;
        reserved_peer_full_jid = null;
        reserved_local_full_jid = null;
        local_proceed_claimed = true;
        return true;
    }

    internal void rollback_local_proceed(Jid peer_full_jid,
            Jid local_full_jid) {
        if (local_proceed_claimed || reserved_peer_full_jid == null ||
                reserved_local_full_jid == null ||
                !((!) reserved_peer_full_jid).equals(peer_full_jid) ||
                !((!) reserved_local_full_jid).equals(local_full_jid)) return;
        reserved_peer_full_jid = null;
        reserved_local_full_jid = null;
    }

    internal bool has_committed_proceed() {
        return local_proceed_claimed;
    }

    internal bool selected_endpoints_match(Jid peer_full_jid,
            Jid local_full_jid) {
        return local_proceed_claimed &&
            selected_peer_full_jid != null &&
            selected_local_full_jid != null &&
            ((!) selected_peer_full_jid).equals(peer_full_jid) &&
            ((!) selected_local_full_jid).equals(local_full_jid);
    }

    internal bool selected_external_action_matches(Jid from, Jid to) {
        return selected_endpoints_match(from, to);
    }

    internal bool selected_own_action_matches(Jid from, Jid to) {
        return local_proceed_claimed &&
            selected_peer_full_jid != null &&
            selected_local_full_jid != null &&
            from.equals((!) selected_local_full_jid) &&
            to.equals((!) selected_peer_full_jid);
    }

    /** Validate peer-originated actions before a resource was selected. */
    internal bool pre_proceed_external_action_matches(
            Xep.JingleMessageInitiation.Action action, Jid from, Jid to) {
        if (local_proceed_claimed || reserved_peer_full_jid != null ||
                from.resourcepart == null) return false;
        if (incoming) {
            if (action != Xep.JingleMessageInitiation.Action.RETRACT &&
                    action != Xep.JingleMessageInitiation.Action.FINISH) {
                return false;
            }
            return from.equals(proposal_source) &&
                to.equals_bare(account.bare_jid) &&
                (proposal_target.resourcepart == null ||
                    to.resourcepart == null || to.equals(proposal_target));
        }
        if (action != Xep.JingleMessageInitiation.Action.RINGING &&
                action != Xep.JingleMessageInitiation.Action.REJECT &&
                action != Xep.JingleMessageInitiation.Action.FINISH &&
                action != Xep.JingleMessageInitiation.Action.PROCEED) {
            return false;
        }
        return from.equals_bare(peer_bare_jid) &&
            (to.equals(proposal_source) ||
                (to.resourcepart == null &&
                    to.equals_bare(account.bare_jid)));
    }

    /** Validate a sent Carbon for a proposal owned by another local device. */
    internal bool own_proposal_action_matches(Jid from, Jid to) {
        return !incoming && !local_proceed_claimed &&
            from.equals(proposal_source) &&
            to.equals_bare(peer_bare_jid);
    }

    internal bool own_incoming_response_matches(Jid from, Jid to) {
        return incoming && !local_proceed_claimed &&
            from.resourcepart != null &&
            from.equals_bare(account.bare_jid) &&
            !from.equals(account.full_jid) &&
            to.equals(proposal_source);
    }

    /** Compatibility for the historical reject message addressed to self. */
    internal bool legacy_own_self_reject_matches(Jid from, Jid to) {
        return incoming && !local_proceed_claimed &&
            reserved_peer_full_jid == null &&
            from.resourcepart != null &&
            from.equals_bare(account.bare_jid) &&
            !from.equals(account.full_jid) &&
            to.resourcepart == null &&
            to.equals_bare(account.bare_jid);
    }

    /** Return the full peer target exactly once after proceed was owned. */
    internal Jid? claim_outgoing_finish_target() {
        if (!local_proceed_claimed || outgoing_finish_claimed ||
                selected_peer_full_jid == null) return null;
        outgoing_finish_claimed = true;
        return selected_peer_full_jid;
    }

    internal Jid? selected_peer_for_migration() {
        if (!local_proceed_claimed || selected_peer_full_jid == null) {
            return null;
        }
        return selected_peer_full_jid;
    }

    internal Jid? selected_local_for_migration() {
        if (!local_proceed_claimed || selected_local_full_jid == null) {
            return null;
        }
        return selected_local_full_jid;
    }
}

internal class JmiTerminalTombstone : Object {
    internal Account account { get; private set; }
    internal Jid peer_bare_jid { get; private set; }
    internal string sid { get; private set; }
    internal Jid proposal_source { get; private set; }
    internal int64 created_at_us { get; private set; }

    internal JmiTerminalTombstone(Account account, Jid peer, string sid,
            Jid proposal_source, int64 created_at_us) {
        this.account = account;
        this.peer_bare_jid = peer.bare_jid;
        this.sid = sid;
        this.proposal_source = proposal_source;
        this.created_at_us = created_at_us;
    }

    internal bool matches(Account candidate_account, Jid candidate_peer,
            string candidate_sid) {
        return account.equals(candidate_account) &&
            peer_bare_jid.equals(candidate_peer.bare_jid) &&
            sid == candidate_sid;
    }

    internal bool has_sid(Account candidate_account, string candidate_sid) {
        return account.equals(candidate_account) && sid == candidate_sid;
    }
}

internal class JmiLiveSessionRegistry : Object {
    internal const int DEFAULT_MAX_TOMBSTONES = 512;
    internal const int64 DEFAULT_RETENTION_US = 24 * TimeSpan.HOUR;

    private ArrayList<JmiLiveSessionEntry> entries =
        new ArrayList<JmiLiveSessionEntry>();
    private ArrayList<JmiTerminalTombstone> tombstones =
        new ArrayList<JmiTerminalTombstone>();
    private int max_tombstones;
    private int64 retention_us;

    internal JmiLiveSessionRegistry(
            int max_tombstones = DEFAULT_MAX_TOMBSTONES,
            int64 retention_us = DEFAULT_RETENTION_US) {
        this.max_tombstones = int.max(1, max_tombstones);
        this.retention_us = int64.max(1, retention_us);
    }

    internal int size { get { return entries.size; } }
    internal int tombstone_size { get { return tombstones.size; } }

    internal JmiProposalDisposition inspect_proposal(Account account,
            Jid peer, string sid, Jid proposal_source) {
        purge_expired_tombstones(GLib.get_monotonic_time());
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.matches(account, peer, sid)) {
                return entry.same_proposal_source(proposal_source)
                    ? JmiProposalDisposition.DUPLICATE
                    : JmiProposalDisposition.CONFLICT;
            }
        }
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.matches(account, peer, sid)) {
                return JmiProposalDisposition.TERMINAL;
            }
        }
        // Exact live or terminal ownership always wins over the broader
        // one-active-SID-per-peer conflict rule. Otherwise a replay of the
        // superseded SID could be mistaken for a request to migrate back.
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.has_sid(account, sid) ||
                    entry.matches_peer(account, peer)) {
                return JmiProposalDisposition.CONFLICT;
            }
        }
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.has_sid(account, sid)) {
                return JmiProposalDisposition.TERMINAL;
            }
        }
        return JmiProposalDisposition.NEW;
    }

    internal JmiLiveSessionEntry? register(Account account, Jid peer,
            string sid, Jid proposal_source, Jid proposal_target,
            bool incoming, Object owner) {
        if (sid.strip() == "" || inspect_proposal(account, peer, sid,
                proposal_source) != JmiProposalDisposition.NEW) return null;
        return add_entry(account, peer, sid, proposal_source, proposal_target,
            incoming, owner);
    }

    /** Rebind an authorised unresolved MAM proposal after a stream change. */
    internal JmiLiveSessionEntry? register_recovered(Account account,
            Jid peer, string sid, Jid proposal_source, Jid proposal_target,
            Object owner) {
        if (sid.strip() == "") return null;
        purge_expired_tombstones(GLib.get_monotonic_time());
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.matches(account, peer, sid) && entry.owner == owner &&
                    entry.same_proposal_source(proposal_source)) return entry;
            if (entry.has_sid(account, sid) ||
                    entry.matches_peer(account, peer)) return null;
        }
        var remove = new ArrayList<JmiTerminalTombstone>();
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.matches(account, peer, sid)) {
                remove.add(tombstone);
            } else if (tombstone.has_sid(account, sid)) {
                return null;
            }
        }
        tombstones.remove_all(remove);
        return add_entry(account, peer, sid, proposal_source,
            proposal_target, true, owner);
    }

    /** Used only after the deterministic tie-break winner replaced its owner. */
    internal JmiLiveSessionEntry? register_after_tie_break(Account account,
            Jid peer, string sid, Jid proposal_source, Jid proposal_target,
            bool incoming, Object owner) {
        if (sid.strip() == "") return null;
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.matches_peer(account, peer) ||
                    entry.has_sid(account, sid)) return null;
        }
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.has_sid(account, sid)) return null;
        }
        return add_entry(account, peer, sid, proposal_source, proposal_target,
            incoming, owner);
    }

    /**
     * Atomically transfers one active direct-call owner to a newly proposed SID.
     * The caller stages the signaling-only engine session first, so a failure
     * here leaves the old media owner untouched.
     */
    internal JmiLiveSessionEntry? replace_for_migration(
            JmiLiveSessionEntry existing, string sid, Jid proposal_source,
            Jid proposal_target, Object owner) {
        if (!entries.contains(existing) || existing.owner != owner ||
                sid.strip() == "" || sid == existing.sid ||
                proposal_source.resourcepart == null ||
                !proposal_source.equals_bare(existing.peer_bare_jid)) {
            return null;
        }
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry == existing) continue;
            if (entry.has_sid(existing.account, sid) ||
                    entry.matches_peer(existing.account,
                        existing.peer_bare_jid)) return null;
        }
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.has_sid(existing.account, sid)) return null;
        }

        Account account = existing.account;
        Jid peer = existing.peer_bare_jid;
        string old_sid = existing.sid;
        Jid old_source = existing.proposal_source;
        entries.remove(existing);
        remember_terminal(account, peer, old_sid, old_source);
        return add_entry(account, peer, sid, proposal_source, proposal_target,
            true, owner);
    }

    private JmiLiveSessionEntry add_entry(Account account, Jid peer,
            string sid, Jid proposal_source, Jid proposal_target,
            bool incoming, Object owner) {
        var entry = new JmiLiveSessionEntry(account, peer, sid,
            proposal_source, proposal_target, incoming, owner);
        entries.add(entry);
        return entry;
    }

    internal JmiLiveSessionEntry? find(Account account, Jid peer,
            string sid) {
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.matches(account, peer, sid)) return entry;
        }
        return null;
    }

    internal JmiLiveSessionEntry? find_by_peer(Account account, Jid peer) {
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.matches_peer(account, peer)) return entry;
        }
        return null;
    }

    internal JmiLiveSessionEntry? find_by_owner(Object owner) {
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.owner == owner) return entry;
        }
        return null;
    }

    internal JmiLiveSessionEntry? find_unique_by_sid(Account account,
            string sid, bool incoming_only, out bool ambiguous) {
        JmiLiveSessionEntry? matched = null;
        ambiguous = false;
        foreach (JmiLiveSessionEntry entry in entries) {
            if (!entry.has_sid(account, sid) ||
                    (incoming_only && !entry.incoming)) continue;
            if (matched != null) {
                ambiguous = true;
                return null;
            }
            matched = entry;
        }
        return matched;
    }

    internal void remember_terminal(Account account, Jid peer, string sid,
            Jid proposal_source) {
        if (sid.strip() == "") return;
        int64 now_us = GLib.get_monotonic_time();
        purge_expired_tombstones(now_us);
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.matches(account, peer, sid) &&
                    tombstone.proposal_source.equals(proposal_source)) return;
        }
        tombstones.add(new JmiTerminalTombstone(account, peer, sid,
            proposal_source, now_us));
        trim_tombstones();
    }

    internal void remove_owner(Object owner) {
        var removed = new ArrayList<JmiLiveSessionEntry>();
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.owner != owner) continue;
            remember_terminal(entry.account, entry.peer_bare_jid, entry.sid,
                entry.proposal_source);
            removed.add(entry);
        }
        entries.remove_all(removed);
    }

    /** Disconnect ends live ownership, but preserves bounded replay fences. */
    internal void clear_account(Account account) {
        var removed = new ArrayList<JmiLiveSessionEntry>();
        foreach (JmiLiveSessionEntry entry in entries) {
            if (!entry.account.equals(account)) continue;
            remember_terminal(entry.account, entry.peer_bare_jid, entry.sid,
                entry.proposal_source);
            removed.add(entry);
        }
        entries.remove_all(removed);
    }

    /** Account removal may release both live and terminal ownership. */
    internal void forget_account(Account account) {
        var removed_entries = new ArrayList<JmiLiveSessionEntry>();
        foreach (JmiLiveSessionEntry entry in entries) {
            if (entry.account.equals(account)) removed_entries.add(entry);
        }
        entries.remove_all(removed_entries);

        var removed_tombstones = new ArrayList<JmiTerminalTombstone>();
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (tombstone.account.equals(account)) {
                removed_tombstones.add(tombstone);
            }
        }
        tombstones.remove_all(removed_tombstones);
    }

    internal void purge_expired_tombstones_for_test(int64 now_us) {
        purge_expired_tombstones(now_us);
    }

    private void purge_expired_tombstones(int64 now_us) {
        var expired = new ArrayList<JmiTerminalTombstone>();
        foreach (JmiTerminalTombstone tombstone in tombstones) {
            if (now_us - tombstone.created_at_us >= retention_us) {
                expired.add(tombstone);
            }
        }
        tombstones.remove_all(expired);
    }

    private void trim_tombstones() {
        while (tombstones.size > max_tombstones) {
            tombstones.remove_at(0);
        }
    }
}

}
