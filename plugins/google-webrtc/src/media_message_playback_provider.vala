namespace Dino.Plugins.GoogleWebrtc {

public class GoogleWebrtcMediaMessagePlaybackProvider : Object, Dino.Plugins.MediaMessagePlaybackProvider {
    public signal void playback_failed(string message);

    private EngineContextSupplier? context_supplier;
    private PreferredMediaDeviceNameSupplier? preferred_audio_output_name_supplier;
    private bool owns_context;
    private GoogleWebrtcMediaMessagePlaybackSession? current_session = null;
    private Mutex creation_mutex = Mutex();
    private Mutex session_mutex = Mutex();

    public string id { get { return "google-libwebrtc"; } }
    public bool available { get { return context_supplier != null; } }
    public string? unavailable_reason {
        owned get {
            return available ? null : "Google/libwebrtc playback context is not available";
        }
    }

    public GoogleWebrtcMediaMessagePlaybackProvider(
            owned EngineContextSupplier context_supplier,
            owned PreferredMediaDeviceNameSupplier? preferred_audio_output_name_supplier = null,
            bool owns_context = false) {
        this.context_supplier = (owned) context_supplier;
        this.preferred_audio_output_name_supplier = (owned) preferred_audio_output_name_supplier;
        this.owns_context = owns_context;
    }

    public Gee.List<Dino.Plugins.MediaDevice> get_audio_output_devices() {
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        if (context_supplier == null) return devices;
        EngineContext? device_context = null;
        try {
            device_context = ((!) context_supplier)();
            foreach (EngineAudioDeviceInfo info in ((!) device_context).get_audio_devices(true)) {
                devices.add(new EngineMediaDevice(info));
            }
        } catch (Error e) {
            warning("Google/libwebrtc media playback: cannot enumerate speaker devices: %s", e.message);
            playback_failed(e.message);
        } finally {
            if (owns_context && device_context != null) ((!) device_context).close();
        }
        devices.sort((left, right) => strcmp(left.id, right.id));
        return devices;
    }

    public Dino.Plugins.MediaMessagePlaybackSession create_audio_playback_session() throws Error {
        creation_mutex.lock();
        try {
            if (context_supplier == null) {
                throw new EngineError.CLOSED("Google/libwebrtc playback context is not available");
            }

            GoogleWebrtcMediaMessagePlaybackSession? previous = null;
            session_mutex.lock();
            previous = current_session;
            current_session = null;
            session_mutex.unlock();
            if (previous != null) ((!) previous).stop();

            EngineContext? playback_context = null;
            try {
                playback_context = ((!) context_supplier)();
                select_saved_speaker((!) playback_context);
                EngineContextActivityLease lease = ((!) playback_context).acquire_activity("media-message-playback");
                var session = new GoogleWebrtcMediaMessagePlaybackSession(
                    (!) playback_context,
                    (owned) lease,
                    on_session_closed,
                    (message) => { playback_failed(message); },
                    owns_context);
                session_mutex.lock();
                current_session = session;
                session_mutex.unlock();
                return session;
            } catch (Error e) {
                if (owns_context && playback_context != null) ((!) playback_context).close();
                playback_failed(e.message);
                throw e;
            }
        } finally {
            creation_mutex.unlock();
        }
    }

    public void stop_current_session() {
        creation_mutex.lock();
        try {
            GoogleWebrtcMediaMessagePlaybackSession? current = null;
            session_mutex.lock();
            current = current_session;
            current_session = null;
            session_mutex.unlock();
            if (current != null) ((!) current).stop();
        } finally {
            creation_mutex.unlock();
        }
    }

    private void select_saved_speaker(EngineContext context) throws EngineError {
        if (preferred_audio_output_name_supplier == null) return;
        string saved_value = ((!) preferred_audio_output_name_supplier)();
        // Production suppliers create a fresh context per playback session.
        // Leaving it unselected actually restores the platform default rather
        // than retaining the explicit speaker from the previous session.
        if (saved_value == "") return;

        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        foreach (EngineAudioDeviceInfo speaker in context.get_audio_devices(true)) {
            devices.add(new EngineMediaDevice(speaker));
        }
        EngineMediaDevice? selected = Dino.Plugins.MediaDeviceSelection.find(devices, saved_value) as EngineMediaDevice;
        if (selected != null) {
            context.set_audio_device(((!) selected).info);
            return;
        }
        debug(
            "Google/libwebrtc media playback: saved speaker '%s' is unavailable; using platform default",
            saved_value);
    }

    private void on_session_closed(GoogleWebrtcMediaMessagePlaybackSession session) {
        session_mutex.lock();
        if (current_session == session) current_session = null;
        session_mutex.unlock();
    }
}

private delegate void MediaMessagePlaybackSessionClosed(
    GoogleWebrtcMediaMessagePlaybackSession session);
private delegate void MediaMessagePlaybackFailure(string message);

public class GoogleWebrtcMediaMessagePlaybackSession : Dino.Plugins.MediaMessagePlaybackSession {
    private EngineContext context;
    private bool owns_context;
    private EngineContextActivityLease? lease;
    private MediaMessagePlaybackSessionClosed? closed_callback;
    private MediaMessagePlaybackFailure? failure_callback;
    private Mutex operation_mutex = Mutex();
    private Mutex state_mutex = Mutex();
    private bool started = false;
    private bool finished = false;
    private bool stopped = false;
    private bool failure_reported = false;

    public override bool active {
        get {
            state_mutex.lock();
            bool value = started && !stopped;
            state_mutex.unlock();
            return value;
        }
    }

    internal GoogleWebrtcMediaMessagePlaybackSession(
            EngineContext context,
            owned EngineContextActivityLease lease,
            owned MediaMessagePlaybackSessionClosed closed_callback,
            owned MediaMessagePlaybackFailure failure_callback,
            bool owns_context = false) {
        this.context = context;
        this.lease = (owned) lease;
        this.closed_callback = (owned) closed_callback;
        this.failure_callback = (owned) failure_callback;
        this.owns_context = owns_context;
    }

    public override void start(
            int sample_rate,
            int channels,
            int bytes_per_sample) throws Error {
        operation_mutex.lock();
        state_mutex.lock();
        if (stopped || started) {
            state_mutex.unlock();
            operation_mutex.unlock();
            throw new EngineError.PROTOCOL("Google/libwebrtc media playback session is not idle");
        }
        started = true;
        finished = false;
        state_mutex.unlock();
        try {
            context.start_media_audio_playout(sample_rate, channels, bytes_per_sample);
        } catch (Error e) {
            state_mutex.lock();
            started = false;
            state_mutex.unlock();
            operation_mutex.unlock();
            report_failure(e.message, true);
            stop();
            throw e;
        }
        operation_mutex.unlock();
    }

    public override uint push_pcm(Bytes pcm_data) throws Error {
        string? native_failure = null;
        operation_mutex.lock();
        try {
            ensure_accepting();
            try {
                return context.push_media_audio_playout(pcm_data);
            } catch (Error e) {
                native_failure = e.message;
                throw e;
            }
        } finally {
            operation_mutex.unlock();
            if (native_failure != null) {
                report_failure((!) native_failure, true);
                stop();
            }
        }
    }

    public override void set_paused(bool paused) throws Error {
        string? native_failure = null;
        operation_mutex.lock();
        try {
            ensure_active();
            try {
                context.set_media_audio_playout_paused(paused);
            } catch (Error e) {
                native_failure = e.message;
                throw e;
            }
        } finally {
            operation_mutex.unlock();
            if (native_failure != null) {
                report_failure((!) native_failure, true);
                stop();
            }
        }
    }

    public override void flush() throws Error {
        string? native_failure = null;
        operation_mutex.lock();
        try {
            ensure_accepting();
            try {
                context.flush_media_audio_playout();
            } catch (Error e) {
                native_failure = e.message;
                throw e;
            }
        } finally {
            operation_mutex.unlock();
            if (native_failure != null) {
                report_failure((!) native_failure, true);
                stop();
            }
        }
    }

    public override uint finish() throws Error {
        string? native_failure = null;
        operation_mutex.lock();
        try {
            ensure_accepting();
            uint queued_duration_ms;
            try {
                queued_duration_ms = context.finish_media_audio_playout();
            } catch (Error e) {
                native_failure = e.message;
                throw e;
            }
            state_mutex.lock();
            finished = true;
            state_mutex.unlock();
            return queued_duration_ms;
        } finally {
            operation_mutex.unlock();
            if (native_failure != null) {
                report_failure((!) native_failure, true);
                stop();
            }
        }
    }

    public override void stop() {
        EngineContextActivityLease? lease_to_release = null;
        MediaMessagePlaybackSessionClosed? callback = null;
        bool should_stop_native = false;
        operation_mutex.lock();
        state_mutex.lock();
        if (!stopped) {
            stopped = true;
            should_stop_native = started;
            started = false;
            finished = false;
            lease_to_release = lease;
            lease = null;
            callback = (owned) closed_callback;
            closed_callback = null;
        }
        state_mutex.unlock();
        if (should_stop_native) {
            try {
                context.stop_media_audio_playout();
            } catch (Error e) {
                debug("Google/libwebrtc media playback stop failed: %s", e.message);
                report_failure(e.message, false);
            }
        }
        state_mutex.lock();
        failure_callback = null;
        state_mutex.unlock();
        operation_mutex.unlock();
        if (lease_to_release != null) ((!) lease_to_release).release();
        if (lease_to_release != null && owns_context) context.close();
        if (callback != null) ((!) callback)(this);
    }

    private void ensure_active() throws EngineError {
        state_mutex.lock();
        bool value = started && !stopped;
        state_mutex.unlock();
        if (!value) {
            throw new EngineError.CLOSED("Google/libwebrtc media playback session is closed");
        }
    }

    private void ensure_accepting() throws EngineError {
        state_mutex.lock();
        bool value = started && !finished && !stopped;
        state_mutex.unlock();
        if (!value) {
            throw new EngineError.CLOSED("Google/libwebrtc media playback session is not accepting PCM");
        }
    }

    private void report_failure(string message, bool emit_session_signal) {
        bool first_failure = false;
        MediaMessagePlaybackFailure? callback = null;
        state_mutex.lock();
        if (!failure_reported) {
            failure_reported = true;
            first_failure = true;
            callback = (owned) failure_callback;
            failure_callback = null;
        }
        state_mutex.unlock();
        if (!first_failure) return;
        if (emit_session_signal) playback_error(message);
        if (callback != null) ((!) callback)(message);
    }

    ~GoogleWebrtcMediaMessagePlaybackSession() {
        stop();
    }
}

}
