using Xmpp.Xep.Muc;

namespace Dino.Test {

class MucOccupantReducerAudit : Gee.TestCase {
    private const string ACCOUNT = "alice@example.test";
    private const string ROOM = "room@conference.example.test";
    private const string BOB = ROOM + "/bob";
    private const string ALICE = ROOM + "/alice";

    public MucOccupantReducerAudit() {
        base("MucOccupantReducerAudit");
        add_test("available_and_self_presence_build_stable_snapshot", test_available_and_self_presence);
        add_test("full_snapshot_order_is_deterministic", test_snapshot_order);
        add_test("unknown_and_explicit_none_remain_distinct", test_unknown_and_none);
        add_test("partial_updates_preserve_known_affiliation_and_role", test_partial_updates);
        add_test("authoritative_privacy_updates_clear_real_jid",
            test_authoritative_privacy_updates_clear_real_jid);
        add_test("available_nick_uses_full_jid_resource",
            test_available_nick_uses_full_jid_resource);
        add_test("hats_real_jid_and_arrays_are_immutable", test_hats_real_jid_and_immutability);
        add_test("duplicate_stale_and_wrong_generation_updates_are_ignored", test_deduplication_and_generation);
        add_test("unavailable_and_removal_status_codes_remove_occupants", test_removal_status_codes);
        add_test("nickname_change_moves_the_stable_occupant", test_nickname_change);
        add_test("degraded_initial_sync_is_explicit", test_degraded_initial_sync);
    }

    private void test_available_and_self_presence() {
        var reducer = new MucOccupantReducer(room_key());
        MucRoomDelta? first = reducer.apply(available(1, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true));
        fail_if(first == null, "First available presence must create a delta");
        fail_if(((!) first).occupant_count != 1 || ((!) first).changed_count != 1,
            "First available presence must add exactly one occupant");
        fail_if(((!) first).initial_snapshot_ready,
            "A normal occupant presence must not complete the initial snapshot");

        int[] self_codes = { (int) StatusCode.SELF_PRESENCE };
        MucRoomDelta? old_self_delta = reducer.apply(available(2, ALICE,
            "alice",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, null, null, null, self_codes, true));
        fail_if(old_self_delta == null ||
                ((!) old_self_delta).initial_snapshot_ready,
            "A self-110 which is not the selected generation boundary must not mark the snapshot ready");

        MucRoomDelta? self_delta = reducer.apply(available(3, ALICE, "alice",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, null, null, null,
            self_codes, true, null, false, null, true));
        fail_if(self_delta == null || !((!) self_delta).initial_snapshot_ready,
            "Only an explicitly selected self-presence boundary must mark the initial reducer snapshot ready");
        fail_if(((!) self_delta).initial_sync_finished,
            "Snapshot readiness must remain distinct from the main-context sync commit");
        fail_if(((!) self_delta).occupant_count != 2,
            "Self-presence must remain part of the occupant snapshot");

        MucRoomDelta? finished = reducer.finish_initial_sync();
        fail_if(finished == null || !((!) finished).initial_sync_finished,
            "Finishing the initial sync must be an explicit reducer transition");
    }

    private void test_unknown_and_none() {
        var reducer = new MucOccupantReducer(room_key());
        reducer.apply(available(1, BOB, "bob"));
        reducer.apply(available(2, ALICE, "alice",
            MucWorkerAffiliationState.NONE, true));

        MucOccupantSnapshot? unknown = reducer.lookup(BOB);
        MucOccupantSnapshot? explicit_none = reducer.lookup(ALICE);
        fail_if(unknown == null || ((!) unknown).affiliation_known ||
            ((!) unknown).affiliation != MucWorkerAffiliationState.UNKNOWN,
            "Missing affiliation must remain UNKNOWN and not authoritative");
        fail_if(explicit_none == null || !((!) explicit_none).affiliation_known ||
            ((!) explicit_none).affiliation != MucWorkerAffiliationState.NONE,
            "Explicit XEP-0045 affiliation none must remain known NONE");
    }

    private void test_snapshot_order() {
        var reducer = new MucOccupantReducer(room_key());
        reducer.apply(available(1, BOB, "bob"));
        reducer.apply(available(2, ALICE, "alice"));

        MucRoomDelta snapshot = reducer.snapshot();
        fail_if(snapshot.occupant_count != 2 || snapshot.changed_count != 2,
            "A full snapshot must contain every current occupant exactly once");
        fail_if(snapshot.changed_at(0).occupant_full_jid != ALICE ||
            snapshot.changed_at(1).occupant_full_jid != BOB,
            "Full snapshots must use deterministic full-JID ordering");
        fail_if(snapshot.revision != reducer.revision,
            "A read-only full snapshot must report the current reducer revision");
    }

