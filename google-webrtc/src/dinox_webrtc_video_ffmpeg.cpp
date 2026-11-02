#include "dinox_webrtc_video_decoder_factory.hpp"
#include "dinox_webrtc_video_ffmpeg.hpp"
#include "dinox_webrtc_hardware_rate_control.hpp"
#include "dinox_webrtc_vp8_decode_qualification.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <map>
#include <cmath>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "absl/strings/match.h"
#include "api/environment/environment.h"
#include "api/environment/environment_factory.h"
#include "api/video/encoded_image.h"
#include "api/video/i420_buffer.h"
#include "api/video/resolution.h"
#include "api/video/video_frame.h"
#include "api/video/video_codec_type.h"
#include "api/video_codecs/builtin_video_decoder_factory.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_codec.h"
#include "api/video_codecs/h264_profile_level_id.h"
#include "common_video/h264/h264_bitstream_parser.h"
#include "common_video/h264/h264_common.h"
#include "modules/video_coding/include/video_codec_interface.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "api/video_codecs/video_decoder_software_fallback_wrapper.h"
#include "libyuv/convert.h"
#include "modules/video_coding/include/video_error_codes.h"

#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
#include "dinox_webrtc_vp8_probe_frames.hpp"

#include <dlfcn.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/log.h>
#include <libavutil/pixfmt.h>
#include <libavutil/opt.h>
#include <va/va.h>
}
#endif

