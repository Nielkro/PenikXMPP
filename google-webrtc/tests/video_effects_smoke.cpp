#include "dinox_webrtc_video_effects.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include "api/video/i420_buffer.h"
#include "api/video/color_space.h"

#define DINOX_CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "check failed: %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (false)

int check_extended_filters() {
    using Processor = dinox::webrtc_effects::VideoEffectProcessor;
    auto buffer = webrtc::I420Buffer::Create(3, 3);
    DINOX_CHECK(buffer != nullptr);
    const uint8_t pixels[3][3] = {{16, 16, 235}, {16, 235, 235}, {235, 235, 235}};
    for (int y = 0; y < 3; ++y) {
        std::memcpy(buffer->MutableDataY() + y * buffer->StrideY(), pixels[y], 3);
    }
    for (int y = 0; y < 2; ++y) {
        std::memset(buffer->MutableDataU() + y * buffer->StrideU(), 20, 2);
        std::memset(buffer->MutableDataV() + y * buffer->StrideV(), 230, 2);
    }
    const webrtc::ColorSpace limited(webrtc::ColorSpace::PrimaryID::kBT709,
        webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
        webrtc::ColorSpace::RangeID::kLimited);
    auto input = webrtc::VideoFrame::Builder()
        .set_video_frame_buffer(buffer).set_color_space(limited)
        .set_timestamp_us(13579).set_rtp_timestamp(24680)
        .set_rotation(webrtc::kVideoRotation_270).set_id(91)
        .set_update_rect(webrtc::VideoFrame::UpdateRect{1, 1, 1, 1}).build();
    webrtc::VideoFrame output = input;
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    uint64_t allocated = 999;
    DINOX_CHECK(Processor::apply_config(input, config, &output, &allocated));
    DINOX_CHECK(allocated == 0 && output.video_frame_buffer() == input.video_frame_buffer());
    DINOX_CHECK(output.update_rect().offset_x == 1 && output.update_rect().width == 1);

    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE;
    DINOX_CHECK(Processor::apply_config(input, config, &output, &allocated));
    auto converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataU()[0] == 28 && converted->DataV()[0] == 218);
    DINOX_CHECK(converted->DataY()[0] == 16);
    DINOX_CHECK(output.color_space().has_value() && *output.color_space() == limited);
    DINOX_CHECK(output.timestamp_us() == 13579 && output.rtp_timestamp() == 24680 &&
        output.rotation() == webrtc::kVideoRotation_270 && output.id() == 91);
    DINOX_CHECK(output.update_rect().width == 3 && output.update_rect().height == 3);
    buffer->MutableDataU()[0] = 255;
    buffer->MutableDataV()[0] = 0;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataU()[0] == 255 && converted->DataV()[0] == 0);

    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_SEPIA;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    // One white and three black pixels produce a quarter-strength tint;
    // the odd final row/column must use only existing pixels.
    DINOX_CHECK(converted->DataU()[0] == 124 && converted->DataV()[0] == 132);
    DINOX_CHECK(converted->DataU()[converted->StrideU() + 1] == 112 &&
        converted->DataV()[converted->StrideV() + 1] == 144);
    buffer->MutableDataY()[buffer->StrideY() + 1] = 16;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataU()[0] == 128 && converted->DataV()[0] == 128);

    const webrtc::ColorSpace full(webrtc::ColorSpace::PrimaryID::kBT709,
        webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
        webrtc::ColorSpace::RangeID::kFull);
    auto full_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(buffer)
        .set_color_space(full).build();
    DINOX_CHECK(Processor::apply_config(full_input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataU()[0] == 127 && converted->DataV()[0] == 129);
    DINOX_CHECK(output.color_space().has_value() && *output.color_space() == full);

    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    config.brightness = 50;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataY()[0] == 126 && converted->DataY()[2] == 235);
    DINOX_CHECK(Processor::apply_config(full_input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataY()[0] == 144 && converted->DataY()[2] == 255);

    config.brightness = 0;
    config.contrast = -100;
    config.saturation = 100;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataY()[0] == 126 && converted->DataY()[2] == 126 &&
        converted->DataU()[0] == 128 && converted->DataV()[0] == 128);
    DINOX_CHECK(Processor::apply_config(full_input, config, &output));
    DINOX_CHECK(output.video_frame_buffer()->ToI420()->DataY()[0] == 128);

    config.contrast = 0;
    config.saturation = -100;
    config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    buffer->MutableDataY()[0] = 0;
    buffer->MutableDataY()[2] = 255;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataY()[0] == 0 && converted->DataY()[2] == 255 &&
        converted->DataU()[0] == 128 && converted->DataV()[0] == 128);

    config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.sharpness = 100;
    for (int y = 0; y < 3; ++y) {
        std::memset(buffer->MutableDataY() + y * buffer->StrideY(), 100, 3);
    }
    buffer->MutableDataY()[buffer->StrideY() + 1] = 120;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    converted = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(converted->DataY()[converted->StrideY() + 1] == 140);
    DINOX_CHECK(converted->DataY()[1] == 95 && converted->DataY()[0] == 100);
    // Edge clamping repeats the source edge; no row wrapping or padding reads.
    buffer->MutableDataY()[buffer->StrideY() + 1] = 100;
    buffer->MutableDataY()[0] = 120;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    DINOX_CHECK(output.video_frame_buffer()->ToI420()->DataY()[0] == 130);
    config.brightness = 10;
    DINOX_CHECK(Processor::apply_config(input, config, &output));
    DINOX_CHECK(output.video_frame_buffer()->ToI420()->DataY()[0] == 152);
    DINOX_CHECK(buffer->DataY()[0] == 120);
    config.sharpness = 101;
    DINOX_CHECK(!Processor::apply_config(input, config, &output));
    return 0;
}

int check_chroma_identity_gain() {
    using Processor = dinox::webrtc_effects::VideoEffectProcessor;
    // Existing goldens establish each preset's pixels. These non-neutral
    // controls cancel only the chroma gain and must preserve those same U/V
    // pixels, including headroom, odd tails and independent padded strides.
    constexpr int width = 35, height = 3, cw = 18, ch = 2;
    constexpr std::array<uint8_t, 9> samples = {0, 1, 64, 127, 128, 129, 192, 254, 255};
    constexpr std::array<std::pair<int, int>, 4> cancelling = {{{25, -20},
        {-20, 25}, {100, -50}, {-50, 100}}};
    auto source = webrtc::I420Buffer::Create(width, height, 43, 23, 27);
    DINOX_CHECK(source != nullptr);
    std::memset(source->MutableDataY(), 0xa3, source->StrideY() * height);
    std::memset(source->MutableDataU(), 0xd7, source->StrideU() * ch);
    std::memset(source->MutableDataV(), 0xe9, source->StrideV() * ch);
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x)
            source->MutableDataY()[y * source->StrideY() + x] =
                samples[static_cast<size_t>(x + y * width) % samples.size()];
    for (int y = 0; y < ch; ++y)
        for (int x = 0; x < cw; ++x) {
            const size_t index = static_cast<size_t>(x + y * cw) % samples.size();
            source->MutableDataU()[y * source->StrideU() + x] = samples[index];
            source->MutableDataV()[y * source->StrideV() + x] = samples[samples.size() - 1 - index];
        }
    const std::vector<uint8_t> original_y(source->DataY(), source->DataY() + source->StrideY() * height);
    const std::vector<uint8_t> original_u(source->DataU(), source->DataU() + source->StrideU() * ch);
    const std::vector<uint8_t> original_v(source->DataV(), source->DataV() + source->StrideV() * ch);
    for (bool full_range : {false, true}) {
        const webrtc::ColorSpace space(webrtc::ColorSpace::PrimaryID::kBT709,
            webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
            full_range ? webrtc::ColorSpace::RangeID::kFull : webrtc::ColorSpace::RangeID::kLimited);
        const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(source)
            .set_color_space(space).build();
        for (int preset = 0; preset <= DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER; ++preset) {
            DinoXWebrtcVideoEffectConfig config = {};
            config.abi_version = DINOX_WEBRTC_ABI_VERSION;
            config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(preset);
            config.sharpness = 70;
            auto reference = input;
            DINOX_CHECK(Processor::apply_config(input, config, &reference));
            auto neutral = reference.video_frame_buffer()->ToI420();
            DINOX_CHECK(neutral != nullptr);
            if (preset == DINOX_WEBRTC_VIDEO_EFFECT_NONE)
                for (int y = 0; y < ch; ++y) {
                    DINOX_CHECK(std::memcmp(neutral->DataU() + y * neutral->StrideU(), source->DataU() + y * source->StrideU(), cw) == 0);
                    DINOX_CHECK(std::memcmp(neutral->DataV() + y * neutral->StrideV(), source->DataV() + y * source->StrideV(), cw) == 0);
                }
            for (const auto [contrast, saturation] : cancelling) {
                config.contrast = contrast;
                config.saturation = saturation;
                auto output = input;
                DINOX_CHECK(Processor::apply_config(input, config, &output));
                auto pixels = output.video_frame_buffer()->ToI420();
                DINOX_CHECK(pixels != nullptr && output.color_space().has_value() && *output.color_space() == space);
                for (int y = 0; y < ch; ++y) {
                    DINOX_CHECK(std::memcmp(pixels->DataU() + y * pixels->StrideU(), neutral->DataU() + y * neutral->StrideU(), cw) == 0);
                    DINOX_CHECK(std::memcmp(pixels->DataV() + y * pixels->StrideV(), neutral->DataV() + y * neutral->StrideV(), cw) == 0);
                }
            }
        }
        // A non-identity gain must retain the old adjustment path: source
        // U64/V192 becomes U32/V224 at +50% saturation, without clipping.
        DinoXWebrtcVideoEffectConfig adjusted = {};
        adjusted.abi_version = DINOX_WEBRTC_ABI_VERSION;
        adjusted.saturation = 50;
        auto output = input;
        DINOX_CHECK(Processor::apply_config(input, adjusted, &output));
        auto pixels = output.video_frame_buffer()->ToI420();
        DINOX_CHECK(pixels != nullptr && pixels->DataU()[2] == 32 && pixels->DataV()[2] == 224);
    }
    DINOX_CHECK(std::memcmp(source->DataY(), original_y.data(), original_y.size()) == 0);
    DINOX_CHECK(std::memcmp(source->DataU(), original_u.data(), original_u.size()) == 0);
    DINOX_CHECK(std::memcmp(source->DataV(), original_v.data(), original_v.size()) == 0);
    return 0;
}

