/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gdk;
using Gee;
using Qlite;

using Xmpp;
using Dino.Entities;
using Dino.Security;

namespace Dino {

public enum AvatarReadPolicy {
    MEMORY_ONLY,
    LOCAL_CACHE_ONLY,
    NETWORK_ALLOWED
}

internal enum AvatarSource {
    USER_AVATARS,
    VCARD
}

internal enum MucRoomAvatarCacheProbe {
    HIT,
    MISS,
    BUSY
}

internal class AvatarHashStore : Object {
    private HashMap<int, HashMap<Jid, string>> user_by_account = new HashMap<int, HashMap<Jid, string>>();
    private HashMap<int, HashMap<Jid, string>> vcard_by_account = new HashMap<int, HashMap<Jid, string>>();

    internal static string? normalize_hash(string? hash) {
        if (hash == null) return null;

        string normalized = ((!) hash).strip().down();
        if (normalized.length != 40) return null;
        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return null;
        }
        return normalized;
    }

    internal bool update_hash(int account_id, Jid jid, string hash, AvatarSource source, out bool preferred_changed) {
        preferred_changed = false;
        string? normalized = normalize_hash(hash);
        if (normalized == null) return false;

        string? previous_preferred = get_preferred(account_id, jid);
        HashMap<Jid, string> account_map = ensure_account_map(account_id, source);
        if (account_map.has_key(jid) && account_map[jid] == (!) normalized) return false;

        account_map[jid] = (!) normalized;
        preferred_changed = previous_preferred != get_preferred(account_id, jid);
        return true;
    }

    internal bool remove(int account_id, Jid jid, AvatarSource source, out bool preferred_changed) {
        preferred_changed = false;
        HashMap<Jid, string>? account_map = get_account_map(account_id, source);
        if (account_map == null || !((!) account_map).has_key(jid)) return false;

        string? previous_preferred = get_preferred(account_id, jid);
        ((!) account_map).unset(jid);
        if (((!) account_map).is_empty) source_maps(source).unset(account_id);
        preferred_changed = previous_preferred != get_preferred(account_id, jid);
        return true;
    }

    internal string? get_preferred(int account_id, Jid jid) {
        string? user_hash = get_source(account_id, jid, AvatarSource.USER_AVATARS);
        return user_hash ?? get_source(account_id, jid, AvatarSource.VCARD);
    }

    internal string? get_source(int account_id, Jid jid, AvatarSource source) {
        HashMap<Jid, string>? account_map = get_account_map(account_id, source);
        return account_map != null ? ((!) account_map)[jid] : null;
    }

    internal HashMap<Jid, string> snapshot(int account_id, AvatarSource source) {
        var result = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
        HashMap<Jid, string>? account_map = get_account_map(account_id, source);
        if (account_map != null) result.set_all((!) account_map);
        return result;
    }

    internal int remove_full_jids(int account_id, AvatarSource source) {
        HashMap<Jid, string>? account_map = get_account_map(account_id, source);
        if (account_map == null) return 0;

        var full_jids = new ArrayList<Jid>(Jid.equals_func);
        foreach (Jid jid in ((!) account_map).keys) {
            if (!jid.is_bare()) full_jids.add(jid);
        }
        foreach (Jid jid in full_jids) ((!) account_map).unset(jid);
        if (((!) account_map).is_empty) source_maps(source).unset(account_id);
        return full_jids.size;
    }

    internal void remove_account(int account_id) {
        user_by_account.unset(account_id);
        vcard_by_account.unset(account_id);
    }

    internal void clear() {
        user_by_account.clear();
        vcard_by_account.clear();
    }

    private HashMap<int, HashMap<Jid, string>> source_maps(AvatarSource source) {
        return source == AvatarSource.USER_AVATARS ? user_by_account : vcard_by_account;
    }

    private HashMap<Jid, string>? get_account_map(int account_id, AvatarSource source) {
        return source_maps(source)[account_id];
    }

    private HashMap<Jid, string> ensure_account_map(int account_id, AvatarSource source) {
        HashMap<int, HashMap<Jid, string>> maps = source_maps(source);
        if (!maps.has_key(account_id)) {
            maps[account_id] = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
        }
        return maps[account_id];
    }
}

internal class AvatarWaiter : Object {
    internal Account account;
    internal Jid jid;
    internal int generation;
    internal bool network_allowed;

    internal AvatarWaiter(Account account, Jid jid, int generation, bool network_allowed = false) {
        this.account = account;
        this.jid = jid;
        this.generation = generation;
        this.network_allowed = network_allowed;
    }

    internal string key() {
        return account.id.to_string() + "\n" + jid.to_string();
    }
}

internal class AvatarWaiterSet : Object {
    private HashMap<string, AvatarWaiter> waiters = new HashMap<string, AvatarWaiter>();

    internal int size { get { return waiters.size; } }
    internal bool is_empty { get { return waiters.is_empty; } }

    internal bool add(Account account, Jid jid, int generation, bool network_allowed = false) {
        var waiter = new AvatarWaiter(account, jid, generation, network_allowed);
        string key = waiter.key();
        if (waiters.has_key(key)) {
            AvatarWaiter existing = waiters[key];
            existing.generation = generation;
            existing.network_allowed = existing.network_allowed || network_allowed;
            return false;
        }
        waiters[key] = waiter;
        return true;
    }

    internal ArrayList<AvatarWaiter> snapshot() {
        var result = new ArrayList<AvatarWaiter>();
        result.add_all(waiters.values);
        return result;
    }

    internal bool remove(Account account, Jid jid) {
        return waiters.unset(account.id.to_string() + "\n" + jid.to_string());
    }

    internal int remove_account(int account_id) {
        var keys = new ArrayList<string>();
        foreach (var entry in waiters.entries) {
            if (entry.value.account.id == account_id) keys.add(entry.key);
        }
        foreach (string key in keys) waiters.unset(key);
        return keys.size;
    }
}

private class AvatarCacheAsyncWaiter : Object {
    internal int account_id { get; private set; }
    private SourceFunc callback;
    private MainContext callback_context;

    internal AvatarCacheAsyncWaiter(int account_id, owned SourceFunc callback, owned MainContext callback_context) {
        this.account_id = account_id;
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    internal void resume() {
        var idle = new IdleSource();
        idle.set_callback((owned) callback);
        idle.attach(callback_context);
    }
}

internal class AvatarMemoryCacheEntry : Object {
    internal string hash;
    internal Bytes bytes;
    internal int64 byte_size;
    internal weak AvatarMemoryCacheEntry? previous = null;
    internal AvatarMemoryCacheEntry? next = null;

    internal AvatarMemoryCacheEntry(string hash, Bytes bytes) {
        this.hash = hash;
        this.bytes = bytes;
        this.byte_size = (int64) bytes.get_size();
    }
}

/** O(1) entry- and byte-bounded LRU for immutable decrypted avatar bytes. */
internal class AvatarMemoryCache : Object {
    private HashMap<string, AvatarMemoryCacheEntry> entries = new HashMap<string, AvatarMemoryCacheEntry>();
    private AvatarMemoryCacheEntry? most_recent = null;
    private AvatarMemoryCacheEntry? least_recent = null;
    private int max_entries;
    private int64 max_bytes;

    internal int entry_count { get { return entries.size; } }
    internal int64 byte_count { get; private set; default = 0; }

    internal AvatarMemoryCache(int max_entries, int64 max_bytes) {
        this.max_entries = int.max(1, max_entries);
        this.max_bytes = max_bytes > 0 ? max_bytes : 1;
    }

    internal Bytes? lookup(string hash) {
        AvatarMemoryCacheEntry? entry = entries[hash];
        if (entry == null) return null;
        touch((!) entry);
        return ((!) entry).bytes;
    }

    internal bool contains(string hash) {
        return entries.has_key(hash);
    }

    internal bool put(string hash, Bytes bytes) {
        int64 byte_size = (int64) bytes.get_size();
        AvatarMemoryCacheEntry? existing = entries[hash];
        if (byte_size > max_bytes) {
            if (existing != null) remove_entry((!) existing);
            return false;
        }

        if (existing != null) {
            byte_count -= ((!) existing).byte_size;
            ((!) existing).bytes = bytes;
            ((!) existing).byte_size = byte_size;
            byte_count += byte_size;
            touch((!) existing);
        } else {
            var entry = new AvatarMemoryCacheEntry(hash, bytes);
            entries[hash] = entry;
            byte_count += byte_size;
            prepend(entry);
        }

        evict_to_limits();
        return entries.has_key(hash);
    }

    internal void clear() {
        entries.clear();
        most_recent = null;
        least_recent = null;
        byte_count = 0;
    }

    private void touch(AvatarMemoryCacheEntry entry) {
        if (most_recent == entry) return;
        detach(entry);
        prepend(entry);
    }

    private void prepend(AvatarMemoryCacheEntry entry) {
        entry.previous = null;
        entry.next = most_recent;
        if (most_recent != null) ((!) most_recent).previous = entry;
        most_recent = entry;
        if (least_recent == null) least_recent = entry;
    }

    private void detach(AvatarMemoryCacheEntry entry) {
        AvatarMemoryCacheEntry? previous = entry.previous;
        AvatarMemoryCacheEntry? next = entry.next;
        if (previous != null) {
            ((!) previous).next = next;
        } else if (most_recent == entry) {
            most_recent = next;
        }
        if (next != null) {
            ((!) next).previous = previous;
        } else if (least_recent == entry) {
            least_recent = previous;
        }
        entry.previous = null;
        entry.next = null;
    }

    private void remove_entry(AvatarMemoryCacheEntry entry) {
        detach(entry);
        entries.unset(entry.hash);
        byte_count -= entry.byte_size;
    }

    private void evict_to_limits() {
        while (entries.size > max_entries || byte_count > max_bytes) {
            AvatarMemoryCacheEntry? victim = least_recent;
            if (victim == null) break;
            remove_entry((!) victim);
        }
    }
}

public delegate bool AvatarObserverCallback(Jid jid, Account account);

public class AvatarObserver : Object {
    internal weak AvatarManager? manager;
    internal string key;
    internal uint id;
    private AvatarObserverCallback? callback;

    internal AvatarObserver(AvatarManager manager, string key, uint id, owned AvatarObserverCallback callback) {
        this.manager = manager;
        this.key = key;
        this.id = id;
        this.callback = (owned) callback;
    }

    internal bool dispatch(Jid jid, Account account) {
        return callback != null && ((!) callback)(jid, account);
    }

    public void unsubscribe() {
        AvatarManager? owner = manager;
        manager = null;
        callback = null;
        if (owner != null) ((!) owner).remove_avatar_observer(this);
    }

    ~AvatarObserver() {
        unsubscribe();
    }
}

private enum OwnAvatarVCardOutcome {
    FAILED,
    SUCCEEDED,
    AMBIGUOUS
}

private enum OwnAvatarPepOutcome {
    FAILED,
    SUCCEEDED,
    AMBIGUOUS
}

internal class OwnAvatarOperationResult : Object {
    internal bool pep_succeeded { get; set; default = false; }
    internal bool pep_ambiguous { get; set; default = false; }
    internal bool vcard_succeeded { get; set; default = false; }
    internal bool vcard_ambiguous { get; set; default = false; }
    internal bool stale { get; set; default = false; }
    internal bool superseded { get; set; default = false; }
    internal bool timed_out { get; set; default = false; }

    internal bool any_succeeded() {
        return pep_succeeded || vcard_succeeded;
    }

    internal bool fully_succeeded() {
        return pep_succeeded && vcard_succeeded;
    }

    internal bool partially_succeeded() {
        return any_succeeded() && !fully_succeeded();
    }

    internal string vcard_status() {
        if (vcard_succeeded) return "succeeded";
        return vcard_ambiguous ? "ambiguous" : "failed";
    }

    internal string pep_status() {
        if (pep_succeeded) return "succeeded";
        return pep_ambiguous ? "ambiguous" : "failed";
    }
}

internal class OwnAvatarOperation : Object {
    internal int generation { get; private set; }
    internal XmppStream stream { get; private set; }
    internal Cancellable cancellable { get; private set; default =
        new Cancellable(); }
    internal bool timed_out { get; private set; default = false; }
    internal bool superseded { get; private set; default = false; }

    private TimeoutSource? timeout_source = null;

    internal OwnAvatarOperation(int generation, XmppStream stream,
            uint timeout_seconds) {
        this.generation = generation;
        this.stream = stream;

        var timeout = new TimeoutSource.seconds(timeout_seconds);
        timeout.set_callback(() => {
            timeout_source = null;
            timed_out = true;
            cancellable.cancel();
            return Source.REMOVE;
        });
        timeout_source = timeout;
        timeout.attach(MainContext.ref_thread_default());
    }

    internal void cancel(bool as_superseded = false) {
        superseded = superseded || as_superseded;
        cancellable.cancel();
        finish();
    }

    internal void finish() {
        if (timeout_source != null) {
            ((!) timeout_source).destroy();
            timeout_source = null;
        }
    }
}

private class OwnAvatarParallelCompletion : Object {
    internal OwnAvatarPepOutcome pep_outcome { get; private set;
        default = OwnAvatarPepOutcome.FAILED; }
    internal OwnAvatarVCardOutcome vcard_outcome { get; private set;
        default = OwnAvatarVCardOutcome.FAILED; }

    private int remaining = 2;
    private SourceFunc? resume_callback;

    internal OwnAvatarParallelCompletion(owned SourceFunc resume_callback) {
        this.resume_callback = (owned) resume_callback;
    }

    internal void complete_pep(OwnAvatarPepOutcome outcome) {
        pep_outcome = outcome;
        complete_one();
    }

    internal void complete_vcard(OwnAvatarVCardOutcome outcome) {
        vcard_outcome = outcome;
        complete_one();
    }

    private void complete_one() {
        remaining--;
        if (remaining != 0 || resume_callback == null) return;
        SourceFunc? callback = (owned) resume_callback;
        if (callback != null) Idle.add((owned) callback);
    }
}

public class AvatarManager : StreamInteractionModule, Object {
    public static ModuleIdentity<AvatarManager> IDENTITY = new ModuleIdentity<AvatarManager>("avatar_manager");
    public string id { get { return IDENTITY.id; } }

    // Hash mapping changed (including removal). Consumers should resolve the
    // current preferred source again; repeated announcements do not emit.
    public signal void received_avatar(Jid jid, Account account);
    // Avatar bytes became usable after pending cache/network work.
    public signal void fetched_avatar(Jid jid, Account account);

    private enum MucAvatarStatEvent {
        HASH_SEEN,
        ALREADY_CACHED,
        QUEUED,
        SKIPPED_DUPLICATE,
        SKIPPED_COOLDOWN,
        SKIPPED_BUDGET,
        SKIPPED_QUEUE_FULL,
        MEMORY_CACHED,
        CACHE_LOAD_OK,
        CACHE_LOAD_FAILED,
        FETCH_STARTED,
        FETCH_OK,
        FETCH_FAILED_OR_TIMEOUT,
        STORE_FAILED,
        HASH_MISMATCH,
        NO_STREAM,
        STALE_GENERATION
    }

    private class QueuedMucAvatarFetch : Object {
        public Account account;
        public string hash;
        public string key;
        public int generation;
        public int account_generation;
        public AvatarWaiterSet waiters = new AvatarWaiterSet();

        public QueuedMucAvatarFetch(Account account, string hash, string key,
                int generation, int account_generation) {
            this.account = account;
            this.hash = hash;
            this.key = key;
            this.generation = generation;
            this.account_generation = account_generation;
        }
    }

