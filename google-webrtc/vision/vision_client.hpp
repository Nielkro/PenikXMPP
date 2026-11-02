#ifndef DINOX_VISION_CLIENT_HPP
#define DINOX_VISION_CLIENT_HPP

// SDK-independent local transport foundation, not a runtime capability. One
// owner belongs to one logical outgoing pipeline, never to each MUJI peer.
#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include "face_decoder.hpp"
#include "vision_protocol.hpp"

namespace dinox::vision {

struct VisionBinding {
    // Unique positive logical-call lease; the controller must never reuse it.
    uint64_t call_lease = 0;
    // Monotonically increasing per call, independently of publication tokens.
    uint64_t source_generation = 0;
    // Local publication token: never substituted for source_generation on wire.
    uint64_t publication_source_id = 0;
    uint64_t config_revision = 0;
    // Identifies the exact immutable dims/rotation/mirror/contentRect context.
    uint64_t transform_id = 0;
    uint32_t demand = 0;
    bool operator==(const VisionBinding&) const = default;
};

struct ContentRect {
    uint32_t x = 0, y = 0, width = 0, height = 0;
    bool operator==(const ContentRect&) const = default;
};

struct VisionFrame {
    uint64_t frame_id = 0; // original camera counter, independent of wire ticket
    uint64_t media_timestamp_ns = 0; // not the age clock
    uint64_t captured_monotonic_ns = 0;
    uint32_t width = 0, height = 0, rotation = 0;
    bool mirrored = false;
    ContentRect segment_content{0, 0, 256, 144};
    ContentRect face_content{0, 0, 128, 128};
    bool operator==(const VisionFrame&) const = default;
};

struct SampleTicket {
    uint64_t nonce = 0;
    uint64_t logical_epoch = 0;
    VisionBinding binding;
    VisionFrame frame;
    bool operator==(const SampleTicket&) const = default;
};

struct VisionResult {
    VisionBinding binding;
    VisionFrame frame;
    uint64_t wire_ticket_id = 0;
    std::vector<uint8_t> mask; // empty or exactly 256*144, including letterbox
    std::optional<Face> face; // absent is a valid tracking loss
};

enum class ClientFault { None, Start, Transport, Deadline, Protocol, TicketOverflow };

struct VisionClientOptions {
    // Trusted installation/controller paths only, never image/frame inputs.
    std::string worker_executable;
    std::string segmentation_model;
    std::string face_model;
    uint32_t sample_fps = 10; // bounded 1..30; guard runs before RGB conversion
    uint32_t io_timeout_ms = 500; // bounded 50..2000; result age always <=500ms
};

struct VisionClientSnapshot {
    bool configured = false, camera_enabled = false, closed = false;
    bool process_active = false, outstanding = false, pending = false;
    bool quiescing = false, quarantined = false, faulted = false;
    // Selected SEG remains unavailable on errors; privacy must never be based
    // on process_active/faulted. The future raw-exit guard also checks BG config.
    bool segmentation_unavailable = false;
    ClientFault fault = ClientFault::None;
    uint64_t logical_epoch = 0;
    uint64_t process_starts = 0, process_exits = 0;
    uint64_t submitted = 0, pending_replaced = 0, completed = 0, discarded = 0;
    size_t owned_rgb_bytes = 0, cached_mask_bytes = 0;
};

class VisionClient final {
 public:
    static std::unique_ptr<VisionClient> create(VisionClientOptions options);
    static uint64_t monotonic_now_ns();
    ~VisionClient();
    VisionClient(const VisionClient&) = delete;
    VisionClient& operator=(const VisionClient&) = delete;

    // No process operations under the state lock or on the caller thread.
    // Logical changes invalidate cache/tickets/pending synchronously. Healthy
    // in-flight work finishes and is discarded; model processes survive slider,
    // transform/source/demand changes. Off/cameraOff/call change stops the child.
    // demand0 and nullopt both mean Off. Faults are latched through logical
    // changes; an explicit Off/cameraOff/new-call cycle permits recovery.
    bool set_binding(std::optional<VisionBinding> binding, bool camera_enabled = true);
    std::optional<SampleTicket> reserve_sample(const VisionFrame& frame, uint64_t now_ns);
    bool submit(const SampleTicket& ticket, std::span<const uint8_t> segment_rgb,
        std::span<const uint8_t> face_rgb, uint64_t now_ns);
    void abandon(const SampleTicket& ticket);
    std::shared_ptr<const VisionResult> result_for(const VisionBinding& binding,
        const VisionFrame& desired, uint64_t now_ns) const;
    bool cache_unavailable(uint64_t now_ns) const;
    VisionClientSnapshot snapshot() const;

    // Nonblocking, irreversible. Destructor calls close and hands the shared
    // state to its I/O guardian without waiting on UI/capture/audio threads.
    void close();
    // Only a designated controller/tests may wait, always with a finite bound.
    // True means no live child or outstanding pipe access, not merely cancel queued.
    bool wait_quiescent(std::chrono::milliseconds timeout) const;

 private:
    struct State;
    explicit VisionClient(std::shared_ptr<State> state);
    static void run(const std::shared_ptr<State>& state);
    std::shared_ptr<State> state_;
    std::thread io_thread_;
};

} // namespace dinox::vision
#endif