namespace dinox::webrtc_runtime {
namespace {

constexpr char kVp8CodecName[] = "VP8";

bool environment_flag_enabled(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr &&
        (std::strcmp(value, "1") == 0 ||
         std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "yes") == 0);
}

template <typename Probe>
bool cached_capability(const std::string& name, Probe probe) {
    // Device/profile capability is stable for one worker lifetime. Bound the
    // cache even if many different resolution queries arrive. Init/Decode/
    // Encode still handle device loss independently through software fallback.
    static std::mutex mutex;
    static std::map<std::string, bool> cache;
    const char* device = std::getenv("DINOX_WEBRTC_VAAPI_DEVICE");
    const std::string key = name + ":" + (device ? device : "") +
        (environment_flag_enabled("DINOX_WEBRTC_DISABLE_CUDA") ? ":no-cuda" : ":cuda");
    std::lock_guard<std::mutex> lock(mutex);
    const auto found = cache.find(key);
    if (found != cache.end()) return found->second;
    const bool available = probe();
    if (cache.size() >= 64) cache.erase(cache.begin());
    cache.emplace(key, available);
    return available;
}

bool decoder_debug_enabled() {
    return environment_flag_enabled("DINOX_WEBRTC_VP8_DECODER_DEBUG") ||
        environment_flag_enabled("DINOX_WEBRTC_HW_CODEC_DEBUG");
}

void decoder_debug(const char* message) {
    if (decoder_debug_enabled() && message != nullptr) {
        std::fprintf(stderr, "DinoX WebRTC hardware codec: %s\n", message);
    }
}

#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)

// M152's built-in H.264 decoder brings its own static FFmpeg into this shared
// library. Direct av* calls here would bind to those hidden symbols at link
// time, mixing Chromium's limited decoder build with our private VA-API build.
// Resolve every FFmpeg call through the private shared-library handles instead.
class VaapiFfmpegApi {
 public:
    VaapiFfmpegApi() {
        Dl_info module = {};
        if (dladdr(kVp8CodecName, &module) == 0 || module.dli_fname == nullptr) {
            decoder_debug("cannot locate private FFmpeg beside the wrapper");
            return;
        }
        std::unique_ptr<char, decltype(&std::free)> wrapper_path(
            realpath(module.dli_fname, nullptr), &std::free);
        if (wrapper_path == nullptr) return;
        const std::string path = wrapper_path.get();
        const std::string directory = path.substr(0, path.find_last_of('/') + 1);
        const std::string util_name = directory + "libavutil-dinox-hw.so." +
            std::to_string(LIBAVUTIL_VERSION_MAJOR);
        const std::string codec_name = directory + "libavcodec-dinox-hw.so." +
            std::to_string(LIBAVCODEC_VERSION_MAJOR);
        util_ = dlopen(util_name.c_str(), RTLD_NOW | RTLD_LOCAL);
        codec_ = dlopen(codec_name.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (util_ == nullptr || codec_ == nullptr) {
            decoder_debug("private FFmpeg shared libraries are unavailable");
            return;
        }
#define DINOX_LOAD_FFMPEG(handle, name) \
        name = reinterpret_cast<decltype(name)>(dlsym(handle, #name)); \
        if (name == nullptr) return;
        DINOX_LOAD_FFMPEG(util_, av_buffer_ref)
        DINOX_LOAD_FFMPEG(util_, av_buffer_unref)
        DINOX_LOAD_FFMPEG(util_, av_frame_alloc)
        DINOX_LOAD_FFMPEG(util_, av_frame_free)
        DINOX_LOAD_FFMPEG(util_, av_hwdevice_ctx_create)
        DINOX_LOAD_FFMPEG(util_, av_hwframe_transfer_data)
        DINOX_LOAD_FFMPEG(util_, av_log_set_level)
        DINOX_LOAD_FFMPEG(util_, av_strerror)
        DINOX_LOAD_FFMPEG(util_, av_frame_get_buffer)
        DINOX_LOAD_FFMPEG(util_, av_frame_make_writable)
        DINOX_LOAD_FFMPEG(util_, av_hwframe_ctx_alloc)
        DINOX_LOAD_FFMPEG(util_, av_hwframe_ctx_init)
        DINOX_LOAD_FFMPEG(util_, av_hwframe_get_buffer)
        DINOX_LOAD_FFMPEG(util_, av_opt_set)
        DINOX_LOAD_FFMPEG(util_, av_opt_set_int)
        DINOX_LOAD_FFMPEG(util_, avutil_version)
        DINOX_LOAD_FFMPEG(codec_, av_new_packet)
        DINOX_LOAD_FFMPEG(codec_, av_packet_alloc)
        DINOX_LOAD_FFMPEG(codec_, av_packet_free)
        DINOX_LOAD_FFMPEG(codec_, avcodec_alloc_context3)
        DINOX_LOAD_FFMPEG(codec_, avcodec_find_decoder)
        DINOX_LOAD_FFMPEG(codec_, avcodec_free_context)
        DINOX_LOAD_FFMPEG(codec_, avcodec_get_hw_config)
        DINOX_LOAD_FFMPEG(codec_, avcodec_open2)
        DINOX_LOAD_FFMPEG(codec_, avcodec_receive_frame)
        DINOX_LOAD_FFMPEG(codec_, avcodec_send_packet)
        DINOX_LOAD_FFMPEG(codec_, avcodec_find_encoder_by_name)
        DINOX_LOAD_FFMPEG(codec_, avcodec_send_frame)
        DINOX_LOAD_FFMPEG(codec_, avcodec_receive_packet)
        DINOX_LOAD_FFMPEG(codec_, avcodec_version)
#undef DINOX_LOAD_FFMPEG
        if ((avcodec_version() >> 16) != LIBAVCODEC_VERSION_MAJOR ||
            (avutil_version() >> 16) != LIBAVUTIL_VERSION_MAJOR) {
            decoder_debug("private FFmpeg ABI does not match the VA-API decoder");
            return;
        }
        available = true;
    }

    ~VaapiFfmpegApi() {
        if (codec_ != nullptr) dlclose(codec_);
        if (util_ != nullptr) dlclose(util_);
    }

    VaapiFfmpegApi(const VaapiFfmpegApi&) = delete;
    VaapiFfmpegApi& operator=(const VaapiFfmpegApi&) = delete;

    bool available = false;
#define DINOX_FFMPEG_FUNCTION(name) decltype(&::name) name = nullptr;
    DINOX_FFMPEG_FUNCTION(av_buffer_ref)
    DINOX_FFMPEG_FUNCTION(av_buffer_unref)
    DINOX_FFMPEG_FUNCTION(av_frame_alloc)
    DINOX_FFMPEG_FUNCTION(av_frame_free)
    DINOX_FFMPEG_FUNCTION(av_hwdevice_ctx_create)
    DINOX_FFMPEG_FUNCTION(av_hwframe_transfer_data)
    DINOX_FFMPEG_FUNCTION(av_log_set_level)
    DINOX_FFMPEG_FUNCTION(av_strerror)
    DINOX_FFMPEG_FUNCTION(av_frame_get_buffer)
    DINOX_FFMPEG_FUNCTION(av_frame_make_writable)
    DINOX_FFMPEG_FUNCTION(av_hwframe_ctx_alloc)
    DINOX_FFMPEG_FUNCTION(av_hwframe_ctx_init)
    DINOX_FFMPEG_FUNCTION(av_hwframe_get_buffer)
    DINOX_FFMPEG_FUNCTION(av_opt_set)
    DINOX_FFMPEG_FUNCTION(av_opt_set_int)
    DINOX_FFMPEG_FUNCTION(avutil_version)
    DINOX_FFMPEG_FUNCTION(av_new_packet)
    DINOX_FFMPEG_FUNCTION(av_packet_alloc)
    DINOX_FFMPEG_FUNCTION(av_packet_free)
    DINOX_FFMPEG_FUNCTION(avcodec_alloc_context3)
    DINOX_FFMPEG_FUNCTION(avcodec_find_decoder)
    DINOX_FFMPEG_FUNCTION(avcodec_free_context)
    DINOX_FFMPEG_FUNCTION(avcodec_get_hw_config)
    DINOX_FFMPEG_FUNCTION(avcodec_open2)
    DINOX_FFMPEG_FUNCTION(avcodec_receive_frame)
    DINOX_FFMPEG_FUNCTION(avcodec_send_packet)
    DINOX_FFMPEG_FUNCTION(avcodec_find_encoder_by_name)
    DINOX_FFMPEG_FUNCTION(avcodec_send_frame)
    DINOX_FFMPEG_FUNCTION(avcodec_receive_packet)
    DINOX_FFMPEG_FUNCTION(avcodec_version)
#undef DINOX_FFMPEG_FUNCTION

 private:
    void* util_ = nullptr;
    void* codec_ = nullptr;
};

const VaapiFfmpegApi& ffmpeg() {
    static const VaapiFfmpegApi api;
    return api;
}

AVPixelFormat hardware_pixel_format(const AVCodec* codec, AVHWDeviceType device_type = AV_HWDEVICE_TYPE_VAAPI) {
    if (codec == nullptr) return AV_PIX_FMT_NONE;
    for (int index = 0;; ++index) {
        const AVCodecHWConfig* config = ffmpeg().avcodec_get_hw_config(codec, index);
        if (config == nullptr) return AV_PIX_FMT_NONE;
        if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
            config->device_type == device_type) {
            return config->pix_fmt;
        }
    }
}

void decoder_debug_error(const char* operation, int error) {
    if (!decoder_debug_enabled()) {
        return;
    }
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    if (ffmpeg().av_strerror(error, buffer, sizeof(buffer)) < 0) {
        std::snprintf(buffer, sizeof(buffer), "error %d", error);
    }
    std::fprintf(
        stderr,
        "DinoX WebRTC hardware codec: %s failed: %s\n",
        operation != nullptr ? operation : "operation",
        buffer);
}

void configure_private_ffmpeg_logging() {
    static std::once_flag configured;
    std::call_once(configured, [] {
        // This minimal FFmpeg is shipped as private sibling libraries and is
        // used only by the DinoX decoder. Expected VA-API probe failures must
        // not add unconditional stderr noise on machines without a usable
        // driver; targeted diagnostics are emitted by decoder_debug.
        ffmpeg().av_log_set_level(AV_LOG_FATAL);
    });
}

bool vaapi_display_supports_profile(VADisplay display, VAProfile profile) {
    if (display == nullptr) {
        return false;
    }

    const int max_profiles = vaMaxNumProfiles(display);
    if (max_profiles <= 0) {
        return false;
    }
    std::vector<VAProfile> profiles(static_cast<std::size_t>(max_profiles));
    int profile_count = 0;
    if (vaQueryConfigProfiles(display, profiles.data(), &profile_count) != VA_STATUS_SUCCESS) {
        return false;
    }
    profile_count = std::clamp(profile_count, 0, max_profiles);
    if (std::find(
            profiles.begin(),
            profiles.begin() + profile_count,
            profile) == profiles.begin() + profile_count) {
        return false;
    }

    const int max_entrypoints = vaMaxNumEntrypoints(display);
    if (max_entrypoints <= 0) {
        return false;
    }
    std::vector<VAEntrypoint> entrypoints(static_cast<std::size_t>(max_entrypoints));
    int entrypoint_count = 0;
    if (vaQueryConfigEntrypoints(
            display,
            profile,
            entrypoints.data(),
            &entrypoint_count) != VA_STATUS_SUCCESS) {
        return false;
    }
    entrypoint_count = std::clamp(entrypoint_count, 0, max_entrypoints);
    return std::find(
               entrypoints.begin(),
               entrypoints.begin() + entrypoint_count,
               VAEntrypointVLD) != entrypoints.begin() + entrypoint_count;
}

bool probe_vp8_vaapi_decode() {
    if (environment_flag_enabled("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER")) {
        decoder_debug("disabled by DINOX_WEBRTC_DISABLE_VP8_HW_DECODER");
        return false;
    }

    if (!IsVp8VaapiProviderAvailable()) {
        decoder_debug("private FFmpeg API is unavailable; keeping software decode");
        return false;
    }

    configure_private_ffmpeg_logging();
    AVBufferRef* device = nullptr;
    const int create_status = ffmpeg().av_hwdevice_ctx_create(
        &device,
        AV_HWDEVICE_TYPE_VAAPI,
        std::getenv("DINOX_WEBRTC_VAAPI_DEVICE"),
        nullptr,
        0);
    if (create_status < 0 || device == nullptr) {
        decoder_debug_error("VA-API device probe", create_status);
        ffmpeg().av_buffer_unref(&device);
        return false;
    }

    const auto* device_context =
        reinterpret_cast<const AVHWDeviceContext*>(device->data);
    const auto* vaapi_context = device_context != nullptr
        ? static_cast<const AVVAAPIDeviceContext*>(device_context->hwctx)
        : nullptr;
    const bool available = vaapi_context != nullptr &&
        vaapi_display_supports_profile(vaapi_context->display, VAProfileVP8Version0_3);
    ffmpeg().av_buffer_unref(&device);
    decoder_debug(available
        ? "VA-API VP8/VLD capability detected"
        : "VA-API device does not expose VP8/VLD");
    return available;
}

class FfmpegHardwareDecoder final : public webrtc::VideoDecoder {
 public:
    FfmpegHardwareDecoder(webrtc::VideoCodecType codec_type, AVHWDeviceType device_type)
        : codec_type_(codec_type), device_type_(device_type) {}
    ~FfmpegHardwareDecoder() override { reset_decoder(); }

    bool Configure(const Settings& settings) override {
        reset_decoder();
        settings_ = settings;
        if (settings.codec_type() != codec_type_) {
            return false;
        }
        if (!ffmpeg().available) {
            return false;
        }

        configure_private_ffmpeg_logging();
        codec_ = ffmpeg().avcodec_find_decoder(
            codec_type_ == webrtc::kVideoCodecVP8 ? AV_CODEC_ID_VP8 : AV_CODEC_ID_H264);
        if (codec_ == nullptr) {
            decoder_debug("bundled FFmpeg hardware decoder is unavailable");
            return false;
        }

        hardware_pixel_format_ = hardware_pixel_format(codec_, device_type_);
        if (hardware_pixel_format_ == AV_PIX_FMT_NONE) {
            decoder_debug("bundled FFmpeg hardware decoder has no VA-API configuration");
            return false;
        }

        int status = ffmpeg().av_hwdevice_ctx_create(
            &hardware_device_,
            device_type_,
            device_type_ == AV_HWDEVICE_TYPE_VAAPI ? std::getenv("DINOX_WEBRTC_VAAPI_DEVICE") : nullptr,
            nullptr,
            0);
        if (status < 0 || hardware_device_ == nullptr) {
            decoder_debug_error("VA-API device creation", status);
            reset_decoder();
            return false;
        }

        codec_context_ = ffmpeg().avcodec_alloc_context3(codec_);
        if (codec_context_ == nullptr) {
            reset_decoder();
            return false;
        }
        codec_context_->opaque = this;
        codec_context_->get_format = &FfmpegHardwareDecoder::select_pixel_format;
        codec_context_->hw_device_ctx = ffmpeg().av_buffer_ref(hardware_device_);
        codec_context_->thread_count = 1;
        codec_context_->flags |= AV_CODEC_FLAG_LOW_DELAY;
        codec_context_->pkt_timebase = AVRational{1, 90000};
        if (codec_context_->hw_device_ctx == nullptr) {
            reset_decoder();
            return false;
        }

        status = ffmpeg().avcodec_open2(codec_context_, codec_, nullptr);
        if (status < 0) {
            decoder_debug_error("hardware decoder initialization", status);
            reset_decoder();
            return false;
        }
        configured_ = true;
        decoder_debug("using bundled FFmpeg hardware decoder");
        return true;
    }

    int32_t Decode(
        const webrtc::EncodedImage& input_image,
        int64_t render_time_ms) override {
        if (!configured_ || codec_context_ == nullptr) {
            return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
        }
        if (failed_) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (callback_ == nullptr || input_image.data() == nullptr || input_image.size() == 0) {
            return WEBRTC_VIDEO_CODEC_ERROR;
        }
        if (input_image.size() > static_cast<std::size_t>(INT_MAX)) {
            return WEBRTC_VIDEO_CODEC_ERROR;
        }

        AVPacket* packet = ffmpeg().av_packet_alloc();
        if (packet == nullptr) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        int status = ffmpeg().av_new_packet(packet, static_cast<int>(input_image.size()));
        if (status < 0) {
            ffmpeg().av_packet_free(&packet);
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        std::memcpy(packet->data, input_image.data(), input_image.size());
        packet->pts = static_cast<int64_t>(input_image.RtpTimestamp());
        packet->dts = packet->pts;

        const auto decode_started = std::chrono::steady_clock::now();
        status = ffmpeg().avcodec_send_packet(codec_context_, packet);
        ffmpeg().av_packet_free(&packet);
        if (status < 0) {
            decoder_debug_error("hardware packet submission", status);
            return status == AVERROR_INVALIDDATA
                ? WEBRTC_VIDEO_CODEC_ERROR
                : WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        pending_frames_.insert_or_assign(input_image.RtpTimestamp(),
            PendingFrame{input_image, render_time_ms, decode_started});
        if (pending_frames_.size() > 32) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;

        int decoded_frames = 0;
        bool delivered_current = false;
        const auto hardware_failure = [&] {
            failed_ = true;
            return delivered_current ? WEBRTC_VIDEO_CODEC_OK : WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        };
        while (true) {
            AVFrame* hardware_frame = ffmpeg().av_frame_alloc();
            if (hardware_frame == nullptr) {
                return hardware_failure();
            }
            status = ffmpeg().avcodec_receive_frame(codec_context_, hardware_frame);
            if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) {
                ffmpeg().av_frame_free(&hardware_frame);
                break;
            }
            if (status < 0) {
                ffmpeg().av_frame_free(&hardware_frame);
                decoder_debug_error("hardware frame receive", status);
                return status == AVERROR_INVALIDDATA
                    ? WEBRTC_VIDEO_CODEC_ERROR
                    : hardware_failure();
            }

            const auto pending = pending_frames_.find(hardware_frame->pts);
            if (pending == pending_frames_.end()) {
                ffmpeg().av_frame_free(&hardware_frame);
                return hardware_failure();
            }
            const int delivery_status = deliver_frame(hardware_frame,
                pending->second.image, pending->second.render_time_ms,
                pending->second.started);
            delivered_current |= delivery_status == WEBRTC_VIDEO_CODEC_OK &&
                pending->second.image.RtpTimestamp() == input_image.RtpTimestamp();
            pending_frames_.erase(pending);
            ffmpeg().av_frame_free(&hardware_frame);
            if (delivery_status != WEBRTC_VIDEO_CODEC_OK) {
                return hardware_failure();
            }
            ++decoded_frames;
        }
        return decoded_frames > 0
            ? WEBRTC_VIDEO_CODEC_OK
            : WEBRTC_VIDEO_CODEC_NO_OUTPUT;
    }

    int32_t RegisterDecodeCompleteCallback(
        webrtc::DecodedImageCallback* callback) override {
        callback_ = callback;
        return WEBRTC_VIDEO_CODEC_OK;
    }

    int32_t Release() override {
        reset_decoder();
        callback_ = nullptr;
        return WEBRTC_VIDEO_CODEC_OK;
    }

    DecoderInfo GetDecoderInfo() const override {
        return {
            .implementation_name = ImplementationName(),
            .is_hardware_accelerated = true,
        };
    }

    const char* ImplementationName() const override {
        return codec_type_ == webrtc::kVideoCodecVP8 ? "DinoX FFmpeg VA-API VP8" :
            device_type_ == AV_HWDEVICE_TYPE_CUDA ? "DinoX FFmpeg NVDEC H264" : "DinoX FFmpeg VA-API H264";
    }

 private:
    static AVPixelFormat select_pixel_format(
        AVCodecContext* context,
        const AVPixelFormat* formats) {
        const auto* self = context != nullptr
            ? static_cast<const FfmpegHardwareDecoder*>(context->opaque)
            : nullptr;
        if (self == nullptr || formats == nullptr) {
            return AV_PIX_FMT_NONE;
        }
        for (const AVPixelFormat* format = formats;
             *format != AV_PIX_FMT_NONE;
             ++format) {
            if (*format == self->hardware_pixel_format_) {
                return *format;
            }
        }
        return AV_PIX_FMT_NONE;
    }

    int deliver_frame(
        const AVFrame* hardware_frame,
        const webrtc::EncodedImage& input_image,
        int64_t render_time_ms,
        std::chrono::steady_clock::time_point decode_started) {
        if (hardware_frame == nullptr || hardware_frame->format != hardware_pixel_format_ ||
            hardware_frame->hw_frames_ctx == nullptr || hardware_frame->width <= 0 ||
            hardware_frame->height <= 0) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }

        const webrtc::RenderResolution maximum = settings_.max_render_resolution();
        if ((maximum.Width() > 0 && hardware_frame->width > maximum.Width()) ||
            (maximum.Height() > 0 && hardware_frame->height > maximum.Height())) {
            decoder_debug("decoded frame exceeds the configured maximum resolution");
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }

        AVFrame* software_frame = ffmpeg().av_frame_alloc();
        if (software_frame == nullptr) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        const int transfer_status = ffmpeg().av_hwframe_transfer_data(
            software_frame,
            hardware_frame,
            0);
        if (transfer_status < 0) {
            decoder_debug_error("VA-API frame transfer", transfer_status);
            ffmpeg().av_frame_free(&software_frame);
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }

        webrtc::scoped_refptr<webrtc::I420Buffer> output;
        const auto pixel_format = static_cast<AVPixelFormat>(software_frame->format);
        if (pixel_format == AV_PIX_FMT_NV12) {
            output = webrtc::I420Buffer::Create(
                software_frame->width,
                software_frame->height);
            const int convert_status = libyuv::NV12ToI420(
                software_frame->data[0],
                software_frame->linesize[0],
                software_frame->data[1],
                software_frame->linesize[1],
                output->MutableDataY(),
                output->StrideY(),
                output->MutableDataU(),
                output->StrideU(),
                output->MutableDataV(),
                output->StrideV(),
                software_frame->width,
                software_frame->height);
            if (convert_status != 0) {
                output = nullptr;
            }
        } else if (pixel_format == AV_PIX_FMT_YUV420P ||
                   pixel_format == AV_PIX_FMT_YUVJ420P) {
            output = webrtc::I420Buffer::Copy(
                software_frame->width,
                software_frame->height,
                software_frame->data[0],
                software_frame->linesize[0],
                software_frame->data[1],
                software_frame->linesize[1],
                software_frame->data[2],
                software_frame->linesize[2]);
        }
        ffmpeg().av_frame_free(&software_frame);
        if (output == nullptr) {
            decoder_debug("VA-API returned an unsupported software frame format");
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }

        webrtc::VideoFrame decoded = webrtc::VideoFrame::Builder()
            .set_video_frame_buffer(output)
            .set_timestamp_ms(render_time_ms)
            .set_timestamp_rtp(input_image.RtpTimestamp())
            .set_ntp_time_ms(input_image.NtpTimeMs())
            .set_rotation(input_image.rotation_)
            .set_color_space(input_image.ColorSpace())
            .set_packet_infos(input_image.PacketInfos())
            .set_content_type(input_image.contentType())
            .build();

        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - decode_started);
        const int64_t bounded_decode_ms = std::clamp<int64_t>(
            elapsed.count(),
            0,
            INT32_MAX);
        const std::optional<uint8_t> qp =
            input_image.qp_ >= 0 && input_image.qp_ <= UINT8_MAX
            ? std::optional<uint8_t>(static_cast<uint8_t>(input_image.qp_))
            : std::nullopt;
        callback_->Decoded(
            decoded,
            static_cast<int32_t>(bounded_decode_ms),
            qp);
        return WEBRTC_VIDEO_CODEC_OK;
    }

    void reset_decoder() {
        configured_ = false;
        failed_ = false;
        pending_frames_.clear();
        if (codec_context_ != nullptr) {
            ffmpeg().avcodec_free_context(&codec_context_);
        }
        if (hardware_device_ != nullptr) {
            ffmpeg().av_buffer_unref(&hardware_device_);
        }
        codec_ = nullptr;
        hardware_pixel_format_ = AV_PIX_FMT_NONE;
    }

    const webrtc::VideoCodecType codec_type_;
    const AVHWDeviceType device_type_;
    struct PendingFrame {
        webrtc::EncodedImage image;
        int64_t render_time_ms;
        std::chrono::steady_clock::time_point started;
    };
    std::map<int64_t, PendingFrame> pending_frames_;
    Settings settings_;
    webrtc::DecodedImageCallback* callback_ = nullptr;
    const AVCodec* codec_ = nullptr;
    AVCodecContext* codec_context_ = nullptr;
    AVBufferRef* hardware_device_ = nullptr;
    AVPixelFormat hardware_pixel_format_ = AV_PIX_FMT_NONE;
    bool configured_ = false;
    bool failed_ = false;
};

enum class Vp8QualificationState { InProgress, Qualified, Rejected };

struct Vp8QualificationCache {
    std::mutex mutex;
    std::map<std::string, Vp8QualificationState> entries;
};

Vp8QualificationCache& vp8_qualification_cache() {
    static Vp8QualificationCache cache;
    return cache;
}

std::string vp8_qualification_key() {
    const char* device = std::getenv("DINOX_WEBRTC_VAAPI_DEVICE");
    return device != nullptr ? device : "";
}

using Vp8ProbeClock = std::chrono::steady_clock;
using Vp8ProbeSamples = std::array<uint8_t, 48>;
constexpr std::size_t kVp8ProbeFrames = 16;
constexpr std::size_t kVp8ProbeWarmup = 2;

class Vp8ProbeCallback final : public webrtc::DecodedImageCallback {
 public:
    Vp8ProbeCallback(int width, int height,
                     std::vector<Vp8ProbeSamples>& software_samples,
                     bool compare_software)
        : width_(width), height_(height), software_samples_(software_samples),
          compare_software_(compare_software) {}

