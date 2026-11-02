using Dino.Entities;
using Xmpp;

namespace Dino.Plugins {

public enum Priority {
    LOWEST,
    LOWER,
    DEFAULT,
    HIGHER,
    HIGHEST
}

public enum WidgetType {
    GTK3,
    GTK4
}

public enum NetworkStatusLevel {
    DISABLED,
    OK,
    WARNING,
    ERROR
}

public interface RootInterface : Object {
    public abstract void registered(Dino.Application app);

    public abstract void shutdown();

    /**
     * Re-encrypt this plugin's database with a new key.
     * Only plugins whose DB uses the shared app.db_key need to do real work;
     * others (OMEMO, plugins without a DB) should implement this as a no-op.
     */
    public abstract void rekey_database(string new_key) throws Error;

    /**
     * Flush WAL journal to the main database file.
     * Called before backup so that all data is in the .db file.
     */
    public abstract void checkpoint_database();

    /** Write consistent database snapshots into a private backup directory. */
    public virtual void backup_database(string directory, Cancellable? cancellable = null) throws Error {
    }
}

/** Trust of locally known recipient keys, not encryption/send readiness. */
public enum ConversationEncryptionTrust {
    UNKNOWN,
    TRUSTED,
    VERIFIED,
    NEEDS_ATTENTION
}

public interface EncryptionListEntry : Object {
    public abstract Entities.Encryption encryption { get; }
    public abstract string name { get; }

    public abstract void encryption_activated(Entities.Conversation conversation, owned Plugins.SetInputFieldStatus callback);
    public abstract Object? get_encryption_icon(Entities.Conversation conversation, ContentItem content_item);
    public abstract string? get_encryption_icon_name(Entities.Conversation conversation, ContentItem content_item);

    /**
     * Read only the account-scoped, currently stored recipient-key state.
     * This must not activate encryption, fetch/publish keys, create sessions,
     * change trust, or imply that cached keys/recipient lists are up to date.
     */
    public virtual ConversationEncryptionTrust get_conversation_trust(Entities.Conversation conversation) {
        return ConversationEncryptionTrust.UNKNOWN;
    }

}

public interface CallEncryptionEntry : Object {
    public abstract CallEncryptionWidget? get_widget(Account account, Xmpp.Xep.Jingle.ContentEncryption encryption);
}

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

public class VideoMessagePreviewFrame : Object {
    public Bytes bgra_data { get; private set; }
    public int width { get; private set; }
    public int height { get; private set; }
    public int stride { get; private set; }
    public uint64 frame_id { get; private set; }

    public VideoMessagePreviewFrame(Bytes bgra_data, int width, int height, int stride, uint64 frame_id) {
        this.bgra_data = bgra_data;
        this.width = width;
        this.height = height;
        this.stride = stride;
        this.frame_id = frame_id;
    }
}

public abstract class AudioMessageRecorderSession : Object {
    public signal void started();
    public signal void duration_changed(double seconds);
    public signal void level_changed(double peak);
    public signal void pcm_frame(Bytes pcm_data, int sample_rate, int channels, int bytes_per_sample);
    public signal void recording_error(string message);
    public signal void recording_stopped(MediaMessageRecorderOutput output);

    public abstract MediaMessageRecorderState state { get; }
    public abstract string? current_output_path { owned get; }

    public abstract void start() throws Error;
    public abstract void stop() throws Error;
    public abstract void cancel();
}

public abstract class VideoMessageRecorderSession : Object {
    public signal void started();
    public signal void duration_changed(double seconds);
    public signal void preview_frame_changed(VideoMessagePreviewFrame frame);
    public signal void recording_error(string message);
    public signal void recording_stopped(MediaMessageRecorderOutput output);

    public abstract MediaMessageRecorderState state { get; }
    public abstract string? current_output_path { owned get; }

    public abstract void start() throws Error;
    public abstract void stop() throws Error;
    public abstract void cancel();
}

public interface MediaMessageRecorderProvider : Object {
    public abstract string id { get; }
    public abstract bool audio_available { get; }
    public abstract string? audio_unavailable_reason { owned get; }
    public abstract bool video_available { get; }
    public abstract string? video_unavailable_reason { owned get; }

    public virtual Gee.List<MediaDevice> get_audio_input_devices() {
        return new Gee.ArrayList<MediaDevice>();
    }

    public virtual Gee.List<MediaDevice> get_video_input_devices() {
        return new Gee.ArrayList<MediaDevice>();
    }

    public abstract AudioMessageRecorderSession create_audio_message_recorder(string output_path) throws Error;
    public abstract VideoMessageRecorderSession create_video_message_recorder(string output_path) throws Error;

    public virtual AudioMessageRecorderSession create_audio_message_recorder_for_device(
            string output_path,
            MediaDevice? device) throws Error {
        return create_audio_message_recorder(output_path);
    }

    public virtual AudioMessageRecorderSession create_audio_test_for_device(
            string output_path,
            MediaDevice? device) throws Error {
        return create_audio_message_recorder_for_device(output_path, device);
    }

    public virtual VideoMessageRecorderSession create_video_message_recorder_for_device(
            string output_path,
            MediaDevice? device) throws Error {
        return create_video_message_recorder(output_path);
    }

    public virtual VideoMessageRecorderSession create_video_preview_for_device(
            string output_path,
            MediaDevice? device) throws Error {
        return create_video_message_recorder_for_device(output_path, device);
    }
}

public abstract class MediaMessagePlaybackSession : Object {
    public signal void playback_error(string message);

    public abstract bool active { get; }
    public abstract void start(int sample_rate, int channels, int bytes_per_sample) throws Error;
    public abstract uint push_pcm(Bytes pcm_data) throws Error;
    public abstract void set_paused(bool paused) throws Error;
    public abstract void flush() throws Error;
    public abstract uint finish() throws Error;
    public abstract void stop();
}

public interface MediaMessagePlaybackProvider : Object {
    public abstract string id { get; }
    public abstract bool available { get; }
    public abstract string? unavailable_reason { owned get; }