int check_padded_processor_frames() {
    // Odd dimensions and distinct padded plane strides exercise both the
    // scalar chroma tail and the existing Warm SIMD path on x86.
    constexpr int width = 35;
    constexpr int height = 3;
    constexpr int chroma_width = 18;
    constexpr int chroma_height = 2;
    auto buffer = webrtc::I420Buffer::Create(width, height, 43, 23, 27);
    DINOX_CHECK(buffer != nullptr);
    std::memset(buffer->MutableDataY(), 0xa3, buffer->StrideY() * height);
    std::memset(buffer->MutableDataU(), 0xd7, buffer->StrideU() * chroma_height);
    std::memset(buffer->MutableDataV(), 0xe9, buffer->StrideV() * chroma_height);
    for (int y = 0; y < height; ++y) {
        std::memset(buffer->MutableDataY() + y * buffer->StrideY(), 110, width);
    }
    buffer->MutableDataY()[buffer->StrideY() + 17] = 130;
    for (int y = 0; y < chroma_height; ++y) {
        for (int x = 0; x < chroma_width; ++x) {
            buffer->MutableDataU()[y * buffer->StrideU() + x] = x % 2 == 0 ? 127 : 129;
            buffer->MutableDataV()[y * buffer->StrideV() + x] = x % 2 == 0 ? 129 : 127;
        }
        buffer->MutableDataU()[y * buffer->StrideU() + 17] = 0;
        buffer->MutableDataV()[y * buffer->StrideV() + 17] = 255;
    }
    const std::vector<uint8_t> original_y(buffer->DataY(),
        buffer->DataY() + buffer->StrideY() * height);
    const std::vector<uint8_t> original_u(buffer->DataU(),
        buffer->DataU() + buffer->StrideU() * chroma_height);
    const std::vector<uint8_t> original_v(buffer->DataV(),
        buffer->DataV() + buffer->StrideV() * chroma_height);
    const webrtc::ColorSpace full(webrtc::ColorSpace::PrimaryID::kBT709,
        webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
        webrtc::ColorSpace::RangeID::kFull);
    const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(buffer)
        .set_color_space(full).set_timestamp_us(246810).set_rtp_timestamp(13579)
        .set_ntp_time_ms(98765).set_rotation(webrtc::kVideoRotation_270).set_id(93)
        .set_update_rect(webrtc::VideoFrame::UpdateRect{1, 1, 2, 1}).build();
    std::mutex mutex;
    std::condition_variable changed;
    uint64_t applied_revision = 0;
    std::vector<webrtc::VideoFrame> outputs;
    auto processor = std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
        [&](const webrtc::VideoFrame& frame, uint64_t, uint64_t, uint64_t) {
            std::lock_guard<std::mutex> lock(mutex);
            outputs.push_back(frame);
            changed.notify_all();
        },
        [&](uint64_t revision, DinoXWebrtcVideoEffectType) {
            std::lock_guard<std::mutex> lock(mutex);
            applied_revision = revision;
            changed.notify_all();
        });
    struct ShutdownOnExit {
        std::shared_ptr<dinox::webrtc_effects::VideoEffectProcessor> processor;
        ~ShutdownOnExit() { processor->shutdown(); }
    } shutdown_on_exit{processor};
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.saturation = -50;
    config.sharpness = 100;
    for (uint64_t revision = 1; revision <= 2; ++revision) {
        if (revision == 2) {
            config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
            config.saturation = 0;
            config.sharpness = 0;
        }
        DINOX_CHECK(processor->enable_config(config, revision));
        {
            std::unique_lock<std::mutex> lock(mutex);
            DINOX_CHECK(changed.wait_for(lock, std::chrono::seconds(2), [&] {
                return applied_revision == revision;
            }));
        }
        DINOX_CHECK(processor->enqueue(input, revision, revision, 31));
        {
            std::unique_lock<std::mutex> lock(mutex);
            DINOX_CHECK(changed.wait_for(lock, std::chrono::seconds(2), [&] {
                return outputs.size() == revision;
            }));
            const auto& output = outputs.back();
            DINOX_CHECK(output.width() == width && output.height() == height &&
                output.timestamp_us() == 246810 && output.rtp_timestamp() == 13579 &&
                output.ntp_time_ms() == 98765 && output.rotation() == webrtc::kVideoRotation_270 &&
                output.id() == 93 && output.color_space().has_value() && *output.color_space() == full);
            DINOX_CHECK(output.update_rect().width == width && output.update_rect().height == height);
            auto pixels = output.video_frame_buffer()->ToI420();
            DINOX_CHECK(pixels != nullptr);
            for (int y = 0; y < height; ++y) {
                for (int x = 0; x < width; ++x) {
                    const bool center = y == 1 && x == 17;
                    const bool neighbour = (y == 1 && (x == 16 || x == 18)) ||
                        (x == 17 && (y == 0 || y == 2));
                    const int expected = revision == 1 ?
                        (center ? 150 : neighbour ? 105 : 110) : (center ? 130 : 110);
                    DINOX_CHECK(pixels->DataY()[y * pixels->StrideY() + x] == expected);
                }
            }
            for (int y = 0; y < chroma_height; ++y) {
                for (int x = 0; x < chroma_width; ++x) {
                    // Both -0.5 and +0.5 must round away from zero. The last
                    // sample also checks clipping in Warm's scalar tail.
                    const int expected_u = revision == 1 ?
                        (x == 17 ? 64 : x % 2 == 0 ? 127 : 129) :
                        (x == 17 ? 0 : x % 2 == 0 ? 119 : 121);
                    const int expected_v = revision == 1 ?
                        (x == 17 ? 192 : x % 2 == 0 ? 129 : 127) :
                        (x == 17 ? 255 : x % 2 == 0 ? 141 : 139);
                    DINOX_CHECK(pixels->DataU()[y * pixels->StrideU() + x] == expected_u);
                    DINOX_CHECK(pixels->DataV()[y * pixels->StrideV() + x] == expected_v);
                }
            }
        }
        // Check every input sample and padding sentinel after each real
        // executor pass; source writes or cross-row accesses must not hide.
        DINOX_CHECK(std::memcmp(buffer->DataY(), original_y.data(), original_y.size()) == 0);
        DINOX_CHECK(std::memcmp(buffer->DataU(), original_u.data(), original_u.size()) == 0);
        DINOX_CHECK(std::memcmp(buffer->DataV(), original_v.data(), original_v.size()) == 0);
        auto pixels = outputs.back().video_frame_buffer()->ToI420();
        const uint64_t frame_bytes = pixels->StrideY() * height +
            pixels->StrideU() * chroma_height + pixels->StrideV() * chroma_height;
        const auto diagnostics = processor->snapshot();
        // Holding both outputs forces two retained pool buffers. The scratch
        // belongs to the worker once and is released when Sharp becomes zero.
        DINOX_CHECK(diagnostics.effect_owned_allocated_bytes ==
            revision * frame_bytes + (revision == 1 ? 3 * width : 0));
    }
    return 0;
}

