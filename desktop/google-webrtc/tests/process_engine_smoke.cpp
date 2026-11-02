#include "dinox_webrtc.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <sys/wait.h>
#endif

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "DINOX_CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

namespace {

bool process_smoke_debug_enabled() {
    const char* value = std::getenv("DINOX_WEBRTC_PROCESS_SMOKE_DEBUG");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

struct CallbackState {
    std::mutex mutex;
    std::condition_variable condition;
    bool offer_received = false;
    bool answer_received = false;
    bool remote_description_set = false;
    std::string sdp;
    struct IceCandidate {
        std::string mid;
        int mline = -1;
        std::string candidate;
    };
    std::vector<IceCandidate> ice_candidates;
    bool local_video_received = false;
    bool remote_video_received = false;
    int local_video_width = 0;
    int local_video_height = 0;
    int remote_video_width = 0;
    int remote_video_height = 0;
    unsigned int local_video_frames = 0;
    unsigned int remote_video_frames = 0;
    unsigned int errors = 0;
};

struct RecorderState {
    std::mutex mutex;
    std::condition_variable condition;
    unsigned int started = 0;
    unsigned int stopped = 0;
    unsigned int audio_frames = 0;
    unsigned int video_frames = 0;
    unsigned int errors = 0;
};

struct PipelineFreeState {
    std::mutex mutex;
    std::condition_variable condition;
    DinoXWebrtcVideoPipeline** owned_pipeline = nullptr;
    DinoXWebrtcVideoPipelineState last_state = {};
    bool callback_entered = false;
    bool callback_completed_free = false;
};

struct PipelineEffectState {
    std::mutex mutex;
    std::condition_variable condition;
    DinoXWebrtcVideoPipelineState state = {};
};

void on_pipeline_effect_state(
    DinoXWebrtcVideoPipeline*,
    const DinoXWebrtcVideoPipelineState* state,
    void* user_data) {
    auto* shared = static_cast<PipelineEffectState*>(user_data);
    std::lock_guard<std::mutex> lock(shared->mutex);
    if (state != nullptr) shared->state = *state;
    shared->condition.notify_all();
}

void on_pipeline_state_and_free(
    DinoXWebrtcVideoPipeline* pipeline,
    const DinoXWebrtcVideoPipelineState* state,
    void* user_data) {
    auto* callback_state = static_cast<PipelineFreeState*>(user_data);
    DinoXWebrtcVideoPipeline* to_free = nullptr;
    {
        std::lock_guard<std::mutex> lock(callback_state->mutex);
        callback_state->callback_entered = true;
        if (state != nullptr) callback_state->last_state = *state;
        if (callback_state->owned_pipeline != nullptr &&
                *callback_state->owned_pipeline == pipeline) {
            to_free = pipeline;
            *callback_state->owned_pipeline = nullptr;
        }
    }
    if (to_free != nullptr) dinox_webrtc_video_pipeline_free(to_free);
    {
        std::lock_guard<std::mutex> lock(callback_state->mutex);
        callback_state->callback_completed_free = true;
        callback_state->condition.notify_all();
    }
}

void on_local_description(
    DinoXWebrtcSession*,
    DinoXWebrtcSdpType type,
    const char* sdp,
    void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || sdp == nullptr) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->offer_received = type == DINOX_WEBRTC_SDP_TYPE_OFFER;
    state->answer_received = type == DINOX_WEBRTC_SDP_TYPE_ANSWER;
    state->sdp = sdp;
    if (process_smoke_debug_enabled()) {
        std::fprintf(
            stderr,
            "process smoke local description type=%d state=%p\n%s\n",
            static_cast<int>(type),
            static_cast<void*>(state),
            sdp);
    }
    state->condition.notify_all();
}

void on_remote_description_set(
    DinoXWebrtcSession*, DinoXWebrtcSdpType, void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->remote_description_set = true;
    state->condition.notify_all();
}

void on_ice_candidate(
    DinoXWebrtcSession*,
    const char* mid,
    int mline,
    const char* candidate,
    void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || mid == nullptr || candidate == nullptr) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->ice_candidates.push_back({mid, mline, candidate});
    if (process_smoke_debug_enabled()) {
        std::fprintf(
            stderr,
            "process smoke ICE state=%p mid=%s mline=%d candidate=%s\n",
            static_cast<void*>(state),
            mid,
            mline,
            candidate);
    }
    state->condition.notify_all();
}

void on_session_error(
    DinoXWebrtcSession*, DinoXWebrtcStatus, const char*, void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->errors;
    state->condition.notify_all();
}

void on_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* pixels,
    int width,
    int height,
    int stride,
    uint64_t,
    void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || pixels == nullptr || width <= 0 || height <= 0 || stride < width * 4) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->local_video_received = true;
    ++state->local_video_frames;
    state->local_video_width = width;
    state->local_video_height = height;
    state->condition.notify_all();
}

void on_remote_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* pixels,
    int width,
    int height,
    int stride,
    uint64_t,
    void* user_data) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (state == nullptr || pixels == nullptr || width <= 0 || height <= 0 || stride < width * 4) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    state->remote_video_received = true;
    ++state->remote_video_frames;
    state->remote_video_width = width;
    state->remote_video_height = height;
    state->condition.notify_all();
}