    public virtual Gee.List<MediaDevice> get_audio_output_devices() {
        return new Gee.ArrayList<MediaDevice>();
    }

    public abstract MediaMessagePlaybackSession create_audio_playback_session() throws Error;
}

/**
 * Optional development call engine for XEP-0353-gated 1:1 calls.
 *
 * This is deliberately narrower than VideoCallPlugin. It is the signaling
 * bridge used while the Google/libwebrtc engine is proven behind explicit
 * build/runtime gates. Production call UI code must not assume this exists.
 */
public abstract class JmiCallEngineSession : Object {
    public signal void active();
    public signal void media_ready(string media);
    public signal void remote_video_frame(JmiCallVideoFrame frame);
    public signal void local_video_frame(JmiCallVideoFrame frame);
    public signal void video_effect_status_changed(JmiVideoEffectStatus status);
    public signal void failed(string message);
    public signal void remote_terminated(string? reason_name, string? reason_text);

    /** Cached original offer shape, independent of local microphone/camera mute. */
    public virtual bool try_get_initial_offer_media(out bool audio, out bool video) {
        audio = false;
        video = false;
        return false;
    }

    public abstract void accept_proposal() throws Error;
    public abstract void reject_proposal() throws Error;
    public abstract void set_local_audio_enabled(bool enabled) throws Error;
    public virtual void set_local_video_enabled(bool enabled) throws Error {
        if (enabled) {
            throw new IOError.NOT_SUPPORTED("Video calls are not supported by this JMI call engine");
        }
    }
    public virtual void set_video_device(MediaDevice device) throws Error {
        throw new IOError.NOT_SUPPORTED("Video device selection is not supported by this JMI call engine");
    }
    public virtual JmiVideoEffectCapabilities get_video_effect_capabilities() {
        return JmiVideoEffectCapabilities.unavailable(JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
    }
    public virtual JmiVideoEffectStatus get_video_effect_status() {
        return new JmiVideoEffectStatus(
            new JmiVideoEffectSelection(JmiVideoEffectKind.OFF),
            JmiVideoEffectApplyState.UNAVAILABLE,
            0,
            0,
            JmiVideoEffectUnavailableReason.UNSUPPORTED_ENGINE);
    }
    public virtual async uint64 select_video_effect(JmiVideoEffectSelection selection) throws Error {
        throw new IOError.NOT_SUPPORTED("Video effects are not supported by this JMI call engine");
    }
    public virtual async void release_video_background(uint asset_id) throws Error {
        // Engines without a background registry own no staged resources.
    }
    /** Stage a bounded image on the control lane; no file path crosses the backend. */
    public virtual async uint stage_video_background(uint builtin_choice,
            JmiVideoBackgroundImage? image = null) throws Error {
        throw new IOError.NOT_SUPPORTED("Background images are unavailable in this engine");
    }
    /** Permanently blocks effects for a session promoted to a MUJI call. */
    public virtual void disable_video_effects_for_group_call() {
    }
    /**
     * Permanently blocks effects and waits asynchronously for the native
     * pipeline-destroy ordering barrier before MUJI becomes active.
     */
    public virtual async void fence_video_effects_for_group_call() {
        disable_video_effects_for_group_call();
    }
    public abstract void send_dtmf(char digit, uint duration_ms = 250) throws Error;
    public abstract JmiCallDiagnostics? get_diagnostics() throws Error;
    public abstract void end(string? reason_name, string? reason_text) throws Error;
    public abstract void discard();
    public abstract void close();
}

/** Backend-neutral, per-call outgoing-camera effect contract. */
public enum JmiVideoEffectKind {
    OFF,
    GRAYSCALE,
    WARM_TONE,
    COLD_TONE,
    SEPIA,
    LIGHT_LEAK,
    DREAMY,
    PRISM_LIGHT,
    FISHEYE,
    VINTAGE_TV,
    FROSTED_GLASS,
    DUO_TONE,
    UNDERWATER
}

public enum JmiVideoBackgroundMode {
    NONE,
    BLUR,
    SOLID,
    IMAGE
}

public enum JmiVideoFramingMode {
    NONE,
    AUTO
}

public enum JmiVideoGlassesStyle { OFF, SUNGLASSES, ROUND, RECTANGULAR }
public enum JmiVideoHatStyle { OFF, CAP, COWBOY, TOP_HAT }
public enum JmiVideoBeardStyle { OFF, MOUSTACHE, GOATEE, FULL }
public enum JmiVideoFaceAccessory { OFF, PUPPY, KARAOKE_MICROPHONE }
public enum JmiVideoSceneEffect { OFF, FIREWORKS, CONFETTI, STARS, FOOTBALL }

public enum JmiVideoEffectQuality {
    AUTO
}

public enum JmiVideoEffectApplyState {
    IDLE,
    ACCEPTED,
    APPLIED,
    DEGRADED,
    UNAVAILABLE,
    FAILED
}

public enum JmiVideoEffectUnavailableReason {
    NONE,
    UNSUPPORTED_ENGINE,
    AUDIO_ONLY,
    GROUP_CALL,
    CALL_ENDED,
    BACKEND_FAILURE
}

/** Immutable, decoded RGB/RGBA pixels; shared only for this logical call. */
public class JmiVideoBackgroundImage : Object {
    public uint width { get; private set; }
    public uint height { get; private set; }
    public uint stride { get; private set; }
    public bool rgba { get; private set; }
    public Bytes pixels { get; private set; }

