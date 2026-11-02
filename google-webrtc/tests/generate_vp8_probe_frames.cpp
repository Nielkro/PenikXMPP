// Regenerate the embedded synthetic VP8 qualification frames with the pinned
// WebRTC SDK. This developer utility is never used by the application.
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>
#include "api/environment/environment_factory.h"
#include "api/video/encoded_image.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video/video_frame_type.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_codec.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_encoder_factory.h"
#include "modules/video_coding/include/video_error_codes.h"
namespace {
constexpr int kFrames = 16;
constexpr int kFps = 30;
constexpr auto kCallbackTimeout = std::chrono::seconds(2);
// Broad areas keep sample checks away from postprocessing-sensitive edges.
int source_luma(int index, int x, int y, int width, int height) {
    const int box_width = width / 5;
    const int box_height = height / 4;
    const int left = (index * 31) % (width - box_width);
    const int top = (index * 17) % (height - box_height);
    if (x >= left && x < left + box_width && y >= top && y < top + box_height) {
        return 184;
    }
    return 64 + ((x / 64 + y / 64) & 1) * 48 + (index % 4) * 4;
}

class EncodedFrames final : public webrtc::EncodedImageCallback {
 public:
    Result OnEncodedImage(const webrtc::EncodedImage& image,
                          const webrtc::CodecSpecificInfo*) override {
        std::lock_guard<std::mutex> lock(mutex_);
        // Own the immutable bytes: encoder implementations may reuse buffers.
        webrtc::EncodedImage copy = image;
        copy.SetEncodedData(webrtc::EncodedImageBuffer::Create(image.data(), image.size()));
        images_.push_back(std::move(copy));
        condition_.notify_all();
        return Result(Result::OK);
    }

    void OnFrameDropped(uint32_t, int, bool) override {
        std::lock_guard<std::mutex> lock(mutex_);
        dropped_ = true;
        condition_.notify_all();
    }

    webrtc::EncodedImage take(uint32_t timestamp) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!condition_.wait_for(lock, kCallbackTimeout,
                [&] { return dropped_ || !images_.empty(); }) ||
            dropped_ || images_.size() != 1 ||
            images_.front().RtpTimestamp() != timestamp) {
            throw std::runtime_error("encoder callback missing, dropped, duplicated or wrong timestamp");
        }
        auto image = std::move(images_.front());
        images_.clear();
        return image;
    }

 private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::vector<webrtc::EncodedImage> images_;
    bool dropped_ = false;
};

struct Sequence {
    int width;
    int height;
    std::vector<webrtc::EncodedImage> images;
};

