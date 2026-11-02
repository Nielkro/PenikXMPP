#include "dinox_webrtc.h"

#include <atomic>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <stdio.h>
#include <stdlib.h>
#include <thread>
#include <map>
#include <memory>
#include <sstream>
#include <string>

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "DINOX_CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

namespace {

constexpr int kMaxIceCandidates = 64;

struct IceCandidateRecord {
    char sdp_mid[128];
    int sdp_mline_index;
    char candidate[4096];
};

struct CallbackState {
    std::mutex mutex;
    std::condition_variable changed;
    int local_description_count;
    int prepared_description_count;
    int remote_description_set_count;
    int ice_candidate_count;
    int ice_gathering_complete_count;
    int error_count;
    DinoXWebrtcSdpType last_type;
    DinoXWebrtcSdpType last_remote_type;
    char last_sdp[65536];
    IceCandidateRecord ice_candidates[kMaxIceCandidates];
    DinoXWebrtcStatus last_error;
    char last_error_message[512];
    uint64_t video_frame_callback_count;
    uint64_t last_video_frame_id;
    int last_video_frame_width;
    int last_video_frame_height;
    int last_video_frame_stride;
    uint64_t local_video_frame_callback_count;
    uint64_t last_local_video_frame_id;
    int last_local_video_frame_width;
    int last_local_video_frame_height;
    int last_local_video_frame_stride;
};

struct RecorderCallbackState {
    int started_count;
    int stopped_count;
    int error_count;
    DinoXWebrtcStatus last_error;
    char last_error_message[512];
    uint64_t audio_frame_count;
    size_t last_audio_byte_count;
    int last_audio_sample_rate;
    int last_audio_channels;
    int last_audio_bytes_per_sample;
    uint64_t last_audio_frame_id;
    uint64_t video_frame_count;
    int last_video_width;
    int last_video_height;
    int last_video_stride;
    uint64_t last_video_frame_id;
};

struct BlockingCallbackState {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false;
    bool released = false;
};

struct PipelineCallbackState {
    std::mutex mutex;
    std::condition_variable changed;
    unsigned int callback_count = 0;
    DinoXWebrtcVideoPipelineState last_state = {};
};

void on_video_pipeline_state(
    DinoXWebrtcVideoPipeline*,
    const DinoXWebrtcVideoPipelineState* state,
    void* user_data) {
    auto* callback_state = static_cast<PipelineCallbackState*>(user_data);
    std::lock_guard<std::mutex> lock(callback_state->mutex);
    callback_state->callback_count++;
    if (state != nullptr) callback_state->last_state = *state;
    callback_state->changed.notify_all();
}

bool wait_for_pipeline_callback(PipelineCallbackState* state, unsigned int count) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(
        lock, std::chrono::seconds(2),
        [state, count]() { return state->callback_count >= count; });
}

void block_callback(BlockingCallbackState* state) {
    std::unique_lock<std::mutex> lock(state->mutex);
    state->entered = true;
    state->changed.notify_all();
    state->changed.wait(lock, [state]() { return state->released; });
}

bool wait_for_blocking_callback(BlockingCallbackState* state) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(
        lock,
        std::chrono::seconds(2),
        [state]() { return state->entered; });
}

void release_blocking_callback(BlockingCallbackState* state) {
    const std::lock_guard<std::mutex> lock(state->mutex);
    state->released = true;
    state->changed.notify_all();
}

void on_blocking_recorder_audio_frame(
    DinoXWebrtcMediaRecorder*,
    const uint8_t*,
    size_t,
    int,
    int,
    int,
    uint64_t,
    void* user_data) {
    block_callback(static_cast<BlockingCallbackState*>(user_data));
}

void on_blocking_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t*,
    int,
    int,
    int,
    uint64_t,
    void* user_data) {
    block_callback(static_cast<BlockingCallbackState*>(user_data));
}

void on_blocking_video_pipeline_state(
    DinoXWebrtcVideoPipeline*,
    const DinoXWebrtcVideoPipelineState*,
    void* user_data) {
    block_callback(static_cast<BlockingCallbackState*>(user_data));
}

void recorder_callback_state_init(RecorderCallbackState* state) {
    state->started_count = 0;
    state->stopped_count = 0;
    state->error_count = 0;
    state->last_error = DINOX_WEBRTC_STATUS_OK;
    state->last_error_message[0] = '\0';
    state->audio_frame_count = 0;
    state->last_audio_byte_count = 0;
    state->last_audio_sample_rate = 0;
    state->last_audio_channels = 0;
    state->last_audio_bytes_per_sample = 0;
    state->last_audio_frame_id = 0;
    state->video_frame_count = 0;
    state->last_video_width = 0;
    state->last_video_height = 0;
    state->last_video_stride = 0;
    state->last_video_frame_id = 0;
}

void on_recorder_started(DinoXWebrtcMediaRecorder*, void* user_data) {
    RecorderCallbackState* state = static_cast<RecorderCallbackState*>(user_data);
    state->started_count++;
}

void on_recorder_stopped(DinoXWebrtcMediaRecorder*, void* user_data) {
    RecorderCallbackState* state = static_cast<RecorderCallbackState*>(user_data);
    state->stopped_count++;
}

void on_recorder_error(
        DinoXWebrtcMediaRecorder*,
        DinoXWebrtcStatus status,
        const char* message,
        void* user_data) {
    RecorderCallbackState* state = static_cast<RecorderCallbackState*>(user_data);
    state->error_count++;
    state->last_error = status;
    snprintf(
        state->last_error_message,
        sizeof(state->last_error_message),
        "%s",
        message != nullptr ? message : "");
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
    RecorderCallbackState* state = static_cast<RecorderCallbackState*>(user_data);
    if (pcm_data != nullptr && byte_count > 0) {
        state->audio_frame_count++;
    }
    state->last_audio_byte_count = byte_count;
    state->last_audio_sample_rate = sample_rate;
    state->last_audio_channels = channels;
    state->last_audio_bytes_per_sample = bytes_per_sample;
    state->last_audio_frame_id = frame_id;
}

void on_recorder_video_frame(
        DinoXWebrtcMediaRecorder*,
        const uint8_t* bgra_data,
        int width,
        int height,
        int stride,
        uint64_t frame_id,
        void* user_data) {
    RecorderCallbackState* state = static_cast<RecorderCallbackState*>(user_data);
    if (bgra_data != nullptr && width > 0 && height > 0 && stride >= width * 4) {
        state->video_frame_count++;
    }
    state->last_video_width = width;
    state->last_video_height = height;
    state->last_video_stride = stride;
    state->last_video_frame_id = frame_id;
}

void callback_state_init(CallbackState* state) {
    state->local_description_count = 0;
    state->prepared_description_count = 0;
    state->remote_description_set_count = 0;
    state->ice_candidate_count = 0;
    state->ice_gathering_complete_count = 0;
    state->error_count = 0;
    state->last_type = DINOX_WEBRTC_SDP_TYPE_ANSWER;
    state->last_remote_type = DINOX_WEBRTC_SDP_TYPE_ANSWER;
    state->last_sdp[0] = '\0';
    for (int i = 0; i < kMaxIceCandidates; i++) {
        state->ice_candidates[i].sdp_mid[0] = '\0';
        state->ice_candidates[i].sdp_mline_index = -1;
        state->ice_candidates[i].candidate[0] = '\0';
    }
    state->last_error = DINOX_WEBRTC_STATUS_OK;
    state->last_error_message[0] = '\0';
    state->video_frame_callback_count = 0;
    state->last_video_frame_id = 0;
    state->last_video_frame_width = 0;
    state->last_video_frame_height = 0;
    state->last_video_frame_stride = 0;
    state->local_video_frame_callback_count = 0;
    state->last_local_video_frame_id = 0;
    state->last_local_video_frame_width = 0;
    state->last_local_video_frame_height = 0;
    state->last_local_video_frame_stride = 0;
}

void callback_state_reset_observations(CallbackState* state) {
    const std::lock_guard<std::mutex> lock(state->mutex);
    state->local_description_count = 0;
    state->prepared_description_count = 0;
    state->remote_description_set_count = 0;
    state->ice_candidate_count = 0;
    state->ice_gathering_complete_count = 0;
    state->error_count = 0;
    state->last_type = DINOX_WEBRTC_SDP_TYPE_ANSWER;
    state->last_remote_type = DINOX_WEBRTC_SDP_TYPE_ANSWER;
    state->last_sdp[0] = '\0';
    for (int i = 0; i < kMaxIceCandidates; i++) {
        state->ice_candidates[i].sdp_mid[0] = '\0';
        state->ice_candidates[i].sdp_mline_index = -1;
        state->ice_candidates[i].candidate[0] = '\0';
    }
    state->last_error = DINOX_WEBRTC_STATUS_OK;
    state->last_error_message[0] = '\0';
    state->video_frame_callback_count = 0;
    state->last_video_frame_id = 0;
    state->last_video_frame_width = 0;
    state->last_video_frame_height = 0;
    state->last_video_frame_stride = 0;
    state->local_video_frame_callback_count = 0;
    state->last_local_video_frame_id = 0;
    state->last_local_video_frame_width = 0;
    state->last_local_video_frame_height = 0;
    state->last_local_video_frame_stride = 0;
}

void on_local_description(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    const char* sdp,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->local_description_count += 1;
    state->last_type = type;
    std::strncpy(state->last_sdp, sdp == nullptr ? "" : sdp, sizeof(state->last_sdp) - 1);
    state->last_sdp[sizeof(state->last_sdp) - 1] = '\0';
    state->changed.notify_all();
}

void on_local_description_prepared(
    DinoXWebrtcSession*, DinoXWebrtcSdpType type, const char* sdp, void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    const std::lock_guard<std::mutex> lock(state->mutex);
    state->prepared_description_count++;
    state->last_type = type;
    snprintf(state->last_sdp, sizeof(state->last_sdp), "%s", sdp != nullptr ? sdp : "");
    state->changed.notify_all();
}

bool wait_for_prepared_description(CallbackState* state) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(5), [state]() {
        return state->prepared_description_count > 0 || state->error_count > 0;
    }) && state->error_count == 0;
}

void on_remote_description_set(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->remote_description_set_count += 1;
    state->last_remote_type = type;
    state->changed.notify_all();
}

