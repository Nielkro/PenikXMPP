using Gee;

namespace Xmpp.Xep.Muc {

public enum RealJidVisibility {
    UNKNOWN,
    ANYONE,
    MODERATORS,
    NOBODY
}

public class Hat : Object {
    public string uri { get; set; }
    public string title { get; set; }
    public string? hue { get; set; }

    public bool equals(Hat other) {
        return uri == other.uri && title == other.title && hue == other.hue;
    }
}

private abstract class DeferredRoomStateDisposalTask : Object {
    public abstract bool dispose_one();
}

private class DeferredRoomMapDisposalTask<V> : DeferredRoomStateDisposalTask {
    private HashMap<Jid, V> bucket;
    private MapIterator<Jid, V> iterator;

    public DeferredRoomMapDisposalTask(HashMap<Jid, V> bucket) {
        this.bucket = bucket;
        this.iterator = bucket.map_iterator();
    }

    public override bool dispose_one() {
        if (!iterator.next()) return false;
        iterator.unset();
        return !bucket.is_empty;
    }
}

/**
 * Process-wide queue for physically releasing detached room projections.
 *
 * One source and one global budget keep several quick room exits from each
 * scheduling their own batches ahead of the UI settle. Tasks own only their
 * retired map and iterator; no Flag, stream or room generation is retained.
 */
private class DeferredRoomStateDisposalQueue : Object {
    private const int DISPOSAL_BUDGET = 64;
    private const int DISPOSAL_PRIORITY = Priority.LOW + 10;
    private static DeferredRoomStateDisposalQueue? instance;

    private Gee.Queue<DeferredRoomStateDisposalTask> tasks =
        new LinkedList<DeferredRoomStateDisposalTask>();
    private uint source_id = 0;

    public static void enqueue<V>(HashMap<Jid, V>? bucket) {
        if (bucket == null || ((!) bucket).is_empty) return;
        if (instance == null) instance = new DeferredRoomStateDisposalQueue();
        ((!) instance).enqueue_task(
            new DeferredRoomMapDisposalTask<V>((!) bucket));
    }

    private void enqueue_task(DeferredRoomStateDisposalTask task) {
        tasks.offer(task);
        if (source_id != 0) return;

        source_id = Idle.add_full(DISPOSAL_PRIORITY, dispose_batch);
    }

    private bool dispose_batch() {
        int remaining = DISPOSAL_BUDGET;
        while (remaining > 0 && !tasks.is_empty) {
            DeferredRoomStateDisposalTask task = tasks.poll();
            if (task.dispose_one()) tasks.offer(task);
            remaining--;
        }

        if (!tasks.is_empty) return true;
        source_id = 0;
        return false;
    }
}

internal class PendingMemberAffiliationSnapshot : Object {
    public Promise<bool> promise { get; private set; default = new Promise<bool>(); }

    private int remaining = 3;
    private bool successful = true;
    private bool completed = false;
    private AffiliationQueryCommitGuard? commit_guard = null;

    public void set_commit_guard(
            owned AffiliationQueryCommitGuard commit_guard) {
        if (completed) return;
        this.commit_guard = (owned) commit_guard;
    }

    public bool may_commit() {
        return !completed && (commit_guard == null || ((!) commit_guard)());
    }

    public bool record_result(bool successful) {
        if (completed) return false;
        this.successful = this.successful && successful;
        remaining--;
        return remaining == 0;
    }

    public void complete(bool valid_snapshot) {
        if (completed) return;
        successful = successful && valid_snapshot;
        completed = true;
        promise.set_value(successful);
        commit_guard = null;
    }

    public void cancel() {
        if (completed) return;
        successful = false;
        completed = true;
        promise.set_value(false);
        commit_guard = null;
    }
}

public class Flag : XmppStreamFlag {
    private const int MAX_CANCELLED_ENTER_ID_TOMBSTONES = 8;
    public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "muc");

    private HashMap<Jid, Gee.List<Feature>> room_features = new HashMap<Jid, Gee.List<Feature>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, string> room_names = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, bool> occupants_may_change_subject = new HashMap<Jid, bool>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, bool> occupants_may_invite = new HashMap<Jid, bool>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, uint64?> room_info_query_generations = new HashMap<Jid, uint64?>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, uint64?> completed_room_info_query_generations = new HashMap<Jid, uint64?>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, uint64?> pending_room_info_query_generations =
        new HashMap<Jid, uint64?>(Jid.hash_bare_func,
            Jid.equals_bare_func);
    private HashMap<Jid, HashMap<string, uint64?>> affiliation_query_generations = new HashMap<Jid, HashMap<string, uint64?>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<string, uint64?>> completed_affiliation_query_generations = new HashMap<Jid, HashMap<string, uint64?>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, PendingMemberAffiliationSnapshot> pending_member_affiliation_snapshots = new HashMap<Jid, PendingMemberAffiliationSnapshot>(Jid.hash_bare_func, Jid.equals_bare_func);
    private uint64 next_query_generation = 0;

