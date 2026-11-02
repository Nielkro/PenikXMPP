namespace Dino.Ui.OccupantMenu {

internal enum InitialSnapshotWaitDecision {
    KEEP_WAITING,
    RELEASE_QUIET_STATE,
    RELEASE_DEADLINE
}

/**
 * Pure presentation policy for the initial member-list wait.
 *
 * This never changes XMPP join state.  In particular, reaching the visible
 * deadline only permits a non-authoritative UI fallback while a complete
 * worker snapshot continues in the background.
 */
internal class InitialSnapshotWaitPolicy : Object {
    internal const int SYNC_QUIET_MS = 250;
    internal const int MAX_VISIBLE_WAIT_MS = 1000;

    internal static InitialSnapshotWaitDecision decide(
            int64 waited_us,
            int64 quiet_us,
            bool initial_presence_sync,
            bool waiting_for_uncached_snapshot,
            int occupant_count,
            int platform_quiet_ms,
            bool snapshot_apply_pending) {
        // This is deliberately the first branch: protocol sync and a pending
        // worker apply must not turn the presentation deadline back into the
        // old 45-second network wait.
        if (waited_us >= (int64) MAX_VISIBLE_WAIT_MS * 1000) {
            return InitialSnapshotWaitDecision.RELEASE_DEADLINE;
        }

        if (snapshot_apply_pending) {
            return InitialSnapshotWaitDecision.KEEP_WAITING;
        }

        bool uncached_snapshot_ready = !waiting_for_uncached_snapshot ||
            occupant_count > 0;
        bool visible_state_ready_before_sync_settles = occupant_count > 0 &&
            quiet_us >= (int64) SYNC_QUIET_MS * 1000;
        if ((!initial_presence_sync ||
                visible_state_ready_before_sync_settles) &&
                uncached_snapshot_ready &&
                quiet_us >= (int64) platform_quiet_ms * 1000) {
            return InitialSnapshotWaitDecision.RELEASE_QUIET_STATE;
        }

        return InitialSnapshotWaitDecision.KEEP_WAITING;
    }

    internal static bool can_keep_cached_presentation(
            bool cache_loaded,
            bool has_visible_rows,
            bool commit_pending) {
        // An in-memory item array alone is not a visible or progressing UI.
        // Keeping it without rows or an active commit would leave the spinner
        // running forever instead of rebuilding the partial fallback.
        return cache_loaded && (has_visible_rows || commit_pending);
    }

    internal static bool needs_empty_partial_surface(
            int occupant_count,
            bool has_visible_rows,
            bool commit_pending) {
        // A released wait without any rows is still an automatic presentation.
        // It must not fall back to the manual "show list" trigger while a late
        // authoritative snapshot is still allowed to arrive.
        return occupant_count == 0 && !has_visible_rows && !commit_pending;
    }
}

}
