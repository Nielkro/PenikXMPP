#include "dinox_webrtc.h"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <span>
#include <string>
#include <thread>

#define CHECK(value) do { if (!(value)) { std::cerr << "privacy check line " << __LINE__ << ": " << #value << '\n'; return 1; } } while (false)
namespace {
struct State {
    std::mutex mutex;
    std::condition_variable changed;
    DinoXWebrtcVideoPipelineState pipeline{};
    uint64_t previews = 0;
    bool all_gray = true;
    bool last_gray = true;
    bool description_entered = false, description_release = false;
    bool description_finished = false, description_timeout = false;
};
bool environment(const char* name, const std::string& value) {
#if defined(_WIN32)
    return _putenv_s(name, value.c_str()) == 0;
#else
    return setenv(name, value.c_str(), 1) == 0;
#endif
}
void state_changed(DinoXWebrtcVideoPipeline*, const DinoXWebrtcVideoPipelineState* state, void* user) {
    if (!state) return;
    auto& owner = *static_cast<State*>(user);
    std::lock_guard<std::mutex> lock(owner.mutex);
    owner.pipeline = *state; owner.changed.notify_all();
}
// ABI callback supplies stride*height BGRA bytes. Validate the extent before
// borrowing at this documented external C pointer boundary.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
void preview(DinoXWebrtcSession*, const uint8_t* bgra, int width, int height,
             int stride, uint64_t, void* user) {
    if (!bgra || width <= 0 || height <= 0 || width > 4096 || height > 4096 || stride < 4 * width) return;
    const auto bytes = std::span(bgra, static_cast<size_t>(stride) * height);
    bool gray = true;
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            const size_t i = static_cast<size_t>(y) * stride + x * 4;
            gray = gray && bytes[i] >= 45 && bytes[i] <= 51 &&
                std::abs(int(bytes[i]) - int(bytes[i + 1])) <= 1 &&
                std::abs(int(bytes[i]) - int(bytes[i + 2])) <= 1;
        }
    auto& owner = *static_cast<State*>(user);
    std::lock_guard<std::mutex> lock(owner.mutex);
    ++owner.previews; owner.all_gray = owner.all_gray && gray;
    owner.last_gray = gray; owner.changed.notify_all();
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
bool applied(State& state, uint64_t revision) {
    std::unique_lock<std::mutex> lock(state.mutex);
    return state.changed.wait_for(lock, std::chrono::seconds(3), [&] {
        return state.pipeline.accepted_revision == revision &&
            state.pipeline.application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_APPLIED;
    });
}
uint64_t count(State& state) { std::lock_guard<std::mutex> lock(state.mutex); return state.previews; }
bool preview_after(State& state, uint64_t before) {
    std::unique_lock<std::mutex> lock(state.mutex);
    return state.changed.wait_for(lock, std::chrono::seconds(3), [&] { return state.previews > before; });
}

void blocked_description(DinoXWebrtcSession*, DinoXWebrtcSdpType type,
        const char* sdp, void* user) {
    if (type != DINOX_WEBRTC_SDP_TYPE_OFFER || !sdp) return;
    auto& state = *static_cast<State*>(user);
    std::unique_lock<std::mutex> lock(state.mutex);
    state.description_entered = true;
    state.changed.notify_all();
    // The native emitter holds the real Session callback gate throughout this
    // public callback. No configuration/close call is made while it is held.
    state.description_timeout = !state.changed.wait_for(lock, std::chrono::seconds(5), [&] {
        return state.description_release;
    });
    state.description_finished = true;
    state.changed.notify_all();
}

struct GateResources {
    explicit GateResources(State& state_in) : state(state_in) {}
    ~GateResources() {
        // Release the finite callback barrier even after an assertion fails.
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.description_release = true;
        }
        state.changed.notify_all();
        if (pipeline) dinox_webrtc_video_pipeline_free(pipeline);
        if (session) dinox_webrtc_session_free(session);
        if (context) dinox_webrtc_context_free(context);
    }
    State& state;
    DinoXWebrtcContext* context = nullptr;
    DinoXWebrtcSession* session = nullptr;
    DinoXWebrtcVideoPipeline* pipeline = nullptr;
};

