#ifndef DINOX_WEBRTC_H
#define DINOX_WEBRTC_H

#include <stdint.h>
#include <stddef.h>

#if defined(DINOX_WEBRTC_STATIC)
#define DINOX_WEBRTC_API
#elif defined(_WIN32) || defined(__CYGWIN__)
#if defined(DINOX_WEBRTC_BUILDING_LIBRARY)
#define DINOX_WEBRTC_API __declspec(dllexport)
#else
#define DINOX_WEBRTC_API __declspec(dllimport)
#endif
#else
#define DINOX_WEBRTC_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define DINOX_WEBRTC_ABI_VERSION 40

typedef struct DinoXWebrtcContext DinoXWebrtcContext;
typedef struct DinoXWebrtcSession DinoXWebrtcSession;
typedef struct DinoXWebrtcMediaRecorder DinoXWebrtcMediaRecorder;
typedef struct DinoXWebrtcVideoPipeline DinoXWebrtcVideoPipeline;

typedef enum {
    DINOX_WEBRTC_STATUS_OK = 0,
    DINOX_WEBRTC_STATUS_INVALID_ARGUMENT = 1,
    DINOX_WEBRTC_STATUS_NOT_READY = 2,
    DINOX_WEBRTC_STATUS_INTERNAL_ERROR = 3,
    DINOX_WEBRTC_STATUS_PARSE_ERROR = 4,
} DinoXWebrtcStatus;

typedef struct {
    unsigned int abi_version;
    unsigned int webrtc_milestone;
    const char* webrtc_branch;
    const char* webrtc_commit;
    const char* artifact_abi;
    int runtime_enabled;
} DinoXWebrtcBuildInfo;

typedef enum {
    DINOX_WEBRTC_SDP_TYPE_OFFER = 0,
    DINOX_WEBRTC_SDP_TYPE_ANSWER = 1,
} DinoXWebrtcSdpType;

typedef enum {
    DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV = 0,
    DINOX_WEBRTC_MEDIA_DIRECTION_SEND_ONLY = 1,
    DINOX_WEBRTC_MEDIA_DIRECTION_RECV_ONLY = 2,
    DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE = 3,
} DinoXWebrtcMediaDirection;

typedef enum {
    DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC = 0,
    DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT = 1,
} DinoXWebrtcAudioDeviceMode;

typedef enum {
    DINOX_WEBRTC_NETWORK_POLICY_AUTOMATIC = 0,
    DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G = 1,
} DinoXWebrtcNetworkPolicy;

typedef enum {
    DINOX_WEBRTC_PEER_CONNECTION_STATE_NEW = 0,
    DINOX_WEBRTC_PEER_CONNECTION_STATE_CONNECTING = 1,
    DINOX_WEBRTC_PEER_CONNECTION_STATE_CONNECTED = 2,
    DINOX_WEBRTC_PEER_CONNECTION_STATE_DISCONNECTED = 3,
    DINOX_WEBRTC_PEER_CONNECTION_STATE_FAILED = 4,
    DINOX_WEBRTC_PEER_CONNECTION_STATE_CLOSED = 5,
} DinoXWebrtcPeerConnectionState;

typedef enum {
    DINOX_WEBRTC_ICE_CONNECTION_STATE_NEW = 0,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_CHECKING = 1,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_CONNECTED = 2,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_COMPLETED = 3,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_FAILED = 4,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_DISCONNECTED = 5,
    DINOX_WEBRTC_ICE_CONNECTION_STATE_CLOSED = 6,
} DinoXWebrtcIceConnectionState;

typedef struct {
    unsigned int abi_version;
    int audio_enabled;
    int video_enabled;
    DinoXWebrtcMediaDirection audio_direction;
    DinoXWebrtcMediaDirection video_direction;
    int defer_audio_transceiver_until_answer;
    int defer_video_transceiver_until_answer;
    int ice_candidate_pool_size;
    int max_bundle;
    DinoXWebrtcNetworkPolicy network_policy;
} DinoXWebrtcSessionConfig;

typedef struct {
    const char* url;
    const char* username;
    const char* credential;
} DinoXWebrtcIceServer;

typedef void (*DinoXWebrtcLocalDescriptionCallback)(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const char* sdp,
    void* user_data);

