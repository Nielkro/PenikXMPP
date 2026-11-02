#include "dinox_webrtc_video_decoder_factory.hpp"
#if !defined(_WIN32)
#include "dinox_webrtc_video_ffmpeg.hpp"
#else
#include "dinox_webrtc_video_mf_codec.hpp"
#endif

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "api/environment/environment_factory.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "api/video_codecs/builtin_video_decoder_factory.h"
#include "api/video_codecs/video_encoder_software_fallback_wrapper.h"
#include "api/video_codecs/video_decoder_software_fallback_wrapper.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_codec.h"
#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_encoder_factory.h"
#include "modules/video_coding/include/video_error_codes.h"

namespace {

constexpr int kWidth = 320;
constexpr int kHeight = 240;
constexpr int kFramesPerCycle = 6;

class EncodeCallback final : public webrtc::EncodedImageCallback {
 public:
    Result OnEncodedImage(
        const webrtc::EncodedImage& image,
        const webrtc::CodecSpecificInfo*) override {
        std::lock_guard<std::mutex> lock(mutex_);
        images_.push_back(image);
        condition_.notify_all();
        return Result(Result::OK);
    }

    void OnFrameDropped(uint32_t, int, bool) override {
        std::lock_guard<std::mutex> lock(mutex_);
        dropped_ = true;
        condition_.notify_all();
    }

    std::optional<webrtc::EncodedImage> take(uint32_t timestamp) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!condition_.wait_for(lock, std::chrono::seconds(2), [&] {
                return dropped_ || !images_.empty();
            }) || dropped_ || images_.size() != 1 ||
            images_.front().RtpTimestamp() != timestamp) {
            return std::nullopt;
        }
        webrtc::EncodedImage image = images_.front();
        images_.clear();
        return image;
    }

 private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::vector<webrtc::EncodedImage> images_;
    bool dropped_ = false;
};

class DecodeCallback final : public webrtc::DecodedImageCallback {
 public:
    int32_t Decoded(webrtc::VideoFrame& frame) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++frames_;
        timestamp_ = frame.rtp_timestamp();
        valid_ = frame.width() == kWidth && frame.height() == kHeight;
        const auto pixels = frame.video_frame_buffer()->ToI420();
        if (pixels == nullptr) {
            valid_ = false;
        } else {
            int64_t sum = 0;
            for (int row = 0; row < kHeight; ++row) {
                for (int column = 0; column < kWidth; ++column) {
                    sum += pixels->DataY()[row * pixels->StrideY() + column];
                }
            }
            average_luma_ = static_cast<int>(sum / (kWidth * kHeight));
        }
        condition_.notify_all();
        return WEBRTC_VIDEO_CODEC_OK;
    }

    bool wait_for_frame(int count, uint32_t timestamp, int expected_luma) {
        std::unique_lock<std::mutex> lock(mutex_);
        return condition_.wait_for(lock, std::chrono::seconds(2), [&] {
                   return frames_ >= count;
               }) && frames_ == count && valid_ && timestamp_ == timestamp &&
            std::abs(average_luma_ - expected_luma) <= 8;
    }

 private:
    std::mutex mutex_;
    std::condition_variable condition_;
    int frames_ = 0;
    uint32_t timestamp_ = 0;
    int average_luma_ = 0;
    bool valid_ = false;
};

int fail(const webrtc::SdpVideoFormat& format, const char* message) {
    std::fprintf(stderr, "FAIL: %s: %s\n", format.ToString().c_str(), message);
    return 1;
}

// Inject the same libwebrtc status returned by production hardware providers.
// The delegate generates real H264 frames, so transitions verify actual codec
// state, callback retention and the first software encoder's IDR, not mocks of
// the fallback wrapper itself.
struct FailureCounts { int frames = 0; int releases = 0; };