    void Expect(std::size_t index, uint32_t timestamp) {
        std::lock_guard<std::mutex> lock(mutex_);
        index_ = index;
        timestamp_ = timestamp;
    }

    int32_t Decoded(webrtc::VideoFrame& frame) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++callbacks_;
        const auto buffer = frame.video_frame_buffer();
        const auto pixels = buffer ? buffer->ToI420() : nullptr;
        if (!pixels || frame.width() != width_ || frame.height() != height_ ||
            pixels->width() != width_ || pixels->height() != height_ ||
            frame.rtp_timestamp() != timestamp_ || index_ >= software_samples_.size() ||
            !pixels->DataY() || !pixels->DataU() || !pixels->DataV() ||
            pixels->StrideY() < width_ || pixels->StrideU() < width_ / 2 ||
            pixels->StrideV() < width_ / 2) {
            valid_ = false;
        } else {
            Vp8ProbeSamples samples{};
            std::size_t sample_index = 0;
            for (int row = 0; row < 4; ++row) {
                for (int column = 0; column < 6; ++column) {
                    const int x = (2 * column + 1) * width_ / 12;
                    const int y = (2 * row + 1) * height_ / 8;
                    samples[sample_index++] = pixels->DataY()[y * pixels->StrideY() + x];
                }
            }
            for (int plane = 0; plane < 2; ++plane) {
                const uint8_t* data = plane == 0 ? pixels->DataU() : pixels->DataV();
                const int stride = plane == 0 ? pixels->StrideU() : pixels->StrideV();
                for (int row = 0; row < 3; ++row) {
                    for (int column = 0; column < 4; ++column) {
                        const int x = (2 * column + 1) * width_ / 16;
                        const int y = (2 * row + 1) * height_ / 12;
                        samples[sample_index++] = data[y * stride + x];
                    }
                }
            }
            if (compare_software_) {
                int total_error = 0;
                for (std::size_t index = 0; index < samples.size(); ++index) {
                    total_error += std::abs(static_cast<int>(samples[index]) -
                        static_cast<int>(software_samples_[index_][index]));
                }
                // libvpx's optional postprocessing can change edge pixels.
                valid_ &= total_error <= static_cast<int>(samples.size()) * 12;
            } else {
                software_samples_[index_] = samples;
            }
        }
        condition_.notify_all();
        return WEBRTC_VIDEO_CODEC_OK;
    }

