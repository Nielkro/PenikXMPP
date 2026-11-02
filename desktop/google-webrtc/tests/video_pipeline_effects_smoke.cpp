#include "dinox_webrtc.h"

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>
#include <utility>

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "check failed: %s:%d: %s\n", \
                __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

namespace {

struct State {
    std::mutex mutex;
    std::condition_variable changed;
    uint64_t pipeline_callback_count = 0;
    uint64_t preview_count = 0;
    uint64_t session_error_count = 0;
    DinoXWebrtcStatus last_session_error = DINOX_WEBRTC_STATUS_OK;
    DinoXWebrtcVideoPipelineState pipeline_state = {};
    bool free_pipeline_on_next_applied = false;
    bool callback_free_returned = false;
};

void on_pipeline_state(
    DinoXWebrtcVideoPipeline* pipeline,
    const DinoXWebrtcVideoPipelineState* state,
    void* user_data) {
    auto* shared = static_cast<State*>(user_data);
    bool free_pipeline = false;
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        if (state != nullptr) shared->pipeline_state = *state;
        shared->pipeline_callback_count++;
        if (state != nullptr &&
                state->application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
                shared->free_pipeline_on_next_applied) {
            shared->free_pipeline_on_next_applied = false;
            free_pipeline = true;
        }
        shared->changed.notify_all();
    }
    if (free_pipeline) {
        // This callback runs on the IPC reader thread.  Teardown must arm an
        // asynchronous reply barrier rather than synchronously wait on itself.
        dinox_webrtc_video_pipeline_free(pipeline);
        std::lock_guard<std::mutex> lock(shared->mutex);
        shared->callback_free_returned = true;
        shared->changed.notify_all();
    }
}

void on_local_video_frame(
    DinoXWebrtcSession*,
    const uint8_t* bgra,
    int width,
    int height,
    int stride,
    uint64_t,
    void* user_data) {
    if (bgra == nullptr || width <= 0 || height <= 0 || stride < width * 4) return;
    auto* shared = static_cast<State*>(user_data);
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->preview_count++;
    shared->changed.notify_all();
}

void on_session_error(
    DinoXWebrtcSession*,
    DinoXWebrtcStatus status,
    const char*,
    void* user_data) {
    auto* shared = static_cast<State*>(user_data);
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->session_error_count++;
    shared->last_session_error = status;
    shared->changed.notify_all();
}

bool wait_for_pipeline(State* state, uint64_t revision, DinoXWebrtcVideoEffectType effect) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(2), [&] {
        return state->pipeline_state.application_state ==
                DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED &&
            state->pipeline_state.applied_revision == revision &&
            state->pipeline_state.effect_type == effect;
    });
}

bool wait_for_pipeline_application(
    State* state,
    uint64_t revision,
    DinoXWebrtcVideoEffectApplicationState application) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(2), [&] {
        return state->pipeline_state.application_state == application &&
            state->pipeline_state.accepted_revision == revision;
    });
}

bool wait_for_preview(State* state, uint64_t minimum) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(2), [&] {
        return state->preview_count >= minimum;
    });
}

bool wait_for_callback_free(State* state) {
    std::unique_lock<std::mutex> lock(state->mutex);
    return state->changed.wait_for(lock, std::chrono::seconds(2), [&] {
        return state->callback_free_returned;
    });
}

}  // namespace

