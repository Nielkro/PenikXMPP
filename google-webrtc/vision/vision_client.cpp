#include "vision_client.hpp"
#include "vision_process.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <system_error>
#include <utility>

namespace dinox::vision {
namespace {
using process_detail::IoStatus;

bool valid_path(const std::string& path) {
    return path.size() <= 4096 && path.find('\0') == std::string::npos;
}

bool valid_binding(const VisionBinding& binding) {
    return binding.call_lease && binding.source_generation && binding.publication_source_id &&
        binding.config_revision && binding.transform_id && binding.demand <= 3;
}

bool valid_rect(const ContentRect& rect, uint32_t width, uint32_t height) {
    return rect.width && rect.height && rect.width <= width && rect.height <= height &&
        rect.x <= width - rect.width && rect.y <= height - rect.height;
}

bool valid_rgb(std::span<const uint8_t> bytes, size_t expected) {
    if (bytes.size() != expected) return false;
    if (!expected) return true;
    const auto address = reinterpret_cast<uintptr_t>(bytes.data());
    return address && expected <= std::numeric_limits<uintptr_t>::max() - address;
}

bool fresh(const VisionFrame& frame, uint64_t now_ns) {
    return frame.frame_id && frame.captured_monotonic_ns && frame.captured_monotonic_ns <= now_ns &&
        now_ns - frame.captured_monotonic_ns <= kMaxResultAgeNs;
}

bool same_geometry(const VisionFrame& a, const VisionFrame& b) {
    return a.width == b.width && a.height == b.height && a.rotation == b.rotation && a.mirrored == b.mirrored &&
        a.segment_content == b.segment_content && a.face_content == b.face_content;
}

void header32(Header& bytes, size_t offset, uint32_t value) {
    write32(bytes, offset, value);
}
void header64(Header& bytes, size_t offset, uint64_t value) {
    write64(bytes, offset, value);
}

Request make_request(const SampleTicket& ticket, uint64_t wire_id) {
    const auto& b = ticket.binding;
    const auto& f = ticket.frame;
    return {{b.call_lease, b.source_generation, b.config_revision, wire_id,
        f.captured_monotonic_ns, b.transform_id}, b.demand, f.width, f.height, f.rotation,
        f.mirrored, payload_size(b.demand)};
}

Header encode_request(const Request& request) {
    Header bytes{};
    header32(bytes, 0, kRequestMagic); header32(bytes, 4, kProtocolVersion);
    header32(bytes, 8, kHeaderBytes); header32(bytes, 12, static_cast<uint32_t>(kHeaderBytes + request.payload_bytes));
    header64(bytes, 16, request.token.call); header64(bytes, 24, request.token.source);
    header64(bytes, 32, request.token.revision); header64(bytes, 40, request.token.frame);
    header64(bytes, 48, request.token.capture_ns); header64(bytes, 56, request.token.transform);
    header32(bytes, 64, request.demand); header32(bytes, 68, request.width);
    header32(bytes, 72, request.height); header32(bytes, 76, request.rotation);
    header32(bytes, 80, request.mirrored ? 1 : 0);
    return bytes;
}

bool valid_frame(const VisionFrame& frame, const VisionBinding& binding, uint64_t now_ns) {
    if (!fresh(frame, now_ns) || !valid_rect(frame.segment_content, 256, 144) ||
            !valid_rect(frame.face_content, 128, 128)) return false;
    const SampleTicket ticket{1, 1, binding, frame};
    return parse_request(encode_request(make_request(ticket, frame.frame_id))).has_value();
}

std::optional<Face> decode_face(std::span<const uint8_t> bytes) {
    static_assert(sizeof(float) == sizeof(uint32_t) && std::numeric_limits<float>::is_iec559);
    if (bytes.size() != kFaceBytes) return std::nullopt;
    std::array<float, 17> values{};
    for (size_t i = 0; i < values.size(); ++i) {
        values[i] = std::bit_cast<float>(read32(bytes.subspan(i * 4).first<4>()));
        if (!std::isfinite(values[i])) return std::nullopt;
    }
    Face face;
    face.score = values[0]; face.left = values[1]; face.top = values[2];
    face.right = values[3]; face.bottom = values[4];
    for (size_t i = 0; i < face.points.size(); ++i) face.points[i] = {values[5 + 2 * i], values[6 + 2 * i]};
    if (face.score < 0.5f || face.score > 1.0f || !face_detail::usable_box(face) ||
            !face_detail::usable_points(face) || !face_detail::intersects_canvas(face)) return std::nullopt;
    return face;
}

struct Packet {
    SampleTicket ticket;
    std::vector<uint8_t> rgb;
};

// Lives until every pipe access has terminated, even after Windows cancel.
struct Transaction {
    std::unique_ptr<Packet> packet;
    Request request;
    Header request_header{};
    Header response_header{};
    std::array<uint8_t, kMaskBytes + kFaceBytes> response_payload{};
};

bool matches_result(const VisionResult& result, const VisionBinding& binding,
        const VisionFrame& desired, uint64_t now_ns) {
    if (result.binding != binding || !fresh(result.frame, now_ns) || !fresh(desired, now_ns) ||
            !same_geometry(result.frame, desired) || result.frame.frame_id > desired.frame_id ||
            result.frame.captured_monotonic_ns > desired.captured_monotonic_ns) return false;
    // Camera/media timestamps are independent from the monotonic age clock.
    // The same camera frame counter must never alias a different capture.
    return result.frame.frame_id != desired.frame_id ||
        (result.frame.media_timestamp_ns == desired.media_timestamp_ns &&
            result.frame.captured_monotonic_ns == desired.captured_monotonic_ns);
}
} // namespace

struct VisionClient::State {
    explicit State(VisionClientOptions value) : options(std::move(value)) {}
    VisionClientOptions options;
    mutable std::mutex mutex;
    std::condition_variable changed;
    std::optional<VisionBinding> binding;
    bool camera_enabled = true, closed = false;
    uint64_t logical_epoch = 1, nonce = 0, wire_ticket = 0;
    uint64_t last_frame = 0, last_capture = 0, last_admission = 0;
    uint64_t last_dispatched_capture = 0;
    std::atomic<uint64_t> cancel_epoch{1};
    uint64_t quiesced_cancel_epoch = 1;
    std::optional<SampleTicket> reservation;
    std::optional<VisionFrame> geometry;
    std::unique_ptr<Packet> pending;
    std::shared_ptr<const VisionResult> cache;
    bool process_active = false, outstanding = false, stopping = false, quarantined = false;
    size_t outstanding_bytes = 0;
    ClientFault fault = ClientFault::None;
    uint64_t process_starts = 0, process_exits = 0, submitted = 0;
    uint64_t pending_replaced = 0, completed = 0, discarded = 0;