    private HashMap<Jid, string> enter_ids = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, string> enter_nicks = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, ArrayList<string>> cancelled_enter_ids =
        new HashMap<Jid, ArrayList<string>>(Jid.hash_bare_func,
            Jid.equals_bare_func);
    private HashMap<Jid, string> cancelled_enter_nicks = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    public HashMap<Jid, Promise<JoinResult?>> enter_futures = new HashMap<Jid, Promise<JoinResult?>>(Jid.hash_func, Jid.equals_func);
    private HashMap<Jid, string> own_nicks = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, string> subjects = new HashMap<Jid, string>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, Jid> subjects_by = new HashMap<Jid, Jid>(Jid.hash_bare_func, Jid.equals_bare_func);

    // Room-scoped live projections. Persistent bare affiliation knowledge is
    // intentionally kept in affiliations across a room exit.
    private HashMap<Jid, HashMap<Jid, Jid>> occupant_real_jids = new HashMap<Jid, HashMap<Jid, Jid>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<Jid, Affiliation>> affiliations = new HashMap<Jid, HashMap<Jid, Affiliation>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<Jid, Affiliation>> occupant_affiliations = new HashMap<Jid, HashMap<Jid, Affiliation>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<Jid, Affiliation>> affiliation_query_snapshots = new HashMap<Jid, HashMap<Jid, Affiliation>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashSet<Affiliation>> completed_affiliation_queries = new HashMap<Jid, HashSet<Affiliation>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<Jid, Role>> occupant_roles = new HashMap<Jid, HashMap<Jid, Role>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, HashMap<Jid, Gee.List<Hat>>> occupant_hats = new HashMap<Jid, HashMap<Jid, Gee.List<Hat>>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, RealJidVisibility> real_jid_visibility =
        new HashMap<Jid, RealJidVisibility>(Jid.hash_bare_func,
            Jid.equals_bare_func);

    public string? get_room_name(Jid muc_jid) { return room_names.has_key(muc_jid.bare_jid) ? room_names[muc_jid.bare_jid] : null; }

    public bool has_room_feature(Jid muc_jid, Feature feature) {
        return room_features.has_key(muc_jid.bare_jid) && room_features[muc_jid.bare_jid].contains(feature);
    }

    public bool knows_room_features(Jid muc_jid) {
        return room_features.has_key(muc_jid.bare_jid);
    }

    /**
     * True only when the newest explicit room-info query completed
     * successfully. Cached room features may remain available to the UI after
     * a failed refresh, but security-sensitive consumers must not treat that
     * older projection as current proof.
     */
    public bool has_current_room_features(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        return room_features.has_key(room) &&
            room_info_query_generations.has_key(room) &&
            completed_room_info_query_generations.has_key(room) &&
            room_info_query_generations[room] ==
                completed_room_info_query_generations[room];
    }

    public bool? get_occupants_may_change_subject(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        return occupants_may_change_subject.has_key(room)
            ? (bool?) occupants_may_change_subject[room] : null;
    }

    /** Effective mediated-invitation policy advertised in room disco info. */
    public bool? get_occupants_may_invite(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        return occupants_may_invite.has_key(room)
            ? (bool?) occupants_may_invite[room] : null;
    }

    public Jid? get_real_jid(Jid full_jid) {
        HashMap<Jid, Jid>? room_real_jids = occupant_real_jids[full_jid.bare_jid];
        return room_real_jids != null ? ((!) room_real_jids)[full_jid] : null;
    }

    public Jid? get_occupant_jid(Jid real_jid, Jid room) {
        HashMap<Jid, Jid>? room_real_jids = occupant_real_jids[room.bare_jid];
        if (room_real_jids == null) return null;

        foreach (Map.Entry<Jid, Jid> entry in (!) room_real_jids) {
            if (entry.value.equals_bare(real_jid)) {
                return entry.key;
            }
        }
        return null;
    }

    /** Resolve only the occupant that disclosed this exact real full JID. */
    public Jid? get_occupant_jid_exact(Jid real_full_jid, Jid room) {
        if (!real_full_jid.is_full()) return null;
        HashMap<Jid, Jid>? room_real_jids =
            occupant_real_jids[room.bare_jid];
        if (room_real_jids == null) return null;

        foreach (Map.Entry<Jid, Jid> entry in (!) room_real_jids) {
            if (entry.value.equals(real_full_jid)) return entry.key;
        }
        return null;
    }