int check_cached_geometry_and_frosted_rows() {
    using Processor = dinox::webrtc_effects::VideoEffectProcessor;
    using Identity = dinox::webrtc_effects::FrameIdentity;
    std::mutex mutex;
    std::condition_variable changed;
    uint64_t applied = 0, revision = 0, received_id = 0, received_revision = 0, received_source = 0;
    std::optional<webrtc::VideoFrame> received;
    auto processor = std::make_shared<Processor>(
        [&](const webrtc::VideoFrame& frame, uint64_t id, uint64_t rev, uint64_t source) {
            std::lock_guard<std::mutex> lock(mutex);
            received = frame;
            received_id = id; received_revision = rev; received_source = source;
            changed.notify_all();
        },
        [&](uint64_t rev, DinoXWebrtcVideoEffectType) {
            std::lock_guard<std::mutex> lock(mutex);
            applied = rev;
            changed.notify_all();
        });
    struct ShutdownOnExit {
        std::shared_ptr<Processor> processor;
        ~ShutdownOnExit() { processor->shutdown(); }
    } shutdown_on_exit{processor};
    const auto enable = [&](DinoXWebrtcVideoEffectConfig config) -> int {
        ++revision;
        DINOX_CHECK(processor->enable_config(config, revision));
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(changed.wait_for(lock, std::chrono::seconds(2), [&] { return applied == revision; }));
        return 0;
    };
    int pool_width = 0, pool_height = 0;
    std::vector<const void*> pool_addresses;
    uint64_t frame_id = 0;
    Identity identity;
    identity.camera_lease = 7;
    identity.binding = {11, 4, 91, 0, 41, 0};
    uint64_t source_id = 91;
    const auto exercise = [&](int width, int height, bool full, DinoXWebrtcVideoEffectConfig config) -> int {
        const int cw = (width + 1) / 2, ch = (height + 1) / 2;
        const int padding = static_cast<int>(frame_id % 5);
        auto source = webrtc::I420Buffer::Create(width, height, width + 5 + padding, cw + 3 + padding, cw + 7 + padding);
        DINOX_CHECK(source != nullptr);
        std::memset(source->MutableDataY(), 0xa3, source->StrideY() * height);
        std::memset(source->MutableDataU(), 0xd7, source->StrideU() * ch);
        std::memset(source->MutableDataV(), 0xe9, source->StrideV() * ch);
        // Include all byte values, signed-rounding boundaries and fresh data
        // on every pass. Reusing geometry must never reuse pixels or strides.
        for (int y = 0; y < height; ++y)
            for (int x = 0; x < width; ++x)
                source->MutableDataY()[y * source->StrideY() + x] = static_cast<uint8_t>(x * 37 + y * 73 + frame_id * 19);
        for (int y = 0; y < ch; ++y)
            for (int x = 0; x < cw; ++x) {
                source->MutableDataU()[y * source->StrideU() + x] = static_cast<uint8_t>(x * 53 + y * 11 + frame_id * 29);
                source->MutableDataV()[y * source->StrideV() + x] = static_cast<uint8_t>(255 - x * 31 - y * 17 - frame_id * 13);
            }
        const std::vector<uint8_t> old_y(source->DataY(), source->DataY() + source->StrideY() * height);
        const std::vector<uint8_t> old_u(source->DataU(), source->DataU() + source->StrideU() * ch);
        const std::vector<uint8_t> old_v(source->DataV(), source->DataV() + source->StrideV() * ch);
        const webrtc::ColorSpace color(webrtc::ColorSpace::PrimaryID::kBT709,
            webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
            full ? webrtc::ColorSpace::RangeID::kFull : webrtc::ColorSpace::RangeID::kLimited);
        const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(source)
            .set_color_space(color).set_timestamp_us(123456 + frame_id).set_rtp_timestamp(9012 + frame_id)
            .set_ntp_time_ms(98765 + frame_id).set_rotation(webrtc::kVideoRotation_270).set_id(33)
            .set_update_rect(webrtc::VideoFrame::UpdateRect{0, 0, 1, 1}).build();
        auto reference = input;
        // apply_config deliberately keeps the uncached scalar mapping and
        // per-sample Frosted clamp/switch path: compare every production pixel
        // against the previous algorithm, not a second copy of the new cache.
        DINOX_CHECK(Processor::apply_config(input, config, &reference));
        DINOX_CHECK(enable(config) == 0);
        ++frame_id;
        auto frame_identity = identity;
        frame_identity.binding.config_revision = revision;
        frame_identity.frame.frame_id = frame_id;
        frame_identity.frame.captured_monotonic_ns = dinox::vision::VisionClient::monotonic_now_ns();
        frame_identity.frame.width = width; frame_identity.frame.height = height;
        frame_identity.frame.rotation = 270;
        DINOX_CHECK(processor->enqueue(input, frame_id, revision, source_id, frame_identity));
        auto result = input;
        {
            std::unique_lock<std::mutex> lock(mutex);
            DINOX_CHECK(changed.wait_for(lock, std::chrono::seconds(2), [&] { return received.has_value(); }));
            DINOX_CHECK(received_id == frame_id && received_revision == revision && received_source == source_id);
            result = *received;
            received.reset();
        }
        DINOX_CHECK(result.timestamp_us() == reference.timestamp_us() && result.rtp_timestamp() == reference.rtp_timestamp() &&
            result.ntp_time_ms() == reference.ntp_time_ms() && result.rotation() == reference.rotation() &&
            result.id() == reference.id() && result.color_space().has_value() && *result.color_space() == color);
        DINOX_CHECK(result.update_rect().offset_x == 0 && result.update_rect().offset_y == 0 &&
            result.update_rect().width == width && result.update_rect().height == height);
        auto actual = result.video_frame_buffer()->ToI420();
        auto expected = reference.video_frame_buffer()->ToI420();
        DINOX_CHECK(actual != nullptr && expected != nullptr);
        for (int y = 0; y < height; ++y)
            DINOX_CHECK(std::memcmp(actual->DataY() + y * actual->StrideY(), expected->DataY() + y * expected->StrideY(), width) == 0);
        for (int y = 0; y < ch; ++y) {
            DINOX_CHECK(std::memcmp(actual->DataU() + y * actual->StrideU(), expected->DataU() + y * expected->StrideU(), cw) == 0);
            DINOX_CHECK(std::memcmp(actual->DataV() + y * actual->StrideV(), expected->DataV() + y * expected->StrideV(), cw) == 0);
        }
        DINOX_CHECK(std::memcmp(source->DataY(), old_y.data(), old_y.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataU(), old_u.data(), old_u.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataV(), old_v.data(), old_v.size()) == 0);
        if (pool_width != width || pool_height != height) {
            pool_width = width; pool_height = height; pool_addresses.clear();
        }
        const void* address = result.video_frame_buffer().get();
        if (std::find(pool_addresses.begin(), pool_addresses.end(), address) == pool_addresses.end()) pool_addresses.push_back(address);
        DINOX_CHECK(pool_addresses.size() <= 3);
        const uint64_t frame_bytes = static_cast<uint64_t>(actual->StrideY()) * height +
            static_cast<uint64_t>(actual->StrideU()) * ch + static_cast<uint64_t>(actual->StrideV()) * ch;
        const uint64_t map_bytes = 4 * (static_cast<uint64_t>(width) * height + static_cast<uint64_t>(cw) * ch);
        const uint64_t geometry = config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE &&
            width <= 65535 && height <= 65535 && map_bytes <= 5 * 1024 * 1024 ? map_bytes : 0;
        const uint64_t scratch = config.sharpness != 0 && width <= 4096 ? 3 * width : 0;
        DINOX_CHECK(processor->snapshot().effect_owned_allocated_bytes ==
            pool_addresses.size() * frame_bytes + scratch + geometry);
        return 0;
    };
    struct Controls { int brightness, contrast, saturation, sharpness; };
    constexpr Controls controls[] = {{0,0,0,0}, {0,0,0,1}, {0,0,0,70}, {0,0,0,100},
        {-37,25,-20,70}, {31,-20,25,100}, {-100,-100,100,1}, {100,100,-100,70}};
    for (const auto [width, height] : {std::pair{1,1}, std::pair{1,17}, std::pair{17,1},
            std::pair{2,2}, std::pair{3,3}, std::pair{4,5}, std::pair{35,9}, std::pair{9,35}, std::pair{4097,1}})
        for (auto effect : {DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS, DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE})
            for (bool full : {false, true})
                for (const auto control : controls) {
                    DinoXWebrtcVideoEffectConfig config{}; config.abi_version = DINOX_WEBRTC_ABI_VERSION;
                    config.effect_type = effect; config.brightness = control.brightness; config.contrast = control.contrast;
                    config.saturation = control.saturation; config.sharpness = control.sharpness;
                    DINOX_CHECK(exercise(width, height, full, config) == 0);
                }
    DinoXWebrtcVideoEffectConfig fisheye{}; fisheye.abi_version = DINOX_WEBRTC_ABI_VERSION;
    fisheye.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE; fisheye.sharpness = 70;
    DINOX_CHECK(exercise(1280, 720, false, fisheye) == 0); // 4.608 MB, fits the bounded map
    fisheye.sharpness = 0;
    DINOX_CHECK(exercise(1025, 1025, true, fisheye) == 0); // just beyond 5 MiB: scalar fallback
    DINOX_CHECK(exercise(65536, 1, false, fisheye) == 0); // cannot pack 16-bit x, exact fallback
    DINOX_CHECK(exercise(35, 9, false, fisheye) == 0); // old oversized geometry is not retained
    ++source_id; ++identity.binding.publication_source_id;
    DINOX_CHECK(exercise(35, 9, true, fisheye) == 0);
    ++identity.camera_lease; ++identity.binding.source_generation;
    DINOX_CHECK(exercise(35, 9, false, fisheye) == 0);
    ++identity.binding.call_lease; ++identity.binding.transform_id;
    fisheye.sharpness = 70;
    DINOX_CHECK(exercise(35, 9, true, fisheye) == 0);
    const auto before_switch = processor->snapshot().effect_owned_allocated_bytes;
    DinoXWebrtcVideoEffectConfig warm{}; warm.abi_version = DINOX_WEBRTC_ABI_VERSION;
    warm.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
    DINOX_CHECK(enable(warm) == 0);
    // A mode change with no next camera frame must already release geometry.
    DINOX_CHECK(processor->snapshot().effect_owned_allocated_bytes == before_switch - 4 * (35 * 9 + 18 * 5));
    DINOX_CHECK(exercise(35, 9, false, warm) == 0);
    warm.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
    DINOX_CHECK(exercise(35, 9, true, warm) == 0);
    ++revision;
    DINOX_CHECK(processor->disable(revision));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(changed.wait_for(lock, std::chrono::seconds(2), [&] { return applied == revision; }));
    }
    const auto disabled = processor->snapshot();
    DINOX_CHECK(disabled.effect_owned_allocated_bytes == 0 &&
        disabled.effect_thread_count == 0 && disabled.effect_handle_count == 0);
    // Reactivation after Off gets a fresh worker/pool, then Stop releases all.
    pool_addresses.clear(); pool_width = pool_height = 0;
    DINOX_CHECK(exercise(35, 9, false, fisheye) == 0);
    processor->shutdown();
    DINOX_CHECK(processor->snapshot().effect_owned_allocated_bytes == 0);
    return 0;
}

