// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// SDK-independent lifecycle/ownership tests. argv[1] is the fake worker binary.
#include "vision_client.hpp"

#include <algorithm>
#include <chrono>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {
using namespace dinox::vision;
using namespace std::chrono_literals;
std::string current_case;

// The platform main ABI guarantees argc accessible, null-terminated argv
// strings. Copy them once; the tests do not retain or index raw argv pointers.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
std::vector<std::string> main_arguments(int argc, char** argv) {
    std::vector<std::string> arguments;
    if (argc < 0 || !argv) return arguments;
    arguments.reserve(static_cast<size_t>(argc));
    for (int i = 0; i < argc; ++i) arguments.emplace_back(argv[i]);
    return arguments;
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif

void check(bool condition, const char* expression, int line) {
    if (!condition) {
        throw std::runtime_error("line " + std::to_string(line) + ": " + expression);
    }
}
#define CHECK(expression) check(bool(expression), #expression, __LINE__)

template<class Predicate>
bool wait_until(Predicate predicate, std::chrono::milliseconds timeout = 1500ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    do {
        if (predicate()) return true;
        std::this_thread::sleep_for(2ms);
    } while (std::chrono::steady_clock::now() < deadline);
    return predicate();
}

VisionBinding binding(uint32_t demand = kSegmentDemand | kFaceDemand) {
    // Publication and source-generation tokens deliberately differ.
    return VisionBinding{101, 7, 7007, 10, 20, demand};
}

VisionFrame frame(uint64_t id) {
    VisionFrame result;
    result.frame_id = id;
    result.media_timestamp_ns = 900000000000ull + id * 33333333;
    result.captured_monotonic_ns = VisionClient::monotonic_now_ns();
    result.width = 640; result.height = 480;
    result.segment_content = {32, 0, 192, 144};
    result.face_content = {0, 16, 128, 96};
    return result;
}

std::vector<uint8_t> rgb(size_t size, uint8_t seed) {
    std::vector<uint8_t> bytes(size);
    for (size_t i = 0; i < size; ++i) bytes[i] = uint8_t(seed + i * 29 + i / 257);
    return bytes;
}

uint32_t checksum(const std::vector<uint8_t>& bytes) {
    uint32_t hash = 2166136261u;
    for (uint8_t byte : bytes) hash = (hash ^ byte) * 16777619u;
    return hash;
}

uint32_t word32(std::span<const uint8_t> bytes, size_t offset) {
    CHECK(bytes.size() >= 4 && offset <= bytes.size() - 4);
    return read32(bytes.subspan(offset).first<4>());
}

uint64_t word64(std::span<const uint8_t> bytes, size_t offset) {
    CHECK(bytes.size() >= 8 && offset <= bytes.size() - 8);
    return word32(bytes, offset) | (uint64_t(word32(bytes, offset + 4)) << 32);
}

struct Harness {
    explicit Harness(const std::string& executable, const std::string& mode = "normal",
            uint32_t io_timeout_ms = 500) {
        VisionClientOptions options;
        options.worker_executable = executable;
        options.segmentation_model = mode;
        options.face_model = mode;
        options.sample_fps = 30;
        options.io_timeout_ms = io_timeout_ms;
        client = VisionClient::create(std::move(options));
        CHECK(client);
    }
    ~Harness() {
        if (client) {
            client->close();
            // Tests are an explicit controller; capture/UI never perform this wait.
            if (!client->wait_quiescent(2000ms)) {
                std::cerr << "VISION_CLIENT cleanup did not become quiescent\n";
            }
        }
    }
    std::unique_ptr<VisionClient> client;
};

SampleTicket reserve(VisionClient& client, const VisionFrame& desired) {
    std::optional<SampleTicket> ticket;
    CHECK(wait_until([&] {
        ticket = client.reserve_sample(desired, VisionClient::monotonic_now_ns());
        return bool(ticket);
    }, 250ms));
    CHECK(ticket->nonce && ticket->logical_epoch);
    CHECK(ticket->frame == desired);
    return *ticket;
}

SampleTicket submit(VisionClient& client, const VisionFrame& desired,
        const VisionBinding& selected, uint8_t segment_seed = 17, uint8_t face_seed = 33) {
    auto ticket = reserve(client, desired);
    CHECK(ticket.binding == selected);
    const auto segment = (selected.demand & kSegmentDemand) ? rgb(kSegmentRgbBytes, segment_seed) :
        std::vector<uint8_t>{};
    const auto face = (selected.demand & kFaceDemand) ? rgb(kFaceRgbBytes, face_seed) :
        std::vector<uint8_t>{};
    CHECK(client.submit(ticket, segment, face, VisionClient::monotonic_now_ns()));
    return ticket;
}

std::shared_ptr<const VisionResult> result(VisionClient& client,
        const VisionBinding& selected, const VisionFrame& desired) {
    std::shared_ptr<const VisionResult> found;
    CHECK(wait_until([&] {
        found = client.result_for(selected, desired, VisionClient::monotonic_now_ns());
        return found && found->frame == desired;
    }));
    CHECK(found->binding == selected);
    CHECK(found->wire_ticket_id);
    return found;
}

void check_marker(const VisionResult& found, uint64_t count,
        uint8_t segment_seed, uint8_t face_seed) {
    CHECK(found.mask.size() == kMaskBytes);
    const auto bytes = std::span<const uint8_t>(found.mask);
    CHECK(word32(bytes, 0) == 0x4b52414d);
    CHECK(word32(bytes, 4) == found.binding.demand);
    CHECK(word64(bytes, 8) == found.wire_ticket_id);
    CHECK(word64(bytes, 16) == found.binding.source_generation);
    CHECK(word64(bytes, 16) != found.binding.publication_source_id);
    CHECK(word64(bytes, 24) == found.binding.config_revision);
    CHECK(word64(bytes, 32) == count);
    CHECK(word64(bytes, 40) == found.binding.call_lease);
    CHECK(word64(bytes, 48) == found.binding.transform_id);
    CHECK(bytes[56] == segment_seed);
    CHECK(bytes[57] == ((found.binding.demand & kFaceDemand) ? face_seed : 0));
    CHECK(word32(bytes, 58) == found.frame.width);
    CHECK(word32(bytes, 62) == found.frame.height);
    CHECK(word32(bytes, 66) == found.frame.rotation);
    CHECK(word32(bytes, 70) == (found.frame.mirrored ? 1u : 0u));
    CHECK(word32(bytes, 74) == checksum(rgb(kSegmentRgbBytes, segment_seed)));
    const auto face = (found.binding.demand & kFaceDemand) ? rgb(kFaceRgbBytes, face_seed) :
        std::vector<uint8_t>{};
    CHECK(word32(bytes, 78) == checksum(face));
}

void close_and_check(VisionClient& client) {
    client.close();
    CHECK(client.wait_quiescent(2000ms));
    const auto state = client.snapshot();
    CHECK(state.closed && !state.process_active && !state.outstanding && !state.pending);
    CHECK(!state.owned_rgb_bytes && !state.cached_mask_bytes);
    CHECK(!client.reserve_sample(frame(100), VisionClient::monotonic_now_ns()));
}

void test_lazy_admission(const std::string& executable) {
    Harness h(executable);
    auto selected = binding(0);
    CHECK(!h.client->reserve_sample(frame(1), VisionClient::monotonic_now_ns()));
    CHECK(h.client->set_binding(selected));
    CHECK(!h.client->reserve_sample(frame(1), VisionClient::monotonic_now_ns()));
    CHECK(!h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    auto state = h.client->snapshot();
    CHECK(!state.process_starts && !state.process_active && !state.owned_rgb_bytes);
    selected.demand = kSegmentDemand;
    CHECK(h.client->set_binding(selected));
    CHECK(h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    CHECK(h.client->snapshot().segmentation_unavailable);
    auto invalid = frame(1); invalid.width = 5000;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    invalid = frame(1); invalid.rotation = 45;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    invalid = frame(1); invalid.segment_content = {250, 0, 256, 144};
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    const auto desired = frame(1);
    const auto ticket = reserve(*h.client, desired);
    CHECK(!h.client->reserve_sample(frame(2), VisionClient::monotonic_now_ns()));
    state = h.client->snapshot();
    // Reservation/rate rejection happen before either RGB copy or process launch.
    CHECK(!state.process_starts && !state.process_active && !state.owned_rgb_bytes);
    h.client->abandon(ticket);
    const auto segment = rgb(kSegmentRgbBytes, 17);
    CHECK(!h.client->submit(ticket, segment, {}, VisionClient::monotonic_now_ns()));
    ++selected.config_revision;
    CHECK(h.client->set_binding(selected));
    auto fresh = reserve(*h.client, frame(1));
    ++selected.config_revision;
    CHECK(h.client->set_binding(selected));
    CHECK(!h.client->submit(fresh, segment, {}, VisionClient::monotonic_now_ns()));
    fresh = reserve(*h.client, frame(1));
    CHECK(!h.client->submit(fresh, std::span<const uint8_t>(segment).first(1), {},
        VisionClient::monotonic_now_ns()));
    h.client->abandon(fresh);
    state = h.client->snapshot();
    CHECK(!state.submitted && !state.process_starts && !state.owned_rgb_bytes);
    close_and_check(*h.client);
}

void test_owned_copies_and_cache_identity(const std::string& executable) {
    Harness h(executable);
    const auto selected = binding();
    CHECK(h.client->set_binding(selected));
    auto desired = frame(1);
    const auto original = desired;
    auto ticket = reserve(*h.client, desired);
    auto segment = rgb(kSegmentRgbBytes, 17), face = rgb(kFaceRgbBytes, 33);
    CHECK(h.client->submit(ticket, segment, face, VisionClient::monotonic_now_ns()));
    std::fill(segment.begin(), segment.end(), 0xee);
    std::fill(face.begin(), face.end(), 0xdd);
    desired.width = 1; ticket.binding.publication_source_id = 1;
    ticket.frame.media_timestamp_ns = 1;
    const auto found = result(*h.client, selected, original);
    check_marker(*found, 1, 17, 33);
    CHECK(found->face);
    CHECK(found->face->score == 0.75f && found->face->left == -0.2f);
    CHECK(found->face->points[0].x == -0.1f);
    CHECK(h.client->snapshot().cached_mask_bytes == kMaskBytes);
    CHECK(!h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    auto different = original; ++different.media_timestamp_ns;
    CHECK(!h.client->result_for(selected, different, VisionClient::monotonic_now_ns()));
    different = original; ++different.captured_monotonic_ns;
    CHECK(!h.client->result_for(selected, different, VisionClient::monotonic_now_ns()));
    different = original; ++different.width;
    CHECK(!h.client->result_for(selected, different, VisionClient::monotonic_now_ns()));
    different = original; different.mirrored = true;
    CHECK(!h.client->result_for(selected, different, VisionClient::monotonic_now_ns()));
    auto other_binding = selected; ++other_binding.publication_source_id;
    CHECK(!h.client->result_for(other_binding, original, VisionClient::monotonic_now_ns()));
    // A later camera frame may use a fresh older cache from the same geometry.
    different = original; ++different.frame_id; ++different.captured_monotonic_ns;
    ++different.media_timestamp_ns;
    CHECK(h.client->result_for(selected, different,
        (std::max)(VisionClient::monotonic_now_ns(), different.captured_monotonic_ns)) == found);
    CHECK(!h.client->result_for(selected, original, original.captured_monotonic_ns - 1));
    const auto expired = original.captured_monotonic_ns + kMaxResultAgeNs + 1;
    CHECK(!h.client->result_for(selected, original, expired));
    CHECK(h.client->cache_unavailable(expired));
    close_and_check(*h.client);
}

void test_latest_pending(const std::string& executable) {
    Harness h(executable, "sleep");
    const auto selected = binding();
    CHECK(h.client->set_binding(selected));
    const auto first = frame(1);
    submit(*h.client, first, selected, 10, 20);
    CHECK(wait_until([&] {
        const auto state = h.client->snapshot();
        return state.process_active && state.outstanding;
    }));
    const auto second = frame(2);
    submit(*h.client, second, selected, 11, 21);
    const auto latest = frame(3);
    auto ticket = reserve(*h.client, latest);
    auto segment = rgb(kSegmentRgbBytes, 12), face = rgb(kFaceRgbBytes, 22);
    CHECK(h.client->submit(ticket, segment, face, VisionClient::monotonic_now_ns()));
    std::fill(segment.begin(), segment.end(), 0xff);
    std::fill(face.begin(), face.end(), 0xff);
    auto state = h.client->snapshot();
    CHECK(state.submitted == 3 && state.pending_replaced == 1);
    CHECK(state.outstanding && state.pending);
    CHECK(state.owned_rgb_bytes == 2 * kMaxPayloadBytes);
    const auto found = result(*h.client, selected, latest);
    check_marker(*found, 2, 12, 22); // request 2 was replaced before dispatch
    CHECK(found->wire_ticket_id > 1);
    CHECK(wait_until([&] { return !h.client->snapshot().outstanding; }));
    state = h.client->snapshot();
    CHECK(state.process_starts == 1 && state.completed == 2);
    CHECK(!state.pending && !state.owned_rgb_bytes);
    CHECK(!h.client->result_for(selected, first, VisionClient::monotonic_now_ns()));
    close_and_check(*h.client);
}

void test_process_reuse_and_epoch_fences(const std::string& executable) {
    Harness h(executable, "sleep");
    auto selected = binding();
    CHECK(h.client->set_binding(selected));
    const auto old_binding = selected;
    const auto old_frame = frame(1);
    submit(*h.client, old_frame, selected);
    CHECK(wait_until([&] {
        const auto state = h.client->snapshot();
        return state.process_active && state.outstanding;
    }));
    ++selected.config_revision;
    CHECK(h.client->set_binding(selected));
    CHECK(!h.client->result_for(old_binding, old_frame, VisionClient::monotonic_now_ns()));
    CHECK(!h.client->snapshot().cached_mask_bytes);
    auto desired = frame(1); // the local counter resets; the wire ticket cannot
    submit(*h.client, desired, selected);
    auto found = result(*h.client, selected, desired);
    check_marker(*found, 2, 17, 33);
    CHECK(h.client->snapshot().discarded >= 1);
    uint64_t previous_wire = found->wire_ticket_id;
    for (int change = 0; change < 5; ++change) {
        const auto previous_binding = selected;
        const auto previous_frame = desired;
        ++selected.config_revision;
        if (change == 0) ++selected.transform_id;
        if (change == 1) { ++selected.source_generation; selected.publication_source_id = 8008; }
        if (change == 2) selected.demand = kFaceDemand;
        if (change == 3) selected.demand = kSegmentDemand;
        if (change == 4) selected.demand = kSegmentDemand | kFaceDemand;
        CHECK(h.client->set_binding(selected));
        CHECK(!h.client->result_for(previous_binding, previous_frame,
            VisionClient::monotonic_now_ns()));
        desired = frame(1);
        submit(*h.client, desired, selected);
        found = result(*h.client, selected, desired);
        CHECK(found->wire_ticket_id > previous_wire);
        previous_wire = found->wire_ticket_id;
        if (selected.demand & kSegmentDemand) check_marker(*found, uint64_t(change + 3), 17, 33);
        else {
            CHECK(found->mask.empty() && found->face);
            CHECK(!h.client->snapshot().segmentation_unavailable);
            CHECK(!h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
        }
        const auto state = h.client->snapshot();
        CHECK(state.process_starts == 1 && !state.process_exits && !state.faulted);
    }
    close_and_check(*h.client);
}

void test_geometry_guard(const std::string& executable) {
    Harness h(executable);
    auto selected = binding();
    CHECK(h.client->set_binding(selected));
    const auto first = frame(1);
    submit(*h.client, first, selected);
    result(*h.client, selected, first);
    std::this_thread::sleep_for(35ms);
    const auto second = frame(2);
    auto invalid = second; invalid.rotation = 90;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    invalid = second; invalid.mirrored = true;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    invalid = second; invalid.width = 320;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    invalid = second; invalid.segment_content = {0, 0, 256, 144};
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    const auto accepted = h.client->reserve_sample(second, VisionClient::monotonic_now_ns());
    CHECK(accepted); // rejected geometry did not consume the sample budget
    h.client->abandon(*accepted);
    ++selected.config_revision;
    CHECK(h.client->set_binding(selected));
    std::this_thread::sleep_for(35ms);
    invalid = frame(1); invalid.width = 320;
    CHECK(!h.client->reserve_sample(invalid, VisionClient::monotonic_now_ns()));
    ++selected.transform_id;
    CHECK(h.client->set_binding(selected));
    auto transformed = frame(1);
    transformed.width = 320; transformed.height = 240;
    transformed.rotation = 90; transformed.mirrored = true;
    transformed.segment_content = {0, 0, 256, 144};
    transformed.face_content = {0, 0, 128, 128};
    submit(*h.client, transformed, selected);
    check_marker(*result(*h.client, selected, transformed), 2, 17, 33);
    CHECK(h.client->snapshot().process_starts == 1);
    close_and_check(*h.client);
}

void test_off_camera_and_call_quiescence(const std::string& executable) {
    Harness h(executable, "sleep");
    auto selected = binding();
    CHECK(h.client->set_binding(selected));
    auto desired = frame(1);
    submit(*h.client, desired, selected);
    CHECK(wait_until([&] { return h.client->snapshot().process_active; }));
    auto off = selected; off.demand = 0;
    CHECK(h.client->set_binding(off));
    CHECK(!h.client->reserve_sample(frame(2), VisionClient::monotonic_now_ns()));
    CHECK(!h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    CHECK(h.client->wait_quiescent(2000ms));
    auto state = h.client->snapshot();
    CHECK(state.process_starts == 1 && state.process_exits == 1);
    CHECK(!state.process_active && !state.outstanding && !state.pending && !state.owned_rgb_bytes);
    CHECK(h.client->set_binding(selected));
    desired = frame(1);
    submit(*h.client, desired, selected);
    CHECK(wait_until([&] { return h.client->snapshot().process_starts == 2; }));
    CHECK(h.client->set_binding(selected, false));
    CHECK(!h.client->reserve_sample(frame(2), VisionClient::monotonic_now_ns()));
    CHECK(h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    CHECK(h.client->snapshot().segmentation_unavailable);
    CHECK(h.client->wait_quiescent(2000ms));
    CHECK(h.client->snapshot().process_exits == 2);
    CHECK(h.client->set_binding(selected, true));
    desired = frame(1);
    submit(*h.client, desired, selected);
    CHECK(wait_until([&] { return h.client->snapshot().process_starts == 3; }));
    ++selected.call_lease;
    CHECK(h.client->set_binding(selected));
    const auto switched = frame(1);
    auto admission = h.client->reserve_sample(switched, VisionClient::monotonic_now_ns());
    if (admission) {
        // Admission is allowed only after the old child/pipe access is terminal.
        CHECK(h.client->snapshot().process_exits == 3);
        h.client->abandon(*admission);
    }
    CHECK(h.client->wait_quiescent(2000ms));
    desired = frame(admission ? 2 : 1);
    submit(*h.client, desired, selected);
    check_marker(*result(*h.client, selected, desired), 1, 17, 33);
    state = h.client->snapshot();
    CHECK(state.process_starts == 4 && state.process_exits == 3 && !state.faulted);
    CHECK(h.client->set_binding(std::nullopt));
    CHECK(h.client->wait_quiescent(2000ms));
    close_and_check(*h.client);
}

void test_stale_completed_response(const std::string& executable) {
    Harness h(executable, "sleep");
    const auto selected = binding();
    CHECK(h.client->set_binding(selected));
    auto desired = frame(1);
    desired.captured_monotonic_ns -= 400000000;
    submit(*h.client, desired, selected);
    CHECK(wait_until([&] { return h.client->snapshot().completed == 1; }));
    const auto state = h.client->snapshot();
    CHECK(state.discarded == 1 && !state.cached_mask_bytes && !state.faulted);
    CHECK(h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    CHECK(!h.client->result_for(selected, desired, VisionClient::monotonic_now_ns()));
    close_and_check(*h.client);
}

void test_fault_latching(const std::string& executable) {
    for (const std::string mode : {"nan", "bad-score", "bad-box", "bad-token",
            "truncated", "exit", "deadline"}) {
        current_case = "fault/" + mode;
        Harness h(executable, mode, mode == "deadline" ? 80 : 500);
        auto selected = binding();
        CHECK(h.client->set_binding(selected));
        const auto desired = frame(1);
        submit(*h.client, desired, selected);
        CHECK(wait_until([&] { return h.client->snapshot().faulted; }));
        auto state = h.client->snapshot();
        CHECK(state.fault != ClientFault::None && state.segmentation_unavailable);
        if (mode == "deadline") CHECK(state.fault == ClientFault::Deadline);
        if (mode == "nan" || mode == "bad-score" || mode == "bad-box" || mode == "bad-token") {
            CHECK(state.fault == ClientFault::Protocol);
        }
        CHECK(h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
        CHECK(!h.client->result_for(selected, desired, VisionClient::monotonic_now_ns()));
        CHECK(h.client->wait_quiescent(2000ms));
        ++selected.config_revision; ++selected.source_generation; ++selected.transform_id;
        selected.demand = kSegmentDemand;
        CHECK(h.client->set_binding(selected));
        CHECK(!h.client->reserve_sample(frame(1), VisionClient::monotonic_now_ns()));
        state = h.client->snapshot();
        CHECK(state.faulted && state.process_starts == 1 && state.process_exits == 1);
        CHECK(state.segmentation_unavailable && !state.owned_rgb_bytes);
        CHECK(h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
        if (mode == "deadline") {
            // Retry requires a deliberate enable cycle after terminal pipe access.
            CHECK(h.client->set_binding(std::nullopt));
            CHECK(h.client->wait_quiescent(2000ms));
            CHECK(h.client->set_binding(selected));
            submit(*h.client, frame(1), selected);
            CHECK(wait_until([&] { return h.client->snapshot().faulted; }));
            CHECK(h.client->snapshot().process_starts == 2);
        }
        close_and_check(*h.client);
    }
}

void test_tracking_loss_and_face_only(const std::string& executable) {
    Harness h(executable, "no-face");
    auto selected = binding();
    CHECK(h.client->set_binding(selected));
    auto desired = frame(1);
    submit(*h.client, desired, selected);
    auto found = result(*h.client, selected, desired);
    check_marker(*found, 1, 17, 33);
    CHECK(!found->face && !h.client->snapshot().faulted);
    ++selected.config_revision; selected.demand = kFaceDemand;
    CHECK(h.client->set_binding(selected));
    desired = frame(1);
    submit(*h.client, desired, selected);
    found = result(*h.client, selected, desired);
    CHECK(found->mask.empty() && !found->face);
    CHECK(!h.client->cache_unavailable(VisionClient::monotonic_now_ns()));
    CHECK(!h.client->snapshot().segmentation_unavailable);
    CHECK(h.client->snapshot().process_starts == 1);
    close_and_check(*h.client);
}

void test_bounded_wait_and_nonblocking_destructor(const std::string& executable) {
    Harness h(executable, "deadline", 2000);
    const auto selected = binding();
    CHECK(h.client->set_binding(selected));
    submit(*h.client, frame(1), selected);
    CHECK(wait_until([&] { return h.client->snapshot().process_active; }));
    auto start = std::chrono::steady_clock::now();
    CHECK(!h.client->wait_quiescent(10ms));
    CHECK(std::chrono::steady_clock::now() - start < 100ms);
    start = std::chrono::steady_clock::now();
    h.client->close();
    CHECK(std::chrono::steady_clock::now() - start < 100ms);
    CHECK(h.client->wait_quiescent(2000ms));
    const auto state = h.client->snapshot();
    CHECK(state.closed && !state.process_active && !state.owned_rgb_bytes);

    Harness detached(executable, "deadline", 2000);
    CHECK(detached.client->set_binding(selected));
    submit(*detached.client, frame(1), selected);
    CHECK(wait_until([&] { return detached.client->snapshot().process_active; }));
    start = std::chrono::steady_clock::now();
    detached.client.reset(); // no callback target exists after owner destruction
    CHECK(std::chrono::steady_clock::now() - start < 100ms);
    // Allow the independent I/O guardian to finish its terminal cleanup before
    // this executable exits; owner destruction itself did not perform that wait.
    std::this_thread::sleep_for(100ms);
}
} // namespace

int main(int argc, char** argv) {
    const auto arguments = main_arguments(argc, argv);
    if (arguments.size() != 2) {
        std::cerr << "usage: vision-client-smoke FAKE_WORKER_EXECUTABLE\n";
        return 2;
    }
    try {
        const auto& executable = arguments[1];
        const auto run_case = [&](const char* name, auto test) {
            current_case = name;
            test(executable);
        };
        run_case("lazy-admission", test_lazy_admission);
        run_case("owned-copy/cache-identity", test_owned_copies_and_cache_identity);
        run_case("latest-pending", test_latest_pending);
        run_case("process-reuse/epochs", test_process_reuse_and_epoch_fences);
        run_case("geometry-guard", test_geometry_guard);
        run_case("off/camera/call-quiescence", test_off_camera_and_call_quiescence);
        run_case("stale-completion", test_stale_completed_response);
        run_case("fault-latching", test_fault_latching);
        run_case("tracking-loss/face-only", test_tracking_loss_and_face_only);
        run_case("bounded-wait/destruction", test_bounded_wait_and_nonblocking_destructor);
    } catch (const std::exception& error) {
        // std::exception::what() promises a null-terminated string; expose only
        // its view to stream output, without a variadic C formatting boundary.
        std::cerr << "VISION_CLIENT_FAIL [" << current_case << "]: " <<
            std::string_view(error.what()) << '\n';
        return 1;
    }
    std::cout << "PASS bounded asynchronous vision client, process reuse, ownership and privacy fences\n";
    return 0;
}
