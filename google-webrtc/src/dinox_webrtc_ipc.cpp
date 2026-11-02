#include "dinox_webrtc_ipc.h"
#include "dinox_webrtc_video_effect_config.hpp"

#include <cstdio>
#include <cstring>
#include <limits>

#ifndef DINOX_WEBRTC_MILESTONE
#define DINOX_WEBRTC_MILESTONE 0
#endif

#ifndef DINOX_WEBRTC_COMMIT
#define DINOX_WEBRTC_COMMIT "unknown"
#endif

#ifndef DINOX_WEBRTC_ARTIFACT_ABI
#define DINOX_WEBRTC_ARTIFACT_ABI "unknown"
#endif

namespace {

void write_u16_le(uint8_t* output, uint16_t value) {
    output[0] = static_cast<uint8_t>(value & 0xffu);
    output[1] = static_cast<uint8_t>((value >> 8) & 0xffu);
}

void write_u32_le(uint8_t* output, uint32_t value) {
    for (unsigned int byte = 0; byte < 4; ++byte) {
        output[byte] = static_cast<uint8_t>((value >> (byte * 8)) & 0xffu);
    }
}

void write_u64_le(uint8_t* output, uint64_t value) {
    for (unsigned int byte = 0; byte < 8; ++byte) {
        output[byte] = static_cast<uint8_t>((value >> (byte * 8)) & 0xffu);
    }
}

uint16_t read_u16_le(const uint8_t* input) {
    return static_cast<uint16_t>(input[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(input[1]) << 8);
}

uint32_t read_u32_le(const uint8_t* input) {
    uint32_t value = 0;
    for (unsigned int byte = 0; byte < 4; ++byte) {
        value |= static_cast<uint32_t>(input[byte]) << (byte * 8);
    }
    return value;
}

int32_t read_i32_le(const uint8_t* input) {
    const uint32_t value = read_u32_le(input);
    return static_cast<int32_t>(value <= INT32_MAX ? static_cast<int64_t>(value) :
        static_cast<int64_t>(value) - (INT64_C(1) << 32));
}

template <typename Config>
void write_video_effect_adjustments(const Config& config, uint8_t* output) {
    write_u32_le(output + 0, static_cast<uint32_t>(config.brightness));
    write_u32_le(output + 4, static_cast<uint32_t>(config.contrast));
    write_u32_le(output + 8, static_cast<uint32_t>(config.saturation));
    write_u32_le(output + 12, static_cast<uint32_t>(config.sharpness));
    write_u32_le(output + 16, static_cast<uint32_t>(config.background_mode));
    write_u32_le(output + 20, static_cast<uint32_t>(config.background_strength));
    write_u32_le(output + 24, config.background_color_rgb);
    write_u32_le(output + 28, static_cast<uint32_t>(config.framing_mode));
    write_u32_le(output + 32, config.glasses_style);
    write_u32_le(output + 36, config.hat_style);
    write_u32_le(output + 40, config.beard_style);
    write_u32_le(output + 44, config.face_accessory);
    write_u32_le(output + 48, config.touch_up);
    write_u32_le(output + 52, config.low_light);
    write_u32_le(output + 56, config.scene_effect);
}

template <typename Config>
void read_video_effect_adjustments(const uint8_t* input, Config* config) {
    config->brightness = read_i32_le(input + 0);
    config->contrast = read_i32_le(input + 4);
    config->saturation = read_i32_le(input + 8);
    config->sharpness = read_i32_le(input + 12);
    config->background_mode =
        static_cast<DinoXWebrtcVideoBackgroundMode>(read_u32_le(input + 16));
    config->background_strength = read_i32_le(input + 20);
    config->background_color_rgb = read_u32_le(input + 24);
    config->framing_mode =
        static_cast<DinoXWebrtcVideoFramingMode>(read_u32_le(input + 28));
    config->glasses_style = read_u32_le(input + 32);
    config->hat_style = read_u32_le(input + 36);
    config->beard_style = read_u32_le(input + 40);
    config->face_accessory = read_u32_le(input + 44);
    config->touch_up = read_u32_le(input + 48);
    config->low_light = read_u32_le(input + 52);
    config->scene_effect = read_u32_le(input + 56);
}

uint64_t read_u64_le(const uint8_t* input) {
    uint64_t value = 0;
    for (unsigned int byte = 0; byte < 8; ++byte) {
        value |= static_cast<uint64_t>(input[byte]) << (byte * 8);
    }
    return value;
}

bool valid_direction(uint32_t direction) {
    return direction <= static_cast<uint32_t>(DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE);
}

bool valid_video_effect_type(uint32_t effect_type) {
    return effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_NONE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_SEPIA) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_DREAMY) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE) ||
        effect_type == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER);
}

bool valid_video_effect_quality(uint32_t quality) {
    return quality == static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO);
}

bool valid_video_effect_application_state(uint32_t state) {
    return state <= static_cast<uint32_t>(DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_FAILED);
}

bool message_requires_session(uint32_t type) {
    return (type >= DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE &&
            type <= DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION) ||
        (type >= DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE &&
            type <= DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STATE_GET) ||
        (type >= DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE &&
            type <= DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE) ||
        (type >= DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION &&
            type <= DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME);
}