    bool enabled() const { return !closed && camera_enabled && binding && binding->demand; }
    bool quiescing() const { return stopping || cancel_epoch.load(std::memory_order_acquire) != quiesced_cancel_epoch; }
    void expire_cache(uint64_t now_ns) {
        if (cache && now_ns >= cache->frame.captured_monotonic_ns &&
                now_ns - cache->frame.captured_monotonic_ns > kMaxResultAgeNs) cache.reset();
    }
    bool segmentation_unavailable(uint64_t now_ns) const {
        return binding && (binding->demand & kSegmentDemand) &&
            (!enabled() || fault != ClientFault::None || quiescing() || !cache ||
                cache->binding != *binding || cache->mask.size() != kMaskBytes || !fresh(cache->frame, now_ns));
    }
    void invalidate() {
        cache.reset(); pending.reset(); reservation.reset();
        last_frame = 0; last_capture = 0;
        if (logical_epoch < std::numeric_limits<uint64_t>::max()) ++logical_epoch;
        else {
            fault = ClientFault::TicketOverflow; closed = true;
            cancel_epoch.fetch_add(1, std::memory_order_release);
        }
    }
};

VisionClient::VisionClient(std::shared_ptr<State> state) : state_(std::move(state)) {}

std::unique_ptr<VisionClient> VisionClient::create(VisionClientOptions options) {
    if (options.worker_executable.empty() || !valid_path(options.worker_executable) ||
            !valid_path(options.segmentation_model) || !valid_path(options.face_model) ||
            options.sample_fps < 1 || options.sample_fps > 30 ||
            options.io_timeout_ms < 50 || options.io_timeout_ms > 2000) return nullptr;
    auto state = std::make_shared<State>(std::move(options));
    auto client = std::unique_ptr<VisionClient>(new VisionClient(state));
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
    try {
        client->io_thread_ = std::thread([state] { run(state); });
    } catch (const std::system_error&) { return nullptr; }
#else
    client->io_thread_ = std::thread([state] { run(state); });
#endif
    return client;
}

uint64_t VisionClient::monotonic_now_ns() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

VisionClient::~VisionClient() {
    close();
    // Only the guardian owns OS handles/buffers. It retains shared state until
    // terminal IO and reap, so destruction never waits on a caller's thread.
    if (io_thread_.joinable()) io_thread_.detach();
}

bool VisionClient::set_binding(std::optional<VisionBinding> binding, bool camera_enabled) {
    if (binding && !valid_binding(*binding)) return false;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->closed) return false;
        if (state_->binding == binding && state_->camera_enabled == camera_enabled) return true;
        const auto previous = state_->binding;
        if (binding && previous && binding->call_lease == previous->call_lease &&
                (binding->source_generation < previous->source_generation ||
                    binding->config_revision < previous->config_revision)) return false;
        const bool call_changed = binding && previous && binding->call_lease != previous->call_lease;
        const bool off = !binding || !binding->demand || !camera_enabled;
        const bool physical_cancel = off || call_changed;
        if (!binding || !previous || binding->call_lease != previous->call_lease ||
                binding->source_generation != previous->source_generation ||
                binding->transform_id != previous->transform_id) state_->geometry.reset();
        state_->invalidate();
        state_->binding = binding;
        state_->camera_enabled = camera_enabled;
        if (physical_cancel) {
            state_->fault = ClientFault::None;
            state_->cancel_epoch.fetch_add(1, std::memory_order_release);
            if (!state_->process_active && !state_->outstanding) {
                state_->quiesced_cancel_epoch = state_->cancel_epoch.load(std::memory_order_acquire);
            }
        }
    }
    state_->changed.notify_all();
    return true;
}

