#ifndef DINOX_VISION_PROTOCOL_HPP
#define DINOX_VISION_PROTOCOL_HPP

// Private bounded inference transport. This does not carry XMPP/Jingle messages.
// Wire integers are little endian; no native pointers, filenames or ABI padding.
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <span>

namespace dinox::vision {
constexpr uint32_t kProtocolVersion = 1;
constexpr size_t kHeaderBytes = 96;
constexpr uint32_t kRequestMagic = 0x51455256; // VREQ
constexpr uint32_t kResponseMagic = 0x53455256; // VRES
constexpr uint32_t kSegmentDemand = 1;
constexpr uint32_t kFaceDemand = 2;
constexpr size_t kSegmentRgbBytes = 256 * 144 * 3;
constexpr size_t kFaceRgbBytes = 128 * 128 * 3;
constexpr size_t kMaskBytes = 256 * 144;
constexpr size_t kFaceBytes = 17 * sizeof(uint32_t);
constexpr size_t kMaxPayloadBytes = kSegmentRgbBytes + kFaceRgbBytes;
constexpr uint64_t kMaxResultAgeNs = 500000000;
using Header = std::array<uint8_t, kHeaderBytes>;

inline uint32_t read32(std::span<const uint8_t, 4> bytes) {
    return uint32_t(bytes[0]) | (uint32_t(bytes[1]) << 8) |
        (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
}
inline void write32(std::span<uint8_t, 4> bytes, uint32_t value) {
    for (size_t i=0;i<4;++i) bytes[i]=uint8_t(value>>(i*8));
}

inline uint32_t read32(const Header& bytes, size_t offset) {
    if (offset > kHeaderBytes - 4) std::abort();
    return uint32_t(bytes[offset]) | (uint32_t(bytes[offset+1]) << 8) |
        (uint32_t(bytes[offset+2]) << 16) | (uint32_t(bytes[offset+3]) << 24);
}
inline uint64_t read64(const Header& bytes, size_t offset) {
    if (offset > kHeaderBytes - 8) std::abort();
    return read32(bytes,offset) | (uint64_t(read32(bytes,offset+4)) << 32);
}
inline void write32(Header& bytes, size_t offset, uint32_t value) {
    if (offset > kHeaderBytes - 4) std::abort();
    for (size_t i=0;i<4;++i) bytes[offset+i]=uint8_t(value>>(i*8));
}
inline void write64(Header& bytes, size_t offset, uint64_t value) {
    if (offset > kHeaderBytes - 8) std::abort();
    write32(bytes,offset,uint32_t(value));write32(bytes,offset+4,uint32_t(value>>32));
}

// Compatibility boundary for an already validated, readable/writable 4/8-byte
// region. Packet fields use the bounded Header overloads above. The pointer
// signature cannot encode the extent; callers must prove it before invocation.
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
inline uint32_t read32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
        (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline uint64_t read64(const uint8_t* p) {
    return read32(p) | (uint64_t(read32(p + 4)) << 32);
}
inline void write32(uint8_t* p, uint32_t value) {
    for (size_t i = 0; i < 4; ++i) p[i] = uint8_t(value >> (i * 8));
}
inline void write64(uint8_t* p, uint64_t value) {
    write32(p, uint32_t(value)); write32(p + 4, uint32_t(value >> 32));
}
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif

struct FrameToken {
    uint64_t call = 0, source = 0, revision = 0, frame = 0;
    uint64_t capture_ns = 0, transform = 0;
};
struct Request {
    FrameToken token;
    uint32_t demand = 0, width = 0, height = 0, rotation = 0;
    bool mirrored = false;
    size_t payload_bytes = 0;
};
inline size_t payload_size(uint32_t demand) {
    return ((demand & kSegmentDemand) ? kSegmentRgbBytes : 0) +
        ((demand & kFaceDemand) ? kFaceRgbBytes : 0);
}
inline std::optional<Request> parse_request(const Header& bytes) {
    if (read32(bytes, 0) != kRequestMagic || read32(bytes, 4) != kProtocolVersion ||
            read32(bytes, 8) != kHeaderBytes || read32(bytes, 84) || read64(bytes, 88)) {
        return std::nullopt;
    }
    Request r;
    r.token = {read64(bytes, 16), read64(bytes, 24), read64(bytes, 32),
        read64(bytes, 40), read64(bytes, 48), read64(bytes, 56)};
    r.demand = read32(bytes, 64); r.width = read32(bytes, 68);
    r.height = read32(bytes, 72); r.rotation = read32(bytes, 76);
    const auto mirrored = read32(bytes, 80);
    if (!r.token.call || !r.token.source || !r.token.revision || !r.token.frame ||
            !r.token.capture_ns || !r.token.transform || r.demand < 1 || r.demand > 3 ||
            !r.width || !r.height || r.width > 4096 || r.height > 4096 ||
            uint64_t(r.width) * r.height > uint64_t(4096) * 2160 ||
            (r.rotation != 0 && r.rotation != 90 && r.rotation != 180 && r.rotation != 270) ||
            mirrored > 1) return std::nullopt;
    r.mirrored = mirrored != 0;
    r.payload_bytes = payload_size(r.demand);
    if (read32(bytes, 12) != kHeaderBytes + r.payload_bytes) return std::nullopt;
    return r;
}
inline bool same_generation(const FrameToken& a, const FrameToken& b) {
    return a.call == b.call && a.source == b.source &&
        a.revision == b.revision && a.transform == b.transform;
}
inline bool result_is_fresh(const FrameToken& result, const FrameToken& desired,
        uint64_t now_ns) {
    return result.call && result.source && result.revision && result.frame &&
        result.capture_ns && result.transform && same_generation(result, desired) &&
        result.frame <= desired.frame && result.capture_ns <= desired.capture_ns &&
        (result.frame != desired.frame || result.capture_ns == desired.capture_ns) &&
        result.capture_ns <= now_ns && now_ns - result.capture_ns <= kMaxResultAgeNs;
}
inline Header response_header(const Request& request, bool has_face) {
    has_face = has_face && (request.demand & kFaceDemand);
    Header bytes{};
    write32(bytes, 0, kResponseMagic); write32(bytes, 4, kProtocolVersion);
    write32(bytes, 8, kHeaderBytes);
    const auto mask_bytes = (request.demand & kSegmentDemand) ? kMaskBytes : 0;
    const auto face_bytes = has_face ? kFaceBytes : 0;
    write32(bytes, 12, uint32_t(kHeaderBytes + mask_bytes + face_bytes));
    const auto& t = request.token;
    write64(bytes, 16, t.call); write64(bytes, 24, t.source);
    write64(bytes, 32, t.revision); write64(bytes, 40, t.frame);
    write64(bytes, 48, t.capture_ns); write64(bytes, 56, t.transform);
    write32(bytes, 64, 0); // status OK; failed inference terminates isolated worker.
    write32(bytes, 68, request.demand);
    write32(bytes, 72, mask_bytes ? 256 : 0); write32(bytes, 76, mask_bytes ? 144 : 0);
    write32(bytes, 80, has_face ? 1 : 0); write32(bytes, 84, uint32_t(mask_bytes));
    write32(bytes, 88, uint32_t(face_bytes));
    return bytes;
}
struct Response {
    FrameToken token;
    uint32_t demand = 0;
    bool has_face = false;
    size_t mask_bytes = 0, face_bytes = 0, payload_bytes = 0;
};
inline std::optional<Response> parse_response(const Header& bytes, const Request& expected) {
    if (read32(bytes, 0) != kResponseMagic || read32(bytes, 4) != kProtocolVersion ||
            read32(bytes, 8) != kHeaderBytes || read32(bytes, 64) || read32(bytes, 92)) {
        return std::nullopt;
    }
    Response r;
    r.token = {read64(bytes, 16), read64(bytes, 24), read64(bytes, 32),
        read64(bytes, 40), read64(bytes, 48), read64(bytes, 56)};
    r.demand = read32(bytes, 68);
    const auto face_count = read32(bytes, 80);
    if (!same_generation(r.token, expected.token) ||
            r.token.frame != expected.token.frame || r.token.capture_ns != expected.token.capture_ns ||
            r.demand != expected.demand || face_count > 1 ||
            (face_count && !(r.demand & kFaceDemand))) return std::nullopt;
    r.has_face = face_count == 1;
    r.mask_bytes = (r.demand & kSegmentDemand) ? kMaskBytes : 0;
    r.face_bytes = r.has_face ? kFaceBytes : 0;
    r.payload_bytes = r.mask_bytes + r.face_bytes;
    if (read32(bytes, 72) != (r.mask_bytes ? 256 : 0) ||
            read32(bytes, 76) != (r.mask_bytes ? 144 : 0) ||
            read32(bytes, 84) != r.mask_bytes || read32(bytes, 88) != r.face_bytes ||
            read32(bytes, 12) != kHeaderBytes + r.payload_bytes) return std::nullopt;
    return r;
}
} // namespace dinox::vision
#endif
