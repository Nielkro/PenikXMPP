namespace Dino.Ui.ConversationSummary {

/** Owns the identity of one asynchronous video playback setup attempt. */
internal class VideoPlaybackLifecycle : Object {
    private uint setup_generation = 0;
    private uint active_generation = 0;

    public bool has_active_setup {
        get { return active_generation != 0; }
    }

    public uint begin_setup() {
        setup_generation++;
        active_generation = setup_generation;
        return setup_generation;
    }

    public void invalidate_setup() {
        setup_generation++;
        active_generation = 0;
    }

    public bool is_current(uint generation) {
        return generation == setup_generation;
    }

    /** Finish only the operation which still owns the active generation. */
    public bool finish_setup(uint generation) {
        if (generation != active_generation) return false;
        active_generation = 0;
        return true;
    }
}

}
