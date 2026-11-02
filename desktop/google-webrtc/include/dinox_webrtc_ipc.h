#ifndef DINOX_WEBRTC_IPC_H
#define DINOX_WEBRTC_IPC_H

#include <stddef.h>
#include <stdint.h>

#include "dinox_webrtc.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DINOX_WEBRTC_IPC_MAGIC UINT32_C(0x44585752)
#define DINOX_WEBRTC_IPC_PROTOCOL_VERSION UINT16_C(10)
#define DINOX_WEBRTC_IPC_HEADER_SIZE UINT16_C(48)
#define DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD UINT32_C(1048576)
#define DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE UINT16_C(44)
#define DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE UINT16_C(84)
#define DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE UINT16_C(80)
#define DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE UINT16_C(148)
#define DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE UINT16_C(176)
#define DINOX_WEBRTC_IPC_VIDEO_PIPELINE_ATTACHMENT_SIZE UINT16_C(28)
#define DINOX_WEBRTC_IPC_VIDEO_PIPELINE_DETACHMENT_SIZE UINT16_C(24)

typedef enum DinoXWebrtcIpcMessageType {
    DINOX_WEBRTC_IPC_MESSAGE_HELLO = 1,
    DINOX_WEBRTC_IPC_MESSAGE_HELLO_REPLY = 2,
    DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN = 3,
    DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE = 10,
    DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CLOSE = 11,
    DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_LIST = 20,
    DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_SELECT = 21,
    DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_GET = 22,
    DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_SET = 23,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_DEVICE_LIST = 24,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_EFFECT_CAPABILITIES_GET = 25,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE = 30,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE = 31,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_ICE_SERVER = 32,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER = 33,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_ANSWER = 34,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_REMOTE_DESCRIPTION = 35,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_REMOTE_CANDIDATE = 36,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_AUDIO_ENABLED = 37,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_VIDEO_ENABLED = 38,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_SEND_DTMF = 39,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_PLAY_DTMF_FEEDBACK = 40,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_START = 41,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_STOP = 42,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET = 43,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO = 44,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_PREPARE_LOCAL_DESCRIPTION = 45,
    DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION = 46,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE = 50,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_START = 51,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STOP = 52,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CANCEL = 53,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_PUSH_SYNTHETIC = 54,
    DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STATE_GET = 55,
    DINOX_WEBRTC_IPC_MESSAGE_TEST_TONE_PLAY = 60,
    DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_CLIP_PLAY = 61,
    DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_PLAYOUT_STOP = 62,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_START = 63,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PUSH = 64,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PAUSE = 65,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FLUSH = 66,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FINISH = 67,
    DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_STOP = 68,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE = 70,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY = 71,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH = 72,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH = 73,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG = 74,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET = 75,
    DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DIAGNOSTICS_GET = 76,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN = 77,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK = 78,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT = 79,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT = 80,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_BUILTIN = 81,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE = 82,
    DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE = 83,
    DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_ABORT = 90,
    DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_HANG = 91,
    DINOX_WEBRTC_IPC_MESSAGE_REPLY = 100,
    DINOX_WEBRTC_IPC_MESSAGE_ERROR = 101,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION = 110,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_REMOTE_DESCRIPTION_SET = 111,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_CANDIDATE = 112,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_GATHERING_COMPLETE = 113,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_SESSION_ERROR = 114,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_FRAME = 115,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME = 116,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE = 117,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION_PREPARED = 118,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STARTED = 120,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STOPPED = 121,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_ERROR = 122,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_AUDIO_FRAME = 123,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME = 124,
    DINOX_WEBRTC_IPC_MESSAGE_EVENT_WORKER_STOPPING = 130
} DinoXWebrtcIpcMessageType;

typedef enum DinoXWebrtcIpcFlags {
    DINOX_WEBRTC_IPC_FLAG_NONE = 0,
    DINOX_WEBRTC_IPC_FLAG_REPLY = 1u << 0,
    DINOX_WEBRTC_IPC_FLAG_EVENT = 1u << 1,
    DINOX_WEBRTC_IPC_FLAG_ERROR = 1u << 2,
    DINOX_WEBRTC_IPC_FLAG_ONEWAY = 1u << 3
} DinoXWebrtcIpcFlags;

