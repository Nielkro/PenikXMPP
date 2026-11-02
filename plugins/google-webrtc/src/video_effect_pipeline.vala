namespace Dino.Plugins.GoogleWebrtc {

private delegate void VideoEffectControlFunc() throws Error;

/** One serialized control thread for the blocking worker IPC boundary. */
private class VideoEffectControlWorker : Object {
    private static GLib.Queue<VideoEffectControlLane>? normal_queue;
    private static GLib.Queue<VideoEffectControlLane>? cleanup_queue;
    private static Thread<void*>? worker_thread;
    private static Mutex queue_mutex;
    private static Cond queue_cond;

    public static VideoEffectControlLane create_lane() {
        return new VideoEffectControlLane();
    }

    public static async void run_latest(
            VideoEffectControlLane lane,
            owned VideoEffectControlFunc func) throws Error {
        SourceFunc callback = run_latest.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        var job = new VideoEffectControlJob(
            (owned) func,
            (owned) callback,
            (owned) callback_context);

        queue_mutex.lock();
        ensure_started_locked();
        if (lane.closing) {
            queue_mutex.unlock();
            job.cancel("The Google/libwebrtc video-effect pipeline is closing");
            yield;
            if (job.error != null) throw (!) job.error;
            return;
        }

        // Per logical call there can be only one native request in flight and
        // one replaceable pending request. Superseded UI choices complete with
        // CANCELLED instead of accumulating behind a slow worker IPC.
        VideoEffectControlJob? superseded = lane.pending_job;
        lane.pending_job = job;
        if (!lane.in_flight && !lane.queued_normal) {
            lane.queued_normal = true;
            ((!) normal_queue).push_tail(lane);
            queue_cond.signal();
        }
        queue_mutex.unlock();

        if (superseded != null) {
            ((!) superseded).cancel("A newer video-effect choice replaced this request");
        }
        yield;
        if (job.error != null) throw (!) job.error;
    }

    public static void request_cleanup(
            VideoEffectControlLane lane,
            owned VideoEffectControlFunc func) {
        VideoEffectControlJob? superseded = null;
        VideoEffectControlJob? in_flight = null;
        queue_mutex.lock();
        ensure_started_locked();
        if (lane.closing || lane.cleanup_finished) {
            queue_mutex.unlock();
            return;
        }

        lane.closing = true;
        superseded = lane.pending_job;
        lane.pending_job = null;
        in_flight = lane.in_flight_job;
        lane.cleanup_func = (owned) func;
        if (lane.queued_normal) {
            ((!) normal_queue).remove(lane);
            lane.queued_normal = false;
        }
        if (!lane.in_flight && !lane.queued_cleanup) {
            lane.queued_cleanup = true;
            ((!) cleanup_queue).push_tail(lane);
            queue_cond.signal();
        }
        queue_mutex.unlock();

        if (superseded != null) {
            ((!) superseded).cancel("The Google/libwebrtc video-effect pipeline is closing");
        }
        if (in_flight != null) {
            // The native call itself remains owned by the control worker, but
            // its logical result is invalid immediately. This resumes the UI
            // request with CANCELLED without waiting for the IPC timeout; the
            // worker then runs prioritized cleanup as soon as native control
            // returns.
            ((!) in_flight).cancel("The Google/libwebrtc video-effect pipeline is closing");
        }
    }

    public static async void wait_for_cleanup(VideoEffectControlLane lane) {
        SourceFunc callback = wait_for_cleanup.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        var waiter = new VideoEffectCleanupWaiter(
            (owned) callback, (owned) callback_context);

        queue_mutex.lock();
        ensure_started_locked();
        if (lane.cleanup_finished || !lane.closing) {
            queue_mutex.unlock();
            return;
        }
        lane.cleanup_waiters.push_tail(waiter);
        queue_mutex.unlock();
        yield;
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    internal static bool lane_in_flight(VideoEffectControlLane lane) {
        queue_mutex.lock();
        bool in_flight = lane.in_flight;
        queue_mutex.unlock();
        return in_flight;
    }

    internal static uint lane_pending_count(VideoEffectControlLane lane) {
        queue_mutex.lock();
        uint count = lane.pending_job != null ? 1U : 0U;
        queue_mutex.unlock();
        return count;
    }

    internal static bool lane_cleanup_finished(VideoEffectControlLane lane) {
        queue_mutex.lock();
        bool finished = lane.cleanup_finished;
        queue_mutex.unlock();
        return finished;
    }
#endif

    private static void ensure_started_locked() {
        if (worker_thread != null) return;
        normal_queue = new GLib.Queue<VideoEffectControlLane>();
        cleanup_queue = new GLib.Queue<VideoEffectControlLane>();
        worker_thread = new Thread<void*>("dinox-video-effect-control", worker_main);
    }

    private static void* worker_main() {
        while (true) {
            VideoEffectControlLane lane;
            VideoEffectControlJob? normal_job = null;
            VideoEffectControlFunc? cleanup_func = null;
            bool is_cleanup = false;

            queue_mutex.lock();
            while (((!) cleanup_queue).is_empty() && ((!) normal_queue).is_empty()) {
                queue_cond.wait(queue_mutex);
            }
            if (!((!) cleanup_queue).is_empty()) {
                lane = ((!) cleanup_queue).pop_head();
                lane.queued_cleanup = false;
                cleanup_func = (owned) lane.cleanup_func;
                lane.cleanup_func = null;
                is_cleanup = true;
            } else {
                lane = ((!) normal_queue).pop_head();
                lane.queued_normal = false;
                normal_job = lane.pending_job;
                lane.pending_job = null;
                lane.in_flight_job = normal_job;
            }
            lane.in_flight = true;
            queue_mutex.unlock();

            if (is_cleanup) {
                if (cleanup_func != null) {
                    try {
                        ((!) cleanup_func)();
                    } catch (Error e) {
                        debug("Google/libwebrtc video-effect cleanup failed: %s", e.message);
                    }
                }
            } else if (normal_job != null) {
                ((!) normal_job).run();
            }

            queue_mutex.lock();
            lane.in_flight = false;
            lane.in_flight_job = null;
            if (is_cleanup) {
                lane.cleanup_finished = true;
                while (!lane.cleanup_waiters.is_empty()) {
                    VideoEffectCleanupWaiter waiter =
                        lane.cleanup_waiters.pop_head();
                    waiter.complete();
                }
            } else if (lane.cleanup_func != null && !lane.queued_cleanup) {
                // Cleanup always jumps ahead of normal work once the currently
                // executing native IPC returns.
                lane.queued_cleanup = true;
                ((!) cleanup_queue).push_tail(lane);
                queue_cond.signal();
            } else if (lane.pending_job != null && !lane.queued_normal) {
                lane.queued_normal = true;
                ((!) normal_queue).push_tail(lane);
                queue_cond.signal();
            }
            queue_mutex.unlock();
        }
    }
}

private class VideoEffectControlLane : Object {
    internal VideoEffectControlJob? pending_job;
    internal VideoEffectControlJob? in_flight_job;
    internal VideoEffectControlFunc? cleanup_func;
    internal bool queued_normal = false;
    internal bool queued_cleanup = false;
    internal bool in_flight = false;
    internal bool closing = false;
    internal bool cleanup_finished = false;
    internal GLib.Queue<VideoEffectCleanupWaiter> cleanup_waiters =
        new GLib.Queue<VideoEffectCleanupWaiter>();
}

private class VideoEffectCleanupWaiter : Object {
    private SourceFunc callback;
    private MainContext callback_context;

    internal VideoEffectCleanupWaiter(
            owned SourceFunc callback,
            owned MainContext callback_context) {
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    internal void complete() {
        var source = new IdleSource();
        source.set_callback((owned) callback);
        source.attach(callback_context);
    }
}

private class VideoEffectControlJob : Object {
    public Error? error { get; private set; }
    private VideoEffectControlFunc func;
    private SourceFunc callback;
    private MainContext callback_context;
    private Mutex completion_mutex;
    private bool completed = false;

    public VideoEffectControlJob(
            owned VideoEffectControlFunc func,
            owned SourceFunc callback,
            owned MainContext callback_context) {
        this.func = (owned) func;
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    public void run() {
        Error? run_error = null;
        try {
            func();
        } catch (Error e) {
            run_error = e;
        }
        complete((owned) run_error);
    }

    public void cancel(string message) {
        completion_mutex.lock();
        if (completed) {
            completion_mutex.unlock();
            return;
        }
        error = new IOError.CANCELLED(message);
        completed = true;
        completion_mutex.unlock();
        dispatch_callback();
    }

    private void complete(owned Error? run_error) {
        completion_mutex.lock();
        if (completed) {
            completion_mutex.unlock();
            return;
        }
        error = (owned) run_error;
        completed = true;
        completion_mutex.unlock();
        dispatch_callback();
    }

    private void dispatch_callback() {
        var source = new IdleSource();
        source.set_callback((owned) callback);
        source.attach(callback_context);
    }
}

/**
 * Owns the control plane for one logical outgoing-video pipeline.
 *
 * Effect frames stay entirely inside the native libwebrtc pipeline; no frame,
 * effect buffer or model crosses this Vala boundary.
 */
public class EngineVideoEffectPipelineOwner : Object {
    private Native.VideoPipeline? native_pipeline;
    private EngineContextActivityLease? activity_lease;
    // Strong references are intentional: native pipeline destruction owns the
    // final detach barrier, so attached session handles must stay alive until
    // that barrier has completed.
    private Gee.ArrayList<EngineSessionOwner> attached_sessions =
        new Gee.ArrayList<EngineSessionOwner>();
    private EngineSessionOwner? preview_session;
    private MainContext callback_context;
    private RecMutex native_mutex;
    private Mutex state_mutex;
    private RecMutex signal_mutex;
    private bool closed = false;
    private bool cached_state_available = false;
    private Native.VideoPipelineState cached_state = {};
    private bool pending_state_available = false;
    private bool state_dispatch_scheduled = false;
    private Native.VideoPipelineState pending_state = {};
    private Source? state_dispatch_source;
    private Native.VideoEffectCapabilities cached_capabilities = {};
    private uint64 background_choice_generation = 0;
#if GOOGLE_WEBRTC_EFFECT_TEST
    private Mutex background_probe_mutex;
    private Cond background_probe_cond;
    private bool background_probe_blocked = false;
    private bool background_probe_reached = false;
#endif
    private VideoEffectControlLane control_lane = VideoEffectControlWorker.create_lane();
    private VideoEffectControlLane background_lane = VideoEffectControlWorker.create_lane();
    private VideoEffectControlLane background_release_lane = VideoEffectControlWorker.create_lane();

    public uint64 logical_call_id { get; private set; }

    /** Emitted on the creating thread's main context after cached_state changed. */
    public signal void state_changed();

    internal EngineVideoEffectPipelineOwner(
            Native.Context context,
            uint64 logical_call_id) throws EngineError {
        if (logical_call_id == 0) {
            throw new EngineError.PROTOCOL("A video-effect pipeline requires a stable logical call id");
        }
        this.logical_call_id = logical_call_id;
        callback_context = MainContext.ref_thread_default();

        // Do not call the by-value C default helper here. This callback
        // structure is small enough to use register return on some ABIs while
        // Vala lowers struct-return declarations to an out parameter. A zeroed
        // value with the two public fields assigned is portable on Linux and
        // Windows and keeps the reserved-free ABI explicit.
        Native.VideoPipelineCallbacks callbacks = {};
        callbacks.abi_version = Native.ABI_VERSION;
        callbacks.on_state_changed = on_native_state_changed;

        Native.VideoPipeline? created = null;
        throw_if_native_error(
            Native.video_pipeline_new(
                context,
                logical_call_id,
                ref callbacks,
                this,
                out created),
            "creating Google/libwebrtc video-effect pipeline");
        native_pipeline = (owned) created;

        throw_if_native_error(
            Native.context_get_video_effect_capabilities(context, out cached_capabilities),
            "reading Google/libwebrtc video-effect capabilities");
        if (cached_capabilities.abi_version != Native.ABI_VERSION) {
            close();
            throw new EngineError.NATIVE("Google/libwebrtc video-effect capabilities ABI mismatch");
        }

        Native.VideoPipelineState initial_state = {};
        try {
            throw_if_native_error(
                Native.video_pipeline_get_state(native_pipeline, out initial_state),
                "reading initial Google/libwebrtc video-effect state");
            validate_state(initial_state);
            state_mutex.lock();
            cached_state = initial_state;
            cached_state_available = true;
            state_mutex.unlock();
        } catch (EngineError e) {
            close();
            throw e;
        }
    }

    public Native.VideoPipelineState get_state() throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            Native.VideoPipelineState state = {};
            throw_if_native_error(
                Native.video_pipeline_get_state(native_pipeline, out state),
                "reading Google/libwebrtc video-effect state");
            validate_state(state);
            return state;
        } finally {
            native_mutex.unlock();
        }
    }

    public Native.VideoEffectCapabilities get_capabilities() {
        return cached_capabilities;
    }

    public bool get_cached_state(out Native.VideoPipelineState state) {
        state_mutex.lock();
        bool available = cached_state_available;
        state = cached_state;
        state_mutex.unlock();
        return available;
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    /** Internal lifecycle probe used by deterministic control-plane smokes. */
    internal bool has_queued_state(uint64 revision) {
        state_mutex.lock();
        bool queued = !closed && state_dispatch_scheduled &&
            pending_state_available &&
            pending_state.accepted_revision == revision &&
            pending_state.applied_revision == revision;
        state_mutex.unlock();
        return queued;
    }

    internal void inject_state_for_test(Native.VideoPipelineState state) {
        dispatch_state(state);
    }
#endif

    public Native.VideoEffectDiagnostics get_diagnostics() throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            Native.VideoEffectDiagnostics diagnostics = {};
            throw_if_native_error(
                Native.video_pipeline_get_diagnostics(native_pipeline, out diagnostics),
                "reading Google/libwebrtc video-effect diagnostics");
            if (diagnostics.abi_version != Native.ABI_VERSION) {
                throw new EngineError.NATIVE("Google/libwebrtc video-effect diagnostics ABI mismatch");
            }
            return diagnostics;
        } finally {
            native_mutex.unlock();
        }
    }

    public uint64 set_none() throws EngineError {
        return set_effect_sync(Native.VideoEffectType.NONE);
    }

    public async uint64 select_effect(Native.VideoEffectType effect_type) throws Error {
        Native.VideoEffectConfig config = Native.video_effect_config_default();
        config.effect_type = effect_type;
        return yield select_config(config);
    }

    public async uint64 select_config(Native.VideoEffectConfig config) throws Error {
        uint64 revision = 0;
        yield VideoEffectControlWorker.run_latest(control_lane, () => {
            revision = set_config_sync(config);
        });
        return revision;
    }

    public async uint stage_background(uint builtin_choice,
            Dino.Plugins.JmiVideoBackgroundImage? image) throws Error {
        if ((image == null && (builtin_choice < 1 || builtin_choice > 10)) ||
                (image != null && builtin_choice != 0))
            throw new IOError.INVALID_ARGUMENT("Invalid background image choice");
        state_mutex.lock();
        if (background_choice_generation == uint64.MAX) {
            state_mutex.unlock();
            throw new IOError.CANCELLED("The background choice generation is exhausted");
        }
        uint64 generation = ++background_choice_generation;
        state_mutex.unlock();
        uint32 asset = 0;
        try { yield VideoEffectControlWorker.run_latest(background_lane, () => {
            native_mutex.lock();
            try {
                require_open();
                if (image != null) {
                    unowned uint8[] pixels = ((!) image).pixels.get_data();
                    throw_if_native_error(Native.video_pipeline_background_upload(
                        (!) native_pipeline, ((!) image).width, ((!) image).height,
                        ((!) image).stride, ((!) image).rgba ? Native.BackgroundPixelFormat.RGBA8888 :
                        Native.BackgroundPixelFormat.RGB888, pixels, out asset), "staging background pixels");
                } else {
                    throw_if_native_error(Native.video_pipeline_background_builtin(
                        (!) native_pipeline, (Native.BackgroundBuiltin) builtin_choice, out asset),
                        "staging a background illustration");
                }
                try {
                    throw_if_native_error(Native.video_pipeline_background_prepare(
                        (!) native_pipeline, asset), "preparing background pixels");
                } catch (Error e) {
                    release_unused_staged_background_sync(asset);
                    throw e;
                }
#if GOOGLE_WEBRTC_EFFECT_TEST
                background_probe_mutex.lock();
                if (background_probe_blocked) {
                    background_probe_reached = true;
                    while (background_probe_blocked) background_probe_cond.wait(background_probe_mutex);
                }
                background_probe_mutex.unlock();
#endif
                state_mutex.lock();
                bool current = !closed && background_choice_generation == generation;
                state_mutex.unlock();
                if (!current) {
                    release_unused_staged_background_sync(asset);
                    throw new IOError.CANCELLED("A newer background choice replaced this image");
                }
            } finally { native_mutex.unlock(); }
        }); } catch (Error e) {
            state_mutex.lock();
            if (background_choice_generation == generation && background_choice_generation != uint64.MAX)
                background_choice_generation++;
            state_mutex.unlock();
            throw e;
        }
        return asset;
    }

    // Called with native_mutex held. Builtins can deduplicate to the already
    // accepted IMAGE ID, so obsolete staging never owns that active lease.
    private void release_unused_staged_background_sync(uint32 asset_id) {
        if (asset_id == 0 || native_pipeline == null) return;
        Native.VideoPipelineState current = {};
        if (Native.video_pipeline_get_state((!) native_pipeline, out current) != Native.Status.OK) return;
        if (current.background_mode == Native.VideoBackgroundMode.IMAGE && current.asset_id == asset_id) return;
        Native.video_pipeline_background_release((!) native_pipeline, asset_id);
    }

    public async void release_background(uint asset_id) throws Error {
        if (asset_id == 0) return;
        yield VideoEffectControlWorker.run_latest(background_release_lane, () => {
            native_mutex.lock();
            try {
                state_mutex.lock(); bool is_closed = closed; state_mutex.unlock();
                if (is_closed || native_pipeline == null) return;
                Native.VideoPipelineState current = {};
                throw_if_native_error(Native.video_pipeline_get_state((!) native_pipeline, out current),
                    "checking staged background ownership");
                // A deduplicated illustration may already belong to a newer
                // accepted selection. Releasing an obsolete UI request must
                // never discard that active image.
                if (current.background_mode == Native.VideoBackgroundMode.IMAGE && current.asset_id == asset_id) return;
                Native.Status result = Native.video_pipeline_background_release((!) native_pipeline, asset_id);
                if (result != Native.Status.NOT_READY)
                    throw_if_native_error(result, "releasing an unused background image");
            } finally { native_mutex.unlock(); }
        });
    }

    private uint64 set_effect_sync(Native.VideoEffectType effect_type) throws EngineError {
        Native.VideoEffectConfig config = Native.video_effect_config_default();
        config.effect_type = effect_type;
        return set_config_sync(config);
    }

    private uint64 set_config_sync(Native.VideoEffectConfig config) throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            uint64 revision = 0;
            throw_if_native_error(
                Native.video_pipeline_set_config(native_pipeline, ref config, out revision),
                "selecting Google/libwebrtc video effect");
            if (revision == 0) {
                throw new EngineError.NATIVE("Google/libwebrtc returned an invalid video-effect revision");
            }
            return revision;
        } finally {
            native_mutex.unlock();
        }
    }

    public void attach(EngineSessionOwner session, bool preview_publisher = true) throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            bool already_attached = attached_sessions.contains(session);
            if (preview_publisher && preview_session != null && preview_session != session) {
                throw new EngineError.PROTOCOL(
                    "Video-effect pipeline already has a preview publisher");
            }
            if (already_attached &&
                    ((preview_publisher && preview_session == session) ||
                     (!preview_publisher && preview_session != session))) {
                return;
            }
            session.attach_video_effect_pipeline((!) native_pipeline, preview_publisher);
            if (!already_attached) attached_sessions.add(session);
            if (preview_session == session && !preview_publisher) {
                preview_session = null;
            } else if (preview_publisher) {
                preview_session = session;
            }
        } finally {
            native_mutex.unlock();
        }
    }

    public void detach_session(EngineSessionOwner session) throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            if (!attached_sessions.contains(session)) return;
            // Native session close already removes the attachment and stops
            // its capture. Only the Vala references remain to be released.
            if (!session.is_closed) {
                session.detach_video_effect_pipeline((!) native_pipeline);
            }
            attached_sessions.remove(session);
            if (preview_session == session) preview_session = null;
        } finally {
            native_mutex.unlock();
        }
    }

    /** Detaches every current subscriber; retained for the direct-call owner. */
    public void detach() throws EngineError {
        native_mutex.lock();
        try {
            require_open();
            var snapshot = new Gee.ArrayList<EngineSessionOwner>();
            snapshot.add_all(attached_sessions);
            foreach (EngineSessionOwner session in snapshot) {
                if (!session.is_closed) {
                    session.detach_video_effect_pipeline((!) native_pipeline);
                }
                attached_sessions.remove(session);
                if (preview_session == session) preview_session = null;
            }
        } finally {
            native_mutex.unlock();
        }
    }

    public void close() {
        // Serialize teardown with the final signal emission. This keeps the
        // stronger lifecycle guarantee even if a caller closes from outside
        // the creating main context: no state_changed signal starts after
        // close() has returned. Recursion is intentional because a signal
        // handler may itself release the last pipeline owner.
        signal_mutex.lock();
        Source? source_to_destroy = null;
        state_mutex.lock();
        if (closed) {
            state_mutex.unlock();
            signal_mutex.unlock();
            return;
        }
        closed = true;
        pending_state_available = false;
        state_dispatch_scheduled = false;
        source_to_destroy = state_dispatch_source;
        state_dispatch_source = null;
        state_mutex.unlock();

        if (source_to_destroy != null) ((!) source_to_destroy).destroy();
        signal_mutex.unlock();

        // Never wait for native_mutex or worker IPC on the GTK/call teardown
        // path. The owner remains alive through this closure until native
        // pipeline destruction has atomically removed all session attachments.
        // Do not call back through attached_session here: the wire session may
        // already be closing on the main thread while this job is pending.
        VideoEffectControlWorker.request_cleanup(background_lane, () => { });
        VideoEffectControlWorker.request_cleanup(background_release_lane, () => { });
        VideoEffectControlWorker.request_cleanup(control_lane, () => {
            finish_close_sync();
        });
    }

    /** Async destroy barrier used before a call is promoted to MUJI. */
    internal async void close_and_wait_for_cleanup() {
        close();
        yield VideoEffectControlWorker.wait_for_cleanup(control_lane);
    }

    private void finish_close_sync() {
        native_mutex.lock();
        try {
            // C pipeline destruction removes every attachment without calling
            // through a possibly closing Vala session. Keep both the session
            // reference and context activity lease alive until that completes.
            native_pipeline = null;
            attached_sessions.clear();
            preview_session = null;
            release_activity_lease();
        } finally {
            native_mutex.unlock();
        }
    }