typedef void (*DinoXWebrtcRemoteDescriptionSetCallback)(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    void* user_data);

typedef void (*DinoXWebrtcIceCandidateCallback)(
    DinoXWebrtcSession* session,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate,
    void* user_data);

typedef void (*DinoXWebrtcIceGatheringCompleteCallback)(
    DinoXWebrtcSession* session,
    void* user_data);

typedef void (*DinoXWebrtcErrorCallback)(
    DinoXWebrtcSession* session,
    DinoXWebrtcStatus status,
    const char* message,
    void* user_data);

/**
 * Delivers one decoded remote video frame as copied BGRA-compatible memory.
 *
 * The frame memory is owned by the native wrapper and is valid only during the
 * callback. Bindings must copy it before returning. The callback is emitted on
 * a libwebrtc worker thread; UI code must marshal it to the UI/main thread.
 */
typedef void (*DinoXWebrtcVideoFrameCallback)(
    DinoXWebrtcSession* session,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data);

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcLocalDescriptionCallback on_local_description;
    DinoXWebrtcRemoteDescriptionSetCallback on_remote_description_set;
    DinoXWebrtcIceCandidateCallback on_ice_candidate;
    DinoXWebrtcIceGatheringCompleteCallback on_ice_gathering_complete;
    DinoXWebrtcErrorCallback on_error;
    DinoXWebrtcVideoFrameCallback on_video_frame;
    DinoXWebrtcVideoFrameCallback on_local_video_frame;
    /** Optional two-phase callback. The SDP has not been set locally yet. */
    DinoXWebrtcLocalDescriptionCallback on_local_description_prepared;
} DinoXWebrtcCallbacks;

typedef struct {
    unsigned int abi_version;
    int audio_transceiver_count;
    int video_transceiver_count;
    int local_audio_source_attached;
    int local_audio_track_attached;
    int local_audio_track_enabled;
    int local_video_source_attached;
    int local_video_track_attached;
    int local_video_track_enabled;
    uint64_t local_video_source_frame_count;
    int local_video_source_last_width;
    int local_video_source_last_height;
    int local_video_capture_running;
    uint64_t local_video_capture_frame_count;
    int local_video_capture_last_width;
    int local_video_capture_last_height;
    int remote_audio_receiver_count;
    int remote_video_receiver_count;
    int remote_audio_sink_count;
    uint64_t remote_audio_sink_frame_count;
    uint64_t remote_audio_sink_sample_count;
    double remote_audio_sink_peak_level;
    int remote_video_sink_count;
    uint64_t remote_video_sink_frame_count;
    int remote_video_sink_last_width;
    int remote_video_sink_last_height;
    uint64_t inbound_audio_packets_received;
    uint64_t inbound_audio_bytes_received;
    uint64_t inbound_audio_total_samples_received;
    uint64_t inbound_video_packets_received;
    uint64_t inbound_video_bytes_received;
    uint64_t inbound_video_frames_received;
    uint64_t inbound_video_frames_decoded;
    int inbound_video_frame_width;
    int inbound_video_frame_height;
    uint64_t outbound_audio_packets_sent;
    uint64_t outbound_audio_bytes_sent;
    double outbound_audio_target_bitrate;
    uint64_t outbound_video_packets_sent;
    uint64_t outbound_video_bytes_sent;
    uint64_t outbound_video_frames_sent;
    uint64_t outbound_video_frames_encoded;
    double outbound_video_target_bitrate;
    int outbound_video_frame_width;
    int outbound_video_frame_height;
    double inbound_audio_level;
    double source_audio_level;
    double source_audio_total_energy;
    double source_audio_total_duration;
    uint64_t stats_report_count;
    int audio_device_initialized;
    int audio_device_playout_initialized;
    int audio_device_recording_initialized;
    int audio_device_playing;
    int audio_device_recording;
    uint64_t audio_device_capture_sample_count;
    uint64_t audio_device_capture_probe_frame_count;
    uint64_t audio_device_capture_probe_sample_count;
    double audio_device_capture_probe_peak_level;
    uint64_t audio_device_playout_sample_count;
    int audio_device_microphone_volume_available;
    double audio_device_microphone_volume;
    int audio_device_speaker_volume_available;
    double audio_device_speaker_volume;
    uint64_t local_dtmf_feedback_start_count;
    uint64_t local_dtmf_feedback_mix_call_count;
    uint64_t local_dtmf_feedback_mixed_frame_count;
    uint64_t local_dtmf_feedback_unsupported_format_count;
    uint32_t local_dtmf_feedback_last_sample_rate;
    uint32_t local_dtmf_feedback_last_channels;
    uint32_t local_dtmf_feedback_last_bytes_per_sample;
    double local_dtmf_feedback_peak_level;
    int local_dtmf_feedback_active;
    int ice_server_count;
    DinoXWebrtcPeerConnectionState peer_connection_state;
    DinoXWebrtcIceConnectionState ice_connection_state;
    DinoXWebrtcNetworkPolicy network_policy;
    int audio_sender_bitrate_cap_bps;
    int audio_sender_adaptive_ptime;
    int audio_sender_policy_applied;
} DinoXWebrtcSessionState;