    public JmiVideoBackgroundImage(uint width, uint height, uint stride,
            bool rgba, Bytes pixels) throws IOError {
        uint64 row = (uint64) width * (rgba ? 4 : 3);
        uint64 required = height > 0 ? (uint64) (height - 1) * stride + row : 0;
        if (width == 0 || height == 0 || width > 1920 || height > 1920 ||
                (uint64) width * height > 2073600 || stride < row ||
                pixels.get_size() > 8388608 || required > pixels.get_size()) {
            throw new IOError.INVALID_ARGUMENT("Background image exceeds the decoded image bounds");
        }
        this.width = width; this.height = height; this.stride = stride;
        this.rgba = rgba; this.pixels = pixels;
    }
}

public class JmiVideoEffectSelection : Object {
    public JmiVideoEffectKind kind { get; private set; }
    public JmiVideoEffectQuality quality { get; private set; }
    public uint preset_id { get; private set; }
    public uint asset_id { get; private set; }
    public int brightness { get; private set; }
    public int contrast { get; private set; }
    public int saturation { get; private set; }
    public int sharpness { get; private set; }
    public JmiVideoBackgroundMode background_mode { get; private set; }
    public int background_strength { get; private set; }
    public uint32 background_color_rgb { get; private set; }
    public JmiVideoFramingMode framing_mode { get; private set; }
    public JmiVideoGlassesStyle glasses_style { get; private set; }
    public JmiVideoHatStyle hat_style { get; private set; }
    public JmiVideoBeardStyle beard_style { get; private set; }
    public JmiVideoFaceAccessory face_accessory { get; private set; }
    public bool touch_up { get; private set; }
    public bool low_light { get; private set; }
    public JmiVideoSceneEffect scene_effect { get; private set; }

    public JmiVideoEffectSelection(
            JmiVideoEffectKind kind,
            JmiVideoEffectQuality quality = JmiVideoEffectQuality.AUTO,
            uint preset_id = 0,
            uint asset_id = 0,
            int brightness = 0,
            int contrast = 0,
            int saturation = 0,
            int sharpness = 0,
            JmiVideoBackgroundMode background_mode = JmiVideoBackgroundMode.NONE,
            int background_strength = 0,
            uint32 background_color_rgb = 0,
            JmiVideoFramingMode framing_mode = JmiVideoFramingMode.NONE,
            JmiVideoGlassesStyle glasses_style = JmiVideoGlassesStyle.OFF,
            JmiVideoHatStyle hat_style = JmiVideoHatStyle.OFF,
            JmiVideoBeardStyle beard_style = JmiVideoBeardStyle.OFF,
            JmiVideoFaceAccessory face_accessory = JmiVideoFaceAccessory.OFF,
            bool touch_up = false,
            bool low_light = false,
            JmiVideoSceneEffect scene_effect = JmiVideoSceneEffect.OFF) {
        this.kind = kind;
        this.quality = quality;
        this.preset_id = preset_id;
        this.asset_id = asset_id;
        this.brightness = brightness;
        this.contrast = contrast;
        this.saturation = saturation;
        this.sharpness = sharpness;
        this.background_mode = background_mode;
        this.background_strength = background_strength;
        this.background_color_rgb = background_color_rgb;
        this.framing_mode = framing_mode;
        this.glasses_style = glasses_style;
        this.hat_style = hat_style;
        this.beard_style = beard_style;
        this.face_accessory = face_accessory;
        this.touch_up = touch_up;
        this.low_light = low_light;
        this.scene_effect = scene_effect;
    }

    public bool is_neutral() {
        return kind == JmiVideoEffectKind.OFF && brightness == 0 &&
            contrast == 0 && saturation == 0 && sharpness == 0 &&
            background_mode == JmiVideoBackgroundMode.NONE &&
            framing_mode == JmiVideoFramingMode.NONE &&
            glasses_style == JmiVideoGlassesStyle.OFF && hat_style == JmiVideoHatStyle.OFF &&
            beard_style == JmiVideoBeardStyle.OFF && face_accessory == JmiVideoFaceAccessory.OFF &&
            !touch_up && !low_light && scene_effect == JmiVideoSceneEffect.OFF;
    }

    public bool is_valid() {
        if (kind < JmiVideoEffectKind.OFF || kind > JmiVideoEffectKind.UNDERWATER ||
                quality != JmiVideoEffectQuality.AUTO || preset_id != 0 ||
                brightness < -100 || brightness > 100 ||
                contrast < -100 || contrast > 100 ||
                saturation < -100 || saturation > 100 ||
                sharpness < 0 || sharpness > 100 ||
                background_strength < 0 || background_strength > 100 ||
                background_color_rgb > 0xffffff ||
                framing_mode < JmiVideoFramingMode.NONE || framing_mode > JmiVideoFramingMode.AUTO ||
                glasses_style < JmiVideoGlassesStyle.OFF || glasses_style > JmiVideoGlassesStyle.RECTANGULAR ||
                hat_style < JmiVideoHatStyle.OFF || hat_style > JmiVideoHatStyle.TOP_HAT ||
                beard_style < JmiVideoBeardStyle.OFF || beard_style > JmiVideoBeardStyle.FULL ||
                face_accessory < JmiVideoFaceAccessory.OFF || face_accessory > JmiVideoFaceAccessory.KARAOKE_MICROPHONE ||
                scene_effect < JmiVideoSceneEffect.OFF || scene_effect > JmiVideoSceneEffect.FOOTBALL) return false;
        switch (background_mode) {
            case JmiVideoBackgroundMode.NONE:
                return asset_id == 0 && background_strength == 0 && background_color_rgb == 0;
            case JmiVideoBackgroundMode.BLUR:
                return asset_id == 0 && background_color_rgb == 0;
            case JmiVideoBackgroundMode.SOLID:
                return asset_id == 0 && background_strength == 0;
            case JmiVideoBackgroundMode.IMAGE:
                return asset_id != 0 && background_strength == 0 && background_color_rgb == 0;
            default:
                return false;
        }
    }

