/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
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

private class MucRoomAvatarWork : Object {
    public Account account;
    public Jid room;
    public string key;
    public int account_generation;
    public int room_generation;
    public MucAvatars.RoomAvatarInfo? advertised_info;
    public Cancellable cancellable = new Cancellable();

    public MucRoomAvatarWork(Account account, Jid room, string key,
            int account_generation, int room_generation,
            MucAvatars.RoomAvatarInfo? advertised_info) {
        this.account = account;
        this.room = room.bare_jid;
        this.key = key;
        this.account_generation = account_generation;
        this.room_generation = room_generation;
        this.advertised_info = advertised_info;
    }
}

/**
 * Low-priority XEP-0486 discovery for bookmarked rooms before joining.
 *
 * This component is deliberately detached from row creation and occupant
 * processing. At most one discovery operation is active globally, while the
 * visible UI remains a local-avatar-cache consumer.
 */
internal class MucRoomAvatarManager : StreamInteractionModule, Object {
    public static ModuleIdentity<MucRoomAvatarManager> IDENTITY =
        new ModuleIdentity<MucRoomAvatarManager>("muc_room_avatar_manager");
    public string id { get { return IDENTITY.id; } }

    private const int MAX_QUEUED_ROOMS = 128;
    private const uint INITIAL_DELAY_MS = 5000;
    private const uint NEXT_DELAY_MS = 1500;
    private const int SUCCESS_TTL_SECONDS = 6 * 60 * 60;
    private const int FAILURE_COOLDOWN_SECONDS = 5 * 60;
    private const int CACHE_BUSY_RETRY_ATTEMPTS = 3;
    private const uint CACHE_BUSY_RETRY_DELAY_MS = 1500;

    private StreamInteractor stream_interactor;
    private MucManager muc_manager;
    private AvatarManager avatar_manager;
    private ArrayList<MucRoomAvatarWork> queue =
        new ArrayList<MucRoomAvatarWork>();
    private HashMap<string, MucRoomAvatarWork> queued =
        new HashMap<string, MucRoomAvatarWork>();
    private HashMap<string, int> room_generations =
        new HashMap<string, int>();
    private HashMap<int, int> account_generations =
        new HashMap<int, int>();
    private HashMap<string, bool> service_support =
        new HashMap<string, bool>();
    private HashMap<string, int64?> checked_at =
        new HashMap<string, int64?>();
    private HashMap<string, int64?> failed_at =
        new HashMap<string, int64?>();
    private HashMap<Account, HashSet<Jid>> known_bookmarks =
        new HashMap<Account, HashSet<Jid>>(Account.hash_func,
            Account.equals_func);

    private uint drain_source = 0;
    private MucRoomAvatarWork? active_work;
    private int next_room_generation = 1;
    private bool refill_needed = false;

    public static void start(StreamInteractor stream_interactor) {
        var manager = new MucRoomAvatarManager(stream_interactor);
        stream_interactor.add_module(manager);
    }

    private MucRoomAvatarManager(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        this.muc_manager = (!) stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        this.avatar_manager = (!) stream_interactor.get_module<AvatarManager>(
            AvatarManager.IDENTITY);

        muc_manager.bookmarks_updated.connect(on_bookmarks_updated);
        muc_manager.conference_added.connect(on_conference_added);
        muc_manager.conference_removed.connect(on_conference_removed);
        muc_manager.room_avatar_info_updated.connect(
            on_room_avatar_info_updated);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.stream_negotiated.connect(on_stream_ready);
        stream_interactor.stream_resumed.connect(on_stream_ready);
        stream_interactor.connection_manager.connection_state_changed.connect(
            on_connection_state_changed);
    }

    private void on_bookmarks_updated(Account account,
            Set<Conference> conferences) {
        var next = new HashSet<Jid>(Jid.hash_bare_func,
            Jid.equals_bare_func);
        foreach (Conference conference in conferences) {
            next.add(conference.jid.bare_jid);
        }

        HashSet<Jid>? previous = known_bookmarks[account];
        if (previous != null) {
            foreach (Jid room in (!) previous) {
                if (!next.contains(room)) cancel_room(account, room);
            }
        }
        known_bookmarks[account] = next;
        foreach (Jid room in next) queue_discovery(account, room, null, false);
    }

    private void on_conference_added(Account account, Conference conference) {
        HashSet<Jid> rooms = ensure_known_bookmarks(account);
        rooms.add(conference.jid.bare_jid);
        queue_discovery(account, conference.jid, null, false);
    }

    private void on_conference_removed(Account account, Jid room) {
        HashSet<Jid>? rooms = known_bookmarks[account];
        if (rooms != null) ((!) rooms).remove(room.bare_jid);
        cancel_room(account, room);
    }