    bool WaitFor(std::size_t count, Vp8ProbeClock::time_point deadline) {
        std::unique_lock<std::mutex> lock(mutex_);
        return condition_.wait_until(lock, deadline,
                   [&] { return callbacks_ >= count; }) &&
            callbacks_ == count && valid_;
    }

 private:
    const int width_, height_;
    std::vector<Vp8ProbeSamples>& software_samples_;
    const bool compare_software_;
    std::mutex mutex_;
    std::condition_variable condition_;
    std::size_t index_ = 0;
    uint32_t timestamp_ = 0;
    std::size_t callbacks_ = 0;
    bool valid_ = true;
};

bool measure_vp8_probe(const webrtc::Environment& environment,
                       const vp8_probe::Sequence& sequence, bool hardware,
                       Vp8ProbeClock::time_point deadline,
                       std::vector<Vp8ProbeSamples>& software_samples,
                       std::vector<double>& measured_ms, const char** reason) {
    const auto in_budget = [&] {
        if (Vp8ProbeClock::now() < deadline) return true;
        *reason = "elapsed-budget";
        return false;
    };
    if (!in_budget()) return false;
    Vp8ProbeCallback callback(sequence.width, sequence.height, software_samples, hardware);
    auto factory = hardware ? nullptr : webrtc::CreateBuiltinVideoDecoderFactory();
    // Do not call the production factory here: it requests this qualification.
    auto decoder = hardware
        ? std::unique_ptr<webrtc::VideoDecoder>(new FfmpegHardwareDecoder(
              webrtc::kVideoCodecVP8, AV_HWDEVICE_TYPE_VAAPI))
        : factory->Create(environment, webrtc::SdpVideoFormat::VP8());
    if (!decoder) {
        *reason = "decoder-unavailable";
        return false;
    }
    const bool decoded = [&] {
        if (!in_budget()) return false;
        webrtc::VideoDecoder::Settings settings;
        settings.set_codec_type(webrtc::kVideoCodecVP8);
        settings.set_number_of_cores(1);
        settings.set_max_render_resolution(
            webrtc::RenderResolution(sequence.width, sequence.height));
        if (!decoder->Configure(settings) ||
            decoder->RegisterDecodeCompleteCallback(&callback) != WEBRTC_VIDEO_CODEC_OK) {
            *reason = "configure-failed";
            return false;
        }
        if (decoder->GetDecoderInfo().is_hardware_accelerated != hardware) {
            *reason = "unexpected-decoder";
            return false;
        }
        if (!in_budget()) return false;
        for (std::size_t index = 0; index < sequence.count; ++index) {
            if (!in_budget()) return false;
            const auto& fixture = sequence.frames[index];
            webrtc::EncodedImage image;
            image.SetEncodedData(webrtc::EncodedImageBuffer::Create(fixture.data, fixture.size));
            image._encodedWidth = sequence.width;
            image._encodedHeight = sequence.height;
            image.SetRtpTimestamp(fixture.rtp_timestamp);
            image.set_frame_type(fixture.key ? webrtc::VideoFrameType::kVideoFrameKey
                                            : webrtc::VideoFrameType::kVideoFrameDelta);
            callback.Expect(index, fixture.rtp_timestamp);
            const auto start = Vp8ProbeClock::now();
            const int status = decoder->Decode(image, 1000 + static_cast<int64_t>(index) * 1000 / 30);
            if (status != WEBRTC_VIDEO_CODEC_OK || !callback.WaitFor(index + 1, deadline)) {
                *reason = "invalid-frames";
                return false;
            }
            const double elapsed_ms = std::chrono::duration<double, std::milli>(
                Vp8ProbeClock::now() - start).count();
            if (!in_budget()) return false;
            if (index >= kVp8ProbeWarmup) measured_ms.push_back(elapsed_ms);
        }
        return true;
    }();
    const int release_status = decoder->Release();
    if (!in_budget()) return false;
    if (release_status != WEBRTC_VIDEO_CODEC_OK) {
        *reason = "release-failed";
        return false;
    }
    return decoded;
}

bool qualify_vp8_vaapi_decode() {
    // This is an elapsed-work budget checked between native calls, not a hard
    // timeout that can interrupt a blocked driver. No UI/network thread probes.
    const auto deadline = Vp8ProbeClock::now() + std::chrono::milliseconds(1000);
    const auto reject = [](const char* reason) {
        if (decoder_debug_enabled()) {
            std::fprintf(stderr, "DinoX WebRTC hardware codec: VP8 qualification rejected: %s\n", reason);
        }
        return false;
    };
    if (!probe_vp8_vaapi_decode()) return reject("capability-unavailable");
    if (Vp8ProbeClock::now() >= deadline) return reject("elapsed-budget");
    const auto environment = webrtc::CreateEnvironment();
    bool checked_480p = false;
    bool checked_720p = false;
    for (const auto& sequence : vp8_probe::kSequences) {
        if (sequence.count != kVp8ProbeFrames || !sequence.frames ||
            sequence.width <= 0 || sequence.height <= 0 || !sequence.frames[0].key) {
            return reject("invalid-fixture");
        }
        bool has_delta = false;
        for (std::size_t index = 0; index < sequence.count; ++index) {
            if (!sequence.frames[index].data || sequence.frames[index].size == 0) {
                return reject("invalid-fixture");
            }
            has_delta |= !sequence.frames[index].key;
        }
        if (!has_delta) return reject("invalid-fixture");
        std::vector<Vp8ProbeSamples> software_samples(sequence.count);
        std::vector<double> software_ms, hardware_ms;
        software_ms.reserve(sequence.count - kVp8ProbeWarmup);
        hardware_ms.reserve(sequence.count - kVp8ProbeWarmup);
        const char* reason = "invalid-frames";
        if (!measure_vp8_probe(environment, sequence, false, deadline,
                software_samples, software_ms, &reason) ||
            !measure_vp8_probe(environment, sequence, true, deadline,
                software_samples, hardware_ms, &reason)) {
            return reject(reason);
        }
        const auto decision = EvaluateVp8DecodeQualification(true, software_ms, hardware_ms);
        if (decoder_debug_enabled()) {
            std::fprintf(stderr,
                "DinoX WebRTC hardware codec: VP8 qualification %dx%d: %s software-p90=%.3fms hardware-p90=%.3fms limit=%.3fms\n",
                sequence.width, sequence.height,
                Vp8DecodeQualificationReasonName(decision.reason), decision.software_p90_ms,
                decision.hardware_p90_ms, decision.limit_ms);
        }
        if (!decision.qualified) return false;
        checked_480p |= sequence.width == 640 && sequence.height == 480;
        checked_720p |= sequence.width == 1280 && sequence.height == 720;
    }
    if (Vp8ProbeClock::now() >= deadline) return reject("elapsed-budget");
    return checked_480p && checked_720p;
}

// The negotiated profile and packetization mode remain authoritative. VA-API
// does not provide a portable byte-limited slice control, so mode 0 uses the
// built-in encoder instead of emitting oversized single-NAL RTP packets.
std::optional<webrtc::H264ProfileLevelId> hardware_h264_profile(
    const webrtc::SdpVideoFormat& format, bool encode) {
    if (!absl::EqualsIgnoreCase(format.name, "H264")) return std::nullopt;
    const auto mode = format.parameters.find("packetization-mode");
    if (encode && (mode == format.parameters.end() || mode->second != "1")) return std::nullopt;
    if (mode != format.parameters.end() && mode->second != "0" && mode->second != "1") return std::nullopt;
    auto profile = webrtc::ParseSdpForH264ProfileLevelId(format.parameters);
    if (!profile || profile->level == webrtc::H264Level::kLevel1_b) return std::nullopt;
    if (profile->profile != webrtc::H264Profile::kProfileConstrainedBaseline &&
        profile->profile != webrtc::H264Profile::kProfileBaseline &&
        profile->profile != webrtc::H264Profile::kProfileMain &&
        profile->profile != webrtc::H264Profile::kProfileHigh) return std::nullopt;
    return profile;
}

int ffmpeg_h264_profile(webrtc::H264Profile profile) {
    switch (profile) {
        case webrtc::H264Profile::kProfileConstrainedBaseline: return AV_PROFILE_H264_CONSTRAINED_BASELINE;
        case webrtc::H264Profile::kProfileBaseline: return AV_PROFILE_H264_BASELINE;
        case webrtc::H264Profile::kProfileMain: return AV_PROFILE_H264_MAIN;
        default: return AV_PROFILE_H264_HIGH;
    }
}

std::optional<AVHWDeviceType> h264_decode_device(const webrtc::SdpVideoFormat& format) {
    const auto profile = hardware_h264_profile(format, false);
    if (!profile || !ffmpeg().available ||
        environment_flag_enabled("DINOX_WEBRTC_DISABLE_H264_HW_DECODER")) return std::nullopt;
    const AVCodec* codec = ffmpeg().avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) return std::nullopt;
    configure_private_ffmpeg_logging();
    for (const auto type : {AV_HWDEVICE_TYPE_VAAPI, AV_HWDEVICE_TYPE_CUDA}) {
        if (type == AV_HWDEVICE_TYPE_CUDA && environment_flag_enabled("DINOX_WEBRTC_DISABLE_CUDA")) continue;
        if (hardware_pixel_format(codec, type) == AV_PIX_FMT_NONE) continue;
        AVBufferRef* device = nullptr;
        int status = ffmpeg().av_hwdevice_ctx_create(&device, type,
            type == AV_HWDEVICE_TYPE_VAAPI ? std::getenv("DINOX_WEBRTC_VAAPI_DEVICE") : nullptr, nullptr, 0);
        bool available = status >= 0 && device != nullptr;
        if (available && type == AV_HWDEVICE_TYPE_VAAPI) {
            const auto* context = reinterpret_cast<const AVHWDeviceContext*>(device->data);
            const auto* vaapi = static_cast<const AVVAAPIDeviceContext*>(context->hwctx);
            const VAProfile va_profile = profile->profile == webrtc::H264Profile::kProfileMain
                ? VAProfileH264Main : profile->profile == webrtc::H264Profile::kProfileHigh
                ? VAProfileH264High : VAProfileH264ConstrainedBaseline;
            available = vaapi && vaapi_display_supports_profile(vaapi->display, va_profile);
        }
        ffmpeg().av_buffer_unref(&device);
        if (available) return type;
    }
    return std::nullopt;
}