void on_ice_candidate(
    DinoXWebrtcSession*,
    const char* sdp_mid,
    int sdp_mline_index,
    const char* candidate,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    if (state->ice_candidate_count < kMaxIceCandidates) {
        IceCandidateRecord* record = &state->ice_candidates[state->ice_candidate_count];
        std::strncpy(record->sdp_mid, sdp_mid == nullptr ? "" : sdp_mid, sizeof(record->sdp_mid) - 1);
        record->sdp_mid[sizeof(record->sdp_mid) - 1] = '\0';
        record->sdp_mline_index = sdp_mline_index;
        std::strncpy(record->candidate, candidate == nullptr ? "" : candidate, sizeof(record->candidate) - 1);
        record->candidate[sizeof(record->candidate) - 1] = '\0';
        state->ice_candidate_count += 1;
    }
    state->changed.notify_all();
}

void on_ice_gathering_complete(DinoXWebrtcSession*, void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->ice_gathering_complete_count += 1;
    state->changed.notify_all();
}

void on_error(
    DinoXWebrtcSession*,
    DinoXWebrtcStatus status,
    const char* message,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->error_count += 1;
    state->last_error = status;
    std::strncpy(state->last_error_message, message == nullptr ? "" : message, sizeof(state->last_error_message) - 1);
    state->last_error_message[sizeof(state->last_error_message) - 1] = '\0';
    state->changed.notify_all();
}

void on_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || bgra_data == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->video_frame_callback_count += 1;
    state->last_video_frame_id = frame_id;
    state->last_video_frame_width = width;
    state->last_video_frame_height = height;
    state->last_video_frame_stride = stride;
    state->changed.notify_all();
}

void on_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    void* user_data) {
    CallbackState* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || bgra_data == nullptr) {
        return;
    }

    const std::lock_guard<std::mutex> lock(state->mutex);
    state->local_video_frame_callback_count += 1;
    state->last_local_video_frame_id = frame_id;
    state->last_local_video_frame_width = width;
    state->last_local_video_frame_height = height;
    state->last_local_video_frame_stride = stride;
    state->changed.notify_all();
}

bool wait_for_local_description(CallbackState* state) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    std::unique_lock<std::mutex> lock(state->mutex);
    while (state->local_description_count == 0 && state->error_count == 0) {
        if (state->changed.wait_until(lock, deadline) == std::cv_status::timeout) {
            return false;
        }
    }
    return true;
}

bool wait_for_remote_description_set(CallbackState* state) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    std::unique_lock<std::mutex> lock(state->mutex);
    while (state->remote_description_set_count == 0 && state->error_count == 0) {
        if (state->changed.wait_until(lock, deadline) == std::cv_status::timeout) {
            return false;
        }
    }
    return true;
}

bool copy_ice_candidate(CallbackState* state, int index, IceCandidateRecord* out_record) {
    const std::lock_guard<std::mutex> lock(state->mutex);
    if (index < 0 || index >= state->ice_candidate_count) {
        return false;
    }
    *out_record = state->ice_candidates[index];
    return true;
}

bool add_pending_ice_candidates(CallbackState* from_state, int* next_index, DinoXWebrtcSession* to_session) {
    while (true) {
        IceCandidateRecord candidate = {};
        if (!copy_ice_candidate(from_state, *next_index, &candidate)) {
            return true;
        }
        DinoXWebrtcStatus status = dinox_webrtc_session_add_remote_ice_candidate(
            to_session,
            candidate.sdp_mid,
            candidate.sdp_mline_index,
            candidate.candidate);
        if (status != DINOX_WEBRTC_STATUS_OK) {
            fprintf(stderr, "failed to add remote ICE candidate: %s\n", dinox_webrtc_status_to_string(status));
            return false;
        }
        *next_index += 1;
    }
}

bool is_connected_state(const DinoXWebrtcSessionState& state) {
    return state.peer_connection_state == DINOX_WEBRTC_PEER_CONNECTION_STATE_CONNECTED ||
        state.ice_connection_state == DINOX_WEBRTC_ICE_CONNECTION_STATE_CONNECTED ||
        state.ice_connection_state == DINOX_WEBRTC_ICE_CONNECTION_STATE_COMPLETED;
}