    private void on_room_avatar_info_updated(Account account, Jid room,
            MucAvatars.RoomAvatarInfo info) {
        // Status 104 and the join-time room-info result are authoritative
        // refresh hints. They supersede an older queued or active discovery.
        queue_discovery(account, room, info, true);
    }

    private void on_account_removed(Account account) {
        invalidate_account(account);
        known_bookmarks.unset(account);
    }

    private void on_connection_state_changed(Account account,
            ConnectionManager.ConnectionState state) {
        if (state == ConnectionManager.ConnectionState.DISCONNECTED) {
            invalidate_account(account);
        }
    }

    private void on_stream_ready(Account account, XmppStream stream) {
        // XmppStream emits its negotiated/resumed signal immediately before it
        // flips negotiation_complete. Re-enter on the next low-priority turn.
        Idle.add_full(Priority.LOW, () => {
            if (stream_interactor.get_stream(account) != stream ||
                    !stream.negotiation_complete) return Source.REMOVE;
            HashSet<Jid>? rooms = known_bookmarks[account];
            if (rooms != null) {
                foreach (Jid room in (!) rooms) {
                    queue_discovery(account, room, null, false);
                }
            }
            return Source.REMOVE;
        });
    }

    private HashSet<Jid> ensure_known_bookmarks(Account account) {
        if (!known_bookmarks.has_key(account)) {
            known_bookmarks[account] = new HashSet<Jid>(Jid.hash_bare_func,
                Jid.equals_bare_func);
        }
        return known_bookmarks[account];
    }

    private void queue_discovery(Account account, Jid room,
            MucAvatars.RoomAvatarInfo? advertised_info, bool force) {
        Jid bare_room = room.bare_jid;
        string key = room_key(account, bare_room);
        if (!force && (was_checked_recently(key) || is_in_failure_cooldown(key))) {
            return;
        }
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !((!) stream).negotiation_complete ||
                stream_interactor.connection_manager.get_state(account) !=
                    ConnectionManager.ConnectionState.CONNECTED) return;

        MucRoomAvatarWork? waiting = queued[key];
        if (waiting != null) {
            if (advertised_info != null) {
                ((!) waiting).advertised_info = advertised_info;
            }
            return;
        }
        if (active_work != null && ((!) active_work).key == key) {
            if (advertised_info == null) return;
            ((!) active_work).cancellable.cancel();
        }
        if (queued.size >= MAX_QUEUED_ROOMS &&
                !make_room_for_priority_work(force)) {
            // The active network queue stays bounded, but ordinary bookmarks
            // above the cap must be reconsidered after the current batch.
            refill_needed = true;
            return;
        }