int main() {
    State state;
    DinoXWebrtcContext* context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new(&context) == DINOX_WEBRTC_STATUS_OK);

    DinoXWebrtcSessionConfig session_config = dinox_webrtc_session_config_default();
    DinoXWebrtcCallbacks session_callbacks = dinox_webrtc_callbacks_default();
    session_callbacks.on_error = on_session_error;
    session_callbacks.on_local_video_frame = on_local_video_frame;
    DinoXWebrtcSession* session = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        context, &session_config, &session_callbacks, &state, &session) ==
        DINOX_WEBRTC_STATUS_OK);

    DinoXWebrtcVideoPipelineCallbacks pipeline_callbacks =
        dinox_webrtc_video_pipeline_callbacks_default();
    pipeline_callbacks.on_state_changed = on_pipeline_state;
    DinoXWebrtcVideoPipeline* pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 9001, &pipeline_callbacks, &state, &pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        pipeline, session, 1) == DINOX_WEBRTC_STATUS_OK);

    // Stop-before-start and repeated Stop are no-ops for an attached preview
    // publisher. The synchronous state request orders both one-way commands
    // before this assertion, including any worker error event they emitted.
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(
        session) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_stop_video_capture(
        session) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState stop_barrier_state = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        session, &stop_barrier_state) == DINOX_WEBRTC_STATUS_OK);
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        DINOX_CHECK(state.session_error_count == 0);
        DINOX_CHECK(state.last_session_error == DINOX_WEBRTC_STATUS_OK);
    }

    DinoXWebrtcVideoEffectDiagnostics diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.effect_thread_count == 0);
    DINOX_CHECK(diagnostics.effect_handle_count == 0);
    DINOX_CHECK(diagnostics.frame_copy_count == 0);

    DinoXWebrtcVideoEffectConfig config = dinox_webrtc_video_effect_config_default();
    DinoXWebrtcVideoEffectCapabilities capabilities = {};
    DINOX_CHECK(dinox_webrtc_context_get_video_effect_capabilities(
        context, &capabilities) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(capabilities.supported_effect_mask == 8191 && capabilities.supported_adjustment_mask == 15);
    DINOX_CHECK(capabilities.supported_background_mask == (capabilities.auto_framing_supported ? 15U : 1U));
    DINOX_CHECK(capabilities.supported_glasses_mask == (capabilities.touch_up_supported ? 15U : 1U) &&
        capabilities.supported_hat_mask == capabilities.supported_glasses_mask &&
        capabilities.supported_beard_mask == capabilities.supported_glasses_mask &&
        capabilities.supported_face_accessory_mask == (capabilities.touch_up_supported ? 7U : 1U) &&
        capabilities.supported_scene_effect_mask == 31 && capabilities.low_light_supported == 1);
    uint64_t rejected_revision = 999;
    config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(13);
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    const std::array<std::pair<uint32_t DinoXWebrtcVideoEffectConfig::*, uint32_t>, 7> selections = {{{
        &DinoXWebrtcVideoEffectConfig::glasses_style, 3}, {&DinoXWebrtcVideoEffectConfig::hat_style, 3},
        {&DinoXWebrtcVideoEffectConfig::beard_style, 3}, {&DinoXWebrtcVideoEffectConfig::face_accessory, 2},
        {&DinoXWebrtcVideoEffectConfig::touch_up, 1}, {&DinoXWebrtcVideoEffectConfig::low_light, 1},
        {&DinoXWebrtcVideoEffectConfig::scene_effect, 4}}};
    for (const auto& [field, maximum] : selections) {
        config = dinox_webrtc_video_effect_config_default();
        config.*field = maximum;
        if (field != &DinoXWebrtcVideoEffectConfig::low_light &&
                field != &DinoXWebrtcVideoEffectConfig::scene_effect && !capabilities.touch_up_supported)
            DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
                pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_NOT_READY);
        config.*field = maximum + 1;
        DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
            pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
        config.*field = UINT32_MAX;
        DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
            pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    }
    config = dinox_webrtc_video_effect_config_default();
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR;
    config.background_strength = 50;
    if (!capabilities.auto_framing_supported)
        DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
            pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_NOT_READY);
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID;
    config.background_strength = 0;
    config.background_color_rgb = UINT32_C(0x123456);
    if (!capabilities.auto_framing_supported)
        DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
            pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_NOT_READY);
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE;
    config.background_color_rgb = 0;
    config.asset_id = 1000;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_NOT_READY);
    config = dinox_webrtc_video_effect_config_default();
    config.framing_mode = DINOX_WEBRTC_VIDEO_FRAMING_AUTO;
    if (!capabilities.auto_framing_supported)
        DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
            pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_NOT_READY);
    config.framing_mode = static_cast<DinoXWebrtcVideoFramingMode>(2);
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    config = dinox_webrtc_video_effect_config_default();
    config.contrast = 101;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &rejected_revision) == DINOX_WEBRTC_STATUS_INVALID_ARGUMENT);
    DINOX_CHECK(rejected_revision == 999);
    DinoXWebrtcVideoPipelineState rejected_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        pipeline, &rejected_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(rejected_state.accepted_revision == 0 && rejected_state.applied_revision == 0 &&
        rejected_state.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_NONE &&
        rejected_state.background_mode == DINOX_WEBRTC_VIDEO_BACKGROUND_NONE &&
        rejected_state.framing_mode == DINOX_WEBRTC_VIDEO_FRAMING_NONE &&
        rejected_state.glasses_style == 0 && rejected_state.hat_style == 0 && rejected_state.beard_style == 0 &&
        rejected_state.face_accessory == 0 && rejected_state.touch_up == 0 && rejected_state.low_light == 0 &&
        rejected_state.scene_effect == 0);
    config = dinox_webrtc_video_effect_config_default();
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    uint64_t revision = 0;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 1);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE));
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&state, 1));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.captured == 1);
    DINOX_CHECK(diagnostics.enqueued == 1);
    DINOX_CHECK(diagnostics.processed == 1);
    DINOX_CHECK(diagnostics.frame_copy_count == 1);
    DINOX_CHECK(diagnostics.effect_thread_count == 1);
    DINOX_CHECK(diagnostics.effect_handle_count == 1);

    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 2);
    DINOX_CHECK(wait_for_pipeline(
        &state, revision, DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.effect_thread_count == 1);
    DINOX_CHECK(diagnostics.effect_handle_count == 1);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&state, 2));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.captured == 2);
    DINOX_CHECK(diagnostics.enqueued == 2);
    DINOX_CHECK(diagnostics.processed == 2);
    DINOX_CHECK(diagnostics.frame_copy_count == 2);
    DINOX_CHECK(diagnostics.effect_thread_count == 1);
    DINOX_CHECK(diagnostics.effect_handle_count == 1);

    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 3);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    uint64_t preview_after_off = 0;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        preview_after_off = state.preview_count;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        DINOX_CHECK(state.preview_count == preview_after_off);
    }
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.captured == 2);
    DINOX_CHECK(diagnostics.enqueued == 2);
    DINOX_CHECK(diagnostics.processed == 2);
    DINOX_CHECK(diagnostics.frame_copy_count == 2);
    DINOX_CHECK(diagnostics.effect_thread_count == 0);
    DINOX_CHECK(diagnostics.effect_handle_count == 0);
    DINOX_CHECK(diagnostics.effect_owned_allocated_bytes == 0);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&state, preview_after_off + 1));
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        DINOX_CHECK(state.preview_count == preview_after_off + 1);
    }
    DinoXWebrtcVideoEffectDiagnostics after_direct_frame = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &after_direct_frame) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(after_direct_frame.captured == diagnostics.captured);
    DINOX_CHECK(after_direct_frame.enqueued == diagnostics.enqueued);
    DINOX_CHECK(after_direct_frame.processed == diagnostics.processed);
    DINOX_CHECK(after_direct_frame.frame_copy_count == diagnostics.frame_copy_count);

    // Original colour with non-neutral adjustments must traverse the same
    // effect executor. A later adjustment of that same preset is a new full
    // configuration revision, echoed through the external-worker IPC state.
    config.brightness = 30;
    config.contrast = -10;
    config.saturation = -15;
    config.sharpness = 30;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 4);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    DinoXWebrtcVideoPipelineState adjusted_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        pipeline, &adjusted_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(adjusted_state.brightness == 30 && adjusted_state.contrast == -10 &&
        adjusted_state.saturation == -15 && adjusted_state.sharpness == 30);
    uint64_t preview_before_adjustment = 0;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        preview_before_adjustment = state.preview_count;
    }
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&state, preview_before_adjustment + 1));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.effect_thread_count == 1 &&
        diagnostics.processed == after_direct_frame.processed + 1 &&
        diagnostics.frame_copy_count == after_direct_frame.frame_copy_count + 1);
    config.brightness = -20;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 5);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        pipeline, &adjusted_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(adjusted_state.brightness == -20 && adjusted_state.contrast == -10 &&
        adjusted_state.saturation == -15 && adjusted_state.sharpness == 30);
    config = dinox_webrtc_video_effect_config_default();
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 6);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        pipeline, &diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(diagnostics.effect_thread_count == 0 &&
        diagnostics.effect_owned_allocated_bytes == 0);

    // Teardown is an IPC ordering barrier.  Queue more effect work than the
    // processor can publish immediately, then prove that neither preview nor
    // pipeline callbacks escape after free returns.  This caught the former
    // one-way destroy path, which reproducibly delivered queued previews late.
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(revision == 7);
    DINOX_CHECK(wait_for_pipeline(&state, revision, DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE));
    for (int frame = 0; frame < 32; ++frame) {
        DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
            session, 320, 180) == DINOX_WEBRTC_STATUS_OK);
    }
    dinox_webrtc_video_pipeline_free(pipeline);
    uint64_t preview_after_free = 0;
    uint64_t pipeline_callbacks_after_free = 0;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        preview_after_free = state.preview_count;
        pipeline_callbacks_after_free = state.pipeline_callback_count;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        DINOX_CHECK(state.preview_count == preview_after_free);
        DINOX_CHECK(state.pipeline_callback_count == pipeline_callbacks_after_free);
    }

    // The fence is scoped to the destroyed effect pipeline.  Ordinary local
    // preview must resume immediately after the synchronous destroy reply.
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&state, preview_after_free + 1));

    // Model a native transform that does not make progress while preview
    // ownership moves from A to B. The stall belongs to the pipeline revision,
    // not to A's obsolete publication token: B must open DEGRADED after 500 ms,
    // feed both current video sources and become the only preview publisher.