bool add_pending_candidates(
    CallbackState* source,
    size_t* next_index,
    DinoXWebrtcSession* destination) {
    while (true) {
        CallbackState::IceCandidate candidate;
        {
            std::lock_guard<std::mutex> lock(source->mutex);
            if (*next_index >= source->ice_candidates.size()) return true;
            candidate = source->ice_candidates[*next_index];
        }
        const DinoXWebrtcStatus status = dinox_webrtc_session_add_remote_ice_candidate(
                destination,
                candidate.mid.c_str(),
                candidate.mline,
                candidate.candidate.c_str());
        if (status != DINOX_WEBRTC_STATUS_OK) {
            std::fprintf(
                stderr,
                "process video smoke: add ICE candidate failed status=%d mid=%s mline=%d\n",
                static_cast<int>(status),
                candidate.mid.c_str(),
                candidate.mline);
            return false;
        }
        ++*next_index;
    }
}

bool wait_for_process_video_pair(
    DinoXWebrtcSession* offer_session,
    CallbackState* offer_state,
    DinoXWebrtcSession* answer_session,
    CallbackState* answer_state) {
    size_t next_offer_candidate = 0;
    size_t next_answer_candidate = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        if (!add_pending_candidates(offer_state, &next_offer_candidate, answer_session) ||
            !add_pending_candidates(answer_state, &next_answer_candidate, offer_session)) {
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
            if (offer_state->remote_video_received &&
                answer_state->remote_video_received &&
                offer_state->remote_video_width == 176 &&
                offer_state->remote_video_height == 144 &&
                answer_state->remote_video_width == 160 &&
                answer_state->remote_video_height == 120) {
                return true;
            }
            if (offer_state->errors != 0 || answer_state->errors != 0) return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    DinoXWebrtcSessionState offer_native_state = {};
    DinoXWebrtcSessionState answer_native_state = {};
    const DinoXWebrtcStatus offer_state_status =
        dinox_webrtc_session_get_state(offer_session, &offer_native_state);
    const DinoXWebrtcStatus answer_state_status =
        dinox_webrtc_session_get_state(answer_session, &answer_native_state);
    {
        const std::scoped_lock lock(offer_state->mutex, answer_state->mutex);
        std::fprintf(
            stderr,
            "process video smoke timeout: "
            "offer candidates=%zu local=%u/%dx%d remote=%u/%dx%d errors=%u; "
            "answer candidates=%zu local=%u/%dx%d remote=%u/%dx%d errors=%u\n",
            offer_state->ice_candidates.size(),
            offer_state->local_video_frames,
            offer_state->local_video_width,
            offer_state->local_video_height,
            offer_state->remote_video_frames,
            offer_state->remote_video_width,
            offer_state->remote_video_height,
            offer_state->errors,
            answer_state->ice_candidates.size(),
            answer_state->local_video_frames,
            answer_state->local_video_width,
            answer_state->local_video_height,
            answer_state->remote_video_frames,
            answer_state->remote_video_width,
            answer_state->remote_video_height,
            answer_state->errors);
        std::fprintf(
            stderr,
            "process video native state: "
            "offer status=%d pc=%d ice=%d local-track=%d remote-receiver=%d "
            "out-frames=%llu in-frames=%llu; "
            "answer status=%d pc=%d ice=%d local-track=%d remote-receiver=%d "
            "out-frames=%llu in-frames=%llu\n",
            static_cast<int>(offer_state_status),
            static_cast<int>(offer_native_state.peer_connection_state),
            static_cast<int>(offer_native_state.ice_connection_state),
            offer_native_state.local_video_track_attached,
            offer_native_state.remote_video_receiver_count,
            static_cast<unsigned long long>(offer_native_state.outbound_video_frames_sent),
            static_cast<unsigned long long>(offer_native_state.inbound_video_frames_received),
            static_cast<int>(answer_state_status),
            static_cast<int>(answer_native_state.peer_connection_state),
            static_cast<int>(answer_native_state.ice_connection_state),
            answer_native_state.local_video_track_attached,
            answer_native_state.remote_video_receiver_count,
            static_cast<unsigned long long>(answer_native_state.outbound_video_frames_sent),
            static_cast<unsigned long long>(answer_native_state.inbound_video_frames_received));
    }
    return false;
}

bool wait_for_process_remote_video_size(
    DinoXWebrtcSession* sender,
    CallbackState* receiver_state,
    int source_width,
    int source_height,
    int expected_width,
    int expected_height) {
    {
        std::lock_guard<std::mutex> lock(receiver_state->mutex);
        receiver_state->remote_video_received = false;
        receiver_state->remote_video_width = 0;
        receiver_state->remote_video_height = 0;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        if (dinox_webrtc_session_push_synthetic_video_frame(
                sender, source_width, source_height) !=
            DINOX_WEBRTC_STATUS_OK) {
            return false;
        }
        std::unique_lock<std::mutex> lock(receiver_state->mutex);
        if (receiver_state->condition.wait_for(
                lock,
                std::chrono::milliseconds(250),
                [&] {
                    return receiver_state->errors != 0 ||
                        (receiver_state->remote_video_received &&
                            receiver_state->remote_video_width == expected_width &&
                            receiver_state->remote_video_height == expected_height);
                })) {
            return receiver_state->errors == 0;
        }
    }
    return false;
}

bool no_waitable_or_running_child() {
#ifdef _WIN32
    return true;
#else
    int status = 0;
    errno = 0;
    return waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
#endif
}

void on_recorder_started(DinoXWebrtcMediaRecorder*, void* user_data) {
    auto* state = static_cast<RecorderState*>(user_data);
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->started;
    state->condition.notify_all();
}

void on_recorder_stopped(DinoXWebrtcMediaRecorder*, void* user_data) {
    auto* state = static_cast<RecorderState*>(user_data);
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->stopped;
    state->condition.notify_all();
}

void on_recorder_error(
    DinoXWebrtcMediaRecorder*, DinoXWebrtcStatus, const char*, void* user_data) {
    auto* state = static_cast<RecorderState*>(user_data);
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->errors;
    state->condition.notify_all();
}

void on_recorder_audio_frame(
    DinoXWebrtcMediaRecorder*, const uint8_t*, size_t byte_count,
    int sample_rate, int channels, int bytes_per_sample, uint64_t, void* user_data) {
    auto* state = static_cast<RecorderState*>(user_data);
    if (byte_count == 0 || sample_rate != 48000 || channels != 1 || bytes_per_sample != 2) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->audio_frames;
    state->condition.notify_all();
}

void on_recorder_video_frame(
    DinoXWebrtcMediaRecorder*, const uint8_t*, int width, int height,
    int stride, uint64_t, void* user_data) {
    auto* state = static_cast<RecorderState*>(user_data);
    if (width <= 0 || height <= 0 || stride < width * 4) return;
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->video_frames;
    state->condition.notify_all();
}

}  // namespace