#if GOOGLE_WEBRTC_EFFECT_TEST
    // Test-only barrier after prepare but before generation publication. The
    // GTK test can supersede a physically running stage without timing races.
    internal void arm_background_precommit_for_test() {
        background_probe_mutex.lock();
        background_probe_reached = false; background_probe_blocked = true;
        background_probe_mutex.unlock();
    }

    internal bool background_precommit_reached_for_test() {
        background_probe_mutex.lock(); bool reached = background_probe_reached;
        background_probe_mutex.unlock(); return reached;
    }

    internal void release_background_precommit_for_test() {
        background_probe_mutex.lock(); background_probe_blocked = false;
        background_probe_cond.broadcast(); background_probe_mutex.unlock();
    }

    /** Deterministic probe for a blocked native-control call during close. */
    internal async void block_native_control_for_test(uint milliseconds) throws Error {
        yield VideoEffectControlWorker.run_latest(control_lane, () => {
            native_mutex.lock();
            Thread.usleep((ulong) milliseconds * 1000UL);
            native_mutex.unlock();
        });
    }

    internal bool control_in_flight_for_test() {
        return VideoEffectControlWorker.lane_in_flight(control_lane);
    }

    internal uint control_pending_count_for_test() {
        return VideoEffectControlWorker.lane_pending_count(control_lane);
    }

    internal bool cleanup_finished_for_test() {
        return VideoEffectControlWorker.lane_cleanup_finished(control_lane);
    }

    internal int attachment_count_for_test() {
        native_mutex.lock();
        int count = attached_sessions.size;
        native_mutex.unlock();
        return count;
    }

    internal bool is_preview_session_for_test(EngineSessionOwner session) {
        native_mutex.lock();
        bool matches = preview_session == session;
        native_mutex.unlock();
        return matches;
    }

