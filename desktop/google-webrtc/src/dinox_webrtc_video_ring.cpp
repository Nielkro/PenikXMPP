#include "dinox_webrtc_video_ring.hpp"

#include <atomic>
#include <cstring>
#include <limits>

namespace dinox::webrtc_worker {
namespace {

constexpr size_t kHeaderSize = 64;
constexpr size_t kMetadataSize = 72;
constexpr uint64_t kSlotStateMask = 7;
constexpr uint64_t kSlotFree = 0;
constexpr uint64_t kSlotWritingNew = 1;
constexpr uint64_t kSlotReady = 2;
constexpr uint64_t kSlotReading = 3;
constexpr uint64_t kSlotReplacing = 4;
constexpr uint64_t kSlotReplacingNotificationConsumed = 5;
constexpr uint64_t kSlotReplacingNotificationDiscarded = 6;

#if defined(DINOX_WEBRTC_VIDEO_RING_TESTING)
VideoRingReplacementTestHook g_replacement_test_hook = nullptr;
void* g_replacement_test_hook_data = nullptr;
#endif

struct RingHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t slot_count;
    uint32_t max_width;
    uint32_t max_height;
    uint32_t max_stride;
    uint64_t next_sequence;
    uint8_t reserved[kHeaderSize - 32];
};

struct SlotMetadata {
    uint64_t sequence;
    uint64_t notification_sequence;
    uint64_t session_id;
    uint64_t generation;
    uint64_t frame_id;
    uint64_t state_token;
    uint32_t kind;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t data_size;
    uint32_t pixel_format;
};

static_assert(sizeof(RingHeader) == kHeaderSize);
static_assert(sizeof(SlotMetadata) == kMetadataSize);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

size_t slot_size() {
    return kMetadataSize + kVideoRingSlotBytes;
}

SlotMetadata* metadata(void* memory, uint32_t slot) {
    auto* bytes = static_cast<uint8_t*>(memory);
    return reinterpret_cast<SlotMetadata*>(bytes + kHeaderSize + slot * slot_size());
}

const SlotMetadata* metadata(const void* memory, uint32_t slot) {
    const auto* bytes = static_cast<const uint8_t*>(memory);
    return reinterpret_cast<const SlotMetadata*>(bytes + kHeaderSize + slot * slot_size());
}

uint8_t* pixels(void* memory, uint32_t slot) {
    return reinterpret_cast<uint8_t*>(metadata(memory, slot)) + kMetadataSize;
}

const uint8_t* pixels(const void* memory, uint32_t slot) {
    return reinterpret_cast<const uint8_t*>(metadata(memory, slot)) + kMetadataSize;
}

uint64_t slot_state(uint64_t notification_sequence, uint64_t state) {
    return notification_sequence | state;
}

uint64_t state_notification_sequence(uint64_t state_token) {
    return state_token & ~kSlotStateMask;
}

class SlotReadGuard final {
 public:
    explicit SlotReadGuard(SlotMetadata* metadata) : metadata_(metadata) {}
    ~SlotReadGuard() {
        if (metadata_ != nullptr) {
            __atomic_store_n(&metadata_->state_token, kSlotFree, __ATOMIC_RELEASE);
        }
    }

    SlotReadGuard(const SlotReadGuard&) = delete;
    SlotReadGuard& operator=(const SlotReadGuard&) = delete;