std::optional<SampleTicket> VisionClient::reserve_sample(const VisionFrame& frame, uint64_t now_ns) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->enabled() || state_->fault != ClientFault::None || state_->quiescing() || state_->reservation ||
            !valid_frame(frame, *state_->binding, now_ns) || frame.frame_id <= state_->last_frame ||
            frame.captured_monotonic_ns < state_->last_capture ||
            frame.captured_monotonic_ns < state_->last_dispatched_capture ||
            (state_->geometry && !same_geometry(frame, *state_->geometry)) ||
            (state_->last_admission && (now_ns < state_->last_admission ||
                now_ns - state_->last_admission < UINT64_C(1000000000) / state_->options.sample_fps))) return std::nullopt;
    if (state_->nonce == std::numeric_limits<uint64_t>::max()) {
        state_->fault = ClientFault::TicketOverflow;
        return std::nullopt;
    }
    SampleTicket ticket{++state_->nonce, state_->logical_epoch, *state_->binding, frame};
    state_->reservation = ticket;
    state_->geometry = frame;
    state_->last_frame = frame.frame_id;
    state_->last_capture = frame.captured_monotonic_ns;
    state_->last_admission = now_ns;
    return ticket;
}

bool VisionClient::submit(const SampleTicket& ticket, std::span<const uint8_t> segment_rgb,
        std::span<const uint8_t> face_rgb, uint64_t now_ns) {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (!state_->reservation || *state_->reservation != ticket) return false;
        state_->reservation.reset();
        if (!state_->enabled() || state_->fault != ClientFault::None || state_->quiescing() ||
                ticket.logical_epoch != state_->logical_epoch || ticket.binding != *state_->binding ||
                !fresh(ticket.frame, now_ns) ||
                !valid_rgb(segment_rgb, (ticket.binding.demand & kSegmentDemand) ? kSegmentRgbBytes : 0) ||
                !valid_rgb(face_rgb, (ticket.binding.demand & kFaceDemand) ? kFaceRgbBytes : 0)) return false;
        if (state_->pending) { state_->pending.reset(); ++state_->pending_replaced; }
        auto packet = std::make_unique<Packet>();
        packet->ticket = ticket;
        packet->rgb = std::vector<uint8_t>(segment_rgb.size() + face_rgb.size());
        // No capacity-growth reuse: every exact-sized owned packet is bounded.
        if (packet->rgb.capacity() > kMaxPayloadBytes) return false;
        auto bytes = std::span(packet->rgb);
        if (!segment_rgb.empty()) std::copy(segment_rgb.begin(), segment_rgb.end(), bytes.begin());
        if (!face_rgb.empty()) std::copy(face_rgb.begin(), face_rgb.end(), bytes.subspan(segment_rgb.size()).begin());
        state_->pending = std::move(packet);
        ++state_->submitted;
    }
    state_->changed.notify_all();
    return true;
}

void VisionClient::abandon(const SampleTicket& ticket) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->reservation && *state_->reservation == ticket) state_->reservation.reset();
}