int main() {
#ifdef _WIN32
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_INTERNAL_WORKER", "1") == 0);
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_ENABLE_TEST_FAULTS", "1") == 0);
    DINOX_CHECK(_putenv_s(
        "DINOX_WEBRTC_TEST_PIPELINE_DESTROY_HANG_LOGICAL_CALL_ID", "9002") == 0);
#else
    DINOX_CHECK(setenv("DINOX_WEBRTC_INTERNAL_WORKER", "1", 1) == 0);
    DINOX_CHECK(setenv("DINOX_WEBRTC_ENABLE_TEST_FAULTS", "1", 1) == 0);
    DINOX_CHECK(setenv(
        "DINOX_WEBRTC_TEST_PIPELINE_DESTROY_HANG_LOGICAL_CALL_ID", "9002", 1) == 0);
#endif
    // A user-controlled environment variable must not bypass the mandatory
    // external worker. Only the worker executable can enter internal mode via
    // the process-local bootstrap API.
    DinoXWebrtcContext* context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new_with_audio_device_mode(
        DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC,
        &context) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(context != nullptr);

    // Closing a session is an implicit detach in both the worker registry and
    // the process proxy.  This must not leave subscriber bookkeeping behind.
    DinoXWebrtcVideoPipelineCallbacks pipeline_callbacks =
        dinox_webrtc_video_pipeline_callbacks_default();
    DinoXWebrtcVideoPipeline* close_cleanup_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 9001, &pipeline_callbacks, nullptr, &close_cleanup_pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionConfig close_cleanup_config = dinox_webrtc_session_config_default();
    close_cleanup_config.audio_enabled = 1;
    close_cleanup_config.video_enabled = 0;
    close_cleanup_config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    close_cleanup_config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    DinoXWebrtcCallbacks close_cleanup_callbacks = dinox_webrtc_callbacks_default();
    DinoXWebrtcSession* close_cleanup_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &close_cleanup_config, &close_cleanup_callbacks, nullptr,
        &close_cleanup_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        close_cleanup_pipeline, close_cleanup_session, 1) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipelineState close_cleanup_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        close_cleanup_pipeline, &close_cleanup_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_cleanup_state.subscriber_count == 1);
    DINOX_CHECK(dinox_webrtc_session_close(close_cleanup_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        close_cleanup_pipeline, &close_cleanup_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(close_cleanup_state.subscriber_count == 0);
    DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
        close_cleanup_pipeline, close_cleanup_session) == DINOX_WEBRTC_STATUS_NOT_READY);
    dinox_webrtc_session_free(close_cleanup_session);
    dinox_webrtc_video_pipeline_free(close_cleanup_pipeline);

    // A state callback is allowed to release its own pipeline.  The destroy
    // reply cannot be awaited on the IPC reader thread itself.  Its one
    // Context-bound watchdog must nevertheless terminate a worker whose
    // processor teardown never returns and release all retained fences.
    CallbackState pipeline_timeout_state;
    DinoXWebrtcCallbacks pipeline_timeout_callbacks = dinox_webrtc_callbacks_default();
    pipeline_timeout_callbacks.on_error = on_session_error;
    DinoXWebrtcSessionConfig pipeline_timeout_config = dinox_webrtc_session_config_default();
    pipeline_timeout_config.audio_enabled = 0;
    pipeline_timeout_config.video_enabled = 1;
    pipeline_timeout_config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    pipeline_timeout_config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    DinoXWebrtcSession* pipeline_timeout_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &pipeline_timeout_config, &pipeline_timeout_callbacks,
        &pipeline_timeout_state, &pipeline_timeout_session) == DINOX_WEBRTC_STATUS_OK);
    PipelineFreeState pipeline_free_state;
    DinoXWebrtcVideoPipeline* callback_owned_pipeline = nullptr;
    pipeline_free_state.owned_pipeline = &callback_owned_pipeline;
    pipeline_callbacks.on_state_changed = on_pipeline_state_and_free;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 9002, &pipeline_callbacks, &pipeline_free_state,
        &callback_owned_pipeline) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        callback_owned_pipeline, pipeline_timeout_session, 1) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoEffectConfig warm_tone = dinox_webrtc_video_effect_config_default();
    warm_tone.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    uint64_t effect_revision = 0;
    const auto pipeline_timeout_start = std::chrono::steady_clock::now();
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        callback_owned_pipeline, &warm_tone, &effect_revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(effect_revision == 1);
    {
        std::unique_lock<std::mutex> lock(pipeline_free_state.mutex);
        DINOX_CHECK(pipeline_free_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] {
                return pipeline_free_state.callback_completed_free;
            }));
        DINOX_CHECK(pipeline_free_state.callback_entered);
        DINOX_CHECK(pipeline_free_state.last_state.application_state ==
            DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED);
        DINOX_CHECK(pipeline_free_state.last_state.effect_type ==
            DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE);
        DINOX_CHECK(pipeline_free_state.last_state.applied_revision == effect_revision);
        DINOX_CHECK(callback_owned_pipeline == nullptr);
    }
    {
        std::unique_lock<std::mutex> lock(pipeline_timeout_state.mutex);
        DINOX_CHECK(pipeline_timeout_state.condition.wait_for(
            lock, std::chrono::seconds(8), [&] {
                return pipeline_timeout_state.errors == 1;
            }));
    }
    const auto pipeline_timeout_elapsed =
        std::chrono::steady_clock::now() - pipeline_timeout_start;
    DINOX_CHECK(pipeline_timeout_elapsed >= std::chrono::seconds(4));
    DINOX_CHECK(pipeline_timeout_elapsed < std::chrono::seconds(8));
    DINOX_CHECK(no_waitable_or_running_child());
    dinox_webrtc_session_free(pipeline_timeout_session);
