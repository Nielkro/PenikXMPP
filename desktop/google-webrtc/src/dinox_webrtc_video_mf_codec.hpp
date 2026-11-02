#pragma once

#include <memory>
#include <optional>
#include "api/video/resolution.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_encoder.h"

namespace dinox::webrtc_runtime {
// Validates private DLL loading and codec configuration without needing a GPU.
bool IsH264MftProviderAvailable();
bool IsH264MftEncodeAvailable(const webrtc::SdpVideoFormat& format,
                            std::optional<webrtc::Resolution> resolution = std::nullopt);
bool IsH264MftDecodeAvailable(const webrtc::SdpVideoFormat& format);
std::unique_ptr<webrtc::VideoEncoder> CreateH264MftEncoder(const webrtc::SdpVideoFormat& format);
std::unique_ptr<webrtc::VideoDecoder> CreateH264MftDecoder(const webrtc::SdpVideoFormat& format);
}  // namespace dinox::webrtc_runtime
