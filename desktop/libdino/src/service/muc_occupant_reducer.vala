/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;

namespace Dino {

public enum MucWorkerPresenceKind {
    AVAILABLE,
    UNAVAILABLE,
    ERROR,
    CONTROL
}

public enum MucWorkerAffiliationState {
    UNKNOWN,
    NONE,
    MEMBER,
    ADMIN,
    OWNER,
    OUTCAST
}

public enum MucWorkerRoleState {
    UNKNOWN,
    NONE,
    VISITOR,
    PARTICIPANT,
    MODERATOR
}

[Flags]
public enum MucOccupantChange {
    NONE = 0,
    MEMBERSHIP = 1 << 0,
    NICK = 1 << 1,
    AFFILIATION = 1 << 2,
    ROLE = 1 << 3,
    REAL_JID = 1 << 4,
    HATS = 1 << 5,
    AVATAR = 1 << 6
}

private class MucWorkerDataCopy {
    internal static string[] strings(string[]? values) {
        if (values == null) return new string[0];

        string[] result = new string[((!) values).length];
        for (int i = 0; i < result.length; i++) result[i] = ((!) values)[i];
        return result;
    }

    internal static int[] integers(int[]? values) {
        if (values == null) return new int[0];

        int[] result = new int[((!) values).length];
        for (int i = 0; i < result.length; i++) result[i] = ((!) values)[i];
        return result;
    }

    internal static MucOccupantSnapshot[] snapshots(MucOccupantSnapshot[]? values) {
        if (values == null) return new MucOccupantSnapshot[0];

        MucOccupantSnapshot[] result = new MucOccupantSnapshot[((!) values).length];
        for (int i = 0; i < result.length; i++) result[i] = ((!) values)[i];
        return result;
    }
}

/**
 * Immutable worker identity. It deliberately contains no live Account, Jid,
 * stream, stanza, flag, or UI object.
 */
public class MucRoomKey : Object {
    public int account_id { get; private set; }
    public string account_bare_jid { get; private set; }
    public string room_bare_jid { get; private set; }
    public uint64 stream_generation { get; private set; }
    public uint64 room_generation { get; private set; }

    public MucRoomKey(int account_id, string account_bare_jid, string room_bare_jid,
            uint64 stream_generation, uint64 room_generation) {
        this.account_id = account_id;
        this.account_bare_jid = account_bare_jid;
        this.room_bare_jid = room_bare_jid;
        this.stream_generation = stream_generation;
        this.room_generation = room_generation;
    }

    public bool matches(MucRoomKey other) {
        return account_id == other.account_id &&
            account_bare_jid == other.account_bare_jid &&
            room_bare_jid == other.room_bare_jid &&
            stream_generation == other.stream_generation &&
            room_generation == other.room_generation;
    }
}

/**
 * Immutable, thread-boundary-safe representation of one parsed MUC presence.
 * Array inputs and outputs are copied so callers cannot mutate queued data.
 */
public class MucPresenceEnvelope : Object {
    public MucRoomKey room { get; private set; }
    public uint64 sequence { get; private set; }
    public MucWorkerPresenceKind kind { get; private set; }
    public string occupant_full_jid { get; private set; }
    public string room_bare_jid { get; private set; }
    public string? nick { get; private set; }
    public string? real_bare_jid { get; private set; }
    public bool real_jid_known { get; private set; }
    public MucWorkerAffiliationState affiliation { get; private set; }
    public bool affiliation_known { get; private set; }
    public MucWorkerRoleState role { get; private set; }
    public bool role_known { get; private set; }
    public string? avatar_hash { get; private set; }
    public bool is_self_presence { get; private set; }
    /** Explicit lifecycle boundary selected on the main context. */
    public bool initial_sync_boundary { get; private set; }
    public int64 received_monotonic_us { get; private set; }

    private string[] hat_uris_value;
    private string[] hat_titles_value;
    private string[] hat_hues_value;
    private int[] status_codes_value;

    public uint hat_count { get { return (uint) hat_uris_value.length; } }
    public uint status_code_count { get { return (uint) status_codes_value.length; } }

    public string hat_uri_at(uint index) {
        return hat_uris_value[index];
    }

    public string hat_title_at(uint index) {
        return hat_titles_value[index];
    }