    private void test_partial_updates() {
        var reducer = new MucOccupantReducer(room_key());
        reducer.apply(available(1, BOB, "bob",
            MucWorkerAffiliationState.ADMIN, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            null, null, null, false, "sha1-old"));

        MucRoomDelta? update = reducer.apply(available(2, BOB, "bob",
            MucWorkerAffiliationState.UNKNOWN, false,
            MucWorkerRoleState.MODERATOR, true));
        fail_if(update == null || ((!) update).changed_count != 1,
            "A role change must emit one changed occupant");
        MucOccupantSnapshot current = (!) reducer.lookup(BOB);
        fail_if(!current.affiliation_known || current.affiliation != MucWorkerAffiliationState.ADMIN,
            "A partial update must not erase a previously authoritative affiliation");
        fail_if(!current.role_known || current.role != MucWorkerRoleState.MODERATOR,
            "A role update must replace the previous authoritative role");
        fail_if_not_eq_str(current.real_bare_jid, "bob@example.test",
            "A partial update must not erase a previously authoritative real JID");
        fail_if_not_eq_str(current.avatar_hash, "sha1-old",
            "A partial update must not erase a previously advertised avatar hash");

        MucRoomDelta? avatar_clear = reducer.apply(available(3, BOB, "bob",
            MucWorkerAffiliationState.ADMIN, true,
            MucWorkerRoleState.MODERATOR, true, "new-bob@example.test",
            null, null, null, false, ""));
        fail_if(avatar_clear == null ||
                ((((!) avatar_clear).changed_flags_at(0) &
                    MucOccupantChange.AVATAR) == 0),
            "An explicit empty avatar hash must emit an avatar delta");
        current = (!) reducer.lookup(BOB);
        fail_if_not_eq_str(current.real_bare_jid, "new-bob@example.test",
            "A new authoritative real JID must replace the old value");
        fail_if_not_eq_str(current.avatar_hash, "",
            "An explicit empty avatar hash must clear the previous advertised hash");
    }

    private void test_authoritative_privacy_updates_clear_real_jid() {
        var reducer = new MucOccupantReducer(room_key());
        reducer.apply(available(1, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            null, null, null, false, null, true));

        MucRoomDelta? presence_clear = reducer.apply(available(2, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, null,
            null, null, null, false, null, true));
        fail_if(presence_clear == null || ((!) presence_clear).changed_count != 1 ||
                (((!) presence_clear).changed_flags_at(0) &
                    MucOccupantChange.REAL_JID) == 0,
            "An authoritative MUC presence without item@jid must clear the cached real JID");
        fail_if(((!) reducer.lookup(BOB)).real_bare_jid != null,
            "The reducer must not retain a real JID after privacy disclosure was revoked");

        reducer.apply(available(3, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            null, null, null, false, null, true));
        var control = new MucPresenceEnvelope(room_key(), 4,
            MucWorkerPresenceKind.CONTROL, BOB, "bob", null,
            MucWorkerAffiliationState.UNKNOWN, false,
            MucWorkerRoleState.UNKNOWN, false, null, null, null, null, false,
            4000, true);
        MucRoomDelta? status_clear = reducer.apply(control);
        fail_if(status_clear == null || ((!) status_clear).changed_count != 1 ||
                (((!) status_clear).changed_flags_at(0) &
                    MucOccupantChange.REAL_JID) == 0,
            "Status 173 control must clear real JIDs without replacing occupant state");
        MucOccupantSnapshot current = (!) reducer.lookup(BOB);
        fail_if(current.real_bare_jid != null ||
                current.affiliation != MucWorkerAffiliationState.MEMBER ||
                current.role != MucWorkerRoleState.PARTICIPANT,
            "Privacy clearing must preserve role and affiliation state");
    }