    public Gee.List<Jid> get_offline_members(Jid muc_jid) {
        Gee.List<Jid> ret = new ArrayList<Jid>(Jid.equals_bare_func);
        HashMap<Jid, Affiliation>? muc_affiliations = affiliations[muc_jid.bare_jid];
        if (muc_affiliations != null) {
            foreach (Map.Entry<Jid, Affiliation> entry in (!) muc_affiliations) {
                if ((entry.value == Affiliation.MEMBER ||
                        entry.value == Affiliation.ADMIN ||
                        entry.value == Affiliation.OWNER) &&
                        !entry.key.is_full() &&
                        !entry.key.equals_bare(muc_jid) &&
                        !ret.contains(entry.key.bare_jid)) {
                    ret.add(entry.key.bare_jid);
                }
            }
        }
        return ret;
    }

    public Gee.List<Jid>? get_complete_member_affiliation_snapshot(Jid muc_jid) {
        if (!has_complete_member_affiliation_snapshot(muc_jid)) return null;

        Gee.List<Jid> ret = new ArrayList<Jid>(Jid.equals_bare_func);
        HashMap<Jid, Affiliation>? muc_affiliations = affiliation_query_snapshots[muc_jid.bare_jid];
        if (muc_affiliations == null) return ret;

        foreach (Map.Entry<Jid, Affiliation> entry in (!) muc_affiliations) {
            if (entry.value != Affiliation.MEMBER && entry.value != Affiliation.ADMIN && entry.value != Affiliation.OWNER) continue;

            Jid jid = entry.key.bare_jid;
            if (!jid.equals_bare(muc_jid) && !ret.contains(jid)) ret.add(jid);
        }
        return ret;
    }

    public Affiliation get_affiliation(Jid muc_jid, Jid full_jid) {
        HashMap<Jid, Affiliation>? live_affiliations = occupant_affiliations[muc_jid.bare_jid];
        if (live_affiliations != null && ((!) live_affiliations).has_key(full_jid)) {
            return ((!) live_affiliations)[full_jid];
        }

        HashMap<Jid, Affiliation>? muc_affiliations = affiliations[muc_jid.bare_jid];
        if (muc_affiliations != null) {
            Jid? real_jid = get_real_jid(full_jid);
            if (real_jid != null && ((!) muc_affiliations).has_key(((!) real_jid).bare_jid)) return ((!) muc_affiliations)[((!) real_jid).bare_jid];

            if (!full_jid.equals_bare(muc_jid) && ((!) muc_affiliations).has_key(full_jid.bare_jid)) return ((!) muc_affiliations)[full_jid.bare_jid];
        }
        return Affiliation.NONE;
    }

    public bool has_affiliation(Jid muc_jid, Jid full_jid) {
        HashMap<Jid, Affiliation>? live_affiliations = occupant_affiliations[muc_jid.bare_jid];
        if (live_affiliations != null && ((!) live_affiliations).has_key(full_jid)) return true;

        HashMap<Jid, Affiliation>? muc_affiliations = affiliations[muc_jid.bare_jid];
        if (muc_affiliations == null) return false;

        Jid? real_jid = get_real_jid(full_jid);
        if (real_jid != null && ((!) muc_affiliations).has_key(((!) real_jid).bare_jid)) return true;

        if (!full_jid.equals_bare(muc_jid) && ((!) muc_affiliations).has_key(full_jid.bare_jid)) return true;
        return false;
    }

    public bool has_complete_member_affiliation_snapshot(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        HashSet<Affiliation>? completed = completed_affiliation_queries[room];
        if (completed == null ||
                !((!) completed).contains(Affiliation.MEMBER) ||
                !((!) completed).contains(Affiliation.ADMIN) ||
                !((!) completed).contains(Affiliation.OWNER)) return false;

        Affiliation[] required_affiliations = {
            Affiliation.MEMBER, Affiliation.ADMIN, Affiliation.OWNER
        };
        foreach (Affiliation affiliation in required_affiliations) {
            string key = affiliation.to_string();
            if (!affiliation_query_generations.has_key(room) ||
                    !affiliation_query_generations[room].has_key(key) ||
                    !completed_affiliation_query_generations.has_key(room) ||
                    !completed_affiliation_query_generations[room].has_key(key) ||
                    affiliation_query_generations[room][key] !=
                        completed_affiliation_query_generations[room][key]) {
                return false;
            }
        }
        return true;
    }

    public Role? get_occupant_role(Jid full_jid) {
        HashMap<Jid, Role>? room_roles = occupant_roles[full_jid.bare_jid];
        if (room_roles != null && ((!) room_roles).has_key(full_jid)) return ((!) room_roles)[full_jid];
        return Role.NONE;
    }

    public bool has_occupant_role(Jid full_jid) {
        HashMap<Jid, Role>? room_roles = occupant_roles[full_jid.bare_jid];
        return room_roles != null && ((!) room_roles).has_key(full_jid);
    }

