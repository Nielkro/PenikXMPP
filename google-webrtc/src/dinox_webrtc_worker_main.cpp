#include "dinox_webrtc.h"
#include "dinox_webrtc_ipc.h"
#include "dinox_webrtc_video_ring.hpp"
#include "dinox_webrtc_windows_pipe.hpp"
#include "dinox_webrtc_video_background_protocol.hpp"

#include <cerrno>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <thread>
#include <chrono>
#include <algorithm>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <unistd.h>
#include <sys/mman.h>
#endif

namespace {

#ifdef _WIN32
using ControlHandle = HANDLE;
using dinox::webrtc_windows_pipe::read_exact;
using dinox::webrtc_windows_pipe::write_exact;
#else
using ControlHandle = int;

bool read_exact(int fd, void* output, size_t size) {
    uint8_t* cursor = static_cast<uint8_t*>(output);
    while (size > 0) {
        const ssize_t count = read(fd, cursor, size);
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
        const ssize_t count = write(fd, cursor, size);
        if (count < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        cursor += static_cast<size_t>(count);
        size -= static_cast<size_t>(count);
    }
    return true;
}
#endif

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

uint32_t read_u32(const uint8_t* input) {
    return static_cast<uint32_t>(input[0]) |
        (static_cast<uint32_t>(input[1]) << 8) |
        (static_cast<uint32_t>(input[2]) << 16) |
        (static_cast<uint32_t>(input[3]) << 24);
}

uint64_t read_u64(const uint8_t* input) {
    uint64_t value = 0;
    for (unsigned int byte = 0; byte < 8; ++byte) {
        value |= static_cast<uint64_t>(input[byte]) << (byte * 8);
    }
    return value;
}

void worker_device_debug(
    const char* phase,
    uint32_t type,
    DinoXWebrtcStatus status = DINOX_WEBRTC_STATUS_OK) {
    const char* enabled = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG");
    if (enabled == nullptr ||
            (std::strcmp(enabled, "1") != 0 &&
             std::strcmp(enabled, "true") != 0 &&
             std::strcmp(enabled, "yes") != 0)) {
        return;
    }

    const char* path = std::getenv("DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE");
    FILE* output = stderr;
    if (path != nullptr && path[0] != '\0') {
        FILE* file = std::fopen(path, "a");
        if (file != nullptr) output = file;
    }
#ifdef _WIN32
    const unsigned long process_id = GetCurrentProcessId();
#else
    const unsigned long process_id = static_cast<unsigned long>(getpid());
#endif
    std::fprintf(
        output,
        "DinoX WebRTC worker: phase=%s pid=%lu type=%u status=%d\n",
        phase == nullptr ? "unknown" : phase,
        process_id,
        static_cast<unsigned int>(type),
        static_cast<int>(status));
    std::fflush(output);
    if (output != stderr) std::fclose(output);
}

class WorkerConnection final {
 public:
    explicit WorkerConnection(ControlHandle fd) : fd_(fd) {}

    bool send_frame(
    DinoXWebrtcIpcMessageType type,
    uint64_t request_id,
    uint64_t session_id,
    uint64_t generation,
    const void* payload,
    uint32_t payload_size) {
        DinoXWebrtcIpcHeader header = dinox_webrtc_ipc_header_default(
            type,
            request_id,
            session_id,
            generation,
            payload_size);
        uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
        if (dinox_webrtc_ipc_encode_header(&header, encoded, sizeof(encoded)) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            return false;
        }
        std::lock_guard<std::mutex> lock(write_mutex_);
        return write_exact(fd_, encoded, sizeof(encoded)) &&
            (payload_size == 0 || write_exact(fd_, payload, payload_size));
    }

    bool send_status(
        const DinoXWebrtcIpcHeader& request,
        DinoXWebrtcStatus status,
        const char* detail = nullptr,
        const std::vector<uint8_t>* success_payload = nullptr) {
        if (status == DINOX_WEBRTC_STATUS_OK) {
            std::vector<uint8_t> payload;
            append_u32(&payload, DINOX_WEBRTC_STATUS_OK);
            if (success_payload != nullptr) {
                payload.insert(payload.end(), success_payload->begin(), success_payload->end());
            }
            return send_frame(
                request.message_type == DINOX_WEBRTC_IPC_MESSAGE_HELLO
                    ? DINOX_WEBRTC_IPC_MESSAGE_HELLO_REPLY
                    : DINOX_WEBRTC_IPC_MESSAGE_REPLY,
                request.request_id,
                request.session_id,
                request.generation,
                payload.data(),
                static_cast<uint32_t>(payload.size()));
        }
        std::string message = detail == nullptr ? dinox_webrtc_status_to_string(status) : detail;
        std::vector<uint8_t> payload;
        append_u32(&payload, static_cast<uint32_t>(status));
        payload.insert(payload.end(), message.begin(), message.end());
        return send_frame(
            DINOX_WEBRTC_IPC_MESSAGE_ERROR,
            request.request_id,
            request.session_id,
            request.generation,
            payload.data(),
            static_cast<uint32_t>(payload.size()));
    }

 private:
    ControlHandle fd_;
    std::mutex write_mutex_;
};

struct WorkerVideoFlowCounters {
    std::mutex mailbox_mutex;
    std::atomic<uint64_t> received{0};
    std::atomic<uint64_t> published{0};
    std::atomic<uint64_t> replaced{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<int> last_width{0};
    std::atomic<int> last_height{0};
};

bool call_video_debug_enabled() {
    static const bool enabled = [] {
        const char* value = std::getenv("DINOX_GOOGLE_WEBRTC_CALL_DEBUG");
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
    return enabled;
}

bool is_power_of_two(uint64_t value) {
    return value != 0 && (value & (value - 1)) == 0;
}

void maybe_log_video_flow(
    const WorkerVideoFlowCounters& counters,
    const char* kind,
    uint64_t session_id,
    int width,
    int height,
    bool noteworthy) {
    if (!call_video_debug_enabled()) return;
    const uint64_t received = counters.received.load(std::memory_order_relaxed);
    if (!noteworthy && received != 1 && received % 120 != 0) return;
    std::fprintf(
        stderr,
        "DinoX WebRTC video flow: stage=worker-ring kind=%s session=%llu "
        "received=%llu published=%llu replaced=%llu dropped=%llu size=%dx%d\n",
        kind,
        static_cast<unsigned long long>(session_id),
        static_cast<unsigned long long>(received),
        static_cast<unsigned long long>(counters.published.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(counters.replaced.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(counters.dropped.load(std::memory_order_relaxed)),
        width,
        height);
}

struct WorkerSession {
    WorkerConnection* connection = nullptr;
    uint64_t session_id = 0;
    uint64_t generation = 0;
    DinoXWebrtcSession* native_session = nullptr;
    void* video_ring = nullptr;
    size_t video_ring_size = 0;
    WorkerVideoFlowCounters remote_video_flow;
    WorkerVideoFlowCounters local_video_flow;

    ~WorkerSession() {
        if (native_session != nullptr) {
            dinox_webrtc_session_free(native_session);
            native_session = nullptr;
        }
    }
};

struct WorkerRecorder {
    WorkerConnection* connection = nullptr;
    uint64_t recorder_id = 0;
    uint64_t generation = 0;
    DinoXWebrtcMediaRecorder* native_recorder = nullptr;
    void* video_ring = nullptr;
    size_t video_ring_size = 0;

    ~WorkerRecorder() {
        if (native_recorder != nullptr) {
            dinox_webrtc_media_recorder_free(native_recorder);
            native_recorder = nullptr;
        }
    }
};

struct WorkerPipelineAttachment {
    uint64_t session_generation = 0;
    uint64_t subscriber_generation = 0;
    bool preview_publisher = false;
};

struct WorkerPipeline {
    struct BackgroundUpload {
        uint64_t ticket=0;
        uint32_t width=0,height=0,stride=0,format=0;
        size_t used=0;
        std::vector<uint8_t> bytes;
        std::chrono::steady_clock::time_point deadline;
    };
    std::optional<BackgroundUpload> background_upload;
    uint64_t next_background_upload=1;
    WorkerConnection* connection = nullptr;
    uint64_t pipeline_id = 0;
    uint64_t generation = 0;
    uint64_t logical_call_id = 0;
    DinoXWebrtcVideoPipeline* native_pipeline = nullptr;
    std::mutex mutex;
    std::unordered_map<uint64_t, WorkerPipelineAttachment> attachments;
    std::unordered_map<uint64_t, uint64_t> subscriber_generations;
    bool defer_state_events_until_reply = false;
    bool has_deferred_state_event = false;
    DinoXWebrtcVideoPipelineState deferred_state_event = {};

    ~WorkerPipeline() {
        if (native_pipeline != nullptr) {
            dinox_webrtc_video_pipeline_free(native_pipeline);
            native_pipeline = nullptr;
        }
    }
};

void send_video_pipeline_state_event(
    WorkerPipeline* pipeline,
    const DinoXWebrtcVideoPipelineState& state) {
    uint8_t payload[DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE] = {};
    if (dinox_webrtc_ipc_encode_video_pipeline_state(&state, payload, sizeof(payload)) !=
            DINOX_WEBRTC_IPC_VALIDATION_OK) {
        return;
    }
    pipeline->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_PIPELINE_STATE,
        0, pipeline->pipeline_id, pipeline->generation,
        payload, sizeof(payload));
}

void flush_deferred_video_pipeline_state_events(WorkerPipeline* pipeline) {
    if (pipeline == nullptr || pipeline->connection == nullptr) return;
    while (true) {
        DinoXWebrtcVideoPipelineState state = {};
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            if (!pipeline->defer_state_events_until_reply) return;
            if (!pipeline->has_deferred_state_event) {
                pipeline->defer_state_events_until_reply = false;
                return;
            }
            state = pipeline->deferred_state_event;
            pipeline->has_deferred_state_event = false;
        }
        send_video_pipeline_state_event(pipeline, state);
    }
}

void apply_worker_pipeline_identity(
    WorkerPipeline* pipeline,
    DinoXWebrtcVideoPipelineState* state) {
    state->pipeline_id = pipeline->pipeline_id;
    state->pipeline_generation = pipeline->generation;
    state->logical_call_id = pipeline->logical_call_id;
    state->subscriber_count = static_cast<uint32_t>(pipeline->attachments.size());
    state->preview_subscriber_id = 0;
    state->preview_subscriber_generation = 0;
    for (const auto& [session_id, attachment] : pipeline->attachments) {
        if (attachment.preview_publisher) {
            state->preview_subscriber_id = session_id;
            state->preview_subscriber_generation = attachment.subscriber_generation;
            break;
        }
    }
}

void on_video_pipeline_state_changed(
    DinoXWebrtcVideoPipeline*,
    const DinoXWebrtcVideoPipelineState* native_state,
    void* user_data) {
    auto* pipeline = static_cast<WorkerPipeline*>(user_data);
    if (pipeline == nullptr || pipeline->connection == nullptr || native_state == nullptr) return;
    DinoXWebrtcVideoPipelineState state = *native_state;
    {
        std::lock_guard<std::mutex> lock(pipeline->mutex);
        apply_worker_pipeline_identity(pipeline, &state);
        if (pipeline->defer_state_events_until_reply) {
            // SET_CONFIG has one reply barrier.  Keep only the newest state so
            // a faulty/native burst cannot turn the control path into an
            // unbounded queue; the eventual state remains revision-correct.
            pipeline->deferred_state_event = state;
            pipeline->has_deferred_state_event = true;
            return;
        }
    }
    send_video_pipeline_state_event(pipeline, state);
}

void emit_video_frame(
    WorkerSession* session,
    dinox::webrtc_worker::VideoFrameKind kind,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id) {
    if (session == nullptr || session->connection == nullptr || session->video_ring == nullptr) return;
    WorkerVideoFlowCounters& counters =
        kind == dinox::webrtc_worker::VideoFrameKind::Remote
            ? session->remote_video_flow
            : session->local_video_flow;
    const char* kind_name =
        kind == dinox::webrtc_worker::VideoFrameKind::Remote ? "remote" : "local";
    // One notification owns one READY mailbox slot until the proxy consumes
    // it. Serialize each individual stream across write + notification; the
    // tokenized ring state still lets Local and Remote progress concurrently.
    std::lock_guard<std::mutex> mailbox_lock(counters.mailbox_mutex);
    counters.received.fetch_add(1, std::memory_order_relaxed);
    const int previous_width = counters.last_width.exchange(width, std::memory_order_relaxed);
    const int previous_height = counters.last_height.exchange(height, std::memory_order_relaxed);
    const bool resolution_changed = previous_width != 0 &&
        (previous_width != width || previous_height != height);
    uint32_t slot = 0;
    uint64_t sequence = 0;
    bool replaced_ready_frame = false;
    bool notification_already_pending = false;
    if (!dinox::webrtc_worker::write_video_ring_frame(
            session->video_ring,
            session->video_ring_size,
            session->session_id,
            session->generation,
            kind,
            bgra_data,
            width,
            height,
            stride,
            frame_id,
            true,
            &slot,
            &sequence,
            &replaced_ready_frame,
            &notification_already_pending)) {
        const uint64_t dropped = counters.dropped.fetch_add(1, std::memory_order_relaxed) + 1;
        maybe_log_video_flow(
            counters, kind_name, session->session_id, width, height,
            is_power_of_two(dropped));
        return;
    }
    if (replaced_ready_frame) {
        const uint64_t replaced = counters.replaced.fetch_add(1, std::memory_order_relaxed) + 1;
        maybe_log_video_flow(
            counters, kind_name, session->session_id, width, height,
            is_power_of_two(replaced));
    }
    if (notification_already_pending) {
        // The original notification now names the preserved notification
        // sequence and will consume this newest frame. Sending another event
        // here recreates an unbounded queue of stale sequence tokens.
        return;
    }
    std::vector<uint8_t> payload;
    append_u32(&payload, slot);
    append_u64(&payload, sequence);
    if (!session->connection->send_frame(
        kind == dinox::webrtc_worker::VideoFrameKind::Remote
            ? DINOX_WEBRTC_IPC_MESSAGE_EVENT_VIDEO_FRAME
            : DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_VIDEO_FRAME,
        0,
        session->session_id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()))) {
        dinox::webrtc_worker::discard_video_ring_frame(
            session->video_ring, session->video_ring_size, slot, sequence);
        const uint64_t dropped = counters.dropped.fetch_add(1, std::memory_order_relaxed) + 1;
        maybe_log_video_flow(
            counters, kind_name, session->session_id, width, height,
            is_power_of_two(dropped));
        return;
    }
    counters.published.fetch_add(1, std::memory_order_relaxed);
    maybe_log_video_flow(
        counters, kind_name, session->session_id, width, height, resolution_changed);
}

void on_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data) {
    emit_video_frame(
        static_cast<WorkerSession*>(user_data),
        dinox::webrtc_worker::VideoFrameKind::Remote,
        bgra_data, width, height, stride, frame_id);
}

void on_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data) {
    emit_video_frame(
        static_cast<WorkerSession*>(user_data),
        dinox::webrtc_worker::VideoFrameKind::Local,
        bgra_data, width, height, stride, frame_id);
}

void on_recorder_started(DinoXWebrtcMediaRecorder*, void* user_data) {
    auto* recorder = static_cast<WorkerRecorder*>(user_data);
    if (recorder == nullptr || recorder->connection == nullptr) return;
    recorder->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STARTED,
        0, recorder->recorder_id, recorder->generation, nullptr, 0);
}

