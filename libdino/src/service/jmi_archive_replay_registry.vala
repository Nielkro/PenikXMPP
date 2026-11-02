using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino {

internal enum JmiArchiveReplayDecision {
    PENDING,
    PUBLISH,
    DROP
}

/** Immutable history projection produced without creating a live CallState. */
internal class JmiArchiveReplayResult : Object {
    internal Account account { get; private set; }
    internal Jid peer { get; private set; }
    internal Jid proposal_source { get; private set; }
    internal Jid proposal_target { get; private set; }
    internal string sid { get; private set; }
    internal bool direction { get; private set; }
    internal bool video_requested { get; private set; }
    internal Call.State state { get; private set; }
    internal DateTime started_at { get; private set; }
    internal DateTime ended_at { get; private set; }
    internal Xep.JingleMessageInitiation.JmiReason? reason {
        get; private set;
    }
    internal bool tie_break { get; private set; }
    internal string? migrated_to_sid { get; private set; }
    internal bool actionable { get; private set; }
    internal Gee.List<StanzaNode> descriptions { get; private set; }

    internal JmiArchiveReplayResult(Account account, Jid peer,
            Jid proposal_source, Jid proposal_target, string sid,
            bool direction, bool video_requested, Call.State state,
            DateTime started_at, DateTime ended_at,
            Xep.JingleMessageInitiation.JmiReason? reason = null,
            bool tie_break = false, string? migrated_to_sid = null,
            bool actionable = false,
            Gee.List<StanzaNode>? descriptions = null) {
        this.account = account;
        this.peer = peer.bare_jid;
        this.proposal_source = proposal_source;
        this.proposal_target = proposal_target;
        this.sid = sid;
        this.direction = direction;
        this.video_requested = video_requested;
        this.state = state;
        this.started_at = started_at;
        this.ended_at = ended_at;
        this.reason = reason;
        this.tie_break = tie_break;
        this.migrated_to_sid = migrated_to_sid;
        this.actionable = actionable;
        var descriptions_copy = new ArrayList<StanzaNode>();
        if (descriptions != null) descriptions_copy.add_all((!) descriptions);
        this.descriptions = descriptions_copy;
    }
}

/** One bounded wire observation retained until its proposal defines roles. */
internal class JmiArchiveActionObservation : Object {
    internal Jid from { get; private set; }
    internal Jid to { get; private set; }
    internal Xep.JingleMessageInitiation.Action action { get; private set; }
    internal DateTime timestamp { get; private set; }
    internal bool video_requested { get; private set; }
    internal Xep.JingleMessageInitiation.JmiReason? reason {
        get; private set;
    }
    internal bool tie_break { get; private set; }
    internal string? migrated_to_sid { get; private set; }
    internal Gee.List<StanzaNode> descriptions { get; private set; }

    internal JmiArchiveActionObservation(Jid from, Jid to,
            Xep.JingleMessageInitiation.Action action, DateTime timestamp,
            bool video_requested,
            Xep.JingleMessageInitiation.JmiReason? reason,
            bool tie_break, string? migrated_to_sid,
            Gee.List<StanzaNode>? descriptions = null) {
        this.from = from;
        this.to = to;
        this.action = action;
        this.timestamp = timestamp;
        this.video_requested = video_requested;
        this.reason = reason;
        this.tie_break = tie_break;
        this.migrated_to_sid = migrated_to_sid;
        var descriptions_copy = new ArrayList<StanzaNode>();
        if (descriptions != null) descriptions_copy.add_all((!) descriptions);
        this.descriptions = descriptions_copy;
    }

    internal bool same_wire_event(JmiArchiveActionObservation other) {
        return action == other.action && from.equals(other.from) &&
            to.equals(other.to) && timestamp.compare(other.timestamp) == 0 &&
            video_requested == other.video_requested &&
            descriptions_equal(descriptions, other.descriptions) &&
            nullable_string_equal(migrated_to_sid, other.migrated_to_sid) &&
            reason_equal(reason, other.reason) && tie_break == other.tie_break;
    }

    private static bool reason_equal(
            Xep.JingleMessageInitiation.JmiReason? first,
            Xep.JingleMessageInitiation.JmiReason? second) {
        if (first == null || second == null) return first == second;
        return nullable_string_equal(((!) first).condition,
                ((!) second).condition) &&
            nullable_string_equal(((!) first).text, ((!) second).text);
    }

    private static bool nullable_string_equal(string? first, string? second) {
        if (first == null || second == null) return first == second;
        return (!) first == (!) second;
    }

    private static bool descriptions_equal(Gee.List<StanzaNode> first,
            Gee.List<StanzaNode> second) {
        if (first.size != second.size) return false;
        try {
            for (int index = 0; index < first.size; index++) {
                if (first[index].to_xml() !=
                        second[index].to_xml()) return false;
            }
        } catch (IOError error) {
            return false;
        }
        return true;
    }
}

internal class JmiArchiveReplayEntry : Object {
    internal Account account { get; private set; }
    internal Jid peer { get; private set; }
    internal string sid { get; private set; }
    internal uint64 sequence { get; private set; }

    private int max_observations;
    private ArrayList<JmiArchiveActionObservation> observations =
        new ArrayList<JmiArchiveActionObservation>();
    private JmiArchiveActionObservation? proposal = null;
    private bool actionable_published = false;
    private bool observations_truncated = false;

    internal JmiArchiveReplayEntry(Account account, Jid peer, string sid,
            uint64 sequence, int max_observations =
                JmiArchiveReplayRegistry.DEFAULT_MAX_OBSERVATIONS_PER_ENTRY) {
        this.account = account;
        this.peer = peer.bare_jid;
        this.sid = sid;
        this.sequence = sequence;
        // Proposal, selected proceed, pre-proceed terminal and selected finish
        // are the maximum set of independent resolution anchors.
        this.max_observations = int.max(4, max_observations);
    }

    internal bool matches(Account candidate_account, Jid candidate_peer,
            string candidate_sid) {
        return account.equals(candidate_account) &&
            peer.equals(candidate_peer.bare_jid) && sid == candidate_sid;
    }

    internal bool has_sid(Account candidate_account, string candidate_sid) {
        return account.equals(candidate_account) && sid == candidate_sid;
    }

    internal bool observe(Jid from, Jid to,
            Xep.JingleMessageInitiation.Action action, DateTime timestamp,
            bool proposal_video_requested,
            Xep.JingleMessageInitiation.JmiReason? reason = null,
            bool tie_break = false, string? migrated_to_sid = null,
            Gee.List<StanzaNode>? descriptions = null) {
        if (!metadata_shape_is_valid(action, reason, tie_break,
                migrated_to_sid)) return false;

        var observation = new JmiArchiveActionObservation(from, to, action,
            timestamp, proposal_video_requested, reason, tie_break,
            migrated_to_sid, descriptions);
        if (action == Xep.JingleMessageInitiation.Action.PROPOSE) {
            return observe_proposal(observation);
        }
        if (!coarse_endpoint_shape_is_valid(observation)) return false;
        if (proposal != null && !role_matches_proposal(observation)) {
            return false;
        }
        return add_observation(observation);
    }

    internal JmiArchiveReplayDecision resolve(DateTime now,
            int64 retention_seconds, out JmiArchiveReplayResult? result) {
        result = null;
        if (proposal == null) {
            return JmiArchiveReplayDecision.PENDING;
        }

        JmiArchiveActionObservation proposal_observation = (!) proposal;
        DateTime started_at = proposal_observation.timestamp;
        JmiArchiveActionObservation? proceed = earliest_proceed(started_at);
        JmiArchiveActionObservation? pre_proceed_terminal =
            earliest_pre_proceed_terminal(started_at, proceed);
        JmiArchiveActionObservation? finish = proceed != null
            ? earliest_finish_for_selected_endpoints((!) proceed)
            : earliest_finish_without_selected_responder(started_at);
        JmiArchiveActionObservation? terminal = earliest_observation(
            pre_proceed_terminal, finish);
        bool established = proceed != null && pre_proceed_terminal == null;
        Call.State final_state;
        DateTime ended_at;

        if (terminal != null) {
            JmiArchiveActionObservation terminal_observation = (!) terminal;
            ended_at = terminal_observation.timestamp;
            if (terminal_observation.tie_break) {
                final_state = Call.State.ENDED;
            } else if (terminal_observation.action ==
                    Xep.JingleMessageInitiation.Action.FINISH || established) {
                final_state = Call.State.ENDED;
            } else if (terminal_observation.action ==
                    Xep.JingleMessageInitiation.Action.REJECT) {
                final_state = Call.State.DECLINED;
            } else {
                final_state = Call.State.MISSED;
            }
        } else if (now.to_unix() - started_at.to_unix() >=
                retention_seconds) {
            ended_at = started_at.add_seconds(retention_seconds);
            final_state = established ? Call.State.ENDED : Call.State.MISSED;
        } else {
            return JmiArchiveReplayDecision.PENDING;
        }

        result = new JmiArchiveReplayResult(account, peer,
            proposal_observation.from, proposal_observation.to, sid,
            proposal_is_outgoing(), proposal_observation.video_requested,
            final_state, started_at, ended_at,
            terminal != null ? ((!) terminal).reason : null,
            terminal != null && ((!) terminal).tie_break,
            terminal != null ? ((!) terminal).migrated_to_sid : null,
            false, proposal_observation.descriptions);
        return JmiArchiveReplayDecision.PUBLISH;
    }

    /** Publish one still-current incoming proposal without consuming it. */
    internal bool take_actionable_snapshot(DateTime now,
            int64 retention_seconds, out JmiArchiveReplayResult? result) {
        result = null;
        if (actionable_published ||
                !permits_persisted_recovery(now, retention_seconds)) {
            return false;
        }

        JmiArchiveActionObservation proposed = (!) proposal;
        DateTime expires_at = proposed.timestamp.add_seconds(
            retention_seconds);
        result = new JmiArchiveReplayResult(account, peer, proposed.from,
            proposed.to, sid, Call.DIRECTION_INCOMING,
            proposed.video_requested, Call.State.RINGING,
            proposed.timestamp, expires_at, null, false, null, true,
            proposed.descriptions);
        actionable_published = true;
        return true;
    }

    /** Whether complete replay evidence still describes an unanswered call. */
    internal bool permits_persisted_recovery(DateTime now,
            int64 retention_seconds) {
        if (observations_truncated || proposal == null ||
                proposal_is_outgoing()) return false;

        JmiArchiveActionObservation proposed = (!) proposal;
        if (proposed.descriptions.is_empty ||
                now.to_unix() < proposed.timestamp.to_unix() ||
                now.to_unix() - proposed.timestamp.to_unix() >=
                    retention_seconds) return false;
        JmiArchiveActionObservation? proceed = earliest_proceed(
            proposed.timestamp);
        return proceed == null && earliest_pre_proceed_terminal(
                proposed.timestamp, proceed) == null &&
            earliest_finish_without_selected_responder(
                proposed.timestamp) == null;
    }

    internal bool is_orphan_expired(DateTime now, int64 retention_seconds) {
        DateTime? latest = latest_observed();
        return latest != null &&
            now.to_unix() - ((!) latest).to_unix() >= retention_seconds;
    }

    internal int64 expiry_delay_seconds(DateTime now,
            int64 retention_seconds) {
        DateTime? anchor = proposal != null
            ? ((!) proposal).timestamp : latest_observed();
        if (anchor == null) return -1;
        return int64.min(retention_seconds,
            ((!) anchor).to_unix() + retention_seconds - now.to_unix());
    }

    private bool observe_proposal(
            owned JmiArchiveActionObservation candidate) {
        if (!proposal_shape_is_valid(candidate)) return false;
        // Routing and archive copies may expose a recipient resource, but a
        // proposal selects only the initiator resource. Keep one canonical
        // bare target so those copies collapse without selecting a responder.
        candidate = new JmiArchiveActionObservation(candidate.from,
            candidate.to.bare_jid, candidate.action, candidate.timestamp,
            candidate.video_requested, null, false, null,
            candidate.descriptions);
        if (proposal != null) {
            JmiArchiveActionObservation existing = (!) proposal;
            if (!existing.from.equals(candidate.from) ||
                    !existing.to.equals(candidate.to) ||
                    existing.video_requested != candidate.video_requested ||
                    !proposal_descriptions_equal(existing.descriptions,
                        candidate.descriptions)) return false;
            bool earlier_timestamp =
                candidate.timestamp.compare(existing.timestamp) < 0;
            if (!earlier_timestamp) return true;
            observations.remove(existing);
            candidate = new JmiArchiveActionObservation(existing.from,
                existing.to, existing.action,
                candidate.timestamp, existing.video_requested,
                null, false, null, existing.descriptions);
        }
        proposal = candidate;
        observations.add(candidate);
        prune_against_proposal();
        trim_observations();
        return true;
    }

    private static bool proposal_descriptions_equal(
            Gee.List<StanzaNode> first, Gee.List<StanzaNode> second) {
        if (first.size != second.size) return false;
        try {
            for (int index = 0; index < first.size; index++) {
                if (first[index].to_xml() !=
                        second[index].to_xml()) return false;
            }
        } catch (IOError error) {
            return false;
        }
        return true;
    }

    private bool proposal_shape_is_valid(
            JmiArchiveActionObservation candidate) {
        if (candidate.from.resourcepart == null) return false;
        bool from_own = candidate.from.equals_bare(account.bare_jid);
        bool to_own = candidate.to.equals_bare(account.bare_jid);
        if (from_own == to_own) return false;
        return from_own
            ? candidate.to.equals_bare(peer)
            : candidate.from.equals_bare(peer) &&
                candidate.to.equals_bare(account.bare_jid);
    }

    private bool proposal_is_outgoing() {
        return proposal != null &&
            ((!) proposal).from.equals_bare(account.bare_jid);
    }

    private bool coarse_endpoint_shape_is_valid(
            JmiArchiveActionObservation observation) {
        bool from_own = observation.from.equals_bare(account.bare_jid);
        bool to_own = observation.to.equals_bare(account.bare_jid);
        switch (observation.action) {
            case Xep.JingleMessageInitiation.Action.RINGING:
            case Xep.JingleMessageInitiation.Action.PROCEED:
            case Xep.JingleMessageInitiation.Action.REJECT:
            case Xep.JingleMessageInitiation.Action.FINISH:
                return from_own != to_own &&
                    observation.from.resourcepart != null &&
                    observation.to.resourcepart != null;
            case Xep.JingleMessageInitiation.Action.RETRACT:
                return from_own != to_own &&
                    observation.from.resourcepart != null &&
                    observation.to.resourcepart == null;
            case Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT:
                return from_own && to_own &&
                    observation.from.resourcepart != null &&
                    observation.to.resourcepart == null;
            case Xep.JingleMessageInitiation.Action.PROPOSE:
                return false;
        }
        assert_not_reached();
    }

    private bool role_matches_proposal(
            JmiArchiveActionObservation observation) {
        JmiArchiveActionObservation proposed = (!) proposal;
        bool outgoing = proposal_is_outgoing();
        switch (observation.action) {
            case Xep.JingleMessageInitiation.Action.RINGING:
            case Xep.JingleMessageInitiation.Action.PROCEED:
            case Xep.JingleMessageInitiation.Action.REJECT:
                return observation.to.equals(proposed.from) &&
                    (outgoing
                        ? observation.from.equals_bare(peer)
                        : observation.from.equals_bare(account.bare_jid));
            case Xep.JingleMessageInitiation.Action.RETRACT:
                return observation.from.equals(proposed.from) &&
                    observation.to.equals(outgoing
                        ? peer : account.bare_jid);
            case Xep.JingleMessageInitiation.Action.FINISH:
                return (observation.from.equals(proposed.from) &&
                        observation.to.resourcepart != null &&
                        observation.to.equals_bare(outgoing
                            ? peer : account.bare_jid)) ||
                    (observation.to.equals(proposed.from) &&
                        observation.from.resourcepart != null &&
                        observation.from.equals_bare(outgoing
                            ? peer : account.bare_jid));
            case Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT:
                return !outgoing &&
                    observation.from.equals_bare(account.bare_jid) &&
                    observation.to.equals(account.bare_jid);
            case Xep.JingleMessageInitiation.Action.PROPOSE:
                return observation.from.equals(proposed.from) &&
                    observation.to.equals(proposed.to);
        }
        assert_not_reached();
    }

    private JmiArchiveActionObservation? earliest_proceed(
            DateTime started_at) {
        JmiArchiveActionObservation? selected = null;
        foreach (JmiArchiveActionObservation observation in observations) {
            if ((observation.action !=
                        Xep.JingleMessageInitiation.Action.PROCEED &&
                    observation.action !=
                        Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT) ||
                    observation.timestamp.compare(started_at) < 0 ||
                    !role_matches_proposal(observation)) continue;
            if (selected == null || observation_compare(observation,
                    (!) selected) < 0) selected = observation;
        }
        return selected;
    }

    private JmiArchiveActionObservation? earliest_pre_proceed_terminal(
            DateTime started_at,
            JmiArchiveActionObservation? proceed) {
        JmiArchiveActionObservation? selected = null;
        foreach (JmiArchiveActionObservation observation in observations) {
            if ((observation.action !=
                        Xep.JingleMessageInitiation.Action.REJECT &&
                    observation.action !=
                        Xep.JingleMessageInitiation.Action.RETRACT) ||
                    observation.timestamp.compare(started_at) < 0 ||
                    !role_matches_proposal(observation)) continue;
            if (proceed != null && observation.timestamp.compare(
                    ((!) proceed).timestamp) >= 0) continue;
            if (selected == null || observation_compare(observation,
                    (!) selected) < 0) selected = observation;
        }
        return selected;
    }

    private JmiArchiveActionObservation?
            earliest_finish_for_selected_endpoints(
                JmiArchiveActionObservation proceed) {
        JmiArchiveActionObservation? selected = null;
        JmiArchiveActionObservation proposed = (!) proposal;
        Jid selected_initiator = proposed.from;
        Jid selected_responder = proceed.from;
        foreach (JmiArchiveActionObservation observation in observations) {
            if (observation.action !=
                        Xep.JingleMessageInitiation.Action.FINISH ||
                    observation.timestamp.compare(proceed.timestamp) <= 0 ||
                    !role_matches_proposal(observation)) continue;
            bool selected_endpoints =
                (observation.from.equals(selected_initiator) &&
                    observation.to.equals(selected_responder)) ||
                (observation.from.equals(selected_responder) &&
                    observation.to.equals(selected_initiator));
            if (!selected_endpoints) continue;
            if (selected == null || observation_compare(observation,
                    (!) selected) < 0) selected = observation;
        }
        return selected;
    }

    /** A complete finish is authoritative even if MAM omitted proceed. */
    private JmiArchiveActionObservation?
            earliest_finish_without_selected_responder(DateTime started_at) {
        JmiArchiveActionObservation? selected = null;
        foreach (JmiArchiveActionObservation observation in observations) {
            if (observation.action !=
                        Xep.JingleMessageInitiation.Action.FINISH ||
                    observation.timestamp.compare(started_at) < 0 ||
                    !role_matches_proposal(observation)) continue;
            if (selected == null || observation_compare(observation,
                    (!) selected) < 0) selected = observation;
        }
        return selected;
    }

    private static JmiArchiveActionObservation? earliest_observation(
            JmiArchiveActionObservation? first,
            JmiArchiveActionObservation? second) {
        if (first == null) return second;
        if (second == null) return first;
        return observation_compare((!) first, (!) second) <= 0
            ? first : second;
    }

    private bool add_observation(JmiArchiveActionObservation candidate) {
        foreach (JmiArchiveActionObservation observation in observations) {
            if (observation.same_wire_event(candidate)) return true;
        }
        observations.add(candidate);
        trim_observations();
        return observations.contains(candidate);
    }

    private void prune_against_proposal() {
        var invalid = new ArrayList<JmiArchiveActionObservation>();
        foreach (JmiArchiveActionObservation observation in observations) {
            if (observation == proposal) continue;
            if (!role_matches_proposal(observation)) invalid.add(observation);
        }
        observations.remove_all(invalid);
    }

    private void trim_observations() {
        while (observations.size > max_observations) {
            int remove_index = -1;
            for (int index = 0; index < observations.size; index++) {
                JmiArchiveActionObservation candidate = observations[index];
                if (is_resolution_anchor(candidate)) continue;
                if (remove_index < 0 || observation_less_valuable(candidate,
                        observations[remove_index])) remove_index = index;
            }
            if (remove_index < 0) return;
            observations.remove_at(remove_index);
            observations_truncated = true;
        }
    }

    /** Preserve the observations which currently define the call phase. */
    private bool is_resolution_anchor(
            JmiArchiveActionObservation observation) {
        if (proposal == null) return false;
        JmiArchiveActionObservation proposed = (!) proposal;
        if (observation == proposed) return true;

        JmiArchiveActionObservation? proceed = earliest_proceed(
            proposed.timestamp);
        JmiArchiveActionObservation? pre_proceed_terminal =
            earliest_pre_proceed_terminal(proposed.timestamp, proceed);
        JmiArchiveActionObservation? finish = proceed != null
            ? earliest_finish_for_selected_endpoints((!) proceed)
            : earliest_finish_without_selected_responder(proposed.timestamp);
        return (proceed != null && observation == (!) proceed) ||
            (pre_proceed_terminal != null &&
                observation == (!) pre_proceed_terminal) ||
            (finish != null && observation == (!) finish);
    }

    private bool observation_less_valuable(
            JmiArchiveActionObservation candidate,
            JmiArchiveActionObservation retained) {
        int candidate_priority = retention_priority(candidate.action);
        int retained_priority = retention_priority(retained.action);
        if (candidate_priority != retained_priority) {
            return candidate_priority > retained_priority;
        }
        if (proposal == null &&
                candidate.action ==
                    Xep.JingleMessageInitiation.Action.FINISH &&
                retained.action ==
                    Xep.JingleMessageInitiation.Action.FINISH) {
            int candidate_metadata = finish_metadata_priority(candidate);
            int retained_metadata = finish_metadata_priority(retained);
            if (candidate_metadata != retained_metadata) {
                return candidate_metadata > retained_metadata;
            }
            // A finish must follow its proposal. Before roles are known, keep
            // the newest candidate so a late MAM proposal can still select it.
            return observation_compare(candidate, retained) < 0;
        }
        return observation_compare(candidate, retained) > 0;
    }

    private static int finish_metadata_priority(
            JmiArchiveActionObservation observation) {
        if (observation.migrated_to_sid != null) return 0;
        if (observation.reason != null) return 1;
        return 2;
    }

    private static int retention_priority(
            Xep.JingleMessageInitiation.Action action) {
        switch (action) {
            case Xep.JingleMessageInitiation.Action.PROPOSE: return 0;
            // Before the proposal arrives, roles are still unknown. Preserve
            // the phase boundary and a finish ahead of rejection noise so a
            // later MAM page can still reconstruct the selected endpoints.
            case Xep.JingleMessageInitiation.Action.PROCEED:
            case Xep.JingleMessageInitiation.Action.LEGACY_ACCEPT:
            case Xep.JingleMessageInitiation.Action.FINISH:
                return 1;
            case Xep.JingleMessageInitiation.Action.REJECT:
            case Xep.JingleMessageInitiation.Action.RETRACT: return 2;
            case Xep.JingleMessageInitiation.Action.RINGING: return 3;
        }
        assert_not_reached();
    }

    private static int observation_compare(
            JmiArchiveActionObservation first,
            JmiArchiveActionObservation second) {
        int timestamp_order = first.timestamp.compare(second.timestamp);
        if (timestamp_order != 0) return timestamp_order;
        int action_order = (int) first.action - (int) second.action;
        if (action_order != 0) return action_order;
        int source_order = strcmp(first.from.to_string(),
            second.from.to_string());
        if (source_order != 0) return source_order;
        int target_order = strcmp(first.to.to_string(),
            second.to.to_string());
        if (target_order != 0) return target_order;
        if (first.tie_break != second.tie_break) {
            return first.tie_break ? -1 : 1;
        }
        int reason_order = reason_compare(first.reason, second.reason);
        if (reason_order != 0) return reason_order;
        return nullable_string_compare(first.migrated_to_sid,
            second.migrated_to_sid);
    }

    private static int reason_compare(
            Xep.JingleMessageInitiation.JmiReason? first,
            Xep.JingleMessageInitiation.JmiReason? second) {
        if (first == null || second == null) {
            if (first == second) return 0;
            return first != null ? -1 : 1;
        }
        int condition_order = nullable_string_compare(((!) first).condition,
            ((!) second).condition);
        if (condition_order != 0) return condition_order;
        return nullable_string_compare(((!) first).text, ((!) second).text);
    }

    private static int nullable_string_compare(string? first, string? second) {
        if (first == null || second == null) {
            if (first == second) return 0;
            return first != null ? -1 : 1;
        }
        return strcmp((!) first, (!) second);
    }

    private DateTime? latest_observed() {
        DateTime? latest = null;
        foreach (JmiArchiveActionObservation observation in observations) {
            if (latest == null || observation.timestamp.compare(
                    (!) latest) > 0) latest = observation.timestamp;
        }
        return latest;
    }

    private bool metadata_shape_is_valid(
            Xep.JingleMessageInitiation.Action action,
            Xep.JingleMessageInitiation.JmiReason? reason,
            bool tie_break, string? migrated_to_sid) {
        if (reason != null &&
                action != Xep.JingleMessageInitiation.Action.REJECT &&
                action != Xep.JingleMessageInitiation.Action.RETRACT &&
                action != Xep.JingleMessageInitiation.Action.FINISH) {
            return false;
        }
        if (tie_break &&
                action != Xep.JingleMessageInitiation.Action.REJECT &&
                action != Xep.JingleMessageInitiation.Action.RETRACT) {
            return false;
        }
        if (migrated_to_sid != null &&
                (action != Xep.JingleMessageInitiation.Action.FINISH ||
                    ((!) migrated_to_sid).strip() == "" ||
                    ((!) migrated_to_sid).strip() == sid)) {
            return false;
        }
        return true;
    }
}

internal class JmiArchiveReplayStream : Object {
    internal Account account { get; private set; }
    internal Object stream_owner { get; private set; }
    internal bool settled { get; set; default=false; }
    internal bool overflowed { get; set; default=false; }

    internal JmiArchiveReplayStream(Account account, Object stream_owner) {
        this.account = account;
        this.stream_owner = stream_owner;
    }
}

/**
 * Bounded, stream-fenced reconstruction of archived one-to-one JMI actions.
 *
 * It owns no UI, database or media object. Results leave the registry only
 * after a successful account catch-up, and live follow-ups may only complete
 * an already observed archived proposal.
 */
internal class JmiArchiveReplayRegistry : Object {
    internal const int DEFAULT_MAX_ENTRIES = 512;
    internal const int DEFAULT_MAX_OBSERVATIONS_PER_ENTRY = 32;
    internal const int64 DEFAULT_RETENTION_SECONDS = 24 * 60 * 60;

    private ArrayList<JmiArchiveReplayStream> streams =
        new ArrayList<JmiArchiveReplayStream>();
    private ArrayList<JmiArchiveReplayEntry> entries =
        new ArrayList<JmiArchiveReplayEntry>();
    private int max_entries;
    private int max_observations_per_entry;
    private int64 retention_seconds;
    private uint64 next_sequence = 1;

    internal JmiArchiveReplayRegistry(
            int max_entries = DEFAULT_MAX_ENTRIES,
            int64 retention_seconds = DEFAULT_RETENTION_SECONDS,
            int max_observations_per_entry =
                DEFAULT_MAX_OBSERVATIONS_PER_ENTRY) {
        this.max_entries = int.max(1, max_entries);
        this.retention_seconds = int64.max(1, retention_seconds);
        this.max_observations_per_entry =
            int.max(4, max_observations_per_entry);
    }

    internal int size { get { return entries.size; } }

    internal void begin_stream(Account account, Object stream_owner) {
        clear_account(account);
        streams.add(new JmiArchiveReplayStream(account, stream_owner));
    }

    internal bool observe_archive(Account account, Object stream_owner,
            Jid from, Jid to, string sid,
            Xep.JingleMessageInitiation.Action action, DateTime timestamp,
            bool video_requested,
            Xep.JingleMessageInitiation.JmiReason? reason = null,
            bool tie_break = false, string? migrated_to_sid = null,
            Gee.List<StanzaNode>? descriptions = null) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || ((!) stream).settled || sid.strip() == "") {
            return false;
        }
        return observe(account, from, to, sid, action, timestamp,
            video_requested, true, reason, tie_break, migrated_to_sid,
            descriptions);
    }

    /**
     * Delayed non-MAM delivery is passive as well, but it may arrive after
     * the account catch-up fence settled. In that case return only the newly
     * authoritative projection; never route the stanza through live Calls.
     */
    internal Gee.List<JmiArchiveReplayResult> observe_delayed(
            Account account, Object stream_owner, Jid from, Jid to,
            string sid, Xep.JingleMessageInitiation.Action action,
            DateTime timestamp, DateTime now, bool video_requested,
            Xep.JingleMessageInitiation.JmiReason? reason = null,
            bool tie_break = false, string? migrated_to_sid = null,
            Gee.List<StanzaNode>? descriptions = null) {
        var empty = new ArrayList<JmiArchiveReplayResult>();
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || sid.strip() == "" ||
                !observe(account, from, to, sid, action, timestamp,
                    video_requested, true, reason, tie_break,
                    migrated_to_sid, descriptions)) return empty;
        return ((!) stream).settled ? collect_resolved(account, now) : empty;
    }

    internal JmiArchiveReplayResult? observe_live_followup(Account account,
            Object stream_owner, Jid from, Jid to, string sid,
            Xep.JingleMessageInitiation.Action action, DateTime timestamp,
            Xep.JingleMessageInitiation.JmiReason? reason = null,
            bool tie_break = false, string? migrated_to_sid = null) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || !((!) stream).settled) return null;
        Jid? peer = derive_peer(account, from, to);
        JmiArchiveReplayEntry? entry = peer != null
            ? find_entry(account, (!) peer, sid)
            : find_unique_entry_by_sid(account, sid);
        if (entry == null || !((!) entry).observe(from, to, action,
                timestamp, false, reason, tie_break,
                migrated_to_sid, null)) return null;
        JmiArchiveReplayResult? result;
        if (((!) entry).resolve(timestamp, retention_seconds, out result) ==
                JmiArchiveReplayDecision.PUBLISH) {
            entries.remove((!) entry);
            return result;
        }
        return null;
    }

    internal Gee.List<JmiArchiveReplayResult> settle_success(Account account,
            Object stream_owner, DateTime now) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || ((!) stream).settled) {
            return new ArrayList<JmiArchiveReplayResult>();
        }
        ((!) stream).settled = true;
        return collect_resolved(account, now);
    }

    internal Gee.List<JmiArchiveReplayResult> expire_settled(Account account,
            Object stream_owner, DateTime now) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || !((!) stream).settled) {
            return new ArrayList<JmiArchiveReplayResult>();
        }
        return collect_resolved(account, now);
    }

    internal int64 next_expiry_delay_seconds(Account account,
            Object stream_owner, DateTime now) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || !((!) stream).settled) return -1;

        int64 next_delay = -1;
        foreach (JmiArchiveReplayEntry entry in entries) {
            if (!entry.account.equals(account)) continue;
            int64 delay = entry.expiry_delay_seconds(now, retention_seconds);
            if (delay >= 0 && (next_delay < 0 || delay < next_delay)) {
                next_delay = delay;
            }
        }
        return next_delay;
    }

    /**
     * A stored proposal may only become actionable when this stream retained
     * every observation relevant to its account and SID.
     */
    internal bool permits_persisted_recovery(Account account,
            Object stream_owner, Jid peer, string sid, DateTime now) {
        JmiArchiveReplayStream? stream = find_stream(account, stream_owner);
        if (stream == null || !((!) stream).settled ||
                ((!) stream).overflowed) return false;
        JmiArchiveReplayEntry? entry = find_entry(account, peer, sid);
        return entry == null || ((!) entry).permits_persisted_recovery(now,
            retention_seconds);
    }

    private Gee.List<JmiArchiveReplayResult> collect_resolved(Account account,
            DateTime now) {
        var results = new ArrayList<JmiArchiveReplayResult>();
        var terminal_results = new ArrayList<JmiArchiveReplayResult>();

        var remove = new ArrayList<JmiArchiveReplayEntry>();
        foreach (JmiArchiveReplayEntry entry in entries) {
            if (!entry.account.equals(account)) continue;
            JmiArchiveReplayResult? result;
            JmiArchiveReplayDecision decision = entry.resolve(now,
                retention_seconds, out result);
            if (decision == JmiArchiveReplayDecision.PUBLISH && result != null) {
                terminal_results.add((!) result);
                remove.add(entry);
            } else if (decision == JmiArchiveReplayDecision.DROP ||
                    entry.is_orphan_expired(now, retention_seconds)) {
                remove.add(entry);
            }
        }
        // Recover still-active replacement proposals before publishing a
        // migrated old-leg finish. This lets both SIDs bind to the live call
        // instead of a terminal history row claiming the replacement first.
        if (!account_replay_overflowed(account)) {
            foreach (JmiArchiveReplayEntry entry in entries) {
                if (!entry.account.equals(account) || remove.contains(entry)) {
                    continue;
                }
                JmiArchiveReplayResult? actionable;
                if (entry.take_actionable_snapshot(now, retention_seconds,
                        out actionable) && actionable != null) {
                    results.add((!) actionable);
                }
            }
        }
        results.add_all(terminal_results);
        entries.remove_all(remove);
        return results;
    }

    /** ERROR discards uncertain partial pages; CANCELLED remains retryable. */
    internal void settle_failed(Account account, Object stream_owner) {
        if (find_stream(account, stream_owner) == null) return;
        clear_account(account);
    }

    internal void forget(Account account, Jid peer, string sid) {
        JmiArchiveReplayEntry? entry = find_entry(account, peer, sid);
        if (entry != null) entries.remove((!) entry);
    }

    internal void clear_account(Account account) {
        var removed_streams = new ArrayList<JmiArchiveReplayStream>();
        foreach (JmiArchiveReplayStream stream in streams) {
            if (stream.account.equals(account)) removed_streams.add(stream);
        }
        streams.remove_all(removed_streams);

        var removed_entries = new ArrayList<JmiArchiveReplayEntry>();
        foreach (JmiArchiveReplayEntry entry in entries) {
            if (entry.account.equals(account)) removed_entries.add(entry);
        }
        entries.remove_all(removed_entries);
    }

    private bool observe(Account account, Jid from, Jid to, string sid,
            Xep.JingleMessageInitiation.Action action, DateTime timestamp,
            bool video_requested, bool create_if_missing,
            Xep.JingleMessageInitiation.JmiReason? reason,
            bool tie_break, string? migrated_to_sid,
            Gee.List<StanzaNode>? descriptions) {
        Jid? peer = derive_peer(account, from, to);
        JmiArchiveReplayEntry? entry = peer != null
            ? find_entry(account, (!) peer, sid)
            : find_unique_entry_by_sid(account, sid);
        if (entry == null && peer != null && create_if_missing) {
            var candidate = new JmiArchiveReplayEntry(account, (!) peer, sid,
                next_sequence, max_observations_per_entry);
            if (!candidate.observe(from, to, action, timestamp,
                    video_requested, reason, tie_break, migrated_to_sid,
                    descriptions)) {
                return false;
            }
            next_sequence++;
            entries.add(candidate);
            trim_entries();
            return true;
        }
        if (entry == null) return false;
        return ((!) entry).observe(from, to, action, timestamp,
            video_requested, reason, tie_break, migrated_to_sid,
            descriptions);
    }

    private static Jid? derive_peer(Account account, Jid from, Jid to) {
        bool from_own = from.equals_bare(account.bare_jid);
        bool to_own = to.equals_bare(account.bare_jid);
        if (from_own == to_own) return null;
        return (from_own ? to : from).bare_jid;
    }

    private JmiArchiveReplayStream? find_stream(Account account,
            Object stream_owner) {
        foreach (JmiArchiveReplayStream stream in streams) {
            if (stream.account.equals(account) &&
                    stream.stream_owner == stream_owner) return stream;
        }
        return null;
    }

    private JmiArchiveReplayEntry? find_entry(Account account, Jid peer,
            string sid) {
        foreach (JmiArchiveReplayEntry entry in entries) {
            if (entry.matches(account, peer, sid)) return entry;
        }
        return null;
    }

    private JmiArchiveReplayEntry? find_unique_entry_by_sid(Account account,
            string sid) {
        JmiArchiveReplayEntry? match = null;
        foreach (JmiArchiveReplayEntry entry in entries) {
            if (!entry.has_sid(account, sid)) continue;
            if (match != null) return null;
            match = entry;
        }
        return match;
    }

    private void trim_entries() {
        while (entries.size > max_entries) {
            JmiArchiveReplayEntry? oldest = null;
            foreach (JmiArchiveReplayEntry entry in entries) {
                if (oldest == null ||
                        entry.sequence < ((!) oldest).sequence) oldest = entry;
            }
            if (oldest == null) return;
            mark_account_replay_overflowed((!) oldest);
            entries.remove((!) oldest);
        }
    }

    private void mark_account_replay_overflowed(
            JmiArchiveReplayEntry evicted) {
        foreach (JmiArchiveReplayStream stream in streams) {
            if (stream.account.equals(evicted.account)) {
                stream.overflowed = true;
            }
        }
    }

    private bool account_replay_overflowed(Account account) {
        foreach (JmiArchiveReplayStream stream in streams) {
            if (stream.account.equals(account) && stream.overflowed) {
                return true;
            }
        }
        return false;
    }
}

}