#if defined(_WIN32)
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US", "900000") == 0);
#else
    DINOX_CHECK(setenv("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US", "900000", 1) == 0);
#endif
    State watchdog_pipeline_state;
    State watchdog_a_state;
    State watchdog_b_state;
    DinoXWebrtcContext* watchdog_context = nullptr;
    DINOX_CHECK(dinox_webrtc_context_new(&watchdog_context) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSession* watchdog_session_a = nullptr;
    DinoXWebrtcSession* watchdog_session_b = nullptr;
    DINOX_CHECK(dinox_webrtc_session_new(
        watchdog_context,
        &session_config,
        &session_callbacks,
        &watchdog_a_state,
        &watchdog_session_a) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_new(
        watchdog_context,
        &session_config,
        &session_callbacks,
        &watchdog_b_state,
        &watchdog_session_b) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipeline* watchdog_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        watchdog_context, 9003, &pipeline_callbacks,
        &watchdog_pipeline_state, &watchdog_pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        watchdog_pipeline, watchdog_session_a, 1) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        watchdog_pipeline, watchdog_session_b, 0) == DINOX_WEBRTC_STATUS_OK);
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        watchdog_pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_pipeline(
        &watchdog_pipeline_state, revision, DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE));
    DinoXWebrtcSessionState source_a_before = {};
    DinoXWebrtcSessionState source_b_before = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_a, &source_a_before) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_b, &source_b_before) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipelineState publisher_a_pipeline_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        watchdog_pipeline, &publisher_a_pipeline_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(publisher_a_pipeline_state.preview_subscriber_id != 0);
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        watchdog_session_a, 160, 120) == DINOX_WEBRTC_STATUS_OK);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    DinoXWebrtcVideoEffectDiagnostics blocked_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        watchdog_pipeline, &blocked_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(blocked_diagnostics.captured == 1);
    DINOX_CHECK(blocked_diagnostics.processed == 0);

    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        watchdog_pipeline, watchdog_session_a, 0) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        watchdog_pipeline, watchdog_session_b, 1) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoPipelineState handover_state = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_state(
        watchdog_pipeline, &handover_state) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(handover_state.preview_subscriber_id != 0);
    DINOX_CHECK(handover_state.preview_subscriber_id !=
        publisher_a_pipeline_state.preview_subscriber_id);

    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    const auto watchdog_route_start = std::chrono::steady_clock::now();
    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        watchdog_session_b, 320, 180) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcSessionState source_b_after_bypass = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_b, &source_b_after_bypass) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(std::chrono::steady_clock::now() - watchdog_route_start <
        std::chrono::milliseconds(200));
    DINOX_CHECK(wait_for_pipeline_application(
        &watchdog_pipeline_state,
        revision,
        DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_DEGRADED));
    DINOX_CHECK(wait_for_preview(&watchdog_b_state, 1));

    // Let A's original 900-ms transform return. It must neither resurrect the
    // applied state nor publish A's stale frame after B opened the direct path.
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    DinoXWebrtcSessionState source_a_after_bypass = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_a, &source_a_after_bypass) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_b, &source_b_after_bypass) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(source_a_after_bypass.local_video_source_frame_count ==
        source_a_before.local_video_source_frame_count + 1);
    DINOX_CHECK(source_b_after_bypass.local_video_source_frame_count ==
        source_b_before.local_video_source_frame_count + 1);
    DINOX_CHECK(source_a_after_bypass.local_video_source_last_width == 320);
    DINOX_CHECK(source_a_after_bypass.local_video_source_last_height == 180);
    DINOX_CHECK(source_b_after_bypass.local_video_source_last_width == 320);
    DINOX_CHECK(source_b_after_bypass.local_video_source_last_height == 180);
    {
        std::lock_guard<std::mutex> lock(watchdog_a_state.mutex);
        DINOX_CHECK(watchdog_a_state.preview_count == 0);
    }
    {
        std::lock_guard<std::mutex> lock(watchdog_b_state.mutex);
        DINOX_CHECK(watchdog_b_state.preview_count == 1);
    }

    DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
        watchdog_session_b, 640, 360) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_preview(&watchdog_b_state, 2));
    DinoXWebrtcSessionState source_a_after_direct = {};
    DinoXWebrtcSessionState source_b_after_direct = {};
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_a, &source_a_after_direct) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_get_state(
        watchdog_session_b, &source_b_after_direct) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(source_a_after_direct.local_video_source_frame_count ==
        source_a_before.local_video_source_frame_count + 2);
    DINOX_CHECK(source_b_after_direct.local_video_source_frame_count ==
        source_b_before.local_video_source_frame_count + 2);
    DINOX_CHECK(source_a_after_direct.local_video_source_last_width == 640);
    DINOX_CHECK(source_a_after_direct.local_video_source_last_height == 360);
    DINOX_CHECK(source_b_after_direct.local_video_source_last_width == 640);
    DINOX_CHECK(source_b_after_direct.local_video_source_last_height == 360);
    {
        std::lock_guard<std::mutex> lock(watchdog_a_state.mutex);
        DINOX_CHECK(watchdog_a_state.preview_count == 0);
    }
    DinoXWebrtcVideoEffectDiagnostics watchdog_diagnostics = {};
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        watchdog_pipeline, &watchdog_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(watchdog_diagnostics.watchdog_bypass == 1);
    DINOX_CHECK(watchdog_diagnostics.effect_thread_count == 0);
    DINOX_CHECK(watchdog_diagnostics.effect_handle_count == 0);
    DINOX_CHECK(watchdog_diagnostics.effect_owned_allocated_bytes == 0);
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        watchdog_pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_pipeline(
        &watchdog_pipeline_state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        watchdog_pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_pipeline(
        &watchdog_pipeline_state, revision, DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE));
    DINOX_CHECK(dinox_webrtc_video_pipeline_get_diagnostics(
        watchdog_pipeline, &watchdog_diagnostics) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(watchdog_diagnostics.effect_thread_count == 1);
    DINOX_CHECK(watchdog_diagnostics.effect_handle_count == 1);
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        watchdog_pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_pipeline(
        &watchdog_pipeline_state, revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE));
    const auto watchdog_free_start = std::chrono::steady_clock::now();
    dinox_webrtc_video_pipeline_free(watchdog_pipeline);
    DINOX_CHECK(std::chrono::steady_clock::now() - watchdog_free_start <
        std::chrono::milliseconds(750));
    DINOX_CHECK(dinox_webrtc_session_close(watchdog_session_a) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_session_close(watchdog_session_b) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(watchdog_session_a);
    dinox_webrtc_session_free(watchdog_session_b);
    dinox_webrtc_context_free(watchdog_context);
#if defined(_WIN32)
    DINOX_CHECK(_putenv_s("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US", "") == 0);
#else
    DINOX_CHECK(unsetenv("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US") == 0);
#endif

    DinoXWebrtcVideoPipeline* callback_pipeline = nullptr;
    DINOX_CHECK(dinox_webrtc_video_pipeline_new(
        context, 9002, &pipeline_callbacks, &state, &callback_pipeline) ==
        DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(dinox_webrtc_video_pipeline_attach_session(
        callback_pipeline, session, 1) == DINOX_WEBRTC_STATUS_OK);
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.free_pipeline_on_next_applied = true;
    }
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(dinox_webrtc_video_pipeline_set_config(
        callback_pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    DINOX_CHECK(wait_for_callback_free(&state));

    // The asynchronous callback path must eventually acknowledge destruction
    // and release its preview fence.  Keep submitting ordinary frames until
    // one passes; no sleep-based assumption about worker scheduling is needed.
    uint64_t preview_after_callback_free = 0;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        preview_after_callback_free = state.preview_count;
    }
    bool preview_resumed = false;
    for (int attempt = 0; attempt < 100 && !preview_resumed; ++attempt) {
        DINOX_CHECK(dinox_webrtc_session_push_synthetic_video_frame(
            session, 160, 120) == DINOX_WEBRTC_STATUS_OK);
        std::unique_lock<std::mutex> lock(state.mutex);
        preview_resumed = state.changed.wait_for(
            lock, std::chrono::milliseconds(20), [&] {
                return state.preview_count > preview_after_callback_free;
            });
    }
    DINOX_CHECK(preview_resumed);

    DINOX_CHECK(dinox_webrtc_session_close(session) == DINOX_WEBRTC_STATUS_OK);
    dinox_webrtc_session_free(session);
    dinox_webrtc_context_free(context);
    return 0;
}