    public string hat_hue_at(uint index) {
        return hat_hues_value[index];
    }

    public string[] dup_hat_uris() {
        return MucWorkerDataCopy.strings(hat_uris_value);
    }

    public string[] dup_hat_titles() {
        return MucWorkerDataCopy.strings(hat_titles_value);
    }

    public string[] dup_hat_hues() {
        return MucWorkerDataCopy.strings(hat_hues_value);
    }

    public int[] dup_status_codes() {
        return MucWorkerDataCopy.integers(status_codes_value);
    }

    public MucPresenceEnvelope(MucRoomKey room, uint64 sequence, MucWorkerPresenceKind kind,
            string occupant_full_jid, string? nick = null, string? real_bare_jid = null,
            MucWorkerAffiliationState affiliation = MucWorkerAffiliationState.UNKNOWN,
            bool affiliation_known = false,
            MucWorkerRoleState role = MucWorkerRoleState.UNKNOWN, bool role_known = false,
            string[]? hat_uris = null, string[]? hat_titles = null,
            string? avatar_hash = null, int[]? status_codes = null,
            bool is_self_presence = false, int64 received_monotonic_us = 0,
            bool real_jid_known = false, string[]? hat_hues = null,
            bool initial_sync_boundary = false) {
        this.room = room;
        this.sequence = sequence;
        this.kind = kind;
        this.occupant_full_jid = occupant_full_jid;
        this.room_bare_jid = room.room_bare_jid;
        this.nick = nick;
        this.real_bare_jid = real_bare_jid;
        this.real_jid_known = real_jid_known;
        this.affiliation_known = affiliation_known && affiliation != MucWorkerAffiliationState.UNKNOWN;
        this.affiliation = this.affiliation_known ? affiliation : MucWorkerAffiliationState.UNKNOWN;
        this.role_known = role_known && role != MucWorkerRoleState.UNKNOWN;
        this.role = this.role_known ? role : MucWorkerRoleState.UNKNOWN;

        string[] copied_hat_uris = MucWorkerDataCopy.strings(hat_uris);
        string[] copied_hat_titles = MucWorkerDataCopy.strings(hat_titles);
        int paired_hat_count = int.min(copied_hat_uris.length, copied_hat_titles.length);
        this.hat_uris_value = new string[paired_hat_count];
        this.hat_titles_value = new string[paired_hat_count];
        this.hat_hues_value = new string[paired_hat_count];
        string[] copied_hat_hues = MucWorkerDataCopy.strings(hat_hues);
        for (int i = 0; i < paired_hat_count; i++) {
            this.hat_uris_value[i] = copied_hat_uris[i];
            this.hat_titles_value[i] = copied_hat_titles[i];
            this.hat_hues_value[i] = i < copied_hat_hues.length
                ? copied_hat_hues[i] : "";
        }

        this.avatar_hash = avatar_hash;
        this.status_codes_value = MucWorkerDataCopy.integers(status_codes);
        this.is_self_presence = is_self_presence;
        this.initial_sync_boundary = initial_sync_boundary;
        this.received_monotonic_us = received_monotonic_us;
    }

    public bool has_status_code(int status_code) {
        foreach (int current in status_codes_value) {
            if (current == status_code) return true;
        }
        return false;
    }
}

/** Immutable occupant state emitted by the reducer. */
public class MucOccupantSnapshot : Object {
    public string occupant_full_jid { get; private set; }
    public string room_bare_jid { get; private set; }
    public string? nick { get; private set; }
    public string? real_bare_jid { get; private set; }
    public MucWorkerAffiliationState affiliation { get; private set; }
    public bool affiliation_known { get; private set; }
    public MucWorkerRoleState role { get; private set; }
    public bool role_known { get; private set; }
    public string? avatar_hash { get; private set; }
    public bool available { get; private set; }
    public int64 last_seen_monotonic_us { get; private set; }

    private string[] hat_uris_value;
    private string[] hat_titles_value;
    private string[] hat_hues_value;

    public uint hat_count { get { return (uint) hat_uris_value.length; } }

    public string hat_uri_at(uint index) {
        return hat_uris_value[index];
    }

    public string hat_title_at(uint index) {
        return hat_titles_value[index];
    }

    public string hat_hue_at(uint index) {
        return hat_hues_value[index];
    }

