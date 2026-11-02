#include "dinox_webrtc_video_decoder_factory.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <vector>

#include "api/environment/environment_factory.h"
#include "api/video/encoded_image.h"
#include "api/video/render_resolution.h"
#include "api/video/video_frame.h"
#include "api/video/video_frame_type.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "modules/video_coding/include/video_error_codes.h"

namespace {

// One generated 320x240 solid-red VP8 key frame. The fixture contains only the
// VP8 frame payload, not its IVF container header.
constexpr uint8_t kVp8KeyFrame[] = {
    0x10, 0x13, 0x00, 0x9d, 0x01, 0x2a, 0x40, 0x01, 0xf0, 0x00, 0x00, 0x47,
    0x08, 0x85, 0x85, 0x88, 0x99, 0x84, 0x88, 0x02, 0x02, 0x02, 0x75, 0xaa,
    0x03, 0xf8, 0x03, 0xfa, 0x02, 0x06, 0xb6, 0xa5, 0xa8, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39, 0xc3, 0xd9, 0x39,
    0xc3, 0xd9, 0x39, 0xc3, 0xc8, 0x00, 0xfe, 0xfd, 0x6e, 0xf3, 0xff, 0xe4,
    0x6f, 0xe3, 0xe7, 0x46, 0xff, 0xc8, 0xe3, 0xff, 0xfc, 0x4a, 0x9e, 0xe3,
    0x89, 0xe3, 0xff, 0xfc, 0x46, 0x80,
};

class DecodeCallback final : public webrtc::DecodedImageCallback {
 public:
    int32_t Decoded(webrtc::VideoFrame& frame) override {
        ++frames;
        width = frame.width();
        height = frame.height();
        return WEBRTC_VIDEO_CODEC_OK;
    }