    private class MucAvatarStats : Object {
        public int account_id;
        public string room;
        public int hash_seen = 0;
        public int already_cached = 0;
        public int queued = 0;
        public int skipped_duplicate = 0;
        public int skipped_cooldown = 0;
        public int skipped_budget = 0;
        public int skipped_queue_full = 0;
        public int memory_cached = 0;
        public int cache_load_ok = 0;
        public int cache_load_failed = 0;
        public int fetch_started = 0;
        public int fetch_ok = 0;
        public int fetch_failed_or_timeout = 0;
        public int store_failed = 0;
        public int hash_mismatch = 0;
        public int no_stream = 0;
        public int stale_generation = 0;

        public MucAvatarStats(int account_id, string room) {
            this.account_id = account_id;
            this.room = room;
        }

        public void increment(MucAvatarStatEvent event) {
            switch (event) {
                case MucAvatarStatEvent.HASH_SEEN:
                    hash_seen++;
                    break;
                case MucAvatarStatEvent.ALREADY_CACHED:
                    already_cached++;
                    break;
                case MucAvatarStatEvent.QUEUED:
                    queued++;
                    break;
                case MucAvatarStatEvent.SKIPPED_DUPLICATE:
                    skipped_duplicate++;
                    break;
                case MucAvatarStatEvent.SKIPPED_COOLDOWN:
                    skipped_cooldown++;
                    break;
                case MucAvatarStatEvent.SKIPPED_BUDGET:
                    skipped_budget++;
                    break;
                case MucAvatarStatEvent.SKIPPED_QUEUE_FULL:
                    skipped_queue_full++;
                    break;
                case MucAvatarStatEvent.MEMORY_CACHED:
                    memory_cached++;
                    break;
                case MucAvatarStatEvent.CACHE_LOAD_OK:
                    cache_load_ok++;
                    break;
                case MucAvatarStatEvent.CACHE_LOAD_FAILED:
                    cache_load_failed++;
                    break;
                case MucAvatarStatEvent.FETCH_STARTED:
                    fetch_started++;
                    break;
                case MucAvatarStatEvent.FETCH_OK:
                    fetch_ok++;
                    break;
                case MucAvatarStatEvent.FETCH_FAILED_OR_TIMEOUT:
                    fetch_failed_or_timeout++;
                    break;
                case MucAvatarStatEvent.STORE_FAILED:
                    store_failed++;
                    break;
                case MucAvatarStatEvent.HASH_MISMATCH:
                    hash_mismatch++;
                    break;
                case MucAvatarStatEvent.NO_STREAM:
                    no_stream++;
                    break;
                case MucAvatarStatEvent.STALE_GENERATION:
                    stale_generation++;
                    break;
            }
        }

        public bool has_activity() {
            return hash_seen > 0 ||
                already_cached > 0 ||
                queued > 0 ||
                skipped_duplicate > 0 ||
                skipped_cooldown > 0 ||
                skipped_budget > 0 ||
                skipped_queue_full > 0 ||
                memory_cached > 0 ||
                cache_load_ok > 0 ||
                cache_load_failed > 0 ||
                fetch_started > 0 ||
                fetch_ok > 0 ||
                fetch_failed_or_timeout > 0 ||
                store_failed > 0 ||
                hash_mismatch > 0 ||
                no_stream > 0 ||
                stale_generation > 0;
        }

        public void reset() {
            hash_seen = 0;
            already_cached = 0;
            queued = 0;
            skipped_duplicate = 0;
            skipped_cooldown = 0;
            skipped_budget = 0;
            skipped_queue_full = 0;
            memory_cached = 0;
            cache_load_ok = 0;
            cache_load_failed = 0;
            fetch_started = 0;
            fetch_ok = 0;
            fetch_failed_or_timeout = 0;
            store_failed = 0;
            hash_mismatch = 0;
            no_stream = 0;
            stale_generation = 0;
        }
    }

    private StreamInteractor stream_interactor;
    private Database db;
    private FileEncryption file_encryption;
    private string folder = null;
    private AvatarHashStore avatar_hashes = new AvatarHashStore();
    private HashSet<string> pending_fetch = new HashSet<string>();
    private AvatarMemoryCache avatar_bytes_cache = new AvatarMemoryCache(MAX_AVATAR_CACHE_ENTRIES, MAX_AVATAR_CACHE_BYTES);
    private HashSet<string> pending_avatar_cache_loads = new HashSet<string>();
    private HashMap<string, AvatarWaiterSet> avatar_cache_load_waiters = new HashMap<string, AvatarWaiterSet>();
    private LinkedList<string> deferred_avatar_cache_load_order = new LinkedList<string>();
    private HashMap<string, AvatarWaiterSet> deferred_avatar_cache_load_waiters = new HashMap<string, AvatarWaiterSet>();
    private HashMap<string, ArrayList<AvatarCacheAsyncWaiter>> avatar_cache_async_waiters = new HashMap<string, ArrayList<AvatarCacheAsyncWaiter>>();
    private int avatar_cache_load_generation = 0;
    private int avatar_cache_write_pause_depth = 0;
    private const int MAX_AVATAR_CACHE_ENTRIES = 512;
    private const int64 MAX_AVATAR_CACHE_BYTES = 32 * 1024 * 1024;
    private const int MAX_PENDING_AVATAR_CACHE_LOADS = 96;
    private const int MAX_DEFERRED_AVATAR_CACHE_LOADS = 512;
    private const int MAX_PIXEL = 192;
    private const int MAX_FAILED_DECRYPT_HASHES = 500;
    private const int MAX_PARALLEL_AVATAR_FETCHES = 4;
    private const int MAX_QUEUED_AVATAR_FETCHES = 256;
    private const int AVATAR_FETCH_RETRY_COOLDOWN_SECONDS = 600;
    private const int MAX_QUEUED_MUC_AVATAR_FETCHES = 512;
    private const int MAX_MUC_AVATAR_NETWORK_FETCHES_PER_ROOM_WINDOW = 50;
    private const int MUC_AVATAR_FETCH_RETRY_COOLDOWN_SECONDS = 1800;
    private const int MUC_AVATAR_ROOM_BUDGET_WINDOW_SECONDS = 3600;
    private const uint MUC_AVATAR_INITIAL_DELAY_MS = 3000;
    private const uint MUC_AVATAR_FETCH_INTERVAL_MS = 1000;
    private const uint AVATAR_CACHE_RETRY_DELAY_MS = 25;
    private const uint MUC_AVATAR_UI_TRANSITION_PAUSE_MS = 900;
    private const uint MUC_AVATAR_STATS_INTERVAL_SECONDS = 60;
    private const uint OWN_AVATAR_OPERATION_TIMEOUT_SECONDS = 35;
    private const int MUC_AVATAR_SNAPSHOT_SLICE_ITEMS = 32;
    private const int64 MUC_AVATAR_SNAPSHOT_SLICE_BUDGET_US = 2000;
    private HashSet<string> failed_decrypt_hashes = new HashSet<string>();
    private ArrayList<AvatarWaiter> avatar_fetch_queue = new ArrayList<AvatarWaiter>();
    private HashSet<string> queued_avatar_fetches = new HashSet<string>();
    private HashMap<string, AvatarWaiterSet> avatar_fetch_waiters = new HashMap<string, AvatarWaiterSet>();
    private HashMap<string, int64?> avatar_fetch_failures = new HashMap<string, int64?>();
    private int active_avatar_fetches = 0;
    private int avatar_fetch_queue_generation = 0;
    private ArrayList<QueuedMucAvatarFetch> muc_avatar_fetch_queue = new ArrayList<QueuedMucAvatarFetch>();
    private HashMap<string, QueuedMucAvatarFetch> queued_muc_avatar_fetches = new HashMap<string, QueuedMucAvatarFetch>();
    private HashMap<string, int64?> muc_avatar_fetch_failures = new HashMap<string, int64?>();
    private HashMap<string, int> muc_avatar_room_budget_used = new HashMap<string, int>();
    private HashMap<string, int64?> muc_avatar_room_budget_reset_at = new HashMap<string, int64?>();
    private HashMap<int, bool> active_muc_avatar_fetch_accounts = new HashMap<int, bool>();
    private uint muc_avatar_fetch_source = 0;
    private int muc_avatar_fetch_generation = 0;
    private HashMap<int, int> muc_avatar_account_generations =
        new HashMap<int, int>();
    private HashMap<int, int> own_avatar_operation_generations =
        new HashMap<int, int>();
    private HashMap<int, OwnAvatarOperation> active_own_avatar_operations =
        new HashMap<int, OwnAvatarOperation>();
    private HashSet<int> own_avatar_resync_accounts = new HashSet<int>();
    private HashSet<int> own_avatar_resync_pending_accounts =
        new HashSet<int>();
    private HashSet<int> own_avatar_pep_resync_accounts = new HashSet<int>();
    private HashMap<int, Cancellable> own_avatar_pep_resync_cancellables =
        new HashMap<int, Cancellable>();
    private HashSet<int> paused_muc_avatar_accounts = new HashSet<int>();
    private HashMap<int, XmppStream> paused_muc_avatar_streams =
        new HashMap<int, XmppStream>();
    private HashMap<string, QueuedMucAvatarFetch> paused_muc_avatar_fetches =
        new HashMap<string, QueuedMucAvatarFetch>();
    private int64 muc_avatar_background_pause_until_us = 0;
    private uint muc_avatar_background_resume_source = 0;
    private bool muc_avatar_stats_enabled = false;
    private uint muc_avatar_stats_source = 0;
    private HashMap<string, MucAvatarStats> muc_avatar_stats = new HashMap<string, MucAvatarStats>();
    private HashMap<string, uint64?> muc_avatar_snapshot_tokens =
        new HashMap<string, uint64?>();
    private HashMap<string, uint64?> muc_avatar_occupant_revisions =
        new HashMap<string, uint64?>();
    private uint64 next_muc_avatar_snapshot_token = 1;
    private HashMap<string, HashMap<uint, AvatarObserver>> avatar_observers = new HashMap<string, HashMap<uint, AvatarObserver>>();
    private uint next_avatar_observer_id = 1;
    private MucManager? muc_manager;

    // Delegates to shared FileUtils (clone removal)
    private static bool looks_like_svg_file(File file) {
        return Dino.FileDetectionUtils.looks_like_svg_file(file);
    }

    public static void start(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        AvatarManager m = new AvatarManager(stream_interactor, db, file_encryption);
        stream_interactor.add_module(m);
    }

    private AvatarManager(StreamInteractor stream_interactor, Database db, FileEncryption file_encryption) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.file_encryption = file_encryption;
        this.muc_avatar_stats_enabled = Environment.get_variable("DINOX_MUC_AVATAR_STATS") == "1";
        received_avatar.connect((jid, account) => notify_avatar_observers(account, jid));
        fetched_avatar.connect((jid, account) => notify_avatar_observers(account, jid));

        File old_avatars = File.new_build_filename(Dino.get_storage_dir(), "avatars");
        File new_avatars = File.new_build_filename(Dino.get_cache_dir(), "avatars");
        this.folder = new_avatars.get_path();

        // Move old avatar location to new one
        if (old_avatars.query_exists()) {
            if (!new_avatars.query_exists()) {
                // Move old avatars folder (~/.local/share/dino) to new location (~/.cache/dino)
                try {
                    new_avatars.get_parent().make_directory_with_parents();
                } catch (Error e) {
                    warning("AvatarManager: Failed to create parent directory for avatars: %s", e.message);
                }
                try {
                    old_avatars.move(new_avatars, FileCopyFlags.NONE);
                    debug("Avatars directory %s moved to %s", old_avatars.get_path(), new_avatars.get_path());
                } catch (Error e) {
                    warning("AvatarManager: Failed to move old avatars directory: %s", e.message);
                }
            } else {
                // If both old and new folders exist, remove the old one
                try {
                    FileEnumerator enumerator = old_avatars.enumerate_children("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                    FileInfo info = null;
                    while ((info = enumerator.next_file()) != null) {
                        FileUtils.remove(Path.build_filename(old_avatars.get_path(), info.get_name()));
                    }
                    DirUtils.remove(old_avatars.get_path());
                } catch (Error e) {
                    warning("AvatarManager: Failed to remove old avatars directory: %s", e.message);
                }
            }
        }

        // Create avatar folder
        try {
            new_avatars.make_directory_with_parents();
        } catch (IOError e) {
            // Directory might already exist; that's fine.
            if (e.code != IOError.EXISTS) {
                warning("AvatarManager: Failed to create avatars directory: %s", e.message);
            }
        } catch (Error e) {
            warning("AvatarManager: Failed to create avatars directory: %s", e.message);
        }

        // Pre-load ALL avatar hashes from DB into memory BEFORE connecting signals.
        // This ensures hashes are available when ConversationManager creates sidebar
        // rows during account_added (which fires before AvatarManager.on_account_added).
        foreach (Row row in db.avatar.select({db.avatar.jid_id, db.avatar.account_id, db.avatar.hash, db.avatar.type_})) {
            try {
                string hash = row[db.avatar.hash];
                if (hash == null || hash.strip() == "") continue;
                Jid jid = db.get_jid_by_id(row[db.avatar.jid_id]);
                if (jid == null) continue;
                int account_id = row[db.avatar.account_id];
                int type = row[db.avatar.type_];
                bool preferred_changed;
                if (type == AvatarSource.USER_AVATARS) {
                    avatar_hashes.update_hash(account_id, jid, hash, AvatarSource.USER_AVATARS, out preferred_changed);
                } else if (type == AvatarSource.VCARD) {
                    avatar_hashes.update_hash(account_id, jid, hash, AvatarSource.VCARD, out preferred_changed);
                }
            } catch (InvalidJidError e) {
                // skip invalid JIDs
            }
        }

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.account_removed.connect(on_account_removed);
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        stream_interactor.stream_resumed.connect(on_stream_resumed);
        stream_interactor.connection_manager.connection_state_changed.connect(on_connection_state_changed);
        this.muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (this.muc_manager != null) {
            ((!) this.muc_manager).room_occupants_snapshot_ready.connect(
                on_muc_occupants_snapshot_ready);
            ((!) this.muc_manager).room_occupants_changed_batch.connect(
                on_muc_occupants_changed_batch);
        }
        stream_interactor.module_manager.initialize_account_modules.connect((_, modules) => {
            modules.add(new Xep.UserAvatars.Module());
            modules.add(new Xep.VCard.Module());
        });
    }

    private void on_muc_occupants_snapshot_ready(Account account, Jid room,
            MucRoomDelta delta) {
        if (!delta.full_snapshot || !delta.initial_snapshot_ready) return;
        queue_muc_avatar_delta_hints(account, room, delta, true);
    }

    private void on_muc_occupants_changed_batch(Account account, Jid room,
            MucRoomDelta delta) {
        if (delta.full_snapshot || !delta.initial_sync_finished) return;
        queue_muc_avatar_delta_hints(account, room, delta, false);
    }

    internal void queue_muc_avatar_delta_hints(Account account, Jid room,
            MucRoomDelta delta, bool full_snapshot) {
        if (delta.room.account_id != account.id ||
                delta.room.room_bare_jid != room.bare_jid.to_string()) return;

        if (full_snapshot) {
            schedule_muc_avatar_snapshot_hints(account, room, delta);
            return;
        }

        string snapshot_key = muc_avatar_snapshot_room_key(account, room);
        uint64? snapshot_token = muc_avatar_snapshot_tokens[snapshot_key];
        if (snapshot_token != null) {
            remember_muc_avatar_delta_revisions(account, delta,
                (!) snapshot_token);
        }
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantChange flags = delta.changed_flags_at(i);
            if ((flags & (MucOccupantChange.MEMBERSHIP |
                    MucOccupantChange.AVATAR)) == 0) continue;
            queue_muc_avatar_snapshot_hint_at(account, room, delta, i);
        }
    }

