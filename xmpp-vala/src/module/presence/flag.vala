using Gee;

namespace Xmpp.Presence {

private class DeferredBarePresenceDisposalTask : Object {
    private WeakRef flag_weak;
    private HashSet<Jid> retired_resources;
    private Iterator<Jid> iterator;

    public DeferredBarePresenceDisposalTask(Flag flag,
            HashSet<Jid> retired_resources) {
        flag_weak = WeakRef(flag);
        this.retired_resources = retired_resources;
        iterator = retired_resources.iterator();
    }

    public bool dispose_one() {
        if (!iterator.next()) return false;

        Jid full_jid = iterator.get();
        Flag? flag = (Flag?) flag_weak.get();
        if (flag != null) {
            ((!) flag).remove_detached_presence(full_jid);
        }
        iterator.remove();
        return !retired_resources.is_empty;
    }
}

/**
 * Process-wide queue for physically releasing detached large-MUC presence
 * buckets without making a local room exit finalize every stanza at once.
 */
private class DeferredBarePresenceDisposalQueue : Object {
    private const int DISPOSAL_BUDGET = 64;
    private const int DISPOSAL_PRIORITY = Priority.LOW + 10;
    private static DeferredBarePresenceDisposalQueue? instance;

    private Gee.Queue<DeferredBarePresenceDisposalTask> tasks =
        new LinkedList<DeferredBarePresenceDisposalTask>();
    private uint source_id = 0;

    public static void enqueue(Flag flag, HashSet<Jid>? retired_resources) {
        if (retired_resources == null || ((!) retired_resources).is_empty) return;
        if (instance == null) instance = new DeferredBarePresenceDisposalQueue();
        ((!) instance).enqueue_task(new DeferredBarePresenceDisposalTask(flag,
            (!) retired_resources));
    }

    private void enqueue_task(DeferredBarePresenceDisposalTask task) {
        tasks.offer(task);
        if (source_id != 0) return;
        source_id = Idle.add_full(DISPOSAL_PRIORITY, dispose_batch);
    }

    private bool dispose_batch() {
        int remaining = DISPOSAL_BUDGET;
        while (remaining > 0 && !tasks.is_empty) {
            DeferredBarePresenceDisposalTask task = tasks.poll();
            if (task.dispose_one()) tasks.offer(task);
            remaining--;
        }

        if (!tasks.is_empty) return true;
        source_id = 0;
        return false;
    }
}

public class Flag : XmppStreamFlag {
    public static FlagIdentity<Flag> IDENTITY = new FlagIdentity<Flag>(NS_URI, "presence");

    // Resource iteration order has no protocol meaning. A hash-backed set keeps
    // MUC initial presence insertion and full-JID removal constant-time.
    private HashMap<Jid, HashSet<Jid>> resources = new HashMap<Jid, HashSet<Jid>>(Jid.hash_bare_func, Jid.equals_bare_func);
    private HashMap<Jid, Presence.Stanza> presences = new HashMap<Jid, Presence.Stanza>(Jid.hash_func, Jid.equals_func);

    public Set<Jid> get_available_jids() {
        var ret = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        ret.add_all(resources.keys);
        return ret;
    }

    public Gee.List<Jid>? get_resources(Jid jid) {
        Jid bare_jid = jid.bare_jid;
        if (!resources.has_key(bare_jid)) return null;
        ArrayList<Jid> ret = new ArrayList<Jid>(Jid.equals_func);
        ret.add_all(resources[bare_jid]);
        return ret;
    }

    public Presence.Stanza? get_presence(Jid full_jid) {
        HashSet<Jid>? active_resources = resources[full_jid.bare_jid];
        if (active_resources == null ||
                !((!) active_resources).contains(full_jid)) return null;
        return presences[full_jid];
    }

    public Gee.List<Presence.Stanza> get_presences(Jid jid) {
        Gee.List<Presence.Stanza> ret = new ArrayList<Presence.Stanza>();
        HashSet<Jid>? jid_res = resources[jid.bare_jid];
        if (jid_res == null) return ret;

        foreach (Jid full_jid in jid_res) {
            ret.add(presences[full_jid]);
        }
        return ret;
    }

    public void add_presence(Presence.Stanza presence) {
        Jid full_jid = presence.from;
        Jid bare_jid = full_jid.bare_jid;
        if (!resources.has_key(bare_jid)) {
            resources[bare_jid] = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        }
        resources[bare_jid].add(full_jid);
        presences[full_jid] = presence;
    }

    public void remove_presence(Jid jid) {
        Jid bare_jid = jid.bare_jid;
        if (resources.has_key(bare_jid)) {
            if (jid.is_bare()) {
                foreach (Jid full_jid in resources[bare_jid]) {
                    presences.unset(full_jid);
                }
                resources.unset(bare_jid);
            } else {
                resources[bare_jid].remove(jid);
                if (resources[bare_jid].is_empty) {
                    resources.unset(bare_jid);
                }
                presences.unset(jid);
            }
        }
    }

    /**
     * Logically detach all resources below one bare JID immediately and release
     * their stored stanzas in bounded idle batches. This is used by the local
     * MUC room-exit boundary; a same-room rejoin cannot be erased by an older
     * disposal task because active full JIDs always win.
     */
    internal void remove_bare_presences_deferred(Jid jid) {
        Jid bare_jid = jid.bare_jid;
        HashSet<Jid>? retired_resources = resources[bare_jid];
        if (retired_resources == null) return;

        resources.unset(bare_jid);
        DeferredBarePresenceDisposalQueue.enqueue(this, retired_resources);
    }

    internal void remove_detached_presence(Jid full_jid) {
        HashSet<Jid>? active_resources = resources[full_jid.bare_jid];
        if (active_resources != null &&
                ((!) active_resources).contains(full_jid)) return;
        presences.unset(full_jid);
    }

    public override string get_ns() {
        return NS_URI;
    }

    public override string get_id() {
        return IDENTITY.id;
    }
}

}