bool wait_for_connected_pair(
    DinoXWebrtcSession* offer_session,
    CallbackState* offer_state,
    DinoXWebrtcSession* answer_session,
    CallbackState* answer_state) {
    int next_offer_candidate = 0;
    int next_answer_candidate = 0;

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);

    while (true) {
        if (!add_pending_ice_candidates(offer_state, &next_offer_candidate, answer_session) ||
            !add_pending_ice_candidates(answer_state, &next_answer_candidate, offer_session)) {
            return false;
        }

        DinoXWebrtcSessionState offer_snapshot = {};
        DinoXWebrtcSessionState answer_snapshot = {};
        if (dinox_webrtc_session_get_state(offer_session, &offer_snapshot) != DINOX_WEBRTC_STATUS_OK ||
            dinox_webrtc_session_get_state(answer_session, &answer_snapshot) != DINOX_WEBRTC_STATUS_OK) {
            return false;
        }

        if (offer_snapshot.remote_audio_receiver_count >= 1 &&
            answer_snapshot.remote_audio_receiver_count >= 1 &&
            offer_snapshot.audio_device_capture_probe_sample_count > 0 &&
            answer_snapshot.audio_device_capture_probe_sample_count > 0 &&
            offer_snapshot.audio_device_capture_probe_peak_level > 0.0 &&
            answer_snapshot.audio_device_capture_probe_peak_level > 0.0 &&
            offer_snapshot.remote_audio_sink_count >= 1 &&
            answer_snapshot.remote_audio_sink_count >= 1 &&
            offer_snapshot.remote_audio_sink_sample_count > 0 &&
            answer_snapshot.remote_audio_sink_sample_count > 0 &&
            is_connected_state(offer_snapshot) &&
            is_connected_state(answer_snapshot)) {
            return true;
        }

        if (std::chrono::steady_clock::now() >= deadline) {
            fprintf(stderr,
                "timed out waiting for connected libwebrtc pair: offer pc=%d ice=%d remote_audio=%d capture_probe_samples=%llu capture_probe_peak=%f remote_audio_sinks=%d remote_audio_samples=%llu, answer pc=%d ice=%d remote_audio=%d capture_probe_samples=%llu capture_probe_peak=%f remote_audio_sinks=%d remote_audio_samples=%llu\n",
                static_cast<int>(offer_snapshot.peer_connection_state),
                static_cast<int>(offer_snapshot.ice_connection_state),
                offer_snapshot.remote_audio_receiver_count,
                static_cast<unsigned long long>(offer_snapshot.audio_device_capture_probe_sample_count),
                offer_snapshot.audio_device_capture_probe_peak_level,
                offer_snapshot.remote_audio_sink_count,
                static_cast<unsigned long long>(offer_snapshot.remote_audio_sink_sample_count),
                static_cast<int>(answer_snapshot.peer_connection_state),
                static_cast<int>(answer_snapshot.ice_connection_state),
                answer_snapshot.remote_audio_receiver_count,
                static_cast<unsigned long long>(answer_snapshot.audio_device_capture_probe_sample_count),
                answer_snapshot.audio_device_capture_probe_peak_level,
                answer_snapshot.remote_audio_sink_count,
                static_cast<unsigned long long>(answer_snapshot.remote_audio_sink_sample_count));
            return false;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

bool wait_for_bidirectional_video_without_state_queries(
    DinoXWebrtcSession* offer_session,
    CallbackState* offer_state,
    DinoXWebrtcSession* answer_session,
    CallbackState* answer_state) {
    int next_offer_candidate = 0;
    int next_answer_candidate = 0;
    uint64_t initial_offer_callbacks = 0;
    uint64_t initial_answer_callbacks = 0;
    {
        const std::scoped_lock lock(offer_state->mutex, answer_state->mutex);
        initial_offer_callbacks = offer_state->video_frame_callback_count;
        initial_answer_callbacks = answer_state->video_frame_callback_count;
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        if (!add_pending_ice_candidates(offer_state, &next_offer_candidate, answer_session) ||
            !add_pending_ice_candidates(answer_state, &next_answer_candidate, offer_session)) {
            return false;
        }
        if (dinox_webrtc_session_push_synthetic_video_frame(offer_session, 160, 120) !=
                DINOX_WEBRTC_STATUS_OK ||
            dinox_webrtc_session_push_synthetic_video_frame(answer_session, 176, 144) !=
                DINOX_WEBRTC_STATUS_OK) {
            return false;
        }

        {
            const std::scoped_lock lock(offer_state->mutex, answer_state->mutex);
            if (offer_state->video_frame_callback_count > initial_offer_callbacks &&
                answer_state->video_frame_callback_count > initial_answer_callbacks &&
                offer_state->last_video_frame_width == 176 &&
                offer_state->last_video_frame_height == 144 &&
                answer_state->last_video_frame_width == 160 &&
                answer_state->last_video_frame_height == 120) {
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    fprintf(stderr,
        "timed out waiting for bidirectional video before any diagnostics query\n");
    return false;
}

bool wait_for_local_dtmf_feedback_mixed(
    DinoXWebrtcSession* session,
    uint64_t previous_mixed_frame_count) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);

    while (true) {
        DinoXWebrtcSessionState snapshot = {};
        if (dinox_webrtc_session_get_state(session, &snapshot) != DINOX_WEBRTC_STATUS_OK) {
            return false;
        }

        if (snapshot.local_dtmf_feedback_mixed_frame_count > previous_mixed_frame_count &&
            snapshot.local_dtmf_feedback_last_sample_rate > 0 &&
            snapshot.local_dtmf_feedback_last_channels > 0 &&
            snapshot.local_dtmf_feedback_last_bytes_per_sample == 2 &&
            snapshot.local_dtmf_feedback_peak_level > 0.0) {
            return true;
        }

        if (std::chrono::steady_clock::now() >= deadline) {
            fprintf(stderr,
                "timed out waiting for local DTMF feedback mix: previous=%llu mixed=%llu start=%llu mix_calls=%llu fmt=%u/%u/%u peak=%f active=%d\n",
                static_cast<unsigned long long>(previous_mixed_frame_count),
                static_cast<unsigned long long>(snapshot.local_dtmf_feedback_mixed_frame_count),
                static_cast<unsigned long long>(snapshot.local_dtmf_feedback_start_count),
                static_cast<unsigned long long>(snapshot.local_dtmf_feedback_mix_call_count),
                snapshot.local_dtmf_feedback_last_sample_rate,
                snapshot.local_dtmf_feedback_last_channels,
                snapshot.local_dtmf_feedback_last_bytes_per_sample,
                snapshot.local_dtmf_feedback_peak_level,
                snapshot.local_dtmf_feedback_active);
            return false;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

bool wait_for_remote_video_frame(
    DinoXWebrtcSession* sender_session,
    DinoXWebrtcSession* receiver_session,
    CallbackState* receiver_callback_state,
    uint64_t previous_frame_count,
    uint64_t previous_callback_count,
    int expected_width,
    int expected_height) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);

    while (true) {
        DinoXWebrtcStatus push_status = dinox_webrtc_session_push_synthetic_video_frame(
            sender_session,
            expected_width,
            expected_height);
        if (push_status != DINOX_WEBRTC_STATUS_OK) {
            fprintf(stderr,
                "failed to push synthetic video frame: %s\n",
                dinox_webrtc_status_to_string(push_status));
            return false;
        }

        DinoXWebrtcSessionState snapshot = {};
        if (dinox_webrtc_session_get_state(receiver_session, &snapshot) != DINOX_WEBRTC_STATUS_OK) {
            return false;
        }

        uint64_t video_frame_callback_count = 0;
        int callback_width = 0;
        int callback_height = 0;
        int callback_stride = 0;
        if (receiver_callback_state != nullptr) {
            const std::lock_guard<std::mutex> lock(receiver_callback_state->mutex);
            video_frame_callback_count = receiver_callback_state->video_frame_callback_count;
            callback_width = receiver_callback_state->last_video_frame_width;
            callback_height = receiver_callback_state->last_video_frame_height;
            callback_stride = receiver_callback_state->last_video_frame_stride;
        }

        if (snapshot.remote_video_sink_count >= 1 &&
            snapshot.remote_video_sink_frame_count > previous_frame_count &&
            snapshot.remote_video_sink_last_width == expected_width &&
            snapshot.remote_video_sink_last_height == expected_height &&
            video_frame_callback_count > previous_callback_count &&
            callback_width == expected_width &&
            callback_height == expected_height &&
            callback_stride >= expected_width * 4) {
            return true;
        }

        if (std::chrono::steady_clock::now() >= deadline) {
            DinoXWebrtcSessionState sender_snapshot = {};
            dinox_webrtc_session_get_state(sender_session, &sender_snapshot);
            fprintf(stderr,
                "timed out waiting for remote video frame: previous=%llu sinks=%d frames=%llu size=%dx%d expected=%dx%d callbacks=%llu/%llu callback-size=%dx%d/%d sender-local-video=%d/%d/%d sender-transceivers=a:%d/v:%d sender-remote-sinks=v:%d/%llu\n",
                static_cast<unsigned long long>(previous_frame_count),
                snapshot.remote_video_sink_count,
                static_cast<unsigned long long>(snapshot.remote_video_sink_frame_count),
                snapshot.remote_video_sink_last_width,
                snapshot.remote_video_sink_last_height,
                expected_width,
                expected_height,
                static_cast<unsigned long long>(video_frame_callback_count),
                static_cast<unsigned long long>(previous_callback_count),
                callback_width,
                callback_height,
                callback_stride,
                sender_snapshot.local_video_source_attached,
                sender_snapshot.local_video_track_attached,
                sender_snapshot.local_video_track_enabled,
                sender_snapshot.audio_transceiver_count,
                sender_snapshot.video_transceiver_count,
                sender_snapshot.remote_video_sink_count,
                static_cast<unsigned long long>(sender_snapshot.remote_video_sink_frame_count));
            return false;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}


int run_projected_muji_smoke(const char* video_codec = "VP8") {
    DinoXWebrtcContext* context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new(&context) == DINOX_WEBRTC_STATUS_OK);
    auto offer_state_storage = std::make_unique<CallbackState>();
    auto answer_state_storage = std::make_unique<CallbackState>();
    CallbackState& offer_state = *offer_state_storage;
    CallbackState& answer_state = *answer_state_storage;
    callback_state_init(&offer_state);
    callback_state_init(&answer_state);
    DinoXWebrtcCallbacks callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_description = on_local_description;
    callbacks.on_local_description_prepared = on_local_description_prepared;
    callbacks.on_remote_description_set = on_remote_description_set;
    callbacks.on_ice_candidate = on_ice_candidate;
    callbacks.on_ice_gathering_complete = on_ice_gathering_complete;
    callbacks.on_error = on_error;
    callbacks.on_video_frame = on_video_frame;
    DinoXWebrtcSessionConfig config = dinox_webrtc_session_config_default();
    DinoXWebrtcSession* offer = nullptr;
    DinoXWebrtcSession* answer = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(context, &config, &callbacks, &offer_state, &offer) == DINOX_WEBRTC_STATUS_OK);
    config.defer_audio_transceiver_until_answer = 1;
    config.defer_video_transceiver_until_answer = 1;
    DINOX_CHECK(dinox_webrtc_session_new(context, &config, &callbacks, &answer_state, &answer) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_prepare_local_description(offer, DINOX_WEBRTC_SDP_TYPE_OFFER) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_prepared_description(&offer_state));
    std::string generated_offer;
    {
        const std::lock_guard<std::mutex> lock(offer_state.mutex);
        DINOX_CHECK(offer_state.local_description_count == 0);
        DINOX_CHECK(offer_state.ice_candidate_count == 0);
        generated_offer = offer_state.last_sdp;
    }
    std::map<std::string, std::string> ids;
    const std::string video_rtpmap = std::string(" ") + video_codec + "/90000";
    bool video_payload_selected = false;
    std::istringstream input(generated_offer);
    std::string line;
    while (std::getline(input, line)) {
        if (line.rfind("a=rtpmap:", 0) != 0) continue;
        const auto space = line.find(' ');
        if (line.find(" opus/48000/2") != std::string::npos) ids[line.substr(9, space - 9)] = "120";
        // Select one actual native format. Its fmtp parameters are retained
        // below, including H.264 profile/packetization and VP9 profile-id.
        if (!video_payload_selected && line.find(video_rtpmap) != std::string::npos) {
            ids[line.substr(9, space - 9)] = "121";
            video_payload_selected = true;
        }
    }
    DINOX_CHECK(ids.size() == 2);
    std::ostringstream projected;
    input.clear(); input.str(generated_offer);
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("m=", 0) == 0) {
            std::istringstream fields(line);
            std::string media, port, protocol, id;
            fields >> media >> port >> protocol;
            projected << media << " " << port << " " << protocol;
            while (fields >> id) if (ids.count(id)) projected << " " << ids.at(id);
            projected << "\r\n";
            continue;
        }
        bool payload_attribute = false;
        for (const std::string prefix : {"a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"}) {
            if (line.rfind(prefix, 0) != 0) continue;
            payload_attribute = true;
            const auto space = line.find(' ', prefix.size());
            const auto id = line.substr(prefix.size(), space - prefix.size());
            if (id == "*") projected << line << "\r\n";
            else if (ids.count(id)) projected << prefix << ids.at(id) << line.substr(space) << "\r\n";
            break;
        }
        if (payload_attribute || line.rfind("a=ssrc-group:FID ", 0) == 0) continue;
        if (line == "a=mid:0") line = "a=mid:audio";
        if (line == "a=mid:1") line = "a=mid:video";
        if (line == "a=group:BUNDLE 0 1") line = "a=group:BUNDLE audio video";
        projected << line << "\r\n";
    }
    std::string offer_sdp = projected.str();
    const auto audio_mid = offer_sdp.find("a=mid:audio\r\n");
    DINOX_CHECK(audio_mid != std::string::npos);
    offer_sdp.insert(audio_mid + 13, "a=ptime:20\r\na=maxptime:60\r\n");
    DINOX_CHECK(offer_sdp.find("a=rtpmap:120 opus/48000/2") != std::string::npos);
    DINOX_CHECK(offer_sdp.find("a=rtpmap:121" + video_rtpmap) != std::string::npos);
    DINOX_CHECK(dinox_webrtc_session_set_local_description(offer, DINOX_WEBRTC_SDP_TYPE_OFFER, offer_sdp.c_str()) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_local_description(&offer_state));
    DINOX_CHECK(offer_state.error_count == 0);
    DINOX_CHECK(std::strstr(offer_state.last_sdp, "a=mid:audio\r\n") != nullptr);
    DINOX_CHECK(std::strstr(offer_state.last_sdp, "a=ptime:20\r\n") != nullptr);
    DINOX_CHECK(std::strstr(offer_state.last_sdp, "a=maxptime:60\r\n") != nullptr);
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(answer, DINOX_WEBRTC_SDP_TYPE_OFFER, offer_state.last_sdp) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_remote_description_set(&answer_state));
    DINOX_CHECK(answer_state.error_count == 0);
    DINOX_CHECK(dinox_webrtc_session_prepare_local_description(answer, DINOX_WEBRTC_SDP_TYPE_ANSWER) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_prepared_description(&answer_state));
    std::string answer_sdp;
    {
        const std::lock_guard<std::mutex> lock(answer_state.mutex);
        DINOX_CHECK(answer_state.local_description_count == 0);
        answer_sdp = answer_state.last_sdp;
    }
    DINOX_CHECK(answer_sdp.find("a=rtpmap:120 opus/48000/2") != std::string::npos);
    DINOX_CHECK(answer_sdp.find("a=rtpmap:121" + video_rtpmap) != std::string::npos);
    // Native answer generation may omit optional media timing; project it
    // before commit, then verify the actual stored description preserves it.
    const auto answer_audio_mid = answer_sdp.find("a=mid:audio\r\n");
    DINOX_CHECK(answer_audio_mid != std::string::npos);
    if (answer_sdp.find("a=ptime:") == std::string::npos) answer_sdp.insert(answer_audio_mid + 13, "a=ptime:20\r\n");
    if (answer_sdp.find("a=maxptime:") == std::string::npos) answer_sdp.insert(answer_audio_mid + 13, "a=maxptime:60\r\n");
    DINOX_CHECK(dinox_webrtc_session_set_local_description(answer, DINOX_WEBRTC_SDP_TYPE_ANSWER, answer_sdp.c_str()) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_local_description(&answer_state));
    DINOX_CHECK(answer_state.error_count == 0);
    DINOX_CHECK(std::strstr(answer_state.last_sdp, "a=ptime:20\r\n") != nullptr);
    DINOX_CHECK(std::strstr(answer_state.last_sdp, "a=maxptime:60\r\n") != nullptr);
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(offer, DINOX_WEBRTC_SDP_TYPE_ANSWER, answer_state.last_sdp) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_remote_description_set(&offer_state));
    DINOX_CHECK(offer_state.error_count == 0);
    DINOX_CHECK(wait_for_bidirectional_video_without_state_queries(offer, &offer_state, answer, &answer_state));
    DINOX_CHECK(wait_for_connected_pair(offer, &offer_state, answer, &answer_state));
    DINOX_CHECK(dinox_webrtc_session_close(answer) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_close(offer) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(answer);
    dinox_webrtc_session_free(offer);
    dinox_webrtc_context_free(context);
    return 0;
}

}  // namespace