        int room_generation = bump_room_generation(key);
        var work = new MucRoomAvatarWork(account, bare_room, key,
            get_account_generation(account), room_generation,
            advertised_info);
        queued[key] = work;
        queue.add(work);
        compact_queue_if_needed();
        schedule_drain(INITIAL_DELAY_MS);
    }

    private void schedule_drain(uint delay_ms) {
        if (drain_source != 0 || active_work != null || queue.is_empty) return;
        drain_source = Timeout.add_full(Priority.LOW, delay_ms, () => {
            drain_source = 0;
            drain();
            return Source.REMOVE;
        });
    }

    private void drain() {
        if (active_work != null) return;
        while (!queue.is_empty) {
            MucRoomAvatarWork work = queue.remove_at(0);
            if (queued[work.key] != work || !is_work_current(work)) continue;
            queued.unset(work.key);
            active_work = work;
            process.begin(work, (_, result) => {
                bool completed = process.end(result);
                if (is_work_current(work)) {
                    int64 now = get_real_time() / 1000000;
                    if (completed) {
                        checked_at[work.key] = now;
                        failed_at.unset(work.key);
                    } else if (!work.cancellable.is_cancelled()) {
                        failed_at[work.key] = now;
                    }
                }
                if (active_work == work && queue.is_empty) {
                    // Refill while the completed item still owns active_work;
                    // queue_discovery() therefore cannot arm a competing
                    // initial-delay source for the next batch.
                    refill_known_bookmarks_if_needed();
                }
                if (active_work == work) active_work = null;
                schedule_drain(NEXT_DELAY_MS);
            });
            return;
        }
        refill_known_bookmarks_if_needed();
    }

    private async bool process(MucRoomAvatarWork work) {
        XmppStream? current_stream = stream_interactor.get_stream(work.account);
        if (current_stream == null) return false;
        XmppStream stream = (!) current_stream;
        if (!is_work_current(work, stream)) return false;

        string support_key = service_key(work.account, work.room.domain_jid);
        bool supports_vcard;
        if (service_support.has_key(support_key)) {
            supports_vcard = service_support[support_key];
        } else {
            ServiceDiscovery.InfoResult? service_info = null;
            try {
                service_info = yield MucAvatars.request_info(stream,
                    work.room.domain_jid, work.cancellable);
            } catch (Error error) {
                if (!(error is IOError.CANCELLED)) {
                    debug("MUC avatar service discovery failed for %s: %s",
                        work.room.domainpart, error.message);
                }
                return false;
            }
            if (!is_work_current(work, stream) || service_info == null) {
                return false;
            }
            supports_vcard = MucAvatars.service_supports_room_avatars(
                (!) service_info);
            service_support[support_key] = supports_vcard;
        }
        if (!supports_vcard) return true;

        MucAvatars.RoomAvatarInfo? advertised = work.advertised_info;
        if (advertised == null) {
            // MUC enter and status-code refreshes already own a fresh room-info
            // request. Join that flight rather than issuing a competing IQ.
            if (muc_manager.has_pending_muc_room_info(work.account,
                    work.room)) {
                bool succeeded = yield muc_manager
                    .wait_for_pending_muc_room_info(work.account, work.room);
                if (!is_work_current(work, stream) || !succeeded) {
                    return false;
                }
                // The accepted result is propagated through
                // room_avatar_info_updated and replaces this generic work. If
                // this work is still current, no sender-authoritative avatar
                // projection was emitted, so perform our guarded request below
                // instead of caching an unverified success.
            }
            ServiceDiscovery.InfoResult? room_info = null;
            try {
                room_info = yield MucAvatars.request_info(stream, work.room,
                    work.cancellable);
            } catch (Error error) {
                if (!(error is IOError.CANCELLED)) {
                    debug("MUC avatar room discovery failed for %s: %s",
                        work.room.to_string(), error.message);
                }
                return false;
            }
            if (!is_work_current(work, stream) || room_info == null) {
                return false;
            }
            advertised = MucAvatars.parse_info_result((!) room_info);
        }
        return yield apply_advertised_info(work, stream, (!) advertised);
    }

    private async bool apply_advertised_info(MucRoomAvatarWork work,
            XmppStream stream, MucAvatars.RoomAvatarInfo info) {
        if (!info.roominfo_form_present) return false;
        if (!info.hash_field_present) {
            if (!is_work_current(work, stream)) return false;
            avatar_manager.remove_vcard_avatar(work.account, work.room);
            return true;
        }
        // A malformed hash field is not authority to erase the last known
        // good avatar and should not trigger a vCard request.
        if (!info.hashes_valid || info.hash_count == 0) return false;

        foreach (string hash in info.dup_hashes()) {
            MucRoomAvatarCacheProbe probe = MucRoomAvatarCacheProbe.BUSY;
            for (int attempt = 0; attempt <= CACHE_BUSY_RETRY_ATTEMPTS;
                    attempt++) {
                probe = yield avatar_manager.probe_muc_room_avatar_image(hash);
                if (!is_work_current(work, stream)) return false;
                if (probe != MucRoomAvatarCacheProbe.BUSY ||
                        attempt == CACHE_BUSY_RETRY_ATTEMPTS) break;
                yield wait_low_priority(CACHE_BUSY_RETRY_DELAY_MS);
            }
            if (!is_work_current(work, stream)) return false;
            // A saturated cache worker is not proof of a cache miss. Never turn
            // local pressure into a vCard network request.
            if (probe == MucRoomAvatarCacheProbe.BUSY) return false;
            if (probe != MucRoomAvatarCacheProbe.HIT) continue;
            avatar_manager.commit_muc_room_vcard_hash(work.account,
                work.room, hash, true);
            return true;
        }

        MucAvatars.FetchedRoomAvatar? fetched = null;
        try {
            fetched = yield MucAvatars.fetch_advertised_avatar(stream,
                work.room, info, work.cancellable);
        } catch (Error error) {
            if (!(error is IOError.CANCELLED)) {
                debug("MUC avatar vCard fetch failed for %s: %s",
                    work.room.to_string(), error.message);
            }
            return false;
        }
        if (!is_work_current(work, stream) || fetched == null) return false;

        bool stored = yield avatar_manager.store_verified_muc_room_avatar_image(
            (!) fetched);
        if (!stored || !is_work_current(work, stream)) return false;
        avatar_manager.commit_muc_room_vcard_hash(work.account, work.room,
            ((!) fetched).hash, true);
        return true;
    }

    private async void wait_low_priority(uint delay_ms) {
        SourceFunc callback = wait_low_priority.callback;
        Timeout.add_full(Priority.LOW, delay_ms, () => {
            callback();
            return Source.REMOVE;
        });
        yield;
    }

    private bool is_work_current(MucRoomAvatarWork work,
            XmppStream? expected_stream = null) {
        if (work.account_generation != get_account_generation(work.account) ||
                work.room_generation != get_room_generation(work.key) ||
                work.cancellable.is_cancelled()) return false;
        XmppStream? stream = stream_interactor.get_stream(work.account);
        if (stream == null || !((!) stream).negotiation_complete ||
                stream_interactor.connection_manager.get_state(work.account) !=
                    ConnectionManager.ConnectionState.CONNECTED) return false;
        return expected_stream == null || stream == expected_stream;
    }

    private void cancel_room(Account account, Jid room) {
        string key = room_key(account, room.bare_jid);
        MucRoomAvatarWork? waiting = queued[key];
        if (waiting != null) ((!) waiting).cancellable.cancel();
        queued.unset(key);
        if (active_work != null && ((!) active_work).key == key) {
            ((!) active_work).cancellable.cancel();
        }
        room_generations.unset(key);
        checked_at.unset(key);
        failed_at.unset(key);
        if (drain_source != 0 && active_work == null && queued.is_empty &&
                !refill_needed) {
            Source.remove(drain_source);
            drain_source = 0;
        }
    }

    private void invalidate_account(Account account) {
        account_generations[account.id] = get_account_generation(account) + 1;
        if (active_work != null &&
                ((!) active_work).account.id == account.id) {
            ((!) active_work).cancellable.cancel();
        }
        string prefix = account.id.to_string() + "\x1f";
        var queued_keys = new ArrayList<string>();
        foreach (string key in queued.keys) {
            if (key.has_prefix(prefix)) queued_keys.add(key);
        }
        foreach (string key in queued_keys) {
            queued[key].cancellable.cancel();
            queued.unset(key);
        }
        remove_map_entries_with_prefix<bool>(service_support, prefix);
        remove_map_entries_with_prefix<int>(room_generations, prefix);
        // Status 104 changes received while offline cannot be replayed. A
        // fresh stream must therefore revalidate bookmarked rooms instead of
        // inheriting the previous stream's success/failure TTL.
        checked_at_remove_account(account);
        failed_at_remove_account(account);
        if (active_work == null && queued.is_empty &&
                !has_connected_bookmark_account()) {
            if (drain_source != 0) {
                Source.remove(drain_source);
                drain_source = 0;
            }
            // Only cancelled/stale entries can remain here. Reconnect rebuilds
            // the bounded batch from known_bookmarks on the fresh stream.
            queue.clear();
            refill_needed = false;
            return;
        }
        if (drain_source != 0 && active_work == null && queued.is_empty &&
                !refill_needed) {
            Source.remove(drain_source);
            drain_source = 0;
        }
    }

    private void checked_at_remove_account(Account account) {
        remove_map_entries_with_prefix<int64?>(checked_at,
            account.id.to_string() + "\x1f");
    }

    private void failed_at_remove_account(Account account) {
        remove_map_entries_with_prefix<int64?>(failed_at,
            account.id.to_string() + "\x1f");
    }

    private bool has_connected_bookmark_account() {
        foreach (Account account in known_bookmarks.keys) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null && ((!) stream).negotiation_complete &&
                    stream_interactor.connection_manager.get_state(account) ==
                        ConnectionManager.ConnectionState.CONNECTED) {
                return true;
            }
        }
        return false;
    }

    private void remove_map_entries_with_prefix<V>(HashMap<string, V> map,
            string prefix) {
        var keys = new ArrayList<string>();
        foreach (string key in map.keys) {
            if (key.has_prefix(prefix)) keys.add(key);
        }
        foreach (string key in keys) map.unset(key);
    }

    private void compact_queue_if_needed() {
        if (queue.size <= MAX_QUEUED_ROOMS * 2) return;
        for (int i = queue.size - 1; i >= 0; i--) {
            MucRoomAvatarWork work = queue[i];
            if (queued[work.key] != work || !is_work_current(work)) {
                queue.remove_at(i);
            }
        }
    }

    private bool make_room_for_priority_work(bool priority_work) {
        if (!priority_work) return false;

        MucRoomAvatarWork? victim = null;
        foreach (MucRoomAvatarWork candidate in queue) {
            if (queued[candidate.key] != candidate) continue;
            if (victim == null || candidate.advertised_info == null) {
                victim = candidate;
            }
            if (candidate.advertised_info == null) break;
        }
        if (victim == null) return false;

        ((!) victim).cancellable.cancel();
        queued.unset(((!) victim).key);
        room_generations.unset(((!) victim).key);
        refill_needed = true;
        return true;
    }

    /**
     * Refill the bounded active queue from the authoritative bookmark sets.
     * One room per connected account is admitted per pass so a large account
     * cannot indefinitely starve another account.
     */
    private void refill_known_bookmarks_if_needed() {
        if (!refill_needed || !queue.is_empty) return;
        refill_needed = false;

        var accounts = new ArrayList<Account>();
        accounts.add_all(known_bookmarks.keys);
        bool made_progress = true;
        while (queued.size < MAX_QUEUED_ROOMS && made_progress) {
            made_progress = false;
            foreach (Account account in accounts) {
                Jid? room = next_bookmark_candidate(account);
                if (room == null) continue;
                int previous_size = queued.size;
                queue_discovery(account, (!) room, null, false);
                if (queued.size > previous_size) made_progress = true;
                if (queued.size >= MAX_QUEUED_ROOMS) break;
            }
        }
        // Reaching the cap may still leave bookmarks outside the active
        // batch. A harmless extra scan after the final full batch is cheaper
        // than duplicating every bookmark in a second backlog.
        if (queued.size >= MAX_QUEUED_ROOMS) refill_needed = true;
    }

    private Jid? next_bookmark_candidate(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !((!) stream).negotiation_complete ||
                stream_interactor.connection_manager.get_state(account) !=
                    ConnectionManager.ConnectionState.CONNECTED) return null;
        HashSet<Jid>? rooms = known_bookmarks[account];
        if (rooms == null) return null;
        foreach (Jid room in (!) rooms) {
            string key = room_key(account, room);
            if (queued.has_key(key) ||
                    (active_work != null && ((!) active_work).key == key) ||
                    was_checked_recently(key) ||
                    is_in_failure_cooldown(key)) continue;
            return room;
        }
        return null;
    }

    private bool was_checked_recently(string key) {
        int64? timestamp = checked_at[key];
        return timestamp != null && get_real_time() / 1000000 -
            (!) timestamp < SUCCESS_TTL_SECONDS;
    }

    private bool is_in_failure_cooldown(string key) {
        int64? timestamp = failed_at[key];
        return timestamp != null && get_real_time() / 1000000 -
            (!) timestamp < FAILURE_COOLDOWN_SECONDS;
    }

    private int get_account_generation(Account account) {
        return account_generations.has_key(account.id)
            ? account_generations[account.id] : 0;
    }

    private int get_room_generation(string key) {
        return room_generations.has_key(key) ? room_generations[key] : 0;
    }

    private int bump_room_generation(string key) {
        int next = next_room_generation;
        next_room_generation = next_room_generation == int.MAX
            ? 1 : next_room_generation + 1;
        room_generations[key] = next;
        return next;
    }

    private static string room_key(Account account, Jid room) {
        return "%d\x1f%s".printf(account.id, room.bare_jid.to_string());
    }

    private static string service_key(Account account, Jid service) {
        return "%d\x1f%s".printf(account.id,
            service.domain_jid.to_string());
    }

    internal int queued_room_count_for_tests() {
        return queued.size;
    }

    internal bool refill_needed_for_tests() {
        return refill_needed;
    }

    internal Jid[] queued_rooms_for_tests(Account account) {
        var rooms = new ArrayList<Jid>();
        foreach (MucRoomAvatarWork work in queued.values) {
            if (work.account.id == account.id) rooms.add(work.room);
        }
        return rooms.to_array();
    }

    internal void mark_room_checked_for_tests(Account account, Jid room) {
        checked_at[room_key(account, room)] = get_real_time() / 1000000;
    }

    internal void mark_room_failed_for_tests(Account account, Jid room) {
        failed_at[room_key(account, room)] = get_real_time() / 1000000;
    }

    internal bool was_room_checked_recently_for_tests(Account account,
            Jid room) {
        return was_checked_recently(room_key(account, room));
    }

    internal bool is_room_in_failure_cooldown_for_tests(Account account,
            Jid room) {
        return is_in_failure_cooldown(room_key(account, room));
    }

    internal bool has_active_work_for_tests(Account account) {
        return active_work != null &&
            ((!) active_work).account.id == account.id;
    }

    internal bool has_drain_source_for_tests() {
        return drain_source != 0;
    }

    internal void drain_for_tests() {
        if (drain_source != 0) {
            Source.remove(drain_source);
            drain_source = 0;
        }
        drain();
    }
}

}