typedef enum DinoXWebrtcIpcValidationStatus {
    DINOX_WEBRTC_IPC_VALIDATION_OK = 0,
    DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT = 1,
    DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED = 2,
    DINOX_WEBRTC_IPC_VALIDATION_BAD_MAGIC = 3,
    DINOX_WEBRTC_IPC_VALIDATION_UNSUPPORTED_VERSION = 4,
    DINOX_WEBRTC_IPC_VALIDATION_UNKNOWN_MESSAGE = 5,
    DINOX_WEBRTC_IPC_VALIDATION_INVALID_FLAGS = 6,
    DINOX_WEBRTC_IPC_VALIDATION_INVALID_REQUEST_ID = 7,
    DINOX_WEBRTC_IPC_VALIDATION_INVALID_SESSION_ID = 8,
    DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION = 9,
    DINOX_WEBRTC_IPC_VALIDATION_PAYLOAD_TOO_LARGE = 10,
    DINOX_WEBRTC_IPC_VALIDATION_FRAME_SIZE_MISMATCH = 11
} DinoXWebrtcIpcValidationStatus;

typedef struct DinoXWebrtcIpcHeader {
    uint32_t magic;
    uint16_t protocol_version;
    uint16_t header_size;
    uint32_t message_type;
    uint32_t flags;
    uint64_t request_id;
    uint64_t session_id;
    uint64_t generation;
    uint32_t payload_size;
    uint32_t reserved;
} DinoXWebrtcIpcHeader;

typedef struct DinoXWebrtcIpcSessionConfig {
    uint32_t abi_version;
    uint32_t audio_enabled;
    uint32_t video_enabled;
    uint32_t audio_direction;
    uint32_t video_direction;
    uint32_t defer_audio_transceiver_until_answer;
    uint32_t defer_video_transceiver_until_answer;
    int32_t ice_candidate_pool_size;
    uint32_t max_bundle;
    uint32_t network_policy;
    uint32_t reserved;
} DinoXWebrtcIpcSessionConfig;

DINOX_WEBRTC_API DinoXWebrtcIpcHeader dinox_webrtc_ipc_header_default(
    DinoXWebrtcIpcMessageType message_type,
    uint64_t request_id,
    uint64_t session_id,
    uint64_t generation,
    uint32_t payload_size);
DINOX_WEBRTC_API int dinox_webrtc_ipc_message_type_is_known(uint32_t message_type);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_validate_header(
    const DinoXWebrtcIpcHeader* header,
    size_t complete_frame_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_header(
    const DinoXWebrtcIpcHeader* header,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_header(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcIpcHeader* out_header);
DINOX_WEBRTC_API const char* dinox_webrtc_ipc_validation_status_to_string(
    DinoXWebrtcIpcValidationStatus status);
DINOX_WEBRTC_API size_t dinox_webrtc_ipc_build_handshake(char* output, size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_session_config(
    const DinoXWebrtcIpcSessionConfig* config,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_session_config(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcIpcSessionConfig* out_config);
DINOX_WEBRTC_API size_t dinox_webrtc_ipc_session_state_size(void);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_session_state(
    const DinoXWebrtcSessionState* state,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_session_state(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcSessionState* out_state);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_config(
    const DinoXWebrtcVideoEffectConfig* config,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_config(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectConfig* out_config);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_capabilities(
    const DinoXWebrtcVideoEffectCapabilities* capabilities,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_capabilities(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_pipeline_state(
    const DinoXWebrtcVideoPipelineState* state,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_pipeline_state(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoPipelineState* out_state);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_diagnostics(
    const DinoXWebrtcVideoEffectDiagnostics* diagnostics,
    uint8_t* output,
    size_t output_size);
DINOX_WEBRTC_API DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_diagnostics(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics);

#ifdef __cplusplus
}
#endif

#endif
