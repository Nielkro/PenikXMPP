#include "dinox_webrtc_video_mf_codec.hpp"

#include <cstdio>
#include <cstring>
#include "api/video_codecs/sdp_video_format.h"

namespace {
webrtc::SdpVideoFormat H264(const char* profile, const char* mode) {
    webrtc::CodecParameterMap parameters;
    parameters["profile-level-id"] = profile;
    if (mode) parameters["packetization-mode"] = mode;
    return webrtc::SdpVideoFormat("H264", parameters);
}
}  // namespace

int main(int argc, char** argv) {
    using namespace dinox::webrtc_runtime;
    const bool no_hardware = argc == 2 && std::strcmp(argv[1], "--expect-no-hardware") == 0;
    if (argc > 2 || (argc == 2 && !no_hardware)) return 1;
    // This must succeed even on a VM without GPU video facilities, otherwise
    // software fallback could conceal a packaging/FFmpeg isolation regression.
    if (!IsH264MftProviderAvailable()) {
        std::fputs("FAIL: private Windows FFmpeg MF/D3D11 provider unavailable\n", stderr);
        return 1;
    }
    for (const auto& format : {webrtc::SdpVideoFormat("VP8"), webrtc::SdpVideoFormat("VP9"),
            H264("invalid", "1"), H264("42e01f", "2"), H264("f4001f", "1")}) {
        if (IsH264MftEncodeAvailable(format) || IsH264MftDecodeAvailable(format) ||
            CreateH264MftEncoder(format) || CreateH264MftDecoder(format)) {
            std::fputs("FAIL: Windows hardware provider accepted an unsupported SDP format\n", stderr);
            return 1;
        }
    }
    const char* single_nal_modes[] = {nullptr, "0"};
    for (const char* mode : single_nal_modes) {
        const auto format = H264("42e01f", mode);
        if (IsH264MftEncodeAvailable(format) || CreateH264MftEncoder(format)) {
            std::fputs("FAIL: MF cannot guarantee single-NAL packetization\n", stderr);
            return 1;
        }
    }
    for (const char* profile : {"42e01f", "42001f", "4d001f", "64001f"}) {
        const auto format = H264(profile, "1");
        const bool encode = IsH264MftEncodeAvailable(format);
        const bool decode = IsH264MftDecodeAvailable(format);
        std::printf("H264 %s: MF hardware encoder=%d D3D11 hardware decoder=%d\n", profile, encode, decode);
        if (no_hardware && (encode || decode || CreateH264MftEncoder(format) || CreateH264MftDecoder(format))) {
            std::fputs("FAIL: VM without video hardware was marked hardware accelerated\n", stderr);
            return 1;
        }
    }
    std::puts("OK: private Windows provider, SDP guards and hardware capability reporting");
    return 0;
}