/**
 * Outgoing-camera effect selected for a logical local-video pipeline.
 *
 * Callers must use the capability mask instead of assuming that a declared
 * value is available. NONE with neutral adjustments/background/framing is the
 * exact passthrough path. All other selections are opt-in camera effects.
 */
typedef enum {
    DINOX_WEBRTC_VIDEO_EFFECT_NONE = 0,
    DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE = 1,
    DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE = 2,
    DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE = 3,
    DINOX_WEBRTC_VIDEO_EFFECT_SEPIA = 4,
    DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK = 5,
    DINOX_WEBRTC_VIDEO_EFFECT_DREAMY = 6,
    DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT = 7,
    DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE = 8,
    DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV = 9,
    DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS = 10,
    DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE = 11,
    DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER = 12,
} DinoXWebrtcVideoEffectType;

typedef enum {
    DINOX_WEBRTC_VIDEO_BACKGROUND_NONE = 0,
    DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR = 1,
    DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID = 2,
    DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE = 3,
} DinoXWebrtcVideoBackgroundMode;

typedef enum {
    DINOX_WEBRTC_VIDEO_FRAMING_NONE = 0,
    DINOX_WEBRTC_VIDEO_FRAMING_AUTO = 1,
} DinoXWebrtcVideoFramingMode;

typedef enum {
    DINOX_WEBRTC_BACKGROUND_RGB888 = 0,
    DINOX_WEBRTC_BACKGROUND_RGBA8888 = 1,
} DinoXWebrtcBackgroundPixelFormat;
typedef enum {
    DINOX_WEBRTC_BACKGROUND_BUILTIN_NONE = 0,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_LIVING_ROOM = 1,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_OFFICE = 2,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_CAFE = 3,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_STONES = 4,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_FOOD = 5,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_ABSTRACT = 6,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_BEACH = 7,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_SUNSET = 8,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_CELEBRATION = 9,
    DINOX_WEBRTC_BACKGROUND_BUILTIN_FOREST = 10,
} DinoXWebrtcBackgroundBuiltin;

#define DINOX_WEBRTC_VIDEO_ADJUSTMENT_BRIGHTNESS UINT32_C(1)
#define DINOX_WEBRTC_VIDEO_ADJUSTMENT_CONTRAST UINT32_C(2)
#define DINOX_WEBRTC_VIDEO_ADJUSTMENT_SATURATION UINT32_C(4)
#define DINOX_WEBRTC_VIDEO_ADJUSTMENT_SHARPNESS UINT32_C(8)

typedef enum {
    DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO = 0,
} DinoXWebrtcVideoEffectQuality;

typedef enum {
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_IDLE = 0,
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_ACCEPTED = 1,
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED = 2,
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_UNAVAILABLE = 3,
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_DEGRADED = 4,
    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_FAILED = 5,
} DinoXWebrtcVideoEffectApplicationState;