int main() {
    const char* video_codec = std::getenv("DINOX_WEBRTC_VIDEO_CODEC_SMOKE_ONLY");
    if (video_codec != nullptr) {
        DINOX_CHECK(std::strcmp(video_codec, "VP8") == 0 ||
                    std::strcmp(video_codec, "VP9") == 0 ||
                    std::strcmp(video_codec, "H264") == 0);
        return run_projected_muji_smoke(video_codec);
    }
#ifdef DINOX_WEBRTC_MUJI_SDP_SMOKE_ONLY
    return run_projected_muji_smoke();
#endif
    if (std::getenv("DINOX_WEBRTC_MUJI_SDP_SMOKE_ONLY") != nullptr) return run_projected_muji_smoke();
    const DinoXWebrtcBuildInfo* build_info = dinox_webrtc_get_build_info();
    DINOX_CHECK(build_info != nullptr);
    DINOX_CHECK(build_info->abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(build_info->webrtc_milestone == 152);
    DINOX_CHECK(std::strcmp(build_info->webrtc_branch, "7977") == 0);
    DINOX_CHECK(std::strcmp(build_info->webrtc_commit, "6f37672d358475cd17544121a12494da454d85fb") == 0);
    DINOX_CHECK(std::strcmp(build_info->artifact_abi, "dinox-libwebrtc-runtime-v2") == 0);
    DINOX_CHECK(build_info->runtime_enabled == 1);

    DINOX_CHECK(std::strcmp(dinox_webrtc_status_to_string(DINOX_WEBRTC_STATUS_OK), "ok") == 0);
    DINOX_CHECK(std::strcmp(dinox_webrtc_status_to_string(DINOX_WEBRTC_STATUS_PARSE_ERROR), "parse-error") == 0);
    DINOX_CHECK(dinox_webrtc_context_new(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DinoXWebrtcContext* invalid_context = nullptr;
    DINOX_CHECK(
        dinox_webrtc_context_new_with_audio_device_mode(
            static_cast<DinoXWebrtcAudioDeviceMode>(99),
            &invalid_context) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(invalid_context == nullptr);
    DINOX_CHECK(dinox_webrtc_session_create_offer(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DinoXWebrtcSessionState empty_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(nullptr, &empty_state) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_get_state(nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_set_local_audio_enabled(nullptr, 0) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_set_local_video_enabled(nullptr, 0) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(nullptr, 160, 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_start_video_capture(nullptr, "invalid", 640, 480, 30) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    int invalid_count = -1;
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_count(nullptr, 0, &invalid_count) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_count(nullptr, 0, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device(nullptr, 0, 0) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);

    DinoXWebrtcContext* context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new(&context) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(context != nullptr);

    DinoXWebrtcVideoEffectCapabilities effect_capabilities = {};
    DINOX_CHECK(dinox_webrtc_context_get_video_effect_capabilities(
        context, &effect_capabilities) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_capabilities.abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(effect_capabilities.supported_effect_mask ==
        ((UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_NONE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_SEPIA) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_DREAMY) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE) |
         (UINT64_C(1) << DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER)));
    DINOX_CHECK(effect_capabilities.supported_adjustment_mask == 15);
    DINOX_CHECK(effect_capabilities.supported_background_mask == (effect_capabilities.auto_framing_supported ? 15U : 1U));
    DINOX_CHECK(effect_capabilities.supported_glasses_mask == (effect_capabilities.touch_up_supported ? 15U : 1U) &&
        effect_capabilities.supported_hat_mask == effect_capabilities.supported_glasses_mask &&
        effect_capabilities.supported_beard_mask == effect_capabilities.supported_glasses_mask &&
        effect_capabilities.supported_face_accessory_mask == (effect_capabilities.touch_up_supported ? 7U : 1U) &&
        effect_capabilities.supported_scene_effect_mask == 31 && effect_capabilities.low_light_supported == 1);
    DINOX_CHECK(effect_capabilities.supported_quality_mask == 1);
    DINOX_CHECK(effect_capabilities.shared_pipeline_supported == 1);
    DINOX_CHECK(effect_capabilities.preview_publisher_supported == 1);

    PipelineCallbackState pipeline_callback_state;
    DinoXWebrtcVideoPipelineCallbacks pipeline_callbacks =
        dinox_webrtc_video_pipeline_callbacks_default();
    pipeline_callbacks.on_state_changed = on_video_pipeline_state;
    DinoXWebrtcVideoPipeline* video_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 7001, &pipeline_callbacks, &pipeline_callback_state, &video_pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(video_pipeline != nullptr);
    DinoXWebrtcVideoPipelineState initial_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &initial_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(initial_pipeline_state.logical_call_id == 7001);
    DINOX_CHECK(initial_pipeline_state.application_state ==
        DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_IDLE);
    DINOX_CHECK(initial_pipeline_state.accepted_revision == 0);
    DINOX_CHECK(initial_pipeline_state.applied_revision == 0);
    DINOX_CHECK(initial_pipeline_state.subscriber_count == 0);

    DinoXWebrtcMediaRecorderConfig recorder_config =
        dinox_webrtc_media_recorder_config_default();
    DinoXWebrtcMediaRecorderCallbacks recorder_callbacks =
        dinox_webrtc_media_recorder_callbacks_default();
    DINOX_CHECK(recorder_config.abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(recorder_config.kind == DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO);
    DINOX_CHECK(std::strcmp(recorder_config.mime_type, "audio/mp4") == 0);
    DINOX_CHECK(recorder_config.width == 640);
    DINOX_CHECK(recorder_config.height == 480);
    DINOX_CHECK(recorder_config.max_fps == 24);
    DINOX_CHECK(recorder_callbacks.abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DinoXWebrtcMediaRecorderState recorder_state = DINOX_WEBRTC_MEDIA_RECORDER_STATE_FAILED;
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(nullptr, &recorder_state) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DinoXWebrtcMediaRecorder* invalid_recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        nullptr,
        &recorder_config,
        &recorder_callbacks,
        nullptr,
        &invalid_recorder) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(invalid_recorder == nullptr);
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context,
        &recorder_config,
        &recorder_callbacks,
        nullptr,
        &invalid_recorder) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(invalid_recorder == nullptr);

    recorder_config.output_path = "/tmp/dinox-webrtc-wrapper-smoke.m4a";
    recorder_config.mime_type = "audio/mp4";
    RecorderCallbackState recorder_callback_state = {};
    recorder_callback_state_init(&recorder_callback_state);
    recorder_callbacks.on_started = on_recorder_started;
    recorder_callbacks.on_stopped = on_recorder_stopped;
    recorder_callbacks.on_error = on_recorder_error;
    recorder_callbacks.on_audio_frame = on_recorder_audio_frame;
    recorder_callbacks.on_video_frame = on_recorder_video_frame;
    DinoXWebrtcMediaRecorder* audio_recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context,
        &recorder_config,
        &recorder_callbacks,
        &recorder_callback_state,
        &audio_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(audio_recorder != nullptr);
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(audio_recorder, &recorder_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(audio_recorder) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(audio_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(audio_recorder, &recorder_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_RECORDING);
    DINOX_CHECK(recorder_callback_state.started_count == 1);
    DINOX_CHECK(recorder_callback_state.error_count == 0);
    DINOX_CHECK(recorder_callback_state.audio_frame_count == 1);
    DINOX_CHECK(recorder_callback_state.last_audio_byte_count == 480 * sizeof(int16_t));
    DINOX_CHECK(recorder_callback_state.last_audio_sample_rate == 48000);
    DINOX_CHECK(recorder_callback_state.last_audio_channels == 1);
    DINOX_CHECK(recorder_callback_state.last_audio_bytes_per_sample == static_cast<int>(sizeof(int16_t)));
    DINOX_CHECK(recorder_callback_state.last_audio_frame_id == 1);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(audio_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_callback_state.audio_frame_count == 2);
    DINOX_CHECK(recorder_callback_state.last_audio_frame_id == 2);
    DINOX_CHECK(dinox_webrtc_media_recorder_stop(audio_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_callback_state.stopped_count == 1);
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(audio_recorder, &recorder_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE);
    DINOX_CHECK(dinox_webrtc_media_recorder_cancel(audio_recorder) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_media_recorder_free(audio_recorder);

    recorder_config.kind = DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO;
    recorder_config.output_path = "/tmp/dinox-webrtc-wrapper-smoke.mp4";
    recorder_config.mime_type = "video/mp4";
    recorder_callback_state_init(&recorder_callback_state);
    DinoXWebrtcMediaRecorder* video_recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context,
        &recorder_config,
        &recorder_callbacks,
        &recorder_callback_state,
        &video_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(video_recorder != nullptr);
    DINOX_CHECK(dinox_webrtc_media_recorder_get_state(video_recorder, &recorder_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_state == DINOX_WEBRTC_MEDIA_RECORDER_STATE_IDLE);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(video_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_callback_state.started_count == 1);
    DINOX_CHECK(recorder_callback_state.video_frame_count == 1);
    DINOX_CHECK(recorder_callback_state.last_video_width == recorder_config.width);
    DINOX_CHECK(recorder_callback_state.last_video_height == recorder_config.height);
    DINOX_CHECK(recorder_callback_state.last_video_stride == recorder_config.width * 4);
    DINOX_CHECK(recorder_callback_state.last_video_frame_id == 1);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(video_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_callback_state.video_frame_count == 2);
    DINOX_CHECK(recorder_callback_state.last_video_frame_id == 2);
    DINOX_CHECK(dinox_webrtc_media_recorder_stop(video_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_callback_state.stopped_count == 1);
    dinox_webrtc_media_recorder_free(video_recorder);

    BlockingCallbackState recorder_barrier_state;
    DinoXWebrtcMediaRecorderCallbacks blocking_recorder_callbacks =
        dinox_webrtc_media_recorder_callbacks_default();
    blocking_recorder_callbacks.on_audio_frame = on_blocking_recorder_audio_frame;
    recorder_config.kind = DINOX_WEBRTC_MEDIA_RECORDER_KIND_AUDIO;
    recorder_config.output_path = "/tmp/dinox-webrtc-wrapper-callback-barrier.m4a";
    recorder_config.mime_type = "audio/mp4";
    DinoXWebrtcMediaRecorder* barrier_recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context,
        &recorder_config,
        &blocking_recorder_callbacks,
        &recorder_barrier_state,
        &barrier_recorder) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcStatus barrier_start_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::thread recorder_callback_thread([&]() {
        barrier_start_status = dinox_webrtc_media_recorder_start(barrier_recorder);
    });
    DINOX_CHECK(wait_for_blocking_callback(&recorder_barrier_state));
    std::atomic<bool> recorder_cancel_done = false;
    DinoXWebrtcStatus barrier_cancel_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::thread recorder_cancel_thread([&]() {
        barrier_cancel_status = dinox_webrtc_media_recorder_cancel(barrier_recorder);
        recorder_cancel_done.store(true);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    DINOX_CHECK(!recorder_cancel_done.load());
    release_blocking_callback(&recorder_barrier_state);
    recorder_callback_thread.join();
    recorder_cancel_thread.join();
    DINOX_CHECK(barrier_start_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(barrier_cancel_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(recorder_cancel_done.load());
    dinox_webrtc_media_recorder_free(barrier_recorder);

    int synthetic_microphone_count = 0;
    int synthetic_speaker_count = 0;
    char synthetic_microphone_name[128] = {};
    char synthetic_microphone_guid[128] = {};
    char synthetic_speaker_name[128] = {};
    char synthetic_speaker_guid[128] = {};
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_count(context, 0, &synthetic_microphone_count) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_count(context, 1, &synthetic_speaker_count) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(synthetic_microphone_count == 1);
    DINOX_CHECK(synthetic_speaker_count == 1);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_count(context, 2, &synthetic_microphone_count) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_name(
        context, 0, 0,
        synthetic_microphone_name, sizeof(synthetic_microphone_name),
        synthetic_microphone_guid, sizeof(synthetic_microphone_guid)) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_name(
        context, 1, 0,
        synthetic_speaker_name, sizeof(synthetic_speaker_name),
        synthetic_speaker_guid, sizeof(synthetic_speaker_guid)) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(std::strcmp(synthetic_microphone_name, "DinoX synthetic microphone") == 0);
    DINOX_CHECK(std::strcmp(synthetic_speaker_name, "DinoX synthetic speaker") == 0);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device(context, 0, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device(context, 1, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device(context, 0, 1) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    double synthetic_microphone_volume = 0.0;
    int synthetic_microphone_volume_available = 1;
    double synthetic_speaker_volume = 0.0;
    int synthetic_speaker_volume_available = 1;
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_volume(
        context, 0, &synthetic_microphone_volume, &synthetic_microphone_volume_available) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_volume(
        context, 1, &synthetic_speaker_volume, &synthetic_speaker_volume_available) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(synthetic_microphone_volume_available == 0);
    DINOX_CHECK(synthetic_speaker_volume_available == 0);
    DINOX_CHECK(synthetic_microphone_volume == 1.0);
    DINOX_CHECK(synthetic_speaker_volume == 1.0);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_volume(context, 2, &synthetic_microphone_volume, &synthetic_microphone_volume_available) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_audio_device_volume(context, 0, nullptr, &synthetic_microphone_volume_available) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device_volume(context, 0, 0.75) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device_volume(context, 1, 0.75) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device_volume(context, 2, 0.75) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_play_test_tone(nullptr, '5', 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_play_test_tone(context, 'x', 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_play_test_tone(context, '5', 19) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_play_test_tone(context, '5', 1001) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    std::array<uint8_t, 960 * 2> audio_test_clip = {};
    for (size_t index = 0; index < audio_test_clip.size() / 2; index++) {
        const int16_t sample = (index % 48) < 24 ? 8000 : -8000;
        audio_test_clip[index * 2] = static_cast<uint8_t>(sample & 0xff);
        audio_test_clip[index * 2 + 1] = static_cast<uint8_t>((sample >> 8) & 0xff);
    }
    unsigned int audio_test_duration_ms = 0;
    DINOX_CHECK(dinox_webrtc_context_play_audio_test_clip(
        nullptr,
        audio_test_clip.data(),
        audio_test_clip.size(),
        48000,
        1,
        2,
        &audio_test_duration_ms) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_play_audio_test_clip(
        context,
        audio_test_clip.data(),
        audio_test_clip.size(),
        48000,
        1,
        2,
        &audio_test_duration_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(audio_test_duration_ms == 20);
    DINOX_CHECK(dinox_webrtc_context_stop_audio_test_playout(context) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_stop_audio_test_playout(nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);

    unsigned int media_audio_queued_ms = 0;
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        nullptr, 48000, 1, 2) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        context, 7999, 1, 2) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        context, 48000, 3, 2) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        audio_test_clip.data(),
        audio_test_clip.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        context, 48000, 1, 2) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        audio_test_clip.data(),
        audio_test_clip.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(media_audio_queued_ms > 0 && media_audio_queued_ms <= 20);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 2) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_flush(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        audio_test_clip.data(),
        audio_test_clip.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_finish(
        context, &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(media_audio_queued_ms <= 20);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        audio_test_clip.data(),
        audio_test_clip.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(nullptr) ==
        DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    int video_device_count = -1;
    char video_device_name[256] = {};
    char video_device_unique_id[1024] = {};
    char video_device_product_id[128] = {};
    DINOX_CHECK(dinox_webrtc_context_get_video_device_count(nullptr, &video_device_count) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_video_device_count(context, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_video_device_count(context, &video_device_count) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(video_device_count >= 0);
    DINOX_CHECK(dinox_webrtc_context_get_video_device_name(
        nullptr,
        0,
        video_device_name,
        sizeof(video_device_name),
        video_device_unique_id,
        sizeof(video_device_unique_id),
        video_device_product_id,
        sizeof(video_device_product_id)) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_video_device_name(
        context,
        -1,
        video_device_name,
        sizeof(video_device_name),
        video_device_unique_id,
        sizeof(video_device_unique_id),
        video_device_product_id,
        sizeof(video_device_product_id)) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_context_get_video_device_name(
        context,
        0,
        nullptr,
        sizeof(video_device_name),
        video_device_unique_id,
        sizeof(video_device_unique_id),
        video_device_product_id,
        sizeof(video_device_product_id)) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    if (video_device_count > 0) {
        DINOX_CHECK(dinox_webrtc_context_get_video_device_name(
            context,
            0,
            video_device_name,
            sizeof(video_device_name),
            video_device_unique_id,
            sizeof(video_device_unique_id),
            video_device_product_id,
            sizeof(video_device_product_id)) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(video_device_name[0] != '\0');
        DINOX_CHECK(video_device_unique_id[0] != '\0');
    } else {
        DINOX_CHECK(dinox_webrtc_context_get_video_device_name(
            context,
            0,
            video_device_name,
            sizeof(video_device_name),
            video_device_unique_id,
            sizeof(video_device_unique_id),
            video_device_product_id,
            sizeof(video_device_product_id)) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    }

    const char* test_platform_audio = getenv("DINOX_WEBRTC_TEST_PLATFORM_AUDIO_DEVICE");
    if (test_platform_audio != nullptr && strcmp(test_platform_audio, "1") == 0) {
        DinoXWebrtcContext* platform_context = nullptr;
        DINOX_CHECK(
            dinox_webrtc_context_new_with_audio_device_mode(
                DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT,
                &platform_context) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(platform_context != nullptr);
        int platform_microphone_count = 0;
        int platform_speaker_count = 0;
        DinoXWebrtcStatus platform_microphone_status =
            dinox_webrtc_context_get_audio_device_count(platform_context, 0, &platform_microphone_count);
        DinoXWebrtcStatus platform_speaker_status =
            dinox_webrtc_context_get_audio_device_count(platform_context, 1, &platform_speaker_count);
        DINOX_CHECK(platform_microphone_status == DINOX_WEBRTC_STATUS_OK ||
            platform_microphone_status == DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
        DINOX_CHECK(platform_speaker_status == DINOX_WEBRTC_STATUS_OK ||
            platform_speaker_status == DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
        if (platform_microphone_status == DINOX_WEBRTC_STATUS_OK && platform_microphone_count > 0) {
            char platform_name[128] = {};
            char platform_guid[128] = {};
            DINOX_CHECK(dinox_webrtc_context_get_audio_device_name(
                platform_context, 0, 0,
                platform_name, sizeof(platform_name),
                platform_guid, sizeof(platform_guid)) == DINOX_WEBRTC_STATUS_OK);
            double platform_microphone_volume = 0.0;
            int platform_microphone_volume_available = 0;
            DinoXWebrtcStatus platform_microphone_volume_status =
                dinox_webrtc_context_get_audio_device_volume(
                    platform_context,
                    0,
                    &platform_microphone_volume,
                    &platform_microphone_volume_available);
            DINOX_CHECK(platform_microphone_volume_status == DINOX_WEBRTC_STATUS_OK ||
                platform_microphone_volume_status == DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
            if (platform_microphone_volume_status == DINOX_WEBRTC_STATUS_OK) {
                DINOX_CHECK(platform_microphone_volume >= 0.0);
                DINOX_CHECK(platform_microphone_volume <= 1.0);
                DINOX_CHECK(platform_microphone_volume_available == 0 ||
                    platform_microphone_volume_available == 1);
            }
        }
        if (platform_speaker_status == DINOX_WEBRTC_STATUS_OK && platform_speaker_count > 0) {
            char platform_name[128] = {};
            char platform_guid[128] = {};
            DINOX_CHECK(dinox_webrtc_context_get_audio_device_name(
                platform_context, 1, 0,
                platform_name, sizeof(platform_name),
                platform_guid, sizeof(platform_guid)) == DINOX_WEBRTC_STATUS_OK);
            double platform_speaker_volume = 0.0;
            int platform_speaker_volume_available = 0;
            DinoXWebrtcStatus platform_speaker_volume_status =
                dinox_webrtc_context_get_audio_device_volume(
                    platform_context,
                    1,
                    &platform_speaker_volume,
                    &platform_speaker_volume_available);
            DINOX_CHECK(platform_speaker_volume_status == DINOX_WEBRTC_STATUS_OK ||
                platform_speaker_volume_status == DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
            if (platform_speaker_volume_status == DINOX_WEBRTC_STATUS_OK) {
                DINOX_CHECK(platform_speaker_volume >= 0.0);
                DINOX_CHECK(platform_speaker_volume <= 1.0);
                DINOX_CHECK(platform_speaker_volume_available == 0 ||
                    platform_speaker_volume_available == 1);
            }
        }
        dinox_webrtc_context_free(platform_context);

        DinoXWebrtcContext* second_platform_context = nullptr;
        DINOX_CHECK(
            dinox_webrtc_context_new_with_audio_device_mode(
                DINOX_WEBRTC_AUDIO_DEVICE_PLATFORM_DEFAULT,
                &second_platform_context) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(second_platform_context != nullptr);
        dinox_webrtc_context_free(second_platform_context);
    }

    DinoXWebrtcSessionConfig config = dinox_webrtc_session_config_default();
    DINOX_CHECK(config.abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(config.audio_enabled == 1);
    DINOX_CHECK(config.video_enabled == 1);
    DINOX_CHECK(config.audio_direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV);
    DINOX_CHECK(config.defer_audio_transceiver_until_answer == 0);
    DINOX_CHECK(config.video_direction == DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV);
    DINOX_CHECK(config.defer_video_transceiver_until_answer == 0);
    DINOX_CHECK(config.max_bundle == 1);

    CallbackState callback_state;
    callback_state_init(&callback_state);
    DinoXWebrtcCallbacks callbacks = dinox_webrtc_callbacks_default();
    DINOX_CHECK(callbacks.abi_version == DINOX_WEBRTC_ABI_VERSION);
    callbacks.on_local_description = on_local_description;
    callbacks.on_remote_description_set = on_remote_description_set;
    callbacks.on_ice_candidate = on_ice_candidate;
    callbacks.on_ice_gathering_complete = on_ice_gathering_complete;
    callbacks.on_error = on_error;
    callbacks.on_video_frame = on_video_frame;
    callbacks.on_local_video_frame = on_local_video_frame;

    BlockingCallbackState session_barrier_state;
    DinoXWebrtcCallbacks blocking_session_callbacks = dinox_webrtc_callbacks_default();
    blocking_session_callbacks.on_local_video_frame = on_blocking_local_video_frame;
    DinoXWebrtcSession* barrier_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context,
        &config,
        &blocking_session_callbacks,
        &session_barrier_state,
        &barrier_session) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcStatus barrier_push_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::thread session_callback_thread([&]() {
        barrier_push_status = dinox_webrtc_session_push_synthetic_video_frame(
            barrier_session,
            160,
            120);
    });
    DINOX_CHECK(wait_for_blocking_callback(&session_barrier_state));
    std::atomic<bool> session_close_done = false;
    DinoXWebrtcStatus barrier_close_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::thread session_close_thread([&]() {
        barrier_close_status = dinox_webrtc_session_close(barrier_session);
        session_close_done.store(true);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    DINOX_CHECK(!session_close_done.load());
    release_blocking_callback(&session_barrier_state);
    session_callback_thread.join();
    session_close_thread.join();
    DINOX_CHECK(barrier_push_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(barrier_close_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_close_done.load());
    dinox_webrtc_session_free(barrier_session);

    // Hold the pipeline publication gate after the effect-state transition,
    // then close its publisher. Close marks the session closed before waiting
    // for that gate. Observation/pruning in this interval must retain the
    // attachment so Close still owns its ordered detach/capture cleanup.
    BlockingCallbackState close_prune_pipeline_barrier;
    DinoXWebrtcVideoPipelineCallbacks close_prune_pipeline_callbacks =
        dinox_webrtc_video_pipeline_callbacks_default();
    close_prune_pipeline_callbacks.on_state_changed =
        on_blocking_video_pipeline_state;
    DinoXWebrtcVideoPipeline* close_prune_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context,
        7002,
        &close_prune_pipeline_callbacks,
        &close_prune_pipeline_barrier,
        &close_prune_pipeline) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSession* close_prune_session = nullptr;
    DinoXWebrtcCallbacks close_prune_session_callbacks =
        dinox_webrtc_callbacks_default();
    DINOX_CHECK(dinox_webrtc_session_new(
        context,
        &config,
        &close_prune_session_callbacks,
        nullptr,
        &close_prune_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        close_prune_pipeline,
        close_prune_session,
        1) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoEffectConfig close_prune_no_effect =
        dinox_webrtc_video_effect_config_default();
    uint64_t close_prune_revision = 0;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        close_prune_pipeline,
        &close_prune_no_effect,
        &close_prune_revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_prune_revision == 1);
    DINOX_CHECK(wait_for_blocking_callback(&close_prune_pipeline_barrier));

    std::atomic<bool> close_prune_started = false;
    std::atomic<bool> close_prune_done = false;
    DinoXWebrtcStatus close_prune_status = DINOX_WEBRTC_STATUS_INTERNAL_ERROR;
    std::thread close_prune_thread([&]() {
        close_prune_started.store(true);
        close_prune_status = dinox_webrtc_session_close(close_prune_session);
        close_prune_done.store(true);
    });
    const auto close_prune_start_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!close_prune_started.load() &&
            std::chrono::steady_clock::now() < close_prune_start_deadline) {
        std::this_thread::yield();
    }
    DINOX_CHECK(close_prune_started.load());
    // Close has no blocking work before marking SessionCore closed and joining
    // the publication barrier. Give it multiple scheduler quanta, then observe
    // the pipeline through its independent state mutex while it is still held.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    DINOX_CHECK(!close_prune_done.load());
    DinoXWebrtcVideoPipelineState close_prune_blocked_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        close_prune_pipeline,
        &close_prune_blocked_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_prune_blocked_state.subscriber_count == 1);
    DINOX_CHECK(close_prune_blocked_state.preview_subscriber_id != 0);

    release_blocking_callback(&close_prune_pipeline_barrier);
    close_prune_thread.join();
    DINOX_CHECK(close_prune_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_prune_done.load());
    DinoXWebrtcVideoPipelineState close_prune_detached_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        close_prune_pipeline,
        &close_prune_detached_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_prune_detached_state.subscriber_count == 0);
    DINOX_CHECK(close_prune_detached_state.preview_subscriber_id == 0);
    DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
        close_prune_pipeline,
        close_prune_session) == DINOX_WEBRTC_STATUS_NOT_READY);
    dinox_webrtc_session_free(close_prune_session);
    dinox_webrtc_video_pipeline_free(close_prune_pipeline);

    DINOX_CHECK(dinox_webrtc_session_add_ice_server(nullptr, "stun:127.0.0.1:9", nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DinoXWebrtcSession* ice_config_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(context, &config, &callbacks, &callback_state, &ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(ice_config_session != nullptr);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        video_pipeline, ice_config_session, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(
        ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(
        ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipelineState attached_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &attached_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(attached_pipeline_state.subscriber_count == 1);
    DINOX_CHECK(attached_pipeline_state.preview_subscriber_id != 0);
    DINOX_CHECK(attached_pipeline_state.preview_subscriber_generation == 1);
    DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
        video_pipeline, ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        video_pipeline, ice_config_session, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &attached_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(attached_pipeline_state.subscriber_count == 1);
    DINOX_CHECK(attached_pipeline_state.preview_subscriber_id == 0);
    // Subscriber generations, unlike session generations, advance on every
    // successful detach/reattach.  Make it observable by promoting the same
    // subscriber back to preview publisher.
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        video_pipeline, ice_config_session, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &attached_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(attached_pipeline_state.preview_subscriber_generation == 2);

    DinoXWebrtcVideoEffectConfig no_effect = dinox_webrtc_video_effect_config_default();
    uint64_t effect_revision = 0;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        video_pipeline, &no_effect, &effect_revision) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipelineState accepted_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &accepted_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(accepted_pipeline_state.accepted_revision == effect_revision);
    DINOX_CHECK(
        (accepted_pipeline_state.application_state ==
             DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_ACCEPTED &&
         accepted_pipeline_state.applied_revision == 0) ||
        (accepted_pipeline_state.application_state ==
             DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
         accepted_pipeline_state.applied_revision == effect_revision));
    DINOX_CHECK(effect_revision == 1);
    DINOX_CHECK(wait_for_pipeline_callback(&pipeline_callback_state, 1));
    {
        std::lock_guard<std::mutex> lock(pipeline_callback_state.mutex);
        DINOX_CHECK(pipeline_callback_state.last_state.application_state ==
            DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED);
        DINOX_CHECK(pipeline_callback_state.last_state.accepted_revision == effect_revision);
        DINOX_CHECK(pipeline_callback_state.last_state.applied_revision == effect_revision);
    }
    DinoXWebrtcVideoEffectDiagnostics effect_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        video_pipeline, &effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_diagnostics.configuration_request_count == 1);
    DINOX_CHECK(effect_diagnostics.effect_owned_allocated_bytes == 0);
    DINOX_CHECK(effect_diagnostics.effect_thread_count == 0);
    DINOX_CHECK(effect_diagnostics.frame_copy_count == 0);

    DinoXWebrtcVideoEffectConfig grayscale_effect = no_effect;
    grayscale_effect.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        video_pipeline, &grayscale_effect, &effect_revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_revision == 2);
    DINOX_CHECK(wait_for_pipeline_callback(&pipeline_callback_state, 2));
    {
        std::lock_guard<std::mutex> lock(pipeline_callback_state.mutex);
        DINOX_CHECK(pipeline_callback_state.last_state.application_state ==
            DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED);
        DINOX_CHECK(pipeline_callback_state.last_state.effect_type ==
            DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE);
        DINOX_CHECK(pipeline_callback_state.last_state.applied_revision == effect_revision);
    }
    uint64_t preview_before_effect = 0;
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        preview_before_effect = callback_state.local_video_frame_callback_count;
    }
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        ice_config_session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.changed.wait_for(
            lock, std::chrono::seconds(2), [&] {
                return callback_state.local_video_frame_callback_count > preview_before_effect;
            }));
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        video_pipeline, &effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_diagnostics.configuration_request_count == 2);
    DINOX_CHECK(effect_diagnostics.captured == 1);
    DINOX_CHECK(effect_diagnostics.enqueued == 1);
    DINOX_CHECK(effect_diagnostics.processed == 1);
    DINOX_CHECK(effect_diagnostics.frame_copy_count == 1);
    DINOX_CHECK(effect_diagnostics.effect_thread_count == 1);
    DINOX_CHECK(effect_diagnostics.effect_handle_count == 1);

    DinoXWebrtcVideoEffectConfig warm_tone_effect = no_effect;
    warm_tone_effect.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        video_pipeline, &warm_tone_effect, &effect_revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_revision == 3);
    DINOX_CHECK(wait_for_pipeline_callback(&pipeline_callback_state, 3));
    {
        std::lock_guard<std::mutex> lock(pipeline_callback_state.mutex);
        DINOX_CHECK(pipeline_callback_state.last_state.application_state ==
            DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED);
        DINOX_CHECK(pipeline_callback_state.last_state.effect_type ==
            DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);
        DINOX_CHECK(pipeline_callback_state.last_state.applied_revision == effect_revision);
    }
    uint64_t preview_before_warm_tone = 0;
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        preview_before_warm_tone = callback_state.local_video_frame_callback_count;
    }
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        ice_config_session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.changed.wait_for(
            lock, std::chrono::seconds(2), [&] {
                return callback_state.local_video_frame_callback_count >
                    preview_before_warm_tone;
            }));
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        video_pipeline, &effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_diagnostics.configuration_request_count == 3);
    DINOX_CHECK(effect_diagnostics.captured == 2);
    DINOX_CHECK(effect_diagnostics.enqueued == 2);
    DINOX_CHECK(effect_diagnostics.processed == 2);
    DINOX_CHECK(effect_diagnostics.frame_copy_count == 2);
    DINOX_CHECK(effect_diagnostics.effect_thread_count == 1);
    DINOX_CHECK(effect_diagnostics.effect_handle_count == 1);

    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        video_pipeline, &no_effect, &effect_revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_revision == 4);
    DINOX_CHECK(wait_for_pipeline_callback(&pipeline_callback_state, 4));
    {
        std::lock_guard<std::mutex> lock(pipeline_callback_state.mutex);
        DINOX_CHECK(pipeline_callback_state.last_state.effect_type ==
            DINOX_WEBRTC_VIDEO_EFFECT_NONE);
    }
    uint64_t preview_after_off = 0;
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        preview_after_off = callback_state.local_video_frame_callback_count;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.local_video_frame_callback_count == preview_after_off);
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        video_pipeline, &effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_diagnostics.configuration_request_count == 4);
    DINOX_CHECK(effect_diagnostics.captured == 2);
    DINOX_CHECK(effect_diagnostics.enqueued == 2);
    DINOX_CHECK(effect_diagnostics.processed == 2);
    DINOX_CHECK(effect_diagnostics.frame_copy_count == 2);
    DINOX_CHECK(effect_diagnostics.effect_thread_count == 0);
    DINOX_CHECK(effect_diagnostics.effect_handle_count == 0);
    DINOX_CHECK(effect_diagnostics.effect_owned_allocated_bytes == 0);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        ice_config_session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.local_video_frame_callback_count == preview_after_off + 1);
    }
    DinoXWebrtcVideoEffectDiagnostics direct_effect_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        video_pipeline, &direct_effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(direct_effect_diagnostics.captured == effect_diagnostics.captured);
    DINOX_CHECK(direct_effect_diagnostics.enqueued == effect_diagnostics.enqueued);
    DINOX_CHECK(direct_effect_diagnostics.processed == effect_diagnostics.processed);
    DINOX_CHECK(direct_effect_diagnostics.frame_copy_count ==
        effect_diagnostics.frame_copy_count);

    // One logical camera pipeline feeds every attached PeerConnection while
    // publishing the local preview exactly once.  This direct-mode (effect
    // Off) path must not depend on the asynchronous effect worker.
    std::array<CallbackState, 3> fanout_callback_states;
    std::array<DinoXWebrtcSession*, 3> fanout_sessions = {};
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        callback_state_init(&fanout_callback_states[i]);
        DINOX_CHECK(dinox_webrtc_session_new(
            context,
            &config,
            &callbacks,
            &fanout_callback_states[i],
            &fanout_sessions[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
            video_pipeline, fanout_sessions[i], 0) == DINOX_WEBRTC_STATUS_OK);
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &attached_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(attached_pipeline_state.subscriber_count == 4);

    DinoXWebrtcSessionState fanout_publisher_before = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        ice_config_session, &fanout_publisher_before) == DINOX_WEBRTC_STATUS_OK);
    std::array<DinoXWebrtcSessionState, 3> fanout_before = {};
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &fanout_before[i]) == DINOX_WEBRTC_STATUS_OK);
    }
    uint64_t fanout_preview_before = 0;
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        fanout_preview_before = callback_state.local_video_frame_callback_count;
    }
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        ice_config_session, 320, 180) == DINOX_WEBRTC_STATUS_OK);

    DinoXWebrtcSessionState fanout_publisher_after = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        ice_config_session, &fanout_publisher_after) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_publisher_after.local_video_source_frame_count ==
        fanout_publisher_before.local_video_source_frame_count + 1);
    DINOX_CHECK(fanout_publisher_after.local_video_source_last_width == 320);
    DINOX_CHECK(fanout_publisher_after.local_video_source_last_height == 180);
    {
        std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.local_video_frame_callback_count ==
            fanout_preview_before + 1);
    }
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DinoXWebrtcSessionState state = {};
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &state) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(state.local_video_source_frame_count ==
            fanout_before[i].local_video_source_frame_count + 1);
        DINOX_CHECK(state.local_video_source_last_width == 320);
        DINOX_CHECK(state.local_video_source_last_height == 180);
        std::lock_guard<std::mutex> lock(fanout_callback_states[i].mutex);
        DINOX_CHECK(fanout_callback_states[i].local_video_frame_callback_count == 0);
    }

    // Detaching one subscriber must stop only that sink.  The publisher and
    // the other two local video sources continue to receive the shared frame.
    DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
        video_pipeline, fanout_sessions[1]) == DINOX_WEBRTC_STATUS_OK);
    std::array<DinoXWebrtcSessionState, 3> fanout_after_detach = {};
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &fanout_after_detach[i]) == DINOX_WEBRTC_STATUS_OK);
    }
    const uint64_t publisher_before_second_frame =
        fanout_publisher_after.local_video_source_frame_count;
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        ice_config_session, 640, 360) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(
        ice_config_session, &fanout_publisher_after) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_publisher_after.local_video_source_frame_count ==
        publisher_before_second_frame + 1);
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DinoXWebrtcSessionState state = {};
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &state) == DINOX_WEBRTC_STATUS_OK);
        const uint64_t expected_increment = i == 1 ? 0 : 1;
        DINOX_CHECK(state.local_video_source_frame_count ==
            fanout_after_detach[i].local_video_source_frame_count + expected_increment);
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        video_pipeline, &attached_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(attached_pipeline_state.subscriber_count == 3);
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        if (i != 1) {
            DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
                video_pipeline, fanout_sessions[i]) == DINOX_WEBRTC_STATUS_OK);
        }
        DINOX_CHECK(dinox_webrtc_session_close(fanout_sessions[i]) ==
            DINOX_WEBRTC_STATUS_OK);
        dinox_webrtc_session_free(fanout_sessions[i]);
    }

    DinoXWebrtcVideoEffectConfig unknown_effect = no_effect;
    unknown_effect.effect_type = static_cast<DinoXWebrtcVideoEffectType>(99);
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        video_pipeline, &unknown_effect, &effect_revision) ==
        DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
        video_pipeline, ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_add_ice_server(ice_config_session, nullptr, nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_add_ice_server(ice_config_session, "", nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_add_ice_server(ice_config_session, "stun:127.0.0.1:9", nullptr, nullptr) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState ice_config_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(ice_config_session, &ice_config_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(ice_config_state.ice_server_count == 1);
    DINOX_CHECK(dinox_webrtc_session_close(ice_config_session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(ice_config_session);
    callback_state_reset_observations(&callback_state);

    DinoXWebrtcSession* session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(nullptr, &config, &callbacks, nullptr, &session) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_new(context, nullptr, &callbacks, nullptr, &session) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_new(context, &config, nullptr, nullptr, &session) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_new(context, &config, &callbacks, nullptr, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);

    DINOX_CHECK(dinox_webrtc_session_new(context, &config, &callbacks, &callback_state, &session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session != nullptr);
    DinoXWebrtcSessionState session_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(session, nullptr) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.abi_version == DINOX_WEBRTC_ABI_VERSION);
    DINOX_CHECK(session_state.audio_transceiver_count == 1);
    DINOX_CHECK(session_state.video_transceiver_count == 1);
    DINOX_CHECK(session_state.local_audio_source_attached == 1);
    DINOX_CHECK(session_state.local_audio_track_attached == 1);
    DINOX_CHECK(session_state.local_audio_track_enabled == 1);
    DINOX_CHECK(session_state.local_video_source_attached == 1);
    DINOX_CHECK(session_state.local_video_track_attached == 1);
    DINOX_CHECK(session_state.local_video_track_enabled == 1);
    DINOX_CHECK(session_state.audio_device_capture_probe_frame_count == 0);
    DINOX_CHECK(session_state.audio_device_capture_probe_sample_count == 0);
    DINOX_CHECK(session_state.audio_device_capture_probe_peak_level == 0.0);
    DINOX_CHECK(session_state.local_dtmf_feedback_start_count == 0);
    DINOX_CHECK(session_state.local_dtmf_feedback_mix_call_count == 0);
    DINOX_CHECK(session_state.local_dtmf_feedback_mixed_frame_count == 0);
    DINOX_CHECK(session_state.local_dtmf_feedback_unsupported_format_count == 0);
    DINOX_CHECK(dinox_webrtc_context_play_test_tone(context, '5', 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_set_audio_device(context, 1, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.remote_audio_receiver_count == 0);
    DINOX_CHECK(session_state.remote_video_receiver_count == 0);
    DINOX_CHECK(session_state.remote_audio_sink_count == 0);
    DINOX_CHECK(session_state.remote_audio_sink_frame_count == 0);
    DINOX_CHECK(session_state.remote_audio_sink_sample_count == 0);
    DINOX_CHECK(session_state.remote_video_sink_count == 0);
    DINOX_CHECK(session_state.remote_video_sink_frame_count == 0);
    DINOX_CHECK(session_state.remote_video_sink_last_width == 0);
    DINOX_CHECK(session_state.remote_video_sink_last_height == 0);
    DINOX_CHECK(session_state.audio_device_initialized == 1);
    DINOX_CHECK(session_state.ice_server_count == 0);
    DINOX_CHECK(session_state.peer_connection_state == DINOX_WEBRTC_PEER_CONNECTION_STATE_NEW);
    DINOX_CHECK(session_state.ice_connection_state == DINOX_WEBRTC_ICE_CONNECTION_STATE_NEW);
    DINOX_CHECK(dinox_webrtc_session_set_local_audio_enabled(session, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.local_audio_track_enabled == 0);
    DINOX_CHECK(dinox_webrtc_session_set_local_audio_enabled(session, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.local_audio_track_enabled == 1);
    DINOX_CHECK(dinox_webrtc_session_set_local_video_enabled(session, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.local_video_track_enabled == 0);
    DINOX_CHECK(dinox_webrtc_session_set_local_video_enabled(session, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.local_video_track_enabled == 1);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(nullptr, '1', 250) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, 'x', 250) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, '1', 69) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, '1', 6001) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, '1', 250) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(session, 0, 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(session, 160, 0) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_start_video_capture(session, nullptr, 640, 480, 30) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_start_video_capture(session, "", 640, 480, 30) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_start_video_capture(session, "invalid", 0, 480, 30) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_start_video_capture(session, "invalid", 640, 480, 0) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    {
        const std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.local_video_frame_callback_count == 1);
        DINOX_CHECK(callback_state.last_local_video_frame_id == 1);
        DINOX_CHECK(callback_state.last_local_video_frame_width == 160);
        DINOX_CHECK(callback_state.last_local_video_frame_height == 120);
        DINOX_CHECK(callback_state.last_local_video_frame_stride >= 160 * 4);
    }
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(nullptr, '1', 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, 'x', 120) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, '1', 19) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, '1', 1001) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, '1', 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, 'a', 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &session_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(session_state.local_dtmf_feedback_start_count == 3);

    DinoXWebrtcSessionConfig audio_only_config = config;
    audio_only_config.video_enabled = 0;
    DinoXWebrtcSession* audio_only_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(context, &audio_only_config, &callbacks, &callback_state, &audio_only_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(audio_only_session != nullptr);
    DinoXWebrtcSessionState audio_only_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(audio_only_session, &audio_only_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(audio_only_state.audio_transceiver_count == 1);
    DINOX_CHECK(audio_only_state.video_transceiver_count == 0);
    DINOX_CHECK(audio_only_state.local_audio_source_attached == 1);
    DINOX_CHECK(audio_only_state.local_audio_track_attached == 1);
    DINOX_CHECK(audio_only_state.local_audio_track_enabled == 1);
    DINOX_CHECK(audio_only_state.local_video_source_attached == 0);
    DINOX_CHECK(audio_only_state.local_video_track_attached == 0);
    DINOX_CHECK(audio_only_state.local_video_track_enabled == 0);
    DINOX_CHECK(audio_only_state.audio_device_capture_probe_frame_count == 0);
    DINOX_CHECK(audio_only_state.audio_device_capture_probe_sample_count == 0);
    DINOX_CHECK(audio_only_state.audio_device_capture_probe_peak_level == 0.0);
    DINOX_CHECK(audio_only_state.remote_audio_receiver_count == 0);
    DINOX_CHECK(audio_only_state.remote_video_receiver_count == 0);
    DINOX_CHECK(audio_only_state.remote_audio_sink_count == 0);
    DINOX_CHECK(audio_only_state.remote_audio_sink_frame_count == 0);
    DINOX_CHECK(audio_only_state.remote_audio_sink_sample_count == 0);
    DINOX_CHECK(audio_only_state.remote_video_sink_count == 0);
    DINOX_CHECK(audio_only_state.remote_video_sink_frame_count == 0);
    DINOX_CHECK(audio_only_state.ice_server_count == 0);
    DINOX_CHECK(dinox_webrtc_session_set_local_video_enabled(audio_only_session, 0) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(audio_only_session, 160, 120) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_session_close(audio_only_session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(audio_only_session);

    DinoXWebrtcSessionConfig deferred_answer_config = config;
    deferred_answer_config.video_enabled = 0;
    deferred_answer_config.defer_audio_transceiver_until_answer = 1;
    DinoXWebrtcSession* deferred_answer_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(context, &deferred_answer_config, &callbacks, &callback_state, &deferred_answer_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(deferred_answer_session != nullptr);
    DinoXWebrtcSessionState deferred_answer_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(deferred_answer_session, &deferred_answer_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(deferred_answer_state.audio_transceiver_count == 0);
    DINOX_CHECK(deferred_answer_state.video_transceiver_count == 0);
    DINOX_CHECK(deferred_answer_state.local_audio_source_attached == 1);
    DINOX_CHECK(deferred_answer_state.local_audio_track_attached == 1);
    DINOX_CHECK(deferred_answer_state.local_audio_track_enabled == 1);
    DINOX_CHECK(dinox_webrtc_session_set_local_audio_enabled(deferred_answer_session, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_close(deferred_answer_session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(deferred_answer_session);

    DINOX_CHECK(dinox_webrtc_session_set_remote_description(session, DINOX_WEBRTC_SDP_TYPE_OFFER, "not valid sdp") == DINOX_WEBRTC_STATUS_PARSE_ERROR);
    DINOX_CHECK(dinox_webrtc_session_add_remote_ice_candidate(session, "0", -1, "candidate:1 1 udp 1 127.0.0.1 9 typ host") == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);

    {
        const std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.error_count == 1);
        DINOX_CHECK(callback_state.last_error == DINOX_WEBRTC_STATUS_PARSE_ERROR);
    }
    callback_state_reset_observations(&callback_state);

    DINOX_CHECK(dinox_webrtc_session_create_offer(session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_local_description(&callback_state));
    char offer_sdp[65536] = {};
    {
        const std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.error_count == 0);
        DINOX_CHECK(callback_state.local_description_count == 1);
        DINOX_CHECK(callback_state.last_type == DINOX_WEBRTC_SDP_TYPE_OFFER);
        DINOX_CHECK(std::strstr(callback_state.last_sdp, "v=0") != nullptr);
        DINOX_CHECK(std::strstr(callback_state.last_sdp, "m=audio") != nullptr);
        DINOX_CHECK(std::strstr(callback_state.last_sdp, "telephone-event") != nullptr);
        DINOX_CHECK(std::strstr(callback_state.last_sdp, "m=video") != nullptr);
        std::strncpy(offer_sdp, callback_state.last_sdp, sizeof(offer_sdp) - 1);
        offer_sdp[sizeof(offer_sdp) - 1] = '\0';
    }

    CallbackState answer_callback_state;
    callback_state_init(&answer_callback_state);
    DinoXWebrtcSession* answer_session = nullptr;
    DinoXWebrtcSessionConfig answer_config = config;
    answer_config.defer_audio_transceiver_until_answer = 1;
    answer_config.defer_video_transceiver_until_answer = 1;
    DINOX_CHECK(dinox_webrtc_session_new(context, &answer_config, &callbacks, &answer_callback_state, &answer_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(answer_session != nullptr);
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(answer_session, DINOX_WEBRTC_SDP_TYPE_OFFER, offer_sdp) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_remote_description_set(&answer_callback_state));
    {
        const std::lock_guard<std::mutex> lock(answer_callback_state.mutex);
        DINOX_CHECK(answer_callback_state.error_count == 0);
        DINOX_CHECK(answer_callback_state.remote_description_set_count == 1);
        DINOX_CHECK(answer_callback_state.last_remote_type == DINOX_WEBRTC_SDP_TYPE_OFFER);
    }
    DINOX_CHECK(dinox_webrtc_session_create_answer(answer_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_local_description(&answer_callback_state));
    char answer_sdp[65536] = {};
    {
        const std::lock_guard<std::mutex> lock(answer_callback_state.mutex);
        DINOX_CHECK(answer_callback_state.error_count == 0);
        DINOX_CHECK(answer_callback_state.local_description_count == 1);
        DINOX_CHECK(answer_callback_state.last_type == DINOX_WEBRTC_SDP_TYPE_ANSWER);
        DINOX_CHECK(std::strstr(answer_callback_state.last_sdp, "v=0") != nullptr);
        DINOX_CHECK(std::strstr(answer_callback_state.last_sdp, "m=audio") != nullptr);
        DINOX_CHECK(std::strstr(answer_callback_state.last_sdp, "telephone-event") != nullptr);
        DINOX_CHECK(std::strstr(answer_callback_state.last_sdp, "m=video") != nullptr);
        std::strncpy(answer_sdp, answer_callback_state.last_sdp, sizeof(answer_sdp) - 1);
        answer_sdp[sizeof(answer_sdp) - 1] = '\0';
    }
    callback_state_reset_observations(&callback_state);
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(session, DINOX_WEBRTC_SDP_TYPE_ANSWER, answer_sdp) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_remote_description_set(&callback_state));
    {
        const std::lock_guard<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.error_count == 0);
        DINOX_CHECK(callback_state.remote_description_set_count == 1);
        DINOX_CHECK(callback_state.last_remote_type == DINOX_WEBRTC_SDP_TYPE_ANSWER);
    }
    // This is deliberately the first operation after completing SDP/ICE that
    // can observe remote video.  A get_state() call must not be required to
    // attach the production video sink.
    DINOX_CHECK(wait_for_bidirectional_video_without_state_queries(
        session, &callback_state, answer_session, &answer_callback_state));

    DinoXWebrtcSessionState answer_remote_offer_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(answer_session, &answer_remote_offer_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(answer_remote_offer_state.remote_audio_receiver_count >= 1);
    DINOX_CHECK(answer_remote_offer_state.remote_audio_sink_count >= 1);
    DinoXWebrtcSessionState offer_remote_answer_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &offer_remote_answer_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(offer_remote_answer_state.remote_audio_receiver_count >= 1);
    DINOX_CHECK(offer_remote_answer_state.remote_audio_sink_count >= 1);

    DINOX_CHECK(wait_for_connected_pair(session, &callback_state, answer_session, &answer_callback_state));
    DinoXWebrtcSessionState offer_before_video = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &offer_before_video) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState answer_before_video = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(answer_session, &answer_before_video) == DINOX_WEBRTC_STATUS_OK);
    uint64_t offer_before_video_callback_count = 0;
    uint64_t answer_before_video_callback_count = 0;
    {
        const std::scoped_lock lock(callback_state.mutex, answer_callback_state.mutex);
        offer_before_video_callback_count = callback_state.video_frame_callback_count;
        answer_before_video_callback_count = answer_callback_state.video_frame_callback_count;
    }
    DINOX_CHECK(wait_for_remote_video_frame(
        session,
        answer_session,
        &answer_callback_state,
        answer_before_video.remote_video_sink_frame_count,
        answer_before_video_callback_count,
        160,
        120));
    DINOX_CHECK(wait_for_remote_video_frame(
        answer_session,
        session,
        &callback_state,
        offer_before_video.remote_video_sink_frame_count,
        offer_before_video_callback_count,
        176,
        144));
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, '5', 250) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(answer_session, '#', 250) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_send_dtmf(session, 'a', 250) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState offer_before_dtmf_feedback = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &offer_before_dtmf_feedback) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState answer_before_dtmf_feedback = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(answer_session, &answer_before_dtmf_feedback) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(session, '5', 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_play_local_dtmf_feedback(answer_session, '#', 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_local_dtmf_feedback_mixed(
        session,
        offer_before_dtmf_feedback.local_dtmf_feedback_mixed_frame_count));
    DINOX_CHECK(wait_for_local_dtmf_feedback_mixed(
        answer_session,
        answer_before_dtmf_feedback.local_dtmf_feedback_mixed_frame_count));

    DINOX_CHECK(dinox_webrtc_session_close(answer_session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(answer_session);

    DINOX_CHECK(dinox_webrtc_session_close(session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_close(session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(session);

    dinox_webrtc_video_pipeline_free(video_pipeline);

    dinox_webrtc_context_free(context);
    dinox_webrtc_context_free(nullptr);
    dinox_webrtc_session_free(nullptr);
    DINOX_CHECK(run_projected_muji_smoke() == 0);

    return 0;
}