int check_model_free_presets() {
    using Processor = dinox::webrtc_effects::VideoEffectProcessor;
    struct Pixel { uint8_t y; uint8_t u; uint8_t v; };
    // Fixed spec examples for source Y64/U127/V129: neutral limited/full,
    // then B+20/C-50/S+50/Sharp100 limited/full. A singleton has no unsharp
    // detail and must never sample the surrounding padding sentinels.
    constexpr Pixel expected[7][4] = {
        {{99,119,141}, {105,119,141}, {156,121,138}, {167,121,138}},
        {{67,127,129}, {68,127,129}, {140,127,129}, {149,127,129}},
        {{64,111,141}, {64,111,141}, {139,115,138}, {147,115,138}},
        {{64,127,129}, {64,127,129}, {139,127,129}, {147,127,129}},
        {{64,127,129}, {64,127,129}, {139,127,129}, {147,127,129}},
        {{63,127,129}, {63,127,129}, {138,127,129}, {146,127,129}},
        {{76,141,117}, {77,140,118}, {145,138,120}, {153,137,120}},
    };
    constexpr uint8_t negative_brightness_y[7][2] = {
        {42,43}, {16,0}, {16,0}, {16,0}, {16,0}, {16,0}, {16,1}};
    auto single = webrtc::I420Buffer::Create(1, 1, 7, 5, 9);
    DINOX_CHECK(single != nullptr);
    std::memset(single->MutableDataY(), 0xa3, 7);
    std::memset(single->MutableDataU(), 0xd7, 5);
    std::memset(single->MutableDataV(), 0xe9, 9);
    single->MutableDataY()[0] = 64;
    single->MutableDataU()[0] = 127;
    single->MutableDataV()[0] = 129;
    const std::vector<uint8_t> original_y(single->DataY(), single->DataY() + 7);
    const std::vector<uint8_t> original_u(single->DataU(), single->DataU() + 5);
    const std::vector<uint8_t> original_v(single->DataV(), single->DataV() + 9);
    for (int range = 0; range < 2; ++range) {
        const webrtc::ColorSpace space(webrtc::ColorSpace::PrimaryID::kBT709,
            webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
            range == 0 ? webrtc::ColorSpace::RangeID::kLimited : webrtc::ColorSpace::RangeID::kFull);
        const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(single)
            .set_color_space(space).set_timestamp_us(9876).set_rtp_timestamp(1234)
            .set_ntp_time_ms(5678).set_rotation(webrtc::kVideoRotation_90).set_id(95).build();
        for (int index = 0; index < 7; ++index) {
            for (int controls = 0; controls < 3; ++controls) {
                DinoXWebrtcVideoEffectConfig config = {};
                config.abi_version = DINOX_WEBRTC_ABI_VERSION;
                config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(5 + index);
                if (controls != 0) {
                    config.brightness = controls == 1 ? 20 : -20;
                    config.contrast = controls == 1 ? -50 : 50;
                    config.saturation = controls == 1 ? 50 : -50;
                    config.sharpness = 100;
                }
                auto output = input;
                uint64_t allocated = 0;
                DINOX_CHECK(Processor::apply_config(input, config, &output, &allocated));
                auto pixels = output.video_frame_buffer()->ToI420();
                DINOX_CHECK(pixels != nullptr && allocated > 0);
                const Pixel reference = expected[index][range + (controls == 0 ? 0 : 2)];
                DINOX_CHECK(pixels->DataY()[0] == (controls == 2 ?
                    negative_brightness_y[index][range] : reference.y));
                DINOX_CHECK(pixels->DataU()[0] == reference.u && pixels->DataV()[0] == reference.v);
                DINOX_CHECK(output.color_space().has_value() && *output.color_space() == space &&
                    output.timestamp_us() == 9876 && output.rtp_timestamp() == 1234 &&
                    output.ntp_time_ms() == 5678 && output.rotation() == webrtc::kVideoRotation_90 &&
                    output.id() == 95);
            }
        }
    }
    DINOX_CHECK(std::memcmp(single->DataY(), original_y.data(), original_y.size()) == 0);
    DINOX_CHECK(std::memcmp(single->DataU(), original_u.data(), original_u.size()) == 0);
    DINOX_CHECK(std::memcmp(single->DataV(), original_v.data(), original_v.size()) == 0);

    // A softened preset must feed sharpening's neighbours, rather than the
    // original input or partially written output. Check whole padded 3x3 Y.
    auto detail = webrtc::I420Buffer::Create(3, 3, 8, 5, 7);
    DINOX_CHECK(detail != nullptr);
    std::memset(detail->MutableDataY(), 0xa3, detail->StrideY() * 3);
    std::memset(detail->MutableDataU(), 128, detail->StrideU() * 2);
    std::memset(detail->MutableDataV(), 128, detail->StrideV() * 2);
    for (int y = 0; y < 3; ++y) {
        std::memset(detail->MutableDataY() + y * detail->StrideY(), 110, 3);
    }
    detail->MutableDataY()[detail->StrideY() + 1] = 130;
    const auto detail_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(detail).build();
    constexpr uint8_t dreamy_sharp[3][3] = {{111,116,111}, {116,130,116}, {111,116,111}};
    constexpr uint8_t frosted_sharp[3][3] = {{108,112,108}, {112,115,112}, {108,112,108}};
    for (auto preset : {DINOX_WEBRTC_VIDEO_EFFECT_DREAMY, DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS}) {
        DinoXWebrtcVideoEffectConfig config = {};
        config.abi_version = DINOX_WEBRTC_ABI_VERSION;
        config.effect_type = preset;
        config.sharpness = 100;
        auto output = detail_input;
        DINOX_CHECK(Processor::apply_config(detail_input, config, &output));
        auto pixels = output.video_frame_buffer()->ToI420();
        const auto& reference = preset == DINOX_WEBRTC_VIDEO_EFFECT_DREAMY ? dreamy_sharp : frosted_sharp;
        for (int y = 0; y < 3; ++y) {
            DINOX_CHECK(std::memcmp(pixels->DataY() + y * pixels->StrideY(), reference[y], 3) == 0);
        }
    }
    DINOX_CHECK(detail->DataY()[detail->StrideY() + 1] == 130);
    for (int y = 0; y < 3; ++y) {
        for (int x = 3; x < detail->StrideY(); ++x) {
            DINOX_CHECK(detail->DataY()[y * detail->StrideY() + x] == 0xa3);
        }
    }

    // At this rectangular top edge the circular lens moves (8,0) to (9,1).
    // An ellipse normalized independently per axis would keep (8,0).
    auto ramp = webrtc::I420Buffer::Create(33, 9, 39, 23, 27);
    DINOX_CHECK(ramp != nullptr);
    std::memset(ramp->MutableDataY(), 0xa3, ramp->StrideY() * 9);
    std::memset(ramp->MutableDataU(), 0xd7, ramp->StrideU() * 5);
    std::memset(ramp->MutableDataV(), 0xe9, ramp->StrideV() * 5);
    for (int y = 0; y < 9; ++y) {
        for (int x = 0; x < 33; ++x) ramp->MutableDataY()[y * ramp->StrideY() + x] = 8 * y + x;
    }
    for (int y = 0; y < 5; ++y) {
        for (int x = 0; x < 17; ++x) {
            ramp->MutableDataU()[y * ramp->StrideU() + x] = 20 + x + 8 * y;
            ramp->MutableDataV()[y * ramp->StrideV() + x] = 200 - x - 8 * y;
        }
    }
    auto ramp_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(ramp).build();
    DinoXWebrtcVideoEffectConfig fisheye = {};
    fisheye.abi_version = DINOX_WEBRTC_ABI_VERSION;
    fisheye.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE;
    auto ramp_output = ramp_input;
    DINOX_CHECK(Processor::apply_config(ramp_input, fisheye, &ramp_output));
    auto warped = ramp_output.video_frame_buffer()->ToI420();
    DINOX_CHECK(warped->DataY()[8] == 17 && warped->DataY()[0] == 0 && warped->DataY()[32] == 32);
    DINOX_CHECK(warped->DataY()[4 * warped->StrideY() + 16] == 48);
    DINOX_CHECK(warped->DataU()[4] == 25 && warped->DataV()[4] == 195);

    auto leak = webrtc::I420Buffer::Create(4, 12);
    DINOX_CHECK(leak != nullptr);
    std::memset(leak->MutableDataY(), 64, leak->StrideY() * 12);
    std::memset(leak->MutableDataU(), 128, leak->StrideU() * 6);
    std::memset(leak->MutableDataV(), 128, leak->StrideV() * 6);
    auto leak_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(leak).build();
    DinoXWebrtcVideoEffectConfig spatial = {};
    spatial.abi_version = DINOX_WEBRTC_ABI_VERSION;
    spatial.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK;
    auto leak_output = leak_input;
    DINOX_CHECK(Processor::apply_config(leak_input, spatial, &leak_output));
    auto leak_pixels = leak_output.video_frame_buffer()->ToI420();
    // m={256,86,233,63} has exact mean159.5. Rounding that mean to160
    // prematurely would paint V136 rather than the required V135.
    DINOX_CHECK(leak_pixels->DataU()[0] == 123 && leak_pixels->DataV()[0] == 135);

    auto duo = webrtc::I420Buffer::Create(2, 2);
    DINOX_CHECK(duo != nullptr);
    std::memset(duo->MutableDataY(), 16, duo->StrideY() * 2);
    duo->MutableDataY()[duo->StrideY() + 1] = 26;
    std::memset(duo->MutableDataU(), 128, duo->StrideU());
    std::memset(duo->MutableDataV(), 128, duo->StrideV());
    auto duo_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(duo).build();
    auto duo_output = duo_input;
    spatial.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE;
    DINOX_CHECK(Processor::apply_config(duo_input, spatial, &duo_output));
    auto duo_pixels = duo_output.video_frame_buffer()->ToI420();
    // meanY18.5 must stay rational; rounding it to19 changes the dark V.
    DINOX_CHECK(duo_pixels->DataU()[0] == 151 && duo_pixels->DataV()[0] == 108);

    auto prism = webrtc::I420Buffer::Create(8, 1);
    DINOX_CHECK(prism != nullptr);
    std::memset(prism->MutableDataY(), 64, prism->StrideY());
    std::memset(prism->MutableDataU(), 128, prism->StrideU());
    std::memset(prism->MutableDataV(), 128, prism->StrideV());
    auto prism_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(prism).build();
    auto prism_output = prism_input;
    spatial.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT;
    DINOX_CHECK(Processor::apply_config(prism_input, spatial, &prism_output));
    auto prism_pixels = prism_output.video_frame_buffer()->ToI420();
    constexpr uint8_t prism_u[4] = {112,120,144,136};
    constexpr uint8_t prism_v[4] = {140,116,120,144};
    DINOX_CHECK(std::memcmp(prism_pixels->DataU(), prism_u, 4) == 0 &&
        std::memcmp(prism_pixels->DataV(), prism_v, 4) == 0);

    auto tv = webrtc::I420Buffer::Create(1, 4);
    DINOX_CHECK(tv != nullptr);
    std::memset(tv->MutableDataY(), 64, tv->StrideY() * 4);
    std::memset(tv->MutableDataU(), 127, tv->StrideU() * 2);
    std::memset(tv->MutableDataV(), 129, tv->StrideV() * 2);
    auto tv_input = webrtc::VideoFrame::Builder().set_video_frame_buffer(tv).build();
    auto tv_output = tv_input;
    spatial.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV;
    DINOX_CHECK(Processor::apply_config(tv_input, spatial, &tv_output));
    auto tv_pixels = tv_output.video_frame_buffer()->ToI420();
    DINOX_CHECK(tv_pixels->DataY()[0] == 64 &&
        tv_pixels->DataY()[tv_pixels->StrideY()] == 64 &&
        tv_pixels->DataY()[2 * tv_pixels->StrideY()] == 53 &&
        tv_pixels->DataY()[3 * tv_pixels->StrideY()] == 53);

    // One-dimensional, odd padded and rectangular frames must all remain
    // bounded, immutable and usable with every new preset and signed controls.
    for (const auto dimensions : {std::pair{1,17}, std::pair{17,1}, std::pair{5,3}}) {
        const auto [width, height] = dimensions;
        const int cw = (width + 1) / 2;
        const int ch = (height + 1) / 2;
        auto source = webrtc::I420Buffer::Create(width, height, width + 5, cw + 3, cw + 7);
        DINOX_CHECK(source != nullptr);
        std::memset(source->MutableDataY(), 0xa3, source->StrideY() * height);
        std::memset(source->MutableDataU(), 0xd7, source->StrideU() * ch);
        std::memset(source->MutableDataV(), 0xe9, source->StrideV() * ch);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) source->MutableDataY()[y * source->StrideY() + x] = 32 + x + y;
        }
        for (int y = 0; y < ch; ++y) {
            std::memset(source->MutableDataU() + y * source->StrideU(), 96, cw);
            std::memset(source->MutableDataV() + y * source->StrideV(), 160, cw);
        }
        const std::vector<uint8_t> y_before(source->DataY(), source->DataY() + source->StrideY() * height);
        const std::vector<uint8_t> u_before(source->DataU(), source->DataU() + source->StrideU() * ch);
        const std::vector<uint8_t> v_before(source->DataV(), source->DataV() + source->StrideV() * ch);
        const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(source).build();
        for (int preset = 5; preset <= 11; ++preset) {
            DinoXWebrtcVideoEffectConfig config = {};
            config.abi_version = DINOX_WEBRTC_ABI_VERSION;
            config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(preset);
            config.brightness = -10;
            config.contrast = 20;
            config.saturation = -25;
            config.sharpness = 75;
            auto output = input;
            DINOX_CHECK(Processor::apply_config(input, config, &output));
            DINOX_CHECK(output.width() == width && output.height() == height &&
                output.update_rect().width == width && output.update_rect().height == height);
        }
        if (width == 1 || height == 1) {
            auto output = input;
            DINOX_CHECK(Processor::apply_config(input, fisheye, &output));
            auto pixels = output.video_frame_buffer()->ToI420();
            DINOX_CHECK(pixels->DataY()[width == 1 ? 4 * pixels->StrideY() : 4] == 37);
        }
        DINOX_CHECK(std::memcmp(source->DataY(), y_before.data(), y_before.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataU(), u_before.data(), u_before.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataV(), v_before.data(), v_before.size()) == 0);
    }
    fisheye.effect_type = static_cast<DinoXWebrtcVideoEffectType>(13);
    DINOX_CHECK(!Processor::apply_config(ramp_input, fisheye, &ramp_output));
    return 0;
}