    private void schedule_muc_avatar_snapshot_hints(Account account, Jid room,
            MucRoomDelta delta) {
        string key = muc_avatar_snapshot_room_key(account, room);
        uint64 token = next_muc_avatar_snapshot_token++;
        if (next_muc_avatar_snapshot_token == 0) {
            next_muc_avatar_snapshot_token = 1;
        }
        muc_avatar_snapshot_tokens[key] = token;
        uint index = 0;

        Idle.add(() => {
            if (!muc_avatar_snapshot_tokens.has_key(key) ||
                    (!) muc_avatar_snapshot_tokens[key] != token ||
                    !muc_avatar_snapshot_is_current(account, room,
                        delta.room)) {
                if (muc_avatar_snapshot_tokens.has_key(key) &&
                        (!) muc_avatar_snapshot_tokens[key] == token) {
                    muc_avatar_snapshot_tokens.unset(key);
                }
                clear_muc_avatar_snapshot_revisions(account, token);
                return Source.REMOVE;
            }

            int processed = 0;
            int64 deadline = GLib.get_monotonic_time() +
                MUC_AVATAR_SNAPSHOT_SLICE_BUDGET_US;
            while (index < delta.changed_count &&
                    processed < MUC_AVATAR_SNAPSHOT_SLICE_ITEMS &&
                    GLib.get_monotonic_time() < deadline) {
                uint snapshot_index = index++;
                if (muc_avatar_snapshot_item_is_current(account, delta,
                        token, snapshot_index)) {
                    queue_muc_avatar_snapshot_hint_at(account, room, delta,
                        snapshot_index);
                }
                processed++;
            }

            if (index >= delta.changed_count) {
                muc_avatar_snapshot_tokens.unset(key);
                clear_muc_avatar_snapshot_revisions(account, token);
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        }, Priority.LOW);
    }

    private void remember_muc_avatar_delta_revisions(Account account,
            MucRoomDelta delta, uint64 token) {
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantChange flags = delta.changed_flags_at(i);
            if ((flags & (MucOccupantChange.MEMBERSHIP |
                    MucOccupantChange.AVATAR)) == 0) continue;
            remember_muc_avatar_occupant_revision(account, token,
                delta.changed_at(i).occupant_full_jid, delta.revision);
        }
        for (uint i = 0; i < delta.removed_count; i++) {
            remember_muc_avatar_occupant_revision(account, token,
                delta.removed_at(i), delta.revision);
        }
    }

    private void remember_muc_avatar_occupant_revision(Account account,
            uint64 token, string occupant_full_jid, uint64 revision) {
        string key = muc_avatar_occupant_revision_key(account, token,
            occupant_full_jid);
        uint64? previous = muc_avatar_occupant_revisions[key];
        if (previous == null || (!) previous < revision) {
            muc_avatar_occupant_revisions[key] = revision;
        }
    }

    private bool muc_avatar_snapshot_item_is_current(Account account,
            MucRoomDelta delta, uint64 token, uint index) {
        string key = muc_avatar_occupant_revision_key(account, token,
            delta.changed_at(index).occupant_full_jid);
        uint64? latest = muc_avatar_occupant_revisions[key];
        return latest == null || (!) latest <= delta.revision;
    }

    private string muc_avatar_snapshot_room_key(Account account, Jid room) {
        return account.id.to_string() + "\n" + room.bare_jid.to_string();
    }

    private string muc_avatar_occupant_revision_key(Account account,
            uint64 token, string occupant_full_jid) {
        return account.id.to_string() + "\n" + token.to_string() + "\n" +
            occupant_full_jid;
    }

    private void clear_muc_avatar_snapshot_revisions(Account account,
            uint64 token) {
        string prefix = account.id.to_string() + "\n" + token.to_string() +
            "\n";
        var stale_keys = new ArrayList<string>();
        foreach (string key in muc_avatar_occupant_revisions.keys) {
            if (key.has_prefix(prefix)) stale_keys.add(key);
        }
        foreach (string key in stale_keys) {
            muc_avatar_occupant_revisions.unset(key);
        }
    }

    private bool muc_avatar_snapshot_is_current(Account account, Jid room,
            MucRoomKey expected) {
        if (muc_manager == null) return true;
        MucRoomKey? current = ((!) muc_manager)
            .get_room_occupant_generation(account, room);
        return current != null && ((!) current).matches(expected);
    }

    private void queue_muc_avatar_snapshot_hint_at(Account account, Jid room,
            MucRoomDelta delta, uint index) {
        MucOccupantSnapshot snapshot = delta.changed_at(index);
        if (!snapshot.available) return;
        try {
            Jid occupant = new Jid(snapshot.occupant_full_jid);
            if (!occupant.is_full() || !room.equals_bare(occupant)) return;

            // XEP-0153's empty <photo/> is an explicit removal, not an
            // invalid hash. Apply it from the ordered worker delta as well as
            // from the direct presence callback. This closes the race where
            // an older sliced full snapshot can restore the previous hash
            // before the newer live delta is handled.
            if (snapshot.avatar_hash == "") {
                handle_vcard_avatar_removed(account, occupant, true);
                return;
            }
            string? hash = AvatarHashStore.normalize_hash(
                snapshot.avatar_hash);
            if (hash == null) return;

            // Raw presence records hash state only. A stabilized worker
            // snapshot is the producer that may start bounded cache and
            // network work, keeping member-list open/bind cache-only.
            handle_vcard_avatar_received(account, occupant, (!) hash, true);
            queue_avatar_cache_load(account, occupant, (!) hash, true);
        } catch (InvalidJidError error) {
            // The worker already validates occupant JIDs; fail closed if an
            // externally constructed delta violates that contract.
        }
    }

    public Bytes? get_avatar_bytes(Account account, Jid jid_, bool request_fetch = true) {
        return get_avatar_bytes_with_policy(account, jid_, request_fetch ? AvatarReadPolicy.NETWORK_ALLOWED : AvatarReadPolicy.LOCAL_CACHE_ONLY);
    }

    public AvatarObserver observe_avatar(Account account, Jid jid, owned AvatarObserverCallback callback) {
        string key = avatar_observer_key(account.id, jid);
        if (!avatar_observers.has_key(key)) {
            avatar_observers[key] = new HashMap<uint, AvatarObserver>();
        }

        uint observer_id = next_avatar_observer_id++;
        if (next_avatar_observer_id == 0) next_avatar_observer_id = 1;
        var observer = new AvatarObserver(this, key, observer_id, (owned) callback);
        avatar_observers[key][observer_id] = observer;
        return observer;
    }

    internal void remove_avatar_observer(AvatarObserver observer) {
        if (!avatar_observers.has_key(observer.key)) return;

        avatar_observers[observer.key].unset(observer.id);
        if (avatar_observers[observer.key].is_empty) avatar_observers.unset(observer.key);
    }

    private void notify_avatar_observers(Account account, Jid jid) {
        notify_avatar_observer_key(avatar_observer_key(account.id, jid), jid, account);
    }

    private void notify_avatar_observer_key(string key, Jid jid, Account account) {
        if (!avatar_observers.has_key(key)) return;

        var observers = new ArrayList<AvatarObserver>();
        observers.add_all(avatar_observers[key].values);
        foreach (AvatarObserver observer in observers) {
            if (!observer.dispatch(jid, account)) observer.unsubscribe();
        }
    }

    private string avatar_observer_key(int account_id, Jid jid) {
        return account_id.to_string() + "\n" + jid.to_string();
    }

    private void remove_avatar_observers_for_account(int account_id) {
        string prefix = account_id.to_string() + "\n";
        var observers = new ArrayList<AvatarObserver>();
        foreach (var entry in avatar_observers.entries) {
            if (entry.key.has_prefix(prefix)) observers.add_all(entry.value.values);
        }
        foreach (AvatarObserver observer in observers) observer.unsubscribe();
    }

    /**
     * Resolve the ordered avatar identities used for a conversation participant.
     * Private MUC occupants prefer their real bare JID and retain the occupant
     * full JID as a fallback; ordinary chats use the contact bare JID.
     */
    public void resolve_participant_avatar_identity(Conversation conversation, Jid jid,
            out Jid primary_jid, out Jid? secondary_jid, out string color_id) {
        primary_jid = jid;
        secondary_jid = null;
        color_id = jid.to_string();

        if (conversation.type_ != Conversation.Type.CHAT && jid.equals_bare(conversation.counterpart)) {
            MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            Jid? real_jid = muc_manager != null ? ((!) muc_manager).get_real_jid(jid, conversation.account) : null;
            if (real_jid != null && ((!) muc_manager).is_private_room(conversation.account, conversation.counterpart.bare_jid)) {
                secondary_jid = jid;
                primary_jid = ((!) real_jid).bare_jid;
                color_id = primary_jid.to_string();
            } else if (jid.resourcepart != null) {
                color_id = jid.resourcepart;
            }
        } else if (conversation.type_ == Conversation.Type.CHAT) {
            primary_jid = jid.bare_jid;
            color_id = primary_jid.to_string();
        }
    }

    public void resolve_participant_avatar_jids(Conversation conversation, Jid jid,
            out Jid primary_jid, out Jid? secondary_jid) {
        string color_id;
        resolve_participant_avatar_identity(conversation, jid,
            out primary_jid, out secondary_jid, out color_id);
    }

    public Bytes? get_avatar_bytes_with_policy(Account account, Jid jid_, AvatarReadPolicy policy) {
        Jid jid = get_avatar_identity(account, jid_);
        string? hash = avatar_hashes.get_preferred(account.id, jid);
        if (hash == null) return null;

        // Check in-memory cache first (avoids file I/O + AES decrypt)
        Bytes? cached_bytes = avatar_bytes_cache.lookup(hash);
        if (cached_bytes != null) return cached_bytes;

        if (policy == AvatarReadPolicy.MEMORY_ONLY) return null;

        // Corrupt local state must not repeat expensive PBKDF work. A network-
        // allowed caller can still repair it through the normal fetch queue.
        if (failed_decrypt_hashes.contains(hash)) {
            if (policy == AvatarReadPolicy.NETWORK_ALLOWED) queue_network_after_cache_miss(account, jid, hash);
            return null;
        }

        queue_avatar_cache_load(account, jid, hash, policy == AvatarReadPolicy.NETWORK_ALLOWED);
        return null;
    }

    public async Bytes? get_avatar_bytes_from_local_cache_async(Account account, Jid jid_) {
        Jid jid = get_avatar_identity(account, jid_);
        string? hash = avatar_hashes.get_preferred(account.id, jid);
        if (hash == null) return null;
        Bytes? cached_bytes = avatar_bytes_cache.lookup((!) hash);
        if (cached_bytes != null) return cached_bytes;
        if (failed_decrypt_hashes.contains((!) hash)) return null;

        if (!queue_avatar_cache_load(account, jid, (!) hash, false)) return null;

        SourceFunc callback = get_avatar_bytes_from_local_cache_async.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        var waiter = new AvatarCacheAsyncWaiter(account.id, (owned) callback, (owned) callback_context);
        if (!avatar_cache_async_waiters.has_key((!) hash)) {
            avatar_cache_async_waiters[(!) hash] = new ArrayList<AvatarCacheAsyncWaiter>();
        }
        avatar_cache_async_waiters[(!) hash].add(waiter);
        int generation = avatar_cache_load_generation;

        yield;

        if (generation != avatar_cache_load_generation ||
                avatar_hashes.get_preferred(account.id, jid) != hash ||
                !avatar_bytes_cache.contains((!) hash)) return null;
        return avatar_bytes_cache.lookup((!) hash);
    }