 private:
    SlotMetadata* metadata_ = nullptr;
};

enum class NotificationClaim {
    None,
    Ready,
    ReplacementInProgress,
};

NotificationClaim claim_notification(
    SlotMetadata* meta,
    uint64_t notification_sequence,
    bool discard_replacement = false) {
    if (meta == nullptr || notification_sequence == 0 ||
            (notification_sequence & kSlotStateMask) != 0) {
        return NotificationClaim::None;
    }
    uint64_t state = __atomic_load_n(&meta->state_token, __ATOMIC_ACQUIRE);
    while (true) {
        if (state == slot_state(notification_sequence, kSlotReady)) {
            uint64_t expected = state;
            if (__atomic_compare_exchange_n(
                    &meta->state_token,
                    &expected,
                    slot_state(notification_sequence, kSlotReading),
                    false,
                    __ATOMIC_ACQUIRE,
                    __ATOMIC_RELAXED)) {
                return NotificationClaim::Ready;
            }
            state = expected;
            continue;
        }
        if (state == slot_state(notification_sequence, kSlotReplacing)) {
            // The proxy may consume the one outstanding wake-up while the
            // producer is replacing its READY frame. A normal reader requests
            // exactly one follow-up event; an explicit discard requests FREE.
            // Both handshakes close the lost-wakeup window without spinning
            // the serial proxy reader.
            uint64_t expected = state;
            if (__atomic_compare_exchange_n(
                    &meta->state_token,
                    &expected,
                    slot_state(
                        notification_sequence,
                        discard_replacement
                            ? kSlotReplacingNotificationDiscarded
                            : kSlotReplacingNotificationConsumed),
                    false,
                    __ATOMIC_ACQ_REL,
                    __ATOMIC_RELAXED)) {
                return NotificationClaim::ReplacementInProgress;
            }
            state = expected;
            continue;
        }
        return NotificationClaim::None;
    }
}

bool valid_frame_metadata(
    const SlotMetadata* meta,
    uint64_t frame_sequence,
    uint64_t notification_sequence,
    uint64_t expected_session_id,
    uint64_t expected_generation,
    VideoFrameKind expected_kind) {
    return meta != nullptr &&
        __atomic_load_n(&meta->sequence, __ATOMIC_ACQUIRE) == frame_sequence &&
        __atomic_load_n(&meta->notification_sequence, __ATOMIC_ACQUIRE) ==
            notification_sequence &&
        __atomic_load_n(&meta->session_id, __ATOMIC_ACQUIRE) == expected_session_id &&
        __atomic_load_n(&meta->generation, __ATOMIC_ACQUIRE) == expected_generation &&
        __atomic_load_n(&meta->kind, __ATOMIC_ACQUIRE) ==
            static_cast<uint32_t>(expected_kind) &&
        meta->pixel_format == 1 && meta->width > 0 && meta->height > 0 &&
        meta->width <= kVideoRingMaxWidth && meta->height <= kVideoRingMaxHeight &&
        meta->stride >= meta->width * 4 && meta->stride <= kVideoRingMaxStride &&
        meta->data_size == meta->stride * meta->height &&
        meta->data_size <= kVideoRingSlotBytes;
}

bool valid_ring(const void* memory, size_t size) {
    if (memory == nullptr || size < video_ring_size()) return false;
    const auto* header = static_cast<const RingHeader*>(memory);
    return header->magic == kVideoRingMagic &&
        header->version == kVideoRingVersion &&
        header->slot_count == kVideoRingSlotCount &&
        header->max_width == kVideoRingMaxWidth &&
        header->max_height == kVideoRingMaxHeight &&
        header->max_stride == kVideoRingMaxStride;
}

}  // namespace

size_t video_ring_size() {
    return kHeaderSize + kVideoRingSlotCount * slot_size();
}