    private void test_available_nick_uses_full_jid_resource() {
        var reducer = new MucOccupantReducer(room_key());
        MucRoomDelta? first = reducer.apply(available(1, BOB, "room"));
        fail_if(first == null || ((!) first).changed_count != 1,
            "A valid occupant presence must still create one delta");
        fail_if_not_eq_str(((!) first).changed_at(0).nick, "bob",
            "AVAILABLE snapshots must derive nick from the full-JID resource");

        uint64 revision = reducer.revision;
        MucRoomDelta? misleading_update = reducer.apply(available(2, BOB,
            "different-wrong-hint"));
        fail_if(misleading_update != null || reducer.revision != revision,
            "A changed display hint must not create churn when full-JID state is unchanged");
        fail_if_not_eq_str(((!) reducer.lookup(BOB)).nick, "bob",
            "A misleading live hint must not poison the stable snapshot");

        uint8[] invalid_nick_bytes = { 'b', 0xff, 0 };
        string invalid_nick = (string) invalid_nick_bytes;
        MucRoomDelta? invalid_hint = reducer.apply(available(3, ALICE,
            invalid_nick));
        fail_if(invalid_hint == null ||
                !((!) invalid_hint).changed_at(0).nick.validate(),
            "Invalid hint bytes must not cross into the canonical snapshot nick");
        fail_if_not_eq_str(((!) invalid_hint).changed_at(0).nick, "alice",
            "The full-JID resource must replace an invalid display hint");

        var slash_resource_reducer = new MucOccupantReducer(room_key());
        string slash_resource_jid = ROOM + "/bob/device";
        MucRoomDelta? slash_resource = slash_resource_reducer.apply(available(
            1, slash_resource_jid, "wrong"));
        fail_if(slash_resource == null,
            "A slash inside an XMPP resource must remain a valid occupant identity");
        fail_if_not_eq_str(((!) slash_resource).changed_at(0).nick,
            "bob/device", "Canonical nick extraction must preserve the full resource");

        string other_room_occupant = "other@conference.example.test/mallory";
        fail_if(reducer.apply(available(4, other_room_occupant, "mallory")) != null ||
                reducer.occupant_count != 2,
            "An occupant identity from another room must be rejected");
    }

    private void test_hats_real_jid_and_immutability() {
        string[] hat_uris = { "urn:xmpp:hats:support" };
        string[] hat_titles = { "Support" };
        string[] hat_hues = { "120" };
        int[] status_codes = { 100 };
        var envelope = available(1, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            hat_uris, hat_titles, status_codes, false, null, false,
            hat_hues);

        hat_uris[0] = "mutated-input";
        hat_titles[0] = "mutated-input";
        hat_hues[0] = "mutated-input";
        status_codes[0] = 999;
        fail_if_not_eq_str(envelope.hat_uri_at(0), "urn:xmpp:hats:support",
            "Envelope construction must copy hat URI input");
        fail_if_not_eq_str(envelope.hat_title_at(0), "Support",
            "Envelope construction must copy hat title input");
        fail_if_not_eq_str(envelope.hat_hue_at(0), "120",
            "Envelope construction must copy hat hue input");
        fail_if(!envelope.has_status_code(100) || envelope.has_status_code(999),
            "Envelope construction must copy status-code input");

        string[] returned_hats = envelope.dup_hat_uris();
        returned_hats[0] = "mutated-output";
        fail_if_not_eq_str(envelope.hat_uri_at(0), "urn:xmpp:hats:support",
            "Envelope array getters must return defensive copies");

        var reducer = new MucOccupantReducer(room_key());
        MucRoomDelta delta = (!) reducer.apply(envelope);
        string[] snapshot_hats = delta.changed_at(0).dup_hat_uris();
        snapshot_hats[0] = "mutated-snapshot";
        MucOccupantSnapshot snapshot = (!) reducer.lookup(BOB);
        fail_if_not_eq_str(snapshot.hat_uri_at(0), "urn:xmpp:hats:support",
            "Snapshot array getters must not expose reducer-owned state");

        MucOccupantSnapshot[] changed = delta.dup_changed();
        changed[0] = null;
        fail_if(delta.changed_at(0) == null,
            "Delta array getters must not expose the immutable changed array");

        string[] updated_hat_uris = { "urn:xmpp:hats:team" };
        string[] updated_hat_titles = { "Team" };
        string[] updated_hat_hues = { "210" };
        MucRoomDelta? hats_update = reducer.apply(available(2, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            updated_hat_uris, updated_hat_titles, null, false, null, false,
            updated_hat_hues));
        fail_if(hats_update == null || ((!) hats_update).changed_count != 1,
            "A hats update must emit one changed occupant");
        MucOccupantSnapshot updated_snapshot = (!) reducer.lookup(BOB);
        fail_if_not_eq_str(updated_snapshot.hat_uri_at(0), "urn:xmpp:hats:team",
            "A hats update must replace the previous hat URI");
        fail_if_not_eq_str(updated_snapshot.hat_title_at(0), "Team",
            "A hats update must replace the previous hat title");
        fail_if_not_eq_str(updated_snapshot.hat_hue_at(0), "210",
            "A hats update must preserve the hat hue");

        string[] hue_only_update = { "240" };
        MucRoomDelta? hue_delta = reducer.apply(available(3, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test",
            updated_hat_uris, updated_hat_titles, null, false, null, false,
            hue_only_update));
        fail_if(hue_delta == null || ((!) hue_delta).changed_count != 1,
            "A hue-only hats update must emit one changed occupant");
        fail_if(hue_delta != null &&
                (((!) hue_delta).changed_flags_at(0) &
                    MucOccupantChange.HATS) == 0,
            "A hue-only hats update must emit a HATS delta");
    }