void on_recorder_stopped(DinoXWebrtcMediaRecorder*, void* user_data) {
    auto* recorder = static_cast<WorkerRecorder*>(user_data);
    if (recorder == nullptr || recorder->connection == nullptr) return;
    recorder->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_STOPPED,
        0, recorder->recorder_id, recorder->generation, nullptr, 0);
}

void on_recorder_error(
    DinoXWebrtcMediaRecorder*,
    DinoXWebrtcStatus status,
    const char* message,
    void* user_data) {
    auto* recorder = static_cast<WorkerRecorder*>(user_data);
    if (recorder == nullptr || recorder->connection == nullptr) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(status));
    const char* detail = message == nullptr ? dinox_webrtc_status_to_string(status) : message;
    payload.insert(payload.end(), detail, detail + std::strlen(detail));
    recorder->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_ERROR,
        0, recorder->recorder_id, recorder->generation,
        payload.data(), static_cast<uint32_t>(payload.size()));
}

void on_recorder_audio_frame(
    DinoXWebrtcMediaRecorder*,
    const uint8_t* pcm_data,
    size_t byte_count,
    int sample_rate,
    int channels,
    int bytes_per_sample,
    uint64_t frame_id,
    void* user_data) {
    auto* recorder = static_cast<WorkerRecorder*>(user_data);
    if (recorder == nullptr || recorder->connection == nullptr || pcm_data == nullptr ||
            byte_count > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD - 24) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(sample_rate));
    append_u32(&payload, static_cast<uint32_t>(channels));
    append_u32(&payload, static_cast<uint32_t>(bytes_per_sample));
    append_u32(&payload, static_cast<uint32_t>(byte_count));
    append_u64(&payload, frame_id);
    payload.insert(payload.end(), pcm_data, pcm_data + byte_count);
    recorder->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_AUDIO_FRAME,
        0, recorder->recorder_id, recorder->generation,
        payload.data(), static_cast<uint32_t>(payload.size()));
}

