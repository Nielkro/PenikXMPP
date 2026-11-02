#include "dinox_webrtc_video_ring.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#define DINOX_CHECK(expression) do { \
    if (!(expression)) { \
        std::fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expression); \
        std::exit(1); \
    } \
} while (0)

namespace {

struct ReplacementBarrier {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false;
    bool released = false;
};

void replacement_barrier_hook(void* user_data) {
    auto* barrier = static_cast<ReplacementBarrier*>(user_data);
    DINOX_CHECK(barrier != nullptr);
    std::unique_lock<std::mutex> lock(barrier->mutex);
    barrier->entered = true;
    barrier->condition.notify_one();
    barrier->condition.wait(lock, [&] { return barrier->released; });
}

void wait_for_replacement(ReplacementBarrier* barrier) {
    std::unique_lock<std::mutex> lock(barrier->mutex);
    DINOX_CHECK(barrier->condition.wait_for(
        lock, std::chrono::seconds(5), [&] { return barrier->entered; }));
}

void release_replacement(ReplacementBarrier* barrier) {
    std::lock_guard<std::mutex> lock(barrier->mutex);
    barrier->released = true;
    barrier->condition.notify_one();
}

}  // namespace

int main() {
    using namespace dinox::webrtc_worker;
    static_assert(kVideoRingSlotCount >= 5);
    DINOX_CHECK(video_ring_size() <= 80u * 1024u * 1024u);
    std::vector<uint8_t> ring(video_ring_size());
    DINOX_CHECK(initialize_video_ring(ring.data(), ring.size()));

    constexpr int width = 160;
    constexpr int height = 120;
    constexpr int stride = width * 4;
    std::vector<uint8_t> pixels(static_cast<size_t>(stride) * height, 7);
    uint32_t slot = 0;
    uint64_t sequence = 0;
    bool ignored_notification_pending = false;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 11, 3, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 7, true, &slot, &sequence,
        nullptr, &ignored_notification_pending));
    VideoFrame frame;
    DINOX_CHECK(read_video_ring_frame(
        ring.data(), ring.size(), slot, sequence, 11, 3,
        VideoFrameKind::Remote, &frame));
    DINOX_CHECK(frame.frame_id == 7 && frame.pixels == pixels);
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), slot, sequence, 11, 4,
        VideoFrameKind::Remote, &frame));

    // Monal can send a 1344x1792 portrait frame.  Checking only the independent
    // width/height limits is insufficient: the shared-memory slot must hold the
    // complete stride*height payload as well.
    constexpr int portrait_width = 1344;
    constexpr int portrait_height = 1792;
    constexpr int portrait_stride = portrait_width * 4;
    std::vector<uint8_t> portrait_pixels(
        static_cast<size_t>(portrait_stride) * portrait_height, 23);
    uint32_t portrait_slot = 0;
    uint64_t portrait_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 12, 4, VideoFrameKind::Remote,
        portrait_pixels.data(), portrait_width, portrait_height,
        portrait_stride, 1, true, &portrait_slot, &portrait_sequence,
        nullptr, &ignored_notification_pending));
    VideoFrame portrait_frame;
    DINOX_CHECK(read_video_ring_frame(
        ring.data(), ring.size(), portrait_slot, portrait_sequence, 12, 4,
        VideoFrameKind::Remote, &portrait_frame));
    DINOX_CHECK(portrait_frame.width == portrait_width &&
        portrait_frame.height == portrait_height &&
        portrait_frame.pixels == portrait_pixels);

    // Recorder frames are ordered and must not replace unread frames. Fill
    // every slot and prove that the next recorder frame is backpressured.
    uint32_t held_slots[kVideoRingSlotCount] = {};
    uint64_t held_sequences[kVideoRingSlotCount] = {};
    for (uint32_t index = 0; index < kVideoRingSlotCount; ++index) {
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), 21, 5, VideoFrameKind::Recorder,
            pixels.data(), width, height, stride, 100 + index,
            false, &held_slots[index], &held_sequences[index]));
    }
    uint32_t blocked_slot = 0;
    uint64_t blocked_sequence = 0;
    DINOX_CHECK(!write_video_ring_frame(
        ring.data(), ring.size(), 21, 5, VideoFrameKind::Recorder,
        pixels.data(), width, height, stride, 200,
        false, &blocked_slot, &blocked_sequence));
    for (uint32_t index = 0; index < kVideoRingSlotCount; ++index) {
        VideoFrame held_frame;
        DINOX_CHECK(read_video_ring_frame(
            ring.data(), ring.size(), held_slots[index], held_sequences[index],
            21, 5, VideoFrameKind::Recorder, &held_frame));
        DINOX_CHECK(held_frame.frame_id == 100 + index);
    }

    uint32_t discarded_slot = 0;
    uint64_t discarded_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 22, 6, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 300,
        true, &discarded_slot, &discarded_sequence,
        nullptr, &ignored_notification_pending));
    DINOX_CHECK(discard_video_ring_frame(
        ring.data(), ring.size(), discarded_slot, discarded_sequence));
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), discarded_slot, discarded_sequence,
        22, 6, VideoFrameKind::Remote, &frame));

    // Live call video is a mailbox. Many newer unread frames replace the same
    // slot while preserving one notification token. A worker therefore needs
    // to queue exactly one wake-up, and that wake-up must consume the newest
    // frame instead of chasing one stale event per replacement.
    uint32_t mailbox_slot = 0;
    uint64_t mailbox_sequence = 0;
    bool mailbox_replaced = false;
    bool mailbox_notification_pending = false;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 31, 7, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 400, true,
        &mailbox_slot, &mailbox_sequence, &mailbox_replaced,
        &mailbox_notification_pending));
    DINOX_CHECK(!mailbox_replaced && !mailbox_notification_pending);
    std::vector<uint8_t> newest_pixels(pixels.size(), 91);
    uint32_t newest_slot = 0;
    uint64_t newest_sequence = 0;
    unsigned int notification_count = 1;
    for (uint64_t frame_id = 401; frame_id <= 656; ++frame_id) {
        std::fill(
            newest_pixels.begin(), newest_pixels.end(),
            static_cast<uint8_t>(frame_id & 0xffu));
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), 31, 7, VideoFrameKind::Remote,
            newest_pixels.data(), width, height, stride, frame_id, true,
            &newest_slot, &newest_sequence, &mailbox_replaced,
            &mailbox_notification_pending));
        if (!mailbox_notification_pending) ++notification_count;
        DINOX_CHECK(mailbox_replaced && mailbox_notification_pending &&
            newest_slot == mailbox_slot);
        DINOX_CHECK(newest_sequence == mailbox_sequence);
    }
    DINOX_CHECK(notification_count == 1);
    DINOX_CHECK(read_video_ring_frame(
        ring.data(), ring.size(), mailbox_slot, mailbox_sequence,
        31, 7, VideoFrameKind::Remote, &frame));
    DINOX_CHECK(frame.frame_id == 656 && frame.pixels == newest_pixels);
    DINOX_CHECK(frame.sequence != mailbox_sequence);
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), newest_slot, newest_sequence,
        31, 7, VideoFrameKind::Remote, &frame));

    // Local preview and remote render share the product ring. Under sustained
    // dual-stream pressure each stream retains one wake-up regardless of how
    // many frames replace its READY slot. This is the bounded contract used by
    // worker_main instead of queuing one stale pipe event per captured frame.
    struct MailboxNotification {
        uint32_t slot = 0;
        uint64_t sequence = 0;
        VideoFrameKind kind = VideoFrameKind::Remote;
    };
    std::vector<MailboxNotification> mailbox_notifications;
    uint64_t last_local_frame_id = 0;
    uint64_t last_remote_frame_id = 0;
    for (uint64_t index = 0; index < 1024; ++index) {
        const VideoFrameKind kind = index % 2 == 0
            ? VideoFrameKind::Local : VideoFrameKind::Remote;
        const uint64_t frame_id = 1000 + index;
        std::fill(
            newest_pixels.begin(), newest_pixels.end(),
            static_cast<uint8_t>(frame_id & 0xffu));
        uint32_t dual_slot = 0;
        uint64_t dual_sequence = 0;
        bool dual_replaced = false;
        bool dual_notification_pending = false;
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), 33, 9, kind,
            newest_pixels.data(), width, height, stride, frame_id, true,
            &dual_slot, &dual_sequence, &dual_replaced,
            &dual_notification_pending));
        if (!dual_notification_pending) {
            mailbox_notifications.push_back({dual_slot, dual_sequence, kind});
        }
        DINOX_CHECK(dual_replaced == dual_notification_pending);
        if (kind == VideoFrameKind::Local) {
            last_local_frame_id = frame_id;
        } else {
            last_remote_frame_id = frame_id;
        }
        DINOX_CHECK(mailbox_notifications.size() <= 2);
    }
    DINOX_CHECK(mailbox_notifications.size() == 2);
    for (const MailboxNotification& notification : mailbox_notifications) {
        VideoFrame newest_dual_frame;
        DINOX_CHECK(read_video_ring_frame(
            ring.data(), ring.size(), notification.slot, notification.sequence,
            33, 9, notification.kind, &newest_dual_frame));
        DINOX_CHECK(newest_dual_frame.frame_id ==
            (notification.kind == VideoFrameKind::Local
                ? last_local_frame_id : last_remote_frame_id));
        const uint8_t expected = static_cast<uint8_t>(newest_dual_frame.frame_id & 0xffu);
        for (uint8_t value : newest_dual_frame.pixels) DINOX_CHECK(value == expected);
    }

    // A four-peer MUJI video call produces four independent remote-render
    // streams plus one local preview. Keep all five wake-ups pending while
    // every producer remains hot; each stream must retain its own latest frame
    // and the shared allocation remains bounded above.
    struct GroupMailbox {
        uint64_t session_id = 0;
        VideoFrameKind kind = VideoFrameKind::Remote;
        uint32_t slot = 0;
        uint64_t notification_sequence = 0;
        uint64_t last_frame_id = 0;
    };
    std::array<GroupMailbox, 5> group_mailboxes = {{
        {101, VideoFrameKind::Remote},
        {102, VideoFrameKind::Remote},
        {103, VideoFrameKind::Remote},
        {104, VideoFrameKind::Remote},
        {105, VideoFrameKind::Local},
    }};
    for (GroupMailbox& stream : group_mailboxes) {
        bool replaced = false;
        bool notification_pending = false;
        stream.last_frame_id = stream.session_id * 1000;
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), stream.session_id, 12, stream.kind,
            pixels.data(), width, height, stride, stream.last_frame_id, true,
            &stream.slot, &stream.notification_sequence,
            &replaced, &notification_pending));
        DINOX_CHECK(!replaced && !notification_pending);
    }
    for (uint64_t round = 1; round <= 512; ++round) {
        for (GroupMailbox& stream : group_mailboxes) {
            uint32_t slot = 0;
            uint64_t notification_sequence = 0;
            bool replaced = false;
            bool notification_pending = false;
            stream.last_frame_id = stream.session_id * 1000 + round;
            DINOX_CHECK(write_video_ring_frame(
                ring.data(), ring.size(), stream.session_id, 12, stream.kind,
                newest_pixels.data(), width, height, stride,
                stream.last_frame_id, true, &slot, &notification_sequence,
                &replaced, &notification_pending));
            DINOX_CHECK(replaced && notification_pending);
            DINOX_CHECK(slot == stream.slot);
            DINOX_CHECK(notification_sequence == stream.notification_sequence);
        }
    }
    for (const GroupMailbox& stream : group_mailboxes) {
        VideoFrame newest_group_frame;
        DINOX_CHECK(read_video_ring_frame(
            ring.data(), ring.size(), stream.slot, stream.notification_sequence,
            stream.session_id, 12, stream.kind, &newest_group_frame));
        DINOX_CHECK(newest_group_frame.frame_id == stream.last_frame_id);
    }

    uint32_t stale_discard_slot = 0;
    uint64_t stale_discard_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 32, 8, VideoFrameKind::Local,
        pixels.data(), width, height, stride, 500, true,
        &stale_discard_slot, &stale_discard_sequence,
        nullptr, &ignored_notification_pending));
    uint32_t replacement_discard_slot = 0;
    uint64_t replacement_discard_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 32, 8, VideoFrameKind::Local,
        newest_pixels.data(), width, height, stride, 501, true,
        &replacement_discard_slot, &replacement_discard_sequence,
        &mailbox_replaced, &mailbox_notification_pending));
    DINOX_CHECK(mailbox_replaced && mailbox_notification_pending &&
        replacement_discard_slot == stale_discard_slot);
    DINOX_CHECK(replacement_discard_sequence == stale_discard_sequence);
    DINOX_CHECK(discard_video_ring_frame(
        ring.data(), ring.size(), stale_discard_slot, stale_discard_sequence));
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), replacement_discard_slot,
        replacement_discard_sequence, 32, 8, VideoFrameKind::Local, &frame));

    // Deterministically consume the only pending wake-up after the producer
    // has claimed READY -> REPLACING but before it publishes the new pixels.
    // The writer must then mint exactly one follow-up token for the new frame.
    uint32_t consumed_slot = 0;
    uint64_t consumed_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 34, 10, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 700, true,
        &consumed_slot, &consumed_sequence,
        nullptr, &ignored_notification_pending));
    ReplacementBarrier consumed_barrier;
    set_video_ring_replacement_test_hook(
        replacement_barrier_hook, &consumed_barrier);
    bool consumed_write_succeeded = false;
    bool consumed_replaced = false;
    bool consumed_notification_pending = true;
    uint32_t consumed_followup_slot = 0;
    uint64_t consumed_followup_sequence = 0;
    std::thread consumed_writer([&] {
        consumed_write_succeeded = write_video_ring_frame(
            ring.data(), ring.size(), 34, 10, VideoFrameKind::Remote,
            newest_pixels.data(), width, height, stride, 701, true,
            &consumed_followup_slot, &consumed_followup_sequence,
            &consumed_replaced, &consumed_notification_pending);
    });
    wait_for_replacement(&consumed_barrier);
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), consumed_slot, consumed_sequence,
        34, 10, VideoFrameKind::Remote, &frame));
    release_replacement(&consumed_barrier);
    consumed_writer.join();
    set_video_ring_replacement_test_hook(nullptr, nullptr);
    DINOX_CHECK(consumed_write_succeeded && consumed_replaced &&
        !consumed_notification_pending);
    DINOX_CHECK(consumed_followup_slot == consumed_slot &&
        consumed_followup_sequence != consumed_sequence);
    DINOX_CHECK(read_video_ring_frame(
        ring.data(), ring.size(), consumed_followup_slot,
        consumed_followup_sequence, 34, 10, VideoFrameKind::Remote, &frame));
    DINOX_CHECK(frame.frame_id == 701 && frame.pixels == newest_pixels);

    // Deterministically discard that wake-up in the same replacement window.
    // A closing proxy must free the slot and the writer must not resurrect the
    // replacement or ask the worker to queue a follow-up event.
    uint32_t closing_slot = 0;
    uint64_t closing_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 35, 11, VideoFrameKind::Local,
        pixels.data(), width, height, stride, 710, true,
        &closing_slot, &closing_sequence,
        nullptr, &ignored_notification_pending));
    ReplacementBarrier discard_barrier;
    set_video_ring_replacement_test_hook(
        replacement_barrier_hook, &discard_barrier);
    bool discarded_write_succeeded = true;
    uint32_t discarded_followup_slot = 0;
    uint64_t discarded_followup_sequence = 0;
    std::thread discarded_writer([&] {
        bool replacement = false;
        bool notification_pending = false;
        discarded_write_succeeded = write_video_ring_frame(
            ring.data(), ring.size(), 35, 11, VideoFrameKind::Local,
            newest_pixels.data(), width, height, stride, 711, true,
            &discarded_followup_slot, &discarded_followup_sequence,
            &replacement, &notification_pending);
    });
    wait_for_replacement(&discard_barrier);
    DINOX_CHECK(discard_video_ring_frame(
        ring.data(), ring.size(), closing_slot, closing_sequence));
    release_replacement(&discard_barrier);
    discarded_writer.join();
    set_video_ring_replacement_test_hook(nullptr, nullptr);
    DINOX_CHECK(!discarded_write_succeeded);
    DINOX_CHECK(!read_video_ring_frame(
        ring.data(), ring.size(), closing_slot, closing_sequence,
        35, 11, VideoFrameKind::Local, &frame));

    // A borrowed view keeps its slot in READING state for the whole
    // synchronous callback.  Fill the other slots so re-entrant reads,
    // discards and ordered writes can prove that this slot is not released
    // until the callback returns.
    uint32_t view_slot = 0;
    uint64_t view_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 41, 9, VideoFrameKind::Local,
        newest_pixels.data(), width, height, stride, 600, true,
        &view_slot, &view_sequence, nullptr, &ignored_notification_pending));
    uint32_t view_held_slots[kVideoRingSlotCount - 1] = {};
    uint64_t view_held_sequences[kVideoRingSlotCount - 1] = {};
    for (uint32_t index = 0; index < kVideoRingSlotCount - 1; ++index) {
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), 42, 10, VideoFrameKind::Recorder,
            pixels.data(), width, height, stride, 610 + index, false,
            &view_held_slots[index], &view_held_sequences[index]));
    }
    struct ViewCallbackContext {
        void* ring = nullptr;
        size_t ring_size = 0;
        uint32_t slot = 0;
        uint64_t sequence = 0;
        const std::vector<uint8_t>* expected_pixels = nullptr;
        std::vector<uint8_t> snapshot;
        const uint8_t* borrowed_pointer = nullptr;
        bool active = false;
        bool called = false;
    } view_context = {
        ring.data(), ring.size(), view_slot, view_sequence, &newest_pixels,
    };
    const auto inspect_view = [] (const VideoFrameView* view, void* user_data) {
        auto* context = static_cast<ViewCallbackContext*>(user_data);
        DINOX_CHECK(context != nullptr && view != nullptr && !context->active);
        context->active = true;
        context->called = true;
        context->borrowed_pointer = view->pixels;
        DINOX_CHECK(view->session_id == 41 && view->generation == 9);
        DINOX_CHECK(view->frame_id == 600 && view->sequence == context->sequence);
        DINOX_CHECK(view->kind == VideoFrameKind::Local);
        DINOX_CHECK(view->width == width && view->height == height && view->stride == stride);
        DINOX_CHECK(view->pixels != nullptr &&
            view->data_size == context->expected_pixels->size());
        DINOX_CHECK(std::equal(
            view->pixels,
            view->pixels + view->data_size,
            context->expected_pixels->begin()));

        VideoFrame nested_frame;
        DINOX_CHECK(!read_video_ring_frame(
            context->ring, context->ring_size, context->slot, context->sequence,
            41, 9, VideoFrameKind::Local, &nested_frame));
        DINOX_CHECK(!discard_video_ring_frame(
            context->ring, context->ring_size, context->slot, context->sequence));
        uint32_t blocked_view_slot = 0;
        uint64_t blocked_view_sequence = 0;
        DINOX_CHECK(!write_video_ring_frame(
            context->ring, context->ring_size, 42, 10, VideoFrameKind::Recorder,
            context->expected_pixels->data(), width, height, stride, 620, false,
            &blocked_view_slot, &blocked_view_sequence));

        context->snapshot.assign(view->pixels, view->pixels + view->data_size);
        context->active = false;
    };
    DINOX_CHECK(with_video_ring_frame_view(
        ring.data(), ring.size(), view_slot, view_sequence, 41, 9,
        VideoFrameKind::Local, inspect_view, &view_context));
    DINOX_CHECK(view_context.called && !view_context.active);
    DINOX_CHECK(view_context.borrowed_pointer != nullptr);
    DINOX_CHECK(view_context.snapshot == newest_pixels);

    // Returning from the callback releases precisely the viewed slot.
    uint32_t post_view_slot = 0;
    uint64_t post_view_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 42, 10, VideoFrameKind::Recorder,
        pixels.data(), width, height, stride, 620, false,
        &post_view_slot, &post_view_sequence));
    DINOX_CHECK(post_view_slot == view_slot);
    VideoFrame post_view_frame;
    DINOX_CHECK(read_video_ring_frame(
        ring.data(), ring.size(), post_view_slot, post_view_sequence,
        42, 10, VideoFrameKind::Recorder, &post_view_frame));
    for (uint32_t index = 0; index < kVideoRingSlotCount - 1; ++index) {
        VideoFrame held_frame;
        DINOX_CHECK(read_video_ring_frame(
            ring.data(), ring.size(), view_held_slots[index], view_held_sequences[index],
            42, 10, VideoFrameKind::Recorder, &held_frame));
        DINOX_CHECK(held_frame.frame_id == 610 + index);
    }

    // A mailbox wake-up keeps its notification token across replacements and
    // the borrowed view consumes the newest frame exactly once.
    uint32_t stale_view_slot = 0;
    uint64_t stale_view_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 43, 11, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 700, true,
        &stale_view_slot, &stale_view_sequence,
        nullptr, &ignored_notification_pending));
    uint32_t newest_view_slot = 0;
    uint64_t newest_view_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 43, 11, VideoFrameKind::Remote,
        newest_pixels.data(), width, height, stride, 701, true,
        &newest_view_slot, &newest_view_sequence, &mailbox_replaced,
        &mailbox_notification_pending));
    DINOX_CHECK(mailbox_replaced && mailbox_notification_pending &&
        newest_view_slot == stale_view_slot);
    DINOX_CHECK(newest_view_sequence == stale_view_sequence);
    struct CountViewContext {
        unsigned int calls = 0;
        uint64_t frame_id = 0;
        std::vector<uint8_t> snapshot;
    } count_view_context;
    const auto count_view = [] (const VideoFrameView* view, void* user_data) {
        auto* context = static_cast<CountViewContext*>(user_data);
        DINOX_CHECK(context != nullptr && view != nullptr);
        ++context->calls;
        context->frame_id = view->frame_id;
        context->snapshot.assign(view->pixels, view->pixels + view->data_size);
    };
    DINOX_CHECK(with_video_ring_frame_view(
        ring.data(), ring.size(), stale_view_slot, stale_view_sequence, 43, 11,
        VideoFrameKind::Remote, count_view, &count_view_context));
    DINOX_CHECK(count_view_context.calls == 1 && count_view_context.frame_id == 701);
    DINOX_CHECK(count_view_context.snapshot == newest_pixels);
    DINOX_CHECK(!with_video_ring_frame_view(
        ring.data(), ring.size(), newest_view_slot, newest_view_sequence, 43, 11,
        VideoFrameKind::Remote, count_view, &count_view_context));
    DINOX_CHECK(count_view_context.calls == 1 && count_view_context.frame_id == 701);
    DINOX_CHECK(count_view_context.snapshot == newest_pixels);

    // Invalid metadata is rejected before entering the consumer and still
    // releases the claimed slot so a producer cannot be wedged permanently.
    uint32_t invalid_view_slot = 0;
    uint64_t invalid_view_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 44, 12, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 800, true,
        &invalid_view_slot, &invalid_view_sequence,
        nullptr, &ignored_notification_pending));
    count_view_context = {};
    DINOX_CHECK(!with_video_ring_frame_view(
        ring.data(), ring.size(), invalid_view_slot, invalid_view_sequence, 44, 13,
        VideoFrameKind::Remote, count_view, &count_view_context));
    DINOX_CHECK(count_view_context.calls == 0);
    uint32_t recovered_slot = 0;
    uint64_t recovered_sequence = 0;
    DINOX_CHECK(write_video_ring_frame(
        ring.data(), ring.size(), 45, 13, VideoFrameKind::Remote,
        pixels.data(), width, height, stride, 801, true,
        &recovered_slot, &recovered_sequence,
        nullptr, &ignored_notification_pending));
    DINOX_CHECK(discard_video_ring_frame(
        ring.data(), ring.size(), recovered_slot, recovered_sequence));

    // Exercise the worker's real wake-up rule under concurrent Local/Remote
    // pressure. Producers enqueue only when no notification remains pending;
    // the single serial consumer reads exactly those tokens. At completion no
    // READY mailbox may remain stranded, even when a token races a replacement.
    struct QueuedNotification {
        uint32_t slot = 0;
        uint64_t sequence = 0;
        uint64_t session_id = 0;
        uint64_t generation = 0;
        VideoFrameKind kind = VideoFrameKind::Remote;
    };
    std::mutex notification_mutex;
    std::condition_variable notification_cv;
    std::deque<QueuedNotification> notification_queue;
    std::atomic<unsigned int> active_writers{2};
    std::atomic<unsigned int> delivered_local{0};
    std::atomic<unsigned int> delivered_remote{0};
    size_t max_notification_depth = 0;
    const auto mailbox_writer = [&] (
        uint64_t session_id,
        uint64_t generation,
        VideoFrameKind kind,
        uint64_t frame_base) {
        std::vector<uint8_t> source(static_cast<size_t>(stride) * height);
        for (uint64_t index = 0; index < 10000; ++index) {
            const uint64_t frame_id = frame_base + index;
            std::fill(source.begin(), source.end(), static_cast<uint8_t>(frame_id & 0xffu));
            uint32_t next_slot = 0;
            uint64_t next_sequence = 0;
            bool notification_pending = false;
            if (!write_video_ring_frame(
                    ring.data(), ring.size(), session_id, generation, kind,
                    source.data(), width, height, stride, frame_id, true,
                    &next_slot, &next_sequence, nullptr,
                    &notification_pending)) {
                std::this_thread::yield();
                continue;
            }
            if (!notification_pending) {
                {
                    std::lock_guard<std::mutex> lock(notification_mutex);
                    notification_queue.push_back({
                        next_slot, next_sequence, session_id, generation, kind,
                    });
                    max_notification_depth = std::max(
                        max_notification_depth, notification_queue.size());
                }
                notification_cv.notify_one();
            }
        }
        active_writers.fetch_sub(1, std::memory_order_release);
        notification_cv.notify_one();
    };
    std::thread local_mailbox_writer(
        mailbox_writer, 51, 13, VideoFrameKind::Local, 100000);
    std::thread remote_mailbox_writer(
        mailbox_writer, 52, 14, VideoFrameKind::Remote, 200000);
    std::thread notification_reader([&] {
        while (true) {
            QueuedNotification notification;
            {
                std::unique_lock<std::mutex> lock(notification_mutex);
                notification_cv.wait(lock, [&] {
                    return !notification_queue.empty() ||
                        active_writers.load(std::memory_order_acquire) == 0;
                });
                if (notification_queue.empty()) {
                    DINOX_CHECK(active_writers.load(std::memory_order_acquire) == 0);
                    break;
                }
                notification = notification_queue.front();
                notification_queue.pop_front();
            }
            VideoFrame candidate;
            if (!read_video_ring_frame(
                    ring.data(), ring.size(), notification.slot, notification.sequence,
                    notification.session_id, notification.generation,
                    notification.kind, &candidate)) {
                continue;
            }
            const uint8_t expected = static_cast<uint8_t>(candidate.frame_id & 0xffu);
            for (uint8_t value : candidate.pixels) DINOX_CHECK(value == expected);
            (candidate.kind == VideoFrameKind::Local
                ? delivered_local : delivered_remote).fetch_add(1, std::memory_order_relaxed);
        }
    });
    local_mailbox_writer.join();
    remote_mailbox_writer.join();
    notification_reader.join();
    DINOX_CHECK(max_notification_depth <= 2);
    DINOX_CHECK(delivered_local.load() > 0 && delivered_remote.load() > 0);

    // Four ordered writes prove that the concurrent mailbox run did not leave
    // an unread live slot without a corresponding wake-up.
    uint32_t closure_slots[kVideoRingSlotCount] = {};
    uint64_t closure_sequences[kVideoRingSlotCount] = {};
    for (uint32_t index = 0; index < kVideoRingSlotCount; ++index) {
        DINOX_CHECK(write_video_ring_frame(
            ring.data(), ring.size(), 53, 15, VideoFrameKind::Recorder,
            pixels.data(), width, height, stride, 300000 + index, false,
            &closure_slots[index], &closure_sequences[index]));
    }
    for (uint32_t index = 0; index < kVideoRingSlotCount; ++index) {
        DINOX_CHECK(discard_video_ring_frame(
            ring.data(), ring.size(), closure_slots[index], closure_sequences[index]));
    }

    std::atomic<uint32_t> latest_slot{slot};
    std::atomic<uint64_t> latest_sequence{sequence};
    std::atomic<bool> writer_done{false};
    std::atomic<unsigned int> successful_reads{0};
    std::thread writer([&] {
        std::vector<uint8_t> source(static_cast<size_t>(stride) * height);
        for (uint64_t frame_id = 8; frame_id < 10008; ++frame_id) {
            std::fill(source.begin(), source.end(), static_cast<uint8_t>(frame_id & 0xffu));
            uint32_t next_slot = 0;
            uint64_t next_sequence = 0;
            bool notification_pending = false;
            if (write_video_ring_frame(
                    ring.data(), ring.size(), 11, 3, VideoFrameKind::Remote,
                    source.data(), width, height, stride, frame_id,
                    true, &next_slot, &next_sequence,
                    nullptr, &notification_pending)) {
                latest_slot.store(next_slot, std::memory_order_release);
                latest_sequence.store(next_sequence, std::memory_order_release);
            }
        }
        writer_done.store(true, std::memory_order_release);
    });

    std::thread reader([&] {
        while (!writer_done.load(std::memory_order_acquire)) {
            VideoFrame candidate;
            const uint32_t current_slot = latest_slot.load(std::memory_order_acquire);
            const uint64_t current_sequence = latest_sequence.load(std::memory_order_acquire);
            if (!read_video_ring_frame(
                    ring.data(), ring.size(), current_slot, current_sequence,
                    11, 3, VideoFrameKind::Remote, &candidate)) {
                std::this_thread::yield();
                continue;
            }
            const uint8_t expected = static_cast<uint8_t>(candidate.frame_id & 0xffu);
            for (uint8_t value : candidate.pixels) DINOX_CHECK(value == expected);
            successful_reads.fetch_add(1, std::memory_order_relaxed);
        }
    });
    writer.join();
    reader.join();
    DINOX_CHECK(successful_reads.load() > 0);
    std::puts("Shared video ring concurrency smoke OK");
    return 0;
}