class FailingEncoder final : public webrtc::VideoEncoder {
 public:
    FailingEncoder(std::unique_ptr<webrtc::VideoEncoder> delegate, FailureCounts& counts,
                   bool fail_init, bool fail_runtime)
        : delegate_(std::move(delegate)), counts_(counts), fail_init_(fail_init), fail_runtime_(fail_runtime) {}
    int InitEncode(const webrtc::VideoCodec* codec, const Settings& settings) override {
        return fail_init_ ? WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE : delegate_->InitEncode(codec, settings);
    }
    int32_t RegisterEncodeCompleteCallback(webrtc::EncodedImageCallback* callback) override {
        return delegate_->RegisterEncodeCompleteCallback(callback);
    }
    int32_t Release() override { ++counts_.releases; return delegate_->Release(); }
    int32_t Encode(const webrtc::VideoFrame& frame, const std::vector<webrtc::VideoFrameType>* types) override {
        if (++counts_.frames == 2 && fail_runtime_) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        return delegate_->Encode(frame, types);
    }
    void SetRates(const RateControlParameters& rates) override { delegate_->SetRates(rates); }
    EncoderInfo GetEncoderInfo() const override {
        auto info = delegate_->GetEncoderInfo();
        info.is_hardware_accelerated = true;
        return info;
    }
 private:
    std::unique_ptr<webrtc::VideoEncoder> delegate_;
    FailureCounts& counts_;
    const bool fail_init_, fail_runtime_;
};

class FailingDecoder final : public webrtc::VideoDecoder {
 public:
    FailingDecoder(std::unique_ptr<webrtc::VideoDecoder> delegate, FailureCounts& counts,
                   bool fail_init, bool fail_runtime)
        : delegate_(std::move(delegate)), counts_(counts), fail_init_(fail_init), fail_runtime_(fail_runtime) {}
    bool Configure(const Settings& settings) override { return !fail_init_ && delegate_->Configure(settings); }
    int32_t RegisterDecodeCompleteCallback(webrtc::DecodedImageCallback* callback) override {
        return delegate_->RegisterDecodeCompleteCallback(callback);
    }
    int32_t Release() override { ++counts_.releases; return delegate_->Release(); }
    int32_t Decode(const webrtc::EncodedImage& image, int64_t render_time_ms) override {
        if (++counts_.frames == 2 && fail_runtime_) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        return delegate_->Decode(image, render_time_ms);
    }
    DecoderInfo GetDecoderInfo() const override { return {"injected hardware decoder", true}; }
 private:
    std::unique_ptr<webrtc::VideoDecoder> delegate_;
    FailureCounts& counts_;
    const bool fail_init_, fail_runtime_;
};

