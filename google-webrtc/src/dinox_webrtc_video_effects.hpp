#ifndef DINOX_WEBRTC_VIDEO_EFFECTS_HPP
#define DINOX_WEBRTC_VIDEO_EFFECTS_HPP

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

#include "api/video/video_frame.h"
#include "common_video/include/video_frame_buffer_pool.h"

#include "dinox_webrtc.h"
#include "dinox_webrtc_video_runtime.hpp"

namespace dinox::webrtc_effects {

struct Diagnostics {
    uint64_t captured = 0;
    uint64_t enqueued = 0;
    uint64_t processed = 0;
    uint64_t bypassed = 0;
    uint64_t queue_replaced = 0;
    uint64_t failed = 0;
    uint64_t watchdog_bypass = 0;
    uint64_t processing_time_total_us = 0;
    uint64_t processing_time_max_us = 0;
    uint64_t processing_time_p95_us = 0;
    uint64_t processing_time_p99_us = 0;
    uint64_t last_completed_monotonic_us = 0;
    uint64_t effect_owned_allocated_bytes = 0;
    uint64_t frame_copy_count = 0;
    uint32_t effect_thread_count = 0;
    uint32_t effect_handle_count = 0;
};

class VideoEffectProcessor final
    : public std::enable_shared_from_this<VideoEffectProcessor> {
 public:
    using OutputCallback =
        std::function<void(const webrtc::VideoFrame&, uint64_t, uint64_t, uint64_t)>;
    using AppliedCallback =
        std::function<void(uint64_t, DinoXWebrtcVideoEffectType)>;
    using DegradedCallback =
        std::function<void(const webrtc::VideoFrame&, uint64_t, uint64_t, uint64_t)>;
    using RuntimeOutputCallback = std::function<void(const webrtc::VideoFrame&,
        uint64_t, uint64_t, uint64_t, const FrameIdentity&)>;

    VideoEffectProcessor(
        OutputCallback output_callback,
        AppliedCallback applied_callback,
        uint32_t processing_delay_for_test_us = 0,
        DegradedCallback degraded_callback = {},
        std::shared_ptr<VideoRuntime> runtime = {},
        RuntimeOutputCallback runtime_output_callback = {},
        RuntimeOutputCallback runtime_degraded_callback = {});
    ~VideoEffectProcessor();

    VideoEffectProcessor(const VideoEffectProcessor&) = delete;
    VideoEffectProcessor& operator=(const VideoEffectProcessor&) = delete;

    bool enable_effect(DinoXWebrtcVideoEffectType effect, uint64_t revision);
    bool enable_config(const DinoXWebrtcVideoEffectConfig& config, uint64_t revision);
    bool disable(uint64_t revision);
    bool enqueue(
        const webrtc::VideoFrame& frame,
        uint64_t frame_id,
        uint64_t revision,
        uint64_t source_id,
        FrameIdentity identity = {});
    bool degrade_if_stalled(
        const webrtc::VideoFrame& bypass_frame,
        uint64_t frame_id,
        uint64_t revision,
        uint64_t source_id,
        FrameIdentity identity = {});
    void shutdown();
    Diagnostics snapshot() const;

    static bool apply_grayscale(
        const webrtc::VideoFrame& input,
        webrtc::VideoFrame* output,
        uint64_t* out_allocated_bytes = nullptr);
    static bool apply_warm_tone(
        const webrtc::VideoFrame& input,
        webrtc::VideoFrame* output,
        uint64_t* out_allocated_bytes = nullptr);
    static bool apply_config(
        const webrtc::VideoFrame& input,
        const DinoXWebrtcVideoEffectConfig& config,
        webrtc::VideoFrame* output,
        uint64_t* out_allocated_bytes = nullptr);

 private:
    struct PendingFrame {
        webrtc::VideoFrame frame;
        uint64_t frame_id = 0;
        uint64_t revision = 0;
        uint64_t source_id = 0;
        DinoXWebrtcVideoEffectConfig config = {};
        FrameIdentity identity;
    };

    void run();
    void record_processing_time_locked(uint64_t elapsed_us);
    void finish_thread_locked();
    bool prepare_fisheye_geometry(int width, int height, const PendingFrame& pending);
    void release_fisheye_geometry_locked();

    OutputCallback output_callback_;
    AppliedCallback applied_callback_;
    DegradedCallback degraded_callback_;
    std::shared_ptr<VideoRuntime> runtime_;
    RuntimeOutputCallback runtime_output_callback_;
    RuntimeOutputCallback runtime_degraded_callback_;
    mutable std::mutex mutex_;
    std::recursive_mutex configure_mutex_;
    std::condition_variable condition_;
    std::optional<PendingFrame> pending_frame_;
    std::thread thread_;
    bool thread_running_ = false;
    bool stop_requested_ = false;
    bool desired_enabled_ = false;
    DinoXWebrtcVideoEffectConfig desired_config_ = {};
    bool watchdog_tripped_ = false;
    bool processing_active_ = false;
    std::chrono::steady_clock::time_point processing_started_ = {};
    uint64_t processing_revision_ = 0;
    uint64_t processing_source_id_ = 0;
    uint64_t desired_revision_ = 0;
    Diagnostics diagnostics_;
    std::array<uint64_t, 128> processing_samples_ = {};
    size_t processing_sample_count_ = 0;
    size_t processing_sample_cursor_ = 0;
    uint32_t processing_delay_for_test_us_ = 0;
    webrtc::VideoFrameBufferPool buffer_pool_{false, 3};
    int pool_width_ = 0;
    int pool_height_ = 0;
    std::array<const void*, 3> pool_buffer_addresses_ = {};
    size_t pool_buffer_count_ = 0;
    uint64_t pool_buffer_bytes_ = 0;
    // Worker-only, exact three-row preset+BC ring, never a full-frame copy.
    std::unique_ptr<uint8_t[]> luma_scratch_;
    size_t luma_scratch_bytes_ = 0;
    int scratch_width_ = 0;
    int scratch_height_ = 0;
    // Worker-owned packed x/y coordinates only: no camera pixels or masks.
    // At most 5 MiB, including Y and shared U/V geometry. Snapshot reads only
    // the mutex-protected byte count; control never releases a live reader.
    std::unique_ptr<uint32_t[]> fisheye_geometry_;
    size_t fisheye_geometry_entries_ = 0;
    size_t fisheye_geometry_bytes_ = 0;
    int fisheye_width_ = 0;
    int fisheye_height_ = 0;
    uint64_t fisheye_source_id_ = 0;
    uint64_t fisheye_camera_lease_ = 0;
    vision::VisionBinding fisheye_binding_{};
};

}  // namespace dinox::webrtc_effects

#endif
