#ifndef DINOX_WEBRTC_VIDEO_DECODER_FACTORY_HPP
#define DINOX_WEBRTC_VIDEO_DECODER_FACTORY_HPP

#include <memory>

namespace webrtc {
class VideoDecoderFactory;
class VideoEncoderFactory;
}

namespace dinox::webrtc_runtime {

// Creates the decoder factory used by the DinoX peer-connection factory.
// Hardware providers retain the built-in codec formats and use libwebrtc's
// software fallback wrappers independently for sending and receiving.
std::unique_ptr<webrtc::VideoDecoderFactory> CreateVideoDecoderFactory();
std::unique_ptr<webrtc::VideoEncoderFactory> CreateVideoEncoderFactory();

// Performs the first-use VP8 decode qualification used by decoder creation.
// Runs on the decode queue; concurrent calls keep software while it runs.
bool IsVp8VaapiDecodeAvailable();

// Reads the VP8 qualification cache without opening a device or decoding.
// Capability queries use this conservative path before first decoder creation.
bool IsVp8VaapiDecodeQualified();

// Checks the private FFmpeg provider without opening a GPU device. Linux
// runtime smoke tests use this to detect a missing or incorrectly bound
// provider even on hosts where the hardware test must be skipped.
bool IsVp8VaapiProviderAvailable();

}  // namespace dinox::webrtc_runtime

#endif  // DINOX_WEBRTC_VIDEO_DECODER_FACTORY_HPP