    public JmiVideoEffectSelection with_color_settings(JmiVideoEffectKind kind,
            int brightness, int contrast, int saturation, int sharpness) {
        return new JmiVideoEffectSelection(kind, quality, preset_id, asset_id,
            brightness, contrast, saturation, sharpness, background_mode,
            background_strength, background_color_rgb, framing_mode, glasses_style,
            hat_style, beard_style, face_accessory, touch_up, low_light, scene_effect);
    }

    public JmiVideoEffectSelection with_background_settings(JmiVideoBackgroundMode mode,
            int strength, uint32 color_rgb, uint image_asset,
            JmiVideoFramingMode framing) {
        return new JmiVideoEffectSelection(kind, quality, preset_id, image_asset,
            brightness, contrast, saturation, sharpness, mode, strength, color_rgb,
            framing, glasses_style, hat_style, beard_style, face_accessory,
            touch_up, low_light, scene_effect);
    }

    public bool matches(JmiVideoEffectSelection other) {
        return kind == other.kind && quality == other.quality &&
            preset_id == other.preset_id && asset_id == other.asset_id &&
            brightness == other.brightness && contrast == other.contrast &&
            saturation == other.saturation && sharpness == other.sharpness &&
            background_mode == other.background_mode &&
            background_strength == other.background_strength &&
            background_color_rgb == other.background_color_rgb && framing_mode == other.framing_mode &&
            glasses_style == other.glasses_style && hat_style == other.hat_style &&
            beard_style == other.beard_style && face_accessory == other.face_accessory &&
            touch_up == other.touch_up && low_light == other.low_light && scene_effect == other.scene_effect;
    }
}

public class JmiVideoEffectCapabilities : Object {
    public bool available { get; private set; }
    public bool grayscale_supported { get; private set; }
    public bool warm_tone_supported { get; private set; }
    public bool cold_tone_supported { get; private set; }
    public bool sepia_supported { get; private set; }
    public uint64 additional_effect_mask { get; private set; }
    public uint32 supported_adjustment_mask { get; private set; }
    public uint32 supported_background_mask { get; private set; }
    public bool auto_framing_supported { get; private set; }
    public uint32 supported_glasses_mask { get; private set; }
    public uint32 supported_hat_mask { get; private set; }
    public uint32 supported_beard_mask { get; private set; }
    public uint32 supported_face_accessory_mask { get; private set; }
    public uint32 supported_scene_effect_mask { get; private set; }
    public bool touch_up_supported { get; private set; }
    public bool low_light_supported { get; private set; }
    public bool brightness_supported { get { return (supported_adjustment_mask & 1) != 0; } }
    public bool contrast_supported { get { return (supported_adjustment_mask & 2) != 0; } }
    public bool saturation_supported { get { return (supported_adjustment_mask & 4) != 0; } }
    public bool sharpness_supported { get { return (supported_adjustment_mask & 8) != 0; } }
    public JmiVideoEffectUnavailableReason unavailable_reason { get; private set; }

    public JmiVideoEffectCapabilities(
            bool available,
            bool grayscale_supported,
            bool warm_tone_supported,
            JmiVideoEffectUnavailableReason unavailable_reason = JmiVideoEffectUnavailableReason.NONE,
            bool cold_tone_supported = false,
            bool sepia_supported = false,
            uint32 supported_adjustment_mask = 0,
            uint32 supported_background_mask = 1,
            bool auto_framing_supported = false,
            uint64 additional_effect_mask = 0,
            uint32 supported_glasses_mask = 1,
            uint32 supported_hat_mask = 1,
            uint32 supported_beard_mask = 1,
            uint32 supported_face_accessory_mask = 1,
            uint32 supported_scene_effect_mask = 1,
            bool touch_up_supported = false,
            bool low_light_supported = false) {
        this.available = available;
        this.grayscale_supported = grayscale_supported;
        this.warm_tone_supported = warm_tone_supported;
        this.unavailable_reason = unavailable_reason;
        this.cold_tone_supported = cold_tone_supported;
        this.sepia_supported = sepia_supported;
        this.supported_adjustment_mask = supported_adjustment_mask;
        this.supported_background_mask = supported_background_mask;
        this.auto_framing_supported = auto_framing_supported;
        this.additional_effect_mask = additional_effect_mask & 8160UL;
        this.supported_glasses_mask = supported_glasses_mask & 15U;
        this.supported_hat_mask = supported_hat_mask & 15U;
        this.supported_beard_mask = supported_beard_mask & 15U;
        this.supported_face_accessory_mask = supported_face_accessory_mask & 7U;
        this.supported_scene_effect_mask = supported_scene_effect_mask & 31U;
        this.touch_up_supported = touch_up_supported;
        this.low_light_supported = low_light_supported;
    }

    public bool supports_kind(JmiVideoEffectKind kind) {
        if (!available) return false;
        switch (kind) {
            case JmiVideoEffectKind.OFF: return true;
            case JmiVideoEffectKind.GRAYSCALE: return grayscale_supported;
            case JmiVideoEffectKind.WARM_TONE: return warm_tone_supported;
            case JmiVideoEffectKind.COLD_TONE: return cold_tone_supported;
            case JmiVideoEffectKind.SEPIA: return sepia_supported;
            default:
                return kind >= JmiVideoEffectKind.LIGHT_LEAK && kind <= JmiVideoEffectKind.UNDERWATER &&
                    (additional_effect_mask & (1UL << (int) kind)) != 0;
        }
    }

    public bool supports_selection(JmiVideoEffectSelection selection) {
        if (!selection.is_valid() || !supports_kind(selection.kind)) return false;
        return (selection.brightness == 0 || brightness_supported) &&
            (selection.contrast == 0 || contrast_supported) &&
            (selection.saturation == 0 || saturation_supported) &&
            (selection.sharpness == 0 || sharpness_supported) &&
            (supported_background_mask & (1U << (int) selection.background_mode)) != 0 &&
            (selection.framing_mode == JmiVideoFramingMode.NONE || auto_framing_supported) &&
            (supported_glasses_mask & (1U << (int) selection.glasses_style)) != 0 &&
            (supported_hat_mask & (1U << (int) selection.hat_style)) != 0 &&
            (supported_beard_mask & (1U << (int) selection.beard_style)) != 0 &&
            (supported_face_accessory_mask & (1U << (int) selection.face_accessory)) != 0 &&
            (supported_scene_effect_mask & (1U << (int) selection.scene_effect)) != 0 &&
            (!selection.touch_up || touch_up_supported) && (!selection.low_light || low_light_supported);
    }