bool initialize_video_ring(void* memory, size_t size) {
    if (memory == nullptr || size < video_ring_size()) return false;
    std::memset(memory, 0, video_ring_size());
    auto* header = static_cast<RingHeader*>(memory);
    header->magic = kVideoRingMagic;
    header->version = kVideoRingVersion;
    header->slot_count = kVideoRingSlotCount;
    header->max_width = kVideoRingMaxWidth;
    header->max_height = kVideoRingMaxHeight;
    header->max_stride = kVideoRingMaxStride;
    header->next_sequence = 8;
    return true;
}

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
    bool* out_replaced_ready_frame,
    bool* out_notification_already_pending) {
    if (!valid_ring(memory, size) || bgra_data == nullptr || out_slot == nullptr ||
            out_notification_sequence == nullptr || session_id == 0 || generation == 0 ||
            (latest_frame_wins && out_notification_already_pending == nullptr) ||
            width <= 0 || height <= 0 || stride < width * 4 ||
            width > static_cast<int>(kVideoRingMaxWidth) ||
            height > static_cast<int>(kVideoRingMaxHeight) ||
            stride > static_cast<int>(kVideoRingMaxStride)) {
        return false;
    }
    const uint64_t data_size_64 = static_cast<uint64_t>(stride) * static_cast<uint64_t>(height);
    if (data_size_64 > kVideoRingSlotBytes || data_size_64 > std::numeric_limits<uint32_t>::max()) {
        return false;
    }
    auto* header = static_cast<RingHeader*>(memory);
    const uint64_t sequence = __atomic_fetch_add(&header->next_sequence, 8, __ATOMIC_RELAXED);
    uint32_t slot = 0;
    SlotMetadata* meta = nullptr;
    bool replaced_ready_frame = false;
    bool notification_already_pending = false;
    uint64_t notification_sequence = sequence;

    // Call preview and remote-render frames are a real-time mailbox, not a
    // playback queue. If an unread frame for the same stream is still ready,
    // atomically replace it while preserving the original notification token.
    // One already queued IPC wake-up can therefore deliver the newest frame
    // without accumulating stale events. Recorder frames deliberately opt out
    // because every captured frame must reach the writer in order.
    if (latest_frame_wins) {
        for (uint32_t candidate = 0; candidate < kVideoRingSlotCount; ++candidate) {
            SlotMetadata* candidate_meta = metadata(memory, candidate);
            const uint64_t candidate_state = __atomic_load_n(
                &candidate_meta->state_token,
                __ATOMIC_ACQUIRE);
            if ((candidate_state & kSlotStateMask) != kSlotReady) continue;
            const uint64_t candidate_notification_sequence =
                state_notification_sequence(candidate_state);
            if (candidate_notification_sequence == 0) continue;

            // Metadata published under this exact token stays immutable until
            // either the reader or this replacement claims candidate_state.
            // Including the token in the CAS prevents foreign-slot and ABA
            // claims when another stream reuses the same slot.
            const bool same_stream =
                __atomic_load_n(
                    &candidate_meta->session_id,
                    __ATOMIC_ACQUIRE) == session_id &&
                __atomic_load_n(
                    &candidate_meta->generation,
                    __ATOMIC_ACQUIRE) == generation &&
                __atomic_load_n(
                    &candidate_meta->kind,
                    __ATOMIC_ACQUIRE) == static_cast<uint32_t>(kind) &&
                __atomic_load_n(
                    &candidate_meta->notification_sequence,
                    __ATOMIC_ACQUIRE) == candidate_notification_sequence;
            if (!same_stream) continue;

            uint64_t expected_state = candidate_state;
            if (!__atomic_compare_exchange_n(
                    &candidate_meta->state_token,
                    &expected_state,
                    slot_state(candidate_notification_sequence, kSlotReplacing),
                    false,
                    __ATOMIC_ACQ_REL,
                    __ATOMIC_RELAXED)) {
                continue;
            }
            slot = candidate;
            meta = candidate_meta;
            replaced_ready_frame = true;
            notification_sequence = candidate_notification_sequence;
            break;
        }
    }

    if (meta == nullptr) {
        for (uint32_t attempt = 0; attempt < kVideoRingSlotCount; ++attempt) {
            const uint32_t candidate = static_cast<uint32_t>(
                ((sequence / 8) + attempt) % kVideoRingSlotCount);
            SlotMetadata* candidate_meta = metadata(memory, candidate);
            uint64_t expected_state = kSlotFree;
            if (__atomic_compare_exchange_n(
                    &candidate_meta->state_token,
                    &expected_state,
                    slot_state(sequence, kSlotWritingNew),
                    false,
                    __ATOMIC_ACQUIRE,
                    __ATOMIC_RELAXED)) {
                slot = candidate;
                meta = candidate_meta;
                break;
            }
        }
    }
    if (meta == nullptr) return false;
#if defined(DINOX_WEBRTC_VIDEO_RING_TESTING)
    if (replaced_ready_frame && g_replacement_test_hook != nullptr) {
        g_replacement_test_hook(g_replacement_test_hook_data);
    }
#endif
    __atomic_store_n(&meta->sequence, sequence | 1u, __ATOMIC_RELEASE);
    __atomic_store_n(
        &meta->notification_sequence,
        notification_sequence,
        __ATOMIC_RELAXED);
    __atomic_store_n(&meta->session_id, session_id, __ATOMIC_RELAXED);
    __atomic_store_n(&meta->generation, generation, __ATOMIC_RELAXED);
    meta->frame_id = frame_id;
    __atomic_store_n(
        &meta->kind,
        static_cast<uint32_t>(kind),
        __ATOMIC_RELAXED);
    meta->width = static_cast<uint32_t>(width);
    meta->height = static_cast<uint32_t>(height);
    meta->stride = static_cast<uint32_t>(stride);
    meta->data_size = static_cast<uint32_t>(data_size_64);
    meta->pixel_format = 1;  // BGRA8
    std::memcpy(pixels(memory, slot), bgra_data, static_cast<size_t>(data_size_64));
    __atomic_store_n(&meta->sequence, sequence, __ATOMIC_RELEASE);
    // Keep the slot owned by this event until the proxy has copied the frame.
    // A replacement normally reuses the already pending wake-up. If the proxy
    // consumed that wake-up while this slot was WRITING, publish the new frame
    // under its own token and let the worker send exactly one follow-up event.
    if (replaced_ready_frame) {
        uint64_t expected = slot_state(notification_sequence, kSlotReplacing);
        if (__atomic_compare_exchange_n(
                &meta->state_token,
                &expected,
                slot_state(notification_sequence, kSlotReady),
                false,
                __ATOMIC_RELEASE,
                __ATOMIC_RELAXED)) {
            notification_already_pending = true;
        } else if (expected == slot_state(
                notification_sequence,
                kSlotReplacingNotificationConsumed)) {
            notification_sequence = sequence;
            __atomic_store_n(
                &meta->notification_sequence,
                notification_sequence,
                __ATOMIC_RELAXED);
            __atomic_store_n(
                &meta->state_token,
                slot_state(notification_sequence, kSlotReady),
                __ATOMIC_RELEASE);
        } else if (expected == slot_state(
                notification_sequence,
                kSlotReplacingNotificationDiscarded)) {
            // The proxy deliberately discarded the outstanding event while
            // this replacement was being copied (closed session, callback
            // fence, or missing consumer). Do not resurrect it with a new
            // notification.
            __atomic_store_n(&meta->state_token, kSlotFree, __ATOMIC_RELEASE);
            return false;
        } else {
            return false;
        }
    } else {
        __atomic_store_n(
            &meta->state_token,
            slot_state(notification_sequence, kSlotReady),
            __ATOMIC_RELEASE);
    }
    *out_slot = slot;
    *out_notification_sequence = notification_sequence;
    if (out_replaced_ready_frame != nullptr) {
        *out_replaced_ready_frame = replaced_ready_frame;
    }
    if (out_notification_already_pending != nullptr) {
        *out_notification_already_pending = notification_already_pending;
    }
    return true;
}