    public string[] dup_hat_uris() {
        return MucWorkerDataCopy.strings(hat_uris_value);
    }

    public string[] dup_hat_titles() {
        return MucWorkerDataCopy.strings(hat_titles_value);
    }

    public string[] dup_hat_hues() {
        return MucWorkerDataCopy.strings(hat_hues_value);
    }

    internal MucOccupantSnapshot(string occupant_full_jid, string room_bare_jid,
            string? nick, string? real_bare_jid,
            MucWorkerAffiliationState affiliation, bool affiliation_known,
            MucWorkerRoleState role, bool role_known,
            string[]? hat_uris, string[]? hat_titles, string? avatar_hash,
            bool available, int64 last_seen_monotonic_us,
            string[]? hat_hues = null) {
        this.occupant_full_jid = occupant_full_jid;
        this.room_bare_jid = room_bare_jid;
        this.nick = nick;
        this.real_bare_jid = real_bare_jid;
        this.affiliation_known = affiliation_known && affiliation != MucWorkerAffiliationState.UNKNOWN;
        this.affiliation = this.affiliation_known ? affiliation : MucWorkerAffiliationState.UNKNOWN;
        this.role_known = role_known && role != MucWorkerRoleState.UNKNOWN;
        this.role = this.role_known ? role : MucWorkerRoleState.UNKNOWN;
        string[] copied_hat_uris = MucWorkerDataCopy.strings(hat_uris);
        string[] copied_hat_titles = MucWorkerDataCopy.strings(hat_titles);
        int paired_hat_count = int.min(copied_hat_uris.length, copied_hat_titles.length);
        this.hat_uris_value = new string[paired_hat_count];
        this.hat_titles_value = new string[paired_hat_count];
        this.hat_hues_value = new string[paired_hat_count];
        string[] copied_hat_hues = MucWorkerDataCopy.strings(hat_hues);
        for (int i = 0; i < paired_hat_count; i++) {
            this.hat_uris_value[i] = copied_hat_uris[i];
            this.hat_titles_value[i] = copied_hat_titles[i];
            this.hat_hues_value[i] = i < copied_hat_hues.length
                ? copied_hat_hues[i] : "";
        }
        this.avatar_hash = avatar_hash;
        this.available = available;
        this.last_seen_monotonic_us = last_seen_monotonic_us;
    }

    internal bool has_same_display_state(MucOccupantSnapshot other) {
        return occupant_full_jid == other.occupant_full_jid &&
            room_bare_jid == other.room_bare_jid && nick == other.nick &&
            real_bare_jid == other.real_bare_jid && affiliation == other.affiliation &&
            affiliation_known == other.affiliation_known && role == other.role &&
            role_known == other.role_known && avatar_hash == other.avatar_hash &&
            available == other.available && equal_strings(hat_uris_value, other.hat_uris_value) &&
            equal_strings(hat_titles_value, other.hat_titles_value) &&
            equal_strings(hat_hues_value, other.hat_hues_value);
    }

    internal bool has_same_hats(MucOccupantSnapshot other) {
        return equal_strings(hat_uris_value, other.hat_uris_value) &&
            equal_strings(hat_titles_value, other.hat_titles_value) &&
            equal_strings(hat_hues_value, other.hat_hues_value);
    }

    private bool equal_strings(string[] left, string[] right) {
        if (left.length != right.length) return false;
        for (int i = 0; i < left.length; i++) {
            if (left[i] != right[i]) return false;
        }
        return true;
    }
}

/** Immutable reducer output. Changed entries are deltas, not a security snapshot. */
public class MucRoomDelta : Object {
    public MucRoomKey room { get; private set; }
    public uint64 revision { get; private set; }
    public bool initial_sync_started { get; private set; }
    public bool initial_snapshot_ready { get; private set; }
    public bool initial_sync_finished { get; private set; }
    public bool degraded_partial { get; private set; }
    public bool full_snapshot { get; private set; }
    public uint occupant_count { get; private set; }

    private MucOccupantSnapshot[] changed_value;
    private int[] changed_flags_value;
    private string[] removed_occupant_full_jids_value;

    public uint changed_count { get { return (uint) changed_value.length; } }
    public uint removed_count { get { return (uint) removed_occupant_full_jids_value.length; } }