bool message_is_event(uint32_t type) {
    return type >= DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION &&
        type <= DINOX_WEBRTC_IPC_MESSAGE_EVENT_WORKER_STOPPING;
}

bool message_is_reply(uint32_t type) {
    return type == DINOX_WEBRTC_IPC_MESSAGE_HELLO_REPLY ||
        type == DINOX_WEBRTC_IPC_MESSAGE_REPLY ||
        type == DINOX_WEBRTC_IPC_MESSAGE_ERROR;
}

}  // namespace

extern "C" DinoXWebrtcIpcHeader dinox_webrtc_ipc_header_default(
    DinoXWebrtcIpcMessageType message_type,
    uint64_t request_id,
    uint64_t session_id,
    uint64_t generation,
    uint32_t payload_size) {
    DinoXWebrtcIpcHeader header = {};
    header.magic = DINOX_WEBRTC_IPC_MAGIC;
    header.protocol_version = DINOX_WEBRTC_IPC_PROTOCOL_VERSION;
    header.header_size = DINOX_WEBRTC_IPC_HEADER_SIZE;
    header.message_type = static_cast<uint32_t>(message_type);
    header.request_id = request_id;
    header.session_id = session_id;
    header.generation = generation;
    header.payload_size = payload_size;
    if (message_is_event(header.message_type)) {
        header.flags = DINOX_WEBRTC_IPC_FLAG_EVENT;
    } else if (message_is_reply(header.message_type)) {
        header.flags = DINOX_WEBRTC_IPC_FLAG_REPLY;
        if (header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR) {
            header.flags |= DINOX_WEBRTC_IPC_FLAG_ERROR;
        }
    }
    return header;
}