    public static JmiVideoEffectCapabilities unavailable(JmiVideoEffectUnavailableReason reason) {
        return new JmiVideoEffectCapabilities(false, false, false, reason);
    }
}

public class JmiVideoEffectStatus : Object {
    public JmiVideoEffectSelection selection { get; private set; }
    public JmiVideoEffectApplyState state { get; private set; }
    public uint64 accepted_revision { get; private set; }
    public uint64 applied_revision { get; private set; }
    public JmiVideoEffectUnavailableReason reason { get; private set; }

    public JmiVideoEffectStatus(
            JmiVideoEffectSelection selection,
            JmiVideoEffectApplyState state,
            uint64 accepted_revision,
            uint64 applied_revision,
            JmiVideoEffectUnavailableReason reason = JmiVideoEffectUnavailableReason.NONE) {
        this.selection = selection;
        this.state = state;
        this.accepted_revision = accepted_revision;
        this.applied_revision = applied_revision;
        this.reason = reason;
    }
}

public class JmiCallVideoFrame : Object {
    public Bytes data { get; private set; }
    public int width { get; private set; }
    public int height { get; private set; }
    public int stride { get; private set; }
    public uint64 frame_id { get; private set; }

    public JmiCallVideoFrame(Bytes data, int width, int height, int stride, uint64 frame_id) {
        this.data = data;
        this.width = width;
        this.height = height;
        this.stride = stride;
        this.frame_id = frame_id;
    }
}

public class JmiCallDiagnostics : Object {
    public bool wire_started { get; set; default=false; }
    public bool audio_requested { get; set; default=false; }
    public bool video_requested { get; set; default=false; }
    public int audio_transceiver_count { get; set; default=0; }
    public int video_transceiver_count { get; set; default=0; }
    public bool local_audio_source_attached { get; set; default=false; }
    public bool local_audio_track_attached { get; set; default=false; }
    public bool local_audio_track_enabled { get; set; default=false; }
    public bool local_video_source_attached { get; set; default=false; }
    public bool local_video_track_attached { get; set; default=false; }
    public bool local_video_track_enabled { get; set; default=false; }
    public bool local_video_capture_running { get; set; default=false; }
    public uint64 local_video_capture_frame_count { get; set; default=0; }
    public int local_video_capture_last_width { get; set; default=0; }
    public int local_video_capture_last_height { get; set; default=0; }
    public int remote_audio_receiver_count { get; set; default=0; }
    public int remote_video_receiver_count { get; set; default=0; }
    public int remote_audio_sink_count { get; set; default=0; }
    public uint64 remote_audio_sink_frame_count { get; set; default=0; }
    public uint64 remote_audio_sink_sample_count { get; set; default=0; }
    public double remote_audio_sink_peak_level { get; set; default=0; }
    public int remote_video_sink_count { get; set; default=0; }
    public uint64 remote_video_sink_frame_count { get; set; default=0; }
    public int remote_video_sink_last_width { get; set; default=0; }
    public int remote_video_sink_last_height { get; set; default=0; }
    public uint64 inbound_audio_packets_received { get; set; default=0; }
    public uint64 inbound_audio_bytes_received { get; set; default=0; }
    public uint64 inbound_audio_total_samples_received { get; set; default=0; }
    public uint64 inbound_video_packets_received { get; set; default=0; }
    public uint64 inbound_video_bytes_received { get; set; default=0; }
    public uint64 inbound_video_frames_received { get; set; default=0; }
    public uint64 inbound_video_frames_decoded { get; set; default=0; }
    public int inbound_video_frame_width { get; set; default=0; }
    public int inbound_video_frame_height { get; set; default=0; }
    public uint64 outbound_audio_packets_sent { get; set; default=0; }
    public uint64 outbound_audio_bytes_sent { get; set; default=0; }
    public double outbound_audio_target_bitrate { get; set; default=0; }
    public string call_network_policy { get; set; default="automatic"; }
    public int audio_sender_bitrate_cap_bps { get; set; default=0; }
    public bool audio_sender_adaptive_ptime { get; set; default=false; }
    public bool audio_sender_policy_applied { get; set; default=false; }
    public uint64 outbound_video_packets_sent { get; set; default=0; }
    public uint64 outbound_video_bytes_sent { get; set; default=0; }
    public uint64 outbound_video_frames_sent { get; set; default=0; }
    public uint64 outbound_video_frames_encoded { get; set; default=0; }
    public double outbound_video_target_bitrate { get; set; default=0; }
    public int outbound_video_frame_width { get; set; default=0; }
    public int outbound_video_frame_height { get; set; default=0; }
    public double inbound_audio_level { get; set; default=0; }
    public double source_audio_level { get; set; default=0; }
    public double source_audio_total_energy { get; set; default=0; }
    public double source_audio_total_duration { get; set; default=0; }
    public uint64 stats_report_count { get; set; default=0; }
    public bool audio_device_initialized { get; set; default=false; }
    public bool audio_device_playout_initialized { get; set; default=false; }
    public bool audio_device_recording_initialized { get; set; default=false; }
    public bool audio_device_playing { get; set; default=false; }
    public bool audio_device_recording { get; set; default=false; }
    public uint64 audio_device_capture_sample_count { get; set; default=0; }
    public uint64 audio_device_capture_probe_frame_count { get; set; default=0; }
    public uint64 audio_device_capture_probe_sample_count { get; set; default=0; }
    public double audio_device_capture_probe_peak_level { get; set; default=0; }
    public uint64 audio_device_playout_sample_count { get; set; default=0; }
    public bool audio_device_microphone_volume_available { get; set; default=false; }
    public double audio_device_microphone_volume { get; set; default=1.0; }
    public bool audio_device_speaker_volume_available { get; set; default=false; }
    public double audio_device_speaker_volume { get; set; default=1.0; }
    public uint64 local_dtmf_feedback_start_count { get; set; default=0; }
    public uint64 local_dtmf_feedback_mix_call_count { get; set; default=0; }
    public uint64 local_dtmf_feedback_mixed_frame_count { get; set; default=0; }
    public uint64 local_dtmf_feedback_unsupported_format_count { get; set; default=0; }
    public uint local_dtmf_feedback_last_sample_rate { get; set; default=0; }
    public uint local_dtmf_feedback_last_channels { get; set; default=0; }
    public uint local_dtmf_feedback_last_bytes_per_sample { get; set; default=0; }
    public double local_dtmf_feedback_peak_level { get; set; default=0; }
    public bool local_dtmf_feedback_active { get; set; default=false; }
    public int ice_server_count { get; set; default=0; }
    public string? jmi_state { get; set; default=null; }
    public string? peer_connection_state { get; set; default=null; }
    public string? ice_connection_state { get; set; default=null; }
}

public interface JmiCallEnginePlugin : Object {
    public abstract string engine_id { get; }