    public MucOccupantSnapshot changed_at(uint index) {
        return changed_value[index];
    }

    public MucOccupantChange changed_flags_at(uint index) {
        return (MucOccupantChange) changed_flags_value[index];
    }

    public string removed_at(uint index) {
        return removed_occupant_full_jids_value[index];
    }

    public MucOccupantSnapshot[] dup_changed() {
        return MucWorkerDataCopy.snapshots(changed_value);
    }

    public string[] dup_removed_occupant_full_jids() {
        return MucWorkerDataCopy.strings(removed_occupant_full_jids_value);
    }

    internal MucRoomDelta(MucRoomKey room, uint64 revision,
            bool initial_sync_started, bool initial_snapshot_ready,
            bool initial_sync_finished, bool degraded_partial, bool full_snapshot,
            uint occupant_count,
            MucOccupantSnapshot[]? changed = null,
            string[]? removed_occupant_full_jids = null,
            int[]? changed_flags = null) {
        this.room = room;
        this.revision = revision;
        this.initial_sync_started = initial_sync_started;
        this.initial_snapshot_ready = initial_snapshot_ready;
        this.initial_sync_finished = initial_sync_finished;
        this.degraded_partial = degraded_partial;
        this.full_snapshot = full_snapshot;
        this.occupant_count = occupant_count;
        this.changed_value = MucWorkerDataCopy.snapshots(changed);
        int[] copied_flags = MucWorkerDataCopy.integers(changed_flags);
        this.changed_flags_value = new int[this.changed_value.length];
        for (int i = 0; i < this.changed_flags_value.length; i++) {
            this.changed_flags_value[i] = i < copied_flags.length
                ? copied_flags[i]
                : (int) MucOccupantChange.NONE;
        }
        this.removed_occupant_full_jids_value = MucWorkerDataCopy.strings(removed_occupant_full_jids);
    }
}

/**
 * Deterministic per-room reducer. Its mutable map is worker-local; every input
 * and output object is immutable and contains data only.
 */
internal class MucOccupantReducer : Object {
    private const int STATUS_ROOM_NICKNAME = 303;

    internal MucRoomKey room { get; private set; }
    internal uint64 revision { get; private set; default = 0; }
    internal uint occupant_count { get { return (uint) occupants.size; } }

    private HashMap<string, MucOccupantSnapshot> occupants = new HashMap<string, MucOccupantSnapshot>();
    private uint64 last_sequence = 0;
    private bool has_sequence = false;
    private bool initial_sync_started;
    private bool initial_snapshot_ready = false;
    private bool initial_sync_finished = false;
    private bool degraded_partial = false;

    internal MucOccupantReducer(MucRoomKey room, bool initial_sync_started = true) {
        this.room = room;
        this.initial_sync_started = initial_sync_started;
    }

    internal MucRoomDelta? apply(MucPresenceEnvelope envelope) {
        if (!room.matches(envelope.room) || envelope.room_bare_jid != room.room_bare_jid) return null;
        if ((envelope.kind == MucWorkerPresenceKind.AVAILABLE ||
                envelope.kind == MucWorkerPresenceKind.UNAVAILABLE) &&
                get_occupant_resource(envelope.occupant_full_jid) == null) {
            return null;
        }
        if (has_sequence && envelope.sequence <= last_sequence) return null;
        has_sequence = true;
        last_sequence = envelope.sequence;

        var changed = new ArrayList<MucOccupantSnapshot>();
        var changed_flags = new ArrayList<int>();
        var removed = new ArrayList<string>();
        bool lifecycle_changed = false;
        bool occupant_state_changed = false;

        if (envelope.initial_sync_boundary && !initial_snapshot_ready) {
            initial_snapshot_ready = true;
            lifecycle_changed = true;
        }

        switch (envelope.kind) {
            case MucWorkerPresenceKind.AVAILABLE:
                occupant_state_changed = apply_available(envelope, changed,
                    changed_flags);
                break;
            case MucWorkerPresenceKind.UNAVAILABLE:
                occupant_state_changed = apply_unavailable(envelope, changed,
                    changed_flags, removed);
                break;
            case MucWorkerPresenceKind.ERROR:
                break;
            case MucWorkerPresenceKind.CONTROL:
                occupant_state_changed = apply_control(envelope, changed,
                    changed_flags);
                break;
        }

        if (!lifecycle_changed && !occupant_state_changed) return null;
        revision++;
        return create_delta(changed.to_array(), removed.to_array(), false,
            changed_flags.to_array());
    }