    private bool queue_avatar_cache_load(Account account, Jid jid, string hash, bool network_allowed) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null || avatar_hashes.get_preferred(account.id, jid) != normalized_hash) return false;

        if (avatar_bytes_cache.lookup((!) normalized_hash) != null) return true;
        if (pending_avatar_cache_loads.contains((!) normalized_hash)) {
            avatar_cache_load_waiters[(!) normalized_hash].add(account, jid, avatar_cache_load_generation, network_allowed);
            return true;
        }
        if (pending_avatar_cache_loads.size >= MAX_PENDING_AVATAR_CACHE_LOADS) {
            return defer_avatar_cache_load(account, jid, (!) normalized_hash, network_allowed);
        }

        var waiters = new AvatarWaiterSet();
        waiters.add(account, jid, avatar_cache_load_generation, network_allowed);
        pending_avatar_cache_loads.add((!) normalized_hash);
        avatar_cache_load_waiters[(!) normalized_hash] = waiters;
        int generation = avatar_cache_load_generation;
        string path = Path.build_filename(folder, (!) normalized_hash);

        AvatarCacheWorker.load_verified.begin(path, file_encryption,
                (!) normalized_hash, (_, result) => {
            Bytes? bytes = null;
            bool corrupt = false;
            bool retry_later = false;
            try {
                bytes = AvatarCacheWorker.load_verified.end(result).bytes;
            } catch (AvatarCacheWorkerError.NOT_FOUND error) {
                // Normal cache miss.
            } catch (AvatarCacheWorkerError.QUEUE_FULL error) {
                retry_later = true;
            } catch (AvatarCacheWorkerError.CORRUPT error) {
                corrupt = true;
            } catch (AvatarCacheWorkerError.TOO_LARGE error) {
                corrupt = true;
            } catch (Error error) {
                corrupt = true;
                warning("Avatar cache worker failed to load %s: %s", (!) normalized_hash, error.message);
            }
            complete_avatar_cache_load((!) normalized_hash, generation, bytes, corrupt, retry_later);
        });
        return true;
    }

    private bool defer_avatar_cache_load(Account account, Jid jid, string hash, bool network_allowed) {
        if (deferred_avatar_cache_load_waiters.has_key(hash)) {
            deferred_avatar_cache_load_waiters[hash].add(account, jid, avatar_cache_load_generation, network_allowed);
            return true;
        }
        if (deferred_avatar_cache_load_order.size >= MAX_DEFERRED_AVATAR_CACHE_LOADS) return false;

        var waiters = new AvatarWaiterSet();
        waiters.add(account, jid, avatar_cache_load_generation, network_allowed);
        deferred_avatar_cache_load_waiters[hash] = waiters;
        deferred_avatar_cache_load_order.add(hash);
        return true;
    }

    private void drain_deferred_avatar_cache_loads() {
        while (pending_avatar_cache_loads.size < MAX_PENDING_AVATAR_CACHE_LOADS &&
                !deferred_avatar_cache_load_order.is_empty) {
            string hash = deferred_avatar_cache_load_order.remove_at(0);
            AvatarWaiterSet? waiters = deferred_avatar_cache_load_waiters[hash];
            deferred_avatar_cache_load_waiters.unset(hash);
            if (waiters == null) continue;

            bool queued = false;
            foreach (AvatarWaiter waiter in ((!) waiters).snapshot()) {
                if (waiter.generation == avatar_cache_load_generation &&
                        avatar_hashes.get_preferred(waiter.account.id, waiter.jid) == hash) {
                    queue_avatar_cache_load(waiter.account, waiter.jid, hash, waiter.network_allowed);
                    queued = true;
                }
            }
            if (!queued) resume_avatar_cache_async_waiters(hash);
        }
    }

    private void complete_avatar_cache_load(string hash, int generation, Bytes? bytes, bool corrupt, bool retry_later) {
        // purge_in_memory_caches() can be followed immediately by a new request
        // for the same hash. An old completion must not remove that new state.
        if (generation != avatar_cache_load_generation) return;

        AvatarWaiterSet? waiters = avatar_cache_load_waiters[hash];
        avatar_cache_load_waiters.unset(hash);
        pending_avatar_cache_loads.remove(hash);
        drain_deferred_avatar_cache_loads();
        if (waiters == null) return;

        if (bytes != null) {
            cache_avatar_bytes(hash, (!) bytes);
        } else if (corrupt) {
            if (failed_decrypt_hashes.size >= MAX_FAILED_DECRYPT_HASHES) failed_decrypt_hashes.clear();
            failed_decrypt_hashes.add(hash);
        }

        ArrayList<AvatarWaiter> waiter_snapshot = ((!) waiters).snapshot();
        if (retry_later) {
            Timeout.add_full(GLib.Priority.LOW, AVATAR_CACHE_RETRY_DELAY_MS, () => {
                if (generation != avatar_cache_load_generation) return false;
                bool queued = false;
                foreach (AvatarWaiter waiter in waiter_snapshot) {
                    if (avatar_hashes.get_preferred(waiter.account.id, waiter.jid) == hash) {
                        queued = queue_avatar_cache_load(waiter.account, waiter.jid, hash, waiter.network_allowed) || queued;
                    }
                }
                if (!queued) resume_avatar_cache_async_waiters(hash);
                return false;
            });
            return;
        }

        resume_avatar_cache_async_waiters(hash);

        foreach (AvatarWaiter waiter in waiter_snapshot) {
            if (waiter.generation != avatar_cache_load_generation ||
                    avatar_hashes.get_preferred(waiter.account.id, waiter.jid) != hash) continue;

            if (bytes != null) {
                if (is_muc_occupant_avatar_jid(waiter.account, waiter.jid)) {
                    count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.CACHE_LOAD_OK);
                }
                fetched_avatar(waiter.jid, waiter.account);
            } else {
                if (is_muc_occupant_avatar_jid(waiter.account, waiter.jid)) {
                    count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.CACHE_LOAD_FAILED);
                }
                if (waiter.network_allowed) queue_network_after_cache_miss(waiter.account, waiter.jid, hash);
            }
        }
    }

    private void resume_avatar_cache_async_waiters(string hash) {
        ArrayList<AvatarCacheAsyncWaiter>? waiters = avatar_cache_async_waiters[hash];
        avatar_cache_async_waiters.unset(hash);
        if (waiters == null) return;
        foreach (AvatarCacheAsyncWaiter waiter in (!) waiters) waiter.resume();
    }

    private void cancel_avatar_cache_async_waiters() {
        var waiters = new ArrayList<AvatarCacheAsyncWaiter>();
        foreach (ArrayList<AvatarCacheAsyncWaiter> hash_waiters in avatar_cache_async_waiters.values) {
            waiters.add_all(hash_waiters);
        }
        avatar_cache_async_waiters.clear();
        foreach (AvatarCacheAsyncWaiter waiter in waiters) waiter.resume();
    }

    private void cancel_avatar_cache_async_waiters_for_account(int account_id) {
        var to_resume = new ArrayList<AvatarCacheAsyncWaiter>();
        var empty_hashes = new ArrayList<string>();
        foreach (var entry in avatar_cache_async_waiters.entries) {
            foreach (AvatarCacheAsyncWaiter waiter in entry.value.to_array()) {
                if (waiter.account_id != account_id) continue;
                entry.value.remove(waiter);
                to_resume.add(waiter);
            }
            if (entry.value.is_empty) empty_hashes.add(entry.key);
        }
        foreach (string hash in empty_hashes) avatar_cache_async_waiters.unset(hash);
        foreach (AvatarCacheAsyncWaiter waiter in to_resume) waiter.resume();
    }

    private void queue_network_after_cache_miss(Account account, Jid jid, string hash) {
        if (is_muc_occupant_avatar_jid(account, jid)) {
            queue_muc_avatar_network_fetch(account, jid, hash);
        } else {
            queue_fetch_for_jid(account, jid);
        }
    }

    private string avatar_fetch_key(Account account, Jid jid) {
        return account.id.to_string() + "\n" + jid.to_string();
    }

    private bool is_avatar_fetch_in_cooldown(string key) {
        if (!avatar_fetch_failures.has_key(key)) return false;

        int64 failed_at = avatar_fetch_failures[key];
        int64 now = get_real_time() / 1000000;
        if (now - failed_at < AVATAR_FETCH_RETRY_COOLDOWN_SECONDS) return true;

        avatar_fetch_failures.unset(key);
        return false;
    }

    private void clear_avatar_fetch_failure(Account account, Jid jid) {
        avatar_fetch_failures.unset(avatar_fetch_key(account, jid));
    }

    private string muc_avatar_fetch_key(Account account, Jid jid, string hash) {
        return account.id.to_string() + "\n" + jid.to_string() + "\n" + hash.down();
    }

    private string muc_avatar_fetch_work_key(Account account, Jid jid, string hash) {
        return account.id.to_string() + "\n" + jid.bare_jid.to_string() + "\n" + hash.down();
    }

    private string muc_avatar_room_key(Account account, Jid jid) {
        return account.id.to_string() + "\n" + jid.bare_jid.to_string();
    }

    private bool is_current_muc_avatar_request(Account account, Jid jid, string hash) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return false;
        string? current_hash = avatar_hashes.get_preferred(account.id, jid);
        return current_hash == normalized_hash && is_muc_occupant_avatar_jid(account, jid);
    }

    private bool is_active_muc_avatar_request(Account account, Jid jid, string hash) {
        if (!is_muc_occupant_avatar_jid(account, jid)) return false;
        return is_current_muc_avatar_request(account, jid, hash);
    }

    private MucAvatarStats? get_muc_avatar_stats(Account account, Jid jid) {
        if (!muc_avatar_stats_enabled) return null;

        string key = muc_avatar_room_key(account, jid);
        if (!muc_avatar_stats.has_key(key)) {
            muc_avatar_stats[key] = new MucAvatarStats(account.id, jid.bare_jid.to_string());
        }
        schedule_muc_avatar_stats_report();
        return muc_avatar_stats[key];
    }

    private void count_muc_avatar_stat(Account account, Jid jid, MucAvatarStatEvent event) {
        MucAvatarStats? stats = get_muc_avatar_stats(account, jid);
        if (stats == null) return;
        ((!) stats).increment(event);
    }

    private void schedule_muc_avatar_stats_report() {
        if (!muc_avatar_stats_enabled || muc_avatar_stats_source != 0) return;

        muc_avatar_stats_source = Timeout.add_seconds_full(GLib.Priority.LOW, MUC_AVATAR_STATS_INTERVAL_SECONDS, () => {
            muc_avatar_stats_source = 0;
            report_muc_avatar_stats();
            return false;
        });
    }

    private void report_muc_avatar_stats() {
        if (!muc_avatar_stats_enabled) return;

        foreach (MucAvatarStats stats in muc_avatar_stats.values) {
            if (!stats.has_activity()) continue;

            message(
                "MUC avatar stats account_id=%d room=%s hash_seen=%d already_cached=%d queued=%d skipped_duplicate=%d skipped_cooldown=%d skipped_budget=%d skipped_queue_full=%d memory_cached=%d cache_load_ok=%d cache_load_failed=%d fetch_started=%d fetch_ok=%d fetch_failed_or_timeout=%d store_failed=%d hash_mismatch=%d no_stream=%d stale_generation=%d network_queue_size=%d",
                stats.account_id,
                stats.room,
                stats.hash_seen,
                stats.already_cached,
                stats.queued,
                stats.skipped_duplicate,
                stats.skipped_cooldown,
                stats.skipped_budget,
                stats.skipped_queue_full,
                stats.memory_cached,
                stats.cache_load_ok,
                stats.cache_load_failed,
                stats.fetch_started,
                stats.fetch_ok,
                stats.fetch_failed_or_timeout,
                stats.store_failed,
                stats.hash_mismatch,
                stats.no_stream,
                stats.stale_generation,
                muc_avatar_fetch_queue.size
            );
            stats.reset();
        }
    }

    private void cache_avatar_bytes(string hash, Bytes data) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return;
        avatar_bytes_cache.put((!) normalized_hash, data);
        failed_decrypt_hashes.remove((!) normalized_hash);
    }

    private int get_muc_avatar_account_generation(int account_id) {
        return muc_avatar_account_generations.has_key(account_id)
            ? muc_avatar_account_generations[account_id]
            : 0;
    }

    private void bump_muc_avatar_account_generation(int account_id) {
        int current = get_muc_avatar_account_generation(account_id);
        muc_avatar_account_generations[account_id] = current == int.MAX
            ? 1
            : current + 1;
    }

    private bool is_current_muc_avatar_fetch(
            QueuedMucAvatarFetch request) {
        return request.generation == muc_avatar_fetch_generation &&
            request.account_generation ==
                get_muc_avatar_account_generation(request.account.id);
    }

    private ArrayList<AvatarWaiter> get_active_muc_avatar_waiters(
            AvatarWaiterSet waiters, string hash) {
        var result = new ArrayList<AvatarWaiter>();
        foreach (AvatarWaiter waiter in waiters.snapshot()) {
            if (waiter.generation !=
                    get_muc_avatar_account_generation(waiter.account.id) ||
                    !is_active_muc_avatar_request(waiter.account, waiter.jid,
                        hash)) {
                count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.STALE_GENERATION);
                waiters.remove(waiter.account, waiter.jid);
                continue;
            }
            result.add(waiter);
        }
        return result;
    }

    private bool consume_muc_avatar_room_budget(Account account, Jid jid) {
        string key = muc_avatar_room_key(account, jid);
        int64 now = get_real_time() / 1000000;
        if (!muc_avatar_room_budget_reset_at.has_key(key) || now >= muc_avatar_room_budget_reset_at[key]) {
            muc_avatar_room_budget_used[key] = 0;
            muc_avatar_room_budget_reset_at[key] = now + MUC_AVATAR_ROOM_BUDGET_WINDOW_SECONDS;
        }

        int used = muc_avatar_room_budget_used.has_key(key) ? muc_avatar_room_budget_used[key] : 0;
        if (used >= MAX_MUC_AVATAR_NETWORK_FETCHES_PER_ROOM_WINDOW) return false;

        muc_avatar_room_budget_used[key] = used + 1;
        return true;
    }

    private bool is_muc_avatar_fetch_in_cooldown(string key) {
        if (!muc_avatar_fetch_failures.has_key(key)) return false;

        int64 failed_at = muc_avatar_fetch_failures[key];
        int64 now = get_real_time() / 1000000;
        if (now - failed_at < MUC_AVATAR_FETCH_RETRY_COOLDOWN_SECONDS) return true;

        muc_avatar_fetch_failures.unset(key);
        return false;
    }

    private void clear_muc_avatar_fetch_failure(Account account, Jid jid, string hash) {
        muc_avatar_fetch_failures.unset(muc_avatar_fetch_key(account, jid, hash));
    }

    private void queue_muc_avatar_network_fetch(Account account, Jid jid, string hash) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null || !is_current_muc_avatar_request(account, jid, (!) normalized_hash)) return;
        if (paused_muc_avatar_accounts.contains(account.id)) {
            // Preserve only this actual cache-miss/network intent. Replaying a
            // whole room on reconnect decrypts every unchanged avatar again.
            remember_paused_muc_avatar_fetch(account, jid,
                (!) normalized_hash);
            return;
        }
        int account_generation = get_muc_avatar_account_generation(account.id);

        if (avatar_bytes_cache.lookup((!) normalized_hash) != null) {
            fetched_avatar(jid, account);
            count_muc_avatar_stat(account, jid, MucAvatarStatEvent.MEMORY_CACHED);
            return;
        }

        string work_key = muc_avatar_fetch_work_key(account, jid, (!) normalized_hash);
        if (queued_muc_avatar_fetches.has_key(work_key)) {
            QueuedMucAvatarFetch queued = queued_muc_avatar_fetches[work_key];
            if (is_current_muc_avatar_fetch(queued)) {
                queued.waiters.add(account, jid, account_generation);
                count_muc_avatar_stat(account, jid,
                    MucAvatarStatEvent.SKIPPED_DUPLICATE);
                return;
            }
            queued_muc_avatar_fetches.unset(work_key);
        }
        string failure_key = muc_avatar_fetch_key(account, jid, (!) normalized_hash);
        if (is_muc_avatar_fetch_in_cooldown(failure_key)) {
            count_muc_avatar_stat(account, jid, MucAvatarStatEvent.SKIPPED_COOLDOWN);
            return;
        }
        if (!consume_muc_avatar_room_budget(account, jid)) {
            count_muc_avatar_stat(account, jid, MucAvatarStatEvent.SKIPPED_BUDGET);
            return;
        }
        if (muc_avatar_fetch_queue.size >= MAX_QUEUED_MUC_AVATAR_FETCHES) {
            muc_avatar_fetch_failures[failure_key] = get_real_time() / 1000000;
            count_muc_avatar_stat(account, jid, MucAvatarStatEvent.SKIPPED_QUEUE_FULL);
            return;
        }

        var request = new QueuedMucAvatarFetch(account, (!) normalized_hash,
            work_key, muc_avatar_fetch_generation, account_generation);
        request.waiters.add(account, jid, account_generation);
        queued_muc_avatar_fetches[work_key] = request;
        muc_avatar_fetch_queue.add(request);
        count_muc_avatar_stat(account, jid, MucAvatarStatEvent.QUEUED);
        schedule_muc_avatar_fetch_drain(MUC_AVATAR_INITIAL_DELAY_MS);
    }

    private void schedule_muc_avatar_fetch_drain(uint delay_ms) {
        if (muc_avatar_fetch_source != 0) return;
        if (is_muc_avatar_background_paused()) {
            schedule_muc_avatar_background_resume();
            return;
        }
        muc_avatar_fetch_source = Timeout.add_full(GLib.Priority.LOW, delay_ms, () => {
            muc_avatar_fetch_source = 0;
            drain_muc_avatar_fetch_queue();
            return false;
        });
    }

    public void defer_muc_avatar_background_work_for_ui_transition() {
        int64 pause_until_us = GLib.get_monotonic_time() + ((int64) MUC_AVATAR_UI_TRANSITION_PAUSE_MS * 1000);
        if (pause_until_us > muc_avatar_background_pause_until_us) {
            muc_avatar_background_pause_until_us = pause_until_us;
        }

        if (muc_avatar_fetch_source != 0) {
            GLib.Source.remove(muc_avatar_fetch_source);
            muc_avatar_fetch_source = 0;
        }

        schedule_muc_avatar_background_resume();
    }

    private bool is_muc_avatar_background_paused() {
        return GLib.get_monotonic_time() < muc_avatar_background_pause_until_us;
    }

    private uint get_muc_avatar_background_pause_remaining_ms() {
        int64 remaining_us = muc_avatar_background_pause_until_us - GLib.get_monotonic_time();
        if (remaining_us <= 0) return 0;
        int64 remaining_ms = (remaining_us + 999) / 1000;
        return (uint) remaining_ms;
    }

    private void schedule_muc_avatar_background_resume() {
        if (muc_avatar_background_resume_source != 0) return;

        uint delay_ms = get_muc_avatar_background_pause_remaining_ms();
        if (delay_ms == 0) delay_ms = 1;
        muc_avatar_background_resume_source = Timeout.add_full(GLib.Priority.LOW, delay_ms, () => {
            muc_avatar_background_resume_source = 0;
            if (is_muc_avatar_background_paused()) {
                schedule_muc_avatar_background_resume();
                return false;
            }

            if (!muc_avatar_fetch_queue.is_empty) {
                schedule_muc_avatar_fetch_drain(1);
            }
            return false;
        });
    }

    private void drain_muc_avatar_fetch_queue() {
        for (int i = 0; i < muc_avatar_fetch_queue.size; i++) {
            QueuedMucAvatarFetch request = muc_avatar_fetch_queue[i];
            if (!is_current_muc_avatar_fetch(request)) {
                muc_avatar_fetch_queue.remove_at(i);
                if (queued_muc_avatar_fetches[request.key] == request) {
                    queued_muc_avatar_fetches.unset(request.key);
                }
                i--;
                continue;
            }
            if (active_muc_avatar_fetch_accounts.has_key(request.account.id)) continue;

            muc_avatar_fetch_queue.remove_at(i);
            active_muc_avatar_fetch_accounts[request.account.id] = true;
            fetch_and_store_muc_avatar.begin(request, (_, res) => {
                fetch_and_store_muc_avatar.end(res);
                if (is_current_muc_avatar_fetch(request)) {
                    active_muc_avatar_fetch_accounts.unset(request.account.id);
                    if (queued_muc_avatar_fetches[request.key] == request) {
                        queued_muc_avatar_fetches.unset(request.key);
                    }
                    if (!muc_avatar_fetch_queue.is_empty) {
                        schedule_muc_avatar_fetch_drain(MUC_AVATAR_FETCH_INTERVAL_MS);
                    }
                }
            });
            return;
        }

        if (!muc_avatar_fetch_queue.is_empty) {
            schedule_muc_avatar_fetch_drain(MUC_AVATAR_FETCH_INTERVAL_MS);
        }
    }

    private async bool fetch_and_store_muc_avatar(QueuedMucAvatarFetch request) {
        if (!is_current_muc_avatar_fetch(request)) return false;
        ArrayList<AvatarWaiter> active_waiters =
            get_active_muc_avatar_waiters(request.waiters, request.hash);
        if (active_waiters.is_empty) return false;

        if (avatar_bytes_cache.lookup(request.hash) != null) {
            foreach (AvatarWaiter waiter in active_waiters) {
                count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.ALREADY_CACHED);
                fetched_avatar(waiter.jid, waiter.account);
                clear_muc_avatar_fetch_failure(waiter.account, waiter.jid, request.hash);
            }
            return true;
        }

        XmppStream? stream = stream_interactor.get_stream(request.account);
        if (stream == null || !stream.negotiation_complete) {
            foreach (AvatarWaiter waiter in active_waiters) {
                muc_avatar_fetch_failures[muc_avatar_fetch_key(waiter.account, waiter.jid, request.hash)] = get_real_time() / 1000000;
                count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.NO_STREAM);
            }
            return false;
        }

        Bytes? bytes = null;
        bool hash_mismatch = false;
        bool stream_lost = false;
        var attempted = new HashSet<string>();

        // Several occupants can advertise the same content hash. One successful
        // vCard request is enough, but a non-answering occupant must not put all
        // other candidates into cooldown. Try each still-current endpoint once.
        while (bytes == null) {
            if (!is_current_muc_avatar_fetch(request)) return false;
            active_waiters = get_active_muc_avatar_waiters(request.waiters,
                request.hash);
            AvatarWaiter? fetch_waiter = null;
            foreach (AvatarWaiter waiter in active_waiters) {
                if (!attempted.contains(waiter.key())) {
                    fetch_waiter = waiter;
                    break;
                }
            }
            if (fetch_waiter == null) break;

            attempted.add(((!) fetch_waiter).key());
            count_muc_avatar_stat(((!) fetch_waiter).account, ((!) fetch_waiter).jid, MucAvatarStatEvent.FETCH_STARTED);
            Bytes? candidate = yield Xmpp.Xep.VCard.fetch_image(stream, ((!) fetch_waiter).jid, request.hash, false, false);
            if (!is_current_muc_avatar_fetch(request)) return false;
            if (candidate != null) {
                if (avatar_bytes_match_hash((!) candidate, request.hash)) {
                    bytes = candidate;
                    break;
                }
                hash_mismatch = true;
            }

            if (stream_interactor.get_stream(request.account) != stream || !stream.negotiation_complete) {
                stream_lost = true;
                break;
            }
        }
        if (!is_current_muc_avatar_fetch(request)) return false;
        active_waiters = get_active_muc_avatar_waiters(request.waiters,
            request.hash);
        if (active_waiters.is_empty) return false;

        bool success = bytes != null;
        if (success) {
            success = yield store_image_checked(request.hash, (!) bytes);
            if (!is_current_muc_avatar_fetch(request)) return false;
        }
        if (success) {
            // New same-hash waiters can join while the async encrypted cache
            // write is pending. Snapshot again so none miss the ready event.
            active_waiters = get_active_muc_avatar_waiters(request.waiters,
                request.hash);
            foreach (AvatarWaiter waiter in active_waiters) {
                clear_muc_avatar_fetch_failure(waiter.account, waiter.jid, request.hash);
                fetched_avatar(waiter.jid, waiter.account);
                count_muc_avatar_stat(waiter.account, waiter.jid, MucAvatarStatEvent.FETCH_OK);
            }
        } else {
            foreach (AvatarWaiter waiter in active_waiters) {
                muc_avatar_fetch_failures[muc_avatar_fetch_key(waiter.account, waiter.jid, request.hash)] = get_real_time() / 1000000;
                count_muc_avatar_stat(waiter.account, waiter.jid,
                    stream_lost ? MucAvatarStatEvent.NO_STREAM :
                    (bytes != null ? MucAvatarStatEvent.STORE_FAILED :
                    (hash_mismatch ? MucAvatarStatEvent.HASH_MISMATCH : MucAvatarStatEvent.FETCH_FAILED_OR_TIMEOUT)));
            }
        }
        return success;
    }

    private void queue_fetch_for_jid(Account account, Jid jid) {
        if (jid.is_full()) return;

        string key = avatar_fetch_key(account, jid);
        if (is_avatar_fetch_in_cooldown(key)) return;
        if (queued_avatar_fetches.contains(key)) return;
        if (avatar_fetch_queue.size >= MAX_QUEUED_AVATAR_FETCHES) {
            debug("Avatar fetch queue is full; deferring fetch for %s", jid.to_string());
            avatar_fetch_failures[key] = get_real_time() / 1000000;
            return;
        }

        queued_avatar_fetches.add(key);
        avatar_fetch_queue.add(new AvatarWaiter(account, jid, avatar_fetch_queue_generation));
        drain_avatar_fetch_queue();
    }

    private void drain_avatar_fetch_queue() {
        while (active_avatar_fetches < MAX_PARALLEL_AVATAR_FETCHES && !avatar_fetch_queue.is_empty) {
            AvatarWaiter request = avatar_fetch_queue.remove_at(0);
            active_avatar_fetches++;
            fetch_and_store_for_jid.begin(request.account, request.jid, request.generation, (_, res) => {
                fetch_and_store_for_jid.end(res);
                active_avatar_fetches--;
                if (request.generation == avatar_fetch_queue_generation) {
                    queued_avatar_fetches.remove(request.key());
                }
                drain_avatar_fetch_queue();
            });
        }
    }

    private void add_avatar_fetch_waiter(string hash, Account account, Jid jid, int generation) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return;
        if (!avatar_fetch_waiters.has_key((!) normalized_hash)) {
            avatar_fetch_waiters[(!) normalized_hash] = new AvatarWaiterSet();
        }
        avatar_fetch_waiters[(!) normalized_hash].add(account, jid, generation);
    }

    private void notify_avatar_fetch_waiters(string hash, bool success, string? completed_key = null) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null || !avatar_fetch_waiters.has_key((!) normalized_hash)) return;

        AvatarWaiterSet waiters = avatar_fetch_waiters[(!) normalized_hash];
        avatar_fetch_waiters.unset((!) normalized_hash);
        if (!success) return;

        foreach (AvatarWaiter request in waiters.snapshot()) {
            if (request.key() != completed_key &&
                    request.generation == avatar_fetch_queue_generation &&
                    avatar_hashes.get_preferred(request.account.id, request.jid) == normalized_hash &&
                    avatar_bytes_cache.contains((!) normalized_hash)) {
                fetched_avatar(request.jid, request.account);
            }
        }
    }

    private bool is_muc_occupant_avatar_jid(Account account, Jid jid) {
        MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        return jid.is_full() && muc_manager != null && ((!) muc_manager).might_be_groupchat(jid.bare_jid, account);
    }

    private Jid get_avatar_identity(Account account, Jid jid_) {
        Jid jid = jid_;
        MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (muc_manager == null || !((!) muc_manager).is_groupchat_occupant(jid_, account)) {
            jid = jid_.bare_jid;
        }
        return jid;
    }

    private string? get_avatar_hash(Account account, Jid jid_) {
        return avatar_hashes.get_preferred(account.id, get_avatar_identity(account, jid_));
    }

    public bool has_avatar(Account account, Jid jid) {
        return has_avatar_hash(account, jid);
    }

    public bool has_avatar_hash(Account account, Jid jid) {
        return get_avatar_hash(account, jid) != null;
    }

    public bool has_avatar_image_file(Account account, Jid jid) {
        string? hash = get_avatar_hash(account, jid);
        return hash != null && has_image(hash);
    }

    /**
     * Clears in-memory avatar caches. Must be called after DB purge_caches()
     * to ensure consistency between DB and memory state.
     */
    public void purge_in_memory_caches() {
        ArrayList<Account> accounts = stream_interactor.get_accounts();
        foreach (Account account in accounts) {
            // Purging drops every persisted and in-memory avatar hash, not only
            // mutations that happen to be active at this instant. Reverify
            // both own server representations so the current stream recovers
            // without waiting for a reconnect or a new PEP event.
            mark_own_vcard_state_unverified(account);
            mark_own_pep_state_unverified(account);
        }
        foreach (OwnAvatarOperation operation in
                active_own_avatar_operations.values) {
            operation.cancel();
        }
        active_own_avatar_operations.clear();
        own_avatar_operation_generations.clear();
        foreach (Cancellable cancellable in
                own_avatar_pep_resync_cancellables.values) {
            cancellable.cancel();
        }
        own_avatar_pep_resync_cancellables.clear();
        AvatarCacheWorker.invalidate_pending_stores();
        cancel_avatar_cache_async_waiters();
        avatar_hashes.clear();
        pending_fetch.clear();
        pending_avatar_cache_loads.clear();
        avatar_cache_load_waiters.clear();
        deferred_avatar_cache_load_order.clear();
        deferred_avatar_cache_load_waiters.clear();
        avatar_cache_load_generation++;
        avatar_fetch_queue.clear();
        queued_avatar_fetches.clear();
        avatar_fetch_waiters.clear();
        avatar_fetch_failures.clear();
        avatar_fetch_queue_generation++;
        muc_avatar_fetch_queue.clear();
        queued_muc_avatar_fetches.clear();
        muc_avatar_snapshot_tokens.clear();
        muc_avatar_occupant_revisions.clear();
        muc_avatar_fetch_failures.clear();
        muc_avatar_room_budget_used.clear();
        muc_avatar_room_budget_reset_at.clear();
        active_muc_avatar_fetch_accounts.clear();
        muc_avatar_account_generations.clear();
        paused_muc_avatar_accounts.clear();
        paused_muc_avatar_streams.clear();
        paused_muc_avatar_fetches.clear();
        muc_avatar_fetch_generation++;
        if (muc_avatar_fetch_source != 0) {
            GLib.Source.remove(muc_avatar_fetch_source);
            muc_avatar_fetch_source = 0;
        }
        if (muc_avatar_background_resume_source != 0) {
            GLib.Source.remove(muc_avatar_background_resume_source);
            muc_avatar_background_resume_source = 0;
        }
        muc_avatar_background_pause_until_us = 0;
        if (muc_avatar_stats_source != 0) {
            GLib.Source.remove(muc_avatar_stats_source);
            muc_avatar_stats_source = 0;
        }
        muc_avatar_stats.clear();
        avatar_bytes_cache.clear();
        failed_decrypt_hashes.clear();

        foreach (Account account in accounts) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                start_own_vcard_resync_if_required(account, (!) stream);
                start_own_pep_resync_if_required(account, (!) stream);
            }
        }
    }

    public void begin_cache_clear() {
        if (avatar_cache_write_pause_depth < int.MAX) {
            avatar_cache_write_pause_depth++;
        }
        AvatarCacheWorker.invalidate_pending_stores();
    }

    public void finish_cache_clear() {
        purge_in_memory_caches();
        if (avatar_cache_write_pause_depth > 0) {
            avatar_cache_write_pause_depth--;
        }
    }

    internal bool avatar_cache_writes_paused_for_tests() {
        return avatar_cache_write_pause_depth > 0;
    }

    private OwnAvatarOperation begin_own_avatar_operation(Account account,
            XmppStream stream) {
        cancel_own_pep_resync(account);
        OwnAvatarOperation? previous = active_own_avatar_operations[account.id];
        if (previous != null) {
            mark_own_vcard_state_unverified(account);
            mark_own_pep_state_unverified(account);
            ((!) previous).cancel(true);
        }

        int current = own_avatar_operation_generations.has_key(account.id)
            ? own_avatar_operation_generations[account.id] : 0;
        int next = current == int.MAX ? 1 : current + 1;
        own_avatar_operation_generations[account.id] = next;
        var operation = new OwnAvatarOperation(next, stream,
            OWN_AVATAR_OPERATION_TIMEOUT_SECONDS);
        active_own_avatar_operations[account.id] = operation;
        return operation;
    }

    private void mark_own_vcard_state_unverified(Account account,
            bool require_resync = true) {
        if (require_resync) own_avatar_resync_accounts.add(account.id);
        Xep.VCard.Module? vcard_module = stream_interactor.module_manager
            .get_module<Xep.VCard.Module>(account,
                Xep.VCard.Module.IDENTITY);
        bool changed = vcard_module != null &&
            ((!) vcard_module).invalidate_own_avatar_state();
        if (changed && stream_interactor.connection_manager.get_state(
                account) == ConnectionManager.ConnectionState.CONNECTED) {
            resend_own_avatar_presence(account);
        }
    }

    private void mark_own_vcard_state_verified(Account account) {
        own_avatar_resync_accounts.remove(account.id);
    }

    private void mark_own_pep_state_unverified(Account account) {
        own_avatar_pep_resync_accounts.add(account.id);
        // PEP has source priority over vCard. Drop an unverified local PEP
        // claim immediately so the UI cannot keep preferring a stale hash.
        on_user_avatar_removed(account, account.bare_jid);
    }

    private void mark_own_pep_state_verified(Account account) {
        own_avatar_pep_resync_accounts.remove(account.id);
    }

    private void cancel_own_pep_resync(Account account) {
        Cancellable? cancellable =
            own_avatar_pep_resync_cancellables[account.id];
        if (cancellable == null) return;
        ((!) cancellable).cancel();
        own_avatar_pep_resync_cancellables.unset(account.id);
    }

    private bool own_avatar_operation_matches_current(Account account,
            OwnAvatarOperation operation) {
        return active_own_avatar_operations.has_key(account.id) &&
            active_own_avatar_operations[account.id] == operation &&
            own_avatar_operation_generations.has_key(account.id) &&
            own_avatar_operation_generations[account.id] ==
                operation.generation &&
            stream_interactor.get_stream(account) == operation.stream;
    }

    private bool own_avatar_operation_is_current(Account account,
            OwnAvatarOperation operation) {
        return own_avatar_operation_matches_current(account, operation) &&
            !operation.cancellable.is_cancelled();
    }

    private void finish_own_avatar_operation(Account account,
            OwnAvatarOperation operation) {
        operation.finish();
        if (active_own_avatar_operations.has_key(account.id) &&
                active_own_avatar_operations[account.id] == operation) {
            active_own_avatar_operations.unset(account.id);
        }
    }

    private void finish_own_avatar_mutation(Account account,
            OwnAvatarOperation operation,
            OwnAvatarOperationResult? result = null) {
        if (result != null &&
                (((!) result).timed_out ||
                    ((!) result).vcard_ambiguous) &&
                !((!) result).vcard_succeeded &&
                !((!) result).superseded && !((!) result).stale) {
            mark_own_vcard_state_unverified(account);
        }
        if (result != null && ((!) result).pep_ambiguous &&
                !((!) result).pep_succeeded &&
                !((!) result).superseded && !((!) result).stale) {
            mark_own_pep_state_unverified(account);
        }
        finish_own_avatar_operation(account, operation);
        start_own_vcard_resync_if_required(account, operation.stream);
        start_own_pep_resync_if_required(account, operation.stream);
    }

    private void cancel_own_avatar_operation(Account account,
            bool as_superseded = false) {
        OwnAvatarOperation? operation = active_own_avatar_operations[account.id];
        if (operation == null) return;
        ((!) operation).cancel(as_superseded);
        if (active_own_avatar_operations.has_key(account.id) &&
                active_own_avatar_operations[account.id] == operation) {
            active_own_avatar_operations.unset(account.id);
        }
    }

    internal OwnAvatarOperation begin_own_avatar_operation_for_tests(
            Account account, XmppStream stream) {
        return begin_own_avatar_operation(account, stream);
    }

    internal bool own_avatar_operation_is_current_for_tests(Account account,
            OwnAvatarOperation operation) {
        return own_avatar_operation_is_current(account, operation);
    }

    internal void finish_own_avatar_operation_for_tests(Account account,
            OwnAvatarOperation operation) {
        finish_own_avatar_operation(account, operation);
    }

    internal void finish_own_avatar_mutation_for_tests(Account account,
            OwnAvatarOperation operation, OwnAvatarOperationResult result) {
        finish_own_avatar_mutation(account, operation, result);
    }

    internal bool own_avatar_resync_required_for_tests(Account account) {
        return own_avatar_resync_accounts.contains(account.id);
    }

    internal bool own_avatar_pep_resync_required_for_tests(Account account) {
        return own_avatar_pep_resync_accounts.contains(account.id);
    }

    private async OwnAvatarVCardOutcome publish_vcard_avatar_path(
            XmppStream stream,
            Bytes avatar_bytes, Cancellable cancellable) {
        bool set_started = false;
        try {
            Xep.VCard.VCardInfo? vcard = yield Xep.VCard
                .fetch_vcard_checked_with_cancellable(stream, null,
                    cancellable);
            if (vcard == null) vcard = new Xep.VCard.VCardInfo();
            ((!) vcard).photo = avatar_bytes;
            ((!) vcard).photo_type = "image/png";
            Iq.Stanza iq = new Iq.Stanza.set(
                ((!) vcard).to_node().add_self_xmlns());
            set_started = true;
            Iq.Stanza iq_result = yield stream.get_module<Iq.Module>(
                Iq.Module.IDENTITY).send_iq_async(stream, iq,
                    Priority.DEFAULT, cancellable);
            if (iq_result.is_error()) {
                warning("Server rejected vCard-temp avatar publication.");
                return OwnAvatarVCardOutcome.FAILED;
            }
            return OwnAvatarVCardOutcome.SUCCEEDED;
        } catch (Error e) {
            if (!(e is IOError.CANCELLED)) {
                warning("vCard-temp avatar publication did not return a " +
                    "definite result: %s", e.message);
            }
            return set_started ? OwnAvatarVCardOutcome.AMBIGUOUS :
                OwnAvatarVCardOutcome.FAILED;
        }
    }

    private async OwnAvatarOperationResult publish_own_avatar_paths(
            Account account, OwnAvatarOperation operation, uint8[] buffer,
            int width, int height, Bytes avatar_bytes, string sha1) {
        SourceFunc resume = publish_own_avatar_paths.callback;
        var completion = new OwnAvatarParallelCompletion((owned) resume);

        Xep.UserAvatars.publish_png_with_result.begin(operation.stream, buffer,
            width, height, operation.cancellable, (_, result) => {
                Xep.UserAvatars.AvatarPublishResult? pep_result =
                    Xep.UserAvatars.publish_png_with_result.end(result);
                bool succeeded = pep_result != null && pep_result.ok;
                if (succeeded && own_avatar_operation_is_current(account,
                        operation)) {
                    mark_own_pep_state_verified(account);
                    on_user_avatar_received(account, account.bare_jid, sha1);
                }
                completion.complete_pep(succeeded
                    ? OwnAvatarPepOutcome.SUCCEEDED
                    : (pep_result == null || pep_result.ambiguous
                        ? OwnAvatarPepOutcome.AMBIGUOUS
                        : OwnAvatarPepOutcome.FAILED));
            });
        publish_vcard_avatar_path.begin(operation.stream, avatar_bytes,
            operation.cancellable, (_, result) => {
                OwnAvatarVCardOutcome outcome =
                    publish_vcard_avatar_path.end(result);
                bool succeeded = outcome ==
                    OwnAvatarVCardOutcome.SUCCEEDED;
                if (succeeded && own_avatar_operation_is_current(account,
                        operation)) {
                    mark_own_vcard_state_verified(account);
                    handle_vcard_avatar_received(account, account.bare_jid,
                        sha1, false);
                    advertise_own_vcard_avatar(account, sha1, true);
                }
                completion.complete_vcard(outcome);
            });
        yield;

        var operation_result = new OwnAvatarOperationResult();
        operation_result.pep_succeeded = completion.pep_outcome ==
            OwnAvatarPepOutcome.SUCCEEDED;
        operation_result.pep_ambiguous = completion.pep_outcome ==
            OwnAvatarPepOutcome.AMBIGUOUS;
        operation_result.vcard_succeeded = completion.vcard_outcome ==
            OwnAvatarVCardOutcome.SUCCEEDED;
        operation_result.vcard_ambiguous = completion.vcard_outcome ==
            OwnAvatarVCardOutcome.AMBIGUOUS;
        operation_result.timed_out = operation.timed_out;
        operation_result.superseded = operation.superseded;
        operation_result.stale = !operation_result.superseded &&
            !own_avatar_operation_matches_current(account, operation);
        return operation_result;
    }

    internal async OwnAvatarOperationResult
            publish_own_avatar_paths_for_tests(Account account,
                OwnAvatarOperation operation, uint8[] buffer, int width,
                int height, Bytes avatar_bytes, string sha1) {
        return yield publish_own_avatar_paths(account, operation, buffer,
            width, height, avatar_bytes, sha1);
    }

    public async bool publish(Account account, File file) {
        debug("Publish avatar from %s", file.get_uri());
        FileInputStream file_stream = null;
        OwnAvatarOperation? operation = null;
        OwnAvatarOperationResult? operation_result = null;
        try {
            if (looks_like_svg_file(file)) {
                warning("AvatarManager: Refusing to publish SVG/SVGZ avatar (avoids Flatpak SVG loader crash).");
                return false;
            }
            file_stream = file.read();
            Pixbuf pixbuf = new Pixbuf.from_stream(file_stream);
            if (pixbuf.width >= pixbuf.height && pixbuf.width > MAX_PIXEL) {
                int dest_height = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.width * pixbuf.height));
                pixbuf = pixbuf.scale_simple(MAX_PIXEL, dest_height, InterpType.BILINEAR);
            } else if (pixbuf.height > pixbuf.width && pixbuf.height > MAX_PIXEL) {
                int dest_width = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.height * pixbuf.width));
                pixbuf = pixbuf.scale_simple(dest_width, MAX_PIXEL, InterpType.BILINEAR);
            }
            uint8[] buffer = pixbuf_to_png_bytes(pixbuf);
            XmppStream? maybe_stream = stream_interactor.get_stream(account);
            if (maybe_stream == null) {
                warning("No stream when trying to publish.");
                return false;
            }

            XmppStream stream = (!) maybe_stream;
            Bytes avatar_bytes = new Bytes(buffer);
            string sha1 = Checksum.compute_for_data(ChecksumType.SHA1,
                buffer);

            // Keep the selected image immediately available to the UI. Disk
            // persistence starts only after at least one server path accepts
            // the avatar and must never block either protocol publication.
            cache_avatar_bytes(sha1, avatar_bytes);
            operation = begin_own_avatar_operation(account, stream);
            OwnAvatarOperationResult result = yield publish_own_avatar_paths(
                account, (!) operation, buffer, pixbuf.width, pixbuf.height,
                avatar_bytes, sha1);
            operation_result = result;
            ((!) operation).finish();
            if (result.any_succeeded() && !result.superseded &&
                    !result.stale) {
                store_image_in_background(sha1, avatar_bytes);
            }
            if (!result.superseded && !result.stale &&
                    result.partially_succeeded()) {
                warning("Avatar publication only partially succeeded " +
                    "(PEP=%s, vCard=%s).",
                    result.pep_status(),
                    result.vcard_status());
            } else if (!result.superseded && !result.stale &&
                    !result.any_succeeded() && !result.vcard_ambiguous &&
                    !result.pep_ambiguous) {
                warning("Avatar publication failed on both server paths%s.",
                    result.timed_out ? " after timeout" : "");
            }
            return result.any_succeeded() || result.superseded;
        } catch (Error e) {
            warning(e.message);
            return false;
        } finally {
            if (operation != null) {
                finish_own_avatar_mutation(account, (!) operation,
                    operation_result);
            }
            try {
                if (file_stream != null) file_stream.close();
            } catch (Error e) {
                // Ignore
            }
        }
    }

    public void unset_avatar(Account account) {
        unset_avatar_async.begin(account, (_, res) => {
            OwnAvatarOperationResult result = unset_avatar_async.end(res);
            if (!result.superseded && !result.stale &&
                    !result.any_succeeded() && !result.vcard_ambiguous &&
                    !result.pep_ambiguous) {
                warning("Avatar removal was not accepted by either server path.");
            }
        });
    }

    private async OwnAvatarOperationResult unset_avatar_async(Account account) {
        XmppStream? maybe_stream = stream_interactor.get_stream(account);
        if (maybe_stream == null) return new OwnAvatarOperationResult();

        OwnAvatarOperation operation = begin_own_avatar_operation(account,
            (!) maybe_stream);
        OwnAvatarOperationResult? operation_result = null;
        try {
            OwnAvatarOperationResult result = yield remove_own_avatar_paths(
                account, operation);
            operation_result = result;
            operation.finish();
            if (!result.superseded && !result.stale &&
                    result.partially_succeeded()) {
                warning("Avatar removal only partially succeeded " +
                    "(PEP=%s, vCard=%s). The remaining server path was " +
                    "left unchanged.", result.pep_status(),
                    result.vcard_status());
            }
            return result;
        } finally {
            finish_own_avatar_mutation(account, operation,
                operation_result);
        }
    }

    private async OwnAvatarOperationResult remove_own_avatar_paths(
            Account account, OwnAvatarOperation operation) {
        SourceFunc resume = remove_own_avatar_paths.callback;
        var completion = new OwnAvatarParallelCompletion((owned) resume);

        Xep.UserAvatars.unset_avatar_with_result.begin(operation.stream,
            operation.cancellable, (_, result) => {
                Xep.UserAvatars.AvatarPublishResult? pep_result =
                    Xep.UserAvatars.unset_avatar_with_result.end(result);
                bool succeeded = pep_result != null && pep_result.ok;
                if (succeeded && own_avatar_operation_is_current(account,
                        operation)) {
                    mark_own_pep_state_verified(account);
                    on_user_avatar_removed(account, account.bare_jid);
                }
                completion.complete_pep(succeeded
                    ? OwnAvatarPepOutcome.SUCCEEDED
                    : (pep_result == null || pep_result.ambiguous
                        ? OwnAvatarPepOutcome.AMBIGUOUS
                        : OwnAvatarPepOutcome.FAILED));
            });
        unset_vcard_avatar_remote.begin(operation.stream,
            operation.cancellable, (_, result) => {
                OwnAvatarVCardOutcome outcome =
                    unset_vcard_avatar_remote.end(result);
                bool succeeded = outcome ==
                    OwnAvatarVCardOutcome.SUCCEEDED;
                if (succeeded && own_avatar_operation_is_current(account,
                        operation)) {
                    mark_own_vcard_state_verified(account);
                    apply_vcard_avatar_removal(account);
                }
                completion.complete_vcard(outcome);
            });
        yield;

        var operation_result = new OwnAvatarOperationResult();
        operation_result.pep_succeeded = completion.pep_outcome ==
            OwnAvatarPepOutcome.SUCCEEDED;
        operation_result.pep_ambiguous = completion.pep_outcome ==
            OwnAvatarPepOutcome.AMBIGUOUS;
        operation_result.vcard_succeeded = completion.vcard_outcome ==
            OwnAvatarVCardOutcome.SUCCEEDED;
        operation_result.vcard_ambiguous = completion.vcard_outcome ==
            OwnAvatarVCardOutcome.AMBIGUOUS;
        operation_result.timed_out = operation.timed_out;
        operation_result.superseded = operation.superseded;
        operation_result.stale = !operation_result.superseded &&
            !own_avatar_operation_matches_current(account, operation);
        return operation_result;
    }

    private async OwnAvatarVCardOutcome unset_vcard_avatar_remote(
            XmppStream stream,
            Cancellable cancellable) {
        bool set_started = false;
        try {
            Iq.Stanza iq = new Iq.Stanza.get(new StanzaNode.build("vCard", "vcard-temp").add_self_xmlns());
            Iq.Stanza iq_res = yield stream.get_module<Iq.Module>(
                Iq.Module.IDENTITY).send_iq_async(stream, iq,
                    Priority.DEFAULT, cancellable);

            // Create a new vCard node to ensure clean state
            StanzaNode new_vcard = new StanzaNode.build("vCard", "vcard-temp");
            new_vcard.add_self_xmlns();

            if (iq_res.is_error()) {
                ErrorStanza? stanza_error = iq_res.get_error();
                if (stanza_error == null || ((!) stanza_error).condition !=
                        ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
                    return OwnAvatarVCardOutcome.FAILED;
                }
            } else {
                StanzaNode? vcard = iq_res.stanza.get_subnode("vCard",
                    "vcard-temp");
                if (vcard != null) {
                    // Preserve every profile field, including extensions that
                    // VCardInfo does not parse, and remove only PHOTO.
                    foreach (var child in ((!) vcard).sub_nodes) {
                        if (child.name != "PHOTO") new_vcard.put_node(child);
                    }
                }
            }

            Iq.Stanza iq_set = new Iq.Stanza.set(new_vcard);
            set_started = true;
            Iq.Stanza iq_set_res = yield stream.get_module<Iq.Module>(
                Iq.Module.IDENTITY).send_iq_async(stream, iq_set,
                    Priority.DEFAULT, cancellable);
            if (iq_set_res.is_error()) return OwnAvatarVCardOutcome.FAILED;
            return OwnAvatarVCardOutcome.SUCCEEDED;
        } catch (Error e) {
            if (!(e is IOError.CANCELLED)) {
                warning("vCard avatar removal did not return a definite " +
                    "result: %s", e.message);
            }
            return set_started ? OwnAvatarVCardOutcome.AMBIGUOUS :
                OwnAvatarVCardOutcome.FAILED;
        }
    }

    private void apply_vcard_avatar_removal(Account account) {
        Jid jid = account.bare_jid;
        bool preferred_changed;
        bool removed = avatar_hashes.remove(account.id, jid,
            AvatarSource.VCARD, out preferred_changed);
        remove_avatar_hash(account, jid, AvatarSource.VCARD);
        // Avatar files are content-addressed and may still be referenced by
        // another contact or account. Cache eviction owns their lifetime.
        if (removed && preferred_changed) received_avatar(jid, account);
        advertise_own_vcard_avatar(account, null, true);
    }

    private void advertise_own_vcard_avatar(Account account, string? hash,
            bool force) {
        Xep.VCard.Module? vcard_module = stream_interactor.module_manager
            .get_module<Xep.VCard.Module>(account, Xep.VCard.Module.IDENTITY);
        if (vcard_module == null) return;
        bool changed = ((!) vcard_module).set_own_avatar_hash(hash);
        if (!changed && !force) return;

        resend_own_avatar_presence(account);
    }

    private void resend_own_avatar_presence(Account account) {
        PresenceManager? presence_manager = stream_interactor.get_module<
            PresenceManager>(PresenceManager.IDENTITY);
        if (presence_manager != null) {
            ((!) presence_manager).resend_presence(account);
        }
        MucManager? current_muc_manager = stream_interactor.get_module<
            MucManager>(MucManager.IDENTITY);
        if (current_muc_manager != null) {
            ((!) current_muc_manager).resend_own_presence_to_joined_rooms(
                account);
        }
    }

    private void on_account_added(Account account) {
        stream_interactor.module_manager.get_module<Xep.UserAvatars.Module>(account, Xep.UserAvatars.Module.IDENTITY).received_avatar_hash.connect((stream, jid, id) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            if (AvatarHashStore.normalize_hash(id) == null) return;
            on_user_avatar_received(account, jid, id);
            if (jid.bare_jid.equals(account.bare_jid)) {
                mark_own_pep_state_verified(account);
                cancel_own_pep_resync(account);
            }
        });
        stream_interactor.module_manager.get_module<Xep.UserAvatars.Module>(account, Xep.UserAvatars.Module.IDENTITY).avatar_removed.connect((stream, jid) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            on_user_avatar_removed(account, jid);
            if (jid.bare_jid.equals(account.bare_jid)) {
                mark_own_pep_state_verified(account);
                cancel_own_pep_resync(account);
            }
        });
        Xep.VCard.Module vcard_module = stream_interactor.module_manager
            .get_module<Xep.VCard.Module>(account, Xep.VCard.Module.IDENTITY);
        vcard_module.received_avatar_hash.connect((stream, jid, id) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            on_vcard_avatar_received(account, jid, id);
        });
        vcard_module.avatar_removed.connect((stream, jid) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            on_vcard_avatar_removed(account, jid);
        });
        vcard_module.own_avatar_state_reset_requested.connect((stream,
                refetch) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            mark_own_vcard_state_unverified(account, refetch);
            if (refetch) {
                start_own_vcard_resync_if_required(account, stream);
            }
        });
        stream_interactor.module_manager.get_module<Presence.Module>(account, Presence.Module.IDENTITY).received_unavailable.connect((stream, presence) => {
            if (!stream_interactor.connection_manager
                    .is_current_or_provisionally_retained_stream(account,
                        stream)) return;
            on_presence_unavailable(account, presence);
        });

        // No need to re-load hashes from DB here — the constructor already
        // pre-loaded all account-scoped avatar hashes into avatar_hashes.
        // The old code did get_avatar_hashes() + on_*_received() which caused
        // redundant DB reads and unnecessary received_avatar signal emissions.
    }

    private void on_account_removed(Account account) {
        cancel_own_avatar_operation(account);
        cancel_own_pep_resync(account);
        own_avatar_operation_generations.unset(account.id);
        own_avatar_resync_accounts.remove(account.id);
        own_avatar_resync_pending_accounts.remove(account.id);
        own_avatar_pep_resync_accounts.remove(account.id);
        paused_muc_avatar_accounts.remove(account.id);
        paused_muc_avatar_streams.unset(account.id);
        remove_paused_muc_avatar_fetches(account.id);
        remove_avatar_observers_for_account(account.id);
        cancel_avatar_cache_async_waiters_for_account(account.id);
        clear_account_avatar_work(account, true);
        avatar_hashes.remove_account(account.id);
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;
        // StreamInteractor emits this only for a genuinely fresh session, not
        // for XEP-0198 resumption. Occupant Full-JIDs belong to the previous
        // MUC session and are invalid only at this boundary.
        paused_muc_avatar_accounts.remove(account.id);
        paused_muc_avatar_streams.unset(account.id);
        remove_paused_muc_avatar_fetches(account.id);
        clear_account_avatar_work(account, false);
        avatar_hashes.remove_full_jids(account.id, AvatarSource.USER_AVATARS);
        avatar_hashes.remove_full_jids(account.id, AvatarSource.VCARD);
        // A fresh stream has no verified XEP-0153 server state. Keep a durable
        // same-session retry marker until the initial vCard readback succeeds,
        // so a transient GET failure is retried on XEP-0198 resume/recovery.
        mark_own_vcard_state_unverified(account);
        start_own_vcard_sync(account, stream);
        start_own_pep_resync_if_required(account, stream);
    }

    private void start_own_vcard_sync(Account account, XmppStream stream) {
        synchronize_own_vcard_avatar.begin(account, stream, (_, res) => {
            synchronize_own_vcard_avatar.end(res);
        });
    }

    private void start_own_vcard_resync_if_required(Account account,
            XmppStream stream) {
        if (!own_avatar_resync_accounts.contains(account.id) ||
                stream_interactor.get_stream(account) != stream ||
                stream_interactor.connection_manager.get_state(account) !=
                    ConnectionManager.ConnectionState.CONNECTED) return;
        OwnAvatarOperation? active = active_own_avatar_operations[account.id];
        if (active != null && !((!) active).cancellable.is_cancelled()) {
            // A resume/recovery signal can race the final callback of the
            // initial readback. Remember it once so the completed operation
            // cannot swallow the only same-stream retry opportunity.
            own_avatar_resync_pending_accounts.add(account.id);
            return;
        }
        own_avatar_resync_pending_accounts.remove(account.id);
        start_own_vcard_sync(account, stream);
    }

    private void start_own_pep_resync_if_required(Account account,
            XmppStream stream) {
        if (!own_avatar_pep_resync_accounts.contains(account.id) ||
                own_avatar_pep_resync_cancellables.has_key(account.id) ||
                stream_interactor.get_stream(account) != stream ||
                stream_interactor.connection_manager.get_state(account) !=
                    ConnectionManager.ConnectionState.CONNECTED) return;
        OwnAvatarOperation? active = active_own_avatar_operations[account.id];
        if (active != null && !((!) active).cancellable.is_cancelled()) return;
        if (stream.get_module<Iq.Module>(Iq.Module.IDENTITY) == null ||
                stream.get_module<Xep.Pubsub.Module>(
                    Xep.Pubsub.Module.IDENTITY) == null) return;

        int generation = own_avatar_operation_generations.has_key(account.id)
            ? own_avatar_operation_generations[account.id] : 0;
        var cancellable = new Cancellable();
        own_avatar_pep_resync_cancellables[account.id] = cancellable;
        synchronize_own_pep_avatar.begin(account, stream, generation,
            cancellable, (_, result) => {
                synchronize_own_pep_avatar.end(result);
            });
    }

    private async void synchronize_own_pep_avatar(Account account,
            XmppStream stream, int generation, Cancellable cancellable) {
        Xep.UserAvatars.AvatarMetadataResult? result = null;
        try {
            result = yield Xep.UserAvatars.fetch_current_avatar(stream,
                account.bare_jid, cancellable);
        } finally {
            Cancellable? current =
                own_avatar_pep_resync_cancellables[account.id];
            if (current == cancellable) {
                own_avatar_pep_resync_cancellables.unset(account.id);
            }
        }

        int current_generation = own_avatar_operation_generations.has_key(
            account.id) ? own_avatar_operation_generations[account.id] : 0;
        if (result == null || !((!) result).ok ||
                cancellable.is_cancelled() ||
                current_generation != generation ||
                stream_interactor.get_stream(account) != stream ||
                active_own_avatar_operations.has_key(account.id) ||
                !own_avatar_pep_resync_accounts.contains(account.id)) return;

        string? hash = ((!) result).hash;
        if (hash != null && AvatarHashStore.normalize_hash((!) hash) == null) {
            return;
        }
        if (hash == null) {
            on_user_avatar_removed(account, account.bare_jid);
        } else {
            on_user_avatar_received(account, account.bare_jid, (!) hash);
        }
        mark_own_pep_state_verified(account);
    }

    private async void synchronize_own_vcard_avatar(Account account,
            XmppStream stream) {
        // Synthetic lifecycle streams used by tests and teardown paths can be
        // intentionally module-less. A real negotiated account stream always
        // has the mandatory IQ module.
        if (stream.get_module<Iq.Module>(Iq.Module.IDENTITY) == null) return;
        OwnAvatarOperation? active = active_own_avatar_operations[account.id];
        if (active != null && !((!) active).cancellable.is_cancelled()) return;
        OwnAvatarOperation operation = begin_own_avatar_operation(account,
            stream);
        try {
            Xep.VCard.VCardInfo? vcard = yield Xep.VCard
                .fetch_vcard_checked_with_cancellable(stream, null,
                    operation.cancellable);
            if (!own_avatar_operation_is_current(account, operation)) return;
            operation.finish();

            Bytes? photo = vcard != null ? ((!) vcard).photo : null;
            string? hash = null;
            if (photo != null && ((!) photo).get_size() > 0) {
                hash = Checksum.compute_for_bytes(ChecksumType.SHA1,
                    (!) photo);
                cache_avatar_bytes((!) hash, (!) photo);
                store_image_in_background((!) hash, (!) photo);
                handle_vcard_avatar_received(account, account.bare_jid,
                    (!) hash, false);
            } else {
                handle_vcard_avatar_removed(account, account.bare_jid, false);
            }

            mark_own_vcard_state_verified(account);
            advertise_own_vcard_avatar(account, hash, false);
        } catch (Error e) {
            if (!(e is IOError.CANCELLED)) {
                // Keep the stream-scoped state unknown on transient failures;
                // XEP-0153 then advertises support without a stale photo hash.
                debug("Could not synchronize own vCard avatar: %s", e.message);
            }
        } finally {
            finish_own_avatar_operation(account, operation);
            if (own_avatar_resync_pending_accounts.remove(account.id)) {
                start_own_vcard_resync_if_required(account, stream);
            }
            start_own_pep_resync_if_required(account, stream);
        }
    }

    private void on_connection_state_changed(Account account, ConnectionManager.ConnectionState state) {
        if (state == ConnectionManager.ConnectionState.DISCONNECTED) {
            bool interrupted_own_avatar_operation =
                active_own_avatar_operations.has_key(account.id);
            cancel_own_avatar_operation(account);
            cancel_own_pep_resync(account);
            if (interrupted_own_avatar_operation) {
                mark_own_vcard_state_unverified(account);
                mark_own_pep_state_unverified(account);
            }
            XmppStream? tracked_stream = stream_interactor.connection_manager
                .get_provisionally_retained_stream(account);
            bool replacement_pending = stream_interactor.connection_manager
                .is_stream_replacement_pending(account);
            if (tracked_stream == null && !replacement_pending) {
                paused_muc_avatar_accounts.remove(account.id);
                paused_muc_avatar_streams.unset(account.id);
                remove_paused_muc_avatar_fetches(account.id);
                clear_account_avatar_work(account, false);
                avatar_hashes.remove_full_jids(account.id,
                    AvatarSource.USER_AVATARS);
                avatar_hashes.remove_full_jids(account.id,
                    AvatarSource.VCARD);
                return;
            }
            // NetworkMonitor also emits DISCONNECTED while retaining the same
            // stream for a recovery ping. Preserve the addressable Full-JID
            // hashes and local snapshot work, but fence network IQs that may be
            // suspended on an unreachable transport.
            paused_muc_avatar_accounts.add(account.id);
            if (tracked_stream != null) {
                paused_muc_avatar_streams[account.id] = (!) tracked_stream;
            } else {
                paused_muc_avatar_streams.unset(account.id);
            }
            invalidate_account_muc_avatar_network_work(account);
        } else if (state == ConnectionManager.ConnectionState.CONNECTED) {
            XmppStream? paused_stream = paused_muc_avatar_streams[account.id];
            XmppStream? current_stream = stream_interactor.get_stream(account);
            if (paused_stream != null && current_stream == paused_stream) {
                resume_muc_avatar_work(account);
                start_own_vcard_resync_if_required(account,
                    (!) current_stream);
                start_own_pep_resync_if_required(account,
                    (!) current_stream);
            }
        }
    }

    private void on_stream_resumed(Account account, XmppStream stream) {
        if (stream_interactor.get_stream(account) != stream) return;
        if (paused_muc_avatar_accounts.contains(account.id)) {
            resume_muc_avatar_work(account);
        }
        start_own_vcard_resync_if_required(account, stream);
        start_own_pep_resync_if_required(account, stream);
    }

    private void resume_muc_avatar_work(Account account) {
        if (!paused_muc_avatar_accounts.remove(account.id)) return;
        paused_muc_avatar_streams.unset(account.id);
        requeue_paused_muc_avatar_fetches(account);
    }

    private void remember_paused_muc_avatar_fetch(Account account, Jid jid,
            string hash) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null || !is_current_muc_avatar_request(account,
                jid, (!) normalized_hash)) return;

        string key = muc_avatar_fetch_work_key(account, jid,
            (!) normalized_hash);
        QueuedMucAvatarFetch? retained = paused_muc_avatar_fetches[key];
        if (retained == null) {
            if (paused_muc_avatar_fetches.size >=
                    MAX_QUEUED_MUC_AVATAR_FETCHES) return;
            retained = new QueuedMucAvatarFetch(account, (!) normalized_hash,
                key, muc_avatar_fetch_generation,
                get_muc_avatar_account_generation(account.id));
            paused_muc_avatar_fetches[key] = (!) retained;
        }
        ((!) retained).waiters.add(account, jid,
            get_muc_avatar_account_generation(account.id));
    }

    private void requeue_paused_muc_avatar_fetches(Account account) {
        var retained = new ArrayList<QueuedMucAvatarFetch>();
        var keys = new ArrayList<string>();
        foreach (var entry in paused_muc_avatar_fetches.entries) {
            if (entry.value.account.id != account.id) continue;
            retained.add(entry.value);
            keys.add(entry.key);
        }
        foreach (string key in keys) paused_muc_avatar_fetches.unset(key);

        foreach (QueuedMucAvatarFetch request in retained) {
            foreach (AvatarWaiter waiter in request.waiters.snapshot()) {
                queue_muc_avatar_network_fetch(waiter.account, waiter.jid,
                    request.hash);
            }
        }
    }

    private void remove_paused_muc_avatar_fetches(int account_id) {
        var keys = new ArrayList<string>();
        foreach (var entry in paused_muc_avatar_fetches.entries) {
            if (entry.value.account.id == account_id) keys.add(entry.key);
        }
        foreach (string key in keys) paused_muc_avatar_fetches.unset(key);
    }

    private void invalidate_account_muc_avatar_network_work(Account account) {
        int account_id = account.id;
        var request_keys = new ArrayList<string>();
        foreach (var entry in queued_muc_avatar_fetches.entries) {
            if (entry.value.account.id == account_id) {
                if (paused_muc_avatar_accounts.contains(account_id)) {
                    foreach (AvatarWaiter waiter in
                            entry.value.waiters.snapshot()) {
                        remember_paused_muc_avatar_fetch(waiter.account,
                            waiter.jid, entry.value.hash);
                    }
                }
                refund_queued_muc_avatar_room_budget(entry.value);
                request_keys.add(entry.key);
            }
        }
        bump_muc_avatar_account_generation(account_id);

        for (int i = muc_avatar_fetch_queue.size - 1; i >= 0; i--) {
            if (muc_avatar_fetch_queue[i].account.id == account_id) {
                muc_avatar_fetch_queue.remove_at(i);
            }
        }
        foreach (string key in request_keys) {
            queued_muc_avatar_fetches.unset(key);
        }
        active_muc_avatar_fetch_accounts.unset(account_id);

        if (muc_avatar_fetch_queue.is_empty && muc_avatar_fetch_source != 0) {
            GLib.Source.remove(muc_avatar_fetch_source);
            muc_avatar_fetch_source = 0;
        } else if (!muc_avatar_fetch_queue.is_empty &&
                muc_avatar_fetch_source == 0) {
            // A fenced active request will deliberately not run its stale
            // completion callback. Keep work for other accounts moving.
            schedule_muc_avatar_fetch_drain(1);
        }
    }

    private void refund_queued_muc_avatar_room_budget(
            QueuedMucAvatarFetch request) {
        foreach (AvatarWaiter waiter in request.waiters.snapshot()) {
            string room_key = muc_avatar_room_key(waiter.account, waiter.jid);
            if (!muc_avatar_room_budget_used.has_key(room_key)) return;
            int used = muc_avatar_room_budget_used[room_key];
            if (used <= 1) {
                muc_avatar_room_budget_used.unset(room_key);
            } else {
                muc_avatar_room_budget_used[room_key] = used - 1;
            }
            return;
        }
    }

    private void clear_account_avatar_work(Account account, bool include_contact_work) {
        int account_id = account.id;
        invalidate_account_muc_avatar_network_work(account);
        remove_account_prefixed_keys(muc_avatar_fetch_failures, account_id);
        remove_account_prefixed_keys(muc_avatar_room_budget_used, account_id);
        remove_account_prefixed_keys(muc_avatar_room_budget_reset_at, account_id);
        remove_account_prefixed_keys(muc_avatar_stats, account_id);
        remove_account_prefixed_keys(muc_avatar_snapshot_tokens, account_id);
        remove_account_prefixed_keys(muc_avatar_occupant_revisions,
            account_id);

        if (include_contact_work) {
            for (int i = avatar_fetch_queue.size - 1; i >= 0; i--) {
                AvatarWaiter request = avatar_fetch_queue[i];
                if (request.account.id != account_id) continue;
                avatar_fetch_queue.remove_at(i);
                queued_avatar_fetches.remove(request.key());
            }

            var empty_hashes = new ArrayList<string>();
            foreach (var entry in avatar_fetch_waiters.entries) {
                entry.value.remove_account(account_id);
                if (entry.value.is_empty) empty_hashes.add(entry.key);
            }
            foreach (string hash in empty_hashes) avatar_fetch_waiters.unset(hash);
            remove_account_prefixed_keys(avatar_fetch_failures, account_id);

            foreach (AvatarWaiterSet waiters in avatar_cache_load_waiters.values) {
                waiters.remove_account(account_id);
            }
            var empty_deferred_hashes = new ArrayList<string>();
            foreach (var entry in deferred_avatar_cache_load_waiters.entries) {
                entry.value.remove_account(account_id);
                if (entry.value.is_empty) empty_deferred_hashes.add(entry.key);
            }
            foreach (string hash in empty_deferred_hashes) {
                deferred_avatar_cache_load_waiters.unset(hash);
                deferred_avatar_cache_load_order.remove(hash);
            }
        }
    }

    private void remove_account_prefixed_keys<V>(HashMap<string, V> map, int account_id) {
        string prefix = account_id.to_string() + "\n";
        var keys = new ArrayList<string>();
        foreach (string key in map.keys) {
            if (key.has_prefix(prefix)) keys.add(key);
        }
        foreach (string key in keys) map.unset(key);
    }

    private void on_presence_unavailable(Account account, Presence.Stanza presence) {
        Jid jid = presence.from;
        if (jid.is_bare()) return;

        bool preferred_changed;
        bool removed = avatar_hashes.remove(account.id, jid, AvatarSource.VCARD, out preferred_changed);
        if (removed && preferred_changed) received_avatar(jid, account);
    }

    internal void on_user_avatar_received(Account account, Jid jid_, string id) {
        Jid jid = jid_.bare_jid;

        bool preferred_changed;
        if (avatar_hashes.update_hash(account.id, jid, id, AvatarSource.USER_AVATARS, out preferred_changed)) {
            string? normalized_id = avatar_hashes.get_source(account.id, jid, AvatarSource.USER_AVATARS);
            set_avatar_hash(account, jid, (!) normalized_id, AvatarSource.USER_AVATARS);
            if (preferred_changed) received_avatar(jid, account);
        }
        clear_avatar_fetch_failure(account, jid);
    }

    internal void on_user_avatar_removed(Account account, Jid jid_) {
        Jid jid = jid_.bare_jid;
        bool preferred_changed;
        bool removed = avatar_hashes.remove(account.id, jid, AvatarSource.USER_AVATARS, out preferred_changed);
        remove_avatar_hash(account, jid, AvatarSource.USER_AVATARS);
        if (removed && preferred_changed) received_avatar(jid, account);
    }

    public void on_vcard_avatar_received(Account account, Jid jid_, string id) {
        bool is_gc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(jid_.bare_jid, account);
        handle_vcard_avatar_received(account, jid_, id, is_gc);
    }

    internal void handle_vcard_avatar_received(Account account, Jid jid_, string id, bool is_gc) {
        string? normalized_id = AvatarHashStore.normalize_hash(id);
        if (normalized_id == null) return;
        Jid jid = is_gc ? jid_ : jid_.bare_jid;

        bool preferred_changed;
        if (avatar_hashes.update_hash(account.id, jid, (!) normalized_id, AvatarSource.VCARD, out preferred_changed)) {
            if (jid.is_bare()) { // don't save MUC occupant avatars
                set_avatar_hash(account, jid, (!) normalized_id, AvatarSource.VCARD);
            }
            if (preferred_changed) received_avatar(jid, account);
        }
        clear_avatar_fetch_failure(account, jid);
        if (is_gc && jid.is_full()) {
            count_muc_avatar_stat(account, jid, MucAvatarStatEvent.HASH_SEEN);
        }
    }

    internal string? get_avatar_source_hash_for_tests(Account account, Jid jid,
            AvatarSource source) {
        return avatar_hashes.get_source(account.id, jid, source);
    }

    internal async bool store_verified_muc_room_avatar_image(
            Xep.MucAvatars.FetchedRoomAvatar avatar) {
        return yield store_image_checked(avatar.hash, avatar.bytes, true);
    }

    internal async MucRoomAvatarCacheProbe probe_muc_room_avatar_image(
            string hash) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return MucRoomAvatarCacheProbe.MISS;
        if (avatar_bytes_cache.lookup((!) normalized_hash) != null) {
            return MucRoomAvatarCacheProbe.HIT;
        }
        if (failed_decrypt_hashes.contains((!) normalized_hash)) {
            return MucRoomAvatarCacheProbe.MISS;
        }

        int generation = avatar_cache_load_generation;
        try {
            AvatarCacheWorkerResult result = yield AvatarCacheWorker
                .load_verified(
                Path.build_filename(folder, (!) normalized_hash),
                file_encryption, (!) normalized_hash);
            if (generation != avatar_cache_load_generation) {
                return MucRoomAvatarCacheProbe.BUSY;
            }
            cache_avatar_bytes((!) normalized_hash, result.bytes);
            return MucRoomAvatarCacheProbe.HIT;
        } catch (AvatarCacheWorkerError.NOT_FOUND error) {
            return MucRoomAvatarCacheProbe.MISS;
        } catch (AvatarCacheWorkerError.QUEUE_FULL error) {
            return MucRoomAvatarCacheProbe.BUSY;
        } catch (AvatarCacheWorkerError.CORRUPT error) {
            if (failed_decrypt_hashes.size >= MAX_FAILED_DECRYPT_HASHES) {
                failed_decrypt_hashes.clear();
            }
            failed_decrypt_hashes.add((!) normalized_hash);
            return MucRoomAvatarCacheProbe.MISS;
        } catch (AvatarCacheWorkerError.TOO_LARGE error) {
            return MucRoomAvatarCacheProbe.MISS;
        } catch (Error error) {
            debug("Could not load cached MUC room avatar %s: %s",
                (!) normalized_hash, error.message);
            return MucRoomAvatarCacheProbe.MISS;
        }
    }

    internal void commit_muc_room_vcard_hash(Account account, Jid room,
            string hash, bool bytes_ready) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return;
        Jid bare_room = room.bare_jid;
        string? previous = avatar_hashes.get_source(account.id, bare_room,
            AvatarSource.VCARD);
        handle_vcard_avatar_received(account, bare_room,
            (!) normalized_hash, true);
        if (bytes_ready && previous == normalized_hash) {
            fetched_avatar(bare_room, account);
        }
    }

    internal int get_muc_avatar_account_generation_for_tests(Account account) {
        return get_muc_avatar_account_generation(account.id);
    }

    internal bool is_muc_avatar_account_paused_for_tests(Account account) {
        return paused_muc_avatar_accounts.contains(account.id);
    }

    internal void queue_muc_avatar_network_fetch_for_tests(Account account,
            Jid jid, string hash) {
        queue_muc_avatar_network_fetch(account, jid, hash);
    }

    internal int get_paused_muc_avatar_fetch_count_for_tests(Account account) {
        int count = 0;
        foreach (QueuedMucAvatarFetch request in
                paused_muc_avatar_fetches.values) {
            if (request.account.id == account.id) count++;
        }
        return count;
    }

    internal int get_queued_muc_avatar_fetch_count_for_tests(Account account) {
        int count = 0;
        foreach (QueuedMucAvatarFetch request in
                queued_muc_avatar_fetches.values) {
            if (request.account.id == account.id) count++;
        }
        return count;
    }

    private void on_vcard_avatar_removed(Account account, Jid jid_) {
        bool is_gc = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).might_be_groupchat(jid_.bare_jid, account);
        handle_vcard_avatar_removed(account, jid_, is_gc);
    }

    internal void handle_vcard_avatar_removed(Account account, Jid jid_, bool is_gc) {
        Jid jid = is_gc ? jid_ : jid_.bare_jid;
        bool preferred_changed;
        bool removed = avatar_hashes.remove(account.id, jid, AvatarSource.VCARD, out preferred_changed);
        if (jid.is_bare()) remove_avatar_hash(account, jid, AvatarSource.VCARD);
        if (removed && preferred_changed) received_avatar(jid, account);
    }

    /** Remove a vCard avatar from memory, DB, and notify UI. Used for MUC room avatar removal. */
    public void remove_vcard_avatar(Account account, Jid jid) {
        bool preferred_changed;
        bool removed = avatar_hashes.remove(account.id, jid, AvatarSource.VCARD, out preferred_changed);
        remove_avatar_hash(account, jid, AvatarSource.VCARD);
        if (removed && preferred_changed) received_avatar(jid, account);
    }

    public void set_avatar_hash(Account account, Jid jid, string hash, int type) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        if (normalized_hash == null) return;
        db.avatar.insert()
            .value(db.avatar.jid_id, db.get_jid_id(jid))
            .value(db.avatar.account_id, account.id)
            .value(db.avatar.hash, (!) normalized_hash)
            .value(db.avatar.type_, type)
            .perform();
    }

    public void remove_avatar_hash(Account account, Jid jid, int type) {
        db.avatar.delete()
            .with(db.avatar.jid_id, "=", db.get_jid_id(jid))
            .with(db.avatar.account_id, "=", account.id)
            .with(db.avatar.type_, "=", type)
            .perform();
    }

    public HashMap<Jid, string> get_avatar_hashes(Account account, int type) {
        HashMap<Jid, string> ret = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
        foreach (Row row in db.avatar.select({db.avatar.jid_id, db.avatar.hash})
                .with(db.avatar.type_, "=", type)
                .with(db.avatar.account_id, "=", account.id)) {
            try {
                string? normalized_hash = AvatarHashStore.normalize_hash(row[db.avatar.hash]);
                if (normalized_hash != null) {
                    ret[db.get_jid_by_id(row[db.avatar.jid_id])] = (!) normalized_hash;
                }
            } catch (Xmpp.InvalidJidError e) {
                warning("Invalid JID in avatar DB: %s", e.message);
            }
        }
        return ret;
    }

    public async bool fetch_and_store_for_jid(Account account, Jid jid, int generation = -1) {
        if (generation < 0) generation = avatar_fetch_queue_generation;
        int source = -1;
        string? hash = avatar_hashes.get_source(account.id, jid, AvatarSource.USER_AVATARS);
        if (hash != null) {
            source = 1;
        } else {
            hash = avatar_hashes.get_source(account.id, jid, AvatarSource.VCARD);
            if (hash == null) return false;
            source = 2;
        }

        if (hash != null && avatar_bytes_cache.lookup(hash) != null) {
            fetched_avatar(jid, account);
            return true;
        }

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null || !stream.negotiation_complete) return false;

        if (pending_fetch.contains(hash)) {
            add_avatar_fetch_waiter(hash, account, jid, generation);
            return false;
        }

        return yield fetch_and_store(stream, account, jid, source, hash, generation);
    }

    private async bool fetch_and_store(XmppStream stream, Account account, Jid jid, int source, string? hash, int generation) {
        if (hash == null) return false;

        pending_fetch.add(hash);
        Bytes? bytes = null;
        if (source == 1) {
            bytes = yield Xmpp.Xep.UserAvatars.fetch_image(stream, jid, hash);
        } else if (source == 2) {
            bytes = yield Xmpp.Xep.VCard.fetch_image(stream, jid, hash);
        }

        if (generation != avatar_fetch_queue_generation) {
            return false;
        }

        bool success = bytes != null && avatar_bytes_match_hash((!) bytes, hash);
        if (bytes != null) {
            if (success) {
                success = yield store_image_checked(hash, bytes);
            }
            bool current_request = avatar_hashes.get_preferred(account.id, jid) == hash;
            if (success && current_request) {
                clear_avatar_fetch_failure(account, jid);
                fetched_avatar(jid, account);
            } else if (!success && current_request) {
                avatar_fetch_failures[avatar_fetch_key(account, jid)] = get_real_time() / 1000000;
            }
        } else if (avatar_hashes.get_preferred(account.id, jid) == hash) {
            avatar_fetch_failures[avatar_fetch_key(account, jid)] = get_real_time() / 1000000;
        }
        pending_fetch.remove(hash);
        notify_avatar_fetch_waiters(hash, success, avatar_fetch_key(account, jid));
        return success;
    }

    private bool avatar_bytes_match_hash(Bytes bytes, string hash) {
        string? normalized_hash = AvatarHashStore.normalize_hash(hash);
        return normalized_hash != null && Checksum.compute_for_bytes(ChecksumType.SHA1, bytes) == normalized_hash;
    }

    public async void store_image(string id, Bytes data) {
        yield store_image_checked(id, data);
    }

    private void store_image_in_background(string id, Bytes data) {
        store_image_checked.begin(id, data, false, (_, result) => {
            store_image_checked.end(result);
        });
    }

    private async bool store_image_checked(string id, Bytes data,
            bool already_verified = false) {
        string? normalized_id = AvatarHashStore.normalize_hash(id);
        if (normalized_id == null || avatar_cache_write_pause_depth > 0) {
            return false;
        }
        int generation = avatar_cache_load_generation;
        try {
            string path = Path.build_filename(folder, (!) normalized_id);
            AvatarCacheWorkerResult result = already_verified
                ? yield AvatarCacheWorker.store(path, file_encryption, data)
                : yield AvatarCacheWorker.store_verified(path,
                    file_encryption, data, (!) normalized_id);
            if (!result.committed || avatar_cache_write_pause_depth > 0 ||
                    generation != avatar_cache_load_generation) return false;
            // Pre-populate cache so the next get_avatar_bytes() is instant.
            cache_avatar_bytes((!) normalized_id, data);
            return true;
        } catch (Error e) {
            warning("Error writing avatar file: %s", e.message);
            return false;
        }
    }

    public bool has_image(string id) {
        string? normalized_id = AvatarHashStore.normalize_hash(id);
        if (normalized_id == null) return false;
        File file = File.new_for_path(Path.build_filename(folder, (!) normalized_id));
        return file.query_exists();
    }
}

}