int check_sharp_row_ring_equivalence() {
    using Processor = dinox::webrtc_effects::VideoEffectProcessor;
    // Existing native/Java goldens establish preset+BC math. Independently
    // apply the signed Laplacian to a complete Sharp0 reference image here:
    // this catches ring overwrites/edge mistakes without duplicating the ring
    // or the expensive preset implementation under test.
    constexpr std::array<std::array<int, 3>, 5> controls = {{{0,0,0},
        {20,-50,50}, {-20,50,-50}, {100,-100,100}, {-100,100,-100}}};
    uint32_t random_state = UINT32_C(0x7c913da5);
    const auto random_byte = [&]() {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return static_cast<uint8_t>(random_state);
    };
    for (const auto dimensions : {std::pair{1,1}, std::pair{1,7}, std::pair{7,1},
            std::pair{2,2}, std::pair{3,5}, std::pair{17,9}, std::pair{64,31},
            std::pair{4096,1}, std::pair{4097,1}}) {
        const auto [width, height] = dimensions;
        const int cw = (width + 1) / 2;
        const int ch = (height + 1) / 2;
        auto source = webrtc::I420Buffer::Create(width, height, width + 5, cw + 3, cw + 7);
        DINOX_CHECK(source != nullptr);
        std::memset(source->MutableDataY(), 0xa3, source->StrideY() * height);
        std::memset(source->MutableDataU(), 0xd7, source->StrideU() * ch);
        std::memset(source->MutableDataV(), 0xe9, source->StrideV() * ch);
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            source->MutableDataY()[y * source->StrideY() + x] = random_byte();
        }
        for (int y = 0; y < ch; ++y) for (int x = 0; x < cw; ++x) {
            source->MutableDataU()[y * source->StrideU() + x] = random_byte();
            source->MutableDataV()[y * source->StrideV() + x] = random_byte();
        }
        const std::vector<uint8_t> original_y(source->DataY(), source->DataY() + source->StrideY() * height);
        const std::vector<uint8_t> original_u(source->DataU(), source->DataU() + source->StrideU() * ch);
        const std::vector<uint8_t> original_v(source->DataV(), source->DataV() + source->StrideV() * ch);
        for (const auto range : {webrtc::ColorSpace::RangeID::kLimited, webrtc::ColorSpace::RangeID::kFull}) {
            const webrtc::ColorSpace color_space(webrtc::ColorSpace::PrimaryID::kBT709,
                webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709, range);
            const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(source)
                .set_color_space(color_space).set_timestamp_us(246810).set_rtp_timestamp(13579)
                .set_rotation(webrtc::kVideoRotation_270).set_id(93).build();
            for (int preset = 5; preset <= 11; ++preset) for (const auto& control : controls) {
                DinoXWebrtcVideoEffectConfig config = {};
                config.abi_version = DINOX_WEBRTC_ABI_VERSION;
                config.effect_type = static_cast<DinoXWebrtcVideoEffectType>(preset);
                config.brightness = control[0];
                config.contrast = control[1];
                config.saturation = control[2];
                auto reference = input;
                DINOX_CHECK(Processor::apply_config(input, config, &reference));
                auto reference_pixels = reference.video_frame_buffer()->ToI420();
                for (const int sharpness : {1,50,70,100}) {
                    config.sharpness = sharpness;
                    auto output = input;
                    DINOX_CHECK(Processor::apply_config(input, config, &output));
                    auto actual = output.video_frame_buffer()->ToI420();
                    DINOX_CHECK(output.timestamp_us() == input.timestamp_us() &&
                        output.rtp_timestamp() == input.rtp_timestamp() && output.id() == input.id() &&
                        output.rotation() == input.rotation() && output.color_space() == input.color_space());
                    const auto sample = [&](int x, int y) {
                        return reference_pixels->DataY()[std::clamp(y, 0, height - 1) *
                            reference_pixels->StrideY() + std::clamp(x, 0, width - 1)];
                    };
                    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                        const int center = sample(x, y);
                        const int numerator = sharpness * (4 * center - sample(x - 1, y) -
                            sample(x + 1, y) - sample(x, y - 1) - sample(x, y + 1));
                        const int detail = numerator < 0 ? -((-numerator + 200) / 400) :
                            (numerator + 200) / 400;
                        DINOX_CHECK(actual->DataY()[y * actual->StrideY() + x] ==
                            std::clamp(center + detail, 0, 255));
                    }
                    for (int y = 0; y < ch; ++y) {
                        DINOX_CHECK(std::memcmp(actual->DataU() + y * actual->StrideU(),
                            reference_pixels->DataU() + y * reference_pixels->StrideU(), cw) == 0);
                        DINOX_CHECK(std::memcmp(actual->DataV() + y * actual->StrideV(),
                            reference_pixels->DataV() + y * reference_pixels->StrideV(), cw) == 0);
                    }
                }
            }
        }
        DINOX_CHECK(std::memcmp(source->DataY(), original_y.data(), original_y.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataU(), original_u.data(), original_u.size()) == 0);
        DINOX_CHECK(std::memcmp(source->DataV(), original_v.data(), original_v.size()) == 0);
    }
    return 0;
}

int check_underwater_and_runtime() {
    using namespace dinox::webrtc_effects;
    auto buffer = webrtc::I420Buffer::Create(3, 3, 7, 5, 6);
    DINOX_CHECK(buffer != nullptr);
    std::memset(buffer->MutableDataY(), 0xa5, 21);
    std::memset(buffer->MutableDataU(), 0xa5, 10);
    std::memset(buffer->MutableDataV(), 0xa5, 12);
    const uint8_t y[9] = {16,60,125,200,235,17,255,100,0};
    const uint8_t u[4] = {100,150,200,50}, v[4] = {200,130,50,240};
    for (int row = 0; row < 3; ++row)
        std::memcpy(buffer->MutableDataY() + row * 7, y + row * 3, 3);
    for (int row = 0; row < 2; ++row) {
        std::memcpy(buffer->MutableDataU() + row * 5, u + row * 2, 2);
        std::memcpy(buffer->MutableDataV() + row * 6, v + row * 2, 2);
    }
    const std::vector<uint8_t> original_y(buffer->DataY(), buffer->DataY() + 21);
    const std::vector<uint8_t> original_u(buffer->DataU(), buffer->DataU() + 10);
    const std::vector<uint8_t> original_v(buffer->DataV(), buffer->DataV() + 12);
    DinoXWebrtcVideoEffectConfig config{}; config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    for (bool full_range : {false, true}) {
        config = {}; config.abi_version = DINOX_WEBRTC_ABI_VERSION;
        const webrtc::ColorSpace color(webrtc::ColorSpace::PrimaryID::kBT709,
            webrtc::ColorSpace::TransferID::kBT709, webrtc::ColorSpace::MatrixID::kBT709,
            full_range ? webrtc::ColorSpace::RangeID::kFull : webrtc::ColorSpace::RangeID::kLimited);
        const auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(buffer)
            .set_color_space(color).set_rotation(webrtc::kVideoRotation_90)
            .set_timestamp_us(123456).set_rtp_timestamp(9012).set_id(33).build();
        webrtc::VideoFrame output = input;
        config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER;
        DINOX_CHECK(VideoEffectProcessor::apply_config(input, config, &output));
        auto pixels = output.video_frame_buffer()->ToI420();
        const uint8_t expected_u[4] = {109,155,static_cast<uint8_t>(full_range ? 213 : 212),50};
        const uint8_t expected_v[4] = {192,126,39,240};
        for (int row = 0; row < 3; ++row)
            DINOX_CHECK(std::memcmp(pixels->DataY() + row * pixels->StrideY(), y + row * 3, 3) == 0);
        for (int row = 0; row < 2; ++row)
            for (int x = 0; x < 2; ++x) {
                DINOX_CHECK(pixels->DataU()[row * pixels->StrideU() + x] == expected_u[row * 2 + x]);
                DINOX_CHECK(pixels->DataV()[row * pixels->StrideV() + x] == expected_v[row * 2 + x]);
            }
        config.effect_type = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
        config.low_light = 0;
        VisionPaths unavailable; unavailable.segmentation = true;
        VideoRuntime runtime(unavailable);
        FrameIdentity identity; identity.frame.frame_id = 1;
        identity.frame.captured_monotonic_ns = dinox::vision::VisionClient::monotonic_now_ns();
        for (auto background : {DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR,
                DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID, DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE}) {
            config.background_mode = background;
            config.background_strength = background == DINOX_WEBRTC_VIDEO_BACKGROUND_BLUR ? 100 : 0;
            config.asset_id = background == DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE ? 1000 : 0;
            // Missing/stale inference and unstaged image must be opaque grey,
            // irrespective of the private source bytes, its odd strides or ROI.
            auto hidden = runtime.prepare(input, buffer, config, identity);
            DINOX_CHECK(hidden != nullptr && runtime.concealed() && runtime.mask_capture_ns() == 0);
            const int expected_y = background == DINOX_WEBRTC_VIDEO_BACKGROUND_SOLID ?
                (full_range ? 0 : 16) : (full_range ? 48 : 57);
            for (int row = 0; row < 3; ++row)
                for (int x = 0; x < 3; ++x)
                    DINOX_CHECK(hidden->DataY()[row * hidden->StrideY() + x] == expected_y);
            for (int row = 0; row < 2; ++row)
                for (int x = 0; x < 2; ++x)
                    DINOX_CHECK(hidden->DataU()[row * hidden->StrideU() + x] == 128 &&
                        hidden->DataV()[row * hidden->StrideV() + x] == 128);
            DINOX_CHECK(runtime.owned_bytes() <= 64);
        }
        runtime.release_workspace();
        DINOX_CHECK(runtime.owned_bytes() == 0);
        config = {}; config.abi_version = DINOX_WEBRTC_ABI_VERSION;
        config.glasses_style = 3;
        DINOX_CHECK(!VideoEffectProcessor::apply_config(input, config, &output));
        config.glasses_style = 0; config.scene_effect = 4;
        DINOX_CHECK(VideoEffectProcessor::apply_config(input, config, &output));
        DINOX_CHECK(output.timestamp_us() == 123456 && output.rtp_timestamp() == 9012 &&
            output.rotation() == webrtc::kVideoRotation_90 && output.id() == 33 &&
            output.color_space() && *output.color_space() == color);
    }
    DINOX_CHECK(std::memcmp(buffer->DataY(), original_y.data(), original_y.size()) == 0);
    DINOX_CHECK(std::memcmp(buffer->DataU(), original_u.data(), original_u.size()) == 0);
    DINOX_CHECK(std::memcmp(buffer->DataV(), original_v.data(), original_v.size()) == 0);
    auto dark = webrtc::I420Buffer::Create(1, 1);
    dark->MutableDataY()[0] = 64; dark->MutableDataU()[0] = dark->MutableDataV()[0] = 128;
    config = {}; config.abi_version = DINOX_WEBRTC_ABI_VERSION; config.low_light = 1;
    auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(dark).build();
    webrtc::VideoFrame output = input;
    DINOX_CHECK(VideoEffectProcessor::apply_config(input, config, &output));
    DINOX_CHECK(output.video_frame_buffer()->ToI420()->DataY()[0] == 79 && dark->DataY()[0] == 64);
    return 0;
}