void on_recorder_video_frame(
    DinoXWebrtcMediaRecorder*,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data) {
    auto* recorder = static_cast<WorkerRecorder*>(user_data);
    if (recorder == nullptr || recorder->connection == nullptr || recorder->video_ring == nullptr) return;
    uint32_t slot = 0;
    uint64_t sequence = 0;
    if (!dinox::webrtc_worker::write_video_ring_frame(
            recorder->video_ring, recorder->video_ring_size,
            recorder->recorder_id, recorder->generation,
            dinox::webrtc_worker::VideoFrameKind::Recorder,
            bgra_data, width, height, stride, frame_id, false,
            &slot, &sequence)) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, slot);
    append_u64(&payload, sequence);
    if (!recorder->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_RECORDER_VIDEO_FRAME,
        0, recorder->recorder_id, recorder->generation,
        payload.data(), static_cast<uint32_t>(payload.size()))) {
        dinox::webrtc_worker::discard_video_ring_frame(
            recorder->video_ring, recorder->video_ring_size, slot, sequence);
    }
}

void on_local_description(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    const char* sdp,
    void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr || sdp == nullptr) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    payload.insert(payload.end(), sdp, sdp + std::strlen(sdp));
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION,
        0,
        session->session_id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

void on_local_description_prepared(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    const char* sdp,
    void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr || sdp == nullptr) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    payload.insert(payload.end(), sdp, sdp + std::strlen(sdp));
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_LOCAL_DESCRIPTION_PREPARED,
        0, session->session_id, session->generation,
        payload.data(), static_cast<uint32_t>(payload.size()));
}

void on_remote_description_set(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(type));
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_REMOTE_DESCRIPTION_SET,
        0,
        session->session_id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

void on_ice_candidate(
    DinoXWebrtcSession*,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate,
    void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr ||
            sdp_mid == nullptr || candidate == nullptr || sdp_mline_index < 0) return;
    const size_t mid_size = std::strlen(sdp_mid);
    const size_t candidate_size = std::strlen(candidate);
    if (mid_size > 4096 || candidate_size > DINOX_WEBRTC_IPC_MAX_CONTROL_PAYLOAD - 8 - mid_size) return;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(sdp_mline_index));
    append_u32(&payload, static_cast<uint32_t>(mid_size));
    payload.insert(payload.end(), sdp_mid, sdp_mid + mid_size);
    payload.insert(payload.end(), candidate, candidate + candidate_size);
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_CANDIDATE,
        0,
        session->session_id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

void on_ice_gathering_complete(DinoXWebrtcSession*, void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr) return;
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_ICE_GATHERING_COMPLETE,
        0,
        session->session_id,
        session->generation,
        nullptr,
        0);
}

void on_session_error(
    DinoXWebrtcSession*,
    DinoXWebrtcStatus status,
    const char* message,
    void* user_data) {
    auto* session = static_cast<WorkerSession*>(user_data);
    if (session == nullptr || session->connection == nullptr) return;
    const char* detail = message == nullptr ? dinox_webrtc_status_to_string(status) : message;
    std::vector<uint8_t> payload;
    append_u32(&payload, static_cast<uint32_t>(status));
    payload.insert(payload.end(), detail, detail + std::strlen(detail));
    session->connection->send_frame(
        DINOX_WEBRTC_IPC_MESSAGE_EVENT_SESSION_ERROR,
        0,
        session->session_id,
        session->generation,
        payload.data(),
        static_cast<uint32_t>(payload.size()));
}

class WorkerState final {
 public:
    WorkerState(ControlHandle fd, void* video_ring, size_t video_ring_size)
        : connection_(fd), video_ring_(video_ring), video_ring_size_(video_ring_size) {}

    ~WorkerState() {
        pipelines_.clear();
        recorders_.clear();
        sessions_.clear();
        if (context_ != nullptr) dinox_webrtc_context_free(context_);
    }

    bool hello_complete() const { return hello_complete_; }

    void report_oneway_error(
        const DinoXWebrtcIpcHeader& request,
        DinoXWebrtcStatus status) {
        if (request.message_type >= DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE &&
                request.message_type <= DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO) {
            WorkerSession* session = find_session(request);
            if (session != nullptr) {
                on_session_error(
                    session->native_session,
                    status,
                    "Google/libwebrtc worker command failed",
                    session);
            }
            return;
        }
        if (request.message_type >= DINOX_WEBRTC_IPC_MESSAGE_RECORDER_START &&
                request.message_type <= DINOX_WEBRTC_IPC_MESSAGE_RECORDER_PUSH_SYNTHETIC) {
            WorkerRecorder* recorder = find_recorder(request);
            if (recorder != nullptr) {
                on_recorder_error(
                    recorder->native_recorder,
                    status,
                    "Google/libwebrtc worker recorder command failed",
                    recorder);
            }
        }
    }