int callback_gate_age_case(bool concealed) {
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_SEGMENT_MODEL", concealed ? "exit" : "normal"));
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_FACE_MODEL", concealed ? "exit" : "normal"));
    State state;
    GateResources resources(state);
    CHECK(dinox_webrtc_context_new(&resources.context) == DINOX_WEBRTC_STATUS_OK);
    auto callbacks = dinox_webrtc_callbacks_default();
    callbacks.on_local_video_frame = preview;
    callbacks.on_local_description = blocked_description;
    auto session_config = dinox_webrtc_session_config_default();
    CHECK(dinox_webrtc_session_new(resources.context, &session_config, &callbacks,
        &state, &resources.session) == DINOX_WEBRTC_STATUS_OK);
    auto pipeline_callbacks = dinox_webrtc_video_pipeline_callbacks_default();
    pipeline_callbacks.on_state_changed = state_changed;
    CHECK(dinox_webrtc_video_pipeline_new(resources.context, concealed ? 99203 : 99202,
        &pipeline_callbacks, &state, &resources.pipeline) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_attach_session(resources.pipeline, resources.session, 1) ==
        DINOX_WEBRTC_STATUS_OK);
    auto config = dinox_webrtc_video_effect_config_default();
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR;
    config.background_strength = 70;
    uint64_t revision = 0;
    CHECK(dinox_webrtc_video_pipeline_set_config(resources.pipeline, &config, &revision) ==
        DINOX_WEBRTC_STATUS_OK);
    CHECK(applied(state, revision));

    // The first frame supplies the inference sample. The normal fake worker
    // returns mask=200: a later black frame is composited black, whereas a
    // missing/failed mask is visibly opaque gray. Verify the intended branch
    // before blocking the gate, instead of treating a missing mask as proof.
    bool warmed = false;
    for (int attempt = 0; attempt < 8 && !warmed; ++attempt) {
        const auto before = count(state);
        CHECK(dinox_webrtc_session_push_synthetic_video_frame(resources.session, 16, 12) ==
            DINOX_WEBRTC_STATUS_OK);
        CHECK(preview_after(state, before));
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            warmed = concealed ? state.last_gray : !state.last_gray;
        }
        if (!warmed) std::this_thread::sleep_for(std::chrono::milliseconds(110));
    }
    CHECK(warmed);
    DinoXWebrtcSessionState before_source{};
    DinoXWebrtcVideoEffectDiagnostics before_diagnostics{};
    CHECK(dinox_webrtc_session_get_state(resources.session, &before_source) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_get_diagnostics(resources.pipeline, &before_diagnostics) ==
        DINOX_WEBRTC_STATUS_OK);
    const uint64_t before_preview = count(state);

    CHECK(dinox_webrtc_session_create_offer(resources.session) == DINOX_WEBRTC_STATUS_OK);
    {
        std::unique_lock<std::mutex> lock(state.mutex);
        CHECK(state.changed.wait_for(lock, std::chrono::seconds(3), [&] {
            return state.description_entered;
        }));
    }
    CHECK(dinox_webrtc_session_push_synthetic_video_frame(resources.session, 16, 12) ==
        DINOX_WEBRTC_STATUS_OK);
    bool processed = false;
    const auto processing_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < processing_deadline && !processed) {
        DinoXWebrtcVideoEffectDiagnostics diagnostics{};
        CHECK(dinox_webrtc_video_pipeline_get_diagnostics(resources.pipeline, &diagnostics) ==
            DINOX_WEBRTC_STATUS_OK);
        processed = diagnostics.processed == before_diagnostics.processed + 1;
        if (!processed) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    CHECK(processed);
    // Processing finished while publication is blocked by the real callback
    // gate. Even a mask captured by this new request is now older than 500ms.
    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    CHECK(count(state) == before_preview);
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        CHECK(!state.description_finished && !state.description_timeout);
        state.description_release = true;
    }
    state.changed.notify_all();
    {
        std::unique_lock<std::mutex> lock(state.mutex);
        CHECK(state.changed.wait_for(lock, std::chrono::seconds(3), [&] {
            return state.description_finished;
        }));
        CHECK(!state.description_timeout);
    }
    if (concealed) CHECK(preview_after(state, before_preview));

    // Off shares the publication gate and processor configure gate: its
    // acknowledgement drains the blocked output before reading final counts.
    config = dinox_webrtc_video_effect_config_default();
    CHECK(dinox_webrtc_video_pipeline_set_config(resources.pipeline, &config, &revision) ==
        DINOX_WEBRTC_STATUS_OK);
    CHECK(applied(state, revision));
    DinoXWebrtcSessionState after_source{};
    CHECK(dinox_webrtc_session_get_state(resources.session, &after_source) == DINOX_WEBRTC_STATUS_OK);
    CHECK(after_source.local_video_source_frame_count ==
        before_source.local_video_source_frame_count + (concealed ? 1 : 0));
    CHECK(count(state) == before_preview + (concealed ? 1 : 0));
    if (concealed) {
        std::lock_guard<std::mutex> lock(state.mutex);
        CHECK(state.all_gray);
    }
    return 0;
}
} // namespace