class FfmpegHardwareH264Encoder final : public webrtc::VideoEncoder {
 public:
    explicit FfmpegHardwareH264Encoder(webrtc::SdpVideoFormat format) : format_(std::move(format)) {}
    ~FfmpegHardwareH264Encoder() override { reset(); }

    int InitEncode(const webrtc::VideoCodec* codec, const Settings&) override {
        reset();
        const auto profile = hardware_h264_profile(format_, true);
        if (!ffmpeg().available || !profile || codec == nullptr ||
            codec->codecType != webrtc::kVideoCodecH264 || codec->width == 0 || codec->height == 0 ||
            codec->width % 2 != 0 || codec->height % 2 != 0 || codec->maxFramerate == 0 ||
            codec->maxFramerate > 120 || codec->startBitrate > UINT32_MAX / 1000 ||
            codec->numberOfSimulcastStreams > 1 || codec->H264().numberOfTemporalLayers > 1 ||
            (codec->GetScalabilityMode() && *codec->GetScalabilityMode() != webrtc::ScalabilityMode::kL1T1)) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        codec_ = *codec;
        target_bitrate_ = bitrate_ = (codec->startBitrate == 0 ? 500 : codec->startBitrate) * 1000;
        target_framerate_ = framerate_ = codec->maxFramerate;
        paused_ = codec->startBitrate == 0;
        configure_private_ffmpeg_logging();
        return initialize() ? WEBRTC_VIDEO_CODEC_OK : WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
    }

