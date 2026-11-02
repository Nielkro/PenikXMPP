#ifndef DINOX_WEBRTC_VIDEO_RING_HPP
#define DINOX_WEBRTC_VIDEO_RING_HPP

#include <cstddef>
#include <cstdint>
#include <vector>

namespace dinox::webrtc_worker {

constexpr uint32_t kVideoRingMagic = 0x44585652;
constexpr uint32_t kVideoRingVersion = 6;
// Four simultaneous remote participant streams plus one local preview each
// retain an independent latest-frame mailbox. A hot stream replaces only its
// own unread slot and therefore cannot starve any of the other four streams.
constexpr uint32_t kVideoRingSlotCount = 5;
constexpr uint32_t kVideoRingMaxWidth = 1920;
constexpr uint32_t kVideoRingMaxHeight = 1920;
constexpr uint32_t kVideoRingMaxStride = kVideoRingMaxWidth * 4;
constexpr size_t kVideoRingSlotBytes =
    static_cast<size_t>(kVideoRingMaxWidth) * kVideoRingMaxHeight * 4;

enum class VideoFrameKind : uint32_t {
    Remote = 1,
    Local = 2,
    Recorder = 3,
};

struct VideoFrame {
    uint64_t session_id = 0;
    uint64_t generation = 0;
    uint64_t frame_id = 0;
    uint64_t sequence = 0;
    VideoFrameKind kind = VideoFrameKind::Remote;
    int width = 0;
    int height = 0;
    int stride = 0;
    std::vector<uint8_t> pixels;
};

/**
 * Borrowed view of one validated shared-memory frame.
 *
 * The pixel pointer is valid only for the synchronous duration of the callback
 * passed to with_video_ring_frame_view().  The ring slot remains locked for
 * reading during that callback and must not be retained by the consumer.
 */
struct VideoFrameView {
    uint64_t session_id = 0;
    uint64_t generation = 0;
    uint64_t frame_id = 0;
    uint64_t sequence = 0;
    VideoFrameKind kind = VideoFrameKind::Remote;
    int width = 0;
    int height = 0;
    int stride = 0;
    const uint8_t* pixels = nullptr;
    size_t data_size = 0;
};

using VideoFrameViewCallback = void (*)(const VideoFrameView* frame, void* user_data);

#if defined(DINOX_WEBRTC_VIDEO_RING_TESTING)
using VideoRingReplacementTestHook = void (*)(void* user_data);
void set_video_ring_replacement_test_hook(
    VideoRingReplacementTestHook hook,
    void* user_data);
#endif

size_t video_ring_size();
bool initialize_video_ring(void* memory, size_t size);

/**
 * Publish one frame into the shared ring.
 *
 * For latest-frame-wins streams, out_replaced_ready_frame reports that an
 * unread frame was replaced. out_notification_already_pending reports whether
 * its existing control-channel wake-up still owns the newest frame. The caller
 * must provide that output and send a notification exactly when it is false.
 */
bool write_video_ring_frame(
    void* memory,
    size_t size,
    uint64_t session_id,
    uint64_t generation,
    VideoFrameKind kind,
    const uint8_t* bgra_data,
    int width,
    int height,
    int stride,
    uint64_t frame_id,
    bool latest_frame_wins,
    uint32_t* out_slot,
    uint64_t* out_notification_sequence,
    bool* out_replaced_ready_frame = nullptr,
    bool* out_notification_already_pending = nullptr);
bool read_video_ring_frame(
    const void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence,
    uint64_t expected_session_id,
    uint64_t expected_generation,
    VideoFrameKind expected_kind,
    VideoFrame* out_frame);
bool with_video_ring_frame_view(
    const void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence,
    uint64_t expected_session_id,
    uint64_t expected_generation,
    VideoFrameKind expected_kind,
    VideoFrameViewCallback callback,
    void* user_data);
bool discard_video_ring_frame(
    void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence);

}  // namespace dinox::webrtc_worker

#endif