std::shared_ptr<const VisionResult> VisionClient::result_for(const VisionBinding& binding,
        const VisionFrame& desired, uint64_t now_ns) const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->expire_cache(now_ns);
    if (!state_->enabled() || state_->fault != ClientFault::None || state_->quiescing() ||
            !state_->binding || binding != *state_->binding || !state_->cache ||
            !matches_result(*state_->cache, binding, desired, now_ns)) return nullptr;
    return state_->cache;
}

bool VisionClient::cache_unavailable(uint64_t now_ns) const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->expire_cache(now_ns);
    return state_->segmentation_unavailable(now_ns);
}

VisionClientSnapshot VisionClient::snapshot() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->expire_cache(monotonic_now_ns());
    VisionClientSnapshot result;
    result.configured = state_->binding.has_value(); result.camera_enabled = state_->camera_enabled;
    result.closed = state_->closed; result.process_active = state_->process_active;
    result.outstanding = state_->outstanding; result.pending = state_->pending != nullptr;
    result.quiescing = state_->quiescing(); result.quarantined = state_->quarantined;
    result.faulted = state_->fault != ClientFault::None;
    result.segmentation_unavailable = state_->segmentation_unavailable(monotonic_now_ns());
    result.fault = state_->fault; result.logical_epoch = state_->logical_epoch;
    result.process_starts = state_->process_starts; result.process_exits = state_->process_exits;
    result.submitted = state_->submitted; result.pending_replaced = state_->pending_replaced;
    result.completed = state_->completed; result.discarded = state_->discarded;
    result.owned_rgb_bytes = state_->outstanding_bytes + (state_->pending ? state_->pending->rgb.capacity() : 0);
    result.cached_mask_bytes = state_->cache ? state_->cache->mask.capacity() : 0;
    return result;
}

void VisionClient::close() {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->closed) return;
        state_->closed = true;
        state_->invalidate();
        state_->binding.reset();
        state_->cancel_epoch.fetch_add(1, std::memory_order_release);
        if (!state_->process_active && !state_->outstanding) {
            state_->quiesced_cancel_epoch = state_->cancel_epoch.load(std::memory_order_acquire);
        }
    }
    state_->changed.notify_all();
}

bool VisionClient::wait_quiescent(std::chrono::milliseconds timeout) const {
    // Even an erroneous caller cannot request an unbounded wait.
    timeout = std::clamp(timeout, std::chrono::milliseconds(0), std::chrono::milliseconds(5000));
    std::unique_lock<std::mutex> lock(state_->mutex);
    return state_->changed.wait_for(lock, timeout, [&] {
        return !state_->process_active && !state_->outstanding && !state_->quiescing();
    });
}