    int32_t RegisterEncodeCompleteCallback(webrtc::EncodedImageCallback* callback) override {
        callback_ = callback;
        return WEBRTC_VIDEO_CODEC_OK;
    }

    int32_t Release() override {
        reset();
        callback_ = nullptr;
        return WEBRTC_VIDEO_CODEC_OK;
    }

    void SetRates(const RateControlParameters& rates) override {
        paused_ = rates.bitrate.get_sum_bps() == 0;
        if (paused_) return;
        const uint32_t bitrate = rates.bitrate.get_sum_bps();
        const int fps = rates.framerate_fps > 0 && std::isfinite(rates.framerate_fps)
            ? static_cast<int>(std::clamp(rates.framerate_fps, 1.0, 120.0)) : framerate_;
        target_bitrate_ = bitrate;
        target_framerate_ = fps;
    }

    int32_t Encode(const webrtc::VideoFrame& frame,
                   const std::vector<webrtc::VideoFrameType>* frame_types) override {
        if (callback_ == nullptr || context_ == nullptr) return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
        if (hardware_failed_) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (paused_) return WEBRTC_VIDEO_CODEC_OK;
        if (frame_types && !frame_types->empty() &&
            frame_types->front() == webrtc::VideoFrameType::kEmptyFrame) return WEBRTC_VIDEO_CODEC_OK;
        if (frame.width() != codec_.width || frame.height() != codec_.height) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - initialized_at_).count();
        const auto update = !encoded_since_init_ &&
                (bitrate_ != target_bitrate_ || framerate_ != target_framerate_)
            ? HardwareRateUpdate::Reinitialize
            : DecideFfmpegHardwareRateUpdate(bitrate_, framerate_, target_bitrate_, target_framerate_, elapsed);
        if (update == HardwareRateUpdate::SoftwareFallback) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (update == HardwareRateUpdate::Reinitialize) {
            bitrate_ = target_bitrate_;
            framerate_ = target_framerate_;
            if (!initialize()) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        const auto pixels = frame.video_frame_buffer()->ToI420();
        if (!pixels) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (ffmpeg().av_frame_make_writable(software_frame_) < 0) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (libyuv::I420ToNV12(pixels->DataY(), pixels->StrideY(), pixels->DataU(), pixels->StrideU(),
            pixels->DataV(), pixels->StrideV(), software_frame_->data[0], software_frame_->linesize[0],
            software_frame_->data[1], software_frame_->linesize[1], codec_.width, codec_.height) != 0) {
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        AVFrame* hardware_frame = ffmpeg().av_frame_alloc();
        if (!hardware_frame) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        int status = ffmpeg().av_hwframe_get_buffer(context_->hw_frames_ctx, hardware_frame, 0);
        if (status >= 0) status = ffmpeg().av_hwframe_transfer_data(hardware_frame, software_frame_, 0);
        const int64_t pts = sequence_++;
        hardware_frame->pts = pts;
        const bool request_key = force_key_ || (frame_types && std::find(frame_types->begin(), frame_types->end(),
            webrtc::VideoFrameType::kVideoFrameKey) != frame_types->end());
        hardware_frame->pict_type = request_key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
        if (status >= 0) status = ffmpeg().avcodec_send_frame(context_, hardware_frame);
        ffmpeg().av_frame_free(&hardware_frame);
        if (status < 0) {
            decoder_debug_error("hardware H264 frame submission", status);
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        }
        pending_.emplace(pts, PendingEncoding{frame, request_key});
        encoded_since_init_ = true;
        force_key_ = false;
        if (pending_.size() > 8) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        bool delivered_current = false;
        const auto hardware_failure = [&] {
            hardware_failed_ = true;
            return delivered_current ? WEBRTC_VIDEO_CODEC_OK : WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        };
        for (;;) {
            AVPacket* packet = ffmpeg().av_packet_alloc();
            if (!packet) return hardware_failure();
            status = ffmpeg().avcodec_receive_packet(context_, packet);
            if (status == AVERROR(EAGAIN)) {
                ffmpeg().av_packet_free(&packet);
                return WEBRTC_VIDEO_CODEC_OK;
            }
            if (status < 0) {
                ffmpeg().av_packet_free(&packet);
                decoder_debug_error("hardware H264 packet receive", status);
                return hardware_failure();
            }
            const auto source = pending_.find(packet->pts);
            if (source == pending_.end() || packet->size <= 0 || packet->data == nullptr) {
                ffmpeg().av_packet_free(&packet);
                return hardware_failure();
            }
            const auto bytes = std::span<const uint8_t>(packet->data, packet->size);
            bool idr = false, sps = false, pps = false;
            const auto nalus = webrtc::H264::FindNaluIndices(bytes);
            for (const auto& nalu : nalus) {
                if (nalu.payload_size == 0) continue;
                const uint8_t* data = packet->data + nalu.payload_start_offset;
                const auto type = webrtc::H264::ParseNaluType(data[0]);
                idr |= type == webrtc::H264::kIdr;
                pps |= type == webrtc::H264::kPps;
                if (type == webrtc::H264::kSps) {
                    if (nalu.payload_size < 4) { ffmpeg().av_packet_free(&packet); return hardware_failure(); }
                    char value[7];
                    std::snprintf(value, sizeof(value), "%02x%02x%02x", data[1], data[2], data[3]);
                    webrtc::CodecParameterMap actual{{"profile-level-id", value}};
                    const auto expected = hardware_h264_profile(format_, true);
                    const auto emitted = webrtc::ParseSdpForH264ProfileLevelId(actual);
                    if (!expected || !emitted || !webrtc::H264IsProfileSubsetOf(actual, format_.parameters) ||
                        static_cast<int>(emitted->level) > static_cast<int>(expected->level)) {
                        ffmpeg().av_packet_free(&packet);
                        return hardware_failure();
                    }
                    sps = true;
                }
            }
            if (nalus.empty() || (source->second.key_requested && !idr) || (idr && (!sps || !pps))) {
                ffmpeg().av_packet_free(&packet);
                return hardware_failure();
            }
            webrtc::EncodedImage image;
            image.SetEncodedData(webrtc::EncodedImageBuffer::Create(packet->data, packet->size));
            image._encodedWidth = codec_.width;
            image._encodedHeight = codec_.height;
            image.SetRtpTimestamp(source->second.frame.rtp_timestamp());
            image.capture_time_ms_ = source->second.frame.timestamp_us() / 1000;
            image.ntp_time_ms_ = source->second.frame.ntp_time_ms();
            image.rotation_ = source->second.frame.rotation();
            image.SetColorSpace(source->second.frame.color_space());
            image.SetPacketInfos(source->second.frame.packet_infos());
            image.content_type_ = source->second.frame.content_type().value_or(
                webrtc::VideoContentType::UNSPECIFIED);
            image.set_frame_type(idr ? webrtc::VideoFrameType::kVideoFrameKey : webrtc::VideoFrameType::kVideoFrameDelta);
            parser_.ParseBitstream(bytes);
            image.qp_ = parser_.GetLastSliceQp().value_or(-1);
            webrtc::CodecSpecificInfo info;
            info.codecType = webrtc::kVideoCodecH264;
            info.codecSpecific.H264.packetization_mode = webrtc::H264PacketizationMode::NonInterleaved;
            info.codecSpecific.H264.temporal_idx = 0;
            info.codecSpecific.H264.base_layer_sync = false;
            info.codecSpecific.H264.idr_frame = idr;
            pending_.erase(source);
            ffmpeg().av_packet_free(&packet);
            if (callback_->OnEncodedImage(image, &info).error != webrtc::EncodedImageCallback::Result::OK) {
                return WEBRTC_VIDEO_CODEC_ERROR;
            }
            delivered_current |= image.RtpTimestamp() == frame.rtp_timestamp();
        }
    }

    EncoderInfo GetEncoderInfo() const override {
        EncoderInfo info;
        info.implementation_name = device_type_ == AV_HWDEVICE_TYPE_CUDA
            ? "DinoX FFmpeg NVENC H264" : "DinoX FFmpeg VA-API H264";
        info.is_hardware_accelerated = true;
        info.supports_native_handle = false;
        info.has_trusted_rate_controller = false;
        info.requested_resolution_alignment = 2;
        info.supports_simulcast = false;
        info.scaling_settings = ScalingSettings(24, 37);
        return info;
    }

 private:
    bool initialize() {
        reset();
        const auto profile = hardware_h264_profile(format_, true);
        if (!profile) return false;
        for (const auto type : {AV_HWDEVICE_TYPE_VAAPI, AV_HWDEVICE_TYPE_CUDA}) {
            if (type == AV_HWDEVICE_TYPE_CUDA && environment_flag_enabled("DINOX_WEBRTC_DISABLE_CUDA")) continue;
            for (const int low_power : {0, 1}) {
                if (type == AV_HWDEVICE_TYPE_CUDA && low_power != 0) break;
                reset();
                device_type_ = type;
                const AVCodec* encoder = ffmpeg().avcodec_find_encoder_by_name(
                    type == AV_HWDEVICE_TYPE_VAAPI ? "h264_vaapi" : "h264_nvenc");
                if (!encoder) break;
                int status = ffmpeg().av_hwdevice_ctx_create(&device_, type,
                    type == AV_HWDEVICE_TYPE_VAAPI ? std::getenv("DINOX_WEBRTC_VAAPI_DEVICE") : nullptr, nullptr, 0);
                if (status < 0 || device_ == nullptr) break;
                context_ = ffmpeg().avcodec_alloc_context3(encoder);
                if (!context_) continue;
                context_->width = codec_.width;
                context_->height = codec_.height;
                context_->time_base = AVRational{1, framerate_};
                context_->framerate = AVRational{framerate_, 1};
                context_->pix_fmt = type == AV_HWDEVICE_TYPE_VAAPI ? AV_PIX_FMT_VAAPI : AV_PIX_FMT_CUDA;
                context_->profile = ffmpeg_h264_profile(profile->profile);
                context_->level = static_cast<int>(profile->level);
                context_->bit_rate = bitrate_;
                context_->rc_max_rate = bitrate_;
                context_->rc_buffer_size = static_cast<int>(std::min<uint32_t>(bitrate_ / 2, INT_MAX));
                context_->gop_size = std::max(framerate_ * 2, 1);
                context_->max_b_frames = 0;
                context_->flags |= AV_CODEC_FLAG_LOW_DELAY;
                context_->thread_count = 1;
                context_->hw_device_ctx = ffmpeg().av_buffer_ref(device_);
                context_->hw_frames_ctx = ffmpeg().av_hwframe_ctx_alloc(device_);
                if (!context_->hw_device_ctx || !context_->hw_frames_ctx) continue;
                auto* frames = reinterpret_cast<AVHWFramesContext*>(context_->hw_frames_ctx->data);
                frames->format = context_->pix_fmt;
                frames->sw_format = AV_PIX_FMT_NV12;
                frames->width = codec_.width;
                frames->height = codec_.height;
                frames->initial_pool_size = 16;
                if (ffmpeg().av_hwframe_ctx_init(context_->hw_frames_ctx) < 0) continue;
                if (type == AV_HWDEVICE_TYPE_VAAPI) {
                    if (ffmpeg().av_opt_set_int(context_->priv_data, "low_power", low_power, 0) < 0 ||
                        ffmpeg().av_opt_set_int(context_->priv_data, "async_depth", 1, 0) < 0) continue;
                } else {
                    const char* name = profile->profile == webrtc::H264Profile::kProfileMain ? "main" :
                        profile->profile == webrtc::H264Profile::kProfileHigh ? "high" : "baseline";
                    const bool modern_presets = ffmpeg().av_opt_set(context_->priv_data, "preset", "p1", 0) == 0;
                    if ((!modern_presets && ffmpeg().av_opt_set(context_->priv_data, "preset", "llhp", 0) < 0) ||
                        (modern_presets && ffmpeg().av_opt_set(context_->priv_data, "tune", "ull", 0) < 0) ||
                        ffmpeg().av_opt_set(context_->priv_data, "profile", name, 0) < 0 ||
                        ffmpeg().av_opt_set(context_->priv_data, "rc", "cbr", 0) < 0 ||
                        ffmpeg().av_opt_set_int(context_->priv_data, "rc-lookahead", 0, 0) < 0 ||
                        ffmpeg().av_opt_set_int(context_->priv_data, "delay", 0, 0) < 0 ||
                        ffmpeg().av_opt_set_int(context_->priv_data, "zerolatency", 1, 0) < 0 ||
                        ffmpeg().av_opt_set_int(context_->priv_data, "forced-idr", 1, 0) < 0) continue;
                }
                status = ffmpeg().avcodec_open2(context_, encoder, nullptr);
                if (status < 0) { decoder_debug_error("H264 hardware encoder initialization", status); continue; }
                software_frame_ = ffmpeg().av_frame_alloc();
                if (!software_frame_) continue;
                software_frame_->format = AV_PIX_FMT_NV12;
                software_frame_->width = codec_.width;
                software_frame_->height = codec_.height;
                if (ffmpeg().av_frame_get_buffer(software_frame_, 32) < 0) continue;
                force_key_ = true;
                encoded_since_init_ = false;
                initialized_at_ = std::chrono::steady_clock::now();
                return true;
            }
        }
        reset();
        return false;
    }

    void reset() {
        // Encoders with delayed output cannot carry old frames into a new
        // rate-control context. Inform libwebrtc before discarding them.
        if (callback_) for (const auto& entry : pending_) callback_->OnFrameDropped(entry.second.frame.rtp_timestamp(), 0, true);
        pending_.clear();
        if (software_frame_) ffmpeg().av_frame_free(&software_frame_);
        if (context_) ffmpeg().avcodec_free_context(&context_);
        if (device_) ffmpeg().av_buffer_unref(&device_);
        force_key_ = true;
        hardware_failed_ = false;
    }

    const webrtc::SdpVideoFormat format_;
    webrtc::VideoCodec codec_;
    webrtc::EncodedImageCallback* callback_ = nullptr;
    AVCodecContext* context_ = nullptr;
    AVBufferRef* device_ = nullptr;
    AVFrame* software_frame_ = nullptr;
    AVHWDeviceType device_type_ = AV_HWDEVICE_TYPE_NONE;
    struct PendingEncoding { webrtc::VideoFrame frame; bool key_requested; };
    std::map<int64_t, PendingEncoding> pending_;
    webrtc::H264BitstreamParser parser_;
    uint32_t bitrate_ = 0;
    uint32_t target_bitrate_ = 0;
    int framerate_ = 30;
    int target_framerate_ = 30;
    std::chrono::steady_clock::time_point initialized_at_;
    int64_t sequence_ = 0;
    bool paused_ = false;
    bool force_key_ = true;
    bool encoded_since_init_ = false;
    bool hardware_failed_ = false;
};

#endif  // DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER

}  // namespace