    private void test_deduplication_and_generation() {
        var reducer = new MucOccupantReducer(room_key());
        MucPresenceEnvelope first = available(10, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true);
        fail_if(reducer.apply(first) == null, "First ordered envelope must be applied");
        uint64 revision = reducer.revision;
        fail_if(reducer.apply(first) != null || reducer.revision != revision,
            "A repeated sequence must be ignored without changing revision");
        fail_if(reducer.apply(available(9, BOB, "bob")) != null || reducer.revision != revision,
            "An older sequence must be ignored without changing revision");

        var other_generation = new MucRoomKey(7, ACCOUNT, ROOM, 2, 1);
        var wrong_generation = new MucPresenceEnvelope(other_generation, 11,
            MucWorkerPresenceKind.AVAILABLE, BOB, "bob");
        fail_if(reducer.apply(wrong_generation) != null || reducer.revision != revision,
            "A stale stream generation must not enter another room reducer");

        var other_room_generation = new MucRoomKey(7, ACCOUNT, ROOM, 1, 2);
        var stale_room = new MucPresenceEnvelope(other_room_generation, 12,
            MucWorkerPresenceKind.AVAILABLE, BOB, "bob");
        fail_if(reducer.apply(stale_room) != null || reducer.revision != revision,
            "A stale leave/rejoin room generation must not enter the current reducer");

        MucRoomDelta? same_state = reducer.apply(available(11, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true));
        fail_if(same_state != null || reducer.revision != revision,
            "A newer but display-identical presence must not create UI churn");
    }

    private void test_removal_status_codes() {
        int[] removal_codes = {
            (int) StatusCode.BANNED,
            (int) StatusCode.KICKED,
            (int) StatusCode.REMOVED_AFFILIATION_CHANGE,
            (int) StatusCode.REMOVED_MEMBERS_ONLY,
            (int) StatusCode.REMOVED_SHUTDOWN
        };

        foreach (int code in removal_codes) {
            var reducer = new MucOccupantReducer(room_key());
            reducer.apply(available(1, BOB, "bob"));
            MucRoomDelta? removed = reducer.apply(unavailable(2, BOB, null, { code }));
            fail_if(removed == null || ((!) removed).occupant_count != 0,
                "Unavailable removal status must remove the occupant");
            fail_if(((!) removed).removed_count != 1 || ((!) removed).removed_at(0) != BOB,
                "Removal delta must identify the removed full occupant JID");
        }

        var normal = new MucOccupantReducer(room_key());
        normal.apply(available(1, BOB, "bob"));
        fail_if(normal.apply(unavailable(2, BOB)) == null || normal.occupant_count != 0,
            "Normal unavailable presence must remove the occupant too");
    }

