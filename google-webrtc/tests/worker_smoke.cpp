#include "dinox_webrtc.h"
#include "dinox_webrtc_ipc.h"

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "DINOX_CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

namespace {

bool read_exact(int fd, void* output, size_t size) {
    uint8_t* cursor = static_cast<uint8_t*>(output);
    while (size > 0) {
        ssize_t count = read(fd, cursor, size);
        if (count == 0) return false;
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        cursor += static_cast<size_t>(count);
        size -= static_cast<size_t>(count);
    }
    return true;
}

bool write_exact(int fd, const void* input, size_t size) {
    const uint8_t* cursor = static_cast<const uint8_t*>(input);
    while (size > 0) {
        ssize_t count = write(fd, cursor, size);
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        cursor += static_cast<size_t>(count);
        size -= static_cast<size_t>(count);
    }
    return true;
}

void append_u32(std::vector<uint8_t>* payload, uint32_t value) {
    for (unsigned int byte = 0; byte < 4; ++byte) {
        payload->push_back(static_cast<uint8_t>((value >> (byte * 8)) & 0xffu));
    }
}

void append_u64(std::vector<uint8_t>* payload, uint64_t value) {
    for (unsigned int byte = 0; byte < 8; ++byte) {
        payload->push_back(static_cast<uint8_t>((value >> (byte * 8)) & 0xffu));
    }
}

bool send_request(
    int fd,
    DinoXWebrtcIpcMessageType type,
    uint64_t request_id,
    uint64_t session_id = 0,
    uint64_t generation = 0,
    const void* payload = nullptr,
    uint32_t payload_size = 0) {
    DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
        type,
        request_id,
        session_id,
        generation,
        payload_size);
    uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
    return dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK &&
        write_exact(fd, encoded, sizeof(encoded)) &&
        (payload_size == 0 || write_exact(fd, payload, payload_size));
}

bool send_oneway_request(
    int fd,
    DinoXWebrtcIpcMessageType type,
    uint64_t session_id,
    uint64_t generation,
    const void* payload,
    uint32_t payload_size) {
    DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
        type, 0, session_id, generation, payload_size);
    header.flags = DINOX_WEBRTC_IPC_FLAG_ONEWAY;
    uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
    return dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) ==
            DINOX_WEBRTC_IPC_VALIDATION_OK &&
        write_exact(fd, encoded, sizeof(encoded)) &&
        (payload_size == 0 || write_exact(fd, payload, payload_size));
}

struct ReceivedFrame {
    DinoXWebrtcIpcHeader header = {};
    std::vector<uint8_t> payload;
};

bool receive_frame(int fd, ReceivedFrame* frame) {
    if (frame == nullptr) return false;
    uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
    if (!read_exact(fd, encoded, sizeof(encoded))) return false;
    if (dinox_webrtc_ipc_decode_header(encoded, sizeof(encoded), &frame->header) !=
            DINOX_WEBRTC_IPC_VALIDATION_OK) return false;
    frame->payload.resize(frame->header.payload_size);
    return frame->payload.empty() || read_exact(fd, frame->payload.data(), frame->payload.size());
}

bool frame_is_success(
    const ReceivedFrame& frame,
    uint64_t request_id,
    DinoXWebrtcIpcMessageType expected_type) {
    return frame.header.request_id == request_id &&
        frame.header.message_type == expected_type &&
        frame.payload.size() == sizeof(uint32_t) &&
        frame.payload[0] == DINOX_WEBRTC_STATUS_OK &&
        frame.payload[1] == 0 && frame.payload[2] == 0 && frame.payload[3] == 0;
}

bool receive_success(int fd, uint64_t request_id, DinoXWebrtcIpcMessageType expected_type) {
    // libwebrtc events and control replies share the framed worker stream.
    // A late ICE/gathering event may legally arrive between a request and its
    // reply, including during session teardown.
    for (unsigned int attempt = 0; attempt < 128; ++attempt) {
        ReceivedFrame frame;
        if (!receive_frame(fd, &frame)) return false;
        if ((frame.header.flags & DINOX_WEBRTC_IPC_FLAG_EVENT) != 0) continue;
        return frame_is_success(frame, request_id, expected_type);
    }
    return false;
}