extern "C" int dinox_webrtc_ipc_message_type_is_known(uint32_t type) {
    switch (type) {
        case DINOX_WEBRTC_IPC_MESSAGE_HELLO:
        case DINOX_WEBRTC_IPC_MESSAGE_HELLO_REPLY:
        case DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN:
        case DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE:
        case DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CLOSE:
        case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_LIST:
        case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_SELECT:
        case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_SET:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_DEVICE_LIST:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_EFFECT_CAPABILITIES_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_ICE_SERVER:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PREPARE_LOCAL_DESCRIPTION:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_ANSWER:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_REMOTE_DESCRIPTION:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_REMOTE_CANDIDATE:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_AUDIO_ENABLED:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_VIDEO_ENABLED:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SEND_DTMF:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PLAY_DTMF_FEEDBACK:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_START:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_STOP:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_START:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STOP:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CANCEL:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_PUSH_SYNTHETIC:
        case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STATE_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_TEST_TONE_PLAY:
        case DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_CLIP_PLAY:
        case DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_PLAYOUT_STOP:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_START:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PUSH:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PAUSE:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FLUSH:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FINISH:
        case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_STOP:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DIAGNOSTICS_GET:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_BUILTIN:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE:
        case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE:
        case DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_ABORT:
        case DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_HANG:
        case DINOX_WEBRTC_IPC_MESSAGE_REPLY:
        case DINOX_WEBRTC_IPC_MESSAGE_ERROR:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION_PREPARED:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_REMOTE_DESCRIPTION_SET:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_CANDIDATE:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_GATHERING_COMPLETE:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_SESSION_ERROR:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_FRAME:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STARTED:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STOPPED:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_ERROR:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_AUDIO_FRAME:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME:
        case DINOX_WEBRTC_IPC_MESSAGE_EVENT_WORKER_STOPPING:
            return 1;
        default:
            return 0;
    }
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_validate_header(
    const DinoXWebrtcIpcHeader* header,
    size_t complete_frame_size) {
    if (header == nullptr) return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    if (header->magic != DINOX_WEBRTC_IPC_MAGIC) return DINOX_WEBRTC_IPC_VALIDATION_BAD_MAGIC;
    if (header->protocol_version != DINOX_WEBRTC_IPC_PROTOCOL_VERSION ||
            header->header_size != DINOX_WEBRTC_IPC_HEADER_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_UNSUPPORTED_VERSION;
    }
    if (!dinox_webrtc_ipc_message_type_is_known(header->message_type)) {
        return DINOX_WEBRTC_IPC_VALIDATION_UNKNOWN_MESSAGE;
    }
    const bool event = message_is_event(header->message_type);
    const bool reply = message_is_reply(header->message_type);
    const bool error = header->message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR;
    const uint32_t allowed_flags = DINOX_WEBRTC_IPC_FLAG_REPLY |
        DINOX_WEBRTC_IPC_FLAG_EVENT |
        DINOX_WEBRTC_IPC_FLAG_ERROR |
        DINOX_WEBRTC_IPC_FLAG_ONEWAY;
    if ((header->flags & ~allowed_flags) != 0 ||
            (event && header->flags != DINOX_WEBRTC_IPC_FLAG_EVENT) ||
            (reply && !error && header->flags != DINOX_WEBRTC_IPC_FLAG_REPLY) ||
            (error && header->flags !=
                (DINOX_WEBRTC_IPC_FLAG_REPLY | DINOX_WEBRTC_IPC_FLAG_ERROR)) ||
            (!event && !reply && header->flags != DINOX_WEBRTC_IPC_FLAG_NONE &&
                header->flags != DINOX_WEBRTC_IPC_FLAG_ONEWAY)) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_FLAGS;
    }
    const bool oneway = header->flags == DINOX_WEBRTC_IPC_FLAG_ONEWAY;
    if ((!event && !oneway && header->request_id == 0) ||
            (oneway && header->request_id != 0)) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_REQUEST_ID;
    }
    if (message_requires_session(header->message_type) &&
            (header->session_id == 0 || header->generation == 0)) {
        return header->session_id == 0
            ? DINOX_WEBRTC_IPC_VALIDATION_INVALID_SESSION_ID
            : DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION;
    }
    if (header->payload_size > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD) {
        return DINOX_WEBRTC_IPC_VALIDATION_PAYLOAD_TOO_LARGE;
    }
    if (complete_frame_size != 0) {
        const uint64_t expected = static_cast<uint64_t>(DINOX_WEBRTC_IPC_HEADER_SIZE) +
            static_cast<uint64_t>(header->payload_size);
        if (expected > std::numeric_limits<size_t>::max() ||
                complete_frame_size != static_cast<size_t>(expected)) {
            return DINOX_WEBRTC_IPC_VALIDATION_FRAME_SIZE_MISMATCH;
        }
    }
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_header(
    const DinoXWebrtcIpcHeader* header,
    uint8_t* output,
    size_t output_size) {
    if (header == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_HEADER_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_validate_header(header, 0);
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    write_u32_le(output + 0, header->magic);
    write_u16_le(output + 4, header->protocol_version);
    write_u16_le(output + 6, header->header_size);
    write_u32_le(output + 8, header->message_type);
    write_u32_le(output + 12, header->flags);
    write_u64_le(output + 16, header->request_id);
    write_u64_le(output + 24, header->session_id);
    write_u64_le(output + 32, header->generation);
    write_u32_le(output + 40, header->payload_size);
    write_u32_le(output + 44, 0);
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_header(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcIpcHeader* out_header) {
    if (input == nullptr || out_header == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size < DINOX_WEBRTC_IPC_HEADER_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcIpcHeader header = {};
    header.magic = read_u32_le(input + 0);
    header.protocol_version = read_u16_le(input + 4);
    header.header_size = read_u16_le(input + 6);
    header.message_type = read_u32_le(input + 8);
    header.flags = read_u32_le(input + 12);
    header.request_id = read_u64_le(input + 16);
    header.session_id = read_u64_le(input + 24);
    header.generation = read_u64_le(input + 32);
    header.payload_size = read_u32_le(input + 40);
    header.reserved = read_u32_le(input + 44);
    if (header.reserved != 0) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_FLAGS;
    }
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_validate_header(&header, 0);
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    *out_header = header;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" const char* dinox_webrtc_ipc_validation_status_to_string(
    DinoXWebrtcIpcValidationStatus status) {
    switch (status) {
        case DINOX_WEBRTC_IPC_VALIDATION_OK: return "ok";
        case DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT: return "invalid-argument";
        case DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED: return "truncated";
        case DINOX_WEBRTC_IPC_VALIDATION_BAD_MAGIC: return "bad-magic";
        case DINOX_WEBRTC_IPC_VALIDATION_UNSUPPORTED_VERSION: return "unsupported-version";
        case DINOX_WEBRTC_IPC_VALIDATION_UNKNOWN_MESSAGE: return "unknown-message";
        case DINOX_WEBRTC_IPC_VALIDATION_INVALID_FLAGS: return "invalid-flags";
        case DINOX_WEBRTC_IPC_VALIDATION_INVALID_REQUEST_ID: return "invalid-request-id";
        case DINOX_WEBRTC_IPC_VALIDATION_INVALID_SESSION_ID: return "invalid-session-id";
        case DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION: return "invalid-generation";
        case DINOX_WEBRTC_IPC_VALIDATION_PAYLOAD_TOO_LARGE: return "payload-too-large";
        case DINOX_WEBRTC_IPC_VALIDATION_FRAME_SIZE_MISMATCH: return "frame-size-mismatch";
        default: return "unknown";
    }
}

extern "C" size_t dinox_webrtc_ipc_build_handshake(char* output, size_t output_size) {
    const int required = std::snprintf(
        nullptr,
        0,
        "abi=%u;milestone=%u;commit=%s;artifact=%s",
        DINOX_WEBRTC_ABI_VERSION,
        DINOX_WEBRTC_MILESTONE,
        DINOX_WEBRTC_COMMIT,
        DINOX_WEBRTC_ARTIFACT_ABI);
    if (required < 0) return 0;
    const size_t required_size = static_cast<size_t>(required);
    if (output != nullptr && output_size > required_size) {
        std::snprintf(
            output,
            output_size,
            "abi=%u;milestone=%u;commit=%s;artifact=%s",
            DINOX_WEBRTC_ABI_VERSION,
            DINOX_WEBRTC_MILESTONE,
            DINOX_WEBRTC_COMMIT,
            DINOX_WEBRTC_ARTIFACT_ABI);
    }
    return required_size;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_session_config(
    const DinoXWebrtcIpcSessionConfig* config,
    uint8_t* output,
    size_t output_size) {
    if (config == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    if (config->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            config->audio_enabled > 1 || config->video_enabled > 1 ||
            !valid_direction(config->audio_direction) ||
            !valid_direction(config->video_direction) ||
            config->defer_audio_transceiver_until_answer > 1 ||
            config->defer_video_transceiver_until_answer > 1 ||
            config->ice_candidate_pool_size < 0 ||
            config->ice_candidate_pool_size > 255 ||
            config->max_bundle > 1 ||
            config->network_policy > DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G ||
            config->reserved != 0) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    write_u32_le(output + 0, config->abi_version);
    write_u32_le(output + 4, config->audio_enabled);
    write_u32_le(output + 8, config->video_enabled);
    write_u32_le(output + 12, config->audio_direction);
    write_u32_le(output + 16, config->video_direction);
    write_u32_le(output + 20, config->defer_audio_transceiver_until_answer);
    write_u32_le(output + 24, config->defer_video_transceiver_until_answer);
    write_u32_le(output + 28, static_cast<uint32_t>(config->ice_candidate_pool_size));
    write_u32_le(output + 32, config->max_bundle);
    write_u32_le(output + 36, config->network_policy);
    write_u32_le(output + 40, 0);
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_session_config(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcIpcSessionConfig* out_config) {
    if (input == nullptr || out_config == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size != DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcIpcSessionConfig config = {};
    config.abi_version = read_u32_le(input + 0);
    config.audio_enabled = read_u32_le(input + 4);
    config.video_enabled = read_u32_le(input + 8);
    config.audio_direction = read_u32_le(input + 12);
    config.video_direction = read_u32_le(input + 16);
    config.defer_audio_transceiver_until_answer = read_u32_le(input + 20);
    config.defer_video_transceiver_until_answer = read_u32_le(input + 24);
    config.ice_candidate_pool_size = static_cast<int32_t>(read_u32_le(input + 28));
    config.max_bundle = read_u32_le(input + 32);
    config.network_policy = read_u32_le(input + 36);
    config.reserved = read_u32_le(input + 40);
    uint8_t encoded[DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE] = {};
    DinoXWebrtcIpcValidationStatus validation = dinox_webrtc_ipc_encode_session_config(
        &config,
        encoded,
        sizeof(encoded));
    if (validation != DINOX_WEBRTC_IPC_VALIDATION_OK) return validation;
    *out_config = config;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

#define DINOX_WEBRTC_SESSION_STATE_FIELDS(U32, U64, F64) \
    U32(abi_version) \
    U32(audio_transceiver_count) \
    U32(video_transceiver_count) \
    U32(local_audio_source_attached) \
    U32(local_audio_track_attached) \
    U32(local_audio_track_enabled) \
    U32(local_video_source_attached) \
    U32(local_video_track_attached) \
    U32(local_video_track_enabled) \
    U64(local_video_source_frame_count) \
    U32(local_video_source_last_width) \
    U32(local_video_source_last_height) \
    U32(local_video_capture_running) \
    U64(local_video_capture_frame_count) \
    U32(local_video_capture_last_width) \
    U32(local_video_capture_last_height) \
    U32(remote_audio_receiver_count) \
    U32(remote_video_receiver_count) \
    U32(remote_audio_sink_count) \
    U64(remote_audio_sink_frame_count) \
    U64(remote_audio_sink_sample_count) \
    F64(remote_audio_sink_peak_level) \
    U32(remote_video_sink_count) \
    U64(remote_video_sink_frame_count) \
    U32(remote_video_sink_last_width) \
    U32(remote_video_sink_last_height) \
    U64(inbound_audio_packets_received) \
    U64(inbound_audio_bytes_received) \
    U64(inbound_audio_total_samples_received) \
    U64(inbound_video_packets_received) \
    U64(inbound_video_bytes_received) \
    U64(inbound_video_frames_received) \
    U64(inbound_video_frames_decoded) \
    U32(inbound_video_frame_width) \
    U32(inbound_video_frame_height) \
    U64(outbound_audio_packets_sent) \
    U64(outbound_audio_bytes_sent) \
    F64(outbound_audio_target_bitrate) \
    U64(outbound_video_packets_sent) \
    U64(outbound_video_bytes_sent) \
    U64(outbound_video_frames_sent) \
    U64(outbound_video_frames_encoded) \
    F64(outbound_video_target_bitrate) \
    U32(outbound_video_frame_width) \
    U32(outbound_video_frame_height) \
    F64(inbound_audio_level) \
    F64(source_audio_level) \
    F64(source_audio_total_energy) \
    F64(source_audio_total_duration) \
    U64(stats_report_count) \
    U32(audio_device_initialized) \
    U32(audio_device_playout_initialized) \
    U32(audio_device_recording_initialized) \
    U32(audio_device_playing) \
    U32(audio_device_recording) \
    U64(audio_device_capture_sample_count) \
    U64(audio_device_capture_probe_frame_count) \
    U64(audio_device_capture_probe_sample_count) \
    F64(audio_device_capture_probe_peak_level) \
    U64(audio_device_playout_sample_count) \
    U32(audio_device_microphone_volume_available) \
    F64(audio_device_microphone_volume) \
    U32(audio_device_speaker_volume_available) \
    F64(audio_device_speaker_volume) \
    U64(local_dtmf_feedback_start_count) \
    U64(local_dtmf_feedback_mix_call_count) \
    U64(local_dtmf_feedback_mixed_frame_count) \
    U64(local_dtmf_feedback_unsupported_format_count) \
    U32(local_dtmf_feedback_last_sample_rate) \
    U32(local_dtmf_feedback_last_channels) \
    U32(local_dtmf_feedback_last_bytes_per_sample) \
    F64(local_dtmf_feedback_peak_level) \
    U32(local_dtmf_feedback_active) \
    U32(ice_server_count) \
    U32(peer_connection_state) \
    U32(ice_connection_state) \
    U32(network_policy) \
    U32(audio_sender_bitrate_cap_bps) \
    U32(audio_sender_adaptive_ptime) \
    U32(audio_sender_policy_applied)

extern "C" size_t dinox_webrtc_ipc_session_state_size(void) {
#define DINOX_SIZE_U32(field) + 4
#define DINOX_SIZE_U64(field) + 8
#define DINOX_SIZE_F64(field) + 8
    return 0 DINOX_WEBRTC_SESSION_STATE_FIELDS(DINOX_SIZE_U32, DINOX_SIZE_U64, DINOX_SIZE_F64);
#undef DINOX_SIZE_U32
#undef DINOX_SIZE_U64
#undef DINOX_SIZE_F64
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_session_state(
    const DinoXWebrtcSessionState* state,
    uint8_t* output,
    size_t output_size) {
    if (state == nullptr || output == nullptr) return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    const size_t required = dinox_webrtc_ipc_session_state_size();
    if (output_size < required) return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    if (state->abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    size_t offset = 0;
#define DINOX_WRITE_U32(field) \
    write_u32_le(output + offset, static_cast<uint32_t>(state->field)); offset += 4;
#define DINOX_WRITE_U64(field) \
    write_u64_le(output + offset, static_cast<uint64_t>(state->field)); offset += 8;
#define DINOX_WRITE_F64(field) \
    do { uint64_t bits = 0; static_assert(sizeof(bits) == sizeof(state->field)); \
        std::memcpy(&bits, &state->field, sizeof(bits)); write_u64_le(output + offset, bits); offset += 8; } while (false);
    DINOX_WEBRTC_SESSION_STATE_FIELDS(DINOX_WRITE_U32, DINOX_WRITE_U64, DINOX_WRITE_F64)
#undef DINOX_WRITE_U32
#undef DINOX_WRITE_U64
#undef DINOX_WRITE_F64
    return offset == required ? DINOX_WEBRTC_IPC_VALIDATION_OK : DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_session_state(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcSessionState* out_state) {
    if (input == nullptr || out_state == nullptr) return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    const size_t required = dinox_webrtc_ipc_session_state_size();
    if (input_size != required) return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    DinoXWebrtcSessionState state = {};
    size_t offset = 0;
#define DINOX_READ_U32(field) \
    state.field = static_cast<decltype(state.field)>(read_u32_le(input + offset)); offset += 4;
#define DINOX_READ_U64(field) \
    state.field = static_cast<decltype(state.field)>(read_u64_le(input + offset)); offset += 8;
#define DINOX_READ_F64(field) \
    do { uint64_t bits = read_u64_le(input + offset); \
        std::memcpy(&state.field, &bits, sizeof(bits)); offset += 8; } while (false);
    DINOX_WEBRTC_SESSION_STATE_FIELDS(DINOX_READ_U32, DINOX_READ_U64, DINOX_READ_F64)
#undef DINOX_READ_U32
#undef DINOX_READ_U64
#undef DINOX_READ_F64
    if (offset != required || state.abi_version != DINOX_WEBRTC_ABI_VERSION) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    *out_state = state;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

#undef DINOX_WEBRTC_SESSION_STATE_FIELDS

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_config(
    const DinoXWebrtcVideoEffectConfig* config,
    uint8_t* output,
    size_t output_size) {
    if (config == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    if (!dinox::webrtc_effects::valid_config(*config)) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    write_u32_le(output + 0, config->abi_version);
    write_u32_le(output + 4, static_cast<uint32_t>(config->effect_type));
    write_u32_le(output + 8, static_cast<uint32_t>(config->quality));
    write_u32_le(output + 12, config->preset_id);
    write_u32_le(output + 16, config->asset_id);
    write_u32_le(output + 20, 0);
    write_video_effect_adjustments(*config, output + 24);
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_config(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectConfig* out_config) {
    if (input == nullptr || out_config == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size != DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = read_u32_le(input + 0);
    config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(read_u32_le(input + 4));
    config.quality = static_cast<DinoXWebrtcVideoEffectQuality>(read_u32_le(input + 8));
    config.preset_id = read_u32_le(input + 12);
    config.asset_id = read_u32_le(input + 16);
    config.reserved = read_u32_le(input + 20);
    read_video_effect_adjustments(input + 24, &config);
    uint8_t encoded[DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE] = {};
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_encode_video_effect_config(
        &config, encoded, sizeof(encoded));
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    *out_config = config;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_capabilities(
    const DinoXWebrtcVideoEffectCapabilities* capabilities,
    uint8_t* output,
    size_t output_size) {
    if (capabilities == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    if (capabilities->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            (capabilities->supported_effect_mask &
                ~dinox::webrtc_effects::kKnownEffectMask) != 0 ||
            (capabilities->supported_effect_mask & UINT64_C(1)) == 0 ||
            capabilities->supported_quality_mask != UINT64_C(1) ||
            capabilities->max_subscribers == 0 || capabilities->max_subscribers > 64 ||
            (capabilities->shared_pipeline_supported != 0 &&
             capabilities->shared_pipeline_supported != 1) ||
            (capabilities->preview_publisher_supported != 0 &&
             capabilities->preview_publisher_supported != 1) ||
            capabilities->reserved != 0 ||
            (capabilities->supported_adjustment_mask &
                ~dinox::webrtc_effects::kSupportedAdjustmentMask) != 0 ||
            (capabilities->supported_background_mask &
                ~dinox::webrtc_effects::kKnownBackgroundMask) != 0 ||
            (capabilities->supported_background_mask & UINT32_C(1)) == 0 ||
            (capabilities->auto_framing_supported != 0 &&
             capabilities->auto_framing_supported != 1) ||
            (capabilities->supported_glasses_mask & ~dinox::webrtc_effects::kKnownThreeStyleMask) != 0 ||
            (capabilities->supported_hat_mask & ~dinox::webrtc_effects::kKnownThreeStyleMask) != 0 ||
            (capabilities->supported_beard_mask & ~dinox::webrtc_effects::kKnownThreeStyleMask) != 0 ||
            (capabilities->supported_face_accessory_mask & ~dinox::webrtc_effects::kKnownFaceAccessoryMask) != 0 ||
            (capabilities->supported_scene_effect_mask & ~dinox::webrtc_effects::kKnownSceneEffectMask) != 0 ||
            (capabilities->supported_glasses_mask & UINT32_C(1)) == 0 ||
            (capabilities->supported_hat_mask & UINT32_C(1)) == 0 ||
            (capabilities->supported_beard_mask & UINT32_C(1)) == 0 ||
            (capabilities->supported_face_accessory_mask & UINT32_C(1)) == 0 ||
            (capabilities->supported_scene_effect_mask & UINT32_C(1)) == 0 ||
            capabilities->touch_up_supported > 1 || capabilities->low_light_supported > 1) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    write_u32_le(output + 0, capabilities->abi_version);
    write_u32_le(output + 4, capabilities->max_subscribers);
    write_u64_le(output + 8, capabilities->supported_effect_mask);
    write_u64_le(output + 16, capabilities->supported_quality_mask);
    write_u32_le(output + 24, static_cast<uint32_t>(capabilities->shared_pipeline_supported));
    write_u32_le(output + 28, static_cast<uint32_t>(capabilities->preview_publisher_supported));
    write_u32_le(output + 32, 0);
    write_u32_le(output + 36, 0);
    write_u32_le(output + 40, capabilities->supported_adjustment_mask);
    write_u32_le(output + 44, capabilities->supported_background_mask);
    write_u32_le(output + 48, static_cast<uint32_t>(capabilities->auto_framing_supported));
    write_u32_le(output + 52, capabilities->supported_glasses_mask);
    write_u32_le(output + 56, capabilities->supported_hat_mask);
    write_u32_le(output + 60, capabilities->supported_beard_mask);
    write_u32_le(output + 64, capabilities->supported_face_accessory_mask);
    write_u32_le(output + 68, capabilities->supported_scene_effect_mask);
    write_u32_le(output + 72, capabilities->touch_up_supported);
    write_u32_le(output + 76, capabilities->low_light_supported);
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_capabilities(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectCapabilities* out_capabilities) {
    if (input == nullptr || out_capabilities == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size != DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcVideoEffectCapabilities capabilities = {};
    capabilities.abi_version = read_u32_le(input + 0);
    capabilities.max_subscribers = read_u32_le(input + 4);
    capabilities.supported_effect_mask = read_u64_le(input + 8);
    capabilities.supported_quality_mask = read_u64_le(input + 16);
    capabilities.shared_pipeline_supported = static_cast<int>(read_u32_le(input + 24));
    capabilities.preview_publisher_supported = static_cast<int>(read_u32_le(input + 28));
    capabilities.reserved = read_u32_le(input + 32);
    capabilities.supported_adjustment_mask = read_u32_le(input + 40);
    capabilities.supported_background_mask = read_u32_le(input + 44);
    capabilities.auto_framing_supported = static_cast<int>(read_u32_le(input + 48));
    capabilities.supported_glasses_mask = read_u32_le(input + 52);
    capabilities.supported_hat_mask = read_u32_le(input + 56);
    capabilities.supported_beard_mask = read_u32_le(input + 60);
    capabilities.supported_face_accessory_mask = read_u32_le(input + 64);
    capabilities.supported_scene_effect_mask = read_u32_le(input + 68);
    capabilities.touch_up_supported = read_u32_le(input + 72);
    capabilities.low_light_supported = read_u32_le(input + 76);
    if (read_u32_le(input + 36) != 0) return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    uint8_t encoded[DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE] = {};
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded, sizeof(encoded));
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    *out_capabilities = capabilities;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_pipeline_state(
    const DinoXWebrtcVideoPipelineState* state,
    uint8_t* output,
    size_t output_size) {
    if (state == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    const bool preview_identity_valid =
        (state->preview_subscriber_id == 0 && state->preview_subscriber_generation == 0) ||
        (state->preview_subscriber_id != 0 && state->preview_subscriber_generation != 0 &&
         state->subscriber_count != 0);
    const bool revision_state_valid =
        (state->application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_IDLE &&
         state->accepted_revision == 0 && state->applied_revision == 0) ||
        (state->application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_ACCEPTED &&
         state->accepted_revision != 0 &&
         state->applied_revision < state->accepted_revision) ||
        (state->application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
         state->applied_revision == state->accepted_revision) ||
        (state->application_state >= DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_UNAVAILABLE &&
         state->application_state <= DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_FAILED &&
         state->accepted_revision != 0 &&
         state->applied_revision <= state->accepted_revision);
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = state->abi_version;
    config.effect_type = state->effect_type;
    config.quality = state->quality;
    config.preset_id = state->preset_id;
    config.asset_id = state->asset_id;
    config.reserved = state->reserved;
    config.brightness = state->brightness;
    config.contrast = state->contrast;
    config.saturation = state->saturation;
    config.sharpness = state->sharpness;
    config.background_mode = state->background_mode;
    config.background_strength = state->background_strength;
    config.background_color_rgb = state->background_color_rgb;
    config.framing_mode = state->framing_mode;
    config.glasses_style = state->glasses_style;
    config.hat_style = state->hat_style;
    config.beard_style = state->beard_style;
    config.face_accessory = state->face_accessory;
    config.touch_up = state->touch_up;
    config.low_light = state->low_light;
    config.scene_effect = state->scene_effect;
    if (!dinox::webrtc_effects::valid_config(config) ||
            !valid_video_effect_application_state(
                static_cast<uint32_t>(state->application_state)) ||
            state->pipeline_id == 0 || state->pipeline_generation == 0 ||
            state->logical_call_id == 0 ||
            !revision_state_valid ||
            !valid_video_effect_type(static_cast<uint32_t>(state->effect_type)) ||
            !valid_video_effect_quality(static_cast<uint32_t>(state->quality)) ||
            state->subscriber_count > 64 || state->reserved != 0 ||
            !preview_identity_valid) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    write_u32_le(output + 0, state->abi_version);
    write_u32_le(output + 4, static_cast<uint32_t>(state->application_state));
    write_u64_le(output + 8, state->pipeline_id);
    write_u64_le(output + 16, state->pipeline_generation);
    write_u64_le(output + 24, state->logical_call_id);
    write_u64_le(output + 32, state->accepted_revision);
    write_u64_le(output + 40, state->applied_revision);
    write_u32_le(output + 48, static_cast<uint32_t>(state->effect_type));
    write_u32_le(output + 52, static_cast<uint32_t>(state->quality));
    write_u32_le(output + 56, state->preset_id);
    write_u32_le(output + 60, state->asset_id);
    write_u32_le(output + 64, state->subscriber_count);
    write_u32_le(output + 68, 0);
    write_u64_le(output + 72, state->preview_subscriber_id);
    write_u64_le(output + 80, state->preview_subscriber_generation);
    write_video_effect_adjustments(*state, output + 88);
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_pipeline_state(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoPipelineState* out_state) {
    if (input == nullptr || out_state == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size != DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcVideoPipelineState state = {};
    state.abi_version = read_u32_le(input + 0);
    state.application_state = static_cast<DinoXWebrtcVideoEffectApplicationState>(
        read_u32_le(input + 4));
    state.pipeline_id = read_u64_le(input + 8);
    state.pipeline_generation = read_u64_le(input + 16);
    state.logical_call_id = read_u64_le(input + 24);
    state.accepted_revision = read_u64_le(input + 32);
    state.applied_revision = read_u64_le(input + 40);
    state.effect_type = static_cast<DinoXWebrtcVideoEffectType>(read_u32_le(input + 48));
    state.quality = static_cast<DinoXWebrtcVideoEffectQuality>(read_u32_le(input + 52));
    state.preset_id = read_u32_le(input + 56);
    state.asset_id = read_u32_le(input + 60);
    state.subscriber_count = read_u32_le(input + 64);
    state.reserved = read_u32_le(input + 68);
    state.preview_subscriber_id = read_u64_le(input + 72);
    state.preview_subscriber_generation = read_u64_le(input + 80);
    read_video_effect_adjustments(input + 88, &state);
    uint8_t encoded[DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE] = {};
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_encode_video_pipeline_state(
        &state, encoded, sizeof(encoded));
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    *out_state = state;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

#define DINOX_WEBRTC_VIDEO_EFFECT_DIAGNOSTIC_U64_FIELDS(FIELD) \
    FIELD(captured) \
    FIELD(enqueued) \
    FIELD(processed) \
    FIELD(bypassed) \
    FIELD(queue_replaced) \
    FIELD(failed) \
    FIELD(watchdog_bypass) \
    FIELD(quality_downgrade) \
    FIELD(processing_time_total_us) \
    FIELD(processing_time_max_us) \
    FIELD(processing_time_p95_us) \
    FIELD(processing_time_p99_us) \
    FIELD(last_completed_monotonic_us) \
    FIELD(stale_result_age_us) \
    FIELD(loaded_model_bytes) \
    FIELD(effect_owned_allocated_bytes) \
    FIELD(configuration_request_count) \
    FIELD(frame_copy_count)

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_encode_video_effect_diagnostics(
    const DinoXWebrtcVideoEffectDiagnostics* diagnostics,
    uint8_t* output,
    size_t output_size) {
    if (diagnostics == nullptr || output == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (output_size < DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    if (diagnostics->abi_version != DINOX_WEBRTC_ABI_VERSION ||
            diagnostics->active_quality_tier != 0 ||
            diagnostics->logical_pipeline_count > 1 ||
            diagnostics->subscriber_count > 64 ||
            diagnostics->effect_thread_count > 1 ||
            diagnostics->effect_handle_count > 1 ||
            diagnostics->effect_mapping_count != 0 ||
            diagnostics->reserved != 0) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    write_u32_le(output + 0, diagnostics->abi_version);
    write_u32_le(output + 4, diagnostics->active_quality_tier);
    size_t offset = 8;
#define DINOX_WRITE_DIAGNOSTIC_U64(field) \
    write_u64_le(output + offset, diagnostics->field); offset += 8;
    DINOX_WEBRTC_VIDEO_EFFECT_DIAGNOSTIC_U64_FIELDS(DINOX_WRITE_DIAGNOSTIC_U64)
#undef DINOX_WRITE_DIAGNOSTIC_U64
    write_u32_le(output + offset, diagnostics->logical_pipeline_count); offset += 4;
    write_u32_le(output + offset, diagnostics->subscriber_count); offset += 4;
    write_u32_le(output + offset, diagnostics->effect_thread_count); offset += 4;
    write_u32_le(output + offset, diagnostics->effect_handle_count); offset += 4;
    write_u32_le(output + offset, diagnostics->effect_mapping_count); offset += 4;
    write_u32_le(output + offset, 0); offset += 4;
    return offset == DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE
        ? DINOX_WEBRTC_IPC_VALIDATION_OK
        : DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
}

extern "C" DinoXWebrtcIpcValidationStatus dinox_webrtc_ipc_decode_video_effect_diagnostics(
    const uint8_t* input,
    size_t input_size,
    DinoXWebrtcVideoEffectDiagnostics* out_diagnostics) {
    if (input == nullptr || out_diagnostics == nullptr) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    if (input_size != DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED;
    }
    DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
    diagnostics.abi_version = read_u32_le(input + 0);
    diagnostics.active_quality_tier = read_u32_le(input + 4);
    size_t offset = 8;
#define DINOX_READ_DIAGNOSTIC_U64(field) \
    diagnostics.field = read_u64_le(input + offset); offset += 8;
    DINOX_WEBRTC_VIDEO_EFFECT_DIAGNOSTIC_U64_FIELDS(DINOX_READ_DIAGNOSTIC_U64)
#undef DINOX_READ_DIAGNOSTIC_U64
    diagnostics.logical_pipeline_count = read_u32_le(input + offset); offset += 4;
    diagnostics.subscriber_count = read_u32_le(input + offset); offset += 4;
    diagnostics.effect_thread_count = read_u32_le(input + offset); offset += 4;
    diagnostics.effect_handle_count = read_u32_le(input + offset); offset += 4;
    diagnostics.effect_mapping_count = read_u32_le(input + offset); offset += 4;
    diagnostics.reserved = read_u32_le(input + offset); offset += 4;
    if (offset != DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE) {
        return DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT;
    }
    uint8_t encoded[DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE] = {};
    DinoXWebrtcIpcValidationStatus status = dinox_webrtc_ipc_encode_video_effect_diagnostics(
        &diagnostics, encoded, sizeof(encoded));
    if (status != DINOX_WEBRTC_IPC_VALIDATION_OK) return status;
    *out_diagnostics = diagnostics;
    return DINOX_WEBRTC_IPC_VALIDATION_OK;
}

#undef DINOX_WEBRTC_VIDEO_EFFECT_DIAGNOSTIC_U64_FIELDS