    public Gee.List<Hat> get_occupant_hats(Jid full_jid) {
        HashMap<Jid, Gee.List<Hat>>? room_hats = occupant_hats[full_jid.bare_jid];
        if (room_hats != null && ((!) room_hats).has_key(full_jid)) return ((!) room_hats)[full_jid];
        return new ArrayList<Hat>();
    }

    public string? get_muc_nick(Jid muc_jid) { return own_nicks[muc_jid.bare_jid]; }

    public void set_muc_nick(Jid muc_jid) {
        if (muc_jid.is_full()) {
            Jid bare = muc_jid.bare_jid;
            own_nicks[bare] = muc_jid.resourcepart;
            // A cancelled enter ID remains an exact tombstone until its late
            // self-presence arrives or the room is left. Nick matching is no
            // longer safe once another same-nick enter has started.
            cancelled_enter_nicks.unset(bare);
        }
    }

    public string? get_enter_id(Jid muc_jid) { return enter_ids[muc_jid.bare_jid]; }
    public string? get_enter_nick(Jid muc_jid) { return enter_nicks[muc_jid.bare_jid]; }

    public bool is_muc(Jid jid) { return own_nicks[jid] != null; }

    public bool is_occupant(Jid jid) {
        return own_nicks.has_key(jid.bare_jid) || enter_ids.has_key(jid.bare_jid);
    }

    public bool is_muc_enter_outstanding() { return enter_ids.size != 0; }

    public string? get_muc_subject(Jid muc_jid) { return subjects[muc_jid.bare_jid]; }

    internal void set_room_name(Jid muc_jid, string name) {
        room_names[muc_jid.bare_jid] = name;
    }

    internal void set_room_features(Jid muc_jid, Gee.List<Feature> features) {
        room_features[muc_jid.bare_jid] = features;
        if (features.contains(Feature.NON_ANONYMOUS)) {
            real_jid_visibility[muc_jid.bare_jid] =
                RealJidVisibility.ANYONE;
        } else if (features.contains(Feature.SEMI_ANONYMOUS)) {
            real_jid_visibility[muc_jid.bare_jid] =
                RealJidVisibility.MODERATORS;
        } else if (get_real_jid_visibility(muc_jid) !=
                RealJidVisibility.NOBODY) {
            // Missing anonymity features are not proof that real JIDs are
            // visible. Keep privacy-sensitive consumers fail-closed.  Status
            // 174 is the only authoritative fully-anonymous transition and
            // must survive the following disco refresh because XEP-0045 does
            // not define an equivalent disco feature.
            real_jid_visibility[muc_jid.bare_jid] =
                RealJidVisibility.UNKNOWN;
        }
    }

    internal void set_occupants_may_change_subject(Jid muc_jid,
            bool? allowed) {
        Jid room = muc_jid.bare_jid;
        if (allowed == null) {
            occupants_may_change_subject.unset(room);
        } else {
            occupants_may_change_subject[room] = (!) allowed;
        }
    }

    internal void set_occupants_may_invite(Jid muc_jid, bool? allowed) {
        Jid room = muc_jid.bare_jid;
        if (allowed == null) {
            occupants_may_invite.unset(room);
        } else {
            occupants_may_invite[room] = (!) allowed;
        }
    }

    private uint64 allocate_query_generation() {
        next_query_generation++;
        if (next_query_generation == 0) next_query_generation = 1;
        return next_query_generation;
    }

    internal uint64 begin_room_info_query(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        uint64 generation = allocate_query_generation();
        room_info_query_generations[room] = generation;
        pending_room_info_query_generations[room] = generation;
        return generation;
    }

    public bool has_pending_room_info_query(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        return room_info_query_generations.has_key(room) &&
            pending_room_info_query_generations.has_key(room) &&
            room_info_query_generations[room] ==
                pending_room_info_query_generations[room];
    }

    internal void finish_room_info_query(Jid muc_jid,
            uint64 generation) {
        Jid room = muc_jid.bare_jid;
        if (pending_room_info_query_generations.has_key(room) &&
                pending_room_info_query_generations[room] == generation) {
            pending_room_info_query_generations.unset(room);
        }
    }

    internal bool is_current_room_info_query(Jid muc_jid,
            uint64 generation) {
        Jid room = muc_jid.bare_jid;
        return room_info_query_generations.has_key(room) &&
            room_info_query_generations[room] == generation;
    }

    internal void mark_room_info_query_complete(Jid muc_jid,
            uint64 generation) {
        if (is_current_room_info_query(muc_jid, generation)) {
            completed_room_info_query_generations[muc_jid.bare_jid] =
                generation;
        }
    }