    public abstract bool runtime_enabled();
    public abstract bool can_start_audio_only(Account account);
    public virtual bool can_start_video(Account account) { return false; }
    public abstract Gee.List<MediaDevice> get_audio_devices(bool incoming);
    public abstract MediaDevice? get_preferred_audio_device(bool incoming);
    public abstract void set_audio_device(MediaDevice device) throws Error;
    public virtual double get_audio_device_volume(MediaDevice? device) { return 1.0; }
    public virtual void set_audio_device_volume(MediaDevice? device, double volume) throws Error {}
    public virtual void play_test_tone(MediaDevice? device, char digit = '5', uint duration_ms = 360) throws Error {
        throw new IOError.NOT_SUPPORTED("This call engine does not support speaker test tones");
    }
    public virtual uint play_audio_test_clip(
            MediaDevice? device,
            Bytes pcm_data,
            int sample_rate,
            int channels,
            int bytes_per_sample) throws Error {
        throw new IOError.NOT_SUPPORTED("This call engine does not support microphone test playback");
    }
    public virtual void stop_audio_test_playout() throws Error {}
    public virtual Gee.List<MediaDevice> get_video_devices() { return new Gee.ArrayList<MediaDevice>(); }
    public virtual MediaDevice? get_preferred_video_device() {
        Gee.List<MediaDevice> devices = get_video_devices();
        if (devices.is_empty) return null;
        return devices.first();
    }

    public abstract JmiCallEngineSession start_outgoing_audio_session(
        XmppStream stream,
        Jid local_full_jid,
        Jid peer_bare_jid,
        string sid,
        uint64 logical_call_id) throws Error;

    public virtual JmiCallEngineSession start_outgoing_session(
        XmppStream stream,
        Jid local_full_jid,
        Jid peer_bare_jid,
        string sid,
        uint64 logical_call_id,
        bool video_requested) throws Error {
        if (video_requested) {
            throw new IOError.NOT_SUPPORTED("Video calls are not supported by this JMI call engine");
        }
        return start_outgoing_audio_session(stream, local_full_jid, peer_bare_jid, sid, logical_call_id);
    }

    public abstract JmiCallEngineSession create_incoming_session(
        XmppStream stream,
        Jid local_full_jid,
        Jid peer_full_jid,
        string sid,
        uint64 logical_call_id,
        Gee.List<StanzaNode> descriptions) throws Error;

    public abstract bool handle_proceed(Jid from, Jid to, string sid) throws Error;
}

/**
 * One media-engine owner for a temporary XEP-0272 MUJI room.
 *
 * Peer sessions use the established JmiCallEngineSession media/control
 * contract, but their signaling starts directly with Jingle against a full
 * JID.  Incoming sessions are emitted only after a previously registered
 * peer expectation has matched local JID, peer JID, room and a fresh SID.
 */
public abstract class MujiCallEngineGroupSession : Object {
    public signal void video_effect_status_changed(JmiVideoEffectStatus status);
    public signal void incoming_peer_session(
        Jid peer_full_jid, string sid, JmiCallEngineSession session);
    public signal void incoming_peer_session_failed(
        Jid peer_full_jid, string sid, string message);

    public abstract Jid room_jid { get; }
    public abstract Xep.Muji.CodecProvider codec_provider { get; }