bool read_video_ring_frame(
    const void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence,
    uint64_t expected_session_id,
    uint64_t expected_generation,
    VideoFrameKind expected_kind,
    VideoFrame* out_frame) {
    if (!valid_ring(memory, size) || slot >= kVideoRingSlotCount || sequence == 0 ||
            (sequence & kSlotStateMask) != 0 || out_frame == nullptr) {
        return false;
    }
    SlotMetadata* meta = metadata(const_cast<void*>(memory), slot);
    const NotificationClaim claim = claim_notification(meta, sequence);
    if (claim != NotificationClaim::Ready) {
        return false;
    }
    const uint64_t before = __atomic_load_n(&meta->sequence, __ATOMIC_ACQUIRE);
    if (__atomic_load_n(
            &meta->notification_sequence,
            __ATOMIC_ACQUIRE) != sequence) {
        // state_token was claimed with this exact sequence, so disagreement
        // here is corrupt metadata rather than a valid foreign wake-up.
        __atomic_store_n(&meta->state_token, kSlotFree, __ATOMIC_RELEASE);
        return false;
    }
    const bool metadata_valid = valid_frame_metadata(
        meta, before, sequence, expected_session_id, expected_generation, expected_kind);
    VideoFrame frame;
    if (metadata_valid) {
        frame.session_id = __atomic_load_n(&meta->session_id, __ATOMIC_ACQUIRE);
        frame.generation = __atomic_load_n(&meta->generation, __ATOMIC_ACQUIRE);
        frame.frame_id = meta->frame_id;
        frame.sequence = before;
        frame.kind = expected_kind;
        frame.width = static_cast<int>(meta->width);
        frame.height = static_cast<int>(meta->height);
        frame.stride = static_cast<int>(meta->stride);
        frame.pixels.assign(pixels(memory, slot), pixels(memory, slot) + meta->data_size);
    }
    const uint64_t after = __atomic_load_n(&meta->sequence, __ATOMIC_ACQUIRE);
    __atomic_store_n(&meta->state_token, kSlotFree, __ATOMIC_RELEASE);
    if (!metadata_valid || after != before) return false;
    *out_frame = std::move(frame);
    return true;
}