bool receive_response(int fd, uint64_t request_id, ReceivedFrame* out_frame) {
    for (unsigned int attempt = 0; attempt < 128; ++attempt) {
        ReceivedFrame frame;
        if (!receive_frame(fd, &frame)) return false;
        if ((frame.header.flags & DINOX_WEBRTC_IPC_FLAG_EVENT) != 0) continue;
        if (frame.header.request_id != request_id) return false;
        *out_frame = std::move(frame);
        return true;
    }
    return false;
}

int check_background_protocol(int fd) {
    uint64_t request_id=8000;
    const auto exchange=[&](DinoXWebrtcIpcMessageType type,const std::vector<uint8_t>& payload,
                            DinoXWebrtcStatus expected,std::vector<uint8_t>* success=nullptr){
        ReceivedFrame reply;const uint64_t id=++request_id;
        if(!send_request(fd,type,id,88,4,payload.data(),uint32_t(payload.size()))||!receive_response(fd,id,&reply)||
            reply.payload.size()<4||reply.payload[0]!=expected||reply.payload[1]||reply.payload[2]||reply.payload[3])return false;
        if(success)success->assign(reply.payload.begin()+4,reply.payload.end());return true;
    };
    const auto integer=[](const std::vector<uint8_t>& bytes){uint64_t value=0;
        for(size_t i=0;i<bytes.size();++i)value|=uint64_t(bytes[i])<<(8*i);return value;};
    std::vector<uint8_t> begin;
    for(uint32_t value:{1U,1U,3U,0U,3U})append_u32(&begin,value);
    auto invalid=begin;invalid[0]=0;
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,invalid,DINOX_WEBRTC_STATUS_INVALID_ARGUMENT));
    // Forbidden one-way begin must neither allocate nor occupy the single slot.
    DINOX_CHECK(send_oneway_request(fd,DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,88,4,begin.data(),uint32_t(begin.size())));
    std::vector<uint8_t> token;
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,begin,DINOX_WEBRTC_STATUS_OK,&token));
    DINOX_CHECK(token.size()==8&&integer(token)!=0);
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,begin,DINOX_WEBRTC_STATUS_NOT_READY));
    std::vector<uint8_t> chunk;append_u64(&chunk,integer(token)+1);append_u32(&chunk,0);chunk.push_back(1);
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK,chunk,DINOX_WEBRTC_STATUS_NOT_READY));
    // Incomplete commit frees staging; no partially initialized pixels register.
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT,token,DINOX_WEBRTC_STATUS_INVALID_ARGUMENT));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,begin,DINOX_WEBRTC_STATUS_OK,&token));
    chunk.clear();append_u64(&chunk,integer(token));append_u32(&chunk,1);chunk.push_back(1);
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK,chunk,DINOX_WEBRTC_STATUS_INVALID_ARGUMENT));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT,token,DINOX_WEBRTC_STATUS_NOT_READY));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,begin,DINOX_WEBRTC_STATUS_OK,&token));
    chunk.clear();append_u64(&chunk,integer(token));append_u32(&chunk,0);chunk.insert(chunk.end(),{0,255,0});
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK,chunk,DINOX_WEBRTC_STATUS_OK));
    std::vector<uint8_t> asset;
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT,token,DINOX_WEBRTC_STATUS_OK,&asset));
    DINOX_CHECK(asset.size()==4&&integer(asset)!=0);
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE,asset,DINOX_WEBRTC_STATUS_OK));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE,asset,DINOX_WEBRTC_STATUS_OK));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE,asset,DINOX_WEBRTC_STATUS_NOT_READY));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN,begin,DINOX_WEBRTC_STATUS_OK,&token));
    DINOX_CHECK(exchange(DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT,token,DINOX_WEBRTC_STATUS_OK));
    return 0;
}

pid_t spawn_worker(const char* path, int* out_fd) {
    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return -1;
    pid_t child = fork();
    if (child == 0) {
        close(sockets[0]);
        std::string fd = std::to_string(sockets[1]);
        execl(path, path, "--control-fd", fd.c_str(), nullptr);
        _exit(127);
    }
    close(sockets[1]);
    if (child < 0) {
        close(sockets[0]);
        return -1;
    }
    *out_fd = sockets[0];
    return child;
}

}  // namespace