#endif

    internal void take_activity_lease(owned EngineContextActivityLease lease) {
        activity_lease = (owned) lease;
    }

    ~EngineVideoEffectPipelineOwner() {
        close();
    }

    private void require_open() throws EngineError {
        state_mutex.lock();
        bool unavailable = closed || native_pipeline == null;
        state_mutex.unlock();
        if (unavailable) {
            throw new EngineError.CLOSED("Google/libwebrtc video-effect pipeline is closed");
        }
    }

    private void validate_state(Native.VideoPipelineState state) throws EngineError {
        if (state.abi_version != Native.ABI_VERSION ||
                state.pipeline_id == 0 || state.pipeline_generation == 0 ||
                state.logical_call_id != logical_call_id ||
                state.applied_revision > state.accepted_revision) {
            throw new EngineError.NATIVE("Google/libwebrtc returned an invalid video-effect state");
        }
        VideoEffectConfigMapper.from_native(state);
    }

    private void dispatch_state(Native.VideoPipelineState state) {
        try {
            validate_state(state);
        } catch (EngineError e) {
            debug("Ignoring an invalid Google/libwebrtc video-effect callback: %s", e.message);
            return;
        }
        state_mutex.lock();
        if (closed || (cached_state_available &&
                (state.pipeline_id != cached_state.pipeline_id ||
                 state.pipeline_generation != cached_state.pipeline_generation ||
                 state.accepted_revision < cached_state.accepted_revision ||
                 state.applied_revision < cached_state.applied_revision)) ||
                (pending_state_available &&
                (state.pipeline_id != pending_state.pipeline_id ||
                 state.pipeline_generation != pending_state.pipeline_generation ||
                 state.accepted_revision < pending_state.accepted_revision ||
                 state.applied_revision < pending_state.applied_revision))) {
            state_mutex.unlock();
            return;
        }
        // Keep only the newest state and at most one queued main-context
        // source. Rapid revisions must not create an unbounded IdleSource
        // backlog in the GTK process.
        pending_state = state;
        pending_state_available = true;
        if (!state_dispatch_scheduled) {
            state_dispatch_scheduled = true;
            var source = new IdleSource();
            source.set_callback(deliver_pending_state);
            state_dispatch_source = source;
            source.attach(callback_context);
        }
        state_mutex.unlock();
    }

    private bool deliver_pending_state() {
        state_mutex.lock();
        state_dispatch_source = null;
        if (closed || !pending_state_available) {
            pending_state_available = false;
            state_dispatch_scheduled = false;
            state_mutex.unlock();
            return Source.REMOVE;
        }
        Native.VideoPipelineState state = pending_state;
        pending_state_available = false;
        state_dispatch_scheduled = false;
        bool stale =
            state.abi_version != Native.ABI_VERSION ||
            state.logical_call_id != logical_call_id ||
            state.pipeline_id == 0 || state.pipeline_generation == 0 ||
            (cached_state_available &&
                (state.pipeline_id != cached_state.pipeline_id ||
                 state.pipeline_generation != cached_state.pipeline_generation ||
                 state.accepted_revision < cached_state.accepted_revision ||
                 state.applied_revision < cached_state.applied_revision));
        if (!stale) {
            cached_state = state;
            cached_state_available = true;
        }
        state_mutex.unlock();
        if (!stale) {
            signal_mutex.lock();
            state_mutex.lock();
            bool emit = !closed;
            state_mutex.unlock();
            if (emit) state_changed();
            signal_mutex.unlock();
        }
        return Source.REMOVE;
    }

    private void release_activity_lease() {
        if (activity_lease == null) return;
        ((!) activity_lease).release();
        activity_lease = null;
    }

    private static void on_native_state_changed(
            Native.VideoPipeline? pipeline,
            Native.VideoPipelineState* state,
            void* user_data) {
        if (state == null || user_data == null) return;
        unowned EngineVideoEffectPipelineOwner self = (EngineVideoEffectPipelineOwner) user_data;
        self.dispatch_state(*state);
    }
}

}