#ifdef _WIN32
    DINOX_CHECK(_putenv_s(
        "DINOX_WEBRTC_TEST_PIPELINE_DESTROY_HANG_LOGICAL_CALL_ID", "") == 0);
#else
    DINOX_CHECK(unsetenv(
        "DINOX_WEBRTC_TEST_PIPELINE_DESTROY_HANG_LOGICAL_CALL_ID") == 0);
#endif

    // The attachment test intentionally creates and closes a native session;
    // use a fresh isolated worker for the pre-existing media/audio smoke so a
    // stopped platform ADM cannot influence unrelated coverage.
    dinox_webrtc_context_free(context);
    context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new_with_audio_device_mode(
        DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC,
        &context) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(context != nullptr);

    std::vector<uint8_t> media_audio_pcm(960 * 2, 0);
    for (size_t index = 0; index < media_audio_pcm.size() / 2; ++index) {
        const int16_t sample = (index % 48) < 24 ? 6000 : -6000;
        media_audio_pcm[index * 2] = static_cast<uint8_t>(sample & 0xff);
        media_audio_pcm[index * 2 + 1] = static_cast<uint8_t>((sample >> 8) & 0xff);
    }
    unsigned int media_audio_queued_ms = 0;
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        context, 48000, 1, 2) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        media_audio_pcm.data(),
        media_audio_pcm.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(media_audio_queued_ms > 0 && media_audio_queued_ms <= 20);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_flush(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        media_audio_pcm.data(),
        media_audio_pcm.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_finish(
        context, &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(media_audio_queued_ms <= 20);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(context) ==
        DINOX_WEBRTC_STATUS_OK);

    std::vector<uint8_t> one_second_media_audio_pcm(48000 * 2, 0);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_start(
        context, 48000, 1, 2) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_set_paused(
        context, 1) == DINOX_WEBRTC_STATUS_OK);
    for (unsigned int second = 0; second < 6; ++second) {
        DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
            context,
            one_second_media_audio_pcm.data(),
            one_second_media_audio_pcm.size(),
            &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(media_audio_queued_ms == (second + 1) * 1000);
    }
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_push(
        context,
        one_second_media_audio_pcm.data(),
        one_second_media_audio_pcm.size(),
        &media_audio_queued_ms) == DINOX_WEBRTC_STATUS_NOT_READY);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_flush(context) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_media_audio_playout_stop(context) ==
        DINOX_WEBRTC_STATUS_OK);

    CallbackState callback_state;
    DinoXWebrtcCallbacks callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_description = on_local_description;
    DinoXWebrtcSessionConfig config = dinox_webrtc_session_config_default();
    config.audio_enabled = 1;
    config.video_enabled = 0;
    config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    DinoXWebrtcSession* session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context,
        &config,
        &callbacks,
        &callback_state,
        &session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_create_offer(session) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(callback_state.mutex);
        DINOX_CHECK(callback_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return callback_state.offer_received; }));
        DINOX_CHECK(callback_state.sdp.find("m=audio") != std::string::npos);
        DINOX_CHECK(callback_state.sdp.find("m=video") == std::string::npos);
    }
    DINOX_CHECK(dinox_webrtc_session_close(session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(session);

    CallbackState low_bandwidth_state;
    callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_description = on_local_description;
    config = dinox_webrtc_session_config_default();
    config.video_enabled = 0;
    config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    config.network_policy = DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G;
    session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &config, &callbacks, &low_bandwidth_state, &session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_create_offer(session) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(low_bandwidth_state.mutex);
        DINOX_CHECK(low_bandwidth_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] { return low_bandwidth_state.offer_received; }));
        DINOX_CHECK(low_bandwidth_state.sdp.find("m=video") == std::string::npos);
    }
    DinoXWebrtcSessionState low_bandwidth_native_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &low_bandwidth_native_state) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(low_bandwidth_native_state.network_policy ==
        DINOX_WEBRTC_NETWORK_POLICY_LOW_BANDWIDTH_2G);
    DINOX_CHECK(low_bandwidth_native_state.audio_sender_policy_applied == 1);
    DINOX_CHECK(low_bandwidth_native_state.audio_sender_bitrate_cap_bps == 16000);
    DINOX_CHECK(low_bandwidth_native_state.audio_sender_adaptive_ptime == 1);
    dinox_webrtc_session_free(session);

    config.video_enabled = 1;
    DinoXWebrtcSession* invalid_low_bandwidth_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &config, &callbacks, &low_bandwidth_state, &invalid_low_bandwidth_session) ==
        DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(invalid_low_bandwidth_session == nullptr);

    // A recorder that already reached IDLE must not receive a misleading
    // recording error when a later active operation kills the shared worker.
    DinoXWebrtcMediaRecorderCallbacks completed_recorder_callbacks =
        dinox_webrtc_media_recorder_callbacks_default();
    completed_recorder_callbacks.on_started = on_recorder_started;
    completed_recorder_callbacks.on_stopped = on_recorder_stopped;
    completed_recorder_callbacks.on_error = on_recorder_error;
    completed_recorder_callbacks.on_audio_frame = on_recorder_audio_frame;
    DinoXWebrtcMediaRecorderConfig completed_recorder_config =
        dinox_webrtc_media_recorder_config_default();
    completed_recorder_config.output_path =
        "/tmp/dinox-webrtc-process-completed-before-failure.m4a";
    RecorderState completed_recorder_state;
    DinoXWebrtcMediaRecorder* completed_recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context,
        &completed_recorder_config,
        &completed_recorder_callbacks,
        &completed_recorder_state,
        &completed_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(completed_recorder) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(
        completed_recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_stop(completed_recorder) ==
        DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(completed_recorder_state.mutex);
        DINOX_CHECK(completed_recorder_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] {
                return completed_recorder_state.stopped == 1;
            }));
    }

    CallbackState failure_state;
    callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_error = on_session_error;
    config = dinox_webrtc_session_config_default();
    config.video_enabled = 0;
    session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &config, &callbacks, &failure_state, &session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_context_inject_worker_failure_for_test(context, 1) ==
        DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
    {
        std::unique_lock<std::mutex> lock(failure_state.mutex);
        DINOX_CHECK(failure_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] { return failure_state.errors == 1; }));
    }
    DINOX_CHECK(no_waitable_or_running_child());
    dinox_webrtc_session_free(session);

    CallbackState recovery_state;
    callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_description = on_local_description;
    callbacks.on_error = on_session_error;
    session = nullptr;
