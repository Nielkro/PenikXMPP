#ifndef DINOX_WEBRTC_VIDEO_FFMPEG_HPP
#define DINOX_WEBRTC_VIDEO_FFMPEG_HPP

#include <memory>
#include <optional>

#include "api/video/resolution.h"
#include "api/video_codecs/sdp_video_format.h"

namespace webrtc {
class VideoDecoder;
class VideoEncoder;
}

namespace dinox::webrtc_runtime {

bool IsH264FfmpegEncodeAvailable(const webrtc::SdpVideoFormat& format,
                               std::optional<webrtc::Resolution> resolution = std::nullopt);
bool IsH264FfmpegDecodeAvailable(const webrtc::SdpVideoFormat& format);
bool IsH264FfmpegProviderAvailable();
std::unique_ptr<webrtc::VideoEncoder> CreateFfmpegHardwareEncoder(
    const webrtc::SdpVideoFormat& format);
std::unique_ptr<webrtc::VideoDecoder> CreateFfmpegHardwareDecoder(
    const webrtc::SdpVideoFormat& format);

}  // namespace dinox::webrtc_runtime

#endif
