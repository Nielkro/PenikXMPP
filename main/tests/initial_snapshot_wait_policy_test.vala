using Dino.Ui.OccupantMenu;

namespace Dino.Ui.Test {

class InitialSnapshotWaitPolicyTest : Gee.TestCase {
    public InitialSnapshotWaitPolicyTest() {
        base("InitialSnapshotWaitPolicy");
        add_test("deadline_releases_zero_member_sync", test_deadline_releases_zero_member_sync);
        add_test("deadline_releases_pending_worker_apply", test_deadline_releases_pending_worker_apply);
        add_test("pre_deadline_zero_member_sync_waits", test_pre_deadline_zero_member_sync_waits);
        add_test("quiet_known_members_release", test_quiet_known_members_release);
        add_test("pending_worker_apply_waits_before_deadline", test_pending_worker_apply_waits_before_deadline);
        add_test("cached_array_without_rows_or_commit_cannot_stall", test_cached_array_without_rows_or_commit_cannot_stall);
        add_test("visible_or_committing_cache_can_be_kept", test_visible_or_committing_cache_can_be_kept);
        add_test("released_zero_member_wait_uses_empty_surface", test_released_zero_member_wait_uses_empty_surface);
    }

    private void test_deadline_releases_zero_member_sync() {
        assert_decision(InitialSnapshotWaitDecision.RELEASE_DEADLINE,
            1000, 0, true, true, 0, 250, false);
    }

    private void test_deadline_releases_pending_worker_apply() {
        assert_decision(InitialSnapshotWaitDecision.RELEASE_DEADLINE,
            1000, 0, true, true, 0, 250, true);
    }

    private void test_pre_deadline_zero_member_sync_waits() {
        assert_decision(InitialSnapshotWaitDecision.KEEP_WAITING,
            999, 999, true, true, 0, 250, false);
    }

    private void test_quiet_known_members_release() {
        assert_decision(InitialSnapshotWaitDecision.RELEASE_QUIET_STATE,
            250, 250, true, true, 5, 250, false);
    }

    private void test_pending_worker_apply_waits_before_deadline() {
        assert_decision(InitialSnapshotWaitDecision.KEEP_WAITING,
            750, 750, false, false, 200, 0, true);
    }

    private void test_cached_array_without_rows_or_commit_cannot_stall() {
        assert_false(InitialSnapshotWaitPolicy.can_keep_cached_presentation(
            true, false, false));
    }

    private void test_visible_or_committing_cache_can_be_kept() {
        assert_true(InitialSnapshotWaitPolicy.can_keep_cached_presentation(
            true, true, false));
        assert_true(InitialSnapshotWaitPolicy.can_keep_cached_presentation(
            true, false, true));
        assert_false(InitialSnapshotWaitPolicy.can_keep_cached_presentation(
            false, true, true));
    }

    private void test_released_zero_member_wait_uses_empty_surface() {
        assert_true(InitialSnapshotWaitPolicy.needs_empty_partial_surface(
            0, false, false));
        assert_false(InitialSnapshotWaitPolicy.needs_empty_partial_surface(
            1, false, false));
        assert_false(InitialSnapshotWaitPolicy.needs_empty_partial_surface(
            0, true, false));
        assert_false(InitialSnapshotWaitPolicy.needs_empty_partial_surface(
            0, false, true));
    }

    private void assert_decision(InitialSnapshotWaitDecision expected,
            int waited_ms,
            int quiet_ms,
            bool initial_presence_sync,
            bool waiting_for_uncached_snapshot,
            int occupant_count,
            int platform_quiet_ms,
            bool snapshot_apply_pending) {
        InitialSnapshotWaitDecision actual = InitialSnapshotWaitPolicy.decide(
            (int64) waited_ms * 1000, (int64) quiet_ms * 1000,
            initial_presence_sync, waiting_for_uncached_snapshot,
            occupant_count, platform_quiet_ms, snapshot_apply_pending);
        assert_true(actual == expected,
            "unexpected initial member-list wait decision");
    }
}

}