bool with_video_ring_frame_view(
    const void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence,
    uint64_t expected_session_id,
    uint64_t expected_generation,
    VideoFrameKind expected_kind,
    VideoFrameViewCallback callback,
    void* user_data) {
    if (!valid_ring(memory, size) || slot >= kVideoRingSlotCount || sequence == 0 ||
            (sequence & kSlotStateMask) != 0 || callback == nullptr) {
        return false;
    }

    SlotMetadata* meta = metadata(const_cast<void*>(memory), slot);
    const NotificationClaim claim = claim_notification(meta, sequence);
    if (claim != NotificationClaim::Ready) {
        return false;
    }
    SlotReadGuard read_guard(meta);

    const uint64_t before = __atomic_load_n(&meta->sequence, __ATOMIC_ACQUIRE);
    if (__atomic_load_n(
            &meta->notification_sequence,
            __ATOMIC_ACQUIRE) != sequence) {
        // An exact state-token claim cannot race a different wake-up. Let the
        // guard free corrupt metadata instead of stranding the slot.
        return false;
    }
    if (!valid_frame_metadata(
            meta, before, sequence,
            expected_session_id, expected_generation, expected_kind)) {
        return false;
    }

    VideoFrameView frame;
    frame.session_id = __atomic_load_n(&meta->session_id, __ATOMIC_ACQUIRE);
    frame.generation = __atomic_load_n(&meta->generation, __ATOMIC_ACQUIRE);
    frame.frame_id = meta->frame_id;
    frame.sequence = before;
    frame.kind = expected_kind;
    frame.width = static_cast<int>(meta->width);
    frame.height = static_cast<int>(meta->height);
    frame.stride = static_cast<int>(meta->stride);
    frame.pixels = pixels(memory, slot);
    frame.data_size = static_cast<size_t>(meta->data_size);

    callback(&frame, user_data);
    return __atomic_load_n(&meta->sequence, __ATOMIC_ACQUIRE) == before;
}

bool discard_video_ring_frame(
    void* memory,
    size_t size,
    uint32_t slot,
    uint64_t sequence) {
    if (!valid_ring(memory, size) || slot >= kVideoRingSlotCount || sequence == 0 ||
            (sequence & kSlotStateMask) != 0) {
        return false;
    }
    SlotMetadata* meta = metadata(memory, slot);
    const NotificationClaim claim = claim_notification(meta, sequence, true);
    if (claim == NotificationClaim::ReplacementInProgress) return true;
    if (claim != NotificationClaim::Ready) return false;
    const bool matches = __atomic_load_n(
        &meta->notification_sequence,
        __ATOMIC_ACQUIRE) == sequence;
    __atomic_store_n(&meta->state_token, kSlotFree, __ATOMIC_RELEASE);
    return matches;
}

#if defined(DINOX_WEBRTC_VIDEO_RING_TESTING)
void set_video_ring_replacement_test_hook(
    VideoRingReplacementTestHook hook,
    void* user_data) {
    g_replacement_test_hook_data = user_data;
    g_replacement_test_hook = hook;
}
#endif

}  // namespace dinox::webrtc_worker