#define DINOX_WEBRTC_VIDEO_PIPELINE_MAX_SUBSCRIBERS UINT32_C(8)

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcVideoEffectType effect_type;
    DinoXWebrtcVideoEffectQuality quality;
    uint32_t preset_id;
    /* Opaque, nonzero staged registry ID only with IMAGE; never a file path. */
    uint32_t asset_id;
    uint32_t reserved;
    /* Signed percentage deltas, -100..100; zero preserves existing pixels.
     * Brightness shifts by this percentage of the nominal Y span. Contrast
     * and saturation use multipliers (100 + delta) / 100. */
    int32_t brightness;
    int32_t contrast;
    int32_t saturation;
    /* Luma sharpening amount, 0..100; zero disables sharpening. */
    int32_t sharpness;
    DinoXWebrtcVideoBackgroundMode background_mode;
    /* BLUR amount 0..100; zero for NONE, SOLID and IMAGE. */
    int32_t background_strength;
    /* 0xRRGGBB, only with SOLID; zero for other background modes. */
    uint32_t background_color_rgb;
    DinoXWebrtcVideoFramingMode framing_mode;
    /* Independent opt-in selections; capability bit0 always denotes Off.
     * Glasses: 0 Off, 1 sunglasses, 2 round, 3 rectangular.
     * Hats: 0 Off, 1 cap, 2 cowboy, 3 top hat.
     * Beards: 0 Off, 1 moustache, 2 goatee, 3 full beard.
     * Accessory: 0 Off, 1 puppy, 2 karaoke microphone. */
    uint32_t glasses_style;
    uint32_t hat_style;
    uint32_t beard_style;
    uint32_t face_accessory;
    uint32_t touch_up; /* 0 Off, 1 On */
    uint32_t low_light; /* 0 Off, 1 On */
    /* 0 Off, 1 fireworks, 2 confetti, 3 stars, 4 football. */
    uint32_t scene_effect;
} DinoXWebrtcVideoEffectConfig;

typedef struct {
    unsigned int abi_version;
    uint64_t supported_effect_mask;
    uint64_t supported_quality_mask;
    uint32_t max_subscribers;
    int shared_pipeline_supported;
    int preview_publisher_supported;
    uint32_t reserved;
    uint32_t supported_adjustment_mask;
    uint32_t supported_background_mask;
    int auto_framing_supported;
    uint32_t supported_glasses_mask;
    uint32_t supported_hat_mask;
    uint32_t supported_beard_mask;
    uint32_t supported_face_accessory_mask;
    uint32_t supported_scene_effect_mask;
    uint32_t touch_up_supported;
    uint32_t low_light_supported;
} DinoXWebrtcVideoEffectCapabilities;

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcVideoEffectApplicationState application_state;
    uint64_t pipeline_id;
    uint64_t pipeline_generation;
    uint64_t logical_call_id;
    uint64_t accepted_revision;
    uint64_t applied_revision;
    DinoXWebrtcVideoEffectType effect_type;
    DinoXWebrtcVideoEffectQuality quality;
    uint32_t preset_id;
    uint32_t asset_id;
    uint32_t subscriber_count;
    uint32_t reserved;
    uint64_t preview_subscriber_id;
    uint64_t preview_subscriber_generation;
    int32_t brightness;
    int32_t contrast;
    int32_t saturation;
    int32_t sharpness;
    DinoXWebrtcVideoBackgroundMode background_mode;
    int32_t background_strength;
    uint32_t background_color_rgb;
    DinoXWebrtcVideoFramingMode framing_mode;
    uint32_t glasses_style;
    uint32_t hat_style;
    uint32_t beard_style;
    uint32_t face_accessory;
    uint32_t touch_up;
    uint32_t low_light;
    uint32_t scene_effect;
} DinoXWebrtcVideoPipelineState;

/**
 * Bounded aggregate effect diagnostics. A fully neutral config never touches a video frame,
 * starts no effect thread and owns no effect buffer. Processing counters are
 * cumulative for the pipeline lifetime. Active counts are logical processing
 * activity and return to zero after Off/Degraded; they do not prove thread or
 * child-process quiescence. Owned pixel/transport bytes include retained buffers
 * until actual release, including cancellation/reap; external model process RAM,
 * allocator overhead and caller-owned camera/output buffers are not measured.
 * loaded_model_bytes=0 means not measured, not proof that no model is resident.
 */