    /**
     * Freezes the XEP-0272 conference content names and global payload map
     * before ready presence or any new peer leg is created. The native media
     * transport and its Jingle descriptions must agree on these negotiated
     * identities and payload mappings. Engines must reject unsupported media
     * identities here, before the room advertises an unusable conference map.
     */
    public abstract void configure_conference_media(
        Gee.Map<string, string> content_names_by_media,
        Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
            payload_types_by_media) throws Error;
    /** Seeds conference identity from a live 1:1 leg before room presence. */
    public abstract void prepare_peer_adoption(
        Jid peer_full_jid, JmiCallEngineSession session) throws Error;
    public abstract bool copy_preferred_conference_media(
        out Gee.Map<string, string> content_names_by_media,
        out Gee.Map<string, Gee.List<Xep.JingleRtp.PayloadType>>
            payload_types_by_media);
    public abstract JmiCallEngineSession start_outgoing_peer_session(
        Jid peer_full_jid, string sid, bool video_requested) throws Error;
    public abstract void adopt_peer_session(
        Jid peer_full_jid, JmiCallEngineSession session) throws Error;
    public abstract void expect_incoming_peer_session(
        Jid peer_full_jid, bool video_requested) throws Error;
    public abstract bool cancel_expected_incoming_peer_session(Jid peer_full_jid);
    /** Holds already claimed inbound IQs until Core has published exact peers. */
    public virtual void defer_incoming_peer_session_delivery() {
    }
    /** Delivers every held inbound peer exactly once after Core is ready. */
    public virtual void release_deferred_incoming_peer_sessions() {
    }
    public virtual void set_local_video_enabled(bool enabled) throws Error {
        if (enabled) {
            throw new IOError.NOT_SUPPORTED(
                "Video calls are not supported by this MUJI call engine");
        }
    }
    public virtual void set_video_device(MediaDevice device) throws Error {
        throw new IOError.NOT_SUPPORTED(
            "Video device selection is not supported by this MUJI call engine");
    }
    /** Effects belong to the one outgoing-camera source shared by this group. */
    public virtual JmiVideoEffectCapabilities get_video_effect_capabilities() {
        return JmiVideoEffectCapabilities.unavailable(JmiVideoEffectUnavailableReason.GROUP_CALL);
    }
    public virtual JmiVideoEffectStatus get_video_effect_status() {
        return new JmiVideoEffectStatus(new JmiVideoEffectSelection(JmiVideoEffectKind.OFF),
            JmiVideoEffectApplyState.UNAVAILABLE, 0, 0, JmiVideoEffectUnavailableReason.GROUP_CALL);
    }
    public virtual async uint64 select_video_effect(JmiVideoEffectSelection selection) throws Error {
        throw new IOError.NOT_SUPPORTED("This group engine does not support shared video effects");
    }
    public virtual async void release_video_background(uint asset_id) throws Error {
        // Engines without a background registry own no staged resources.
    }
    /** Stage a bounded image on the control lane; no file path crosses the backend. */
    public virtual async uint stage_video_background(uint builtin_choice,
            JmiVideoBackgroundImage? image = null) throws Error {
        throw new IOError.NOT_SUPPORTED("Background images are unavailable in this engine");
    }
    /** Permanently makes this group audio-only after a negotiated codec downgrade. */
    public virtual void disable_video_for_codec_downgrade() {
    }
    public abstract void close();
}

/** Optional direct-Jingle call engine for XEP-0272 MUJI full-mesh calls. */
public interface MujiCallEnginePlugin : Object {
    /** Stable id matched against JmiCallEnginePlugin.engine_id. */
    public abstract string group_engine_id { get; }

    public abstract bool runtime_enabled();
    public abstract bool can_start_group_audio(Account account);
    public virtual bool can_start_group_video(Account account) { return false; }

    public abstract MujiCallEngineGroupSession create_group_session(
        XmppStream stream,
        Jid local_full_jid,
        Jid room_jid,
        uint64 logical_call_id,
        bool video_requested) throws Error;
}

public interface CallEncryptionWidget : Object {
    public abstract string? get_title();
    public abstract bool show_keys();
    public abstract string? get_icon_name();
}

public abstract class AccountSettingsEntry : Object {
    public abstract string id { get; }
    public virtual Priority priority { get { return Priority.DEFAULT; } }
    public abstract string name { get; }
    public virtual int16 label_top_padding { get { return -1; } }

    public signal void activated();
    public abstract void deactivate();

    public abstract void set_account(Account account);
    public abstract Object? get_widget(WidgetType type);
}

public abstract class EncryptionPreferencesEntry : Object {
    public abstract string id { get; }
    public virtual Priority priority { get { return Priority.DEFAULT; } }

    public abstract Object? get_widget(Account account, WidgetType type);
}

public interface ContactDetailsProvider : Object {
    public abstract string id { get; }
    public abstract string tab { get; }

    public abstract void populate(Conversation conversation, ContactDetails contact_details, WidgetType type);
    public abstract Object? get_widget(Conversation conversation);
}

public class ContactDetails : Object {
    public signal void save();
    public signal void add_settings_action_row(Object action_row_model);
}

public interface TextCommand : Object {
    public abstract string cmd { get; }

    public abstract string? handle_command(string? text, Entities.Conversation? conversation);
}

public interface ConversationTitlebarEntry : Object {
    public abstract string id { get; }
    public abstract double order { get; }
    public abstract Object? get_widget(WidgetType type);

    public abstract void set_conversation(Conversation conversation);
    public abstract void unset_conversation();
}

public interface NetworkStatusProvider : Object {
    public abstract string id { get; }
    public abstract string name { get; }

    public signal void status_changed();

    public abstract NetworkStatusLevel get_status_level();
    public abstract Object? get_widget(WidgetType type);
}

public interface AccountProxyProvider : Object {
    public abstract string id { get; }
    public abstract string proxy_type { get; }
    public abstract string proxy_host { owned get; }
    public abstract int proxy_port { get; }
    public abstract bool proxy_enabled { get; }
    public abstract bool proxy_ready { get; }
}

public enum AccountRemovalMode {
    LOCAL_ONLY,
    SERVER
}

public class AccountRemovalImpact : Object {
    public int local_bots = 0;
    public int server_managed_bots = 0;
    public int manual_dedicated_bots = 0;
    public int cloudbot_tokens = 0;

    public bool has_any() {
        return local_bots > 0 || server_managed_bots > 0 || manual_dedicated_bots > 0 || cloudbot_tokens > 0;
    }

    public void add(AccountRemovalImpact other) {
        local_bots += other.local_bots;
        server_managed_bots += other.server_managed_bots;
        manual_dedicated_bots += other.manual_dedicated_bots;
        cloudbot_tokens += other.cloudbot_tokens;
    }
}

public interface AccountRemovalProvider : Object {
    public abstract string id { get; }