    DinoXWebrtcStatus handle(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        bool* out_running) {
        reply_payload_.clear();
        switch (request.message_type) {
            case DINOX_WEBRTC_IPC_MESSAGE_HELLO: {
                const size_t expected_size = dinox_webrtc_ipc_build_handshake(nullptr, 0);
                std::vector<char> expected(expected_size + 1, '\0');
                dinox_webrtc_ipc_build_handshake(expected.data(), expected.size());
                if (hello_complete_ || payload.size() != expected_size ||
                        std::memcmp(payload.data(), expected.data(), expected_size) != 0) {
                    return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                }
                hello_complete_ = true;
                return DINOX_WEBRTC_STATUS_OK;
            }
            case DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CREATE: {
                if (context_ != nullptr || payload.size() != sizeof(uint32_t)) {
                    return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                }
                const uint32_t mode = read_u32(payload.data());
                return dinox_webrtc_context_new_with_audio_device_mode(
                    static_cast<DinoXWebrtcAudioDeviceMode>(mode),
                    &context_);
            }
            case DINOX_WEBRTC_IPC_MESSAGE_CONTEXT_CLOSE:
                if (context_ == nullptr || !payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                pipelines_.clear();
                recorders_.clear();
                sessions_.clear();
                dinox_webrtc_context_free(context_);
                context_ = nullptr;
                return DINOX_WEBRTC_STATUS_OK;
            case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_LIST:
                return list_audio_devices(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_SELECT:
                return select_audio_device(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_GET:
                return get_audio_device_volume(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_AUDIO_DEVICE_VOLUME_SET:
                return set_audio_device_volume(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_DEVICE_LIST:
                return list_video_devices(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_EFFECT_CAPABILITIES_GET:
                return get_video_effect_capabilities(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_TEST_TONE_PLAY:
                return play_test_tone(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_CLIP_PLAY:
                return play_audio_test_clip(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_TEST_AUDIO_PLAYOUT_STOP:
                if (!payload.empty() || context_ == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                return dinox_webrtc_context_stop_audio_test_playout(context_);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_START:
                return start_media_audio_playout(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PUSH:
                return push_media_audio_playout(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_PAUSE:
                return pause_media_audio_playout(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FLUSH:
                if (!payload.empty() || context_ == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                return dinox_webrtc_context_media_audio_playout_flush(context_);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_FINISH:
                return finish_media_audio_playout(payload);
            case DINOX_WEBRTC_IPC_MESSAGE_MEDIA_AUDIO_PLAYOUT_STOP:
                if (!payload.empty() || context_ == nullptr) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                return dinox_webrtc_context_media_audio_playout_stop(context_);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_CREATE:
                return create_video_pipeline(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DESTROY:
                return destroy_video_pipeline(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_ATTACH:
                return attach_video_pipeline(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DETACH:
                return detach_video_pipeline(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG:
                return set_video_pipeline_config(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_STATE_GET:
                return get_video_pipeline_state(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_DIAGNOSTICS_GET:
                return get_video_pipeline_diagnostics(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_BUILTIN:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE:
            case DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE:
                return background_command(request,payload);
            case DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_ABORT:
                if (!test_faults_enabled() || !payload.empty()) return DINOX_WEBRTC_STATUS_NOT_READY;
                std::_Exit(86);
            case DINOX_WEBRTC_IPC_MESSAGE_TEST_WORKER_HANG:
                if (!test_faults_enabled() || !payload.empty()) return DINOX_WEBRTC_STATUS_NOT_READY;
                std::this_thread::sleep_for(std::chrono::hours(24));
                return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE:
                return create_session(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CLOSE:
                if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                return close_session(request);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_OFFER:
                return with_session(request, payload, [](DinoXWebrtcSession* session) {
                    return dinox_webrtc_session_create_offer(session);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_CREATE_ANSWER:
                return with_session(request, payload, [](DinoXWebrtcSession* session) {
                    return dinox_webrtc_session_create_answer(session);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_ICE_SERVER:
                return add_ice_server(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_AUDIO_ENABLED:
                return set_track_enabled(request, payload, true);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_VIDEO_ENABLED:
                return set_track_enabled(request, payload, false);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_REMOTE_DESCRIPTION:
                return set_remote_description(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PREPARE_LOCAL_DESCRIPTION: {
                if (payload.size() != 4 || read_u32(payload.data()) > DINOX_WEBRTC_SDP_TYPE_ANSWER) {
                    return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                }
                WorkerSession* session = find_session(request);
                if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
                return dinox_webrtc_session_prepare_local_description(
                    session->native_session, static_cast<DinoXWebrtcSdpType>(read_u32(payload.data())));
            }
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SET_LOCAL_DESCRIPTION:
                return set_remote_description(request, payload, true);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_ADD_REMOTE_CANDIDATE:
                return add_remote_candidate(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_SEND_DTMF:
                return send_dtmf(request, payload, false);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PLAY_DTMF_FEEDBACK:
                return send_dtmf(request, payload, true);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_START:
                return start_video_capture(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_VIDEO_CAPTURE_STOP:
                return with_session(request, payload, [](DinoXWebrtcSession* session) {
                    return dinox_webrtc_session_stop_video_capture(session);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_PUSH_SYNTHETIC_VIDEO:
                return push_synthetic_video(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SESSION_STATE_GET:
                return get_session_state(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CREATE:
                return create_recorder(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_START:
                return with_recorder(request, payload, [](DinoXWebrtcMediaRecorder* recorder) {
                    return dinox_webrtc_media_recorder_start(recorder);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STOP:
                return with_recorder(request, payload, [](DinoXWebrtcMediaRecorder* recorder) {
                    return dinox_webrtc_media_recorder_stop(recorder);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_CANCEL:
                return close_recorder(request, payload, true);
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_PUSH_SYNTHETIC:
                return with_recorder(request, payload, [](DinoXWebrtcMediaRecorder* recorder) {
                    return dinox_webrtc_media_recorder_push_synthetic_frame(recorder);
                });
            case DINOX_WEBRTC_IPC_MESSAGE_RECORDER_STATE_GET:
                return get_recorder_state(request, payload);
            case DINOX_WEBRTC_IPC_MESSAGE_SHUTDOWN:
                if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
                pipelines_.clear();
                sessions_.clear();
                recorders_.clear();
                *out_running = false;
                return DINOX_WEBRTC_STATUS_OK;
            default:
                return DINOX_WEBRTC_STATUS_NOT_READY;
        }
    }

    WorkerConnection& connection() { return connection_; }
    const std::vector<uint8_t>& reply_payload() const { return reply_payload_; }

    void finish_reply(const DinoXWebrtcIpcHeader& request) {
        if (request.message_type != DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG) {
            return;
        }
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline != nullptr) flush_deferred_video_pipeline_state_events(pipeline);
    }

 private:
    bool test_faults_enabled() const {
        const char* value = std::getenv("DINOX_WEBRTC_ENABLE_TEST_FAULTS");
        return value != nullptr && std::strcmp(value, "1") == 0;
    }
    void append_string(const char* value) {
        const char* safe = value == nullptr ? "" : value;
        const size_t size = std::strlen(safe);
        append_u32(&reply_payload_, static_cast<uint32_t>(size));
        reply_payload_.insert(reply_payload_.end(), safe, safe + size);
    }

    DinoXWebrtcStatus list_audio_devices(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 4 || read_u32(payload.data()) > 1) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        const int incoming = static_cast<int>(read_u32(payload.data()));
        int count = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_get_audio_device_count(context_, incoming, &count);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        append_u32(&reply_payload_, static_cast<uint32_t>(count));
        for (int index = 0; index < count; ++index) {
            char name[256] = {};
            char guid[256] = {};
            status = dinox_webrtc_context_get_audio_device_name(
                context_, incoming, index, name, sizeof(name), guid, sizeof(guid));
            if (status != DINOX_WEBRTC_STATUS_OK) return status;
            append_u32(&reply_payload_, static_cast<uint32_t>(index));
            append_string(name);
            append_string(guid);
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus select_audio_device(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 8 || read_u32(payload.data()) > 1) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_context_set_audio_device(
            context_,
            static_cast<int>(read_u32(payload.data())),
            static_cast<int>(read_u32(payload.data() + 4)));
    }

    DinoXWebrtcStatus get_audio_device_volume(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 4 || read_u32(payload.data()) > 1) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        double volume = 1.0;
        int available = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_get_audio_device_volume(
            context_, static_cast<int>(read_u32(payload.data())), &volume, &available);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        append_u32(&reply_payload_, static_cast<uint32_t>(available != 0));
        uint64_t volume_bits = 0;
        std::memcpy(&volume_bits, &volume, sizeof(volume_bits));
        append_u64(&reply_payload_, volume_bits);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus set_audio_device_volume(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 12 || read_u32(payload.data()) > 1) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        const uint64_t volume_bits = read_u64(payload.data() + 4);
        double volume = 0.0;
        std::memcpy(&volume, &volume_bits, sizeof(volume));
        return dinox_webrtc_context_set_audio_device_volume(
            context_, static_cast<int>(read_u32(payload.data())), volume);
    }

    DinoXWebrtcStatus list_video_devices(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || !payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        int count = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_get_video_device_count(context_, &count);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        append_u32(&reply_payload_, static_cast<uint32_t>(count));
        for (int index = 0; index < count; ++index) {
            char name[256] = {};
            char unique_id[1024] = {};
            char product_id[128] = {};
            status = dinox_webrtc_context_get_video_device_name(
                context_, index, name, sizeof(name), unique_id, sizeof(unique_id), product_id, sizeof(product_id));
            if (status != DINOX_WEBRTC_STATUS_OK) return status;
            append_u32(&reply_payload_, static_cast<uint32_t>(index));
            append_string(name);
            append_string(unique_id);
            append_string(product_id);
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus get_video_effect_capabilities(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || !payload.empty()) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        DinoXWebrtcVideoEffectCapabilities capabilities = {};
        DinoXWebrtcStatus status = dinox_webrtc_context_get_video_effect_capabilities(
            context_, &capabilities);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        reply_payload_.resize(DINOX_WEBRTC_IPC_VIDEO_EFFECT_CAPABILITIES_SIZE);
        if (dinox_webrtc_ipc_encode_video_effect_capabilities(
                &capabilities, reply_payload_.data(), reply_payload_.size()) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            reply_payload_.clear();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus play_test_tone(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 8 || read_u32(payload.data()) > 255) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_context_play_test_tone(
            context_, static_cast<char>(read_u32(payload.data())), read_u32(payload.data() + 4));
    }

    DinoXWebrtcStatus play_audio_test_clip(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() <= 12) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        unsigned int duration_ms = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_play_audio_test_clip(
            context_, payload.data() + 12, payload.size() - 12,
            static_cast<int>(read_u32(payload.data())),
            static_cast<int>(read_u32(payload.data() + 4)),
            static_cast<int>(read_u32(payload.data() + 8)),
            &duration_ms);
        if (status == DINOX_WEBRTC_STATUS_OK) append_u32(&reply_payload_, duration_ms);
        return status;
    }

    DinoXWebrtcStatus start_media_audio_playout(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 12) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_context_media_audio_playout_start(
            context_,
            static_cast<int>(read_u32(payload.data())),
            static_cast<int>(read_u32(payload.data() + 4)),
            static_cast<int>(read_u32(payload.data() + 8)));
    }

    DinoXWebrtcStatus push_media_audio_playout(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.empty()) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        unsigned int queued_duration_ms = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_media_audio_playout_push(
            context_, payload.data(), payload.size(), &queued_duration_ms);
        if (status == DINOX_WEBRTC_STATUS_OK) {
            append_u32(&reply_payload_, queued_duration_ms);
        }
        return status;
    }

    DinoXWebrtcStatus pause_media_audio_playout(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 4 || read_u32(payload.data()) > 1) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_context_media_audio_playout_set_paused(
            context_, static_cast<int>(read_u32(payload.data())));
    }

    DinoXWebrtcStatus finish_media_audio_playout(const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || !payload.empty()) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        unsigned int queued_duration_ms = 0;
        DinoXWebrtcStatus status = dinox_webrtc_context_media_audio_playout_finish(
            context_, &queued_duration_ms);
        if (status == DINOX_WEBRTC_STATUS_OK) {
            append_u32(&reply_payload_, queued_duration_ms);
        }
        return status;
    }

    WorkerSession* find_session(const DinoXWebrtcIpcHeader& request) {
        auto iterator = sessions_.find(request.session_id);
        if (iterator == sessions_.end() || iterator->second->generation != request.generation) return nullptr;
        return iterator->second.get();
    }

    WorkerRecorder* find_recorder(const DinoXWebrtcIpcHeader& request) {
        auto iterator = recorders_.find(request.session_id);
        if (iterator == recorders_.end() || iterator->second->generation != request.generation) return nullptr;
        return iterator->second.get();
    }

    WorkerPipeline* find_video_pipeline(const DinoXWebrtcIpcHeader& request) {
        auto iterator = pipelines_.find(request.session_id);
        if (iterator == pipelines_.end() || iterator->second->generation != request.generation) {
            return nullptr;
        }
        return iterator->second.get();
    }

    DinoXWebrtcStatus create_video_pipeline(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || payload.size() != 8 ||
                read_u64(payload.data()) == 0 || pipelines_.contains(request.session_id)) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        auto pipeline = std::make_unique<WorkerPipeline>();
        pipeline->connection = &connection_;
        pipeline->pipeline_id = request.session_id;
        pipeline->generation = request.generation;
        pipeline->logical_call_id = read_u64(payload.data());
        DinoXWebrtcVideoPipelineCallbacks callbacks =
            dinox_webrtc_video_pipeline_callbacks_default();
        callbacks.on_state_changed = on_video_pipeline_state_changed;
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_new(
            context_, pipeline->logical_call_id, &callbacks, pipeline.get(),
            &pipeline->native_pipeline);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        pipelines_.emplace(request.session_id, std::move(pipeline));
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus destroy_video_pipeline(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        if (test_faults_enabled()) {
            const char* hang_logical_call_id = std::getenv(
                "DINOX_WEBRTC_TEST_PIPELINE_DESTROY_HANG_LOGICAL_CALL_ID");
            if (hang_logical_call_id != nullptr && hang_logical_call_id[0] != '\0') {
                char* end = nullptr;
                errno = 0;
                const unsigned long long parsed = std::strtoull(
                    hang_logical_call_id, &end, 10);
                if (errno == 0 && end != hang_logical_call_id && *end == '\0' &&
                        parsed == pipeline->logical_call_id) {
                    std::this_thread::sleep_for(std::chrono::hours(24));
                }
            }
        }
        pipelines_.erase(request.session_id);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus attach_video_pipeline(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() != DINOX_WEBRTC_IPC_VIDEO_PIPELINE_ATTACHMENT_SIZE) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        const uint64_t session_id = read_u64(payload.data());
        const uint64_t session_generation = read_u64(payload.data() + 8);
        const uint64_t subscriber_generation = read_u64(payload.data() + 16);
        const uint32_t preview_publisher = read_u32(payload.data() + 24);
        auto session_iterator = sessions_.find(session_id);
        if (session_id == 0 || session_generation == 0 || subscriber_generation == 0 ||
                preview_publisher > 1 || session_iterator == sessions_.end() ||
                session_iterator->second->generation != session_generation) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            const auto active = pipeline->attachments.find(session_id);
            if (active != pipeline->attachments.end()) {
                if (active->second.session_generation != session_generation ||
                        active->second.subscriber_generation != subscriber_generation) {
                    return DINOX_WEBRTC_STATUS_NOT_READY;
                }
            } else {
                const uint64_t previous = pipeline->subscriber_generations[session_id];
                if (previous == UINT64_MAX || subscriber_generation != previous + 1 ||
                        pipeline->attachments.size() >=
                            DINOX_WEBRTC_VIDEO_PIPELINE_MAX_SUBSCRIBERS) {
                    return DINOX_WEBRTC_STATUS_NOT_READY;
                }
            }
            if (preview_publisher != 0) {
                for (const auto& [attached_id, attachment] : pipeline->attachments) {
                    if (attached_id != session_id && attachment.preview_publisher) {
                        return DINOX_WEBRTC_STATUS_NOT_READY;
                    }
                }
            }
        }
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_attach_session(
            pipeline->native_pipeline,
            session_iterator->second->native_session,
            static_cast<int>(preview_publisher));
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            pipeline->subscriber_generations[session_id] = subscriber_generation;
            pipeline->attachments[session_id] = {
                session_generation, subscriber_generation, preview_publisher != 0};
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus detach_video_pipeline(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() != DINOX_WEBRTC_IPC_VIDEO_PIPELINE_DETACHMENT_SIZE) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        const uint64_t session_id = read_u64(payload.data());
        const uint64_t session_generation = read_u64(payload.data() + 8);
        const uint64_t subscriber_generation = read_u64(payload.data() + 16);
        auto session_iterator = sessions_.find(session_id);
        if (session_iterator == sessions_.end() ||
                session_iterator->second->generation != session_generation) {
            return DINOX_WEBRTC_STATUS_NOT_READY;
        }
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            const auto active = pipeline->attachments.find(session_id);
            if (active == pipeline->attachments.end() ||
                    active->second.session_generation != session_generation ||
                    active->second.subscriber_generation != subscriber_generation) {
                return DINOX_WEBRTC_STATUS_NOT_READY;
            }
        }
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_detach_session(
            pipeline->native_pipeline, session_iterator->second->native_session);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        std::lock_guard<std::mutex> lock(pipeline->mutex);
        pipeline->attachments.erase(session_id);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus background_command(const DinoXWebrtcIpcHeader& request,
                                       const std::vector<uint8_t>& payload) {
        auto* pipeline=find_video_pipeline(request);
        if(!pipeline)return DINOX_WEBRTC_STATUS_NOT_READY;
        if(pipeline->background_upload&&std::chrono::steady_clock::now()>
                pipeline->background_upload->deadline)pipeline->background_upload.reset();
        const auto type=request.message_type;
        if(type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN){
            if(payload.size()!=20)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            const uint32_t w=read_u32(payload.data()),h=read_u32(payload.data()+4),
                stride=read_u32(payload.data()+8),format=read_u32(payload.data()+12),
                size=read_u32(payload.data()+16);
            if(!dinox::video_background_protocol::valid_upload(w,h,stride,format,size))
                return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            if(pipeline->background_upload||pipeline->next_background_upload==UINT64_MAX)
                return DINOX_WEBRTC_STATUS_NOT_READY;
            WorkerPipeline::BackgroundUpload upload;
            upload.ticket=pipeline->next_background_upload++;
            upload.width=w;upload.height=h;upload.stride=stride;upload.format=format;
            upload.bytes.resize(size);upload.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
            append_u64(&reply_payload_,upload.ticket);pipeline->background_upload=std::move(upload);
            return DINOX_WEBRTC_STATUS_OK;
        }
        if(type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_CHUNK){
            if(payload.size()<=12||payload.size()>12+dinox::video_background_protocol::kChunkBytes)
                return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            auto& upload=pipeline->background_upload;
            if(!upload||read_u64(payload.data())!=upload->ticket)return DINOX_WEBRTC_STATUS_NOT_READY;
            const size_t offset=read_u32(payload.data()+8),size=payload.size()-12;
            if(offset!=upload->used||offset>upload->bytes.size()||size>upload->bytes.size()-offset){
                upload.reset();return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            }
            std::copy(payload.begin()+12,payload.end(),upload->bytes.begin()+offset);
            upload->used+=size;return DINOX_WEBRTC_STATUS_OK;
        }
        if(type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_COMMIT||
                type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT){
            if(payload.size()!=8)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
            auto& upload=pipeline->background_upload;
            if(!upload||read_u64(payload.data())!=upload->ticket)return DINOX_WEBRTC_STATUS_NOT_READY;
            if(type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_ABORT){upload.reset();return DINOX_WEBRTC_STATUS_OK;}
            if(upload->used!=upload->bytes.size()){upload.reset();return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;}
            uint32_t id=0;
            const auto status=dinox_webrtc_video_pipeline_background_upload(pipeline->native_pipeline,
                upload->width,upload->height,upload->stride,static_cast<DinoXWebrtcBackgroundPixelFormat>(upload->format),
                upload->bytes.data(),upload->bytes.size(),&id);
            upload.reset();if(status==DINOX_WEBRTC_STATUS_OK)append_u32(&reply_payload_,id);
            return status;
        }
        if(payload.size()!=4)return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t id=read_u32(payload.data());
        if(type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_BUILTIN){
            uint32_t asset=0;const auto status=dinox_webrtc_video_pipeline_background_builtin(
                pipeline->native_pipeline,static_cast<DinoXWebrtcBackgroundBuiltin>(id),&asset);
            if(status==DINOX_WEBRTC_STATUS_OK)append_u32(&reply_payload_,asset);return status;
        }
        return type==DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_PREPARE ?
            dinox_webrtc_video_pipeline_background_prepare(pipeline->native_pipeline,id) :
            dinox_webrtc_video_pipeline_background_release(pipeline->native_pipeline,id);
    }

    DinoXWebrtcStatus set_video_pipeline_config(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcVideoEffectConfig config = {};
        if (dinox_webrtc_ipc_decode_video_effect_config(
                payload.data(), payload.size(), &config) != DINOX_WEBRTC_IPC_VALIDATION_OK) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            if (pipeline->defer_state_events_until_reply) {
                return DINOX_WEBRTC_STATUS_NOT_READY;
            }
            pipeline->defer_state_events_until_reply = true;
            pipeline->has_deferred_state_event = false;
        }
        uint64_t revision = 0;
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_set_config(
            pipeline->native_pipeline, &config, &revision);
        if (status == DINOX_WEBRTC_STATUS_OK && revision != 0 && test_faults_enabled()) {
            const char* target_text = std::getenv(
                "DINOX_WEBRTC_TEST_EFFECT_CONFIG_DELAY_LOGICAL_CALL_ID");
            char* target_end = nullptr;
            errno = 0;
            const unsigned long long target = target_text == nullptr ? 0 :
                std::strtoull(target_text, &target_end, 10);
            const bool target_matches = target_text != nullptr && target_text[0] != '\0' &&
                errno == 0 && target_end != target_text && *target_end == '\0' &&
                target == pipeline->logical_call_id;
            if (target_matches) {
                // set_config itself only proves ACCEPTED.  For the lifecycle
                // race smoke, wait on the native (in-process) state until the
                // exact revision is APPLIED before exposing the marker.  This
                // is deliberately bounded and available only with explicit
                // test-fault opt-in.
                bool applied = false;
                const auto applied_deadline = std::chrono::steady_clock::now() +
                    std::chrono::seconds(2);
                while (std::chrono::steady_clock::now() < applied_deadline) {
                    DinoXWebrtcVideoPipelineState native_state = {};
                    const DinoXWebrtcStatus state_status =
                        dinox_webrtc_video_pipeline_get_state(
                            pipeline->native_pipeline, &native_state);
                    if (state_status != DINOX_WEBRTC_STATUS_OK) {
                        status = state_status;
                        break;
                    }
                    if (native_state.application_state ==
                            DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                            native_state.accepted_revision == revision &&
                            native_state.applied_revision == revision &&
                            native_state.effect_type == config.effect_type &&
                            native_state.brightness == config.brightness &&
                            native_state.contrast == config.contrast &&
                            native_state.saturation == config.saturation &&
                            native_state.sharpness == config.sharpness &&
                            native_state.background_mode == config.background_mode &&
                            native_state.background_strength == config.background_strength &&
                            native_state.background_color_rgb == config.background_color_rgb &&
                            native_state.framing_mode == config.framing_mode &&
                            native_state.glasses_style == config.glasses_style &&
                            native_state.hat_style == config.hat_style &&
                            native_state.beard_style == config.beard_style &&
                            native_state.face_accessory == config.face_accessory &&
                            native_state.touch_up == config.touch_up &&
                            native_state.low_light == config.low_light &&
                            native_state.scene_effect == config.scene_effect) {
                        applied = true;
                        break;
                    }
                    if (native_state.accepted_revision == revision &&
                            (native_state.application_state ==
                                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_FAILED ||
                             native_state.application_state ==
                                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_DEGRADED ||
                             native_state.application_state ==
                                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_UNAVAILABLE)) {
                        status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if (status == DINOX_WEBRTC_STATUS_OK && !applied) {
                    status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
                }
                if (!applied) return status;

                // Test-only proof point: native APPLIED is now observable,
                // while the process IPC reply is deliberately outstanding.
                const char* marker_path = std::getenv(
                    "DINOX_WEBRTC_TEST_EFFECT_CONFIG_APPLIED_MARKER");
                if (marker_path != nullptr && marker_path[0] != '\0') {
                    if (FILE* marker = std::fopen(marker_path, "wb")) {
                        std::fputs("native-effect-revision-applied\n", marker);
                        std::fclose(marker);
                    }
                }
                const char* delay_text = std::getenv(
                    "DINOX_WEBRTC_TEST_EFFECT_CONFIG_POST_APPLY_DELAY_MS");
                char* delay_end = nullptr;
                errno = 0;
                const unsigned long delay_ms = delay_text == nullptr ? 0 :
                    std::strtoul(delay_text, &delay_end, 10);
                if (delay_text != nullptr && delay_text[0] != '\0' && errno == 0 &&
                        delay_end != delay_text && *delay_end == '\0' && delay_ms <= 2000) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
                }
            }
        }
        if (status == DINOX_WEBRTC_STATUS_OK && revision != 0) {
            append_u64(&reply_payload_, revision);
        }
        return status;
    }

    DinoXWebrtcStatus get_video_pipeline_state(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcVideoPipelineState state = {};
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_get_state(
            pipeline->native_pipeline, &state);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            apply_worker_pipeline_identity(pipeline, &state);
        }
        reply_payload_.resize(DINOX_WEBRTC_IPC_VIDEO_PIPELINE_STATE_SIZE);
        if (dinox_webrtc_ipc_encode_video_pipeline_state(
                &state, reply_payload_.data(), reply_payload_.size()) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            reply_payload_.clear();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus get_video_pipeline_diagnostics(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerPipeline* pipeline = find_video_pipeline(request);
        if (pipeline == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
        DinoXWebrtcStatus status = dinox_webrtc_video_pipeline_get_diagnostics(
            pipeline->native_pipeline, &diagnostics);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        {
            std::lock_guard<std::mutex> lock(pipeline->mutex);
            diagnostics.logical_pipeline_count = 1;
            diagnostics.subscriber_count = static_cast<uint32_t>(pipeline->attachments.size());
        }
        reply_payload_.resize(DINOX_WEBRTC_IPC_VIDEO_EFFECT_DIAGNOSTICS_SIZE);
        if (dinox_webrtc_ipc_encode_video_effect_diagnostics(
                &diagnostics, reply_payload_.data(), reply_payload_.size()) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            reply_payload_.clear();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus create_session(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || sessions_.contains(request.session_id)) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcIpcSessionConfig wire = {};
        if (dinox_webrtc_ipc_decode_session_config(payload.data(), payload.size(), &wire) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        DinoXWebrtcSessionConfig config = dinox_webrtc_session_config_default();
        config.audio_enabled = static_cast<int>(wire.audio_enabled);
        config.video_enabled = static_cast<int>(wire.video_enabled);
        config.audio_direction = static_cast<DinoXWebrtcMediaDirection>(wire.audio_direction);
        config.video_direction = static_cast<DinoXWebrtcMediaDirection>(wire.video_direction);
        config.defer_audio_transceiver_until_answer = static_cast<int>(wire.defer_audio_transceiver_until_answer);
        config.defer_video_transceiver_until_answer = static_cast<int>(wire.defer_video_transceiver_until_answer);
        config.ice_candidate_pool_size = wire.ice_candidate_pool_size;
        config.max_bundle = static_cast<int>(wire.max_bundle);
        config.network_policy = static_cast<DinoXWebrtcNetworkPolicy>(wire.network_policy);
        auto session = std::make_unique<WorkerSession>();
        session->connection = &connection_;
        session->session_id = request.session_id;
        session->generation = request.generation;
        session->video_ring = video_ring_;
        session->video_ring_size = video_ring_size_;
        DinoXWebrtcCallbacks callbacks = dinox_webrtc_callbacks_default();
        callbacks.on_local_description = on_local_description;
        callbacks.on_local_description_prepared = on_local_description_prepared;
        callbacks.on_remote_description_set = on_remote_description_set;
        callbacks.on_ice_candidate = on_ice_candidate;
        callbacks.on_ice_gathering_complete = on_ice_gathering_complete;
        callbacks.on_error = on_session_error;
        callbacks.on_video_frame = on_video_frame;
        callbacks.on_local_video_frame = on_local_video_frame;
        DinoXWebrtcStatus status = dinox_webrtc_session_new(
            context_,
            &config,
            &callbacks,
            session.get(),
            &session->native_session);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        sessions_.emplace(request.session_id, std::move(session));
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus close_session(const DinoXWebrtcIpcHeader& request) {
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        for (auto& [pipeline_id, pipeline] : pipelines_) {
            (void) pipeline_id;
            bool attached = false;
            {
                std::lock_guard<std::mutex> lock(pipeline->mutex);
                attached = pipeline->attachments.contains(request.session_id);
            }
            if (attached) {
                (void) dinox_webrtc_video_pipeline_detach_session(
                    pipeline->native_pipeline, session->native_session);
                std::lock_guard<std::mutex> lock(pipeline->mutex);
                pipeline->attachments.erase(request.session_id);
                pipeline->subscriber_generations.erase(request.session_id);
            }
        }
        sessions_.erase(request.session_id);
        return DINOX_WEBRTC_STATUS_OK;
    }

    DinoXWebrtcStatus create_recorder(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (context_ == nullptr || recorders_.contains(request.session_id)) return DINOX_WEBRTC_STATUS_NOT_READY;
        if (payload.size() < 32) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t path_size = read_u32(payload.data() + 20);
        const uint32_t mime_size = read_u32(payload.data() + 24);
        const uint32_t device_size = read_u32(payload.data() + 28);
        const uint64_t expected = 32ull + path_size + mime_size + device_size;
        if (path_size == 0 || mime_size == 0 || expected != payload.size()) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        size_t offset = 32;
        std::string path(payload.begin() + offset, payload.begin() + offset + path_size);
        offset += path_size;
        std::string mime(payload.begin() + offset, payload.begin() + offset + mime_size);
        offset += mime_size;
        std::string device(payload.begin() + offset, payload.end());
        if (path.find('\0') != std::string::npos || mime.find('\0') != std::string::npos ||
                device.find('\0') != std::string::npos) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;

        DinoXWebrtcMediaRecorderConfig config = dinox_webrtc_media_recorder_config_default();
        config.kind = static_cast<DinoXWebrtcMediaRecorderKind>(read_u32(payload.data()));
        config.width = static_cast<int>(read_u32(payload.data() + 4));
        config.height = static_cast<int>(read_u32(payload.data() + 8));
        config.max_fps = static_cast<int>(read_u32(payload.data() + 12));
        config.include_audio_track = static_cast<int>(read_u32(payload.data() + 16));
        config.output_path = path.c_str();
        config.mime_type = mime.c_str();
        config.video_device_unique_id = device.empty() ? nullptr : device.c_str();
        auto recorder = std::make_unique<WorkerRecorder>();
        recorder->connection = &connection_;
        recorder->recorder_id = request.session_id;
        recorder->generation = request.generation;
        recorder->video_ring = video_ring_;
        recorder->video_ring_size = video_ring_size_;
        DinoXWebrtcMediaRecorderCallbacks callbacks = dinox_webrtc_media_recorder_callbacks_default();
        callbacks.on_started = on_recorder_started;
        callbacks.on_stopped = on_recorder_stopped;
        callbacks.on_error = on_recorder_error;
        callbacks.on_audio_frame = on_recorder_audio_frame;
        callbacks.on_video_frame = on_recorder_video_frame;
        DinoXWebrtcStatus status = dinox_webrtc_media_recorder_new(
            context_, &config, &callbacks, recorder.get(), &recorder->native_recorder);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        recorders_.emplace(request.session_id, std::move(recorder));
        return DINOX_WEBRTC_STATUS_OK;
    }

    template <typename Operation>
    DinoXWebrtcStatus with_recorder(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        Operation operation) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerRecorder* recorder = find_recorder(request);
        return recorder == nullptr ? DINOX_WEBRTC_STATUS_NOT_READY : operation(recorder->native_recorder);
    }

    DinoXWebrtcStatus close_recorder(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        bool cancel) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerRecorder* recorder = find_recorder(request);
        if (recorder == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcStatus status = cancel
            ? dinox_webrtc_media_recorder_cancel(recorder->native_recorder)
            : DINOX_WEBRTC_STATUS_OK;
        recorders_.erase(request.session_id);
        return status;
    }

    DinoXWebrtcStatus get_recorder_state(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerRecorder* recorder = find_recorder(request);
        if (recorder == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        DinoXWebrtcMediaRecorderState state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
        DinoXWebrtcStatus status = dinox_webrtc_media_recorder_get_state(recorder->native_recorder, &state);
        if (status == DINOX_WEBRTC_STATUS_OK) append_u32(&reply_payload_, static_cast<uint32_t>(state));
        return status;
    }

    template <typename Operation>
    DinoXWebrtcStatus with_session(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        Operation operation) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        return session == nullptr ? DINOX_WEBRTC_STATUS_NOT_READY : operation(session->native_session);
    }

    DinoXWebrtcStatus set_track_enabled(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        bool audio) {
        if (payload.size() != 4 || read_u32(payload.data()) > 1) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        return audio
            ? dinox_webrtc_session_set_local_audio_enabled(session->native_session, static_cast<int>(read_u32(payload.data())))
            : dinox_webrtc_session_set_local_video_enabled(session->native_session, static_cast<int>(read_u32(payload.data())));
    }

    DinoXWebrtcStatus set_remote_description(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        bool local = false) {
        if (payload.size() <= 4) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t type = read_u32(payload.data());
        if (type > DINOX_WEBRTC_SDP_TYPE_ANSWER ||
                std::memchr(payload.data() + 4, '\0', payload.size() - 4) != nullptr) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        std::string sdp(reinterpret_cast<const char*>(payload.data() + 4), payload.size() - 4);
        if (local) {
            return dinox_webrtc_session_set_local_description(
                session->native_session, static_cast<DinoXWebrtcSdpType>(type), sdp.c_str());
        }
        return dinox_webrtc_session_set_remote_description(
            session->native_session,
            static_cast<DinoXWebrtcSdpType>(type),
            sdp.c_str());
    }

    DinoXWebrtcStatus add_ice_server(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() < 12) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t url_size = read_u32(payload.data());
        const uint32_t username_size = read_u32(payload.data() + 4);
        const uint32_t credential_size = read_u32(payload.data() + 8);
        const uint64_t total_size = static_cast<uint64_t>(url_size) + username_size + credential_size + 12;
        if (url_size == 0 || total_size != payload.size()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        const auto begin = payload.begin() + 12;
        std::string url(begin, begin + url_size);
        std::string username(begin + url_size, begin + url_size + username_size);
        std::string credential(begin + url_size + username_size, payload.end());
        if (url.find('\0') != std::string::npos || username.find('\0') != std::string::npos ||
                credential.find('\0') != std::string::npos) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_session_add_ice_server(
            session->native_session,
            url.c_str(),
            username.c_str(),
            credential.c_str());
    }

    DinoXWebrtcStatus add_remote_candidate(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() <= 8) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t mline = read_u32(payload.data());
        const uint32_t mid_size = read_u32(payload.data() + 4);
        if (mid_size == 0 || mid_size > payload.size() - 8 || mid_size == payload.size() - 8) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        std::string mid(reinterpret_cast<const char*>(payload.data() + 8), mid_size);
        std::string candidate(
            reinterpret_cast<const char*>(payload.data() + 8 + mid_size),
            payload.size() - 8 - mid_size);
        if (mid.find('\0') != std::string::npos || candidate.find('\0') != std::string::npos) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        return dinox_webrtc_session_add_remote_ice_candidate(
            session->native_session,
            mid.c_str(),
            static_cast<int>(mline),
            candidate.c_str());
    }

    DinoXWebrtcStatus send_dtmf(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload,
        bool local_feedback) {
        if (payload.size() != 8 || read_u32(payload.data()) > 255) {
            return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        }
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        const char digit = static_cast<char>(read_u32(payload.data()));
        const uint32_t duration_ms = read_u32(payload.data() + 4);
        return local_feedback
            ? dinox_webrtc_session_play_local_dtmf_feedback(session->native_session, digit, duration_ms)
            : dinox_webrtc_session_send_dtmf(session->native_session, digit, duration_ms);
    }

    DinoXWebrtcStatus start_video_capture(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() <= 16) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        const uint32_t width = read_u32(payload.data());
        const uint32_t height = read_u32(payload.data() + 4);
        const uint32_t max_fps = read_u32(payload.data() + 8);
        const uint32_t id_size = read_u32(payload.data() + 12);
        if (id_size == 0 || id_size != payload.size() - 16) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        std::string device_id(payload.begin() + 16, payload.end());
        if (device_id.find('\0') != std::string::npos) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        return dinox_webrtc_session_start_video_capture(
            session->native_session,
            device_id.c_str(),
            static_cast<int>(width),
            static_cast<int>(height),
            static_cast<int>(max_fps));
    }

    DinoXWebrtcStatus push_synthetic_video(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (payload.size() != 8) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        return dinox_webrtc_session_push_synthetic_video_frame(
            session->native_session,
            static_cast<int>(read_u32(payload.data())),
            static_cast<int>(read_u32(payload.data() + 4)));
    }

    DinoXWebrtcStatus get_session_state(
        const DinoXWebrtcIpcHeader& request,
        const std::vector<uint8_t>& payload) {
        if (!payload.empty()) return DINOX_WEBRTC_STATUS_INVALID_ARGUMENT;
        WorkerSession* session = find_session(request);
        if (session == nullptr) return DINOX_WEBRTC_STATUS_NOT_READY;
        if (test_faults_enabled()) {
            const char* delay_text = std::getenv("DINOX_WEBRTC_TEST_STATE_DELAY_MS");
            if (delay_text != nullptr && delay_text[0] != '\0') {
                char* end = nullptr;
                errno = 0;
                const unsigned long delay_ms = std::strtoul(delay_text, &end, 10);
                if (errno == 0 && end != delay_text && *end == '\0' && delay_ms <= 2000) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
                }
            }
        }
        DinoXWebrtcSessionState state = {};
        DinoXWebrtcStatus status = dinox_webrtc_session_get_state(session->native_session, &state);
        if (status != DINOX_WEBRTC_STATUS_OK) return status;
        reply_payload_.resize(dinox_webrtc_ipc_session_state_size());
        if (dinox_webrtc_ipc_encode_session_state(
                &state, reply_payload_.data(), reply_payload_.size()) !=
                DINOX_WEBRTC_IPC_VALIDATION_OK) {
            reply_payload_.clear();
            return DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
        }
        return DINOX_WEBRTC_STATUS_OK;
    }

    WorkerConnection connection_;
    DinoXWebrtcContext* context_ = nullptr;
    std::unordered_map<uint64_t, std::unique_ptr<WorkerSession>> sessions_;
    std::unordered_map<uint64_t, std::unique_ptr<WorkerRecorder>> recorders_;
    std::unordered_map<uint64_t, std::unique_ptr<WorkerPipeline>> pipelines_;
    std::vector<uint8_t> reply_payload_;
    bool hello_complete_ = false;
    void* video_ring_ = nullptr;
    size_t video_ring_size_ = 0;
};

int run_worker(ControlHandle fd, void* video_ring, size_t video_ring_size) {
    WorkerState state(fd, video_ring, video_ring_size);
    bool running = true;
    while (running) {
        uint8_t encoded[DINOX_WEBRTC_IPC_HEADER_SIZE] = {};
        if (!read_exact(fd, encoded, sizeof(encoded))) break;
        DinoXWebrtcIpcHeader request = {};
        DinoXWebrtcIpcValidationStatus validation = dinox_webrtc_ipc_decode_header(
            encoded,
            sizeof(encoded),
            &request);
        if (validation != DINOX_WEBRTC_IPC_VALIDATION_OK) return 20;
        validation = dinox_webrtc_ipc_validate_header(
            &request,
            static_cast<size_t>(DINOX_WEBRTC_IPC_HEADER_SIZE) + request.payload_size);
        if (validation != DINOX_WEBRTC_IPC_VALIDATION_OK) return 21;
        std::vector<uint8_t> payload(request.payload_size);
        if (!payload.empty() && !read_exact(fd, payload.data(), payload.size())) return 22;

        if (!state.hello_complete() && request.message_type != DINOX_WEBRTC_IPC_MESSAGE_HELLO) {
            if (!state.connection().send_status(request, DINOX_WEBRTC_STATUS_NOT_READY, "handshake-required")) return 23;
            continue;
        }

        // SET_CONFIG establishes a revision through its reply.  Treating it
        // as one-way would either lose that revision or leave its event barrier
        // armed forever, so reject it without mutating pipeline state.
        if (request.flags == DINOX_WEBRTC_IPC_FLAG_ONEWAY &&
                (request.message_type == DINOX_WEBRTC_IPC_MESSAGE_VIDEO_PIPELINE_SET_CONFIG ||
                 (request.message_type >= DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_UPLOAD_BEGIN &&
                  request.message_type <= DINOX_WEBRTC_IPC_MESSAGE_BACKGROUND_RELEASE))) {
            continue;
        }

        worker_device_debug("handle-enter", request.message_type);
        DinoXWebrtcStatus status = state.handle(request, payload, &running);
        worker_device_debug("handle-exit", request.message_type, status);
        if (request.flags == DINOX_WEBRTC_IPC_FLAG_ONEWAY) {
            if (status != DINOX_WEBRTC_STATUS_OK) state.report_oneway_error(request, status);
            continue;
        }
        worker_device_debug("reply-enter", request.message_type, status);
        if (!state.connection().send_status(request, status, nullptr, &state.reply_payload())) return 24;
        // A pipeline state callback may run on libwebrtc's signaling thread
        // while SET_CONFIG is still being handled.  Keep it behind this exact
        // control-reply write; only now may APPLIED become visible on IPC.
        state.finish_reply(request);
        worker_device_debug("reply-exit", request.message_type, status);
    }
#ifdef _WIN32
    FlushFileBuffers(fd);
    CloseHandle(fd);
#else
    close(fd);
#endif
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    dinox_webrtc_internal_worker_enter();
#ifdef _WIN32
    if (argc != 5 || std::strcmp(argv[1], "--control-pipe") != 0 ||
            std::strcmp(argv[3], "--video-map-handle") != 0) {
        std::fprintf(stderr,
            "Usage: dinox-webrtc-worker --control-pipe NAME --video-map-handle HANDLE\n");
        return 2;
    }
    HANDLE pipe = INVALID_HANDLE_VALUE;
    for (unsigned int attempt = 0; attempt < 50; ++attempt) {
        pipe = CreateFileA(
            argv[2], GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) break;
        if (GetLastError() != ERROR_PIPE_BUSY) return 3;
        if (!WaitNamedPipeA(argv[2], 100)) Sleep(10);
    }
    if (pipe == INVALID_HANDLE_VALUE) return 3;
    char* map_end = nullptr;
    const unsigned long long raw_map = std::strtoull(argv[4], &map_end, 10);
    if (map_end == argv[4] || *map_end != '\0' || raw_map == 0) {
        CloseHandle(pipe);
        return 4;
    }
    HANDLE mapping = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(raw_map));
    const size_t video_ring_size = dinox::webrtc_worker::video_ring_size();
    void* video_ring = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, video_ring_size);
    if (video_ring == nullptr) {
        CloseHandle(pipe);
        return 4;
    }
    const int result = run_worker(pipe, video_ring, video_ring_size);
    UnmapViewOfFile(video_ring);
    CloseHandle(mapping);
    return result;
#else
    if ((argc != 3 && argc != 5) || std::strcmp(argv[1], "--control-fd") != 0 ||
            (argc == 5 && std::strcmp(argv[3], "--video-shm-fd") != 0)) {
        std::fprintf(stderr, "Usage: dinox-webrtc-worker --control-fd FD [--video-shm-fd FD]\n");
        return 2;
    }
    char* end = nullptr;
    const long parsed = std::strtol(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || parsed < 3 || parsed > 1'000'000) {
        std::fprintf(stderr, "dinox-webrtc-worker: invalid control fd\n");
        return 2;
    }
    void* video_ring = nullptr;
    size_t video_ring_size = 0;
    if (argc == 5) {
        char* shm_end = nullptr;
        const long shm_fd = std::strtol(argv[4], &shm_end, 10);
        if (shm_end == argv[4] || *shm_end != '\0' || shm_fd < 3 || shm_fd > 1'000'000) return 2;
        video_ring_size = dinox::webrtc_worker::video_ring_size();
        video_ring = mmap(
            nullptr, video_ring_size, PROT_READ | PROT_WRITE, MAP_SHARED,
            static_cast<int>(shm_fd), 0);
        if (video_ring == MAP_FAILED) return 3;
    }
    const int result = run_worker(static_cast<int>(parsed), video_ring, video_ring_size);
    if (video_ring != nullptr) munmap(video_ring, video_ring_size);
    return result;
#endif
}