    int frames = 0;
    int width = 0;
    int height = 0;
};

int fail(const char* message) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

bool offers_format(
    const std::vector<webrtc::SdpVideoFormat>& formats,
    const char* expected_name) {
    for (const webrtc::SdpVideoFormat& format : formats) {
        if (format.name == expected_name) {
            return true;
        }
    }
    return false;
}

int run_decode(bool require_hardware, bool automatic) {
    if (!dinox::webrtc_runtime::IsVp8VaapiProviderAvailable()) {
        return fail("private FFmpeg VP8/VA-API provider is missing or incorrectly bound");
    }
    if (require_hardware) {
        unsetenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER");
        if (!dinox::webrtc_runtime::IsVp8VaapiDecodeAvailable()) {
            std::puts("SKIP: VA-API VP8/VLD is unavailable");
            return 77;
        }
    } else if (automatic) {
        unsetenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER");
    } else {
        setenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER", "1", 1);
    }

    webrtc::Environment environment = webrtc::CreateEnvironment();
    std::unique_ptr<webrtc::VideoDecoderFactory> factory =
        dinox::webrtc_runtime::CreateVideoDecoderFactory();
    const std::vector<webrtc::SdpVideoFormat> decoder_formats =
        factory->GetSupportedFormats();
    if (!offers_format(decoder_formats, "VP8")) {
        return fail("decoder factory does not advertise VP8");
    }
    if (!offers_format(decoder_formats, "H264") ||
        !offers_format(decoder_formats, "VP9")) {
        return fail("M152 decoder factory must retain H.264 and VP9 alongside VP8");
    }

    std::unique_ptr<webrtc::VideoEncoderFactory> encoder_factory =
        webrtc::CreateBuiltinVideoEncoderFactory();
    const std::vector<webrtc::SdpVideoFormat> encoder_formats =
        encoder_factory->GetSupportedFormats();
    if (!offers_format(encoder_formats, "VP8")) {
        return fail("encoder factory does not advertise VP8");
    }
    if (!offers_format(encoder_formats, "H264") ||
        !offers_format(encoder_formats, "VP9")) {
        return fail("M152 encoder factory must retain H.264 and VP9 alongside VP8");
    }

    const webrtc::SdpVideoFormat format = webrtc::SdpVideoFormat::VP8();
    const webrtc::VideoDecoderFactory::CodecSupport support =
        factory->QueryCodecSupport(format, false, std::nullopt);
    if (!support.is_supported) {
        return fail("factory does not support VP8");
    }
    if (support.is_power_efficient != require_hardware) {
        return fail("factory power-efficiency report does not match the selected path");
    }

    std::unique_ptr<webrtc::VideoDecoder> decoder = factory->Create(environment, format);
    if (decoder == nullptr) {
        return fail("factory did not create a VP8 decoder");
    }
    const bool qualified = dinox::webrtc_runtime::IsVp8VaapiDecodeQualified();
    if (automatic) {
        if (factory->QueryCodecSupport(format, false, std::nullopt).is_power_efficient != qualified ||
            dinox::webrtc_runtime::IsVp8VaapiDecodeAvailable() != qualified ||
            dinox::webrtc_runtime::IsVp8VaapiDecodeAvailable() != qualified) {
            return fail("automatic selection did not retain its qualification result");
        }
        setenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER", "1", 1);
        if (dinox::webrtc_runtime::IsVp8VaapiDecodeAvailable() ||
            dinox::webrtc_runtime::IsVp8VaapiDecodeQualified() ||
            factory->QueryCodecSupport(format, false, std::nullopt).is_power_efficient) {
            return fail("explicit disable did not override the qualification cache");
        }
        unsetenv("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER");
        if (dinox::webrtc_runtime::IsVp8VaapiDecodeQualified() != qualified) {
            return fail("temporary disable discarded the qualification result");
        }
    }
    webrtc::VideoDecoder::DecoderInfo info;
    for (int cycle = 0; cycle < 3; ++cycle) {
        webrtc::VideoDecoder::Settings settings;
        settings.set_codec_type(webrtc::kVideoCodecVP8);
        settings.set_number_of_cores(2);
        settings.set_max_render_resolution(webrtc::RenderResolution(640, 480));
        if (!decoder->Configure(settings)) {
            return fail("VP8 decoder configuration failed");
        }

        info = decoder->GetDecoderInfo();
        if ((!automatic && info.is_hardware_accelerated != require_hardware) ||
            (automatic && info.is_hardware_accelerated && !qualified)) {
            return fail("active decoder hardware state is incorrect");
        }
        DecodeCallback callback;
        if (decoder->RegisterDecodeCompleteCallback(&callback) != WEBRTC_VIDEO_CODEC_OK) {
            return fail("decode callback registration failed");
        }

        webrtc::EncodedImage image;
        image.SetEncodedData(webrtc::EncodedImageBuffer::Create(
            kVp8KeyFrame,
            sizeof(kVp8KeyFrame)));
        image._encodedWidth = 320;
        image._encodedHeight = 240;
        image.SetRtpTimestamp(90000 + static_cast<uint32_t>(cycle * 3000));
        image.ntp_time_ms_ = 1000 + cycle * 33;
        image.set_frame_type(webrtc::VideoFrameType::kVideoFrameKey);
        const int32_t decode_status = decoder->Decode(image, 1000 + cycle * 33);
        if (decode_status != WEBRTC_VIDEO_CODEC_OK) {
            return fail("VP8 key frame decode failed");
        }
        if (callback.frames != 1 || callback.width != 320 || callback.height != 240) {
            return fail("decoded VP8 frame dimensions or callback count are incorrect");
        }
        if (decoder->Release() != WEBRTC_VIDEO_CODEC_OK) {
            return fail("VP8 decoder release failed");
        }
    }

    std::printf(
        "OK: %s VP8 decoder survived three 320x240 decode/release cycles (%s)\n",
        automatic ? "automatic" : require_hardware ? "VA-API" : "software",
        info.implementation_name.c_str());
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    const bool require_hardware = argc == 2 &&
        std::strcmp(argv[1], "--require-hardware") == 0;
    const bool automatic = argc == 2 && std::strcmp(argv[1], "--automatic") == 0;
    if (argc > 2 || (argc == 2 && !require_hardware && !automatic)) {
        return fail("usage: google-webrtc-vp8-decoder-smoke [--require-hardware|--automatic]");
    }
    return run_decode(require_hardware, automatic);
}