typedef struct {
    unsigned int abi_version;
    uint32_t active_quality_tier;
    uint64_t captured;
    uint64_t enqueued;
    uint64_t processed;
    uint64_t bypassed;
    uint64_t queue_replaced;
    uint64_t failed;
    uint64_t watchdog_bypass;
    uint64_t quality_downgrade;
    uint64_t processing_time_total_us;
    uint64_t processing_time_max_us;
    uint64_t processing_time_p95_us;
    uint64_t processing_time_p99_us;
    uint64_t last_completed_monotonic_us;
    uint64_t stale_result_age_us;
    uint64_t loaded_model_bytes;
    uint64_t effect_owned_allocated_bytes;
    uint64_t configuration_request_count;
    uint64_t frame_copy_count;
    uint32_t logical_pipeline_count;
    uint32_t subscriber_count;
    uint32_t effect_thread_count;
    uint32_t effect_handle_count;
    uint32_t effect_mapping_count;
    uint32_t reserved;
} DinoXWebrtcVideoEffectDiagnostics;

/*
 * The state pointer is valid only for the duration of the callback. Callers
 * must copy it and marshal UI work to their main context. Freeing `pipeline`
 * from this callback is supported; other synchronous pipeline operations from
 * inside the callback are not re-entrant and must be scheduled after return.
 */
typedef void (*DinoXWebrtcVideoPipelineStateCallback)(
    DinoXWebrtcVideoPipeline* pipeline,
    const DinoXWebrtcVideoPipelineState* state,
    void* user_data);

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcVideoPipelineStateCallback on_state_changed;
} DinoXWebrtcVideoPipelineCallbacks;

typedef enum {
    DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO = 0,
    DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO = 1,
} DinoXWebrtcMediaRecorderKind;

typedef enum {
    DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE = 0,
    DINOX_WEBRTC_MEDIA_RECORDER_STATE_STARTING = 1,
    DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING = 2,
    DINOX_WEBRTC_MEDIA_RECORDER_STATE_FINALIZING = 3,
    DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED = 4,
} DinoXWebrtcMediaRecorderState;

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcMediaRecorderKind kind;
    const char* output_path;
    const char* mime_type;
    int width;
    int height;
    int max_fps;
    const char* video_device_unique_id;
    int include_audio_track;
} DinoXWebrtcMediaRecorderConfig;

typedef void (*DinoXWebrtcMediaRecorderEventCallback)(
    DinoXWebrtcMediaRecorder* recorder,
    void* user_data);

typedef void (*DinoXWebrtcMediaRecorderErrorCallback)(
    DinoXWebrtcMediaRecorder* recorder,
    DinoXWebrtcStatus status,
    const char* message,
    void* user_data);

/**
 * Delivers one recorder PCM frame as copied little-endian PCM memory.
 *
 * The frame memory is owned by the native wrapper and is valid only during the
 * callback. Bindings must copy it before returning. The callback can be emitted
 * off the UI thread; UI code must marshal it to the UI/main thread.
 */
typedef void (*DinoXWebrtcMediaRecorderAudioFrameCallback)(
    DinoXWebrtcMediaRecorder* recorder,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    uint64_t frame_id,
    void* user_data);

/**
 * Delivers one recorder preview/video frame as copied BGRA-compatible memory.
 *
 * The frame memory is owned by the native wrapper and is valid only during the
 * callback. Bindings must copy it before returning. The callback can be emitted
 * off the UI thread; UI code must marshal it to the UI/main thread.
 */
typedef void (*DinoXWebrtcMediaRecorderVideoFrameCallback)(
    DinoXWebrtcMediaRecorder* recorder,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data);

typedef struct {
    unsigned int abi_version;
    DinoXWebrtcMediaRecorderEventCallback on_started;
    DinoXWebrtcMediaRecorderEventCallback on_stopped;
    DinoXWebrtcMediaRecorderErrorCallback on_error;
    DinoXWebrtcMediaRecorderAudioFrameCallback on_audio_frame;
    DinoXWebrtcMediaRecorderVideoFrameCallback on_video_frame;
} DinoXWebrtcMediaRecorderCallbacks;

DINOX_WEBRTC_API const DinoXWebrtcBuildInfo* dinox_webrtc_get_build_info(void);
DINOX_WEBRTC_API const char* dinox_webrtc_status_to_string(DinoXWebrtcStatus status);

