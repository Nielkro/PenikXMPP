#include "vision_inference.hpp"
#include "vision_protocol.hpp"
#include <array>
#include <bit>
#include <cstdio>
#include <cstring>
#include <memory>
#include <iostream>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#endif

namespace {
using namespace dinox::vision;
enum class ReadStatus { Complete, Eof, Truncated };
ReadStatus read_exact(std::span<uint8_t> bytes, bool allow_eof = false) {
    size_t used = 0;
    while (used < bytes.size()) {
        const auto remaining = bytes.subspan(used);
        // C stdio cannot encode a span; the exact remaining extent is passed.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
        const size_t got = std::fread(remaining.data(), 1, remaining.size(), stdin);
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
        if (!got) return allow_eof && used == 0 && std::feof(stdin) ?
            ReadStatus::Eof : ReadStatus::Truncated;
        used += got;
    }
    return ReadStatus::Complete;
}
bool write_exact(std::span<const uint8_t> bytes) {
    size_t used = 0;
    while (used < bytes.size()) {
        const auto remaining = bytes.subspan(used);
        // Same checked C stdio boundary as read_exact().
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
        const size_t wrote = std::fwrite(remaining.data(), 1, remaining.size(), stdout);
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
        if (!wrote) return false;
        used += wrote;
    }
    return true;
}
void encode_float(std::span<uint8_t,4> out, float value) {
    static_assert(sizeof(float) == sizeof(uint32_t));
    write32(out, std::bit_cast<uint32_t>(value));
}
std::array<uint8_t, kFaceBytes> encode_face(const Face& face) {
    std::array<uint8_t, kFaceBytes> bytes{};
    size_t index = 0;
    for (float value : {face.score, face.left, face.top, face.right, face.bottom}) {
        encode_float(std::span(bytes).subspan(index * 4).first<4>(), value); ++index;
    }
    for (const auto& point : face.points) {
        encode_float(std::span(bytes).subspan(index++ * 4).first<4>(), point.x);
        encode_float(std::span(bytes).subspan(index++ * 4).first<4>(), point.y);
    }
    return bytes;
}
int fail(std::string_view reason) {
    // No camera bytes, identifiers, image paths or model contents in logs.
    std::cerr << "DinoX vision worker: " << reason << '\n';
    return 1;
}
} // namespace

int run_worker(std::span<const std::string> arguments) {
    std::string segment_path, face_path;
    for (size_t i = 1; i < arguments.size(); ++i) {
        const auto& flag = arguments[i];
        if (flag == "--help") {
            std::puts("dinox-vision-worker --segmentation-model FILE --face-model FILE");
            std::puts("Bounded protocol v1 on binary stdin/stdout; models are SHA256 pinned.");
            return 0;
        }
        if (i + 1 >= arguments.size()) return fail("missing option value");
        if (flag == "--segmentation-model") segment_path = arguments[++i];
        else if (flag == "--face-model") face_path = arguments[++i];
        else return fail("unknown option");
    }
#if defined(_WIN32)
    if (_setmode(_fileno(stdin), _O_BINARY) < 0 ||
            _setmode(_fileno(stdout), _O_BINARY) < 0) return fail("binary pipe setup failed");
#endif
    // Demand-free startup loads no model or RGB buffer. The parent owns the
    // deadline/kill policy and must discard late output after hangup/off.
    std::unique_ptr<ModelRuntime> segment, face;
    std::optional<Face> previous_face;
    std::optional<Request> previous_request;
    for (;;) {
        Header header{};
        const auto read_status = read_exact(header, true);
        if (read_status == ReadStatus::Eof) return 0;
        if (read_status != ReadStatus::Complete) return fail("truncated header");
        const auto request = parse_request(header);
        if (!request) return fail("invalid header");
        if (previous_request) {
            const auto& before = previous_request->token;
            const auto& after = request->token;
            if (after.call != before.call || after.source < before.source ||
                    after.revision < before.revision ||
                    (after.source == before.source && after.frame <= before.frame) ||
                    after.capture_ns < before.capture_ns) return fail("invalid request sequence");
            if (after.source != before.source || after.transform != before.transform) {
                previous_face.reset();
            }
        }
        // A disabled task releases its complete model/interpreter/delegate even
        // when the other task remains active in this same isolated process.
        if (!(request->demand & kSegmentDemand)) segment.reset();
        if (!(request->demand & kFaceDemand)) { face.reset(); previous_face.reset(); }
        std::vector<uint8_t> rgb(request->payload_bytes);
        if (read_exact(rgb) != ReadStatus::Complete) return fail("truncated RGB input");
        std::vector<uint8_t> mask;
        std::optional<Face> detected;
        size_t offset = 0;
        if (request->demand & kSegmentDemand) {
            if (!segment) segment = ModelRuntime::create(ModelTask::Segmentation, segment_path);
            if (!segment) return fail("segmentation model initialization failed");
            mask.resize(kMaskBytes);
            if (!segment->segment(std::span(rgb).subspan(offset, kSegmentRgbBytes), mask)) {
                return fail("segmentation invocation failed");
            }
            offset += kSegmentRgbBytes;
        }
        if (request->demand & kFaceDemand) {
            if (!face) face = ModelRuntime::create(ModelTask::Face, face_path);
            if (!face) return fail("face model initialization failed");
            if (!face->face(std::span(rgb).subspan(offset, kFaceRgbBytes),
                    previous_face ? &*previous_face : nullptr, &detected)) {
                return fail("face invocation failed");
            }
            previous_face = detected;
        }
        const auto response = response_header(*request, bool(detected));
        if (!write_exact(response) || (!mask.empty() && !write_exact(mask))) {
            return fail("response write failed");
        }
        if (detected && !write_exact(encode_face(*detected))) return fail("face write failed");
        if (std::fflush(stdout) != 0) return fail("response flush failed");
        previous_request = request;
    }
}

#if defined(_WIN32)
int wmain(int argc, wchar_t** wide_argv) {
    std::vector<std::string> storage;
    if (argc < 1 || argc > 32 || !wide_argv) return fail("invalid argument count");
    storage.reserve(size_t(argc));
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    for (int i = 0; i < argc; ++i) {
        const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            wide_argv[i], -1, nullptr, 0, nullptr, nullptr);
        if (length <= 0 || length > 131072) return fail("invalid UTF-16 launch argument");
        std::string value(size_t(length), '\0');
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide_argv[i], -1,
                value.data(), length, nullptr, nullptr) != length) {
            return fail("UTF-16 launch argument conversion failed");
        }
        value.pop_back();
        storage.push_back(std::move(value));
    }
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    return run_worker(storage);
}
#else
int main(int argc, char** argv) {
    if (argc < 1 || argc > 32 || !argv) return fail("invalid argument count");
    std::vector<std::string> arguments;
    arguments.reserve(size_t(argc));
    // The platform entrypoint owns exactly argc NUL-terminated C arguments.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    for (int i=0;i<argc;++i) {
        if (!argv[i]) return fail("invalid argument");
        arguments.emplace_back(argv[i]);
    }
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
    return run_worker(arguments);
}
#endif
