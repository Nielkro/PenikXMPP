#include "dinox_webrtc_video_decoder_factory.hpp"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "absl/strings/match.h"
#include "api/environment/environment.h"
#include "api/video/resolution.h"
#include "api/video_codecs/builtin_video_decoder_factory.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "api/video_codecs/video_decoder_software_fallback_wrapper.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_encoder_factory.h"
#include "api/video_codecs/video_encoder_software_fallback_wrapper.h"

#if defined(_WIN32)
#include "dinox_webrtc_video_mf_codec.hpp"
#else
#include "dinox_webrtc_video_ffmpeg.hpp"
#endif

namespace dinox::webrtc_runtime {
namespace {

bool disabled(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && (std::strcmp(value, "1") == 0 ||
        std::strcmp(value, "true") == 0 || std::strcmp(value, "yes") == 0);
}

bool hardware_encode_available(const webrtc::SdpVideoFormat& format,
                              std::optional<webrtc::Resolution> resolution) {
    if (!absl::EqualsIgnoreCase(format.name, "H264") ||
        disabled("DINOX_WEBRTC_DISABLE_H264_HW_ENCODER")) return false;
#if defined(_WIN32)
    return IsH264MftEncodeAvailable(format, resolution);
#else
    return IsH264FfmpegEncodeAvailable(format, resolution);
#endif
}

bool hardware_decode_available(const webrtc::SdpVideoFormat& format) {
    if (absl::EqualsIgnoreCase(format.name, "H264")) {
        if (disabled("DINOX_WEBRTC_DISABLE_H264_HW_DECODER")) return false;
#if defined(_WIN32)
        return IsH264MftDecodeAvailable(format);
#else
        return IsH264FfmpegDecodeAvailable(format);
#endif
    }
#if !defined(_WIN32)
    return absl::EqualsIgnoreCase(format.name, "VP8") && IsVp8VaapiDecodeQualified();
#else
    return false;
#endif
}

class DinoXVideoEncoderFactory final : public webrtc::VideoEncoderFactory {
 public:
    DinoXVideoEncoderFactory() : builtin_(webrtc::CreateBuiltinVideoEncoderFactory()) {}

    std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
        return builtin_->GetSupportedFormats();
    }

    CodecSupport QueryCodecSupport(const webrtc::SdpVideoFormat& format,
                                  std::optional<std::string> scalability_mode,
                                  std::optional<webrtc::Resolution> resolution) const override {
        CodecSupport support = builtin_->QueryCodecSupport(format, scalability_mode, resolution);
        if (support.is_supported && (!scalability_mode || *scalability_mode == "L1T1")) {
            support.is_power_efficient = hardware_encode_available(format, resolution);
        }
        return support;
    }

    std::unique_ptr<webrtc::VideoEncoder> Create(const webrtc::Environment& environment,
                                               const webrtc::SdpVideoFormat& format) override {
        auto software = builtin_->Create(environment, format);
        if (software == nullptr || !hardware_encode_available(format, std::nullopt)) return software;
#if defined(_WIN32)
        auto hardware = CreateH264MftEncoder(format);
#else
        auto hardware = CreateFfmpegHardwareEncoder(format);
#endif
        if (hardware == nullptr) return software;
        return webrtc::CreateVideoEncoderSoftwareFallbackWrapper(
            environment, std::move(software), std::move(hardware), false);
    }

 private:
    std::unique_ptr<webrtc::VideoEncoderFactory> builtin_;
};

class DinoXVideoDecoderFactory final : public webrtc::VideoDecoderFactory {
 public:
    DinoXVideoDecoderFactory() : builtin_(webrtc::CreateBuiltinVideoDecoderFactory()) {}

    std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
        return builtin_->GetSupportedFormats();
    }

    CodecSupport QueryCodecSupport(const webrtc::SdpVideoFormat& format,
                                  bool reference_scaling,
                                  std::optional<webrtc::Resolution> resolution) const override {
        CodecSupport support = builtin_->QueryCodecSupport(format, reference_scaling, resolution);
        if (support.is_supported && !reference_scaling) {
            support.is_power_efficient = hardware_decode_available(format);
        }
        return support;
    }

    std::unique_ptr<webrtc::VideoDecoder> Create(const webrtc::Environment& environment,
                                               const webrtc::SdpVideoFormat& format) override {
        auto software = builtin_->Create(environment, format);
        if (software == nullptr) return software;
        if (absl::EqualsIgnoreCase(format.name, "H264") &&
            disabled("DINOX_WEBRTC_DISABLE_H264_HW_DECODER")) return software;
#if defined(_WIN32)
        auto hardware = CreateH264MftDecoder(format);
#else
        if (absl::EqualsIgnoreCase(format.name, "VP8") && !IsVp8VaapiDecodeAvailable()) return software;
        auto hardware = CreateFfmpegHardwareDecoder(format);
#endif
        if (hardware == nullptr) return software;
        return webrtc::CreateVideoDecoderSoftwareFallbackWrapper(
            environment, std::move(software), std::move(hardware));
    }

 private:
    std::unique_ptr<webrtc::VideoDecoderFactory> builtin_;
};

}  // namespace

std::unique_ptr<webrtc::VideoEncoderFactory> CreateVideoEncoderFactory() {
    return std::make_unique<DinoXVideoEncoderFactory>();
}

std::unique_ptr<webrtc::VideoDecoderFactory> CreateVideoDecoderFactory() {
    return std::make_unique<DinoXVideoDecoderFactory>();
}

}  // namespace dinox::webrtc_runtime