    internal MucRoomDelta? finish_initial_sync(bool degraded_partial = false) {
        bool changed = !initial_snapshot_ready || !initial_sync_finished ||
            (degraded_partial && !this.degraded_partial);
        if (!changed) return null;

        initial_snapshot_ready = true;
        initial_sync_finished = true;
        this.degraded_partial = this.degraded_partial || degraded_partial;
        revision++;
        return create_delta();
    }

    internal MucRoomDelta? mark_degraded_partial() {
        if (degraded_partial) return null;

        degraded_partial = true;
        revision++;
        return create_delta();
    }

    internal MucRoomDelta snapshot() {
        var ids = new ArrayList<string>();
        ids.add_all(occupants.keys);
        ids.sort((left, right) => strcmp(left, right));

        var values = new ArrayList<MucOccupantSnapshot>();
        foreach (string id in ids) values.add(occupants[id]);
        return create_delta(values.to_array(), null, true);
    }

    internal MucOccupantSnapshot? lookup(string occupant_full_jid) {
        return occupants[occupant_full_jid];
    }

    private bool apply_available(MucPresenceEnvelope envelope,
            ArrayList<MucOccupantSnapshot> changed,
            ArrayList<int> changed_flags) {
        // For normal MUC presence the resource of the occupant full JID is the
        // protocol identity and therefore the canonical nickname.  The
        // separate nick field is only authoritative for an unavailable 303
        // nickname transition.  Keeping these paths distinct prevents a bad
        // parsed/display hint from poisoning a stable large-room snapshot.
        string? canonical_nick = get_occupant_resource(
            envelope.occupant_full_jid);
        if (canonical_nick == null) return false;

        MucOccupantSnapshot? previous = occupants[envelope.occupant_full_jid];
        bool affiliation_known = envelope.affiliation_known;
        MucWorkerAffiliationState affiliation = envelope.affiliation;
        if (!affiliation_known && previous != null && ((!) previous).affiliation_known) {
            affiliation_known = true;
            affiliation = ((!) previous).affiliation;
        }

        bool role_known = envelope.role_known;
        MucWorkerRoleState role = envelope.role;
        if (!role_known && previous != null && ((!) previous).role_known) {
            role_known = true;
            role = ((!) previous).role;
        }

        string? real_bare_jid = envelope.real_bare_jid;
        if (!envelope.real_jid_known && real_bare_jid == null &&
                previous != null) {
            real_bare_jid = ((!) previous).real_bare_jid;
        }
        string? avatar_hash = envelope.avatar_hash;
        if (avatar_hash == null && previous != null) {
            avatar_hash = ((!) previous).avatar_hash;
        }

        var next = new MucOccupantSnapshot(
            envelope.occupant_full_jid, envelope.room_bare_jid,
            (!) canonical_nick,
            real_bare_jid, affiliation, affiliation_known, role, role_known,
            envelope.dup_hat_uris(), envelope.dup_hat_titles(), avatar_hash,
            true, envelope.received_monotonic_us,
            envelope.dup_hat_hues());

        occupants[envelope.occupant_full_jid] = next;
        MucOccupantChange flags = calculate_change_flags(previous, next);
        if (flags == MucOccupantChange.NONE) return false;

        changed.add(next);
        changed_flags.add((int) flags);
        return true;
    }

    private bool apply_control(MucPresenceEnvelope envelope,
            ArrayList<MucOccupantSnapshot> changed,
            ArrayList<int> changed_flags) {
        if (!envelope.real_jid_known) return false;
        MucOccupantSnapshot? previous = occupants[envelope.occupant_full_jid];
        if (previous == null || ((!) previous).real_bare_jid ==
                envelope.real_bare_jid) return false;

        MucOccupantSnapshot old = (!) previous;
        var next = new MucOccupantSnapshot(old.occupant_full_jid,
            old.room_bare_jid, old.nick, envelope.real_bare_jid,
            old.affiliation, old.affiliation_known, old.role, old.role_known,
            old.dup_hat_uris(), old.dup_hat_titles(), old.avatar_hash,
            old.available, envelope.received_monotonic_us,
            old.dup_hat_hues());
        occupants[envelope.occupant_full_jid] = next;
        MucOccupantChange flags = calculate_change_flags(old, next);
        if (flags == MucOccupantChange.NONE) return false;
        changed.add(next);
        changed_flags.add((int) flags);
        return true;
    }