#ifdef _WIN32
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_TEST_STATE_DELAY_MS", "750") == 0);
#else
    DINOX_CHECK(setenv("DINOX_WEBRTC_TEST_STATE_DELAY_MS", "750", 1) == 0);
#endif
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &config, &callbacks, &recovery_state, &session) == DINOX_WEBRTC_STATUS_OK);
    // Creating the recovery session joins the failed worker's reader thread.
    // At this point fail_active() has necessarily processed every recorder, so
    // this assertion cannot race the completed-recorder callback anymore.
    {
        std::lock_guard<std::mutex> lock(completed_recorder_state.mutex);
        DINOX_CHECK(completed_recorder_state.errors == 0);
    }
    dinox_webrtc_media_recorder_free(completed_recorder);
#ifdef _WIN32
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_TEST_STATE_DELAY_MS", "") == 0);
#else
    DINOX_CHECK(unsetenv("DINOX_WEBRTC_TEST_STATE_DELAY_MS") == 0);
#endif
    DINOX_CHECK(dinox_webrtc_session_create_offer(session) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(recovery_state.mutex);
        DINOX_CHECK(recovery_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] { return recovery_state.offer_received; }));
    }
    DinoXWebrtcSessionState delayed_diagnostics_state = {};
    const auto diagnostics_start = std::chrono::steady_clock::now();
    DINOX_CHECK(dinox_webrtc_session_get_state(session, &delayed_diagnostics_state) ==
        DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
    const auto diagnostics_elapsed = std::chrono::steady_clock::now() - diagnostics_start;
    DINOX_CHECK(diagnostics_elapsed >= std::chrono::milliseconds(400));
    DINOX_CHECK(diagnostics_elapsed < std::chrono::seconds(2));
    // The delayed diagnostics reply arrives after the non-fatal 500 ms client
    // deadline.  Once the worker loop continues, an ordinary request must
    // still succeed and the active call must not receive an error callback.
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    int delayed_diagnostics_video_devices = -1;
    DINOX_CHECK(dinox_webrtc_context_get_video_device_count(
        context, &delayed_diagnostics_video_devices) == DINOX_WEBRTC_STATUS_OK);
    {
        std::lock_guard<std::mutex> lock(recovery_state.mutex);
        DINOX_CHECK(recovery_state.errors == 0);
    }
    std::atomic<bool> hang_request_started{false};
    DinoXWebrtcStatus hang_status = DINOX_WEBRTC_STATUS_OK;
    std::thread hang_request([&] {
        hang_request_started.store(true);
        hang_status = dinox_webrtc_context_inject_worker_failure_for_test(context, 2);
    });
    while (!hang_request_started.load()) std::this_thread::yield();
    // Submit the one-way command while the fault-injection request still owns
    // its 100 ms watchdog window. Sleeping for exactly the timeout made this
    // assertion race the watchdog and intermittently observe NOT_READY after
    // the worker had already been terminated.
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const auto nonblocking_start = std::chrono::steady_clock::now();
    const DinoXWebrtcStatus queued_offer_status = dinox_webrtc_session_create_offer(session);
    const auto nonblocking_elapsed = std::chrono::steady_clock::now() - nonblocking_start;
    hang_request.join();
    DINOX_CHECK(queued_offer_status == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(nonblocking_elapsed < std::chrono::milliseconds(250));
    DINOX_CHECK(hang_status == DINOX_WEBRTC_STATUS_INTERNAL_ERROR);
    {
        std::unique_lock<std::mutex> lock(recovery_state.mutex);
        DINOX_CHECK(recovery_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] { return recovery_state.errors == 1; }));
    }
    DINOX_CHECK(no_waitable_or_running_child());
    dinox_webrtc_session_free(session);

    CallbackState video_state;
    callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_video_frame = on_local_video_frame;
    config = dinox_webrtc_session_config_default();
    config.audio_enabled = 0;
    config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    config.video_enabled = 1;
    session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &config, &callbacks, &video_state, &session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(session, 320, 180) ==
        DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(video_state.mutex);
        DINOX_CHECK(video_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return video_state.local_video_received; }));
        DINOX_CHECK(
            video_state.local_video_width == 320 &&
            video_state.local_video_height == 180);
    }
    dinox_webrtc_session_free(session);

    // Public process API -> IPC -> worker -> native pipeline: one synthetic
    // capture frame must feed four video senders, while the shared-memory
    // local-preview ring publishes it exactly once for the logical call.
    DinoXWebrtcVideoEffectCapabilities fanout_capabilities = {};
    DINOX_CHECK(dinox_webrtc_context_get_video_effect_capabilities(
        context, &fanout_capabilities) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_capabilities.shared_pipeline_supported == 1);
    DinoXWebrtcVideoPipelineCallbacks fanout_pipeline_callbacks =
        dinox_webrtc_video_pipeline_callbacks_default();
    PipelineEffectState fanout_effect_state;
    fanout_pipeline_callbacks.on_state_changed = on_pipeline_effect_state;
    DinoXWebrtcVideoPipeline* fanout_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 9100, &fanout_pipeline_callbacks, &fanout_effect_state, &fanout_pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    std::array<CallbackState, 4> fanout_callback_states;
    std::array<DinoXWebrtcSession*, 4> fanout_sessions = {};
    DinoXWebrtcCallbacks fanout_callbacks = dinox_webrtc_callbacks_default();
    fanout_callbacks.on_error = on_session_error;
    fanout_callbacks.on_local_video_frame = on_local_video_frame;
    DinoXWebrtcSessionConfig fanout_config = dinox_webrtc_session_config_default();
    fanout_config.audio_enabled = 0;
    fanout_config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    fanout_config.video_enabled = 1;
    fanout_config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DINOX_CHECK(dinox_webrtc_session_new(
            context,
            &fanout_config,
            &fanout_callbacks,
            &fanout_callback_states[i],
            &fanout_sessions[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
            fanout_pipeline, fanout_sessions[i], i == 0 ? 1 : 0) ==
            DINOX_WEBRTC_STATUS_OK);
    }
    DinoXWebrtcVideoPipelineState fanout_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        fanout_pipeline, &fanout_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_pipeline_state.subscriber_count == 4);
    DINOX_CHECK(fanout_pipeline_state.preview_subscriber_id != 0);

    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        fanout_sessions[0], 320, 180) == DINOX_WEBRTC_STATUS_OK);
    std::array<DinoXWebrtcSessionState, 4> fanout_native_states = {};
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &fanout_native_states[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(fanout_native_states[i].local_video_source_frame_count == 1);
        DINOX_CHECK(fanout_native_states[i].local_video_source_last_width == 320);
        DINOX_CHECK(fanout_native_states[i].local_video_source_last_height == 180);
    }
    {
        std::unique_lock<std::mutex> lock(fanout_callback_states[0].mutex);
        DINOX_CHECK(fanout_callback_states[0].condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return fanout_callback_states[0].local_video_frames == 1; }));
        DINOX_CHECK(fanout_callback_states[0].local_video_width == 320);
        DINOX_CHECK(fanout_callback_states[0].local_video_height == 180);
    }
    for (size_t i = 1; i < fanout_callback_states.size(); ++i) {
        std::lock_guard<std::mutex> lock(fanout_callback_states[i].mutex);
        DINOX_CHECK(fanout_callback_states[i].local_video_frames == 0);
        DINOX_CHECK(fanout_callback_states[i].errors == 0);
    }

    // Four peers share one transform, one bounded pool and exactly one local
    // preview. The complete config must also reach all four native sources.
    DinoXWebrtcVideoEffectConfig fanout_effect = dinox_webrtc_video_effect_config_default();
    fanout_effect.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE;
    fanout_effect.brightness = 10;
    fanout_effect.contrast = 20;
    fanout_effect.saturation = -20;
    fanout_effect.sharpness = 25;
    uint64_t fanout_effect_revision = 0;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        fanout_pipeline, &fanout_effect, &fanout_effect_revision) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(fanout_effect_state.mutex);
        DINOX_CHECK(fanout_effect_state.condition.wait_for(lock, std::chrono::seconds(5), [&] {
            return fanout_effect_state.state.application_state ==
                    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                fanout_effect_state.state.applied_revision == fanout_effect_revision;
        }));
        DINOX_CHECK(fanout_effect_state.state.sharpness == 25 &&
            fanout_effect_state.state.brightness == 10 &&
            fanout_effect_state.state.contrast == 20 &&
            fanout_effect_state.state.saturation == -20);
    }
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        fanout_sessions[0], 160, 120) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(fanout_callback_states[0].mutex);
        DINOX_CHECK(fanout_callback_states[0].condition.wait_for(
            lock, std::chrono::seconds(5), [&] {
                return fanout_callback_states[0].local_video_frames == 2;
            }));
    }
    DinoXWebrtcVideoEffectDiagnostics fanout_effect_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        fanout_pipeline, &fanout_effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_effect_diagnostics.subscriber_count == 4 &&
        fanout_effect_diagnostics.captured == 1 && fanout_effect_diagnostics.processed == 1 &&
        fanout_effect_diagnostics.frame_copy_count == 1 &&
        fanout_effect_diagnostics.effect_thread_count == 1);
    fanout_effect = dinox_webrtc_video_effect_config_default();
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        fanout_pipeline, &fanout_effect, &fanout_effect_revision) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(fanout_effect_state.mutex);
        DINOX_CHECK(fanout_effect_state.condition.wait_for(lock, std::chrono::seconds(5), [&] {
            return fanout_effect_state.state.application_state ==
                    DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                fanout_effect_state.state.applied_revision == fanout_effect_revision;
        }));
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        fanout_pipeline, &fanout_effect_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_effect_diagnostics.effect_thread_count == 0 &&
        fanout_effect_diagnostics.effect_owned_allocated_bytes == 0);
    // Off crosses the publication gate and waits for the preceding processed
    // frame's entire fan-out. The preview callback alone is not that barrier.
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &fanout_native_states[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(fanout_native_states[i].local_video_source_frame_count == 2 &&
            fanout_native_states[i].local_video_source_last_width == 160 &&
            fanout_native_states[i].local_video_source_last_height == 120);
    }
    for (size_t i = 1; i < fanout_callback_states.size(); ++i) {
        std::lock_guard<std::mutex> lock(fanout_callback_states[i].mutex);
        DINOX_CHECK(fanout_callback_states[i].local_video_frames == 0);
    }

    // Session close is an implicit, ordered detach across both proxy and
    // worker. It must not starve or invalidate the remaining video sources.
    DINOX_CHECK(dinox_webrtc_session_close(fanout_sessions[2]) ==
        DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(fanout_sessions[2]);
    fanout_sessions[2] = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        fanout_pipeline, &fanout_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(fanout_pipeline_state.subscriber_count == 3);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        fanout_sessions[0], 640, 360) == DINOX_WEBRTC_STATUS_OK);
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        if (fanout_sessions[i] == nullptr) continue;
        DINOX_CHECK(dinox_webrtc_session_get_state(
            fanout_sessions[i], &fanout_native_states[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(fanout_native_states[i].local_video_source_frame_count == 3);
        DINOX_CHECK(fanout_native_states[i].local_video_source_last_width == 640);
        DINOX_CHECK(fanout_native_states[i].local_video_source_last_height == 360);
    }
    for (size_t i = 0; i < fanout_sessions.size(); ++i) {
        if (fanout_sessions[i] == nullptr) continue;
        DINOX_CHECK(dinox_webrtc_video_pipeline_detach_session(
            fanout_pipeline, fanout_sessions[i]) == DINOX_WEBRTC_STATUS_OK);
        DINOX_CHECK(dinox_webrtc_session_close(fanout_sessions[i]) ==
            DINOX_WEBRTC_STATUS_OK);
        dinox_webrtc_session_free(fanout_sessions[i]);
    }
    dinox_webrtc_video_pipeline_free(fanout_pipeline);

    // Production regression: remote video must cross the external worker and
    // shared ring immediately after SDP/ICE setup.  No get_state() call is
    // allowed before the first received frames; diagnostics must never be the
    // operation that installs a required media sink.
    CallbackState process_offer_state;
    CallbackState process_answer_state;
    callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_description = on_local_description;
    callbacks.on_remote_description_set = on_remote_description_set;
    callbacks.on_ice_candidate = on_ice_candidate;
    callbacks.on_error = on_session_error;
    callbacks.on_video_frame = on_remote_video_frame;
    config = dinox_webrtc_session_config_default();
    config.audio_enabled = 0;
    config.audio_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    config.video_enabled = 1;
    config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_SEND_RECV;
    DinoXWebrtcSession* process_offer_session = nullptr;
    DinoXWebrtcSession* process_answer_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context,
        &config,
        &callbacks,
        &process_offer_state,
        &process_offer_session) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionConfig process_answer_config = config;
    process_answer_config.defer_video_transceiver_until_answer = 1;
    DINOX_CHECK(dinox_webrtc_session_new(
        context,
        &process_answer_config,
        &callbacks,
        &process_answer_state,
        &process_answer_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_create_offer(process_offer_session) == DINOX_WEBRTC_STATUS_OK);
    std::string process_offer_sdp;
    {
        std::unique_lock<std::mutex> lock(process_offer_state.mutex);
        DINOX_CHECK(process_offer_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return process_offer_state.offer_received || process_offer_state.errors != 0; }));
        DINOX_CHECK(process_offer_state.offer_received && process_offer_state.errors == 0);
        process_offer_sdp = process_offer_state.sdp;
    }
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(
        process_answer_session,
        DINOX_WEBRTC_SDP_TYPE_OFFER,
        process_offer_sdp.c_str()) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(process_answer_state.mutex);
        DINOX_CHECK(process_answer_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return process_answer_state.remote_description_set || process_answer_state.errors != 0; }));
        DINOX_CHECK(process_answer_state.remote_description_set && process_answer_state.errors == 0);
    }
    DINOX_CHECK(dinox_webrtc_session_create_answer(process_answer_session) == DINOX_WEBRTC_STATUS_OK);
    std::string process_answer_sdp;
    {
        std::unique_lock<std::mutex> lock(process_answer_state.mutex);
        DINOX_CHECK(process_answer_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return process_answer_state.answer_received || process_answer_state.errors != 0; }));
        DINOX_CHECK(process_answer_state.answer_received && process_answer_state.errors == 0);
        process_answer_sdp = process_answer_state.sdp;
    }
    DINOX_CHECK(dinox_webrtc_session_set_remote_description(
        process_offer_session,
        DINOX_WEBRTC_SDP_TYPE_ANSWER,
        process_answer_sdp.c_str()) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(process_offer_state.mutex);
        DINOX_CHECK(process_offer_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return process_offer_state.remote_description_set || process_offer_state.errors != 0; }));
        DINOX_CHECK(process_offer_state.remote_description_set && process_offer_state.errors == 0);
    }
    DINOX_CHECK(wait_for_process_video_pair(
        process_offer_session,
        &process_offer_state,
        process_answer_session,
        &process_answer_state));
    DINOX_CHECK(wait_for_process_remote_video_size(
        process_offer_session,
        &process_answer_state,
        1344,
        1792,
        480,
        640));
    dinox_webrtc_session_free(process_answer_session);
    dinox_webrtc_session_free(process_offer_session);

    DinoXWebrtcMediaRecorderCallbacks recorder_callbacks =
        dinox_webrtc_media_recorder_callbacks_default();
    recorder_callbacks.on_started = on_recorder_started;
    recorder_callbacks.on_stopped = on_recorder_stopped;
    recorder_callbacks.on_audio_frame = on_recorder_audio_frame;
    recorder_callbacks.on_video_frame = on_recorder_video_frame;
    DinoXWebrtcMediaRecorderConfig recorder_config = dinox_webrtc_media_recorder_config_default();
    recorder_config.output_path = "/tmp/dinox-webrtc-process-engine.m4a";
    RecorderState recorder_state;
    DinoXWebrtcMediaRecorder* recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context, &recorder_config, &recorder_callbacks, &recorder_state, &recorder) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_stop(recorder) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(recorder_state.mutex);
        DINOX_CHECK(recorder_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] {
                return recorder_state.started == 1 && recorder_state.stopped == 1 &&
                    recorder_state.audio_frames >= 2;
            }));
    }
    dinox_webrtc_media_recorder_free(recorder);

    recorder_config.kind = DINOX_WEBRTC_MEDIA_RECORDER_KIND_VIDEO;
    recorder_config.output_path = "/tmp/dinox-webrtc-process-engine.mp4";
    recorder_config.mime_type = "video/mp4";
    RecorderState video_recorder_state;
    recorder = nullptr;
    DINOX_CHECK(dinox_webrtc_media_recorder_new(
        context, &recorder_config, &recorder_callbacks, &video_recorder_state, &recorder) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_start(recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_push_synthetic_frame(recorder) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_media_recorder_stop(recorder) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(video_recorder_state.mutex);
        DINOX_CHECK(video_recorder_state.condition.wait_for(
            lock, std::chrono::seconds(5), [&] {
                return video_recorder_state.started == 1 && video_recorder_state.stopped == 1 &&
                    video_recorder_state.video_frames >= 2;
            }));
    }
    dinox_webrtc_media_recorder_free(recorder);
    dinox_webrtc_context_free(context);

    // DinoX retires the isolated media worker after the final call because
    // M150's Linux platform ADM may not restart after a complete stop.  Prove
    // that a fresh worker/context can immediately create the next audio call.
    DinoXWebrtcContext* restarted_context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new_with_audio_device_mode(
        DINOX_WEBRTC_AUDIO_DEVICE_SYNTHETIC,
        &restarted_context) == DINOX_WEBRTC_STATUS_OK);
    CallbackState restarted_state;
    DinoXWebrtcCallbacks restarted_callbacks = dinox_webrtc_callbacks_default();
    restarted_callbacks.on_local_description = on_local_description;
    restarted_callbacks.on_error = on_session_error;
    DinoXWebrtcSessionConfig restarted_config = dinox_webrtc_session_config_default();
    restarted_config.video_enabled = 0;
    restarted_config.video_direction = DINOX_WEBRTC_MEDIA_DIRECTION_INACTIVE;
    DinoXWebrtcSession* restarted_session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        restarted_context,
        &restarted_config,
        &restarted_callbacks,
        &restarted_state,
        &restarted_session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_create_offer(restarted_session) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(restarted_state.mutex);
        DINOX_CHECK(restarted_state.condition.wait_for(
            lock,
            std::chrono::seconds(5),
            [&] { return restarted_state.offer_received || restarted_state.errors != 0; }));
        DINOX_CHECK(restarted_state.offer_received && restarted_state.errors == 0);
        DINOX_CHECK(restarted_state.sdp.find("m=audio") != std::string::npos);
        DINOX_CHECK(restarted_state.sdp.find("m=video") == std::string::npos);
    }
    dinox_webrtc_session_free(restarted_session);
    dinox_webrtc_context_free(restarted_context);
    return 0;
}