int check_watchdog_retained_assets() {
    using namespace dinox::webrtc_effects;
    auto runtime=std::make_shared<VideoRuntime>(VisionPaths{});
    const auto staged=runtime->background_builtin(dinox::video_background_images::Builtin::Office);
    DINOX_CHECK(staged.status==dinox::video_background_images::Status::Ok);
    DINOX_CHECK(runtime->background_prepare(staged.id)==dinox::video_background_images::Status::Ok);
    const auto retained=runtime->owned_bytes();DINOX_CHECK(retained>0);
    std::mutex mutex;std::condition_variable changed;bool applied=false;
    auto processor=std::make_shared<VideoEffectProcessor>(VideoEffectProcessor::OutputCallback{},
        [&](uint64_t,DinoXWebrtcVideoEffectType){std::lock_guard lock(mutex);applied=true;changed.notify_all();},
        900000,VideoEffectProcessor::DegradedCallback{},runtime);
    DINOX_CHECK(processor->enable_effect(DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE,1));
    {std::unique_lock lock(mutex);DINOX_CHECK(changed.wait_for(lock,std::chrono::seconds(2),[&]{return applied;}));}
    auto buffer=webrtc::I420Buffer::Create(3,3);
    std::memset(buffer->MutableDataY(),16,9);std::memset(buffer->MutableDataU(),128,4);std::memset(buffer->MutableDataV(),128,4);
    const auto frame=webrtc::VideoFrame::Builder().set_video_frame_buffer(buffer).build();
    DINOX_CHECK(processor->enqueue(frame,1,1,1));
    bool degraded=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    while(!degraded&&std::chrono::steady_clock::now()<deadline){
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        degraded=processor->degrade_if_stalled(frame,2,1,1);
    }
    DINOX_CHECK(degraded);
    const auto diagnostic=processor->snapshot();
    DINOX_CHECK(diagnostic.effect_thread_count==0&&diagnostic.effect_handle_count==0&&
        diagnostic.effect_owned_allocated_bytes==retained);
    processor->shutdown(); // bounded wait, staged assets remain owned separately
    DINOX_CHECK(processor->snapshot().effect_owned_allocated_bytes==retained);
    DINOX_CHECK(runtime->background_release(staged.id)==dinox::video_background_images::Status::Ok);
    DINOX_CHECK(processor->snapshot().effect_owned_allocated_bytes==0);
    return 0;
}