    private bool apply_unavailable(MucPresenceEnvelope envelope,
            ArrayList<MucOccupantSnapshot> changed,
            ArrayList<int> changed_flags, ArrayList<string> removed) {
        MucOccupantSnapshot? previous = occupants[envelope.occupant_full_jid];
        if (previous == null) return false;

        occupants.unset(envelope.occupant_full_jid);
        removed.add(envelope.occupant_full_jid);

        if (envelope.has_status_code(STATUS_ROOM_NICKNAME) && envelope.nick != null &&
                ((!) envelope.nick).length > 0 && ((!) envelope.nick).validate()) {
            string replacement_full_jid = room.room_bare_jid + "/" + ((!) envelope.nick);
            string? replacement_real_jid = envelope.real_jid_known
                ? envelope.real_bare_jid
                : ((!) previous).real_bare_jid;
            var replacement = new MucOccupantSnapshot(
                replacement_full_jid, room.room_bare_jid, envelope.nick,
                replacement_real_jid,
                ((!) previous).affiliation, ((!) previous).affiliation_known,
                ((!) previous).role, ((!) previous).role_known,
                ((!) previous).dup_hat_uris(), ((!) previous).dup_hat_titles(),
                envelope.avatar_hash ?? ((!) previous).avatar_hash, true,
                envelope.received_monotonic_us,
                ((!) previous).dup_hat_hues());
            occupants[replacement_full_jid] = replacement;
            changed.add(replacement);
            changed_flags.add((int) calculate_change_flags(null, replacement));
        }
        return true;
    }

    private string? get_occupant_resource(string occupant_full_jid) {
        string prefix = room.room_bare_jid + "/";
        if (!occupant_full_jid.has_prefix(prefix) ||
                occupant_full_jid.length <= prefix.length) return null;

        string resource = occupant_full_jid.substring(prefix.length);
        return resource.validate() ? resource : null;
    }

    private MucOccupantChange calculate_change_flags(
            MucOccupantSnapshot? previous, MucOccupantSnapshot next) {
        MucOccupantChange flags = MucOccupantChange.NONE;
        if (previous == null) {
            flags |= MucOccupantChange.MEMBERSHIP;
            flags |= MucOccupantChange.NICK;
            if (next.affiliation_known) flags |= MucOccupantChange.AFFILIATION;
            if (next.role_known) flags |= MucOccupantChange.ROLE;
            if (next.real_bare_jid != null) flags |= MucOccupantChange.REAL_JID;
            if (next.hat_count > 0) flags |= MucOccupantChange.HATS;
            if (next.avatar_hash != null) flags |= MucOccupantChange.AVATAR;
            return flags;
        }

        MucOccupantSnapshot old = (!) previous;
        if (old.available != next.available) flags |= MucOccupantChange.MEMBERSHIP;
        if (old.nick != next.nick) flags |= MucOccupantChange.NICK;
        if (old.affiliation_known != next.affiliation_known ||
                old.affiliation != next.affiliation) {
            flags |= MucOccupantChange.AFFILIATION;
        }
        if (old.role_known != next.role_known || old.role != next.role) {
            flags |= MucOccupantChange.ROLE;
        }
        if (old.real_bare_jid != next.real_bare_jid) {
            flags |= MucOccupantChange.REAL_JID;
        }
        if (!old.has_same_hats(next)) flags |= MucOccupantChange.HATS;
        if (old.avatar_hash != next.avatar_hash) flags |= MucOccupantChange.AVATAR;
        return flags;
    }

    private MucRoomDelta create_delta(MucOccupantSnapshot[]? changed = null,
            string[]? removed = null, bool full_snapshot = false,
            int[]? changed_flags = null) {
        return new MucRoomDelta(room, revision, initial_sync_started,
            initial_snapshot_ready, initial_sync_finished, degraded_partial,
            full_snapshot, (uint) occupants.size, changed, removed,
            changed_flags);
    }
}

}
