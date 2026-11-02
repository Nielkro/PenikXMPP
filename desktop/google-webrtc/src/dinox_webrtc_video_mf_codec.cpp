#include "dinox_webrtc_video_mf_codec.hpp"

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
// The Windows SDK declares overloaded GUID/D3D operators. Include it with
// C++ linkage before FFmpeg's hwcontext_d3d11va.h enters the extern-C block.
#include <d3d11.h>
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

#include "absl/strings/match.h"
#include "api/video/i420_buffer.h"
#include "api/video_codecs/h264_profile_level_id.h"
#include "common_video/h264/h264_common.h"
#include "common_video/h264/h264_bitstream_parser.h"
#include "libyuv/convert.h"
#include "libyuv/convert_from.h"
#include "modules/video_coding/include/video_codec_interface.h"
#include "modules/video_coding/include/video_error_codes.h"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
#include <libavutil/opt.h>
}

namespace dinox::webrtc_runtime {
namespace {

// Never resolve FFmpeg symbols through Chromium's statically linked FFmpeg or
// a host application's DLL. Both private DLLs must sit beside this wrapper.
class FfmpegApi {
 public:
#define DINOX_AV_FUNCTIONS(X) \
    X(avcodec_version) X(avutil_version) X(avcodec_find_encoder_by_name) \
    X(avcodec_find_decoder_by_name) X(avcodec_get_hw_config) \
    X(avcodec_alloc_context3) X(avcodec_free_context) X(avcodec_open2) \
    X(avcodec_send_frame) X(avcodec_receive_packet) X(avcodec_send_packet) \
    X(avcodec_receive_frame) X(av_packet_alloc) X(av_packet_free) \
    X(av_packet_unref) X(av_new_packet) X(av_frame_alloc) X(av_frame_free) \
    X(av_frame_unref) X(av_frame_get_buffer) X(av_frame_make_writable) \
    X(av_hwdevice_ctx_create) X(av_hwframe_transfer_data) X(av_buffer_ref) \
    X(av_buffer_unref) X(av_opt_set)
#define DECLARE(name) decltype(&::name) name = nullptr;
    DINOX_AV_FUNCTIONS(DECLARE)
#undef DECLARE
    bool ready = false;