    private void test_nickname_change() {
        var reducer = new MucOccupantReducer(room_key());
        string[] hats = { "urn:xmpp:hats:team" };
        string[] titles = { "Team" };
        reducer.apply(available(1, BOB, "bob",
            MucWorkerAffiliationState.OWNER, true,
            MucWorkerRoleState.MODERATOR, true, "bob@example.test", hats, titles));

        int[] nick_change = { (int) StatusCode.ROOM_NICKNAME };
        MucRoomDelta? moved = reducer.apply(unavailable(2, BOB, "robert", nick_change));
        string replacement = ROOM + "/robert";
        fail_if(moved == null || ((!) moved).occupant_count != 1,
            "A nickname transition must keep one stable occupant");
        fail_if(((!) moved).removed_count != 1 || ((!) moved).removed_at(0) != BOB,
            "Nickname transition must remove the old occupant identity");
        MucOccupantSnapshot? current = reducer.lookup(replacement);
        fail_if(current == null || ((!) current).role != MucWorkerRoleState.MODERATOR ||
            ((!) current).affiliation != MucWorkerAffiliationState.OWNER,
            "Nickname transition must preserve known role and affiliation state");
        fail_if_not_eq_str(((!) current).nick, "robert",
            "Nickname transition must publish the validated replacement resource");
        fail_if(((!) moved).changed_count != 1 ||
                (((!) moved).changed_flags_at(0) & MucOccupantChange.MEMBERSHIP) == 0 ||
                (((!) moved).changed_flags_at(0) & MucOccupantChange.NICK) == 0,
            "Nickname transition must report replacement membership and nick flags");
        fail_if_not_eq_str(((!) current).real_bare_jid, "bob@example.test",
            "Nickname transition must preserve the real bare JID");
        fail_if_not_eq_str(((!) current).hat_title_at(0), "Team",
            "Nickname transition must preserve hats");

        var privacy_reducer = new MucOccupantReducer(room_key());
        privacy_reducer.apply(available(1, BOB, "bob",
            MucWorkerAffiliationState.MEMBER, true,
            MucWorkerRoleState.PARTICIPANT, true, "bob@example.test"));
        privacy_reducer.apply(unavailable(2, BOB, "private-bob",
            nick_change, true));
        MucOccupantSnapshot? private_replacement =
            privacy_reducer.lookup(ROOM + "/private-bob");
        fail_if(private_replacement == null ||
                ((!) private_replacement).real_bare_jid != null,
            "An authoritative 303 item without jid must not carry the old real JID to the replacement nick");

        var invalid_reducer = new MucOccupantReducer(room_key());
        invalid_reducer.apply(available(1, BOB, "bob"));
        uint8[] invalid_nick_bytes = { 'r', 0xff, 0 };
        MucRoomDelta? invalid_move = invalid_reducer.apply(unavailable(2, BOB,
            (string) invalid_nick_bytes, nick_change));
        fail_if(invalid_move == null || ((!) invalid_move).removed_count != 1 ||
                ((!) invalid_move).changed_count != 0 ||
                ((!) invalid_move).occupant_count != 0,
            "Invalid 303 nick bytes must remove the old identity without creating a replacement");
    }

    private void test_degraded_initial_sync() {
        var reducer = new MucOccupantReducer(room_key());
        MucRoomDelta? degraded = reducer.finish_initial_sync(true);
        fail_if(degraded == null || !((!) degraded).initial_snapshot_ready ||
            !((!) degraded).initial_sync_finished || !((!) degraded).degraded_partial,
            "A timeout or overflow must finish as an explicit degraded partial snapshot");
        fail_if(reducer.finish_initial_sync(false) != null,
            "Repeating an already finished sync transition must be a no-op");
    }

    private MucRoomKey room_key() {
        return new MucRoomKey(7, ACCOUNT, ROOM, 1, 1);
    }

    private MucPresenceEnvelope available(uint64 sequence, string occupant_full_jid,
            string? nick = null,
            MucWorkerAffiliationState affiliation = MucWorkerAffiliationState.UNKNOWN,
            bool affiliation_known = false,
            MucWorkerRoleState role = MucWorkerRoleState.UNKNOWN,
            bool role_known = false, string? real_bare_jid = null,
            string[]? hat_uris = null, string[]? hat_titles = null,
            int[]? status_codes = null, bool is_self = false,
            string? avatar_hash = null, bool real_jid_known = false,
            string[]? hat_hues = null,
            bool initial_sync_boundary = false) {
        return new MucPresenceEnvelope(room_key(), sequence,
            MucWorkerPresenceKind.AVAILABLE, occupant_full_jid, nick, real_bare_jid,
            affiliation, affiliation_known, role, role_known, hat_uris, hat_titles,
            avatar_hash, status_codes, is_self, (int64) sequence * 1000,
            real_jid_known, hat_hues, initial_sync_boundary);
    }

    private MucPresenceEnvelope unavailable(uint64 sequence, string occupant_full_jid,
            string? replacement_nick = null, int[]? status_codes = null,
            bool real_jid_known = false) {
        return new MucPresenceEnvelope(room_key(), sequence,
            MucWorkerPresenceKind.UNAVAILABLE, occupant_full_jid, replacement_nick,
            null, MucWorkerAffiliationState.UNKNOWN, false,
            MucWorkerRoleState.UNKNOWN, false, null, null, null, status_codes,
            false, (int64) sequence * 1000, real_jid_known);
    }
}

}