void VisionClient::run(const std::shared_ptr<State>& state) {
    process_detail::prepare_io_thread();
    std::unique_ptr<process_detail::Process> process;
    uint64_t process_epoch = state->cancel_epoch.load(std::memory_order_acquire);
    bool counted_process = false;
    const auto stop_process = [&](Transaction* transaction) {
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->stopping = true;
        }
        if (process) {
            process->stop();
            // Keep every Transaction buffer and the Process alive while the OS
            // still owns an access. No controller/capture thread waits here.
            // After 250ms it remains quarantined, never eligible for restart.
            const auto quarantine_after = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
            while (!process->quiescent()) {
                std::unique_lock<std::mutex> lock(state->mutex);
                if (std::chrono::steady_clock::now() >= quarantine_after) state->quarantined = true;
                state->changed.wait_for(lock, std::chrono::milliseconds(20));
            }
            process.reset();
        }
        // Only now may a cancelled OVERLAPPED source buffer be released.
        transaction->packet.reset();
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (counted_process) ++state->process_exits;
            counted_process = false;
            state->process_active = false; state->outstanding = false; state->outstanding_bytes = 0;
            state->last_dispatched_capture = 0;
            state->stopping = false; state->quarantined = false;
            process_epoch = state->cancel_epoch.load(std::memory_order_acquire);
            state->quiesced_cancel_epoch = process_epoch;
        }
        state->changed.notify_all();
    };

    for (;;) {
        Transaction transaction;
        {
            std::unique_lock<std::mutex> lock(state->mutex);
            const auto ready = [&] {
                return state->closed || state->cancel_epoch.load(std::memory_order_acquire) != process_epoch ||
                    (state->enabled() && state->fault == ClientFault::None && state->pending);
            };
            while (!ready()) {
                const auto now = monotonic_now_ns();
                state->expire_cache(now);
                if (state->cache) {
                    // A single age deadline releases the retained result even
                    // when no new camera sample or consumer poll arrives.
                    const auto remaining = kMaxResultAgeNs - (now - state->cache->frame.captured_monotonic_ns) + 1;
                    state->changed.wait_for(lock, std::chrono::nanoseconds(remaining), ready);
                } else state->changed.wait(lock, ready);
            }
            if (state->cancel_epoch.load(std::memory_order_acquire) != process_epoch || state->closed) {
                lock.unlock(); stop_process(&transaction);
                lock.lock();
                if (state->closed) return;
                continue;
            }
            if (!state->pending) continue;
            if (state->pending->ticket.logical_epoch != state->logical_epoch ||
                    !fresh(state->pending->ticket.frame, monotonic_now_ns()) ||
                    state->pending->ticket.frame.captured_monotonic_ns < state->last_dispatched_capture) {
                state->pending.reset(); ++state->discarded;
                continue;
            }
            transaction.packet = std::move(state->pending);
            state->outstanding = true; state->outstanding_bytes = transaction.packet->rgb.capacity();
            if (state->wire_ticket == std::numeric_limits<uint64_t>::max()) {
                state->fault = ClientFault::TicketOverflow;
                state->invalidate();
                lock.unlock(); stop_process(&transaction);
                continue;
            }
            transaction.request = make_request(transaction.packet->ticket, ++state->wire_ticket);
            state->last_dispatched_capture = transaction.packet->ticket.frame.captured_monotonic_ns;
            transaction.request_header = encode_request(transaction.request);
        }
        ClientFault failure = ClientFault::None;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(state->options.io_timeout_ms);
        if (!process) {
            process = process_detail::make_process();
            const auto& options = state->options;
            const bool started = process && process->launch({options.worker_executable,
                options.segmentation_model, options.face_model});
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->process_active = process != nullptr;
                if (started) { ++state->process_starts; counted_process = true; }
            }
            if (!started) failure = ClientFault::Start;
        }
        IoStatus status = IoStatus::Complete;
        std::optional<Response> response;
        if (failure == ClientFault::None) {
            status = process->write(transaction.request_header, state->cancel_epoch, process_epoch, deadline);
            if (status == IoStatus::Complete) status = process->write(
                std::span(transaction.packet->rgb), state->cancel_epoch, process_epoch, deadline);
            if (status == IoStatus::Complete) status = process->read(transaction.response_header,
                state->cancel_epoch, process_epoch, deadline);
            if (status == IoStatus::Complete) {
                response = parse_response(transaction.response_header, transaction.request);
                if (!response || response->payload_bytes > transaction.response_payload.size()) failure = ClientFault::Protocol;
                else status = process->read(std::span(transaction.response_payload).first(response->payload_bytes),
                    state->cancel_epoch, process_epoch, deadline);
            }
            if (status == IoStatus::Timeout) failure = ClientFault::Deadline;
            else if (status != IoStatus::Complete && status != IoStatus::Cancelled) failure = ClientFault::Transport;
        }
        std::shared_ptr<VisionResult> result;
        if (failure == ClientFault::None && status == IoStatus::Complete && response) {
            result = std::make_shared<VisionResult>();
            result->binding = transaction.packet->ticket.binding;
            result->frame = transaction.packet->ticket.frame;
            result->wire_ticket_id = transaction.request.token.frame;
            auto payload = std::span(transaction.response_payload).first(response->payload_bytes);
            if (response->mask_bytes) result->mask.assign(payload.begin(), payload.subspan(response->mask_bytes).begin());
            if (response->has_face) {
                result->face = decode_face(payload.subspan(response->mask_bytes, response->face_bytes));
                if (!result->face) { failure = ClientFault::Protocol; result.reset(); }
            }
        }
        if (failure != ClientFault::None || status == IoStatus::Cancelled ||
                state->cancel_epoch.load(std::memory_order_acquire) != process_epoch) {
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                if (failure != ClientFault::None && state->cancel_epoch.load(std::memory_order_acquire) == process_epoch && !state->closed) {
                    state->fault = failure;
                    state->invalidate();
                }
            }
            stop_process(&transaction);
            continue;
        }
        const SampleTicket ticket = transaction.packet->ticket;
        transaction.packet.reset();
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->outstanding = false; state->outstanding_bytes = 0;
            if (result) {
                ++state->completed;
                if (state->enabled() && state->fault == ClientFault::None && state->binding == ticket.binding &&
                        state->logical_epoch == ticket.logical_epoch && fresh(ticket.frame, monotonic_now_ns())) state->cache = result;
                else ++state->discarded;
            }
        }
        state->changed.notify_all();
    }
}

} // namespace dinox::vision