int check_background_runtime_format_recovery() {
    using namespace dinox::webrtc_effects;
    namespace bg=dinox::video_background_images;
    VideoRuntime runtime(VisionPaths{});
    const std::array<uint8_t,3> red{255,0,0},blue{0,0,255};
    const auto a=runtime.background_upload({1,1,3,bg::PixelFormat::Rgb888,red});
    DINOX_CHECK(a.status==bg::Status::Ok&&runtime.background_prepare(a.id)==bg::Status::Ok);
    runtime.select_background(a.id);
    const auto b=runtime.background_upload({1,1,3,bg::PixelFormat::Rgb888,blue});
    DINOX_CHECK(b.status==bg::Status::Ok&&runtime.background_prepare(b.id)==bg::Status::Ok);
    DINOX_CHECK(runtime.transport_owned_bytes()==12);
    auto pixels=webrtc::I420Buffer::Create(3,3,7,5,6);DINOX_CHECK(pixels);
    std::memset(pixels->MutableDataY(),202,21);std::memset(pixels->MutableDataU(),17,10);
    std::memset(pixels->MutableDataV(),245,12);
    DinoXWebrtcVideoEffectConfig config{};config.abi_version=DINOX_WEBRTC_ABI_VERSION;
    config.background_mode=DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGE;config.asset_id=a.id;
    FrameIdentity identity;identity.camera_lease=1;identity.binding={1,1,1,1,1,0};
    identity.frame.width=identity.frame.height=3;
    // This tests the actual staging/format APIs independently of inference:
    // no demand/model/process, and every maskless frame must remain concealed.
    const std::array<std::pair<bool,bool>,3> formats{{{true,true},{false,true},{true,false}}};
    for(const auto& [full_range,bt709]:formats){
        identity.full_range=full_range;identity.bt709=bt709;++identity.binding.transform_id;
        ++identity.frame.frame_id;
        identity.frame.captured_monotonic_ns=dinox::vision::VisionClient::monotonic_now_ns();
        runtime.bind(identity);
        DINOX_CHECK(runtime.transport_owned_bytes()==9); // old A variant owner released; B untouched
        const webrtc::ColorSpace color(webrtc::ColorSpace::PrimaryID::kBT709,
            webrtc::ColorSpace::TransferID::kBT709,
            bt709?webrtc::ColorSpace::MatrixID::kBT709:webrtc::ColorSpace::MatrixID::kSMPTE170M,
            full_range?webrtc::ColorSpace::RangeID::kFull:webrtc::ColorSpace::RangeID::kLimited);
        const auto frame=webrtc::VideoFrame::Builder().set_video_frame_buffer(pixels).set_color_space(color).build();
        auto concealed=runtime.prepare(frame,pixels,config,identity);
        DINOX_CHECK(concealed&&runtime.concealed()&&runtime.mask_capture_ns()==0);
        for(int y=0;y<3;++y)for(int x=0;x<3;++x)
            DINOX_CHECK(concealed->DataY()[y*concealed->StrideY()+x]==(full_range?48:57));
        bg::Status prepared=bg::Status::Unavailable;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(1);
        do{
            prepared=runtime.background_prepare(a.id);
            if(prepared!=bg::Status::Ok)std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }while(prepared!=bg::Status::Ok&&std::chrono::steady_clock::now()<deadline);
        DINOX_CHECK(prepared==bg::Status::Ok&&runtime.background_contains(a.id)&&runtime.background_contains(b.id));
        DINOX_CHECK(runtime.transport_owned_bytes()==12); // two1-pixel RGB sources + two I420 variants
        for(size_t i=0;i<21;++i)DINOX_CHECK(pixels->DataY()[i]==202);
        for(size_t i=0;i<10;++i)DINOX_CHECK(pixels->DataU()[i]==17);
        for(size_t i=0;i<12;++i)DINOX_CHECK(pixels->DataV()[i]==245);
    }
    DINOX_CHECK(runtime.background_release(b.id)==bg::Status::Ok&&runtime.background_contains(a.id));
    DINOX_CHECK(runtime.transport_owned_bytes()==6);
    DINOX_CHECK(runtime.background_release(a.id)==bg::Status::Ok);
    const auto released_deadline=std::chrono::steady_clock::now()+std::chrono::seconds(1);
    while(runtime.transport_owned_bytes()!=0&&std::chrono::steady_clock::now()<released_deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    DINOX_CHECK(runtime.transport_owned_bytes()==0); // last asynchronous conversion reader has retired
    return 0;
}

int main() {
    DINOX_CHECK(check_extended_filters() == 0);
    DINOX_CHECK(check_chroma_identity_gain() == 0);
    DINOX_CHECK(check_padded_processor_frames() == 0);
    DINOX_CHECK(check_cached_geometry_and_frosted_rows() == 0);
    DINOX_CHECK(check_model_free_presets() == 0);
    DINOX_CHECK(check_sharp_row_ring_equivalence() == 0);
    DINOX_CHECK(check_underwater_and_runtime() == 0);
    DINOX_CHECK(check_watchdog_retained_assets() == 0);
    DINOX_CHECK(check_background_runtime_format_recovery() == 0);
    auto input_buffer = webrtc::I420Buffer::Create(4, 4);
    DINOX_CHECK(input_buffer != nullptr);
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            input_buffer->MutableDataY()[row * input_buffer->StrideY() + column] =
                static_cast<uint8_t>(16 + row * 4 + column);
        }
    }
    std::memset(input_buffer->MutableDataU(), 20, input_buffer->StrideU() * 2);
    std::memset(input_buffer->MutableDataV(), 230, input_buffer->StrideV() * 2);
    webrtc::VideoFrame input = webrtc::VideoFrame::Builder()
        .set_video_frame_buffer(input_buffer)
        .set_timestamp_us(123456)
        .set_rtp_timestamp(9000)
        .set_rotation(webrtc::kVideoRotation_90)
        .set_id(77)
        .set_update_rect(webrtc::VideoFrame::UpdateRect{1, 1, 2, 2})
        .build();
    webrtc::VideoFrame output = input;
    uint64_t allocated = 0;
    DINOX_CHECK(dinox::webrtc_effects::VideoEffectProcessor::apply_grayscale(
        input, &output, &allocated));
    DINOX_CHECK(allocated > 0);
    DINOX_CHECK(output.timestamp_us() == 123456);
    DINOX_CHECK(output.rtp_timestamp() == 9000);
    DINOX_CHECK(output.rotation() == webrtc::kVideoRotation_90);
    DINOX_CHECK(output.id() == 77);
    DINOX_CHECK(output.update_rect().offset_x == 0 && output.update_rect().offset_y == 0);
    DINOX_CHECK(output.update_rect().width == 4 && output.update_rect().height == 4);
    auto grayscale = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(grayscale != nullptr);
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            DINOX_CHECK(grayscale->DataY()[row * grayscale->StrideY() + column] ==
                input_buffer->DataY()[row * input_buffer->StrideY() + column]);
        }
    }
    for (int row = 0; row < 2; ++row) {
        for (int column = 0; column < 2; ++column) {
            DINOX_CHECK(grayscale->DataU()[row * grayscale->StrideU() + column] == 128);
            DINOX_CHECK(grayscale->DataV()[row * grayscale->StrideV() + column] == 128);
        }
    }

    output = input;
    allocated = 0;
    DINOX_CHECK(dinox::webrtc_effects::VideoEffectProcessor::apply_warm_tone(
        input, &output, &allocated));
    DINOX_CHECK(allocated > 0);
    DINOX_CHECK(output.timestamp_us() == 123456);
    DINOX_CHECK(output.rtp_timestamp() == 9000);
    DINOX_CHECK(output.rotation() == webrtc::kVideoRotation_90);
    DINOX_CHECK(output.id() == 77);
    DINOX_CHECK(output.update_rect().offset_x == 0 && output.update_rect().offset_y == 0);
    DINOX_CHECK(output.update_rect().width == 4 && output.update_rect().height == 4);
    auto warm_tone = output.video_frame_buffer()->ToI420();
    DINOX_CHECK(warm_tone != nullptr);
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            DINOX_CHECK(warm_tone->DataY()[row * warm_tone->StrideY() + column] ==
                input_buffer->DataY()[row * input_buffer->StrideY() + column]);
        }
    }
    for (int row = 0; row < 2; ++row) {
        for (int column = 0; column < 2; ++column) {
            DINOX_CHECK(warm_tone->DataU()[row * warm_tone->StrideU() + column] == 12);
            DINOX_CHECK(warm_tone->DataV()[row * warm_tone->StrideV() + column] == 242);
        }
    }

    auto clamp_buffer = webrtc::I420Buffer::Create(4, 4);
    DINOX_CHECK(clamp_buffer != nullptr);
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            clamp_buffer->MutableDataY()[row * clamp_buffer->StrideY() + column] =
                static_cast<uint8_t>(32 + row * 4 + column);
        }
    }
    const uint8_t clamp_u[] = {0, 7, 8, 255};
    const uint8_t clamp_v[] = {0, 243, 244, 255};
    for (int row = 0; row < 2; ++row) {
        for (int column = 0; column < 2; ++column) {
            const int index = row * 2 + column;
            clamp_buffer->MutableDataU()[row * clamp_buffer->StrideU() + column] =
                clamp_u[index];
            clamp_buffer->MutableDataV()[row * clamp_buffer->StrideV() + column] =
                clamp_v[index];
        }
    }
    webrtc::VideoFrame clamp_input = webrtc::VideoFrame::Builder()
        .set_video_frame_buffer(clamp_buffer)
        .set_timestamp_us(654321)
        .build();
    webrtc::VideoFrame clamp_output = clamp_input;
    DINOX_CHECK(dinox::webrtc_effects::VideoEffectProcessor::apply_warm_tone(
        clamp_input, &clamp_output));
    auto clamped = clamp_output.video_frame_buffer()->ToI420();
    DINOX_CHECK(clamped != nullptr);
    const uint8_t expected_u[] = {0, 0, 0, 247};
    const uint8_t expected_v[] = {12, 255, 255, 255};
    for (int row = 0; row < 2; ++row) {
        for (int column = 0; column < 2; ++column) {
            const int index = row * 2 + column;
            DINOX_CHECK(clamped->DataU()[row * clamped->StrideU() + column] ==
                expected_u[index]);
            DINOX_CHECK(clamped->DataV()[row * clamped->StrideV() + column] ==
                expected_v[index]);
        }
    }

    std::mutex mutex;
    std::condition_variable condition;
    uint64_t last_frame_id = 0;
    uint64_t last_applied_revision = 0;
    DinoXWebrtcVideoEffectType last_applied_effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    auto processor = std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
        [&](const webrtc::VideoFrame&, uint64_t frame_id, uint64_t, uint64_t) {
            std::lock_guard<std::mutex> lock(mutex);
            last_frame_id = frame_id;
            condition.notify_all();
        },
        [&](uint64_t revision, DinoXWebrtcVideoEffectType effect) {
            std::lock_guard<std::mutex> lock(mutex);
            last_applied_revision = revision;
            last_applied_effect = effect;
            condition.notify_all();
        },
        5000);
    DINOX_CHECK(processor->snapshot().effect_thread_count == 0);
    DINOX_CHECK(processor->enable_effect(DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 1));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return last_applied_revision == 1 &&
                last_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
        }));
    }
    for (uint64_t frame_id = 1; frame_id <= 100; ++frame_id) {
        DINOX_CHECK(processor->enqueue(input, frame_id, 1, 7));
    }
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return last_frame_id == 100;
        }));
    }
    auto active = processor->snapshot();
    DINOX_CHECK(active.captured == 100);
    DINOX_CHECK(active.enqueued == 100);
    DINOX_CHECK(active.processed > 0 && active.processed <= 100);
    DINOX_CHECK(active.queue_replaced > 0);
    DINOX_CHECK(active.frame_copy_count == active.processed);
    DINOX_CHECK(active.effect_thread_count == 1);
    DINOX_CHECK(processor->enqueue(input, 101, 1, 7));
    DINOX_CHECK(processor->disable(2));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return last_applied_revision == 2 &&
                last_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_NONE;
        }));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    {
        std::lock_guard<std::mutex> lock(mutex);
        DINOX_CHECK(last_frame_id == 100);
    }
    DINOX_CHECK(!processor->enqueue(input, 102, 2, 7));
    const auto after_off = processor->snapshot();
    DINOX_CHECK(after_off.captured >= active.captured);
    DINOX_CHECK(after_off.enqueued >= active.enqueued);
    DINOX_CHECK(after_off.processed == active.processed);
    DINOX_CHECK(after_off.frame_copy_count == active.frame_copy_count);
    DINOX_CHECK(after_off.effect_thread_count == 0);
    DINOX_CHECK(after_off.effect_handle_count == 0);
    DINOX_CHECK(after_off.effect_owned_allocated_bytes == 0);
    processor->shutdown();

    // Switching between effects keeps the same bounded executor alive. A
    // frame already queued or being processed for an older revision must not
    // be published after the new effect has been accepted.
    struct SwitchOutput {
        uint64_t frame_id = 0;
        uint64_t revision = 0;
        uint8_t u = 0;
        uint8_t v = 0;
    };
    std::vector<SwitchOutput> switch_outputs;
    uint64_t switch_applied_revision = 0;
    DinoXWebrtcVideoEffectType switch_applied_effect =
        DINOX_WEBRTC_VIDEO_EFFECT_NONE;
    auto switch_processor =
        std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            [&](const webrtc::VideoFrame& frame, uint64_t frame_id,
                    uint64_t revision, uint64_t) {
                auto converted = frame.video_frame_buffer()->ToI420();
                std::lock_guard<std::mutex> lock(mutex);
                if (converted != nullptr) {
                    switch_outputs.push_back(SwitchOutput{
                        frame_id,
                        revision,
                        converted->DataU()[0],
                        converted->DataV()[0]});
                }
                condition.notify_all();
            },
            [&](uint64_t revision, DinoXWebrtcVideoEffectType effect) {
                std::lock_guard<std::mutex> lock(mutex);
                switch_applied_revision = revision;
                switch_applied_effect = effect;
                condition.notify_all();
            },
            100000);
    DINOX_CHECK(!switch_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_NONE, 20));
    DINOX_CHECK(!switch_processor->enable_effect(
        static_cast<DinoXWebrtcVideoEffectType>(99), 20));
    DINOX_CHECK(switch_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 20));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 20 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
        }));
    }
    DINOX_CHECK(switch_processor->enqueue(input, 201, 20, 13));
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    DINOX_CHECK(switch_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE, 21));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 21 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE;
        }));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(70));
    {
        std::lock_guard<std::mutex> lock(mutex);
        DINOX_CHECK(switch_outputs.empty());
    }
    DINOX_CHECK(switch_processor->enqueue(input, 202, 21, 13));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return !switch_outputs.empty() && switch_outputs.back().frame_id == 202;
        }));
        DINOX_CHECK(switch_outputs.back().revision == 21);
        DINOX_CHECK(switch_outputs.back().u == 12);
        DINOX_CHECK(switch_outputs.back().v == 242);
    }
    auto switch_active = switch_processor->snapshot();
    DINOX_CHECK(switch_active.effect_thread_count == 1);
    DINOX_CHECK(switch_active.effect_handle_count == 1);

    DINOX_CHECK(switch_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 22));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 22 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
        }));
    }
    DINOX_CHECK(switch_processor->snapshot().effect_thread_count == 1);
    DINOX_CHECK(switch_processor->enqueue(input, 203, 22, 13));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return !switch_outputs.empty() && switch_outputs.back().frame_id == 203;
        }));
        DINOX_CHECK(switch_outputs.back().revision == 22);
        DINOX_CHECK(switch_outputs.back().u == 128);
        DINOX_CHECK(switch_outputs.back().v == 128);
        switch_outputs.clear();
    }

    // One hundred rapid Gray/Warm transitions must remain on this one
    // processor. The artificial conversion delay keeps the first submitted
    // revision in flight while every newer revision replaces the mailbox; only
    // the final revision may publish a frame.
    for (uint64_t index = 0; index < 100; ++index) {
        const uint64_t rapid_revision = 23 + index;
        const DinoXWebrtcVideoEffectType rapid_effect = index % 2 == 0
            ? DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE
            : DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE;
        DINOX_CHECK(switch_processor->enable_effect(rapid_effect, rapid_revision));
        DINOX_CHECK(switch_processor->enqueue(
            input, 300 + index, rapid_revision, 13));
    }
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 122 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE &&
                switch_outputs.size() == 1 && switch_outputs[0].frame_id == 399;
        }));
        DINOX_CHECK(switch_outputs[0].revision == 122);
        DINOX_CHECK(switch_outputs[0].u == 128);
        DINOX_CHECK(switch_outputs[0].v == 128);
    }
    const auto rapid_switch_active = switch_processor->snapshot();
    DINOX_CHECK(rapid_switch_active.effect_thread_count == 1);
    DINOX_CHECK(rapid_switch_active.effect_handle_count == 1);

    // Keep the preset unchanged while rapidly changing its full configuration.
    // Caller-side mutations after enqueue must not alter the newest snapshot.
    {
        std::lock_guard<std::mutex> lock(mutex);
        switch_outputs.clear();
    }
    DinoXWebrtcVideoEffectConfig adjusted = {};
    adjusted.abi_version = DINOX_WEBRTC_ABI_VERSION;
    for (uint64_t index = 0; index < 100; ++index) {
        adjusted.saturation = static_cast<int32_t>(index) - 100;
        DINOX_CHECK(switch_processor->enable_config(adjusted, 123 + index));
        DINOX_CHECK(switch_processor->enqueue(input, 500 + index, 123 + index, 13));
    }
    adjusted.saturation = 100;
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 222 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_NONE &&
                switch_outputs.size() == 1 && switch_outputs[0].frame_id == 599;
        }));
        DINOX_CHECK(switch_outputs[0].revision == 222 &&
            switch_outputs[0].u == 21 && switch_outputs[0].v == 229);
    }
    DINOX_CHECK(switch_processor->snapshot().effect_thread_count == 1);
    DINOX_CHECK(switch_processor->disable(223));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return switch_applied_revision == 223 &&
                switch_applied_effect == DINOX_WEBRTC_VIDEO_EFFECT_NONE;
        }));
    }
    const auto switch_off = switch_processor->snapshot();
    DINOX_CHECK(switch_off.effect_thread_count == 0);
    DINOX_CHECK(switch_off.effect_handle_count == 0);
    DINOX_CHECK(switch_off.effect_owned_allocated_bytes == 0);
    switch_processor->shutdown();

    uint64_t teardown_output_count = 0;
    uint64_t teardown_applied_revision = 0;
    auto teardown_processor =
        std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            [&](const webrtc::VideoFrame&, uint64_t, uint64_t, uint64_t) {
                std::lock_guard<std::mutex> lock(mutex);
                teardown_output_count++;
                condition.notify_all();
            },
            [&](uint64_t revision, DinoXWebrtcVideoEffectType) {
                std::lock_guard<std::mutex> lock(mutex);
                teardown_applied_revision = revision;
                condition.notify_all();
            },
            20000);
    DINOX_CHECK(teardown_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 3));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return teardown_applied_revision == 3;
        }));
    }
    DINOX_CHECK(teardown_processor->enqueue(input, 1, 3, 9));
    teardown_processor->shutdown();
    uint64_t outputs_after_shutdown = 0;
    {
        std::lock_guard<std::mutex> lock(mutex);
        outputs_after_shutdown = teardown_output_count;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    {
        std::lock_guard<std::mutex> lock(mutex);
        DINOX_CHECK(teardown_output_count == outputs_after_shutdown);
    }

    // Retaining all bounded pool buffers must drop a frame instead of leaking
    // one unprocessed colour frame through an active grayscale pipeline. Once
    // a retained buffer is released, the next frame is processed normally.
    std::vector<webrtc::VideoFrame> retained_frames;
    uint64_t pool_applied_revision = 0;
    auto bounded_processor =
        std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            [&](const webrtc::VideoFrame& frame, uint64_t, uint64_t, uint64_t) {
                std::lock_guard<std::mutex> lock(mutex);
                retained_frames.push_back(frame);
                condition.notify_all();
            },
            [&](uint64_t revision, DinoXWebrtcVideoEffectType) {
                std::lock_guard<std::mutex> lock(mutex);
                pool_applied_revision = revision;
                condition.notify_all();
            });
    DINOX_CHECK(bounded_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 4));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return pool_applied_revision == 4;
        }));
    }
    for (uint64_t frame_id = 1; frame_id <= 3; ++frame_id) {
        DINOX_CHECK(bounded_processor->enqueue(input, frame_id, 4, 10));
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return retained_frames.size() == frame_id;
        }));
    }
    DINOX_CHECK(bounded_processor->enqueue(input, 4, 4, 10));
    bool observed_bounded_drop = false;
    for (unsigned int attempt = 0; attempt < 200; ++attempt) {
        auto diagnostics = bounded_processor->snapshot();
        if (diagnostics.failed == 1 && diagnostics.bypassed == 1) {
            observed_bounded_drop = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    DINOX_CHECK(observed_bounded_drop);
    {
        std::lock_guard<std::mutex> lock(mutex);
        DINOX_CHECK(retained_frames.size() == 3);
        retained_frames.clear();
    }
    DINOX_CHECK(bounded_processor->enqueue(input, 5, 4, 10));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return retained_frames.size() == 1;
        }));
    }
    bounded_processor->shutdown();

    // A frame that cannot finish within 500 ms trips the circuit breaker once.
    // That same raw frame is released, while later frames bypass the processor
    // entirely because enqueue rejects the degraded revision.
    uint64_t watchdog_applied_revision = 0;
    uint64_t watchdog_frame_id = 0;
    uint64_t watchdog_output_count = 0;
    uint64_t watchdog_degraded_count = 0;
    bool watchdog_frame_was_raw = false;
    auto watchdog_processor =
        std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            [&](const webrtc::VideoFrame&, uint64_t, uint64_t, uint64_t) {
                std::lock_guard<std::mutex> lock(mutex);
                watchdog_output_count++;
                condition.notify_all();
            },
            [&](uint64_t revision, DinoXWebrtcVideoEffectType) {
                std::lock_guard<std::mutex> lock(mutex);
                watchdog_applied_revision = revision;
                condition.notify_all();
            },
            900000,
            [&](const webrtc::VideoFrame& frame, uint64_t frame_id,
                    uint64_t, uint64_t) {
                auto raw = frame.video_frame_buffer()->ToI420();
                std::lock_guard<std::mutex> lock(mutex);
                watchdog_frame_id = frame_id;
                watchdog_frame_was_raw = raw != nullptr &&
                    raw->DataU()[0] == 20 && raw->DataV()[0] == 230;
                watchdog_degraded_count++;
                condition.notify_all();
            });
    DINOX_CHECK(watchdog_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 5));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return watchdog_applied_revision == 5;
        }));
    }
    const auto watchdog_start = std::chrono::steady_clock::now();
    DINOX_CHECK(watchdog_processor->enqueue(input, 51, 5, 11));
    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    DINOX_CHECK(watchdog_processor->degrade_if_stalled(input, 52, 5, 11));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return watchdog_degraded_count == 1;
        }));
        DINOX_CHECK(watchdog_frame_id == 52);
        DINOX_CHECK(watchdog_frame_was_raw);
        DINOX_CHECK(watchdog_output_count == 0);
    }
    const auto watchdog_elapsed = std::chrono::steady_clock::now() - watchdog_start;
    DINOX_CHECK(watchdog_elapsed >= std::chrono::milliseconds(450));
    DINOX_CHECK(watchdog_elapsed < std::chrono::milliseconds(1200));
    DINOX_CHECK(!watchdog_processor->enqueue(input, 53, 5, 11));
    const auto degraded = watchdog_processor->snapshot();
    DINOX_CHECK(degraded.watchdog_bypass == 1);
    DINOX_CHECK(degraded.failed == 1);
    DINOX_CHECK(degraded.bypassed == 1);
    DINOX_CHECK(degraded.effect_thread_count == 0);
    DINOX_CHECK(degraded.effect_handle_count == 0);
    DINOX_CHECK(degraded.effect_owned_allocated_bytes == 0);
    watchdog_processor->shutdown();

    // Shutdown interrupts a deliberately very long processor delay and never
    // waits for that delay or emits a callback after returning.
    uint64_t bounded_shutdown_callbacks = 0;
    uint64_t bounded_shutdown_applied = 0;
    auto stuck_processor =
        std::make_shared<dinox::webrtc_effects::VideoEffectProcessor>(
            [&](const webrtc::VideoFrame&, uint64_t, uint64_t, uint64_t) {
                std::lock_guard<std::mutex> lock(mutex);
                bounded_shutdown_callbacks++;
                condition.notify_all();
            },
            [&](uint64_t revision, DinoXWebrtcVideoEffectType) {
                std::lock_guard<std::mutex> lock(mutex);
                bounded_shutdown_applied = revision;
                condition.notify_all();
            },
            900000);
    DINOX_CHECK(stuck_processor->enable_effect(
        DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE, 6));
    {
        std::unique_lock<std::mutex> lock(mutex);
        DINOX_CHECK(condition.wait_for(lock, std::chrono::seconds(2), [&] {
            return bounded_shutdown_applied == 6;
        }));
    }
    DINOX_CHECK(stuck_processor->enqueue(input, 61, 6, 12));
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
    const auto shutdown_start = std::chrono::steady_clock::now();
    stuck_processor->shutdown();
    DINOX_CHECK(std::chrono::steady_clock::now() - shutdown_start <
        std::chrono::milliseconds(750));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    {
        std::lock_guard<std::mutex> lock(mutex);
        DINOX_CHECK(bounded_shutdown_callbacks == 0);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    return 0;
}