    FfmpegApi() {
        HMODULE owner = nullptr;
        static const unsigned char module_anchor = 0;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCWSTR>(&module_anchor), &owner)) return;
        const std::wstring wrapper = ModulePath(owner);
        const auto slash = wrapper.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return;
        const std::wstring directory = wrapper.substr(0, slash + 1);
        util_ = LoadSibling(directory + L"avutil-dinox-hw-60.dll", L"avutil-dinox-hw-60.dll");
        if (!util_) return;
        codec_ = LoadSibling(directory + L"avcodec-dinox-hw-62.dll", L"avcodec-dinox-hw-62.dll");
        if (!codec_) { FreeLibrary(util_); util_ = nullptr; return; }
#define RESOLVE(name) \
        name = Resolve<decltype(name)>(codec_, #name); \
        if (!name) name = Resolve<decltype(name)>(util_, #name); \
        if (!name) { Close(); return; }
        DINOX_AV_FUNCTIONS(RESOLVE)
#undef RESOLVE
        ready = (avcodec_version() >> 16) == LIBAVCODEC_VERSION_MAJOR &&
                (avutil_version() >> 16) == LIBAVUTIL_VERSION_MAJOR;
        if (!ready) Close();
    }
    // Loaded for process lifetime: no FFmpeg function pointer or context can
    // outlive its module, including late worker-thread shutdown.
    static const FfmpegApi& Get() { static const FfmpegApi api; return api; }
 private:
    template<class Function> static Function Resolve(HMODULE module, const char* name) {
        const FARPROC address = GetProcAddress(module, name);
        Function result = nullptr;
        static_assert(sizeof(result) == sizeof(address));
        std::memcpy(&result, &address, sizeof(result));
        return result;
    }
    static std::wstring ModulePath(HMODULE module) {
        wchar_t buffer[32768];
        const DWORD length = GetModuleFileNameW(module, buffer, 32768);
        return length && length < 32768 ? std::wstring(buffer, length) : L"";
    }
    static HMODULE LoadSibling(const std::wstring& path, const wchar_t* basename) {
        HMODULE existing = GetModuleHandleW(basename);
        if (existing && _wcsicmp(ModulePath(existing).c_str(), path.c_str()) != 0) return nullptr;
        HMODULE module = LoadLibraryExW(path.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (module && _wcsicmp(ModulePath(module).c_str(), path.c_str()) != 0) {
            FreeLibrary(module); return nullptr;
        }
        return module;
    }
    void Close() {
        ready = false;
        if (codec_) FreeLibrary(codec_);
        if (util_) FreeLibrary(util_);
        codec_ = util_ = nullptr;
    }
    HMODULE codec_ = nullptr;
    HMODULE util_ = nullptr;
};
#undef DINOX_AV_FUNCTIONS

// FFmpeg's MF provider balances CoInitializeEx/CoUninitialize internally.
// Creation, use and destruction must therefore occur on one MTA thread even
// if WebRTC initializes/releases a codec from different task queues.
class CodecThread {
 public:
    CodecThread() : thread_([this] {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            condition_.wait(lock, [this] { return stopping_ || work_; });
            if (stopping_) return;
            auto work = std::move(work_);
            work_ = nullptr;
            lock.unlock(); work(); lock.lock();
            complete_ = true;
            condition_.notify_all();
        }
    }) {}
    ~CodecThread() {
        { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
        condition_.notify_all(); thread_.join();
    }
    void Invoke(std::function<void()> work) {
        std::lock_guard<std::mutex> invocation(invoke_mutex_);
        std::unique_lock<std::mutex> lock(mutex_);
        complete_ = false; work_ = std::move(work);
        condition_.notify_all();
        condition_.wait(lock, [this] { return complete_; });
    }
 private:
    std::mutex invoke_mutex_;
    std::mutex mutex_;
    std::condition_variable condition_;
    std::function<void()> work_;
    bool stopping_ = false;
    bool complete_ = false;
    std::thread thread_;
};

std::optional<webrtc::H264ProfileLevelId> SupportedProfile(
        const webrtc::SdpVideoFormat& format, bool encoder) {
    if (!absl::EqualsIgnoreCase(format.name, "H264")) return std::nullopt;
    const auto mode = format.parameters.find("packetization-mode");
    if (mode != format.parameters.end() && mode->second != "0" && mode->second != "1")
        return std::nullopt;
    // MF cannot bound individual slice sizes for single-NAL packetization.
    if (encoder && (mode == format.parameters.end() || mode->second != "1"))
        return std::nullopt;
    const auto profile = webrtc::ParseSdpForH264ProfileLevelId(format.parameters);
    if (!profile || profile->level == webrtc::H264Level::kLevel1_b) return std::nullopt;
    switch (profile->profile) {
        case webrtc::H264Profile::kProfileConstrainedBaseline:
        case webrtc::H264Profile::kProfileBaseline:
        case webrtc::H264Profile::kProfileMain:
        case webrtc::H264Profile::kProfileHigh: return profile;
        default: return std::nullopt;
    }
}

int AvProfile(webrtc::H264Profile profile) {
    if (profile == webrtc::H264Profile::kProfileConstrainedBaseline)
        return AV_PROFILE_H264_CONSTRAINED_BASELINE;
    if (profile == webrtc::H264Profile::kProfileMain) return AV_PROFILE_H264_MAIN;
    if (profile == webrtc::H264Profile::kProfileHigh) return AV_PROFILE_H264_HIGH;
    return AV_PROFILE_H264_BASELINE;
}

struct FrameMetadata {
    uint32_t rtp_timestamp = 0;
    int64_t timestamp_us = 0;
    int64_t ntp_time_ms = 0;
    std::optional<webrtc::ColorSpace> color_space;
    webrtc::VideoRotation rotation = webrtc::kVideoRotation_0;
    webrtc::RtpPacketInfos packet_infos = {};
    webrtc::VideoContentType content_type = webrtc::VideoContentType::UNSPECIFIED;
    bool key_requested = false;
};

class MftEncoder final : public webrtc::VideoEncoder {
 public:
    explicit MftEncoder(webrtc::SdpVideoFormat format) : format_(std::move(format)) {}
    ~MftEncoder() override { Release(); }
    int InitEncode(const webrtc::VideoCodec* settings, const Settings&) override {
        Release();
        if (!settings || settings->codecType != webrtc::kVideoCodecH264 ||
            !settings->width || !settings->height || settings->width % 2 || settings->height % 2 ||
            !settings->maxFramerate || settings->numberOfSimulcastStreams > 1 ||
            settings->H264().numberOfTemporalLayers > 1 || !SupportedProfile(format_, true))
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (settings->GetScalabilityMode() &&
            *settings->GetScalabilityMode() != webrtc::ScalabilityMode::kL1T1)
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        width_ = settings->width; height_ = settings->height;
        fps_ = settings->maxFramerate;
        bitrate_ = settings->startBitrate * 1000ULL;
        key_interval_ = settings->H264().keyFrameInterval;
        bool ok = false;
        thread_.Invoke([&] { ok = Open(); });
        return ok ? WEBRTC_VIDEO_CODEC_OK : WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
    }
    int32_t RegisterEncodeCompleteCallback(webrtc::EncodedImageCallback* callback) override {
        callback_ = callback; return WEBRTC_VIDEO_CODEC_OK;
    }
    int32_t Release() override {
        thread_.Invoke([this] { Close(); });
        return WEBRTC_VIDEO_CODEC_OK;
    }
    void SetRates(const RateControlParameters& rates) override {
        const uint32_t bitrate = rates.bitrate.get_sum_bps();
        const double fps = rates.framerate_fps;
        thread_.Invoke([&] {
            bitrate_ = bitrate;
            if (std::isfinite(fps) && fps > 0) fps_ = std::clamp(fps, 1.0, 120.0);
            // The private mfenc dynamic-bitrate patch applies this through
            // ICodecAPI before the next frame. No reset and no forced IDR.
            if (context_ && bitrate_) context_->bit_rate = bitrate_;
        });
    }
    int32_t Encode(const webrtc::VideoFrame& frame,
                   const std::vector<webrtc::VideoFrameType>* types) override {
        if (!callback_) return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
        std::vector<webrtc::EncodedImage> output;
        int result = WEBRTC_VIDEO_CODEC_OK;
        thread_.Invoke([&] { result = EncodeOnThread(frame, types, output); });
        // The fallback wrapper may encode this same RTP timestamp again.
        // Publish nothing from a failed operation, including delayed output.
        if (result != WEBRTC_VIDEO_CODEC_OK) return result;
        for (const auto& image : output) {
            webrtc::CodecSpecificInfo info;
            info.codecType = webrtc::kVideoCodecH264;
            info.codecSpecific.H264.packetization_mode = webrtc::H264PacketizationMode::NonInterleaved;
            info.codecSpecific.H264.temporal_idx = webrtc::kNoTemporalIdx;
            info.codecSpecific.H264.base_layer_sync = false;
            info.codecSpecific.H264.idr_frame = image.FrameType() == webrtc::VideoFrameType::kVideoFrameKey;
            if (callback_->OnEncodedImage(image, &info).error != webrtc::EncodedImageCallback::Result::OK)
                return WEBRTC_VIDEO_CODEC_ERROR;
        }
        return result;
    }
    EncoderInfo GetEncoderInfo() const override {
        EncoderInfo info;
        info.implementation_name = "DinoX MediaFoundation H264 (hardware)";
        info.is_hardware_accelerated = true;
        info.supports_native_handle = false;
        info.has_trusted_rate_controller = false;
        info.supports_simulcast = false;
        info.requested_resolution_alignment = 2;
        info.scaling_settings.thresholds = QpThresholds(24, 37);
        return info;
    }
    bool Probe(int width, int height) {
        bool result = false;
        width_ = width; height_ = height; fps_ = 30; bitrate_ = 300000;
        thread_.Invoke([&] {
            if (Open()) {
                auto pixels = webrtc::I420Buffer::Create(width_, height_);
                webrtc::I420Buffer::SetBlack(pixels.get());
                size_t frames_produced = 0;
                for (int index = 0; index < 8 && frames_produced < 2; ++index) {
                    auto frame = webrtc::VideoFrame::Builder().set_video_frame_buffer(pixels)
                        .set_rtp_timestamp(90000 + index * 3000).set_timestamp_us(index * 33333).build();
                    const std::vector<webrtc::VideoFrameType> type{
                        index == 0 ? webrtc::VideoFrameType::kVideoFrameKey : webrtc::VideoFrameType::kVideoFrameDelta};
                    std::vector<webrtc::EncodedImage> output;
                    if (index > 0) context_->bit_rate = 250000;
                    if (EncodeOnThread(frame, &type, output) != WEBRTC_VIDEO_CODEC_OK) {
                        frames_produced = 0; break;
                    }
                    frames_produced += output.size();
                }
                result = frames_produced >= 2;
            }
            Close();
        });
        return result;
    }
 private:
    bool Open(bool baseline_compatible = false) {
        const auto& api = FfmpegApi::Get();
        const auto profile = SupportedProfile(format_, true);
        if (!api.ready || !profile) return false;
        const AVCodec* codec = api.avcodec_find_encoder_by_name("h264_mf");
        if (!codec) return false;
        context_ = api.avcodec_alloc_context3(codec);
        if (!context_) return false;
        context_->width = width_; context_->height = height_;
        context_->pix_fmt = AV_PIX_FMT_NV12;
        context_->time_base = {1, 90000};
        context_->framerate = {static_cast<int>(std::lround(fps_ * 1000)), 1000};
        context_->bit_rate = bitrate_ ? bitrate_ : 300000;
        context_->gop_size = key_interval_ > 0 ? key_interval_ : 300;
        context_->max_b_frames = 0;
        context_->flags |= AV_CODEC_FLAG_LOW_DELAY;
        context_->profile = baseline_compatible ? AV_PROFILE_H264_BASELINE : AvProfile(profile->profile);
        context_->level = static_cast<int>(profile->level);
        if (api.av_opt_set(context_->priv_data, "hw_encoding", "1", 0) < 0 ||
            api.av_opt_set(context_->priv_data, "rate_control", "cbr", 0) < 0 ||
            api.av_opt_set(context_->priv_data, "scenario", "video_conference", 0) < 0 ||
            api.avcodec_open2(context_, codec, nullptr) < 0) {
            Close();
            // Some drivers accept only the Baseline MF enum but emit the
            // constrained subset. Accept that only after checking every SPS.
            if (!baseline_compatible && profile->profile == webrtc::H264Profile::kProfileConstrainedBaseline)
                return Open(true);
            return false;
        }
        input_ = api.av_frame_alloc(); packet_ = api.av_packet_alloc();
        if (!input_ || !packet_) { Close(); return false; }
        input_->format = context_->pix_fmt; input_->width = width_; input_->height = height_;
        if (api.av_frame_get_buffer(input_, 32) < 0) { Close(); return false; }
        return true;
    }
    void Close() {
        const auto& api = FfmpegApi::Get();
        if (api.ready) {
            api.av_frame_free(&input_); api.av_packet_free(&packet_);
            api.avcodec_free_context(&context_);
        }
        pending_.clear(); sps_.clear(); pps_.clear(); key_frame_sent_ = false; next_pts_ = 0;
    }
    bool ReadParameterSets(const uint8_t* data, size_t size) {
        const auto nalus = webrtc::H264::FindNaluIndices(std::span(data, size));
        if (nalus.empty()) return false; // MF must produce Annex B, never AVCC.
        for (const auto& nalu : nalus) {
            if (!nalu.payload_size) return false;
            const uint8_t* payload = data + nalu.payload_start_offset;
            const auto type = webrtc::H264::ParseNaluType(payload[0]);
            if (type == webrtc::H264::kPps) {
                if (nalu.payload_size < 2) return false;
                pps_ = {0, 0, 0, 1};
                pps_.insert(pps_.end(), payload, payload + nalu.payload_size);
            }
            if (type != webrtc::H264::kSps) continue;
            if (nalu.payload_size < 4) return false;
            char value[7];
            std::snprintf(value, sizeof(value), "%02x%02x%02x", payload[1], payload[2], payload[3]);
            webrtc::CodecParameterMap actual;
            actual["profile-level-id"] = value;
            const auto parsed = webrtc::ParseSdpForH264ProfileLevelId(actual);
            const auto negotiated = SupportedProfile(format_, true);
            if (!parsed || !negotiated ||
                !webrtc::H264IsProfileSubsetOf(actual, format_.parameters) ||
                static_cast<int>(parsed->level) > static_cast<int>(negotiated->level)) return false;
            sps_ = {0, 0, 0, 1};
            sps_.insert(sps_.end(), payload, payload + nalu.payload_size);
        }
        return true;
    }
    bool PrepareAccessUnit(std::vector<uint8_t>& bytes, bool key_requested, bool* idr) {
        if (sps_.empty() && context_->extradata && context_->extradata_size > 0 &&
            context_->extradata_size < 1024 * 1024 &&
            !ReadParameterSets(context_->extradata, context_->extradata_size)) return false;
        if (!ReadParameterSets(bytes.data(), bytes.size())) return false;
        *idr = false;
        bool has_sps = false, has_pps = false;
        for (const auto& nalu : webrtc::H264::FindNaluIndices(bytes)) {
            const auto type = webrtc::H264::ParseNaluType(bytes[nalu.payload_start_offset]);
            *idr |= type == webrtc::H264::kIdr;
            has_sps |= type == webrtc::H264::kSps;
            has_pps |= type == webrtc::H264::kPps;
        }
        if (sps_.empty() || pps_.empty() || ((!key_frame_sent_ || key_requested) && !*idr)) return false;
        if (*idr) {
            if (!has_sps || !has_pps) {
                bytes.insert(bytes.begin(), pps_.begin(), pps_.end());
                bytes.insert(bytes.begin(), sps_.begin(), sps_.end());
            }
            key_frame_sent_ = true;
        }
        return true;
    }
    int EncodeOnThread(const webrtc::VideoFrame& frame,
                       const std::vector<webrtc::VideoFrameType>* types,
                       std::vector<webrtc::EncodedImage>& output) {
        const auto& api = FfmpegApi::Get();
        if (!context_) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        if (!bitrate_) return WEBRTC_VIDEO_CODEC_OK;
        if (types && !types->empty() &&
            types->front() == webrtc::VideoFrameType::kEmptyFrame) return WEBRTC_VIDEO_CODEC_OK;
        if (frame.width() != width_ || frame.height() != height_ || pending_.size() >= 32)
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        auto i420 = frame.video_frame_buffer()->ToI420();
        if (!i420 || api.av_frame_make_writable(input_) < 0 ||
            libyuv::I420ToNV12(i420->DataY(), i420->StrideY(), i420->DataU(), i420->StrideU(),
                i420->DataV(), i420->StrideV(), input_->data[0], input_->linesize[0],
                input_->data[1], input_->linesize[1], width_, height_) != 0)
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        // Independent monotonic PTS avoids RTP wraparound and clock-domain
        // ambiguity. Exact metadata is recovered by PTS, never by frame order.
        input_->pts = next_pts_;
        input_->duration = std::max<int64_t>(1, std::llround(90000.0 / fps_));
        next_pts_ += input_->duration;
        input_->pict_type = types && std::find(types->begin(), types->end(),
            webrtc::VideoFrameType::kVideoFrameKey) != types->end() ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
        FrameMetadata metadata{frame.rtp_timestamp(), frame.timestamp_us(), frame.ntp_time_ms(), frame.color_space()};
        metadata.rotation = frame.rotation();
        metadata.packet_infos = frame.packet_infos();
        metadata.content_type = frame.content_type().value_or(webrtc::VideoContentType::UNSPECIFIED);
        metadata.key_requested = input_->pict_type == AV_PICTURE_TYPE_I;
        pending_.emplace(input_->pts, std::move(metadata));
        int result = api.avcodec_send_frame(context_, input_);
        if (result < 0) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        for (;;) {
            result = api.avcodec_receive_packet(context_, packet_);
            if (result == AVERROR(EAGAIN)) return WEBRTC_VIDEO_CODEC_OK;
            if (result < 0) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            const auto found = pending_.find(packet_->pts);
            bool idr = false;
            if (found == pending_.end() || packet_->size <= 0 || packet_->size > 16 * 1024 * 1024) {
                api.av_packet_unref(packet_); return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            }
            std::vector<uint8_t> bytes(packet_->data, packet_->data + packet_->size);
            if (!PrepareAccessUnit(bytes, found->second.key_requested, &idr)) {
                api.av_packet_unref(packet_); return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            }
            webrtc::EncodedImage encoded;
            encoded.SetEncodedData(webrtc::EncodedImageBuffer::Create(bytes.data(), bytes.size()));
            encoded._encodedWidth = width_; encoded._encodedHeight = height_;
            encoded.SetRtpTimestamp(found->second.rtp_timestamp);
            encoded.capture_time_ms_ = found->second.timestamp_us / 1000;
            encoded.ntp_time_ms_ = found->second.ntp_time_ms;
            encoded.SetColorSpace(found->second.color_space);
            encoded.rotation_ = found->second.rotation;
            encoded.SetPacketInfos(found->second.packet_infos);
            encoded.content_type_ = found->second.content_type;
            parser_.ParseBitstream(bytes);
            encoded.qp_ = parser_.GetLastSliceQp().value_or(-1);
            encoded.set_frame_type(idr ? webrtc::VideoFrameType::kVideoFrameKey : webrtc::VideoFrameType::kVideoFrameDelta);
            output.push_back(std::move(encoded));
            pending_.erase(found);
            api.av_packet_unref(packet_);
        }
    }
    webrtc::SdpVideoFormat format_;
    CodecThread thread_;
    AVCodecContext* context_ = nullptr;
    AVFrame* input_ = nullptr;
    AVPacket* packet_ = nullptr;
    webrtc::EncodedImageCallback* callback_ = nullptr;
    std::map<int64_t, FrameMetadata> pending_;
    int width_ = 0, height_ = 0, key_interval_ = 0;
    double fps_ = 30;
    int64_t bitrate_ = 0, next_pts_ = 0;
    bool key_frame_sent_ = false;
    std::vector<uint8_t> sps_, pps_;
    webrtc::H264BitstreamParser parser_;
};

class D3d11Decoder final : public webrtc::VideoDecoder {
 public:
    ~D3d11Decoder() override { Release(); }
    bool Configure(const Settings& settings) override {
        Release();
        if (settings.codec_type() != webrtc::kVideoCodecH264) return false;
        max_width_ = settings.max_render_resolution().Valid() ? settings.max_render_resolution().Width() : 4096;
        max_height_ = settings.max_render_resolution().Valid() ? settings.max_render_resolution().Height() : 4096;
        bool ok = false;
        thread_.Invoke([&] { ok = Open(); });
        return ok;
    }
    int32_t RegisterDecodeCompleteCallback(webrtc::DecodedImageCallback* callback) override {
        callback_ = callback; return WEBRTC_VIDEO_CODEC_OK;
    }
    int32_t Release() override {
        thread_.Invoke([this] { Close(); }); return WEBRTC_VIDEO_CODEC_OK;
    }
    int32_t Decode(const webrtc::EncodedImage& input, int64_t render_time_ms) override {
        if (!callback_) return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
        std::vector<webrtc::VideoFrame> output;
        int result = WEBRTC_VIDEO_CODEC_OK;
        thread_.Invoke([&] { result = DecodeOnThread(input, render_time_ms, output); });
        if (result != WEBRTC_VIDEO_CODEC_OK) return result;
        for (auto& frame : output) callback_->Decoded(frame, std::nullopt, std::nullopt);
        return result;
    }
    DecoderInfo GetDecoderInfo() const override {
        return {"DinoX D3D11VA H264 (hardware)", true};
    }
    bool Probe() {
        bool ok = false; thread_.Invoke([&] { ok = Open(); Close(); }); return ok;
    }
 private:
    static AVPixelFormat ChooseHardwareFormat(AVCodecContext*, const AVPixelFormat* formats) {
        for (; *formats != AV_PIX_FMT_NONE; ++formats)
            if (*formats == AV_PIX_FMT_D3D11) return *formats;
        return AV_PIX_FMT_NONE; // Never silently decode in software here.
    }
    bool Open() {
        const auto& api = FfmpegApi::Get();
        if (!api.ready) return false;
        const AVCodec* codec = api.avcodec_find_decoder_by_name("h264");
        bool supported = false;
        if (codec) for (int index = 0;; ++index) {
            const AVCodecHWConfig* config = api.avcodec_get_hw_config(codec, index);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_D3D11VA &&
                config->pix_fmt == AV_PIX_FMT_D3D11 &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) supported = true;
        }
        if (!supported || api.av_hwdevice_ctx_create(&device_, AV_HWDEVICE_TYPE_D3D11VA,
                nullptr, nullptr, 0) < 0) { Close(); return false; }
        auto* device_context = reinterpret_cast<AVHWDeviceContext*>(device_->data);
        auto* d3d = static_cast<AVD3D11VADeviceContext*>(device_context->hwctx);
        // Device creation alone does not prove video decode support (virtual
        // adapters often expose D3D11 rendering but no H.264 video decoder).
        constexpr GUID h264_vld_nofgt = {0x1b81be68, 0xa0c7, 0x11d3,
            {0xb9, 0x84, 0x00, 0xc0, 0x4f, 0x2e, 0x73, 0xc5}};
        bool h264_nv12 = false;
        if (d3d && d3d->video_device) {
            for (UINT index = 0; index < d3d->video_device->GetVideoDecoderProfileCount(); ++index) {
                GUID profile = {}; BOOL nv12 = FALSE;
                if (SUCCEEDED(d3d->video_device->GetVideoDecoderProfile(index, &profile)) &&
                    std::memcmp(&profile, &h264_vld_nofgt, sizeof(profile)) == 0 &&
                    SUCCEEDED(d3d->video_device->CheckVideoDecoderFormat(&profile, DXGI_FORMAT_NV12, &nv12)) && nv12)
                    h264_nv12 = true;
            }
        }
        if (!h264_nv12) { Close(); return false; }
        context_ = api.avcodec_alloc_context3(codec);
        if (!context_) { Close(); return false; }
        context_->hw_device_ctx = api.av_buffer_ref(device_);
        context_->get_format = ChooseHardwareFormat;
        context_->thread_count = 1;
        context_->max_pixels = static_cast<int64_t>(std::min(max_width_, 4096)) * std::min(max_height_, 4096);
        context_->pkt_timebase = {1, 90000};
        context_->flags |= AV_CODEC_FLAG_LOW_DELAY;
        if (!context_->hw_device_ctx || api.avcodec_open2(context_, codec, nullptr) < 0) {
            Close(); return false;
        }
        decoded_ = api.av_frame_alloc(); cpu_ = api.av_frame_alloc(); packet_ = api.av_packet_alloc();
        if (!decoded_ || !cpu_ || !packet_) { Close(); return false; }
        return true;
    }
    void Close() {
        const auto& api = FfmpegApi::Get();
        if (api.ready) {
            api.av_frame_free(&decoded_); api.av_frame_free(&cpu_); api.av_packet_free(&packet_);
            api.avcodec_free_context(&context_); api.av_buffer_unref(&device_);
        }
        pending_.clear(); next_pts_ = 0;
    }
    int DecodeOnThread(const webrtc::EncodedImage& input, int64_t render_time_ms,
                       std::vector<webrtc::VideoFrame>& output) {
        const auto& api = FfmpegApi::Get();
        if (!context_ || !input.size() || input.size() > 16 * 1024 * 1024 || pending_.size() >= 32)
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        api.av_packet_unref(packet_);
        if (api.av_new_packet(packet_, static_cast<int>(input.size())) < 0)
            return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        std::memcpy(packet_->data, input.data(), input.size());
        // A unique PTS tags each compressed frame independently of RTP wrap.
        packet_->pts = packet_->dts = next_pts_++;
        FrameMetadata metadata{input.RtpTimestamp(), render_time_ms * 1000,
            input.NtpTimeMs(), input.ColorSpace() ? std::optional(*input.ColorSpace()) : std::nullopt};
        metadata.rotation = input.rotation();
        metadata.packet_infos = input.PacketInfos();
        metadata.content_type = input.contentType();
        pending_.emplace(packet_->pts, std::move(metadata));
        int result = api.avcodec_send_packet(context_, packet_);
        api.av_packet_unref(packet_);
        if (result < 0) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
        for (;;) {
            result = api.avcodec_receive_frame(context_, decoded_);
            if (result == AVERROR(EAGAIN)) return WEBRTC_VIDEO_CODEC_OK;
            if (result < 0) return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            const auto found = pending_.find(decoded_->pts);
            if (found == pending_.end() || decoded_->format != AV_PIX_FMT_D3D11 ||
                !decoded_->hw_frames_ctx || decoded_->width <= 0 || decoded_->height <= 0 ||
                decoded_->width > std::min(max_width_, 4096) || decoded_->height > std::min(max_height_, 4096) ||
                api.av_hwframe_transfer_data(cpu_, decoded_, 0) < 0 || cpu_->format != AV_PIX_FMT_NV12) {
                api.av_frame_unref(decoded_); api.av_frame_unref(cpu_);
                return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            }
            auto buffer = webrtc::I420Buffer::Create(cpu_->width, cpu_->height);
            const int converted = libyuv::NV12ToI420(cpu_->data[0], cpu_->linesize[0], cpu_->data[1],
                cpu_->linesize[1], buffer->MutableDataY(), buffer->StrideY(),
                buffer->MutableDataU(), buffer->StrideU(), buffer->MutableDataV(), buffer->StrideV(),
                cpu_->width, cpu_->height);
            if (converted != 0) {
                api.av_frame_unref(decoded_); api.av_frame_unref(cpu_);
                return WEBRTC_VIDEO_CODEC_FALLBACK_SOFTWARE;
            }
            auto frame = webrtc::VideoFrame::Builder().set_video_frame_buffer(buffer)
                .set_rtp_timestamp(found->second.rtp_timestamp)
                .set_timestamp_us(found->second.timestamp_us).set_ntp_time_ms(found->second.ntp_time_ms)
                .set_color_space(found->second.color_space).set_rotation(found->second.rotation)
                .set_packet_infos(found->second.packet_infos).set_content_type(found->second.content_type).build();
            output.push_back(std::move(frame)); pending_.erase(found);
            api.av_frame_unref(decoded_); api.av_frame_unref(cpu_);
        }
    }
    CodecThread thread_;
    AVCodecContext* context_ = nullptr;
    AVBufferRef* device_ = nullptr;
    AVFrame* decoded_ = nullptr;
    AVFrame* cpu_ = nullptr;
    AVPacket* packet_ = nullptr;
    webrtc::DecodedImageCallback* callback_ = nullptr;
    std::map<int64_t, FrameMetadata> pending_;
    int64_t next_pts_ = 0;
    int max_width_ = 4096, max_height_ = 4096;
};

}  // namespace

bool IsH264MftProviderAvailable() {
    const auto& api = FfmpegApi::Get();
    if (!api.ready || !api.avcodec_find_encoder_by_name("h264_mf")) return false;
    const AVCodec* decoder = api.avcodec_find_decoder_by_name("h264");
    if (!decoder) return false;
    for (int index = 0;; ++index) {
        const AVCodecHWConfig* config = api.avcodec_get_hw_config(decoder, index);
        if (!config) return false;
        if (config->device_type == AV_HWDEVICE_TYPE_D3D11VA &&
            config->pix_fmt == AV_PIX_FMT_D3D11 &&
            (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) return true;
    }
}

bool IsH264MftEncodeAvailable(const webrtc::SdpVideoFormat& format,
                            std::optional<webrtc::Resolution> resolution) {
    const auto profile = SupportedProfile(format, true);
    if (!profile || !FfmpegApi::Get().ready) return false;
    // Hardware enumeration/activation is expensive; one capability probe per
    // negotiated profile and level. A new call still opens its own transform.
    static std::mutex mutex;
    static std::map<std::tuple<int, int, int, int>, bool> cache;
    const int width = resolution ? resolution->width : 320;
    const int height = resolution ? resolution->height : 240;
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096 || width % 2 || height % 2) return false;
    const auto key = std::make_tuple(static_cast<int>(profile->profile), static_cast<int>(profile->level), width, height);
    std::lock_guard<std::mutex> lock(mutex);
    const auto found = cache.find(key);
    if (found != cache.end()) return found->second;
    if (cache.size() >= 64) cache.clear();
    return cache.emplace(key, MftEncoder(format).Probe(width, height)).first->second;
}

bool IsH264MftDecodeAvailable(const webrtc::SdpVideoFormat& format) {
    if (!SupportedProfile(format, false) || !FfmpegApi::Get().ready) return false;
    static const bool available = D3d11Decoder().Probe();
    return available;
}

std::unique_ptr<webrtc::VideoEncoder> CreateH264MftEncoder(const webrtc::SdpVideoFormat& format) {
    return IsH264MftEncodeAvailable(format) ? std::make_unique<MftEncoder>(format) : nullptr;
}

std::unique_ptr<webrtc::VideoDecoder> CreateH264MftDecoder(const webrtc::SdpVideoFormat& format) {
    return IsH264MftDecodeAvailable(format) ? std::make_unique<D3d11Decoder>() : nullptr;
}

}  // namespace dinox::webrtc_runtime
#endif