bool IsVp8VaapiDecodeAvailable() {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (environment_flag_enabled("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER")) return false;
    auto& cache = vp8_qualification_cache();
    const auto key = vp8_qualification_key();
    {
        std::lock_guard<std::mutex> lock(cache.mutex);
        const auto found = cache.entries.find(key);
        if (found != cache.entries.end()) {
            return found->second == Vp8QualificationState::Qualified;
        }
        if (cache.entries.size() >= 64) {
            const auto evict = std::find_if(cache.entries.begin(), cache.entries.end(),
                [](const auto& entry) { return entry.second != Vp8QualificationState::InProgress; });
            if (evict == cache.entries.end()) return false;
            cache.entries.erase(evict);
        }
        cache.entries.emplace(key, Vp8QualificationState::InProgress);
    }
    const bool qualified = qualify_vp8_vaapi_decode();
    {
        std::lock_guard<std::mutex> lock(cache.mutex);
        cache.entries[key] = qualified
            ? Vp8QualificationState::Qualified : Vp8QualificationState::Rejected;
    }
    return qualified && !environment_flag_enabled("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER");
#else
    return false;
#endif
}

bool IsVp8VaapiDecodeQualified() {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (environment_flag_enabled("DINOX_WEBRTC_DISABLE_VP8_HW_DECODER")) return false;
    auto& cache = vp8_qualification_cache();
    const auto key = vp8_qualification_key();
    std::lock_guard<std::mutex> lock(cache.mutex);
    const auto found = cache.entries.find(key);
    return found != cache.entries.end() && found->second == Vp8QualificationState::Qualified;
#else
    return false;
#endif
}