int fallback_roundtrip(const webrtc::Environment& environment, const webrtc::SdpVideoFormat& format) {
    auto encoders = webrtc::CreateBuiltinVideoEncoderFactory();
    auto decoders = webrtc::CreateBuiltinVideoDecoderFactory();
    struct Scenario { bool init, encoder, decoder; };
    for (const Scenario scenario : {Scenario{true, true, true}, Scenario{false, true, false},
                                   Scenario{false, false, true}, Scenario{false, true, true}}) {
        FailureCounts encoder_counts, decoder_counts;
        EncodeCallback encoded;
        DecodeCallback decoded;
        auto encoder = webrtc::CreateVideoEncoderSoftwareFallbackWrapper(environment,
            encoders->Create(environment, format), std::make_unique<FailingEncoder>(
                encoders->Create(environment, format), encoder_counts,
                scenario.init && scenario.encoder, !scenario.init && scenario.encoder), false);
        auto decoder = webrtc::CreateVideoDecoderSoftwareFallbackWrapper(environment,
            decoders->Create(environment, format), std::make_unique<FailingDecoder>(
                decoders->Create(environment, format), decoder_counts,
                scenario.init && scenario.decoder, !scenario.init && scenario.decoder));
        webrtc::VideoCodec codec;
        codec.codecType = webrtc::kVideoCodecH264;
        codec.width = kWidth; codec.height = kHeight;
        codec.maxFramerate = 30; codec.startBitrate = 600; codec.maxBitrate = 1000;
        codec.SetFrameDropEnabled(true);
        *codec.H264() = webrtc::VideoEncoder::GetDefaultH264Settings();
        webrtc::VideoDecoder::Settings settings;
        settings.set_codec_type(webrtc::kVideoCodecH264);
        settings.set_number_of_cores(2);
        settings.set_max_render_resolution(webrtc::RenderResolution(kWidth, kHeight));
        if (encoder->InitEncode(&codec, webrtc::VideoEncoder::Settings(
                webrtc::VideoEncoder::Capabilities(false), 2, 1200)) != WEBRTC_VIDEO_CODEC_OK ||
            !decoder->Configure(settings) ||
            encoder->RegisterEncodeCompleteCallback(&encoded) != WEBRTC_VIDEO_CODEC_OK ||
            decoder->RegisterDecodeCompleteCallback(&decoded) != WEBRTC_VIDEO_CODEC_OK) {
            return fail(format, "fallback initialization/callback registration failed");
        }
        webrtc::VideoBitrateAllocation bitrate;
        bitrate.SetBitrate(0, 0, 600000);
        encoder->SetRates(webrtc::VideoEncoder::RateControlParameters(bitrate, 30));
        int decoded_count = 0;
        for (int index = 0; index < 4; ++index) {
            const uint32_t timestamp = 0xfffff000u + static_cast<uint32_t>(index * 3000);
            const int luma = 90 + index * 6;
            auto pixels = webrtc::I420Buffer::Create(kWidth, kHeight);
            for (int y = 0; y < kHeight; ++y) std::memset(pixels->MutableDataY() + y * pixels->StrideY(), luma, kWidth);
            for (int y = 0; y < kHeight / 2; ++y) {
                std::memset(pixels->MutableDataU() + y * pixels->StrideU(), 90, kWidth / 2);
                std::memset(pixels->MutableDataV() + y * pixels->StrideV(), 240, kWidth / 2);
            }
            auto frame = webrtc::VideoFrame::Builder().set_video_frame_buffer(pixels)
                .set_rtp_timestamp(timestamp).set_timestamp_ms(1000 + index * 33).build();
            const std::vector<webrtc::VideoFrameType> types{index == 0 || index == 2
                ? webrtc::VideoFrameType::kVideoFrameKey : webrtc::VideoFrameType::kVideoFrameDelta};
            if (encoder->Encode(frame, &types) != WEBRTC_VIDEO_CODEC_OK) return fail(format, "runtime encoder fallback failed");
            const auto image = encoded.take(timestamp);
            if (!image || (!scenario.init && scenario.encoder && index == 1 && !image->IsKey())) {
                return fail(format, "fallback encoder lost callback/timestamp or did not start with an IDR");
            }
            const int status = decoder->Decode(*image, 1000 + index * 33);
            const bool lost_reference = !scenario.init && !scenario.encoder && scenario.decoder && index == 1;
            if (!lost_reference) {
                if (status != WEBRTC_VIDEO_CODEC_OK || !decoded.wait_for_frame(++decoded_count, timestamp, luma))
                    return fail(format, "decoder did not resume with exact frame metadata/pixels after fallback");
            }
            const bool encoder_hardware = !(scenario.encoder && (scenario.init || index >= 1));
            const bool decoder_hardware = !(scenario.decoder && (scenario.init || index >= 1));
            if (encoder->GetEncoderInfo().is_hardware_accelerated != encoder_hardware ||
                decoder->GetDecoderInfo().is_hardware_accelerated != decoder_hardware)
                return fail(format, "encoder and decoder did not fall back independently");
        }
        encoder->Release(); decoder->Release();
        if ((!scenario.init && scenario.encoder && encoder_counts.frames != 2) ||
            (!scenario.init && scenario.decoder && decoder_counts.frames != 2) ||
            (!scenario.init && (encoder_counts.releases == 0 || decoder_counts.releases == 0)))
            return fail(format, "failed hardware remained active or was not released");
    }
    std::puts("OK: real H264 init/runtime software fallback, independent directions, IDR and RTP wraparound");
    return 0;
}