int main(int argc, char** argv) {
    std::string fake_worker;
    bool watchdog = false;
    bool callback_gate = false;
    // Platform main owns exactly argc C strings; no frame/config supplies argv.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    if ((argc == 2 || argc == 3) && argv && argv[1]) fake_worker = argv[1];
    if (argc == 3 && argv[2]) {
        watchdog = std::string(argv[2]) == "--watchdog";
        callback_gate = std::string(argv[2]) == "--callback-gate";
    }
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    CHECK(!fake_worker.empty());
    if (watchdog) CHECK(environment("DINOX_WEBRTC_VIDEO_EFFECT_TEST_BLOCK_US", "900000"));
    fake_worker = std::filesystem::absolute(fake_worker).string();
    const auto directory = std::filesystem::temp_directory_path() /
        ("dinox-privacy-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(directory);
    const auto original = std::filesystem::current_path();
    struct Cleanup { std::filesystem::path directory, original;
        ~Cleanup() { std::filesystem::current_path(original); std::filesystem::remove_all(directory); }
    } cleanup{directory, original};
    std::filesystem::current_path(directory);
    std::ofstream("exit").put('\n'); // fake-worker's deterministic model mode
    std::ofstream("normal").put('\n');
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_PATHS", "1"));
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_WORKER", fake_worker));
    if (callback_gate) {
        // Requires the existing google-libwebrtc-test-oracle build option;
        // proxy-side user callbacks do not hold the native Session mutex.
        CHECK(environment("DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE", "1"));
        std::cout << "callback-gate regression requires the in-process test oracle\n";
        CHECK(callback_gate_age_case(false) == 0);
        CHECK(callback_gate_age_case(true) == 0);
        return 0;
    }
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_SEGMENT_MODEL", "missing"));
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_FACE_MODEL", "missing"));
    DinoXWebrtcContext* context = nullptr;
    CHECK(dinox_webrtc_context_new(&context) == DINOX_WEBRTC_STATUS_OK);
    DinoXWebrtcVideoEffectCapabilities caps{};
    CHECK(dinox_webrtc_context_get_video_effect_capabilities(context, &caps) == DINOX_WEBRTC_STATUS_OK);
    CHECK(caps.supported_background_mask == 1 && caps.auto_framing_supported == 0 &&
        caps.supported_glasses_mask == 1 && caps.touch_up_supported == 0 &&
        caps.supported_scene_effect_mask == 31 && caps.low_light_supported == 1);
    // Freeze environment before constructing the second native context/worker.
    dinox_webrtc_context_free(context);
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_SEGMENT_MODEL", "exit"));
    CHECK(environment("DINOX_WEBRTC_VISION_TEST_FACE_MODEL", "exit"));
    CHECK(dinox_webrtc_context_new(&context) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_context_get_video_effect_capabilities(context, &caps) == DINOX_WEBRTC_STATUS_OK);
    CHECK(caps.supported_background_mask == 15 && caps.auto_framing_supported == 1 &&
        caps.supported_glasses_mask == 15 && caps.supported_face_accessory_mask == 7);
    State state;
    auto callbacks = dinox_webrtc_callbacks_default(); callbacks.on_local_video_frame = preview;
    auto session_config = dinox_webrtc_session_config_default();
    DinoXWebrtcSession *owner = nullptr, *peer = nullptr;
    CHECK(dinox_webrtc_session_new(context, &session_config, &callbacks, &state, &owner) == DINOX_WEBRTC_STATUS_OK);
    auto peer_callbacks = dinox_webrtc_callbacks_default();
    CHECK(dinox_webrtc_session_new(context, &session_config, &peer_callbacks, nullptr, &peer) == DINOX_WEBRTC_STATUS_OK);
    auto pipeline_callbacks = dinox_webrtc_video_pipeline_callbacks_default();
    pipeline_callbacks.on_state_changed = state_changed;
    DinoXWebrtcVideoPipeline* pipeline = nullptr;
    CHECK(dinox_webrtc_video_pipeline_new(context, 99201, &pipeline_callbacks, &state, &pipeline) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_attach_session(pipeline, owner, 1) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_video_pipeline_attach_session(pipeline, peer, 0) == DINOX_WEBRTC_STATUS_OK);
    auto config = dinox_webrtc_video_effect_config_default();
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR; config.background_strength = 70;
    uint64_t revision = 0;
    CHECK(dinox_webrtc_video_pipeline_set_config(pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    CHECK(applied(state, revision));
    if (watchdog) {
        CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11) == DINOX_WEBRTC_STATUS_OK);
        std::this_thread::sleep_for(std::chrono::milliseconds(520));
        CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11) == DINOX_WEBRTC_STATUS_OK);
        { std::unique_lock<std::mutex> lock(state.mutex);
            CHECK(state.changed.wait_for(lock, std::chrono::seconds(3), [&] {
                return state.pipeline.application_state == DINOX_WEBRTC_VIDEO_EFFECT_APPLICATION_DEGRADED;
            })); }
        for (int i = 0; i < 4; ++i)
            CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11) == DINOX_WEBRTC_STATUS_OK);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        DinoXWebrtcSessionState source{};
        CHECK(dinox_webrtc_session_get_state(owner, &source) == DINOX_WEBRTC_STATUS_OK);
        CHECK(source.local_video_source_frame_count == 0 && count(state) == 0);
        dinox_webrtc_video_pipeline_free(pipeline);
        CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11) == DINOX_WEBRTC_STATUS_OK);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        CHECK(count(state) == 0);
        dinox_webrtc_session_free(owner); dinox_webrtc_session_free(peer); dinox_webrtc_context_free(context);
        return 0;
    }
    auto invalid = config;
    invalid.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE;
    invalid.background_strength = 0; invalid.asset_id = 1001;
    uint64_t unchanged_revision = 999;
    CHECK(dinox_webrtc_video_pipeline_set_config(pipeline, &invalid, &unchanged_revision) ==
        DINOX_WEBRTC_STATUS_NOT_READY && unchanged_revision == 999);
    for (int i = 0; i < 4; ++i) {
        const auto before = count(state);
        CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, i % 2 ? 9 : 7, i % 2 ? 5 : 11) == DINOX_WEBRTC_STATUS_OK);
        CHECK(preview_after(state, before));
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
    }
    // A worker that exits never supplies a mask. Every delivered frame must be
    // solid concealment, even after the inference fault and a source transform.
    { std::lock_guard<std::mutex> lock(state.mutex); CHECK(state.all_gray); }
    DinoXWebrtcSessionState owner_source{}, peer_source{};
    CHECK(dinox_webrtc_session_get_state(owner, &owner_source) == DINOX_WEBRTC_STATUS_OK);
    CHECK(dinox_webrtc_session_get_state(peer, &peer_source) == DINOX_WEBRTC_STATUS_OK);
    CHECK(owner_source.local_video_source_frame_count == peer_source.local_video_source_frame_count &&
        owner_source.local_video_source_frame_count >= 4);
    CHECK(dinox_webrtc_video_pipeline_detach_session(pipeline, owner) == DINOX_WEBRTC_STATUS_OK);
    const auto before_detach = count(state);
    // Missing pipeline / detached lease: the raw synthetic black frame is
    // rejected through the session latch, not substituted for selected blur.
    dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    CHECK(count(state) == before_detach);
    CHECK(dinox_webrtc_video_pipeline_attach_session(pipeline, owner, 1) == DINOX_WEBRTC_STATUS_OK);
    const auto before_rebind = count(state);
    CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11) == DINOX_WEBRTC_STATUS_OK);
    CHECK(preview_after(state, before_rebind));
    { std::lock_guard<std::mutex> lock(state.mutex); CHECK(state.all_gray); }
    // Pure scene/low-light and the new preset need no inference demand. The
    // full config and revision must echo independently of a faulted old model.
    config = dinox_webrtc_video_effect_config_default();
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER;
    config.low_light = 1; config.scene_effect = 3;
    CHECK(dinox_webrtc_video_pipeline_set_config(pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    CHECK(applied(state, revision));
    { std::lock_guard<std::mutex> lock(state.mutex);
        CHECK(state.pipeline.low_light == 1 && state.pipeline.scene_effect == 3 &&
            state.pipeline.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER); }
    const auto before_scene = count(state);
    CHECK(dinox_webrtc_session_push_synthetic_video_frame(owner, 63, 35) == DINOX_WEBRTC_STATUS_OK);
    CHECK(preview_after(state, before_scene));
    // Restore a selected private background before destroying its pipeline;
    // teardown must retain the session latch instead of reopening raw preview.
    config = dinox_webrtc_video_effect_config_default();
    config.background_mode = DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR; config.background_strength = 70;
    CHECK(dinox_webrtc_video_pipeline_set_config(pipeline, &config, &revision) == DINOX_WEBRTC_STATUS_OK);
    CHECK(applied(state, revision));
    dinox_webrtc_video_pipeline_free(pipeline);
    const auto before_free = count(state);
    dinox_webrtc_session_push_synthetic_video_frame(owner, 7, 11);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    CHECK(count(state) == before_free);
    dinox_webrtc_session_free(owner); dinox_webrtc_session_free(peer); dinox_webrtc_context_free(context);
    return 0;
}