bool IsVp8VaapiProviderAvailable() {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    return ffmpeg().available &&
        hardware_pixel_format(ffmpeg().avcodec_find_decoder(AV_CODEC_ID_VP8)) !=
            AV_PIX_FMT_NONE;
#else
    return false;
#endif
}

bool IsH264FfmpegProviderAvailable() {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    return ffmpeg().available && ffmpeg().avcodec_find_decoder(AV_CODEC_ID_H264) != nullptr &&
        ffmpeg().avcodec_find_encoder_by_name("h264_vaapi") != nullptr &&
        ffmpeg().avcodec_find_encoder_by_name("h264_nvenc") != nullptr;
#else
    return false;
#endif
}

bool IsH264FfmpegDecodeAvailable(const webrtc::SdpVideoFormat& format) {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (environment_flag_enabled("DINOX_WEBRTC_DISABLE_H264_HW_DECODER")) return false;
    return cached_capability("h264-decode:" + format.ToString(), [&] {
        const auto device = h264_decode_device(format);
        // CUDA device creation does not prove an NVDEC engine exists. The
        // actual decoder may still attempt it and fall back on its first frame;
        // capability advertisement stays conservative without a decode proof.
        return device && *device == AV_HWDEVICE_TYPE_VAAPI;
    });
#else
    return false;
#endif
}

bool IsH264FfmpegEncodeAvailable(const webrtc::SdpVideoFormat& format,
                               std::optional<webrtc::Resolution> resolution) {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (environment_flag_enabled("DINOX_WEBRTC_DISABLE_H264_HW_ENCODER")) return false;
    webrtc::VideoCodec codec;
    codec.codecType = webrtc::kVideoCodecH264;
    const int width = resolution ? resolution->width : 320;
    const int height = resolution ? resolution->height : 240;
    if (width <= 0 || height <= 0 || width > UINT16_MAX || height > UINT16_MAX) return false;
    codec.width = width;
    codec.height = height;
    codec.maxFramerate = 30;
    codec.startBitrate = 500;
    codec.maxBitrate = 500;
    *codec.H264() = webrtc::VideoEncoder::GetDefaultH264Settings();
    return cached_capability("h264-encode:" + format.ToString() + ":" +
        std::to_string(width) + "x" + std::to_string(height), [&] {
        FfmpegHardwareH264Encoder encoder(format);
        return encoder.InitEncode(&codec, webrtc::VideoEncoder::Settings(
            webrtc::VideoEncoder::Capabilities(false), 1, 1200)) == WEBRTC_VIDEO_CODEC_OK;
    });
#else
    return false;
#endif
}

std::unique_ptr<webrtc::VideoEncoder> CreateFfmpegHardwareEncoder(const webrtc::SdpVideoFormat& format) {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (hardware_h264_profile(format, true)) return std::make_unique<FfmpegHardwareH264Encoder>(format);
#endif
    return nullptr;
}

std::unique_ptr<webrtc::VideoDecoder> CreateFfmpegHardwareDecoder(const webrtc::SdpVideoFormat& format) {
#if defined(DINOX_WEBRTC_ENABLE_VP8_VAAPI_DECODER)
    if (absl::EqualsIgnoreCase(format.name, "VP8")) {
        return std::make_unique<FfmpegHardwareDecoder>(webrtc::kVideoCodecVP8, AV_HWDEVICE_TYPE_VAAPI);
    }
    const auto type = h264_decode_device(format);
    if (type) return std::make_unique<FfmpegHardwareDecoder>(webrtc::kVideoCodecH264, *type);
#endif
    return nullptr;
}

}  // namespace dinox::webrtc_runtime