int main(int argc, char** argv) {
    DINOX_CHECK(argc == 2);
    int fd = -1;
    pid_t worker = spawn_worker(argv[1], &fd);
    DINOX_CHECK(worker > 0 && fd >= 0);
    const size_t handshake_size = dinox_webrtc_ipc_build_handshake(nullptr, 0);
    std::vector<char> handshake(handshake_size + 1, '\0');
    DINOX_CHECK(dinox_webrtc_ipc_build_handshake(handshake.data(), handshake.size()) == handshake_size);
    DINOX_CHECK(send_request(
        fd,
        DINOX_WEBRTC_IPC_MESSAGE_HELLO,
        1,
        0,
        0,
        handshake.data(),
        static_cast<uint32_t>(handshake_size)));
    DINOX_CHECK(receive_success(fd, 1, DINOX_WEBRTC_IPC_MESSAGE_HELLO_REPLY));
    const uint32_t audio_mode = DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC;
    DINOX_CHECK(send_request(
        fd,
        DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE,
        2,
        0,
        0,
        &audio_mode,
        sizeof(audio_mode)));
    DINOX_CHECK(receive_success(fd, 2, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DinoXWebrtcIpcSessionConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.audio_enabled = 1;
    config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    config.video_enabled = 1;
    config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    config.max_bundle = 1;
    uint8_t encoded_config[DINOX_WEBRTC_IPC_SESSION_CONFIG_SIZE] = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_session_config(
        &config,
        encoded_config,
        sizeof(encoded_config)) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(send_request(
        fd,
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE,
        3,
        77,
        1,
        encoded_config,
        sizeof(encoded_config)));
    DINOX_CHECK(receive_success(fd, 3, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_EFFECT_CAPABILITIES_GET, 20));
    ReceivedFrame capabilities_reply;
    DINOX_CHECK(receive_response(fd, 20, &capabilities_reply));
    DINOX_CHECK(capabilities_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_REPLY);
    DINOX_CHECK(capabilities_reply.payload.size() ==
        4 + DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE);
    DinoXWebrtcVideoEffectCapabilities capabilities = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_effect_capabilities(
        capabilities_reply.payload.data() + 4,
        capabilities_reply.payload.size() - 4,
        &capabilities) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(capabilities.supported_effect_mask == 8191);
    DINOX_CHECK(capabilities.supported_adjustment_mask == 15);
    DINOX_CHECK(capabilities.supported_background_mask == (capabilities.auto_framing_supported ? 15U : 1U));
    DINOX_CHECK(capabilities.supported_glasses_mask == (capabilities.touch_up_supported ? 15U : 1U) &&
        capabilities.supported_hat_mask == capabilities.supported_glasses_mask &&
        capabilities.supported_beard_mask == capabilities.supported_glasses_mask &&
        capabilities.supported_face_accessory_mask == (capabilities.touch_up_supported ? 7U : 1U) &&
        capabilities.supported_scene_effect_mask == 31 && capabilities.low_light_supported == 1);
    DINOX_CHECK(capabilities.shared_pipeline_supported == 1);

    std::vector<uint8_t> pipeline_create_payload;
    append_u64(&pipeline_create_payload, 4242);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE, 21, 88, 4,
        pipeline_create_payload.data(), pipeline_create_payload.size()));
    DINOX_CHECK(receive_success(fd, 21, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    DINOX_CHECK(check_background_protocol(fd)==0);

    std::vector<uint8_t> attachment;
    append_u64(&attachment, 77);
    append_u64(&attachment, 1);
    append_u64(&attachment, 1);
    append_u32(&attachment, 1);
    DINOX_CHECK(attachment.size() == DINOX_WEBRTC_IPC_VIDEO_PIPELINE_ATTACHMENT_SIZE);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH, 22, 88, 4,
        attachment.data(), attachment.size()));
    DINOX_CHECK(receive_success(fd, 22, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    // A logical pipeline has exactly one local-preview publisher. A second
    // ordinary subscriber may be added later for fan-out, but it must never
    // replace the existing publisher implicitly.
    DINOX_CHECK(send_request(
        fd,
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE,
        220,
        78,
        1,
        encoded_config,
        sizeof(encoded_config)));
    DINOX_CHECK(receive_success(fd, 220, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    std::vector<uint8_t> second_preview_attachment;
    append_u64(&second_preview_attachment, 78);
    append_u64(&second_preview_attachment, 1);
    append_u64(&second_preview_attachment, 1);
    append_u32(&second_preview_attachment, 1);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH, 221, 88, 4,
        second_preview_attachment.data(), second_preview_attachment.size()));
    ReceivedFrame second_preview_reply;
    DINOX_CHECK(receive_response(fd, 221, &second_preview_reply));
    DINOX_CHECK(second_preview_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);
    DINOX_CHECK(second_preview_reply.payload.size() >= 4);
    DINOX_CHECK(second_preview_reply.payload[0] == DINOX_WEBRTC_STATUS_NOT_READY &&
        second_preview_reply.payload[1] == 0 && second_preview_reply.payload[2] == 0 &&
        second_preview_reply.payload[3] == 0);

    // Reuse the rejected session as an ordinary subscriber. With effects Off,
    // one publisher frame must synchronously reach both native video sources;
    // only the publisher produces a local-preview ring notification.
    second_preview_attachment.clear();
    append_u64(&second_preview_attachment, 78);
    append_u64(&second_preview_attachment, 1);
    append_u64(&second_preview_attachment, 1);
    append_u32(&second_preview_attachment, 0);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH, 223, 88, 4,
        second_preview_attachment.data(), second_preview_attachment.size()));
    DINOX_CHECK(receive_success(fd, 223, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    std::vector<uint8_t> synthetic_video_payload;
    append_u32(&synthetic_video_payload, 320);
    append_u32(&synthetic_video_payload, 180);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO, 224, 77, 1,
        synthetic_video_payload.data(), synthetic_video_payload.size()));
    DINOX_CHECK(receive_success(fd, 224, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET, 225, 77, 1));
    ReceivedFrame publisher_state_reply;
    DINOX_CHECK(receive_response(fd, 225, &publisher_state_reply));
    DINOX_CHECK(publisher_state_reply.payload.size() ==
        4 + dinox_webrtc_ipc_session_state_size());
    DinoXWebrtcSessionState publisher_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_state(
        publisher_state_reply.payload.data() + 4,
        publisher_state_reply.payload.size() - 4,
        &publisher_state) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(publisher_state.local_video_source_frame_count == 1);
    DINOX_CHECK(publisher_state.local_video_source_last_width == 320);
    DINOX_CHECK(publisher_state.local_video_source_last_height == 180);

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET, 226, 78, 1));
    ReceivedFrame subscriber_state_reply;
    DINOX_CHECK(receive_response(fd, 226, &subscriber_state_reply));
    DINOX_CHECK(subscriber_state_reply.payload.size() ==
        4 + dinox_webrtc_ipc_session_state_size());
    DinoXWebrtcSessionState subscriber_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_state(
        subscriber_state_reply.payload.data() + 4,
        subscriber_state_reply.payload.size() - 4,
        &subscriber_state) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(subscriber_state.local_video_source_frame_count == 1);
    DINOX_CHECK(subscriber_state.local_video_source_last_width == 320);
    DINOX_CHECK(subscriber_state.local_video_source_last_height == 180);

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE, 222, 78, 1));
    DINOX_CHECK(receive_success(fd, 222, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET, 227, 88, 4));
    ReceivedFrame after_subscriber_close_reply;
    DINOX_CHECK(receive_response(fd, 227, &after_subscriber_close_reply));
    DinoXWebrtcVideoPipelineState after_subscriber_close = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
        after_subscriber_close_reply.payload.data() + 4,
        after_subscriber_close_reply.payload.size() - 4,
        &after_subscriber_close) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(after_subscriber_close.subscriber_count == 1);
    DINOX_CHECK(after_subscriber_close.preview_subscriber_id == 77);

    synthetic_video_payload.clear();
    append_u32(&synthetic_video_payload, 640);
    append_u32(&synthetic_video_payload, 360);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO, 228, 77, 1,
        synthetic_video_payload.data(), synthetic_video_payload.size()));
    DINOX_CHECK(receive_success(fd, 228, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET, 229, 77, 1));
    DINOX_CHECK(receive_response(fd, 229, &publisher_state_reply));
    DINOX_CHECK(dinox_webrtc_ipc_decode_session_state(
        publisher_state_reply.payload.data() + 4,
        publisher_state_reply.payload.size() - 4,
        &publisher_state) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(publisher_state.local_video_source_frame_count == 2);
    DINOX_CHECK(publisher_state.local_video_source_last_width == 640);
    DINOX_CHECK(publisher_state.local_video_source_last_height == 360);

    DinoXWebrtcVideoEffectConfig effect_config = dinox_webrtc_video_effect_config_default();
    effect_config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    uint8_t encoded_effect[DINOX_WEBRTC_IPC_VIDEO_EFFECT_CONFIG_SIZE] = {};
    DINOX_CHECK(dinox_webrtc_ipc_encode_video_effect_config(
        &effect_config, encoded_effect, sizeof(encoded_effect)) == DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG, 23, 88, 4,
        encoded_effect, sizeof(encoded_effect)));
    bool received_config_reply = false;
    bool received_applied_event = false;
    for (unsigned int attempt = 0;
            attempt < 128 && (!received_config_reply || !received_applied_event);
            ++attempt) {
        ReceivedFrame frame;
        DINOX_CHECK(receive_frame(fd, &frame));
        if (frame.header.request_id == 23) {
            DINOX_CHECK(frame.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_REPLY);
            DINOX_CHECK(frame.payload.size() == 12 && frame.payload[0] == DINOX_WEBRTC_STATUS_OK);
            received_config_reply = true;
        } else if (frame.header.message_type ==
                DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE) {
            // The accepted revision must be observable before APPLIED.
            DINOX_CHECK(received_config_reply);
            DinoXWebrtcVideoPipelineState applied = {};
            DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
                frame.payload.data(), frame.payload.size(), &applied) ==
                DINOX_WEBRTC_IPC_VALIDATION_OK);
            DINOX_CHECK(applied.pipeline_id == 88);
            DINOX_CHECK(applied.pipeline_generation == 4);
            DINOX_CHECK(applied.logical_call_id == 4242);
            DINOX_CHECK(applied.application_state ==
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED);
            DINOX_CHECK(applied.accepted_revision == 1 && applied.applied_revision == 1);
            DINOX_CHECK(applied.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);
            DINOX_CHECK(applied.subscriber_count == 1);
            DINOX_CHECK(applied.preview_subscriber_id == 77);
            DINOX_CHECK(applied.preview_subscriber_generation == 1);
            received_applied_event = true;
        }
    }
    DINOX_CHECK(received_config_reply && received_applied_event);

    // SET_CONFIG is revision-bearing and cannot be one-way.  The worker must
    // reject it without arming the reply barrier or mutating state, then remain
    // responsive to the next normal request.
    DINOX_CHECK(send_oneway_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG, 88, 4,
        encoded_effect, sizeof(encoded_effect)));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET, 24, 88, 4));
    ReceivedFrame state_reply;
    DINOX_CHECK(receive_response(fd, 24, &state_reply));
    DINOX_CHECK(state_reply.payload.size() == 4 + DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE);
    DinoXWebrtcVideoPipelineState pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_ipc_decode_video_pipeline_state(
        state_reply.payload.data() + 4, state_reply.payload.size() - 4, &pipeline_state) ==
        DINOX_WEBRTC_IPC_VALIDATION_OK);
    DINOX_CHECK(pipeline_state.logical_call_id == 4242);
    DINOX_CHECK(pipeline_state.accepted_revision == 1);
    DINOX_CHECK(pipeline_state.applied_revision == 1);
    DINOX_CHECK(pipeline_state.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET, 25, 88, 5));
    ReceivedFrame stale_pipeline_reply;
    DINOX_CHECK(receive_response(fd, 25, &stale_pipeline_reply));
    DINOX_CHECK(stale_pipeline_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG, 26, 88, 4,
        encoded_effect, sizeof(encoded_effect) - 1));
    ReceivedFrame truncated_reply;
    DINOX_CHECK(receive_response(fd, 26, &truncated_reply));
    DINOX_CHECK(truncated_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);

    std::vector<uint8_t> detachment;
    append_u64(&detachment, 77);
    append_u64(&detachment, 1);
    append_u64(&detachment, 1);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH, 27, 88, 4,
        detachment.data(), detachment.size()));
    DINOX_CHECK(receive_success(fd, 27, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    attachment.clear();
    append_u64(&attachment, 77);
    append_u64(&attachment, 1);
    append_u64(&attachment, 2);
    append_u32(&attachment, 0);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH, 28, 88, 4,
        attachment.data(), attachment.size()));
    DINOX_CHECK(receive_success(fd, 28, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH, 29, 88, 4,
        detachment.data(), detachment.size()));
    ReceivedFrame stale_subscriber_reply;
    DINOX_CHECK(receive_response(fd, 29, &stale_subscriber_reply));
    DINOX_CHECK(stale_subscriber_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);
    detachment.clear();
    append_u64(&detachment, 77);
    append_u64(&detachment, 1);
    append_u64(&detachment, 2);
    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH, 30, 88, 4,
        detachment.data(), detachment.size()));
    DINOX_CHECK(receive_success(fd, 30, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET, 31, 999, 1));
    ReceivedFrame unknown_pipeline_reply;
    DINOX_CHECK(receive_response(fd, 31, &unknown_pipeline_reply));
    DINOX_CHECK(unknown_pipeline_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);

    DINOX_CHECK(send_request(
        fd, DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY, 32, 88, 4));
    DINOX_CHECK(receive_success(fd, 32, DINOX_WEBRTC_IPC_MESSAGE_REPLY));

    DINOX_CHECK(send_request(
        fd,
        DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER,
        4,
        77,
        1));
    bool received_offer_reply = false;
    bool received_offer_event = false;
    for (unsigned int attempt = 0; attempt < 8 && (!received_offer_reply || !received_offer_event); ++attempt) {
        ReceivedFrame frame;
        DINOX_CHECK(receive_frame(fd, &frame));
        if (frame_is_success(frame, 4, DINOX_WEBRTC_IPC_MESSAGE_REPLY)) {
            received_offer_reply = true;
            continue;
        }
        if (frame.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION &&
                frame.header.session_id == 77 && frame.header.generation == 1 &&
                frame.payload.size() > 4 && frame.payload[0] == DINOX_WEBRTC_SDP_TYPE_OFFER &&
                frame.payload[1] == 0 && frame.payload[2] == 0 && frame.payload[3] == 0) {
            std::string sdp(frame.payload.begin() + 4, frame.payload.end());
            DINOX_CHECK(sdp.find("m=audio") != std::string::npos);
            DINOX_CHECK(sdp.find("m=video") != std::string::npos);
            received_offer_event = true;
        }
    }
    DINOX_CHECK(received_offer_reply && received_offer_event);

    DINOX_CHECK(send_request(fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE, 5, 77, 2));
    ReceivedFrame stale_reply;
    do {
        DINOX_CHECK(receive_frame(fd, &stale_reply));
    } while ((stale_reply.header.flags & DINOX_WEBRTC_IPC_FLAG_EVENT) != 0);
    DINOX_CHECK(stale_reply.header.request_id == 5);
    DINOX_CHECK(stale_reply.header.message_type == DINOX_WEBRTC_IPC_MESSAGE_ERROR);

    DINOX_CHECK(send_request(fd, DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE, 6, 77, 1));
    DINOX_CHECK(receive_success(fd, 6, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    DINOX_CHECK(send_request(fd, DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CLOSE, 7));
    DINOX_CHECK(receive_success(fd, 7, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    DINOX_CHECK(send_request(fd, DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN, 8));
    DINOX_CHECK(receive_success(fd, 8, DINOX_WEBRTC_IPC_MESSAGE_REPLY));
    close(fd);
    int status = 0;
    DINOX_CHECK(waitpid(worker, &status, 0) == worker);
    DINOX_CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    worker = spawn_worker(argv[1], &fd);
    DINOX_CHECK(worker > 0 && fd >= 0);
    DINOX_CHECK(kill(worker, SIGKILL) == 0);
    DINOX_CHECK(waitpid(worker, &status, 0) == worker);
    DINOX_CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
    close(fd);
    return 0;
}