int roundtrip(
    const webrtc::Environment& environment,
    webrtc::VideoEncoderFactory& encoders,
    webrtc::VideoDecoderFactory& decoders,
    const webrtc::SdpVideoFormat& format,
    bool hardware_encode, bool hardware_decode) {
    const auto encode_support = encoders.QueryCodecSupport(
        format, std::nullopt, std::nullopt);
    const auto decode_support = decoders.QueryCodecSupport(
        format, false, std::nullopt);
    if (!encode_support.is_supported || !decode_support.is_supported) {
        return fail(format, "advertised format cannot be encoded and decoded");
    }
    if (encode_support.is_power_efficient != hardware_encode || decode_support.is_power_efficient != hardware_decode) {
        return fail(format, "codec power-efficiency report does not match the requested path");
    }

    // Keep the callbacks alive until their codec instances are destroyed, also
    // on an early failure. Exercise the same factories used by live calls.
    EncodeCallback encoded;
    DecodeCallback decoded;
    auto encoder = encoders.Create(environment, format);
    auto decoder = decoders.Create(environment, format);
    if (encoder == nullptr || decoder == nullptr) {
        return fail(format, "factory failed to create an advertised codec");
    }

    webrtc::VideoCodec codec;
    codec.codecType = webrtc::PayloadStringToCodecType(format.name);
    codec.width = kWidth;
    codec.height = kHeight;
    codec.maxFramerate = 30;
    codec.startBitrate = 600;
    codec.maxBitrate = 1000;
    codec.minBitrate = 30;
    codec.qpMax = 56;
    codec.SetFrameDropEnabled(true);
    switch (codec.codecType) {
        case webrtc::kVideoCodecVP8:
            *codec.VP8() = webrtc::VideoEncoder::GetDefaultVp8Settings();
            break;
        case webrtc::kVideoCodecVP9:
            *codec.VP9() = webrtc::VideoEncoder::GetDefaultVp9Settings();
            break;
        case webrtc::kVideoCodecH264:
            *codec.H264() = webrtc::VideoEncoder::GetDefaultH264Settings();
            break;
        default:
            return fail(format, "unexpected codec selected by the test");
    }

    const webrtc::VideoEncoder::Settings encoder_settings(
        webrtc::VideoEncoder::Capabilities(false), 2, 1200);
    webrtc::VideoDecoder::Settings decoder_settings;
    decoder_settings.set_codec_type(codec.codecType);
    decoder_settings.set_number_of_cores(2);
    decoder_settings.set_max_render_resolution(
        webrtc::RenderResolution(kWidth, kHeight));

    for (int cycle = 0; cycle < 2; ++cycle) {
        if (encoder->InitEncode(&codec, encoder_settings) != WEBRTC_VIDEO_CODEC_OK ||
            !decoder->Configure(decoder_settings)) {
            return fail(format, "encoder/decoder initialization failed");
        }
        if (encoder->GetEncoderInfo().is_hardware_accelerated != hardware_encode ||
            decoder->GetDecoderInfo().is_hardware_accelerated != hardware_decode) {
            return fail(format, "active codec implementation does not match the requested path");
        }
        if (encoder->RegisterEncodeCompleteCallback(&encoded) != WEBRTC_VIDEO_CODEC_OK ||
            decoder->RegisterDecodeCompleteCallback(&decoded) != WEBRTC_VIDEO_CODEC_OK) {
            return fail(format, "codec callback registration failed");
        }
        webrtc::VideoBitrateAllocation bitrate;
        bitrate.SetBitrate(0, 0, 600000);
        encoder->SetRates(webrtc::VideoEncoder::RateControlParameters(bitrate, 30));

        for (int index = 0; index < kFramesPerCycle; ++index) {
            const int serial = cycle * kFramesPerCycle + index;
            const uint32_t timestamp = 90000 + serial * 3000;
            const int expected_luma = 80 + index * 7;
            auto pixels = webrtc::I420Buffer::Create(kWidth, kHeight);
            for (int row = 0; row < kHeight; ++row) {
                std::memset(pixels->MutableDataY() + row * pixels->StrideY(),
                            expected_luma, kWidth);
            }
            for (int row = 0; row < kHeight / 2; ++row) {
                std::memset(pixels->MutableDataU() + row * pixels->StrideU(), 90, kWidth / 2);
                std::memset(pixels->MutableDataV() + row * pixels->StrideV(), 240, kWidth / 2);
            }
            const webrtc::VideoFrame frame = webrtc::VideoFrame::Builder()
                .set_video_frame_buffer(pixels)
                .set_rtp_timestamp(timestamp)
                .set_timestamp_ms(1000 + serial * 33)
                .build();
            if (index == 0 && codec.codecType == webrtc::kVideoCodecH264) {
                const std::vector<webrtc::VideoFrameType> empty{webrtc::VideoFrameType::kEmptyFrame};
                if (encoder->Encode(frame, &empty) != WEBRTC_VIDEO_CODEC_OK) {
                    return fail(format, "explicitly omitted frame was not accepted");
                }
                // Any accidental output remains queued and makes take() below
                // reject the callback count for the following real keyframe.
            }
            const std::vector<webrtc::VideoFrameType> frame_types = {
                (index == 0 || index == 3) ? webrtc::VideoFrameType::kVideoFrameKey
                           : webrtc::VideoFrameType::kVideoFrameDelta,
            };
            if (encoder->Encode(frame, &frame_types) != WEBRTC_VIDEO_CODEC_OK) {
                return fail(format, "video frame encoding failed");
            }
            const auto image = encoded.take(timestamp);
            if (!image || image->size() == 0 ||
                ((index == 0 || index == 3) && image->FrameType() != webrtc::VideoFrameType::kVideoFrameKey)) {
                return fail(format, "encoded frame missing or timestamp/key frame incorrect");
            }
            if (decoder->Decode(*image, 1000 + serial * 33) != WEBRTC_VIDEO_CODEC_OK ||
                !decoded.wait_for_frame(serial + 1, timestamp, expected_luma)) {
                return fail(format, "decoded frame missing or dimensions/timestamp/pixels incorrect");
            }
        }
        if (encoder->GetEncoderInfo().is_hardware_accelerated != hardware_encode ||
            decoder->GetDecoderInfo().is_hardware_accelerated != hardware_decode) {
            return fail(format, "hardware codec silently fell back during the real frame test");
        }
        if (encoder->Release() != WEBRTC_VIDEO_CODEC_OK ||
            decoder->Release() != WEBRTC_VIDEO_CODEC_OK) {
            return fail(format, "codec release failed");
        }
    }

    std::printf("OK: %s: two encode/decode cycles, key and delta frames\n",
                format.ToString().c_str());
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    const bool hardware_encode = argc == 2 && std::strcmp(argv[1], "--require-hardware-encode") == 0;
    const bool hardware_decode = argc == 2 && std::strcmp(argv[1], "--require-hardware-decode") == 0;
    const bool runtime_failure = argc == 2 && std::strcmp(argv[1], "--runtime-failure") == 0;
    const bool unavailable = argc == 2 && std::strcmp(argv[1], "--unavailable-device") == 0;
    if (argc > 2 || (argc == 2 && !hardware_encode && !hardware_decode && !unavailable && !runtime_failure)) return 1;
    // Prove the portable baseline even when a Linux VA-API device is available.
#if defined(_WIN32)
    if (_putenv_s("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER", "1") != 0) return 1;
#else
    if (setenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER", "1", 1) != 0) return 1;
#endif
#if defined(_WIN32)
    _putenv_s("DINOX_WEBRTC_DISABLE_H264_HW_ENCODER", hardware_encode || unavailable ? "0" : "1");
    _putenv_s("DINOX_WEBRTC_DISABLE_H264_HW_DECODER", hardware_decode || unavailable ? "0" : "1");
    if ((hardware_encode || hardware_decode || unavailable) &&
        !dinox::webrtc_runtime::IsH264MftProviderAvailable()) {
        std::fputs("FAIL: private Windows H264 MF/D3D11 provider is missing or incorrectly bound\n", stderr);
        return 1;
    }
#else
    setenv("DINOX_WEBRTC_DISABLE_H264_HW_ENCODER", hardware_encode || unavailable ? "0" : "1", 1);
    setenv("DINOX_WEBRTC_DISABLE_H264_HW_DECODER", hardware_decode || unavailable ? "0" : "1", 1);
    if (unavailable) {
        setenv("DINOX_WEBRTC_VAAPI_DEVICE", "/nonexistent/dinox-vaapi-smoke", 1);
        setenv("DINOX_WEBRTC_DISABLE_CUDA", "1", 1);
    }
    if ((hardware_encode || hardware_decode || unavailable) &&
        !dinox::webrtc_runtime::IsH264FfmpegProviderAvailable()) {
        std::fputs("FAIL: private H264 VAAPI/NVENC provider is missing or incorrectly bound\n", stderr);
        return 1;
    }
#endif
    const webrtc::Environment environment = webrtc::CreateEnvironment();
    if (runtime_failure) {
        const webrtc::SdpVideoFormat format("H264", {{"profile-level-id", "42e01f"},
            {"packetization-mode", "1"}, {"level-asymmetry-allowed", "1"}});
        return fallback_roundtrip(environment, format);
    }
    auto encoders = dinox::webrtc_runtime::CreateVideoEncoderFactory();
    auto decoders = dinox::webrtc_runtime::CreateVideoDecoderFactory();
    bool tested_hardware = false;
    bool tested_vp8 = false;
    bool tested_vp9 = false;
    bool tested_h264_mode0 = false;
    bool tested_h264_mode1 = false;
    for (const auto& format : encoders->GetSupportedFormats()) {
        if (hardware_encode || hardware_decode) {
            if (format.name != "H264") continue;
            const auto encoder = encoders->QueryCodecSupport(format, std::nullopt, std::nullopt);
            const auto decoder = decoders->QueryCodecSupport(format, false, std::nullopt);
            if ((hardware_encode && !encoder.is_power_efficient) ||
                (hardware_decode && !decoder.is_power_efficient)) continue;
            tested_hardware = true;
        }
        if (format.name == "VP8") {
            tested_vp8 = true;
        } else if (format.name == "VP9") {
            const auto profile = format.parameters.find("profile-id");
            if (profile != format.parameters.end() && profile->second != "0") continue;
            tested_vp9 = true;
        } else if (format.name == "H264") {
            const auto mode = format.parameters.find("packetization-mode");
            if (mode == format.parameters.end() || mode->second == "0") {
                tested_h264_mode0 = true;
            } else if (mode->second == "1") {
                tested_h264_mode1 = true;
            }
        } else {
            continue;
        }
        if (roundtrip(environment, *encoders, *decoders, format, hardware_encode, hardware_decode) != 0) return 1;
    }
    if (hardware_encode || hardware_decode) {
        if (!tested_hardware) {
            std::puts("SKIP: H264 hardware codec with the required realtime capabilities is unavailable");
            return 77;
        }
        return 0;
    }
    if (!tested_vp8 || !tested_vp9 || !tested_h264_mode0 || !tested_h264_mode1) {
        std::fputs("FAIL: M152 must offer VP8, VP9 profile 0 and both H.264 packetization modes\n",
                   stderr);
        return 1;
    }
    return 0;
}
