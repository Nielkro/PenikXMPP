using Dino.Ui.ConversationSummary;

namespace Dino.Ui.Test {

class VideoPlaybackLifecycleTest : Gee.TestCase {
    public VideoPlaybackLifecycleTest() {
        base("VideoPlaybackLifecycle");
        add_test("new_setup_supersedes_previous_attempt",
            test_new_setup_supersedes_previous_attempt);
        add_test("explicit_invalidation_rejects_late_completion",
            test_explicit_invalidation_rejects_late_completion);
        add_test("late_finish_cannot_stop_replacement_attempt",
            test_late_finish_cannot_stop_replacement_attempt);
    }

    private void test_new_setup_supersedes_previous_attempt() {
        var lifecycle = new VideoPlaybackLifecycle();
        uint first = lifecycle.begin_setup();
        assert_true(lifecycle.is_current(first),
            "the active setup token must initially be current");

        uint second = lifecycle.begin_setup();
        assert_false(lifecycle.is_current(first),
            "a remapped playback setup must reject the previous completion");
        assert_true(lifecycle.is_current(second),
            "the replacement setup token must be current");
    }

    private void test_explicit_invalidation_rejects_late_completion() {
        var lifecycle = new VideoPlaybackLifecycle();
        uint setup = lifecycle.begin_setup();

        lifecycle.invalidate_setup();

        assert_false(lifecycle.is_current(setup),
            "unmap, revocation or dispose must invalidate an in-flight setup");
        assert_false(lifecycle.has_active_setup,
            "invalidation must clear the active operation");
    }

    private void test_late_finish_cannot_stop_replacement_attempt() {
        var lifecycle = new VideoPlaybackLifecycle();
        uint first = lifecycle.begin_setup();
        lifecycle.invalidate_setup();
        uint replacement = lifecycle.begin_setup();

        assert_false(lifecycle.finish_setup(first),
            "a stale completion must not finish the replacement operation");
        assert_true(lifecycle.has_active_setup,
            "the replacement operation must remain active");
        assert_true(lifecycle.is_current(replacement),
            "the replacement generation must remain current");

        assert_true(lifecycle.finish_setup(replacement),
            "the current operation must be allowed to finish itself");
        assert_false(lifecycle.has_active_setup,
            "the current completion must clear the active operation");
    }
}

}