    internal uint64 begin_affiliation_query(Jid muc_jid,
            Affiliation affiliation) {
        Jid room = muc_jid.bare_jid;
        if (!affiliation_query_generations.has_key(room)) {
            affiliation_query_generations[room] =
                new HashMap<string, uint64?>();
        }
        string key = affiliation.to_string();
        HashMap<string, uint64?> generations =
            affiliation_query_generations[room];
        uint64 generation = allocate_query_generation();
        generations[key] = generation;
        return generation;
    }

    internal bool is_current_affiliation_query(Jid muc_jid,
            Affiliation affiliation, uint64 generation) {
        Jid room = muc_jid.bare_jid;
        string key = affiliation.to_string();
        return affiliation_query_generations.has_key(room) &&
            affiliation_query_generations[room].has_key(key) &&
            affiliation_query_generations[room][key] == generation;
    }

    internal void mark_affiliation_query_complete(Jid muc_jid,
            Affiliation affiliation, uint64 generation) {
        if (!is_current_affiliation_query(muc_jid, affiliation,
                generation)) return;

        Jid room = muc_jid.bare_jid;
        if (!completed_affiliation_query_generations.has_key(room)) {
            completed_affiliation_query_generations[room] =
                new HashMap<string, uint64?>();
        }
        completed_affiliation_query_generations[room][affiliation.to_string()] =
            generation;
    }

    internal PendingMemberAffiliationSnapshot? get_pending_member_affiliation_snapshot(
            Jid muc_jid) {
        return pending_member_affiliation_snapshots[muc_jid.bare_jid];
    }

    internal void set_pending_member_affiliation_snapshot(Jid muc_jid,
            PendingMemberAffiliationSnapshot pending) {
        Jid room = muc_jid.bare_jid;
        PendingMemberAffiliationSnapshot? previous =
            pending_member_affiliation_snapshots[room];
        pending_member_affiliation_snapshots[room] = pending;
        if (previous != null && ((!) previous) != pending) {
            ((!) previous).cancel();
        }
    }

    internal bool is_pending_member_affiliation_snapshot(Jid muc_jid,
            PendingMemberAffiliationSnapshot pending) {
        Jid room = muc_jid.bare_jid;
        return pending_member_affiliation_snapshots.has_key(room) &&
            pending_member_affiliation_snapshots[room] == pending;
    }

    internal void finish_pending_member_affiliation_snapshot(Jid muc_jid,
            PendingMemberAffiliationSnapshot pending, bool valid_snapshot) {
        Jid room = muc_jid.bare_jid;
        if (!is_pending_member_affiliation_snapshot(room, pending)) return;
        // Retain the completed operation until an explicit forced refresh or
        // lifecycle invalidation replaces it. All concurrent consumers then
        // observe the same result instead of silently issuing another three
        // IQs; the high-level OMEMO readiness path can deliberately force one
        // retry after a transient failure.
        pending.complete(valid_snapshot);
    }

    internal void cancel_pending_member_affiliation_snapshot(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        PendingMemberAffiliationSnapshot? pending =
            pending_member_affiliation_snapshots[room];
        if (pending == null) return;
        pending_member_affiliation_snapshots.unset(room);
        ((!) pending).cancel();
    }

