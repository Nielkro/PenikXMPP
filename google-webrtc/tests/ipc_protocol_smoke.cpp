#include "dinox_webrtc_ipc.h"
#include "../src/dinox_webrtc_video_effect_config.hpp"

#include <array>
#include <cstring>
#include <vector>
#include <stdio.h>

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "DINOX_CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

int check_selection_contract() {
    using namespace dinox::webrtc_effects;
    constexpr std::array<DinoXWebrtcVideoEffectType, 13> identities = {
        DINOX_WEBRTC_VIDEO_EFFECT_NONE, DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE,
        DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE, DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE,
        DINOX_WEBRTC_VIDEO_EFFECT_SEPIA, DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK,
        DINOX_WEBRTC_VIDEO_EFFECT_DREAMY, DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT,
        DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE, DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV,
        DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS, DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE,
        DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER};
    for (size_t i = 0; i < identities.size(); ++i) DINOX_CHECK(static_cast<size_t>(identities[i]) == i);
    struct Field {
        uint32_t DinoXWebrtcVideoEffectConfig::*config;
        uint32_t DinoXWebrtcVideoPipelineState::*state;
        uint32_t max;
        size_t wire_offset;
    };
    const std::array<Field, 7> fields = {{{&DinoXWebrtcVideoEffectConfig::glasses_style, &DinoXWebrtcVideoPipelineState::glasses_style, 3, 56},
        {&DinoXWebrtcVideoEffectConfig::hat_style, &DinoXWebrtcVideoPipelineState::hat_style, 3, 60},
        {&DinoXWebrtcVideoEffectConfig::beard_style, &DinoXWebrtcVideoPipelineState::beard_style, 3, 64},
        {&DinoXWebrtcVideoEffectConfig::face_accessory, &DinoXWebrtcVideoPipelineState::face_accessory, 2, 68},
        {&DinoXWebrtcVideoEffectConfig::touch_up, &DinoXWebrtcVideoPipelineState::touch_up, 1, 72},
        {&DinoXWebrtcVideoEffectConfig::low_light, &DinoXWebrtcVideoPipelineState::low_light, 1, 76},
        {&DinoXWebrtcVideoEffectConfig::scene_effect, &DinoXWebrtcVideoPipelineState::scene_effect, 4, 80}}};
    DinoXWebrtcVideoEffectConfig neutral = {};
    neutral.abi_version = DINOX_WEBRTC_ABI_VERSION;
    DINOX_CHECK(valid_config(neutral) && supported_config(neutral) && !active_config(neutral));
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE + 1> wire;
    wire.fill(0xa5);
    for (const auto& field : fields) {
        auto config = neutral;
        config.*field.config = field.max;
        const bool pure = field.config == &DinoXWebrtcVideoEffectConfig::low_light ||
            field.config == &DinoXWebrtcVideoEffectConfig::scene_effect;
        DINOX_CHECK(valid_config(config) && supported_config(config) == pure &&
            supported_config(config, true, true) && active_config(config) && !same_config(config, neutral));
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(&config, wire.data(), wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
        DINOX_CHECK(wire[field.wire_offset] == field.max && wire[field.wire_offset + 1] == 0 &&
            wire[field.wire_offset + 2] == 0 && wire[field.wire_offset + 3] == 0 && wire.back() == 0xa5);
        DinoXWebrtcVideoEffectConfig decoded = {};
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(wire.data(), wire.size() - 1, &decoded) == DINOX_WEBRTC_IPC_VALIDATION_OK);
        DINOX_CHECK(same_config(config, decoded));
        config.*field.config = field.max + 1;
        DINOX_CHECK(!valid_config(config));
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(&config, wire.data(), wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        wire[field.wire_offset] = static_cast<uint8_t>(field.max + 1);
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(wire.data(), wire.size() - 1, &decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        DINOX_CHECK(decoded.*field.config == field.max); // invalid decode is transactional
        config.*field.config = UINT32_MAX;
        DINOX_CHECK(!valid_config(config));
    }
    auto all = neutral;
    constexpr uint32_t values[7] = {1,2,3,2,1,0,4};
    for (size_t i = 0; i < fields.size(); ++i) all.*fields[i].config = values[i];
    all.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER;
    DINOX_CHECK(valid_config(all) && !supported_config(all) && active_config(all));
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(&all, wire.data(), wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoEffectConfig decoded = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(wire.data(), wire.size() - 1, &decoded) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(same_config(all, decoded));
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(wire.data(), wire.size(), &decoded) == DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    wire[20] = 1;
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(wire.data(), wire.size() - 1, &decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    DinoXWebrtcVideoPipelineState state = {};
    state.abi_version = DINOX_WEBRTC_ABI_VERSION;
    state.application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;
    state.pipeline_id = 1; state.pipeline_generation = 2; state.logical_call_id = 3;
    state.accepted_revision = state.applied_revision = 4;
    state.effect_type = all.effect_type;
    for (size_t i = 0; i < fields.size(); ++i) state.*fields[i].state = values[i];
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE + 1> state_wire;
    state_wire.fill(0xa5);
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_pipeline_state(&state, state_wire.data(), state_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoPipelineState state_decoded = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(state_wire.data(), state_wire.size() - 1, &state_decoded) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    for (size_t i = 0; i < fields.size(); ++i) {
        DINOX_CHECK(state_decoded.*fields[i].state == values[i] && state_wire[fields[i].wire_offset + 64] == values[i]);
        auto bad = state_wire;
        bad[fields[i].wire_offset + 64] = static_cast<uint8_t>(fields[i].max + 1);
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(bad.data(), bad.size() - 1, &state_decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    }
    DINOX_CHECK(state_wire.back() == 0xa5 && state_decoded.scene_effect == 4);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(state_wire.data(), state_wire.size(), &state_decoded) == DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    // Poison native padding, then set every field explicitly. The wire must
    // stay field-defined, even where native sizeof(state) has trailing padding.
    DinoXWebrtcVideoPipelineState padded;
    std::memset(&padded, 0xa5, sizeof(padded));
#define COPY_FIELD(field) padded.field = state.field;
    COPY_FIELD(abi_version) COPY_FIELD(application_state) COPY_FIELD(pipeline_id)
    COPY_FIELD(pipeline_generation) COPY_FIELD(logical_call_id) COPY_FIELD(accepted_revision)
    COPY_FIELD(applied_revision) COPY_FIELD(effect_type) COPY_FIELD(quality) COPY_FIELD(preset_id)
    COPY_FIELD(asset_id) COPY_FIELD(subscriber_count) COPY_FIELD(reserved) COPY_FIELD(preview_subscriber_id)
    COPY_FIELD(preview_subscriber_generation) COPY_FIELD(brightness) COPY_FIELD(contrast) COPY_FIELD(saturation)
    COPY_FIELD(sharpness) COPY_FIELD(background_mode) COPY_FIELD(background_strength) COPY_FIELD(background_color_rgb)
    COPY_FIELD(framing_mode) COPY_FIELD(glasses_style) COPY_FIELD(hat_style) COPY_FIELD(beard_style)
    COPY_FIELD(face_accessory) COPY_FIELD(touch_up) COPY_FIELD(low_light) COPY_FIELD(scene_effect)
#undef COPY_FIELD
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE> padded_wire = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_pipeline_state(&padded, padded_wire.data(), padded_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(std::memcmp(padded_wire.data(), state_wire.data(), padded_wire.size()) == 0);
    state_wire[68] = 1;
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(state_wire.data(), state_wire.size() - 1, &state_decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    DinoXWebrtcVideoEffectCapabilities caps = {};
    caps.abi_version = DINOX_WEBRTC_ABI_VERSION;
    caps.supported_effect_mask = kKnownEffectMask; // future renderer flags are valid wire values
    caps.supported_quality_mask = 1;
    caps.max_subscribers = 8;
    caps.shared_pipeline_supported = caps.preview_publisher_supported = 1;
    caps.supported_adjustment_mask = 15;
    caps.supported_background_mask = 1;
    caps.supported_glasses_mask = caps.supported_hat_mask = caps.supported_beard_mask = 15;
    caps.supported_face_accessory_mask = 7;
    caps.supported_scene_effect_mask = 31;
    caps.touch_up_supported = caps.low_light_supported = 1;
    struct CapMask { uint32_t DinoXWebrtcVideoEffectCapabilities::*field; uint32_t known; size_t offset; };
    const std::array<CapMask, 5> masks = {{{&DinoXWebrtcVideoEffectCapabilities::supported_glasses_mask,15,52},
        {&DinoXWebrtcVideoEffectCapabilities::supported_hat_mask,15,56},
        {&DinoXWebrtcVideoEffectCapabilities::supported_beard_mask,15,60},
        {&DinoXWebrtcVideoEffectCapabilities::supported_face_accessory_mask,7,64},
        {&DinoXWebrtcVideoEffectCapabilities::supported_scene_effect_mask,31,68}}};
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE + 1> cap_wire;
    cap_wire.fill(0xa5);
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&caps, cap_wire.data(), cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoEffectCapabilities cap_decoded = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(cap_wire.data(), cap_wire.size() - 1, &cap_decoded) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(cap_decoded.supported_effect_mask == 8191 && cap_decoded.touch_up_supported == 1 && cap_decoded.low_light_supported == 1 && cap_wire.back() == 0xa5);
    for (const auto& field : masks) {
        DINOX_CHECK(cap_decoded.*field.field == field.known && cap_wire[field.offset] == field.known);
        auto bad = caps;
        bad.*field.field = field.known | (field.known + 1);
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&bad, cap_wire.data(), cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        bad.*field.field = 0;
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&bad, cap_wire.data(), cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        bad.*field.field = field.known & ~UINT32_C(1);
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&bad, cap_wire.data(), cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        auto corrupt = cap_wire;
        corrupt[field.offset] = static_cast<uint8_t>(1 | (field.known + 1));
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(corrupt.data(), corrupt.size() - 1, &cap_decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    }
    for (const auto field : {&DinoXWebrtcVideoEffectCapabilities::touch_up_supported,
            &DinoXWebrtcVideoEffectCapabilities::low_light_supported}) {
        auto bad = caps;
        for (const uint32_t invalid : {UINT32_C(2), UINT32_MAX}) {
            bad.*field = invalid;
            DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&bad, cap_wire.data(), cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
        }
    }
    for (const size_t offset : {size_t{32}, size_t{36}, size_t{72}, size_t{76}}) {
        auto corrupt = cap_wire;
        corrupt[offset] = 2;
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(corrupt.data(), corrupt.size() - 1, &cap_decoded) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    }
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(cap_wire.data(), cap_wire.size(), &cap_decoded) == DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    DinoXWebrtcVideoEffectCapabilities padded_caps;
    std::memset(&padded_caps, 0xa5, sizeof(padded_caps));
#define COPY_CAP(field) padded_caps.field = caps.field;
    COPY_CAP(abi_version) COPY_CAP(supported_effect_mask) COPY_CAP(supported_quality_mask)
    COPY_CAP(max_subscribers) COPY_CAP(shared_pipeline_supported) COPY_CAP(preview_publisher_supported)
    COPY_CAP(reserved) COPY_CAP(supported_adjustment_mask) COPY_CAP(supported_background_mask)
    COPY_CAP(auto_framing_supported) COPY_CAP(supported_glasses_mask) COPY_CAP(supported_hat_mask)
    COPY_CAP(supported_beard_mask) COPY_CAP(supported_face_accessory_mask) COPY_CAP(supported_scene_effect_mask)
    COPY_CAP(touch_up_supported) COPY_CAP(low_light_supported)
#undef COPY_CAP
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE> padded_cap_wire = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(&padded_caps, padded_cap_wire.data(), padded_cap_wire.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(std::memcmp(padded_cap_wire.data(), cap_wire.data(), padded_cap_wire.size()) == 0);
    return 0;
}

int main() {
    DINOX_CHECK(check_selection_contract() == 0);
    DINOX_CHECK(DINOX_WEBRTC_IPC_PROTOCOL_VERSION == 10);
    DINOX_CHECK(DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE == 84);
    DINOX_CHECK(DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE == 148);
    DINOX_CHECK(DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE == 80);
    DINOX_CHECK(DINOX_WEBRTC_IPC_HEADER_SIZE == 48);
    DINOX_CHECK(DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD == 1024 * 1024);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(DINOX_WEBRTC_IPC_MESSAGE_HELLO) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PUSH) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_PREPARE_LOCAL_DESCRIPTION) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION_PREPARED) == 1);
    DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(9999) == 0);
    for(uint32_t type=DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN;
            type<=DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE;++type){
        DINOX_CHECK(dinox_webrtc_ipc_message_type_is_known(type));
        auto background=dinox_webrtc_ipc_header_default(static_cast<DinoXWebrtcIpcMessageType>(type),1,88,4,0);
        DINOX_CHECK(dinox_webrtc_ipc_validate_header(&background,DINOX_WEBRTC_IPC_HEADER_SIZE)==DINOX_WEBRTC_IPC_VALIDATION_OK);
        background.generation=0;
        DINOX_CHECK(dinox_webrtc_ipc_validate_header(&background,DINOX_WEBRTC_IPC_HEADER_SIZE)==DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION);
        background.generation=4;background.session_id=0;
        DINOX_CHECK(dinox_webrtc_ipc_validate_header(&background,DINOX_WEBRTC_IPC_HEADER_SIZE)==DINOX_WEBRTC_IPC_VALIDATION_INVALID_SESSION_ID);
    }

    DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER,
        UINT64_C(0x0102030405060708),
        UINT64_C(0x1112131415161718),
        UINT64_C(0x2122232425262728),
        1234);
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &header,
        DINOX_WEBRTC_IPC_HEADER_SIZE + 1234) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcIpcHeader old_header = header;
    old_header.protocol_version = 9;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &old_header,
        DINOX_WEBRTC_IPC_HEADER_SIZE + 1234) ==
        DINOX_WEBRTC_IPC_VALIDATION_UNSUPPORTED_VERSION);

    std::array<uint8_t, DINOX_WEBRTC_IPC_HEADER_SIZE> encoded = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_header(
        &header,
        encoded.data(),
        encoded.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(encoded[0] == 0x52 && encoded[1] == 0x57 && encoded[2] == 0x58 && encoded[3] == 0x44);
    DINOX_CHECK(encoded[16] == 0x08 && encoded[23] == 0x01);
    DINOX_CHECK(encoded[40] == 0xd2 && encoded[41] == 0x04);

    DinoXWebrtcIpcHeader decoded = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_header(
        encoded.data(),
        encoded.size(),
        &decoded) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded.message_type == header.message_type);
    DINOX_CHECK(decoded.request_id == header.request_id);
    DINOX_CHECK(decoded.session_id == header.session_id);
    DINOX_CHECK(decoded.generation == header.generation);
    DINOX_CHECK(decoded.payload_size == header.payload_size);

    DINOX_CHECK(dinox_webrtc_ipc_decode_header(
        encoded.data(),
        encoded.size() - 1,
        &decoded) == DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    std::array<uint8_t, DINOX_WEBRTC_IPC_HEADER_SIZE> invalid = encoded;
    invalid[0] = 0;
    DINOX_CHECK(dinox_webrtc_ipc_decode_header(
        invalid.data(),
        invalid.size(),
        &decoded) == DINOX_WEBRTC_IPC_VALIDATION_BAD_MAGIC);
    invalid = encoded;
    invalid[8] = 0xff;
    invalid[9] = 0xff;
    DINOX_CHECK(dinox_webrtc_ipc_decode_header(
        invalid.data(),
        invalid.size(),
        &decoded) == DINOX_WEBRTC_IPC_VALIDATION_UNKNOWN_MESSAGE);

    DinoXWebrtcIpcHeader oversized = header;
    oversized.payload_size = DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD + 1;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &oversized,
        0) == DINOX_WEBRTC_IPC_VALIDATION_PAYLOAD_TOO_LARGE);
    DinoXWebrtcIpcHeader stale = header;
    stale.generation = 0;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &stale,
        0) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION);
    DinoXWebrtcIpcHeader no_request = header;
    no_request.request_id = 0;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &no_request,
        0) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_REQUEST_ID);
    DinoXWebrtcIpcHeader bad_flags = header;
    bad_flags.flags = DINOX_WEBRTC_IPC_FLAG_EVENT;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &bad_flags,
        0) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_FLAGS);
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &header,
        DINOX_WEBRTC_IPC_HEADER_SIZE + 1233) == DINOX_WEBRTC_IPC_VALIDATION_FRAME_SIZE_MISMATCH);

    DinoXWebrtcIpcHeader event = dinox_webrtc_ipc_header_default(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_CANDIDATE,
        0,
        5,
        9,
        0);
    DINOX_CHECK(event.flags == DINOX_WEBRTC_IPC_FLAG_EVENT);
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &event,
        DINOX_WEBRTC_IPC_HEADER_SIZE) == DINOX_WEBRTC_IPC_VALIDATION_OK);

    DinoXWebrtcIpcHeader error = dinox_webrtc_ipc_header_default(
        DINOX_WEBRTC_IPC_MESSAGE_ERROR,
        42,
        0,
        0,
        0);
    DINOX_CHECK((error.flags & DINOX_WEBRTC_IPC_FLAG_REPLY) != 0);
    DINOX_CHECK((error.flags & DINOX_WEBRTC_IPC_FLAG_ERROR) != 0);
    DINOX_CHECK(std::strcmp(
        dinox_webrtc_ipc_validation_status_to_string(DINOX_WEBRTC_IPC_VALIDATION_BAD_MAGIC),
        "bad-magic") == 0);
    const size_t handshake_size = dinox_webrtc_ipc_build_handshake(nullptr, 0);
    DINOX_CHECK(handshake_size > 40 && handshake_size < 256);
    std::array<char, 256> handshake = {};
    DINOX_CHECK(dinox_webrtc_ipc_build_handshake(handshake.data(), handshake.size()) == handshake_size);
    DINOX_CHECK(std::strstr(handshake.data(), "abi=40;") != nullptr);
    DINOX_CHECK(std::strstr(handshake.data(), "milestone=152;") != nullptr);

    DinoXWebrtcIpcSessionConfig session_config = {};
    session_config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    session_config.audio_enabled = 1;
    session_config.video_enabled = 0;
    session_config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    session_config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    session_config.max_bundle = 1;
    std::array<uint8_t, DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE> encoded_config = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_session_config(
        &session_config,
        encoded_config.data(),
        encoded_config.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcIpcSessionConfig decoded_config = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_config(
        encoded_config.data(),
        encoded_config.size(),
        &decoded_config) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_config.audio_enabled == 1);
    DINOX_CHECK(decoded_config.video_enabled == 0);
    DINOX_CHECK(decoded_config.video_direction == DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE);
    encoded_config[40] = 1;
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_config(
        encoded_config.data(),
        encoded_config.size(),
        &decoded_config) == DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    DinoXWebrtcSessionState state = {};
    state.abi_version = DINOX_WEBRTC_ABI_VERSION;
    state.local_video_source_frame_count = 17;
    state.local_video_source_last_width = 640;
    state.local_video_source_last_height = 360;
    state.inbound_audio_bytes_received = UINT64_C(0x0102030405060708);
    state.outbound_audio_target_bitrate = 12345.5;
    state.network_policy = DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G;
    state.audio_sender_bitrate_cap_bps = 16000;
    state.audio_sender_adaptive_ptime = 1;
    state.audio_sender_policy_applied = 1;
    std::vector<uint8_t> encoded_state(dinox_webrtc_ipc_session_state_size());
    DINOX_CHECK(encoded_state.size() > 300 && encoded_state.size() < 1024);
    DINOX_CHECK(dinox_webrtc_ipc_encode_session_state(
        &state, encoded_state.data(), encoded_state.size()) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(encoded_state[0] == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(encoded_state[1] == 0 && encoded_state[2] == 0 && encoded_state[3] == 0);
    DinoXWebrtcSessionState decoded_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_state(
        encoded_state.data(), encoded_state.size(), &decoded_state) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_state.inbound_audio_bytes_received == state.inbound_audio_bytes_received);
    DINOX_CHECK(decoded_state.local_video_source_frame_count == 17);
    DINOX_CHECK(decoded_state.local_video_source_last_width == 640);
    DINOX_CHECK(decoded_state.local_video_source_last_height == 360);
    DINOX_CHECK(decoded_state.outbound_audio_target_bitrate == state.outbound_audio_target_bitrate);
    DINOX_CHECK(decoded_state.network_policy == DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G);
    DINOX_CHECK(decoded_state.audio_sender_bitrate_cap_bps == 16000);

    DinoXWebrtcVideoEffectConfig effect_config = {};
    effect_config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    effect_config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    effect_config.quality = DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO;
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE> encoded_effect = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoEffectConfig decoded_effect = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_effect.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_NONE);
    effect_config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_effect.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE);
    effect_config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_effect.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);
    effect_config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(13);
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    effect_config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size() - 1, &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    encoded_effect[4] = 99;
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    for (auto preset : {DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE, DINOX_WEBRTC_VIDEO_EFFECT_SEPIA,
            DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK, DINOX_WEBRTC_VIDEO_EFFECT_DREAMY,
            DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT, DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE,
            DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV, DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS,
            DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE, DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER}) {
        effect_config.effect_type = preset;
        effect_config.brightness = -100;
        effect_config.contrast = 100;
        effect_config.saturation = -50;
        effect_config.sharpness = 100;
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
            &effect_config, encoded_effect.data(), encoded_effect.size()) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK);
        // Signed little-endian values must not depend on C struct layout.
        DINOX_CHECK(encoded_effect[24] == 156 && encoded_effect[25] == 255 &&
            encoded_effect[26] == 255 && encoded_effect[27] == 255);
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
            encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK);
        DINOX_CHECK(decoded_effect.effect_type == preset && decoded_effect.brightness == -100 &&
            decoded_effect.contrast == 100 && decoded_effect.saturation == -50 &&
            decoded_effect.sharpness == 100);
    }
    effect_config.brightness = -101;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    effect_config.brightness = 0;
    effect_config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE;
    effect_config.background_strength = 0;
    effect_config.asset_id = UINT32_C(1000);
    effect_config.framing_mode = DINOX_WEBRTC_VIDEO_FRAMING_AUTO;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_effect.asset_id == 1000 &&
        decoded_effect.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE &&
        decoded_effect.background_strength == 0 &&
        decoded_effect.framing_mode == DINOX_WEBRTC_VIDEO_FRAMING_AUTO);
    decoded_effect.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR;
    decoded_effect.asset_id = 0;
    decoded_effect.background_strength = 50;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &decoded_effect, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_config(
        encoded_effect.data(), encoded_effect.size(), &decoded_effect) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_effect.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR &&
        decoded_effect.background_strength == 50);
    effect_config.asset_id = 0;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    effect_config.asset_id = 1;
    effect_config.background_color_rgb = UINT32_C(0x1000000);
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    effect_config.background_color_rgb = 0;
    effect_config.background_mode = static_cast<DinoXWebrtcVideoBackgroundMode>(4);
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    // A former ABI/protocol must never share this changed wire contract.
    effect_config = {};
    effect_config.abi_version = DINOX_WEBRTC_ABI_VERSION - 1;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect.data(), encoded_effect.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    DinoXWebrtcVideoEffectCapabilities capabilities = {};
    capabilities.abi_version = DINOX_WEBRTC_ABI_VERSION;
    capabilities.supported_effect_mask = 0;
    capabilities.supported_quality_mask = 1;
    capabilities.max_subscribers = 8;
    capabilities.shared_pipeline_supported = 1;
    capabilities.preview_publisher_supported = 1;
    capabilities.supported_adjustment_mask = 15;
    capabilities.supported_background_mask = 1;
    capabilities.supported_glasses_mask = 1;
    capabilities.supported_hat_mask = 1;
    capabilities.supported_beard_mask = 1;
    capabilities.supported_face_accessory_mask = 1;
    capabilities.supported_scene_effect_mask = 1;
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE> encoded_caps = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.supported_effect_mask = 4095;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoEffectCapabilities decoded_caps = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(
        encoded_caps.data(), encoded_caps.size(), &decoded_caps) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_caps.max_subscribers == 8);
    DINOX_CHECK(decoded_caps.supported_effect_mask == 4095);
    DINOX_CHECK(decoded_caps.supported_adjustment_mask == 15);
    DINOX_CHECK(decoded_caps.supported_background_mask == 1);
    DINOX_CHECK(decoded_caps.auto_framing_supported == 0);
    DINOX_CHECK(decoded_caps.shared_pipeline_supported == 1);
    // The old invalid mask now names a valid subset of the declared presets.
    capabilities.supported_effect_mask = 63;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    capabilities.supported_effect_mask = 16383;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.supported_effect_mask = 4095;
    capabilities.supported_background_mask = 15;
    capabilities.auto_framing_supported = 1;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    capabilities.auto_framing_supported = -1;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.auto_framing_supported = 2;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.auto_framing_supported = 0;
    capabilities.supported_background_mask = 17;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.supported_background_mask = 0;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    capabilities.supported_background_mask = 1;
    capabilities.supported_adjustment_mask = 31;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_capabilities(
        &capabilities, encoded_caps.data(), encoded_caps.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(
        encoded_caps.data(), encoded_caps.size() - 1, &decoded_caps) ==
        DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);
    std::vector<uint8_t> oversized_caps(encoded_caps.begin(), encoded_caps.end());
    oversized_caps.push_back(0);
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(
        oversized_caps.data(), oversized_caps.size(), &decoded_caps) ==
        DINOX_WEBRTC_IPC_VALIDATION_TRUNCATED);

    DinoXWebrtcVideoPipelineState pipeline_state = {};
    pipeline_state.abi_version = DINOX_WEBRTC_ABI_VERSION;
    pipeline_state.application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;
    pipeline_state.pipeline_id = 7;
    pipeline_state.pipeline_generation = 3;
    pipeline_state.logical_call_id = 42;
    pipeline_state.accepted_revision = 9;
    pipeline_state.applied_revision = 9;
    pipeline_state.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    pipeline_state.quality = DINOX_WEBRTC_VIDEO_EFFECT_QUALITY_AUTO;
    pipeline_state.subscriber_count = 1;
    pipeline_state.preview_subscriber_id = 11;
    pipeline_state.preview_subscriber_generation = 2;
    pipeline_state.brightness = 21;
    pipeline_state.contrast = -43;
    pipeline_state.saturation = 67;
    pipeline_state.sharpness = 89;
    pipeline_state.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID;
    pipeline_state.background_color_rgb = UINT32_C(0xaabbcc);
    pipeline_state.framing_mode = DINOX_WEBRTC_VIDEO_FRAMING_AUTO;
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE> encoded_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_pipeline_state(
        &pipeline_state, encoded_pipeline_state.data(), encoded_pipeline_state.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoPipelineState decoded_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
        encoded_pipeline_state.data(), encoded_pipeline_state.size(), &decoded_pipeline_state) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_pipeline_state.logical_call_id == 42);
    DINOX_CHECK(decoded_pipeline_state.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);
    DINOX_CHECK(decoded_pipeline_state.preview_subscriber_generation == 2);
    DINOX_CHECK(decoded_pipeline_state.brightness == 21 &&
        decoded_pipeline_state.contrast == -43 && decoded_pipeline_state.saturation == 67 &&
        decoded_pipeline_state.sharpness == 89 &&
        decoded_pipeline_state.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID &&
        decoded_pipeline_state.background_color_rgb == UINT32_C(0xaabbcc) &&
        decoded_pipeline_state.framing_mode == DINOX_WEBRTC_VIDEO_FRAMING_AUTO);
    for (int preset = DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK;
            preset <= DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE; ++preset) {
        pipeline_state.effect_type = static_cast<DinoXWebrtcVideoEffectType>(preset);
        DINOX_CHECK(dinox_webrtc_ipc_encode_video_pipeline_state(
            &pipeline_state, encoded_pipeline_state.data(), encoded_pipeline_state.size()) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK);
        DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
            encoded_pipeline_state.data(), encoded_pipeline_state.size(), &decoded_pipeline_state) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK);
        DINOX_CHECK(decoded_pipeline_state.effect_type == preset &&
            decoded_pipeline_state.brightness == 21 && decoded_pipeline_state.contrast == -43 &&
            decoded_pipeline_state.saturation == 67 && decoded_pipeline_state.sharpness == 89);
    }
    pipeline_state.application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_ACCEPTED;
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_pipeline_state(
        &pipeline_state, encoded_pipeline_state.data(), encoded_pipeline_state.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);
    pipeline_state.application_state = DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;
    encoded_pipeline_state[16] = 0;
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
        encoded_pipeline_state.data(), encoded_pipeline_state.size(), &decoded_pipeline_state) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_ARGUMENT);

    DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
    diagnostics.abi_version = DINOX_WEBRTC_ABI_VERSION;
    diagnostics.configuration_request_count = 100;
    diagnostics.logical_pipeline_count = 1;
    diagnostics.subscriber_count = 5;
    std::array<uint8_t, DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE> encoded_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_diagnostics(
        &diagnostics, encoded_diagnostics.data(), encoded_diagnostics.size()) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DinoXWebrtcVideoEffectDiagnostics decoded_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_diagnostics(
        encoded_diagnostics.data(), encoded_diagnostics.size(), &decoded_diagnostics) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(decoded_diagnostics.configuration_request_count == 100);
    DINOX_CHECK(decoded_diagnostics.effect_thread_count == 0);
    DINOX_CHECK(decoded_diagnostics.frame_copy_count == 0);

    DinoXWebrtcIpcHeader pipeline_header = dinox_webrtc_ipc_header_default(
        DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH, 99, 8, 2,
        DINOX_WEBRTC_IPC_VIDEO_PIPELINE_ATTACHMENT_SIZE);
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(
        &pipeline_header,
        DINOX_WEBRTC_IPC_HEADER_SIZE + DINOX_WEBRTC_IPC_VIDEO_PIPELINE_ATTACHMENT_SIZE) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    pipeline_header.generation = 0;
    DINOX_CHECK(dinox_webrtc_ipc_validate_header(&pipeline_header, 0) ==
        DINOX_WEBRTC_IPC_VALIDATION_INVALID_GENERATION);
    return 0;
}
