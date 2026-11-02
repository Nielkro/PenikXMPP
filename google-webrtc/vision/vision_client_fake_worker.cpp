// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// SDK-independent protocol fixture. Model argument values select fault modes;
// stdout is exclusively binary protocol data, including on Windows.
#include "vision_protocol.hpp"

#include <array>
#include <bit>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif

namespace {
using namespace dinox::vision;
enum class ReadStatus { Complete, Eof, Truncated };

// The C stdio API cannot express an extent. Each pointer/length pair below is
// derived from the same already-bounded span, with element size exactly one.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
size_t read_pipe(std::span<uint8_t> bytes) {
    return std::fread(bytes.data(), 1, bytes.size(), stdin);
}
size_t write_pipe(std::span<const uint8_t> bytes) {
    return std::fwrite(bytes.data(), 1, bytes.size(), stdout);
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif

// The platform main ABI guarantees argc accessible, null-terminated argv
// strings. Copy them at this boundary; all option parsing uses owned containers.
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

ReadStatus read_exact(std::span<uint8_t> bytes, bool allow_eof = false) {
    size_t used = 0;
    while (used < bytes.size()) {
        const auto remaining = bytes.subspan(used);
        const size_t got = read_pipe(remaining);
        if (!got) {
            return allow_eof && used == 0 && std::feof(stdin) ?
                ReadStatus::Eof : ReadStatus::Truncated;
        }
        used += got;
    }
    return ReadStatus::Complete;
}

bool write_exact(std::span<const uint8_t> bytes) {
    size_t used = 0;
    while (used < bytes.size()) {
        const auto remaining = bytes.subspan(used);
        const size_t wrote = write_pipe(remaining);
        if (!wrote) return false;
        used += wrote;
    }
    return true;
}

int fail(std::string_view reason) {
    std::cerr << "DinoX fake vision worker: " << reason << '\n';
    return 1;
}

bool known_mode(const std::string& mode) {
    return mode == "normal" || mode == "no-face" || mode == "nan" ||
        mode == "bad-score" || mode == "bad-box" || mode == "bad-token" ||
        mode == "truncated" || mode == "sleep" || mode == "deadline" || mode == "exit";
}

uint32_t checksum(std::span<const uint8_t> bytes) {
    uint32_t hash = 2166136261u;
    for (uint8_t byte : bytes) hash = (hash ^ byte) * 16777619u;
    return hash;
}

void word32(std::span<uint8_t> bytes, size_t offset, uint32_t value) {
    if (bytes.size() < 4 || offset > bytes.size() - 4) std::abort();
    write32(bytes.subspan(offset).first<4>(), value);
}

void word64(std::span<uint8_t> bytes, size_t offset, uint64_t value) {
    if (bytes.size() < 8 || offset > bytes.size() - 8) std::abort();
    word32(bytes, offset, uint32_t(value));
    word32(bytes, offset + 4, uint32_t(value >> 32));
}

std::array<uint8_t, kFaceBytes> face_bytes(const std::string& mode) {
    // A partial canvas box is valid; clamping it would hide a projection bug.
    std::array<float, 17> face{
        0.75f, -0.2f, 0.1f, 0.8f, 0.9f,
        -0.1f, 0.35f, 0.5f, 0.35f, 0.2f, 0.5f,
        0.2f, 0.65f, -0.15f, 0.5f, 0.75f, 0.5f};
    if (mode == "nan") face[5] = std::numeric_limits<float>::quiet_NaN();
    if (mode == "bad-score") face[0] = 1.1f;
    if (mode == "bad-box") { face[1] = 0.8f; face[3] = 0.2f; }
    std::array<uint8_t, kFaceBytes> bytes{};
    static_assert(sizeof(float) == sizeof(uint32_t) && std::numeric_limits<float>::is_iec559);
    for (size_t i = 0; i < face.size(); ++i) {
        const auto bits = std::bit_cast<uint32_t>(face[i]);
        write32(std::span(bytes).subspan(i * sizeof(bits)).first<4>(), bits);
    }
    return bytes;
}

std::vector<uint8_t> marked_mask(const Request& request, uint64_t count,
        std::span<const uint8_t> segment, std::span<const uint8_t> face) {
    std::vector<uint8_t> mask(kMaskBytes, 200);
    const auto bytes = std::span(mask);
    // Test-only prefix: MARK/demand/ticket/source/revision/request counter/
    // call/transform/first RGB bytes/geometry/full owned-copy checksums.
    word32(bytes, 0, 0x4b52414d); word32(bytes, 4, request.demand);
    word64(bytes, 8, request.token.frame); word64(bytes, 16, request.token.source);
    word64(bytes, 24, request.token.revision); word64(bytes, 32, count);
    word64(bytes, 40, request.token.call); word64(bytes, 48, request.token.transform);
    bytes[56] = segment.empty() ? 0 : segment.front();
    bytes[57] = face.empty() ? 0 : face.front();
    word32(bytes, 58, request.width); word32(bytes, 62, request.height);
    word32(bytes, 66, request.rotation); word32(bytes, 70, request.mirrored ? 1 : 0);
    word32(bytes, 74, checksum(segment)); word32(bytes, 78, checksum(face));
    return mask;
}
} // namespace

int main(int argc, char** argv) {
    const auto arguments = main_arguments(argc, argv);
    std::string segment_mode, face_mode;
    for (size_t i = 1; i < arguments.size(); ++i) {
        const auto& flag = arguments[i];
        if (i + 1 >= arguments.size()) return fail("missing option value");
        if (flag == "--segmentation-model") segment_mode = arguments[++i];
        else if (flag == "--face-model") face_mode = arguments[++i];
        else return fail("unknown option");
    }
    if (!known_mode(segment_mode) || !known_mode(face_mode)) return fail("unknown test mode");
#if defined(_WIN32)
    if (_setmode(_fileno(stdin), _O_BINARY) < 0 ||
            _setmode(_fileno(stdout), _O_BINARY) < 0) return fail("binary pipe setup failed");
#endif
    const std::string mode = segment_mode == "normal" ? face_mode : segment_mode;
    uint64_t count = 0, last_ticket = 0, last_capture = 0;
    for (;;) {
        Header header{};
        const auto read_status = read_exact(header, true);
        if (read_status == ReadStatus::Eof) return 0;
        if (read_status != ReadStatus::Complete) return fail("truncated request header");
        const auto request = parse_request(header);
        if (!request) return fail("invalid request header");
        // Camera frame counters may reset after a logical binding change. Wire
        // tickets must still advance across source/config/demand transitions.
        if (request->token.frame <= last_ticket || request->token.capture_ns < last_capture) {
            return fail("nonmonotonic pipeline ticket");
        }
        last_ticket = request->token.frame;
        last_capture = request->token.capture_ns;
        std::vector<uint8_t> rgb(request->payload_bytes);
        if (read_exact(rgb) != ReadStatus::Complete) return fail("truncated RGB request");
        ++count;
        if (mode == "exit") return 3;
        if (mode == "sleep") std::this_thread::sleep_for(std::chrono::milliseconds(180));
        if (mode == "deadline") std::this_thread::sleep_for(std::chrono::seconds(5));
        const size_t segment_size = (request->demand & kSegmentDemand) ? kSegmentRgbBytes : 0;
        const auto segment = std::span<const uint8_t>(rgb).first(segment_size);
        const auto face = std::span<const uint8_t>(rgb).subspan(segment_size);
        const bool has_face = (request->demand & kFaceDemand) && mode != "no-face";
        auto response = response_header(*request, has_face);
        if (mode == "bad-token") write64(response, 40, request->token.frame + 1);
        if (!write_exact(response)) return fail("response header write failed");
        if (mode == "truncated") {
            const std::array<uint8_t, 7> fragment{};
            if (!write_exact(fragment) || std::fflush(stdout)) return fail("fragment write failed");
            return 0;
        }
        if ((request->demand & kSegmentDemand) &&
                !write_exact(marked_mask(*request, count, segment, face))) {
            return fail("mask write failed");
        }
        if (has_face && !write_exact(face_bytes(mode))) return fail("face write failed");
        if (std::fflush(stdout)) return fail("response flush failed");
    }
}