    internal void cancel_all_pending_member_affiliation_snapshots() {
        var rooms = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Jid room in pending_member_affiliation_snapshots.keys) {
            rooms.add(room);
        }
        foreach (Jid room in rooms) {
            cancel_pending_member_affiliation_snapshot(room);
        }
    }

    private void invalidate_room_queries(Jid muc_jid) {
        cancel_pending_member_affiliation_snapshot(muc_jid);
        room_info_query_generations.unset(muc_jid.bare_jid);
        completed_room_info_query_generations.unset(muc_jid.bare_jid);
        pending_room_info_query_generations.unset(muc_jid.bare_jid);
        affiliation_query_generations.unset(muc_jid.bare_jid);
        completed_affiliation_query_generations.unset(muc_jid.bare_jid);
    }

    internal void set_real_jid(Jid full_jid, Jid real_jid) {
        Jid room = full_jid.bare_jid;
        if (!occupant_real_jids.has_key(room)) {
            occupant_real_jids[room] = new HashMap<Jid, Jid>(Jid.hash_func, Jid.equals_func);
        }
        occupant_real_jids[room][full_jid] = real_jid;
    }

    /**
     * Forget the disclosed real JID for one live room/nick occupant.
     *
     * This deliberately leaves affiliation, role and hat state untouched:
     * those describe the occupant independently of whether the current room
     * anonymity policy permits disclosing their real JID.
     */
    internal bool clear_occupant_real_jid(Jid occupant_jid) {
        Jid room = occupant_jid.bare_jid;
        HashMap<Jid, Jid>? room_real_jids = occupant_real_jids[room];
        if (room_real_jids == null || !((!) room_real_jids).unset(occupant_jid)) return false;
        if (((!) room_real_jids).is_empty) occupant_real_jids.unset(room);
        return true;
    }

    /**
     * Forget every disclosed real JID belonging to a room.
     *
     * The returned full room/nick JIDs let callers publish a corresponding
     * privacy update without exposing or retaining the removed real JIDs.
     * Affiliation, role and hat state is intentionally preserved.
     */
    internal Gee.List<Jid> clear_room_real_jids(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        var affected_occupants = new ArrayList<Jid>(Jid.equals_func);
        HashMap<Jid, Jid>? room_real_jids = occupant_real_jids[room];
        if (room_real_jids == null) return affected_occupants;

        foreach (Map.Entry<Jid, Jid> entry in (!) room_real_jids) {
            affected_occupants.add(entry.key);
        }
        occupant_real_jids.unset(room);

        return affected_occupants;
    }

    internal void set_real_jid_visibility(Jid muc_jid,
            RealJidVisibility visibility) {
        real_jid_visibility[muc_jid.bare_jid] = visibility;
    }

    public RealJidVisibility get_real_jid_visibility(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        return real_jid_visibility.has_key(room)
            ? real_jid_visibility[room]
            : RealJidVisibility.UNKNOWN;
    }

    public bool are_real_jids_moderator_only(Jid muc_jid) {
        return get_real_jid_visibility(muc_jid) ==
            RealJidVisibility.MODERATORS;
    }

    /**
     * Remove bare real-JID affiliation projections after this occupant loses
     * permission to see them. Full room/nick affiliations, roles and hats stay
     * intact. In-flight affiliation results are fenced so an old privileged
     * query cannot repopulate the cache after the role/privacy transition.
     */
    internal void clear_room_disclosed_bare_jids(Jid muc_jid) {
        Jid room = muc_jid.bare_jid;
        cancel_pending_member_affiliation_snapshot(room);
        HashMap<Jid, Affiliation>? room_affiliations = affiliations[room];
        if (room_affiliations != null) {
            var disclosed = new ArrayList<Jid>(Jid.equals_func);
            foreach (Map.Entry<Jid, Affiliation> entry in
                    (!) room_affiliations) {
                if (entry.key.is_bare() && !entry.key.equals(room)) {
                    disclosed.add(entry.key);
                }
            }
            foreach (Jid jid in disclosed) {
                ((!) room_affiliations).unset(jid);
            }
        }
        affiliation_query_generations.unset(room);
        clear_member_affiliation_snapshot(room);
    }

    internal void set_offline_member(Jid muc_jid, Jid real_jid, Affiliation affiliation) {
        // affiliation=none is authoritative for the current live occupant,
        // but XEP-0045 explicitly has no persistent "none list". Keep NONE
        // only on room/nick and never retain every departed public occupant by
        // bare JID. OUTCAST may remain known for administration but is filtered
        // from get_offline_members().
        if (affiliation == Affiliation.NONE) {
            HashMap<Jid, Affiliation>? muc_affiliations = affiliations[muc_jid.bare_jid];
            if (muc_affiliations != null) {
                ((!) muc_affiliations).unset(real_jid.bare_jid);
            }
        } else {
            set_affiliation(muc_jid.bare_jid, real_jid.bare_jid, affiliation);
        }
        // MUC presence, successful room-admin mutations and validated
        // affiliation IQs are authoritative deltas. They keep a completed
        // member snapshot current, but cannot make an incomplete baseline
        // complete on their own.
        set_affiliation_query_member(muc_jid.bare_jid, real_jid.bare_jid,
            affiliation);
    }

    internal void set_affiliation_query_member(Jid muc_jid, Jid real_jid, Affiliation affiliation) {
        if (!affiliation_query_snapshots.has_key(muc_jid.bare_jid)) {
            affiliation_query_snapshots[muc_jid.bare_jid] = new HashMap<Jid, Affiliation>(Jid.hash_bare_func, Jid.equals_bare_func);
        }

        Jid bare_jid = real_jid.bare_jid;
        if (affiliation == Affiliation.MEMBER || affiliation == Affiliation.ADMIN || affiliation == Affiliation.OWNER) {
            affiliation_query_snapshots[muc_jid.bare_jid][bare_jid] = affiliation;
        } else {
            affiliation_query_snapshots[muc_jid.bare_jid].unset(bare_jid);
        }
    }

    internal void clear_affiliation_query_result(Jid muc_jid, Affiliation affiliation) {
        string affiliation_key = affiliation.to_string();
        if (completed_affiliation_queries.has_key(muc_jid.bare_jid)) {
            completed_affiliation_queries[muc_jid.bare_jid].remove(affiliation);
        }
        if (completed_affiliation_query_generations.has_key(
                muc_jid.bare_jid)) {
            completed_affiliation_query_generations[muc_jid.bare_jid].unset(
                affiliation_key);
        }

        HashMap<Jid, Affiliation>? muc_affiliations = affiliations[muc_jid.bare_jid];
        if (muc_affiliations != null) {
            var stale_jids = new ArrayList<Jid>(Jid.equals_bare_func);
            foreach (Map.Entry<Jid, Affiliation> entry in (!) muc_affiliations) {
                if (entry.value == affiliation && !entry.key.equals_bare(muc_jid)) stale_jids.add(entry.key);
            }
            foreach (Jid jid in stale_jids) {
                ((!) muc_affiliations).unset(jid);
            }
        }

        HashMap<Jid, Affiliation>? snapshot_affiliations = affiliation_query_snapshots[muc_jid.bare_jid];
        if (snapshot_affiliations == null) return;

        var stale_snapshot_jids = new ArrayList<Jid>(Jid.equals_bare_func);
        foreach (Map.Entry<Jid, Affiliation> entry in (!) snapshot_affiliations) {
            if (entry.value == affiliation) stale_snapshot_jids.add(entry.key);
        }
        foreach (Jid jid in stale_snapshot_jids) {
            ((!) snapshot_affiliations).unset(jid);
        }
    }

    internal void set_affiliation_query_complete(Jid muc_jid,
            Affiliation affiliation, uint64 generation) {
        if (!completed_affiliation_queries.has_key(muc_jid.bare_jid)) {
            completed_affiliation_queries[muc_jid.bare_jid] = new HashSet<Affiliation>();
        }
        completed_affiliation_queries[muc_jid.bare_jid].add(affiliation);
        mark_affiliation_query_complete(muc_jid, affiliation, generation);
    }

    internal void set_affiliation(Jid muc_jid, Jid full_jid, Affiliation affiliation) {
        // NONE is a real value received in occupant presence, even though it
        // is not a persistent affiliation list.  Keep it while the occupant
        // is live so callers can distinguish "known none" from missing or
        // stale state. get_offline_members() deliberately filters it out.
        Jid room = muc_jid.bare_jid;
        if (full_jid.is_full()) {
            if (!occupant_affiliations.has_key(room)) {
                occupant_affiliations[room] = new HashMap<Jid, Affiliation>(Jid.hash_func, Jid.equals_func);
            }
            occupant_affiliations[room][full_jid] = affiliation;
        } else {
            if (!affiliations.has_key(room)) {
                affiliations[room] = new HashMap<Jid, Affiliation>(Jid.hash_bare_func, Jid.equals_bare_func);
            }
            affiliations[room][full_jid.bare_jid] = affiliation;
        }
    }

    internal void set_occupant_role(Jid full_jid, Role role) {
        Jid room = full_jid.bare_jid;
        if (!occupant_roles.has_key(room)) {
            occupant_roles[room] = new HashMap<Jid, Role>(Jid.hash_func, Jid.equals_func);
        }
        occupant_roles[room][full_jid] = role;
    }

    internal void set_occupant_hats(Jid full_jid, Gee.List<Hat> hats) {
        Jid room = full_jid.bare_jid;
        if (!occupant_hats.has_key(room)) {
            occupant_hats[room] = new HashMap<Jid, Gee.List<Hat>>(Jid.hash_func, Jid.equals_func);
        }
        occupant_hats[room][full_jid] = hats;
    }

    internal void set_muc_subject(Jid full_jid, string? subject) {
        subjects[full_jid.bare_jid] = subject;
        subjects_by[full_jid.bare_jid] = full_jid;
    }

    internal void start_muc_enter(Jid jid, string presence_id, string nick) {
        Jid bare = jid.bare_jid;
        invalidate_room_queries(bare);
        enter_ids[bare] = presence_id;
        enter_nicks[bare] = nick;
        cancelled_enter_nicks.unset(bare);
    }

    internal void finish_muc_enter(Jid jid) {
        enter_ids.unset(jid.bare_jid);
        enter_nicks.unset(jid.bare_jid);
    }

    internal bool matches_muc_enter(Jid jid, string? presence_id, string? nick, bool allow_bare_error = false) {
        Jid bare = jid.bare_jid;
        string? enter_id = enter_ids[bare];
        if (enter_id == null) return false;
        if (presence_id != null && presence_id == enter_id) return true;

        string? enter_nick = enter_nicks[bare];
        if (presence_id == null && nick == null && allow_bare_error) return true;
        return presence_id == null && nick != null && enter_nick != null && nick == enter_nick;
    }

    internal void mark_muc_enter_cancelled(Jid jid) {
        Jid bare = jid.bare_jid;
        string? enter_id = enter_ids[bare];
        string? enter_nick = enter_nicks[bare];
        if (enter_id != null) {
            if (!cancelled_enter_ids.has_key(bare)) {
                cancelled_enter_ids[bare] = new ArrayList<string>();
            }
            ArrayList<string> ids = cancelled_enter_ids[bare];
            ids.remove((!) enter_id);
            ids.add((!) enter_id);
            while (ids.size > MAX_CANCELLED_ENTER_ID_TOMBSTONES) {
                ids.remove_at(0);
            }
        }
        if (enter_nick != null) {
            cancelled_enter_nicks[bare] = enter_nick;
        }
    }

    internal bool consume_cancelled_muc_enter(Jid jid, string? presence_id, string? nick, bool allow_nick_match) {
        Jid bare = jid.bare_jid;
        ArrayList<string>? cancelled_ids = cancelled_enter_ids[bare];
        if (presence_id != null && cancelled_ids != null &&
                ((!) cancelled_ids).contains((!) presence_id)) {
            // Keep exact IDs for the room lifecycle: a service may replay or
            // duplicate the same late self-presence more than once.
            return true;
        }

        string? cancelled_nick = cancelled_enter_nicks[bare];
        if (allow_nick_match && presence_id == null && nick != null && cancelled_nick != null && nick == cancelled_nick) {
            cancelled_enter_nicks.unset(bare);
            return true;
        }
        return false;
    }

    private void clear_cancelled_muc_enter(Jid jid) {
        Jid bare = jid.bare_jid;
        cancelled_enter_ids.unset(bare);
        cancelled_enter_nicks.unset(bare);
    }

    internal void left_muc(XmppStream stream, Jid muc_jid,
            bool preserve_cancelled_enter = false) {
        invalidate_room_queries(muc_jid);
        own_nicks.unset(muc_jid);
        if (!preserve_cancelled_enter) clear_cancelled_muc_enter(muc_jid);
        subjects.unset(muc_jid);
        subjects_by.unset(muc_jid);
        room_features.unset(muc_jid.bare_jid);
        real_jid_visibility.unset(muc_jid.bare_jid);
        occupants_may_change_subject.unset(muc_jid.bare_jid);
        occupants_may_invite.unset(muc_jid.bare_jid);
        completed_room_info_query_generations.unset(muc_jid.bare_jid);
        Jid room = muc_jid.bare_jid;
        HashMap<Jid, Affiliation>? retired_affiliation_snapshot =
            affiliation_query_snapshots[room];
        clear_member_affiliation_snapshot(muc_jid);
        HashMap<Jid, Jid>? retired_real_jids = occupant_real_jids[room];
        HashMap<Jid, Affiliation>? retired_affiliations =
            occupant_affiliations[room];
        HashMap<Jid, Role>? retired_roles = occupant_roles[room];
        HashMap<Jid, Gee.List<Hat>>? retired_hats = occupant_hats[room];

        // Detach the room buckets immediately so all accessors observe the
        // completed exit. Retain and drain the old buckets independently at
        // low idle priority: dropping their last reference here would make
        // Gee synchronously finalize every occupant in the leave call stack.
        // A same-room rejoin creates fresh buckets, so deferred disposal can
        // never erase a newer occupant generation.
        occupant_real_jids.unset(room);
        occupant_affiliations.unset(room);
        occupant_roles.unset(room);
        occupant_hats.unset(room);
        DeferredRoomStateDisposalQueue.enqueue(retired_affiliation_snapshot);
        DeferredRoomStateDisposalQueue.enqueue(retired_real_jids);
        DeferredRoomStateDisposalQueue.enqueue(retired_affiliations);
        DeferredRoomStateDisposalQueue.enqueue(retired_roles);
        DeferredRoomStateDisposalQueue.enqueue(retired_hats);
    }

    private void clear_member_affiliation_snapshot(Jid muc_jid) {
        completed_affiliation_queries.unset(muc_jid.bare_jid);
        completed_affiliation_query_generations.unset(muc_jid.bare_jid);
        affiliation_query_snapshots.unset(muc_jid.bare_jid);
    }

    internal void remove_occupant_info(Jid jid) {
        clear_occupant_real_jid(jid);
        Jid room = jid.bare_jid;

        HashMap<Jid, Affiliation>? room_affiliations = occupant_affiliations[room];
        if (room_affiliations != null) {
            ((!) room_affiliations).unset(jid);
            if (((!) room_affiliations).is_empty) occupant_affiliations.unset(room);
        }

        HashMap<Jid, Role>? room_roles = occupant_roles[room];
        if (room_roles != null) {
            ((!) room_roles).unset(jid);
            if (((!) room_roles).is_empty) occupant_roles.unset(room);
        }

        HashMap<Jid, Gee.List<Hat>>? room_hats = occupant_hats[room];
        if (room_hats != null) {
            ((!) room_hats).unset(jid);
            if (((!) room_hats).is_empty) occupant_hats.unset(room);
        }
    }

    internal override string get_ns() { return NS_URI; }

    internal override string get_id() { return IDENTITY.id; }
}

}