    public abstract AccountRemovalImpact get_account_removal_impact(Entities.Account account);
    public abstract async void cleanup_removed_account(Entities.Account account, AccountRemovalMode mode, bool delete_managed_bots);
}

public interface AccountRemovalOperation : Object {
    public abstract async string? remove_server_account();
    public abstract async void cleanup_related_data();
    public abstract async void remove_local_account();
}

public class AccountRemovalCoordinator : Object {
    public static async string? run(AccountRemovalOperation operation, bool remove_from_server) {
        if (remove_from_server) {
            string? server_error = yield operation.remove_server_account();
            if (server_error != null) return server_error;
        }

        yield operation.cleanup_related_data();
        yield operation.remove_local_account();
        return null;
    }
}

public interface ConversationItemPopulator : Object {
    public abstract string id { get; }
    public abstract void init(Conversation conversation, ConversationItemCollection summary, WidgetType type);
    public abstract void close(Conversation conversation);
}

public interface ConversationAdditionPopulator : ConversationItemPopulator {
    public virtual void populate_timespan(Conversation conversation, DateTime from, DateTime to) { }
}

public interface VideoCallPlugin : Object {

    public abstract bool supported();
    // Video widget
    public abstract VideoCallWidget? create_widget(WidgetType type);

    // Devices
    public signal void devices_changed(string media, bool incoming);
    public abstract Gee.List<MediaDevice> get_devices(string media, bool incoming);
    public abstract MediaDevice? get_preferred_device(string media, bool incoming);
    public abstract MediaDevice? get_device(Xmpp.Xep.JingleRtp.Stream? stream, bool incoming);
    public abstract void set_pause(Xmpp.Xep.JingleRtp.Stream? stream, bool pause);
    public abstract void set_device(Xmpp.Xep.JingleRtp.Stream? stream, MediaDevice? device);

    // Volume control (0.0 to 1.0)
    public abstract double get_device_volume(MediaDevice? device);
    public abstract void set_device_volume(MediaDevice? device, double volume);

    // WebRTC Gain
    public abstract void set_digital_gain_db(int gain_db, bool manual_mode);

    // Per-stream volume control for individual participant audio (0.0 to 1.0)
    public abstract double get_stream_volume(Xmpp.Xep.JingleRtp.Stream? stream);
    public abstract void set_stream_volume(Xmpp.Xep.JingleRtp.Stream? stream, double volume);

    // DTMF (RFC 4733 telephone-event)
    public abstract void send_dtmf(Xmpp.Xep.JingleRtp.Stream? stream, char digit, uint duration_ms = 250);

    // Pipeline lifecycle
    public abstract void dispose_pipeline();

    public abstract void dump_dot();
}

public interface VideoCallWidget : Object {
    public signal void resolution_changed(uint width, uint height);
    public abstract void display_stream(Xmpp.Xep.JingleRtp.Stream? stream, Jid jid);
    public abstract void display_device(MediaDevice device);
    public abstract void detach();
}

public interface MediaDevice : Object {
    public abstract string id { owned get; }
    // Runtime IDs may contain an enumeration index. Preferences must use an
    // identity that survives device reordering instead.
    public virtual string persistent_id { owned get { return id; } }
    public virtual bool matches_saved_identifier(string value) {
        if (value == "") return false;
        string? detail = detail_name;
        return persistent_id == value || id == value ||
            (detail != null && detail != "" && detail == value);
    }
    public abstract string display_name { owned get; }
    public abstract string? detail_name { owned get; }

    public abstract string? media { owned get; }
    public abstract bool incoming { get; }
}

public interface NotificationPopulator : Object {
    public abstract string id { get; }
    public abstract void init(Conversation conversation, NotificationCollection summary, WidgetType type);
    public abstract void close(Conversation conversation);
}

public abstract class MetaConversationItem : Object {
    public virtual string populator_id { get; set; }
    public virtual Jid? jid { get; set; default=null; }
    public virtual DateTime time { get; set; default = new DateTime.now_utc(); }
    public virtual int secondary_sort_indicator { get; set; }
    public virtual Encryption encryption { get; set; default = Encryption.NONE; }
    public virtual Entities.Message.Marked mark { get; set; default = Entities.Message.Marked.NONE; }

    public bool can_merge { get; set; default=false; }
    public bool requires_avatar { get; set; default=false; }
    public bool requires_header { get; set; default=false; }
    public bool in_edit_mode { get; set; default=false; }

    public abstract Object? get_widget(ConversationItemWidgetInterface outer, WidgetType type);
    public abstract Gee.List<MessageAction>? get_item_actions(WidgetType type);
}

public interface ConversationItemWidgetInterface: Object {
    public abstract void set_widget(Object object, WidgetType type, int priority);
}

public delegate void MessageActionEvoked(Variant? variant);
public class MessageAction : Object {
    public string name;
    public bool sensitive = true;
    public bool shortcut_action = true;
    public string icon_name;
    public string? tooltip;
    public Object? popover;
    public MessageActionEvoked? callback;
}

public abstract class MetaConversationNotification : Object {
    public abstract Object? get_widget(WidgetType type);
}

public interface ConversationItemCollection : Object {
    public signal void inserted_item(MetaConversationItem item);
    public signal void removed_item(MetaConversationItem item);

    public abstract void insert_item(MetaConversationItem item);
    public abstract void remove_item(MetaConversationItem item);
}

public interface NotificationCollection : Object {
    public signal void add_meta_notification(MetaConversationNotification item);
    public signal void remove_meta_notification(MetaConversationNotification item);
}

public delegate void SetInputFieldStatus(InputFieldStatus field_status);
public class InputFieldStatus : Object {
    public enum MessageType {
        NONE,
        INFO,
        WARNING,
        ERROR
    }
    public enum InputState {
        NORMAL,
        DISABLED,
        NO_SEND
    }

    public string? message;
    public MessageType message_type;
    public InputState input_state;
    public bool contains_markup;

    public InputFieldStatus(string? message, MessageType message_type, InputState input_state, bool contains_markup = false) {
        this.message = message;
        this.message_type = message_type;
        this.input_state = input_state;
        this.contains_markup = contains_markup;
    }
}

}
