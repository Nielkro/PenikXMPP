namespace Dino.Plugins.GoogleWebrtc {

public delegate EngineContext EngineContextSupplier() throws EngineError;
public delegate string PreferredMediaDeviceNameSupplier();

public class GoogleWebrtcMediaMessageRecorderProvider : Object, Dino.Plugins.MediaMessageRecorderProvider {
    private EngineContextSupplier? context_supplier;
    private PreferredMediaDeviceNameSupplier? preferred_audio_input_name_supplier;
    private PreferredMediaDeviceNameSupplier? preferred_video_input_name_supplier;
    private EngineContext? context;
    private bool audio_writer_probe_done = false;
    private bool cached_audio_available = false;
    private string? cached_audio_unavailable_reason = null;
    private bool video_writer_probe_done = false;
    private bool cached_video_available = false;
    private string? cached_video_unavailable_reason = null;

    public string id {
        get { return "google-libwebrtc"; }
    }

    public bool audio_available {
        get {
            ensure_audio_writer_probe();
            return cached_audio_available;
        }
    }

    public string? audio_unavailable_reason {
        owned get {
            ensure_audio_writer_probe();
            return cached_audio_unavailable_reason;
        }
    }

    public bool video_available {
        get {
            ensure_video_writer_probe();
            return cached_video_available;
        }
    }

    public string? video_unavailable_reason {
        owned get {
            ensure_video_writer_probe();
            return cached_video_unavailable_reason;
        }
    }

    public GoogleWebrtcMediaMessageRecorderProvider(
            owned EngineContextSupplier context_supplier,
            owned PreferredMediaDeviceNameSupplier? preferred_audio_input_name_supplier = null,
            owned PreferredMediaDeviceNameSupplier? preferred_video_input_name_supplier = null) {
        this.context_supplier = (owned) context_supplier;
        this.preferred_audio_input_name_supplier = (owned) preferred_audio_input_name_supplier;
        this.preferred_video_input_name_supplier = (owned) preferred_video_input_name_supplier;
    }

    public GoogleWebrtcMediaMessageRecorderProvider.for_context(EngineContext context) {
        this.context = context;
    }

    public Gee.List<Dino.Plugins.MediaDevice> get_audio_input_devices() {
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        try {
            foreach (EngineAudioDeviceInfo info in get_context().get_audio_devices(false)) {
                devices.add(new EngineMediaDevice(info));
            }
        } catch (Error e) {
            warning("Google/libwebrtc media recorder: cannot enumerate microphone devices: %s", e.message);
        }
        devices.sort((left, right) => strcmp(left.id, right.id));
        return devices;
    }

    public Gee.List<Dino.Plugins.MediaDevice> get_video_input_devices() {
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        try {
            foreach (EngineVideoDeviceInfo info in get_context().get_video_devices()) {
                devices.add(new EngineVideoMediaDevice(info));
            }
        } catch (Error e) {
            warning("Google/libwebrtc media recorder: cannot enumerate camera devices: %s", e.message);
        }
        devices.sort((left, right) => strcmp(left.id, right.id));
        return devices;
    }

    public Dino.Plugins.AudioMessageRecorderSession create_audio_message_recorder(string output_path) throws Error {
        return create_audio_message_recorder_for_device(output_path, null);
    }

    public Dino.Plugins.AudioMessageRecorderSession create_audio_message_recorder_for_device(
            string output_path,
            Dino.Plugins.MediaDevice? device) throws Error {
        AudioMessageWriter writer = AudioMessageWriterFactory.create_default_aac_m4a_writer();
        if (!writer.available) {
            throw new Dino.Plugins.MediaMessageRecorderError.ENCODER_UNAVAILABLE(
                writer.unavailable_reason ?? "AAC/M4A recording backend is not available");
        }

        EngineContext? dedicated_context = null;
        try {
            EngineContext recorder_context = get_recording_context(out dedicated_context);
            if (device != null) {
                select_audio_input_device(recorder_context, (!) device);
            } else {
                select_preferred_audio_input_device(recorder_context);
            }
            AudioMessageRecorderV2 recorder = recorder_context.create_audio_message_recorder(output_path, writer);
            return new GoogleWebrtcAudioMessageRecorderSession(recorder, dedicated_context);
        } catch (Error e) {
            close_failed_recording_context(dedicated_context);
            throw e;
        }
    }

    public Dino.Plugins.AudioMessageRecorderSession create_audio_test_for_device(
            string output_path,
            Dino.Plugins.MediaDevice? device) throws Error {
        EngineContext? dedicated_context = null;
        try {
            EngineContext recorder_context = get_recording_context(out dedicated_context);
            if (device != null) {
                select_audio_input_device(recorder_context, (!) device);
            } else {
                select_preferred_audio_input_device(recorder_context);
            }
            // Device testing consumes raw PCM through the session signal. It must
            // not depend on AAC encoding, a container writer or GStreamer playback.
            AudioMessageRecorderV2 recorder = recorder_context.create_audio_message_recorder(output_path, null);
            return new GoogleWebrtcAudioMessageRecorderSession(recorder, dedicated_context);
        } catch (Error e) {
            close_failed_recording_context(dedicated_context);
            throw e;
        }
    }

    public Dino.Plugins.VideoMessageRecorderSession create_video_message_recorder(string output_path) throws Error {
        return create_video_message_recorder_for_device(output_path, null);
    }

    public Dino.Plugins.VideoMessageRecorderSession create_video_message_recorder_for_device(
            string output_path,
            Dino.Plugins.MediaDevice? device) throws Error {
        VideoMessageWriter writer = VideoMessageWriterFactory.create_default_mp4_h264_writer();
        if (!writer.available) {
            throw new Dino.Plugins.MediaMessageRecorderError.ENCODER_UNAVAILABLE(
                writer.unavailable_reason ?? "MP4/H.264 recording backend is not available");
        }

        EngineContext? dedicated_context = null;
        try {
            EngineContext recorder_context = get_recording_context(out dedicated_context);
            select_preferred_audio_input_device(recorder_context);
            Gee.List<EngineVideoDeviceInfo> cameras = recorder_context.get_video_devices();
            if (cameras.is_empty) {
                throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE("No video camera was found");
            }
            EngineVideoDeviceInfo camera = select_video_input_device(cameras, device);

            VideoMessageRecorderV2 recorder = recorder_context.create_video_message_recorder(
                output_path,
                writer,
                camera,
                VideoMessageRecorderV2.DEFAULT_WIDTH,
                VideoMessageRecorderV2.DEFAULT_HEIGHT,
                VideoMessageRecorderV2.DEFAULT_MAX_FPS,
                true);
            return new GoogleWebrtcVideoMessageRecorderSession(recorder, dedicated_context);
        } catch (Error e) {
            close_failed_recording_context(dedicated_context);
            throw e;
        }
    }

    public Dino.Plugins.VideoMessageRecorderSession create_video_preview_for_device(
            string output_path,
            Dino.Plugins.MediaDevice? device) throws Error {
        EngineContext? dedicated_context = null;
        try {
            EngineContext recorder_context = get_recording_context(out dedicated_context);
            Gee.List<EngineVideoDeviceInfo> cameras = recorder_context.get_video_devices();
            if (cameras.is_empty) {
                throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE("No video camera was found");
            }
            EngineVideoDeviceInfo camera = select_video_input_device(cameras, device);

            // Device testing only needs libwebrtc camera capture and preview
            // frames. Do not make it depend on the message encoder, MP4 writer or
            // microphone capture.
            VideoMessageRecorderV2 recorder = recorder_context.create_video_message_recorder(
                output_path,
                null,
                camera,
                VideoMessageRecorderV2.DEFAULT_WIDTH,
                VideoMessageRecorderV2.DEFAULT_HEIGHT,
                VideoMessageRecorderV2.DEFAULT_MAX_FPS,
                false);
            return new GoogleWebrtcVideoMessageRecorderSession(recorder, dedicated_context);
        } catch (Error e) {
            close_failed_recording_context(dedicated_context);
            throw e;
        }
    }

    private EngineContext get_context() throws EngineError {
        if (context != null) return (!) context;
        if (context_supplier == null) {
            throw new EngineError.CLOSED("Google/libwebrtc media recorder provider has no context owner");
        }
        return ((!) context_supplier)();
    }

    private EngineContext get_recording_context(out EngineContext? dedicated_context) throws EngineError {
        dedicated_context = null;
        // Keep capture and device tests independent of calls and playback. A
        // fresh context also makes an explicit system-default selection reset
        // an earlier device choice. On Windows this preserves the workaround
        // for missing WASAPI callbacks on a second StartRecording().
        if (context == null && context_supplier != null) {
            dedicated_context = new EngineContext(EngineAudioDeviceMode.PLATFORM_DEFAULT);
            return (!) dedicated_context;
        }
        return get_context();
    }

    private void close_failed_recording_context(EngineContext? dedicated_context) {
        if (dedicated_context != null) {
            ((!) dedicated_context).close();
        }
    }

    private void select_audio_input_device(EngineContext context, Dino.Plugins.MediaDevice device) throws Error {
        if (device is Dino.Plugins.SystemDefaultMediaDevice) {
            if (device.media != "audio" || device.incoming) {
                throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE(
                    "Selected default device is not a microphone");
            }
            // Production capture contexts are fresh and have no explicit
            // microphone selected. Do not apply message preferences here.
            return;
        }
        context.set_audio_device(resolve_audio_input_device(context.get_audio_devices(false), device));
    }

    internal static EngineAudioDeviceInfo resolve_audio_input_device(
            Gee.List<EngineAudioDeviceInfo> microphones,
            Dino.Plugins.MediaDevice device) throws Error {
        EngineMediaDevice? engine_device = device as EngineMediaDevice?;
        if (engine_device == null || ((!) engine_device).info.incoming) {
            throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE(
                "Selected microphone is not a Google/libwebrtc input device");
        }
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        foreach (EngineAudioDeviceInfo microphone in microphones) {
            devices.add(new EngineMediaDevice(microphone));
        }
        EngineMediaDevice? selected = Dino.Plugins.MediaDeviceSelection.find_selected(devices, device) as EngineMediaDevice;
        if (selected != null) {
            return ((!) selected).info;
        }
        throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE(
            "Selected microphone is no longer available to Google/libwebrtc");
    }

    private void select_preferred_audio_input_device(EngineContext context) throws EngineError {
        if (preferred_audio_input_name_supplier == null) return;
        string preferred_name = ((!) preferred_audio_input_name_supplier)();
        if (preferred_name == "") return;

        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        foreach (EngineAudioDeviceInfo microphone in context.get_audio_devices(false)) {
            devices.add(new EngineMediaDevice(microphone));
        }
        EngineMediaDevice? selected = Dino.Plugins.MediaDeviceSelection.find(devices, preferred_name) as EngineMediaDevice;
        if (selected != null) {
            context.set_audio_device(((!) selected).info);
        }
    }

    private EngineVideoDeviceInfo select_video_input_device(
            Gee.List<EngineVideoDeviceInfo> cameras,
            Dino.Plugins.MediaDevice? device) throws Error {
        if (device == null) return select_preferred_video_input_device(cameras);
        return resolve_video_input_device(cameras, (!) device);
    }

    internal static EngineVideoDeviceInfo resolve_video_input_device(
            Gee.List<EngineVideoDeviceInfo> cameras,
            Dino.Plugins.MediaDevice device) throws Error {
        if (cameras.is_empty) {
            throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE("No video camera was found");
        }
        if (device is Dino.Plugins.SystemDefaultMediaDevice) {
            if (device.media != "video" || device.incoming) {
                throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE(
                    "Selected default device is not a camera");
            }
            return cameras[0];
        }
        var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
        foreach (EngineVideoDeviceInfo camera in cameras) {
            devices.add(new EngineVideoMediaDevice(camera));
        }
        EngineVideoMediaDevice? selected = Dino.Plugins.MediaDeviceSelection.find_selected(devices, device) as EngineVideoMediaDevice;
        if (selected != null) {
            // Always return this context's enumeration entry. The selected
            // device may have come from another context or an older catalog.
            return ((!) selected).info;
        }

        throw new Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE(
            "Selected camera is not available to Google/libwebrtc");
    }

    private EngineVideoDeviceInfo select_preferred_video_input_device(Gee.List<EngineVideoDeviceInfo> cameras) {
        if (preferred_video_input_name_supplier != null) {
            string preferred_name = ((!) preferred_video_input_name_supplier)();
            if (preferred_name != "") {
                var devices = new Gee.ArrayList<Dino.Plugins.MediaDevice>();
                foreach (EngineVideoDeviceInfo camera in cameras) {
                    devices.add(new EngineVideoMediaDevice(camera));
                }
                EngineVideoMediaDevice? selected = Dino.Plugins.MediaDeviceSelection.find(devices, preferred_name) as EngineVideoMediaDevice;
                if (selected != null) {
                    return ((!) selected).info;
                }
            }
        }
        return cameras[0];
    }

    private void ensure_audio_writer_probe() {
        if (audio_writer_probe_done) return;
        AudioMessageWriter writer = AudioMessageWriterFactory.create_default_aac_m4a_writer();
        cached_audio_available = writer.available;
        cached_audio_unavailable_reason = writer.available ? null : writer.unavailable_reason;
        audio_writer_probe_done = true;
    }

    private void ensure_video_writer_probe() {
        if (video_writer_probe_done) return;
#if WINDOWS
        // Windows records through Media Foundation. Do not gate that backend
        // on a system ffmpeg executable which is neither used nor packaged.
        VideoMessageWriter writer = VideoMessageWriterFactory.create_default_mp4_h264_writer();
        cached_video_available = writer.available;
        cached_video_unavailable_reason = writer.available ? null : writer.unavailable_reason;
#else
        if (Environment.find_program_in_path("ffmpeg") == null) {
            cached_video_available = false;
            cached_video_unavailable_reason = "System ffmpeg was not found";
        } else {
            // The full H.264 encoder/MP4 muxer probe is intentionally deferred
            // to recorder start. That start runs off the GTK thread, while this
            // property is used by the account/chat UI before opening the popover.
            cached_video_available = true;
            cached_video_unavailable_reason = null;
        }
#endif
        video_writer_probe_done = true;
    }
}

internal class GoogleWebrtcAudioMessageRecorderSession : Dino.Plugins.AudioMessageRecorderSession {
    private AudioMessageRecorderV2 recorder;
    private EngineContext? dedicated_context;
    private bool finished = false;

    public override Dino.Plugins.MediaMessageRecorderState state {
        get {
            switch (recorder.state) {
                case Native.MediaRecorderState.IDLE:
                    return Dino.Plugins.MediaMessageRecorderState.IDLE;
                case Native.MediaRecorderState.STARTING:
                    return Dino.Plugins.MediaMessageRecorderState.STARTING;
                case Native.MediaRecorderState.RECORDING:
                    return Dino.Plugins.MediaMessageRecorderState.RECORDING;
                case Native.MediaRecorderState.FINALIZING:
                    return Dino.Plugins.MediaMessageRecorderState.FINALIZING;
                case Native.MediaRecorderState.FAILED:
                    return Dino.Plugins.MediaMessageRecorderState.FAILED;
                default:
                    return Dino.Plugins.MediaMessageRecorderState.FAILED;
            }
        }
    }

    public override string? current_output_path {
        owned get { return recorder.output_path; }
    }

    public GoogleWebrtcAudioMessageRecorderSession(
            AudioMessageRecorderV2 recorder,
            EngineContext? dedicated_context = null) {
        this.recorder = recorder;
        this.dedicated_context = dedicated_context;
        recorder.started.connect(() => {
            started();
        });
        recorder.duration_changed.connect((seconds) => {
            duration_changed(seconds);
        });
        recorder.level_changed.connect((peak) => {
            level_changed(peak);
        });
        recorder.frame_received.connect((pcm_data, frame_id) => {
            pcm_frame(
                pcm_data,
                this.recorder.sample_rate,
                this.recorder.channels,
                this.recorder.bytes_per_sample);
        });
        recorder.recording_error.connect((message) => {
            recording_error(message);
        });
    }

    public override void start() throws Error {
        if (finished) {
            throw new Dino.Plugins.MediaMessageRecorderError.INVALID_STATE("audio recorder session is already finished");
        }
        recorder.start();
    }

    public override void stop() throws Error {
        if (finished) {
            throw new Dino.Plugins.MediaMessageRecorderError.INVALID_STATE("audio recorder session is already finished");
        }
        // Keep the recorder alive across the synchronous signal. Its consumer
        // may drop the last reference to this session before signal emission
        // returns, which also clears this.recorder during finalization.
        AudioMessageRecorderV2 completed_recorder = recorder;
        completed_recorder.stop(true);
        bool dedicated_context_closed = close_dedicated_context(completed_recorder);
        finished = true;
        recording_stopped(new Dino.Plugins.MediaMessageRecorderOutput(
            Dino.Plugins.MediaMessageKind.AUDIO,
            completed_recorder.output_path,
            AudioMessageRecorderV2.MIME_TYPE,
            Path.get_basename(completed_recorder.output_path)));
        // Keep the shared worker alive through synchronous consumers of
        // recording_stopped (notably the settings microphone playback).
        if (!dedicated_context_closed) {
            completed_recorder.release_completed_activity();
        }
    }

    public override void cancel() {
        if (finished) return;
        try {
            recorder.cancel();
        } catch (Error e) {
            recording_error(e.message);
        }
        close_dedicated_context(null);
        finished = true;
    }

    private bool close_dedicated_context(AudioMessageRecorderV2? completed_recorder) {
        if (dedicated_context == null) return false;
        if (completed_recorder != null) {
            ((!) completed_recorder).release_completed_activity();
        }
        EngineContext context_to_close = (!) dedicated_context;
        dedicated_context = null;
        context_to_close.close();
        return true;
    }
}

internal class GoogleWebrtcVideoMessageRecorderSession : Dino.Plugins.VideoMessageRecorderSession {
    private VideoMessageRecorderV2 recorder;
    private EngineContext? dedicated_context;
    private bool finished = false;

    public override Dino.Plugins.MediaMessageRecorderState state {
        get {
            switch (recorder.state) {
                case Native.MediaRecorderState.IDLE:
                    return Dino.Plugins.MediaMessageRecorderState.IDLE;
                case Native.MediaRecorderState.STARTING:
                    return Dino.Plugins.MediaMessageRecorderState.STARTING;
                case Native.MediaRecorderState.RECORDING:
                    return Dino.Plugins.MediaMessageRecorderState.RECORDING;
                case Native.MediaRecorderState.FINALIZING:
                    return Dino.Plugins.MediaMessageRecorderState.FINALIZING;
                case Native.MediaRecorderState.FAILED:
                    return Dino.Plugins.MediaMessageRecorderState.FAILED;
                default:
                    return Dino.Plugins.MediaMessageRecorderState.FAILED;
            }
        }
    }

    public override string? current_output_path {
        owned get { return recorder.output_path; }
    }

    public GoogleWebrtcVideoMessageRecorderSession(
            VideoMessageRecorderV2 recorder,
            EngineContext? dedicated_context = null) {
        this.recorder = recorder;
        this.dedicated_context = dedicated_context;
        recorder.started.connect(() => {
            started();
        });
        recorder.duration_changed.connect((seconds) => {
            duration_changed(seconds);
        });
        recorder.preview_frame_changed.connect((bgra_data, width, height, stride) => {
            preview_frame_changed(new Dino.Plugins.VideoMessagePreviewFrame(
                bgra_data,
                width,
                height,
                stride,
                this.recorder.last_frame_id));
        });
        recorder.recording_error.connect((message) => {
            recording_error(message);
        });
    }

    public override void start() throws Error {
        if (finished) {
            throw new Dino.Plugins.MediaMessageRecorderError.INVALID_STATE("video recorder session is already finished");
        }
        recorder.start();
    }

    public override void stop() throws Error {
        if (finished) {
            throw new Dino.Plugins.MediaMessageRecorderError.INVALID_STATE("video recorder session is already finished");
        }
        VideoMessageRecorderV2 completed_recorder = recorder;
        completed_recorder.stop(true);
        bool dedicated_context_closed = close_dedicated_context(completed_recorder);
        finished = true;
        recording_stopped(new Dino.Plugins.MediaMessageRecorderOutput(
            Dino.Plugins.MediaMessageKind.VIDEO,
            completed_recorder.output_path,
            VideoMessageRecorderV2.MIME_TYPE,
            Path.get_basename(completed_recorder.output_path)));
        if (!dedicated_context_closed) {
            completed_recorder.release_completed_activity();
        }
    }

    public override void cancel() {
        if (finished) return;
        try {
            recorder.cancel();
        } catch (Error e) {
            recording_error(e.message);
        }
        close_dedicated_context(null);
        finished = true;
    }

    private bool close_dedicated_context(VideoMessageRecorderV2? completed_recorder) {
        if (dedicated_context == null) return false;
        if (completed_recorder != null) {
            ((!) completed_recorder).release_completed_activity();
        }
        EngineContext context_to_close = (!) dedicated_context;
        dedicated_context = null;
        context_to_close.close();
        return true;
    }
}

}