DINOX_WEBRTC_API DinoXWebrtcSessionConfig dinox_webrtc_session_config_default(void);
DINOX_WEBRTC_API DinoXWebrtcCallbacks dinox_webrtc_callbacks_default(void);
DINOX_WEBRTC_API DinoXWebrtcMediaRecorderConfig dinox_webrtc_media_recorder_config_default(void);
DINOX_WEBRTC_API DinoXWebrtcMediaRecorderCallbacks dinox_webrtc_media_recorder_callbacks_default(void);
DINOX_WEBRTC_API DinoXWebrtcVideoEffectConfig dinox_webrtc_video_effect_config_default(void);
DINOX_WEBRTC_API DinoXWebrtcVideoPipelineCallbacks dinox_webrtc_video_pipeline_callbacks_default(void);

DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_new(DinoXWebrtcContext** out_context);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_new_with_audio_device_mode(
    DinoXWebrtcAudioDeviceMode audio_device_mode,
    DinoXWebrtcContext** out_context);
DINOX_WEBRTC_API void dinox_webrtc_context_free(DinoXWebrtcContext* context);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_count(
    DinoXWebrtcContext* context,
    int incoming,
    int* out_count);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_name(
    DinoXWebrtcContext* context,
    int incoming,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_guid,
    size_t out_guid_size);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_set_audio_device(
    DinoXWebrtcContext* context,
    int incoming,
    int index);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_audio_device_volume(
    DinoXWebrtcContext* context,
    int incoming,
    double* out_volume,
    int* out_available);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_set_audio_device_volume(
    DinoXWebrtcContext* context,
    int incoming,
    double volume);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_play_test_tone(
    DinoXWebrtcContext* context,
    char digit,
    unsigned int duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_play_audio_test_clip(
    DinoXWebrtcContext* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    unsigned int* out_duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_stop_audio_test_playout(
    DinoXWebrtcContext* context);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_start(
    DinoXWebrtcContext* context,
    int sample_rate,
    int channels,
    int bytes_per_sample);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_push(
    DinoXWebrtcContext* context,
    const uint8_t* pcm_data,
    size_t byte_count,
    unsigned int* out_queued_duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_set_paused(
    DinoXWebrtcContext* context,
    int paused);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_flush(
    DinoXWebrtcContext* context);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_finish(
    DinoXWebrtcContext* context,
    unsigned int* out_queued_duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_media_audio_playout_stop(
    DinoXWebrtcContext* context);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_video_device_count(
    DinoXWebrtcContext* context,
    int* out_count);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_video_device_name(
    DinoXWebrtcContext* context,
    int index,
    char* out_name,
    size_t out_name_size,
    char* out_unique_id,
    size_t out_unique_id_size,
    char* out_product_id,
    size_t out_product_id_size);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_get_video_effect_capabilities(
    DinoXWebrtcContext* context,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities);

/** Test-only worker fault injection. Requires DINOX_WEBRTC_ENABLE_TEST_FAULTS=1. */
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_context_inject_worker_failure_for_test(
    DinoXWebrtcContext* context,
    int failure_kind);

/** Internal worker bootstrap. Applications must never call this entry point. */
DINOX_WEBRTC_API void dinox_webrtc_internal_worker_enter(void);

DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_new(
    DinoXWebrtcContext* context,
    const DinoXWebrtcSessionConfig* config,
    const DinoXWebrtcCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcSession** out_session);
DINOX_WEBRTC_API void dinox_webrtc_session_free(DinoXWebrtcSession* session);

DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_add_ice_server(
    DinoXWebrtcSession* session,
    const char* url,
    const char* username,
    const char* credential);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_create_offer(DinoXWebrtcSession* session);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_create_answer(DinoXWebrtcSession* session);
/**
 * MUJI-only two-phase negotiation. Preparation requires the optional prepared
 * callback and never changes the local PeerConnection description. Commit the
 * projected SDP with set_local_description; on_local_description confirms its
 * successful installation. The automatic create_offer/create_answer APIs are
 * unchanged and must not be mixed with a pending preparation.
 */
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_prepare_local_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_set_local_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const char* sdp);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_set_remote_description(
    DinoXWebrtcSession* session,
    DinoXWebrtcSdpType type,
    const char* sdp);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_add_remote_ice_candidate(
    DinoXWebrtcSession* session,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_set_local_audio_enabled(
    DinoXWebrtcSession* session,
    int enabled);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_set_local_video_enabled(
    DinoXWebrtcSession* session,
    int enabled);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_send_dtmf(
    DinoXWebrtcSession* session,
    char digit,
    unsigned int duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_play_local_dtmf_feedback(
    DinoXWebrtcSession* session,
    char digit,
    unsigned int duration_ms);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_push_synthetic_video_frame(
    DinoXWebrtcSession* session,
    int width,
    int height);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_start_video_capture(
    DinoXWebrtcSession* session,
    const char* device_unique_id,
    int width,
    int height,
    int max_fps);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_stop_video_capture(
    DinoXWebrtcSession* session);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_get_state(
    DinoXWebrtcSession* session,
    DinoXWebrtcSessionState* out_state);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_session_close(DinoXWebrtcSession* session);

DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_new(
    DinoXWebrtcContext* context,
    uint64_t logical_call_id,
    const DinoXWebrtcVideoPipelineCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcVideoPipeline** out_pipeline);
DINOX_WEBRTC_API void dinox_webrtc_video_pipeline_free(DinoXWebrtcVideoPipeline* pipeline);
/** Controller lane only: call asynchronously from GTK/JNI; never capture/audio/UI.
 * Bounds: side<=1920, pixels<=2073600, explicit padded buffer<=8MiB. RGBA is
 * straight alpha matted over303030. Copies finish before return. IDs are opaque,
 * positive, process-monotone and never paths; out_asset_id changes only on OK.
 * prepare converts the latest source range/matrix, or Limited/BT601 before capture.
 * A format miss in capture requests bounded async preparation and conceals until
 * ready. release invalidates lookup, retaining existing immutable reader leases.
 * INVALID_ARGUMENT means invalid geometry/format/choice; NOT_READY means absent,
 * retired/exhausted/full registry or closed pipeline. No config revision changes.
 */
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_upload(
    DinoXWebrtcVideoPipeline* pipeline, uint32_t width, uint32_t height,
    uint32_t stride, DinoXWebrtcBackgroundPixelFormat format,
    const uint8_t* pixels, size_t pixel_bytes, uint32_t* out_asset_id);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_builtin(
    DinoXWebrtcVideoPipeline* pipeline, DinoXWebrtcBackgroundBuiltin choice,
    uint32_t* out_asset_id);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_prepare(
    DinoXWebrtcVideoPipeline* pipeline, uint32_t asset_id);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_background_release(
    DinoXWebrtcVideoPipeline* pipeline, uint32_t asset_id);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_attach_session(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcSession* session,
    int preview_publisher);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_detach_session(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcSession* session);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_set_config(
    DinoXWebrtcVideoPipeline* pipeline,
    const DinoXWebrtcVideoEffectConfig* config,
    uint64_t* out_revision);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_get_state(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcVideoPipelineState* out_state);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_video_pipeline_get_diagnostics(
    DinoXWebrtcVideoPipeline* pipeline,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics);

DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_new(
    DinoXWebrtcContext* context,
    const DinoXWebrtcMediaRecorderConfig* config,
    const DinoXWebrtcMediaRecorderCallbacks* callbacks,
    void* user_data,
    DinoXWebrtcMediaRecorder** out_recorder);
DINOX_WEBRTC_API void dinox_webrtc_media_recorder_free(DinoXWebrtcMediaRecorder* recorder);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_start(DinoXWebrtcMediaRecorder* recorder);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_stop(DinoXWebrtcMediaRecorder* recorder);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_cancel(DinoXWebrtcMediaRecorder* recorder);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_push_synthetic_frame(DinoXWebrtcMediaRecorder* recorder);
DINOX_WEBRTC_API DinoXWebrtcStatus dinox_webrtc_media_recorder_get_state(
    DinoXWebrtcMediaRecorder* recorder,
    DinoXWebrtcMediaRecorderState* out_state);

#ifdef __cplusplus
}
#endif

#endif
