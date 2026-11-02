/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui.ChatInput {

public errordomain MediaMessageRecorderError {
    INVALID_STATE,
    DEVICE_UNAVAILABLE,
    CAPTURE_FAILED,
    ENCODER_UNAVAILABLE,
    MUXER_UNAVAILABLE,
    FINALIZE_FAILED,
    CANCELLED,
    UNSUPPORTED,
    INTERNAL
}

public enum MediaMessageKind {
    AUDIO,
    VIDEO
}

public enum MediaMessageCompatibility {
    PRIMARY,
    EXPLICIT_ALTERNATIVE
}

public enum MediaMessageRecorderState {
    IDLE,
    STARTING,
    RECORDING,
    FINALIZING,
    FAILED;

    public bool is_busy() {
        return this == STARTING || this == RECORDING || this == FINALIZING;
    }
}

public class MediaMessageRecorderOutput : Object {
    public MediaMessageKind kind { get; private set; }
    public string path { get; private set; }
    public string mime_type { get; private set; }
    public string suggested_filename { get; private set; }
    public MediaMessageCompatibility compatibility { get; private set; }

    public MediaMessageRecorderOutput(
        MediaMessageKind kind,
        string path,
        string mime_type,
        string suggested_filename,
        MediaMessageCompatibility compatibility = MediaMessageCompatibility.PRIMARY) {
        this.kind = kind;
        this.path = path;
        this.mime_type = mime_type;
        this.suggested_filename = suggested_filename;
        this.compatibility = compatibility;
    }
}

public interface MediaMessageRecorderBackend : Object {
    public abstract MediaMessageKind kind { get; }
    public abstract MediaMessageRecorderState state { get; }
    public abstract string? current_output_path { get; }

    public signal void duration_changed(string text);
    public signal void max_duration_reached();
    public signal void recording_error(string message);
    public signal void recording_stopped(MediaMessageRecorderOutput? output);

    public abstract void start_recording(string output_path) throws Error;
    public abstract void stop_recording();
    public abstract void cancel_recording();
}

public interface AudioMessageRecorderBackend : MediaMessageRecorderBackend {
    public signal void level_changed(double peak);
    public signal void pcm_frame(Bytes pcm_data, int sample_rate, int channels, int bytes_per_sample);
}

public interface VideoMessageRecorderBackend : MediaMessageRecorderBackend {
    public abstract Gdk.Texture? get_preview_texture();
}

// Own signal IDs independently of the recorder. Startup can transfer a session
// from a worker to the main context while cancellation races that handoff.
private class RecorderSessionSignals : Object {
    private Object source;
    private ulong[] handlers = {};
    private Mutex mutex = Mutex();

    public RecorderSessionSignals(Object source) { this.source = source; }
    public void add(ulong handler) {
        mutex.lock();
        handlers += handler;
        mutex.unlock();
    }
    public void disconnect_all() {
        mutex.lock();
        ulong[] to_disconnect = (owned) handlers;
        handlers = {};
        mutex.unlock();
        foreach (ulong handler in to_disconnect) source.disconnect(handler);
    }
    public override void dispose() {
        disconnect_all();
        base.dispose();
    }
}

public class ProviderAudioMessageRecorderBackend : Object, MediaMessageRecorderBackend, AudioMessageRecorderBackend {
    public const int MAX_DURATION_SECONDS = 300;

    private Dino.Plugins.MediaMessageRecorderProvider provider;
    private Dino.Plugins.MediaDevice? explicit_device;
    private bool test_only;
    private Dino.Plugins.AudioMessageRecorderSession? session = null;
    private RecorderSessionSignals? session_signals = null;
    private MediaMessageRecorderState current_state = MediaMessageRecorderState.IDLE;
    private string? output_path = null;
    private bool output_completed = false;
    private bool max_duration_emitted = false;

    public MediaMessageKind kind {
        get { return MediaMessageKind.AUDIO; }
    }

    public MediaMessageRecorderState state {
        get { return current_state; }
    }

    public string? current_output_path {
        get { return output_path; }
    }

    public ProviderAudioMessageRecorderBackend(
            Dino.Plugins.MediaMessageRecorderProvider provider,
            Dino.Plugins.MediaDevice? explicit_device = null,
            bool test_only = false) {
        this.provider = provider;
        this.explicit_device = explicit_device;
        this.test_only = test_only;
    }

    public void start_recording(string output_path) throws Error {
        if (current_state.is_busy()) {
            throw new MediaMessageRecorderError.INVALID_STATE("audio recorder is already active");
        }
        if (!test_only && !provider.audio_available) {
            throw new MediaMessageRecorderError.ENCODER_UNAVAILABLE(
                provider.audio_unavailable_reason ?? "Audio recording backend is not available");
        }

        this.output_path = output_path;
        output_completed = false;
        max_duration_emitted = false;
        current_state = MediaMessageRecorderState.STARTING;
        try {
            Dino.Plugins.AudioMessageRecorderSession created_session = test_only ?
                provider.create_audio_test_for_device(output_path, explicit_device) :
                provider.create_audio_message_recorder_for_device(output_path, explicit_device);
            session = created_session;
            var signals = new RecorderSessionSignals(created_session);
            session_signals = signals;
            signals.add(created_session.duration_changed.connect(on_duration_changed));
            signals.add(created_session.level_changed.connect((peak) => {
                level_changed(peak);
            }));
            signals.add(created_session.pcm_frame.connect((pcm_data, sample_rate, channels, bytes_per_sample) => {
                pcm_frame(pcm_data, sample_rate, channels, bytes_per_sample);
            }));
            signals.add(created_session.recording_error.connect((message) => {
                fail_recording(message);
            }));
            signals.add(created_session.recording_stopped.connect((plugin_output) => {
                detach_session();
                current_state = MediaMessageRecorderState.IDLE;
                // The chat reads this path after stop_recording() returns. The
                // completed file belongs to its consumer, including async upload.
                this.output_path = plugin_output.path;
                output_completed = true;
                recording_stopped(new MediaMessageRecorderOutput(
                    MediaMessageKind.AUDIO,
                    plugin_output.path,
                    plugin_output.mime_type,
                    plugin_output.suggested_filename,
                    MediaMessageCompatibility.PRIMARY));
            }));

            created_session.start();
            if (session == created_session) current_state = MediaMessageRecorderState.RECORDING;
        } catch (Error e) {
            var failed_session = detach_session();
            if (failed_session != null) {
                failed_session.cancel();
                if (!output_completed) FileUtils.unlink(output_path);
            }
            current_state = MediaMessageRecorderState.FAILED;
            this.output_path = null;
            output_completed = false;
            throw e;
        }
    }

    public void stop_recording() {
        if (session == null || current_state == MediaMessageRecorderState.IDLE) return;
        var stopping_session = (!) session;
        current_state = MediaMessageRecorderState.FINALIZING;
        try {
            stopping_session.stop();
            detach_session();
            current_state = MediaMessageRecorderState.IDLE;
        } catch (Error e) {
            fail_recording(e.message);
        }
    }

    private Dino.Plugins.AudioMessageRecorderSession? detach_session() {
        var detached = session;
        session = null;
        var signals = session_signals;
        session_signals = null;
        if (signals != null) signals.disconnect_all();
        return detached;
    }

    public void cancel_recording() {
        var session_to_cancel = detach_session();
        if (session_to_cancel != null) session_to_cancel.cancel();
        if (output_path != null) {
            if (!output_completed) FileUtils.unlink((!) output_path);
            output_path = null;
        }
        output_completed = false;
        current_state = MediaMessageRecorderState.IDLE;
    }

    public override void dispose() {
        cancel_recording();
        base.dispose();
    }

    private void on_duration_changed(double seconds_double) {
        int seconds = (int) seconds_double;
        int mins = seconds / 60;
        int secs = seconds % 60;
        if (seconds >= MAX_DURATION_SECONDS) {
            duration_changed("%d:%02d".printf(mins, secs));
            if (!max_duration_emitted) {
                max_duration_emitted = true;
                max_duration_reached();
            }
            return;
        }

        if (seconds >= MAX_DURATION_SECONDS - 30) {
            int remaining = MAX_DURATION_SECONDS - seconds;
            duration_changed("%d:%02d (-%ds)".printf(mins, secs, remaining));
        } else {
            duration_changed("%d:%02d".printf(mins, secs));
        }
    }

    private void fail_recording(string message) {
        var session_to_cancel = detach_session();
        if (session_to_cancel != null) {
            ((!) session_to_cancel).cancel();
        }
        if (output_path != null) {
            FileUtils.unlink((!) output_path);
            output_path = null;
        }
        output_completed = false;
        current_state = MediaMessageRecorderState.FAILED;
        recording_error(message);
    }
}

public class ProviderVideoMessageRecorderBackend : Object, MediaMessageRecorderBackend, VideoMessageRecorderBackend {
    public const int MAX_DURATION_SECONDS = 120;

    private Dino.Plugins.MediaMessageRecorderProvider provider;
    private Dino.Plugins.MediaDevice? explicit_device;
    private bool preview_only;
    private Dino.Plugins.VideoMessageRecorderSession? session = null;
    private RecorderSessionSignals? session_signals = null;
    private MediaMessageRecorderState current_state = MediaMessageRecorderState.IDLE;
    private string? output_path = null;
    private Gdk.Texture? latest_preview_texture = null;
    private bool max_duration_emitted = false;
    private Mutex start_mutex = Mutex();
    private uint start_generation = 0;

    public MediaMessageKind kind {
        get { return MediaMessageKind.VIDEO; }
    }

    public MediaMessageRecorderState state {
        get { return current_state; }
    }

    public string? current_output_path {
        get { return output_path; }
    }

    public ProviderVideoMessageRecorderBackend(
            Dino.Plugins.MediaMessageRecorderProvider provider,
            Dino.Plugins.MediaDevice? explicit_device = null,
            bool preview_only = false) {
        this.provider = provider;
        this.explicit_device = explicit_device;
        this.preview_only = preview_only;
    }

    public void start_recording(string output_path) throws Error {
        if (current_state.is_busy()) {
            throw new MediaMessageRecorderError.INVALID_STATE("video recorder is already active");
        }
        if (!preview_only && !provider.video_available) {
            throw new MediaMessageRecorderError.ENCODER_UNAVAILABLE(
                provider.video_unavailable_reason ?? "Video recording backend is not available");
        }

        this.output_path = output_path;
        latest_preview_texture = null;
        max_duration_emitted = false;
        current_state = MediaMessageRecorderState.STARTING;
        uint generation = next_start_generation();
        string requested_output_path = output_path;

        new Thread<void*>("dinox-video-recorder-start", () => {
            Dino.Plugins.VideoMessageRecorderSession? created_session = null;
            RecorderSessionSignals? pending_signals = null;
            try {
                Dino.Plugins.VideoMessageRecorderSession local_session = preview_only ?
                    provider.create_video_preview_for_device(requested_output_path, explicit_device) :
                    provider.create_video_message_recorder_for_device(requested_output_path, explicit_device);
                created_session = local_session;
                var local_signals = attach_video_session_handlers(this, local_session, generation);
                pending_signals = local_signals;
                AsyncQueue<VideoRecorderStartAttachResult> attach_queue =
                    new AsyncQueue<VideoRecorderStartAttachResult>();

                Idle.add(() => {
                    var attach_result = new VideoRecorderStartAttachResult();
                    if (!is_current_start_generation(generation) ||
                            current_state != MediaMessageRecorderState.STARTING) {
                        attach_queue.push(attach_result);
                        return Source.REMOVE;
                    }
                    session = local_session;
                    session_signals = local_signals;
                    attach_result.accepted = true;
                    attach_queue.push(attach_result);
                    return Source.REMOVE;
                });

                VideoRecorderStartAttachResult attach_result = attach_queue.pop();
                if (!attach_result.accepted || !is_current_start_generation(generation)) {
                    local_signals.disconnect_all();
                    local_session.cancel();
                    return null;
                }

                local_session.start();

                Idle.add(() => {
                    if (!is_current_start_generation(generation) ||
                            session != local_session ||
                            current_state != MediaMessageRecorderState.STARTING) {
                        local_signals.disconnect_all();
                        local_session.cancel();
                        return Source.REMOVE;
                    }
                    current_state = MediaMessageRecorderState.RECORDING;
                    return Source.REMOVE;
                });
            } catch (Error e) {
                string message = e.message;
                if (pending_signals != null) pending_signals.disconnect_all();
                if (created_session != null) {
                    ((!) created_session).cancel();
                }
                Idle.add(() => {
                    fail_start_recording(generation, message);
                    return Source.REMOVE;
                });
            }
            return null;
        });
    }

    public void stop_recording() {
        if (session == null || current_state == MediaMessageRecorderState.IDLE) return;
        var stopping_session = (!) session;
        current_state = MediaMessageRecorderState.FINALIZING;
        try {
            stopping_session.stop();
            detach_session();
            current_state = MediaMessageRecorderState.IDLE;
        } catch (Error e) {
            fail_recording(e.message);
        }
    }

    private Dino.Plugins.VideoMessageRecorderSession? detach_session() {
        var detached = session;
        session = null;
        var signals = session_signals;
        session_signals = null;
        if (signals != null) signals.disconnect_all();
        return detached;
    }

    public void cancel_recording() {
        invalidate_start_generation();
        var session_to_cancel = detach_session();
        if (session_to_cancel != null) session_to_cancel.cancel();
        if (output_path != null) {
            FileUtils.unlink((!) output_path);
            output_path = null;
        }
        latest_preview_texture = null;
        current_state = MediaMessageRecorderState.IDLE;
    }

    public override void dispose() {
        cancel_recording();
        base.dispose();
    }

    public Gdk.Texture? get_preview_texture() {
        return latest_preview_texture;
    }

    private void on_duration_changed(double seconds_double) {
        int seconds = (int) seconds_double;
        int mins = seconds / 60;
        int secs = seconds % 60;
        if (seconds >= MAX_DURATION_SECONDS) {
            duration_changed("%d:%02d".printf(mins, secs));
            if (!max_duration_emitted) {
                max_duration_emitted = true;
                max_duration_reached();
            }
            return;
        }

        if (seconds >= MAX_DURATION_SECONDS - 15) {
            int remaining = MAX_DURATION_SECONDS - seconds;
            duration_changed("%d:%02d (-%ds)".printf(mins, secs, remaining));
        } else {
            duration_changed("%d:%02d".printf(mins, secs));
        }
    }

    private void on_preview_frame_changed(Dino.Plugins.VideoMessagePreviewFrame frame) {
        if (frame.width <= 0 || frame.height <= 0 || frame.stride < frame.width * 4) {
            return;
        }
        latest_preview_texture = new Gdk.MemoryTexture(
            frame.width,
            frame.height,
            Gdk.MemoryFormat.B8G8R8A8,
            frame.bgra_data,
            frame.stride);
    }

    private static RecorderSessionSignals attach_video_session_handlers(
            ProviderVideoMessageRecorderBackend owner,
            Dino.Plugins.VideoMessageRecorderSession local_session, uint generation) {
        var signals = new RecorderSessionSignals(local_session);
        WeakRef weak_backend = WeakRef(owner);
        signals.add(local_session.duration_changed.connect((seconds) => {
            var backend = weak_backend.get() as ProviderVideoMessageRecorderBackend;
            if (backend == null || !backend.is_current_start_generation(generation)) return;
            backend.on_duration_changed(seconds);
        }));
        signals.add(local_session.preview_frame_changed.connect((frame) => {
            var backend = weak_backend.get() as ProviderVideoMessageRecorderBackend;
            if (backend == null || !backend.is_current_start_generation(generation)) return;
            backend.on_preview_frame_changed(frame);
        }));
        signals.add(local_session.recording_error.connect((message) => {
            var backend = weak_backend.get() as ProviderVideoMessageRecorderBackend;
            if (backend == null || !backend.is_current_start_generation(generation)) return;
            backend.fail_recording(message);
        }));
        signals.add(local_session.recording_stopped.connect((plugin_output) => {
            var backend = weak_backend.get() as ProviderVideoMessageRecorderBackend;
            if (backend == null || !backend.is_current_start_generation(generation)) return;
            backend.invalidate_start_generation();
            backend.detach_session();
            backend.current_state = MediaMessageRecorderState.IDLE;
            backend.output_path = null;
            backend.recording_stopped(new MediaMessageRecorderOutput(
                MediaMessageKind.VIDEO,
                plugin_output.path,
                plugin_output.mime_type,
                plugin_output.suggested_filename,
                MediaMessageCompatibility.PRIMARY));
        }));
        return signals;
    }

    private uint next_start_generation() {
        start_mutex.lock();
        start_generation++;
        uint generation = start_generation;
        start_mutex.unlock();
        return generation;
    }

    private bool is_current_start_generation(uint generation) {
        start_mutex.lock();
        bool is_current = generation == start_generation;
        start_mutex.unlock();
        return is_current;
    }

    private void invalidate_start_generation() {
        start_mutex.lock();
        start_generation++;
        start_mutex.unlock();
    }

    private void fail_start_recording(uint generation, string message) {
        if (!is_current_start_generation(generation)) return;
        var session_to_cancel = detach_session();
        if (session_to_cancel != null) session_to_cancel.cancel();
        if (output_path != null) {
            FileUtils.unlink((!) output_path);
            output_path = null;
        }
        latest_preview_texture = null;
        current_state = MediaMessageRecorderState.FAILED;
        invalidate_start_generation();
        recording_error(message);
    }

    private void fail_recording(string message) {
        invalidate_start_generation();
        var session_to_cancel = detach_session();
        if (session_to_cancel != null) {
            ((!) session_to_cancel).cancel();
        }
        if (output_path != null) {
            FileUtils.unlink((!) output_path);
            output_path = null;
        }
        current_state = MediaMessageRecorderState.FAILED;
        recording_error(message);
    }
}

private class VideoRecorderStartAttachResult : Object {
    public bool accepted = false;
}

}