Sequence generate_sequence(const webrtc::Environment& environment, int width, int height) {
    EncodedFrames callback;
    auto factory = webrtc::CreateBuiltinVideoEncoderFactory();
    auto encoder = factory->Create(environment, webrtc::SdpVideoFormat::VP8());
    if (!encoder) throw std::runtime_error("builtin VP8 encoder unavailable");
    webrtc::VideoCodec codec;
    codec.codecType = webrtc::kVideoCodecVP8;
    codec.width = width;
    codec.height = height;
    codec.maxFramerate = kFps;
    codec.startBitrate = 3000;
    codec.maxBitrate = 5000;
    codec.minBitrate = 100;
    codec.qpMax = 40;
    codec.SetFrameDropEnabled(false);
    *codec.VP8() = webrtc::VideoEncoder::GetDefaultVp8Settings();
    codec.VP8()->numberOfTemporalLayers = 1;
    codec.VP8()->automaticResizeOn = false;
    codec.VP8()->denoisingOn = false;
    const webrtc::VideoEncoder::Settings settings(
        webrtc::VideoEncoder::Capabilities(false), 1, 1200);
    if (encoder->InitEncode(&codec, settings) != WEBRTC_VIDEO_CODEC_OK ||
        encoder->RegisterEncodeCompleteCallback(&callback) != WEBRTC_VIDEO_CODEC_OK) {
        throw std::runtime_error("builtin VP8 encoder initialization failed");
    }
    webrtc::VideoBitrateAllocation allocation;
    allocation.SetBitrate(0, 0, 3000000);
    encoder->SetRates(webrtc::VideoEncoder::RateControlParameters(allocation, kFps));

    Sequence result{width, height, {}};
    for (int index = 0; index < kFrames; ++index) {
        const uint32_t timestamp = 90000 + index * (90000 / kFps);
        auto pixels = webrtc::I420Buffer::Create(width, height);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                pixels->MutableDataY()[y * pixels->StrideY() + x] =
                    static_cast<uint8_t>(source_luma(index, x, y, width, height));
            }
        }
        for (int y = 0; y < height / 2; ++y) {
            std::memset(pixels->MutableDataU() + y * pixels->StrideU(), 96, width / 2);
            std::memset(pixels->MutableDataV() + y * pixels->StrideV(), 160, width / 2);
        }
        const auto frame = webrtc::VideoFrame::Builder()
            .set_video_frame_buffer(pixels)
            .set_rtp_timestamp(timestamp)
            .set_timestamp_ms(1000 + index * 1000 / kFps)
            .build();
        const std::vector<webrtc::VideoFrameType> types{
            index == 0 ? webrtc::VideoFrameType::kVideoFrameKey
                       : webrtc::VideoFrameType::kVideoFrameDelta};
        if (encoder->Encode(frame, &types) != WEBRTC_VIDEO_CODEC_OK) {
            throw std::runtime_error("builtin VP8 encoding failed");
        }
        auto image = callback.take(timestamp);
        if (!image.size() || image._encodedWidth != width || image._encodedHeight != height ||
            (index == 0 && !image.IsKey())) {
            throw std::runtime_error("generated VP8 frame dimensions or keyframe invalid");
        }
        result.images.push_back(std::move(image));
    }
    if (encoder->Release() != WEBRTC_VIDEO_CODEC_OK) {
        throw std::runtime_error("builtin VP8 encoder release failed");
    }
    return result;
}


} // namespace
int main(int argc, char** argv) {
    if (argc != 2) {
        std::fputs("usage: google-webrtc-vp8-probe-fixture-generator OUTPUT.hpp\n", stderr);
        return 2;
    }
    try {
        const auto environment = webrtc::CreateEnvironment();
        std::vector<Sequence> sequences;
        sequences.push_back(generate_sequence(environment, 640, 480));
        sequences.push_back(generate_sequence(environment, 1280, 720));
        std::unique_ptr<FILE, decltype(&std::fclose)> output(std::fopen(argv[1], "wb"), &std::fclose);
        if (!output) throw std::runtime_error("cannot open output");
        FILE* file = output.get();
        std::fputs("// Generated by tests/generate_vp8_probe_frames.cpp with the pinned M152 SDK.\n"
            "// Synthetic motion: one key frame and 15 delta frames per resolution.\n"
            "// No camera, network or runtime encoding is used for qualification.\n"
            "#ifndef DINOX_WEBRTC_VP8_PROBE_FRAMES_HPP\n#define DINOX_WEBRTC_VP8_PROBE_FRAMES_HPP\n"
            "#include <cstddef>\n#include <cstdint>\nnamespace dinox::webrtc_runtime::vp8_probe {\n"
            "struct Frame { const uint8_t* data; size_t size; uint32_t rtp_timestamp; bool key; };\n"
            "struct Sequence { int width; int height; const Frame* frames; size_t count; };\n", file);
        for (size_t sequence = 0; sequence < sequences.size(); ++sequence) {
            const auto& images = sequences[sequence].images;
            for (size_t frame = 0; frame < images.size(); ++frame) {
                std::fprintf(file, "inline constexpr uint8_t kFrame%zu_%zu[] = {\n", sequence, frame);
                for (size_t byte = 0; byte < images[frame].size(); ++byte) {
                    if (byte % 16 == 0) std::fputs("    ", file);
                    std::fprintf(file, "0x%02x,", images[frame].data()[byte]);
                    std::fputs(byte % 16 == 15 || byte + 1 == images[frame].size() ? "\n" : " ", file);
                }
                std::fputs("};\n", file);
            }
            std::fprintf(file, "inline constexpr Frame kFrames%zu[] = {\n", sequence);
            for (size_t frame = 0; frame < images.size(); ++frame)
                std::fprintf(file, "    {kFrame%zu_%zu, sizeof(kFrame%zu_%zu), %uu, %s},\n",
                    sequence, frame, sequence, frame, images[frame].RtpTimestamp(),
                    images[frame].IsKey() ? "true" : "false");
            std::fputs("};\n", file);
        }
        std::fputs("inline constexpr Sequence kSequences[] = {\n", file);
        for (size_t sequence = 0; sequence < sequences.size(); ++sequence)
            std::fprintf(file, "    {%d, %d, kFrames%zu, sizeof(kFrames%zu) / sizeof(kFrames%zu[0])},\n",
                sequences[sequence].width, sequences[sequence].height, sequence, sequence, sequence);
        std::fputs("};\n} // namespace dinox::webrtc_runtime::vp8_probe\n#endif\n", file);
        if (std::fflush(file) != 0 || std::ferror(file)) throw std::runtime_error("output write failed");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "fixture generation failed: %s\n", error.what());
        return 1;
    }
}
