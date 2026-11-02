#include "dinox_webrtc_video_effects.hpp"
#include "dinox_webrtc_video_effect_config.hpp"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <new>
#include <system_error>
#include <utility>
#include <vector>

#if defined(__SSE2__) || defined(_M_X64) || \
        (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define DINOX_WEBRTC_WARM_TONE_HAS_SSE2 1
#endif

#include "api/video/i420_buffer.h"
#include "libyuv/planar_functions.h"

namespace dinox::webrtc_effects {
namespace {

constexpr int kMaxSharpWidth = 4096;
constexpr size_t kMaxFisheyeGeometryBytes = 5 * 1024 * 1024;
constexpr auto kEffectWatchdogDeadline = std::chrono::milliseconds(500);
constexpr auto kShutdownJoinDeadline = std::chrono::milliseconds(550);

uint64_t monotonic_time_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

uint64_t percentile(std::vector<uint64_t>* samples, unsigned int numerator) {
    if (samples == nullptr || samples->empty()) return 0;
    std::sort(samples->begin(), samples->end());
    const size_t index = std::min(
        samples->size() - 1,
        (samples->size() * numerator + 99) / 100 - 1);
    return (*samples)[index];
}

bool write_grayscale(
    const webrtc::VideoFrame& input,
    const webrtc::scoped_refptr<webrtc::I420BufferInterface>& source,
    const webrtc::scoped_refptr<webrtc::I420Buffer>& grayscale,
    webrtc::VideoFrame* output,
    uint64_t* out_buffer_bytes) {
    if (output == nullptr || source == nullptr || grayscale == nullptr) {
        return false;
    }
    if (source->width() != grayscale->width() ||
            source->height() != grayscale->height()) {
        return false;
    }
    for (int row = 0; row < source->height(); ++row) {
        std::memcpy(
            grayscale->MutableDataY() + row * grayscale->StrideY(),
            source->DataY() + row * source->StrideY(),
            static_cast<size_t>(source->width()));
    }
    const int chroma_height = (source->height() + 1) / 2;
    const int chroma_width = (source->width() + 1) / 2;
    for (int row = 0; row < chroma_height; ++row) {
        std::memset(
            grayscale->MutableDataU() + row * grayscale->StrideU(),
            128,
            static_cast<size_t>(chroma_width));
        std::memset(
            grayscale->MutableDataV() + row * grayscale->StrideV(),
            128,
            static_cast<size_t>(chroma_width));
    }
    *output = input;
    output->set_video_frame_buffer(grayscale);
    // Every pixel is changed in chroma space, so a partial input update rect is
    // no longer valid.  libwebrtc represents a full-frame update after clear.
    output->clear_update_rect();
    if (out_buffer_bytes != nullptr) {
        *out_buffer_bytes =
            static_cast<uint64_t>(grayscale->StrideY()) * source->height() +
            static_cast<uint64_t>(grayscale->StrideU()) * chroma_height +
            static_cast<uint64_t>(grayscale->StrideV()) * chroma_height;
    }
    return true;
}

bool write_warm_tone(
    const webrtc::VideoFrame& input,
    const webrtc::scoped_refptr<webrtc::I420BufferInterface>& source,
    const webrtc::scoped_refptr<webrtc::I420Buffer>& warm_tone,
    webrtc::VideoFrame* output,
    uint64_t* out_buffer_bytes) {
    if (output == nullptr || source == nullptr || warm_tone == nullptr) {
        return false;
    }
    if (source->width() != warm_tone->width() ||
            source->height() != warm_tone->height()) {
        return false;
    }
    libyuv::CopyPlane(
        source->DataY(),
        source->StrideY(),
        warm_tone->MutableDataY(),
        warm_tone->StrideY(),
        source->width(),
        source->height());
    const int chroma_height = (source->height() + 1) / 2;
    const int chroma_width = (source->width() + 1) / 2;
    for (int row = 0; row < chroma_height; ++row) {
        const uint8_t* source_u = source->DataU() + row * source->StrideU();
        const uint8_t* source_v = source->DataV() + row * source->StrideV();
        uint8_t* target_u =
            warm_tone->MutableDataU() + row * warm_tone->StrideU();
        uint8_t* target_v =
            warm_tone->MutableDataV() + row * warm_tone->StrideV();
        int column = 0;
#if defined(DINOX_WEBRTC_WARM_TONE_HAS_SSE2)
        const __m128i u_offset = _mm_set1_epi8(8);
        const __m128i v_offset = _mm_set1_epi8(12);
        for (; column + 16 <= chroma_width; column += 16) {
            const __m128i u = _mm_loadu_si128(
                reinterpret_cast<const __m128i*>(source_u + column));
            const __m128i v = _mm_loadu_si128(
                reinterpret_cast<const __m128i*>(source_v + column));
            _mm_storeu_si128(
                reinterpret_cast<__m128i*>(target_u + column),
                _mm_subs_epu8(u, u_offset));
            _mm_storeu_si128(
                reinterpret_cast<__m128i*>(target_v + column),
                _mm_adds_epu8(v, v_offset));
        }
#endif
        // Keep a scalar tail and a complete fallback for non-x86 targets.
        for (; column < chroma_width; ++column) {
            target_u[column] = source_u[column] > 8
                ? static_cast<uint8_t>(source_u[column] - 8)
                : 0;
            target_v[column] = source_v[column] <= 243
                ? static_cast<uint8_t>(source_v[column] + 12)
                : 255;
        }
    }
    *output = input;
    output->set_video_frame_buffer(warm_tone);
    // The complete chroma planes change, so a partial update rect can no
    // longer describe the output frame.
    output->clear_update_rect();
    if (out_buffer_bytes != nullptr) {
        *out_buffer_bytes =
            static_cast<uint64_t>(warm_tone->StrideY()) * source->height() +
            static_cast<uint64_t>(warm_tone->StrideU()) * chroma_height +
            static_cast<uint64_t>(warm_tone->StrideV()) * chroma_height;
    }
    return true;
}

int rounded_divide(int numerator, int denominator) {
    // Signed round-to-nearest, with ties away from zero, independent of the
    // platform's floating-point rounding mode.
    return numerator >= 0 ? (numerator + denominator / 2) / denominator :
        -((-numerator + denominator / 2) / denominator);
}

int rounded_coordinate_divide(int64_t numerator, int64_t denominator) {
    return static_cast<int>(numerator >= 0 ?
        (numerator + denominator / 2) / denominator :
        -((-numerator + denominator / 2) / denominator));
}

int plane_sample(
    const uint8_t* data, int stride, int width, int height, int x, int y) {
    return data[std::clamp(y, 0, height - 1) * stride +
        std::clamp(x, 0, width - 1)];
}

int cardinal_sum(
    const uint8_t* data, int stride, int width, int height, int x, int y, int radius) {
    return plane_sample(data, stride, width, height, x, y) +
        plane_sample(data, stride, width, height, x - radius, y) +
        plane_sample(data, stride, width, height, x + radius, y) +
        plane_sample(data, stride, width, height, x, y - radius) +
        plane_sample(data, stride, width, height, x, y + radius);
}

int light_leak_mask(int x, int y, int width, int height) {
    const int px = rounded_coordinate_divide(
        INT64_C(256) * x, std::max(width - 1, 1));
    const int py = rounded_coordinate_divide(
        INT64_C(256) * y, std::max(height - 1, 1));
    return std::max(0, 256 - 2 * px - py);
}

std::pair<int, int> fisheye_coordinates(int x, int y, int width, int height) {
    // A shared denominator keeps the active lens circular in pixel space,
    // including portrait, landscape and one-pixel source planes.
    const int denominator = std::max({width - 1, height - 1, 1});
    const int64_t dx = INT64_C(2) * x - width + 1;
    const int64_t dy = INT64_C(2) * y - height + 1;
    const int nx = rounded_coordinate_divide(INT64_C(256) * dx, denominator);
    const int ny = rounded_coordinate_divide(INT64_C(256) * dy, denominator);
    const int radius_squared = std::min(nx * nx + ny * ny, 65536);
    const int factor = 256 - rounded_divide(51 * (65536 - radius_squared), 65536);
    return {
        std::clamp(rounded_coordinate_divide(
            static_cast<int64_t>(width - 1) * 256 + dx * factor, 512), 0, width - 1),
        std::clamp(rounded_coordinate_divide(
            static_cast<int64_t>(height - 1) * 256 + dy * factor, 512), 0, height - 1)};
}

constexpr int kPrismOffsets[4][2] = {
    {-16, 12}, {-8, -12}, {16, -8}, {8, 16}};

void write_frosted_luma_row(const uint8_t* source, int stride, int width, int height,
    int y, int black, int white, int brightness, int contrast, uint8_t* target) {
    const uint8_t* center = source + y * stride;
    const uint8_t* above = source + std::max(y - 2, 0) * stride;
    const uint8_t* below = source + std::min(y + 2, height - 1) * stride;
    const auto sample = [&](int x, int left, int right) {
        const int sum = center[x] + center[left] + center[right] + above[x] + below[x];
        const int value = std::clamp(rounded_divide(sum, 5) +
            (((x & 1) != (y & 1)) ? 1 : -1), 0, 255);
        target[x] = static_cast<uint8_t>(brightness == 0 && contrast == 100 ? value :
            std::clamp(rounded_divide((2 * value - black - white) * contrast +
                (black + white) * 100 + 2 * brightness * (white - black), 200), black, white));
    };
    const int interior_start = std::min(2, width);
    const int interior_end = std::max(interior_start, width - 2);
    for (int x = 0; x < interior_start; ++x) sample(x, std::max(x - 2, 0), std::min(x + 2, width - 1));
    for (int x = interior_start; x < interior_end; ++x) sample(x, x - 2, x + 2);
    for (int x = interior_end; x < width; ++x) sample(x, std::max(x - 2, 0), std::min(x + 2, width - 1));
}

void write_frosted_chroma_row(const uint8_t* source, int stride, int width, int height,
    int y, int gain, uint8_t* target) {
    const uint8_t* center = source + y * stride;
    const uint8_t* above = source + std::max(y - 1, 0) * stride;
    const uint8_t* below = source + std::min(y + 1, height - 1) * stride;
    const auto sample = [&](int x, int left, int right) {
        const int value = rounded_divide(center[x] + center[left] + center[right] + above[x] + below[x], 5);
        target[x] = static_cast<uint8_t>(gain == 10000 ? value :
            std::clamp(128 + rounded_divide((value - 128) * gain, 10000), 0, 255));
    };
    sample(0, 0, std::min(1, width - 1));
    for (int x = 1; x + 1 < width; ++x) sample(x, x - 1, x + 1);
    if (width > 1) sample(width - 1, width - 2, width - 1);
}

bool write_config(
    const webrtc::VideoFrame& input,
    const DinoXWebrtcVideoEffectConfig& config,
    const webrtc::scoped_refptr<webrtc::I420BufferInterface>& source,
    const webrtc::scoped_refptr<webrtc::I420Buffer>& target,
    webrtc::VideoFrame* output,
    uint64_t* out_buffer_bytes,
    uint8_t* luma_scratch,
    size_t luma_scratch_bytes,
    bool fast_rows = false,
    const uint32_t* fisheye_geometry = nullptr,
    size_t fisheye_geometry_entries = 0) {
    if (output == nullptr || source == nullptr || target == nullptr ||
            source->width() != target->width() || source->height() != target->height()) {
        return false;
    }
    const int width = source->width();
    const int height = source->height();
    const int chroma_width = (width + 1) / 2;
    const int chroma_height = (height + 1) / 2;
    const uint8_t* const source_y_data = source->DataY();
    const uint8_t* const source_u_data = source->DataU();
    const uint8_t* const source_v_data = source->DataV();
    const int source_y_stride = source->StrideY();
    const int source_u_stride = source->StrideU();
    const int source_v_stride = source->StrideV();
    uint8_t* const target_y_data = target->MutableDataY();
    uint8_t* const target_u_data = target->MutableDataU();
    uint8_t* const target_v_data = target->MutableDataV();
    const int target_y_stride = target->StrideY();
    const int target_u_stride = target->StrideU();
    const int target_v_stride = target->StrideV();
    if (config.sharpness != 0 && width <= kMaxSharpWidth && (luma_scratch == nullptr ||
            luma_scratch_bytes < static_cast<size_t>(width) * 3)) return false;
    const bool neutral_adjustments = config.brightness == 0 &&
        config.contrast == 0 && config.saturation == 0 && config.sharpness == 0;
    if (neutral_adjustments && config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE) {
        // Keep the existing SIMD transform and exact legacy clipping behavior.
        return write_warm_tone(input, source, target, output, out_buffer_bytes);
    }
    if (neutral_adjustments && config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE) {
        return write_grayscale(input, source, target, output, out_buffer_bytes);
    }
    const bool full_range = input.color_space().has_value() &&
        input.color_space()->range() == webrtc::ColorSpace::RangeID::kFull;
    // Unspecified camera I420 uses the existing limited-range interpretation.
    const int black = full_range ? 0 : 16;
    const int white = full_range ? 255 : 235;
    const int span = white - black;
    const int midpoint_twice = black + white;
    const int contrast = 100 + config.contrast;
    const int saturation = 100 + config.saturation;
    const size_t luma_entries = static_cast<size_t>(width) * height;
    const bool cached_fisheye = fisheye_geometry != nullptr &&
        fisheye_geometry_entries == luma_entries + static_cast<size_t>(chroma_width) * chroma_height;
    const bool cached_fisheye_rows = cached_fisheye &&
        config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE;
    const bool adjust_fisheye_luma = config.brightness != 0 || config.contrast != 0;
    std::array<uint8_t, 256> fisheye_luma_lut{};
    if (cached_fisheye_rows && adjust_fisheye_luma) {
        // Exact integer BC, once for each possible input byte. The neutral
        // branch deliberately preserves camera headroom instead of clipping.
        for (int value = 0; value < 256; ++value)
            fisheye_luma_lut[value] = static_cast<uint8_t>(std::clamp(rounded_divide(
                (2 * value - midpoint_twice) * contrast + midpoint_twice * 100 +
                    2 * config.brightness * span,
                200), black, white));
    }
    const auto write_cached_fisheye_row = [&](int y, uint8_t* row) {
        const uint32_t* coordinates = fisheye_geometry + static_cast<size_t>(y) * width;
        // No preset switch, original-pixel read or BC divisions inside these
        // cached row loops. Packed coordinates and their bounds are unchanged.
        if (adjust_fisheye_luma) {
            for (int x = 0; x < width; ++x) {
                const uint32_t packed = coordinates[x];
                const uint8_t sample = source_y_data[static_cast<size_t>(packed >> 16) *
                    source_y_stride + (packed & UINT32_C(65535))];
                row[x] = fisheye_luma_lut[sample];
            }
        } else {
            for (int x = 0; x < width; ++x) {
                const uint32_t packed = coordinates[x];
                row[x] = source_y_data[static_cast<size_t>(packed >> 16) *
                    source_y_stride + (packed & UINT32_C(65535))];
            }
        }
    };
    const auto preset_luma = [&](int x, int y) -> int {
        const int value = source_y_data[y * source_y_stride + x];
        switch (config.effect_type) {
            case DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK:
                return std::clamp(value + rounded_divide(16 * span *
                    light_leak_mask(x, y, width, height), 25600), 0, 255);
            case DINOX_WEBRTC_VIDEO_EFFECT_DREAMY:
                return std::clamp(rounded_divide(3 * value + cardinal_sum(
                    source_y_data, source_y_stride, width, height,
                    x, y, 1), 8) + rounded_divide(span, 64), 0, 255);
            case DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE: {
                if (cached_fisheye) {
                    const uint32_t packed = fisheye_geometry[static_cast<size_t>(y) * width + x];
                    return source_y_data[static_cast<size_t>(packed >> 16) * source_y_stride + (packed & UINT32_C(65535))];
                }
                const auto [sx, sy] = fisheye_coordinates(x, y, width, height);
                return source_y_data[sy * source_y_stride + sx];
            }
            case DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV:
                return std::max(value - (y % 4 >= 2 ? rounded_divide(span, 20) : 0), 0);
            case DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS:
                return std::clamp(rounded_divide(cardinal_sum(
                    source_y_data, source_y_stride, width, height,
                    x, y, 2), 5) + (((x & 1) != (y & 1)) ? 1 : -1), 0, 255);
            case DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE:
                return black + rounded_divide(span + 8 * std::clamp(value - black, 0, span), 10);
            default:
                return value;
        }
    };
    const auto adjusted_luma = [&](int x, int y) {
        const int value = preset_luma(x, y);
        if (config.brightness == 0 && config.contrast == 0) return value;
        return std::clamp(rounded_divide(
            (2 * value - midpoint_twice) * contrast + midpoint_twice * 100 +
                2 * config.brightness * span,
            200), black, white);
    };
    const bool preset_changes_luma =
        config.effect_type >= DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK &&
        config.effect_type != DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT &&
        config.effect_type != DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER;
    if (!preset_changes_luma && config.brightness == 0 && config.contrast == 0 &&
            config.sharpness == 0) {
        libyuv::CopyPlane(source_y_data, source_y_stride,
            target_y_data, target_y_stride, width, height);
    } else if (config.sharpness != 0 && width <= kMaxSharpWidth) {
        // Evaluate each preset+BC sample once. Three rows hold the exact
        // immutable neighbours, including one-row and edge-clamped frames.
        const auto prepare_row = [&](int y) {
            uint8_t* row = luma_scratch + (y % 3) * width;
            if (cached_fisheye_rows) {
                write_cached_fisheye_row(y, row);
                return;
            }
            if (fast_rows && config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS) {
                write_frosted_luma_row(source_y_data, source_y_stride, width, height,
                    y, black, white, config.brightness, contrast, row);
                return;
            }
            for (int x = 0; x < width; ++x) {
                row[x] = static_cast<uint8_t>(adjusted_luma(x, y));
            }
        };
        prepare_row(0);
        for (int y = 0; y < height; ++y) {
            if (y + 1 < height) prepare_row(y + 1);
            const uint8_t* center_row = luma_scratch + (y % 3) * width;
            const uint8_t* above = luma_scratch + (std::max(y - 1, 0) % 3) * width;
            const uint8_t* below = luma_scratch + (std::min(y + 1, height - 1) % 3) * width;
            uint8_t* row = target_y_data + y * target_y_stride;
            if (fast_rows) {
                const auto sharpen = [&](int x, int left, int right) {
                    const int center = center_row[x];
                    const int laplacian = 4 * center - center_row[left] -
                        center_row[right] - above[x] - below[x];
                    row[x] = static_cast<uint8_t>(std::clamp(center +
                        rounded_divide(config.sharpness * laplacian, 400), 0, 255));
                };
                // Handle the two edge positions once. The interior has no
                // x-clamps or edge branches; singleton/odd widths stay exact.
                sharpen(0, 0, width > 1 ? 1 : 0);
                for (int x = 1; x + 1 < width; ++x) sharpen(x, x - 1, x + 1);
                if (width > 1) sharpen(width - 1, width - 2, width - 1);
                continue;
            }
            // Static apply_config retains this original per-pixel reference.
            for (int x = 0; x < width; ++x) {
                const int center = center_row[x];
                const int laplacian = 4 * center - center_row[std::max(x - 1, 0)] -
                    center_row[std::min(x + 1, width - 1)] - above[x] - below[x];
                row[x] = static_cast<uint8_t>(std::clamp(center +
                    rounded_divide(config.sharpness * laplacian, 400), 0, 255));
            }
        }
    } else if (cached_fisheye_rows && config.sharpness == 0) {
        for (int y = 0; y < height; ++y)
            write_cached_fisheye_row(y, target_y_data + y * target_y_stride);
    } else if (fast_rows && config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS && config.sharpness == 0) {
        for (int y = 0; y < height; ++y)
            write_frosted_luma_row(source_y_data, source_y_stride, width, height,
                y, black, white, config.brightness, contrast, target_y_data + y * target_y_stride);
    } else {
        for (int y = 0; y < height; ++y) {
            uint8_t* row = target_y_data + y * target_y_stride;
            for (int x = 0; x < width; ++x) {
                int value = adjusted_luma(x, y);
                if (config.sharpness != 0) {
                    // Compatibility for unusually wide sources: keep the
                    // prior immutable-neighbour path, using no extra scratch.
                    const int laplacian = 4 * value -
                        adjusted_luma(std::max(x - 1, 0), y) -
                        adjusted_luma(std::min(x + 1, width - 1), y) -
                        adjusted_luma(x, std::max(y - 1, 0)) -
                        adjusted_luma(x, std::min(y + 1, height - 1));
                    value = std::clamp(value +
                        rounded_divide(config.sharpness * laplacian, 400), 0, 255);
                }
                row[x] = static_cast<uint8_t>(value);
            }
        }
    }
    const int chroma_gain = contrast * saturation;
    for (int y = 0; y < chroma_height; ++y) {
        const uint8_t* source_u = source_u_data + y * source_u_stride;
        const uint8_t* source_v = source_v_data + y * source_v_stride;
        uint8_t* target_u = target_u_data + y * target_u_stride;
        uint8_t* target_v = target_v_data + y * target_v_stride;
        if (fast_rows && config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS) {
            write_frosted_chroma_row(source_u_data, source_u_stride, chroma_width, chroma_height, y, chroma_gain, target_u);
            write_frosted_chroma_row(source_v_data, source_v_stride, chroma_width, chroma_height, y, chroma_gain, target_v);
            continue;
        }
        for (int x = 0; x < chroma_width; ++x) {
            int u = source_u[x];
            int v = source_v[x];
            switch (config.effect_type) {
                case DINOX_WEBRTC_VIDEO_EFFECT_GRAYSCALE:
                    u = v = 128;
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_WARM_TONE:
                    u = std::max(u - 8, 0);
                    v = std::min(v + 12, 255);
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_COLD_TONE:
                    u = std::min(u + 8, 255);
                    v = std::max(v - 12, 0);
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK:
                case DINOX_WEBRTC_VIDEO_EFFECT_PRISM_LIGHT: {
                    int sum_u = 0;
                    int sum_v = 0;
                    int samples = 0;
                    for (int dy = 0; dy < 2 && 2 * y + dy < height; ++dy) {
                        for (int dx = 0; dx < 2 && 2 * x + dx < width; ++dx) {
                            const int lx = 2 * x + dx;
                            const int ly = 2 * y + dy;
                            if (config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK) {
                                const int mask = light_leak_mask(
                                    lx, ly, width, height);
                                sum_u -= 8 * mask;
                                sum_v += 12 * mask;
                            } else {
                                const int band = static_cast<int>(
                                    INT64_C(4) * lx / width);
                                sum_u += kPrismOffsets[band][0];
                                sum_v += kPrismOffsets[band][1];
                            }
                            ++samples;
                        }
                    }
                    const int divisor = samples *
                        (config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_LIGHT_LEAK ? 256 : 1);
                    u = std::clamp(u + rounded_divide(sum_u, divisor), 0, 255);
                    v = std::clamp(v + rounded_divide(sum_v, divisor), 0, 255);
                    break;
                }
                case DINOX_WEBRTC_VIDEO_EFFECT_DREAMY:
                    u = 128 + rounded_divide(7 * (u - 128), 8);
                    v = 128 + rounded_divide(7 * (v - 128), 8);
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE: {
                    if (cached_fisheye) {
                        const uint32_t packed = fisheye_geometry[luma_entries + static_cast<size_t>(y) * chroma_width + x];
                        u = source_u_data[static_cast<size_t>(packed >> 16) * source_u_stride + (packed & UINT32_C(65535))];
                        v = source_v_data[static_cast<size_t>(packed >> 16) * source_v_stride + (packed & UINT32_C(65535))];
                        break;
                    }
                    const auto [sx, sy] = fisheye_coordinates(
                        x, y, chroma_width, chroma_height);
                    u = source_u_data[sy * source_u_stride + sx];
                    v = source_v_data[sy * source_v_stride + sx];
                    break;
                }
                case DINOX_WEBRTC_VIDEO_EFFECT_VINTAGE_TV:
                    u = 128 + rounded_divide(3 * (u - 128), 4);
                    v = 128 + rounded_divide(3 * (v - 128), 4);
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_FROSTED_GLASS:
                    u = rounded_divide(cardinal_sum(source_u_data, source_u_stride,
                        chroma_width, chroma_height, x, y, 1), 5);
                    v = rounded_divide(cardinal_sum(source_v_data, source_v_stride,
                        chroma_width, chroma_height, x, y, 1), 5);
                    break;
                case DINOX_WEBRTC_VIDEO_EFFECT_SEPIA: {
                    int sum = 0;
                    int samples = 0;
                    for (int dy = 0; dy < 2 && 2 * y + dy < height; ++dy) {
                        for (int dx = 0; dx < 2 && 2 * x + dx < width; ++dx) {
                            sum += source_y_data[
                                (2 * y + dy) * source_y_stride + 2 * x + dx];
                            ++samples;
                        }
                    }
                    const int tint = rounded_divide(
                        16 * std::clamp(sum - samples * black, 0, samples * span),
                        samples * span);
                    u = 128 - tint;
                    v = 128 + tint;
                    break;
                }
                case DINOX_WEBRTC_VIDEO_EFFECT_DUO_TONE: {
                    int sum = 0;
                    int samples = 0;
                    for (int dy = 0; dy < 2 && 2 * y + dy < height; ++dy) {
                        for (int dx = 0; dx < 2 && 2 * x + dx < width; ++dx) {
                            sum += source_y_data[
                                (2 * y + dy) * source_y_stride + 2 * x + dx];
                            ++samples;
                        }
                    }
                    const int q = std::clamp(sum - samples * black, 0, samples * span);
                    u = 152 - rounded_divide(48 * q, samples * span);
                    v = 108 + rounded_divide(40 * q, samples * span);
                    break;
                }
                case DINOX_WEBRTC_VIDEO_EFFECT_UNDERWATER: {
                    int sum = 0, count = 0;
                    for (int dy = 0; dy < 2 && 2 * y + dy < height; ++dy)
                        for (int dx = 0; dx < 2 && 2 * x + dx < width; ++dx) {
                            sum += std::clamp(source_y_data[(2 * y + dy) *
                                source_y_stride + 2 * x + dx] - black, 0, span);
                            ++count;
                        }
                    u = std::clamp(u + rounded_divide(18 * sum, count * span), 0, 255);
                    v = std::clamp(v - rounded_divide(16 * sum, count * span), 0, 255);
                    break;
                }
                default:
                    break;
            }
            if (chroma_gain == 10000) {
                // Every preset above produces U/V in 0..255. The final gain
                // is exact identity, including controls whose product cancels.
                target_u[x] = static_cast<uint8_t>(u);
                target_v[x] = static_cast<uint8_t>(v);
            } else {
                target_u[x] = static_cast<uint8_t>(std::clamp(
                    128 + rounded_divide((u - 128) * chroma_gain, 10000), 0, 255));
                target_v[x] = static_cast<uint8_t>(std::clamp(
                    128 + rounded_divide((v - 128) * chroma_gain, 10000), 0, 255));
            }
        }
    }
    *output = input;
    output->set_video_frame_buffer(target);
    output->clear_update_rect();
    if (out_buffer_bytes != nullptr) {
        *out_buffer_bytes = static_cast<uint64_t>(target_y_stride) * height +
            static_cast<uint64_t>(target_u_stride) * chroma_height +
            static_cast<uint64_t>(target_v_stride) * chroma_height;
    }
    return true;
}

}  // namespace

VideoEffectProcessor::VideoEffectProcessor(
    OutputCallback output_callback,
    AppliedCallback applied_callback,
    uint32_t processing_delay_for_test_us,
    DegradedCallback degraded_callback,
    std::shared_ptr<VideoRuntime> runtime,
    RuntimeOutputCallback runtime_output_callback,
    RuntimeOutputCallback runtime_degraded_callback)
    : output_callback_(std::move(output_callback)),
      applied_callback_(std::move(applied_callback)),
      degraded_callback_(std::move(degraded_callback)),
      runtime_(runtime ? std::move(runtime) : std::make_shared<VideoRuntime>(VisionPaths{})),
      runtime_output_callback_(std::move(runtime_output_callback)),
      runtime_degraded_callback_(std::move(runtime_degraded_callback)),
      processing_delay_for_test_us_(processing_delay_for_test_us) {}

VideoEffectProcessor::~VideoEffectProcessor() {
    shutdown();
}

bool VideoEffectProcessor::enable_effect(
    DinoXWebrtcVideoEffectType effect,
    uint64_t revision) {
    DinoXWebrtcVideoEffectConfig config = {};
    config.abi_version = DINOX_WEBRTC_ABI_VERSION;
    config.effect_type = effect;
    return enable_config(config, revision);
}

bool VideoEffectProcessor::enable_config(
    const DinoXWebrtcVideoEffectConfig& config,
    uint64_t revision) {
    if (!valid_config(config) || !supported_config(config,
            runtime_ && runtime_->segmentation_available(),
            runtime_ && runtime_->face_available()) ||
            !active_config(config) || revision == 0) {
        return false;
    }
    std::lock_guard<std::recursive_mutex> configure_lock(configure_mutex_);
    std::thread completed_thread;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_requested_) return false;
        if (thread_.joinable() && !thread_running_) {
            completed_thread = std::move(thread_);
        }
    }
    if (completed_thread.joinable()) completed_thread.join();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_requested_) return false;
        desired_enabled_ = true;
        desired_config_ = config;
        desired_revision_ = revision;
        pending_frame_.reset();
        watchdog_tripped_ = false;
        if (!thread_running_) {
            thread_running_ = true;
            diagnostics_.effect_thread_count = 1;
            diagnostics_.effect_handle_count = 1;
            std::shared_ptr<VideoEffectProcessor> self = weak_from_this().lock();
            if (self == nullptr) {
                finish_thread_locked();
                return false;
            }
            // The pinned WebRTC Windows toolchain disables C++ exceptions.
            // Keep the recoverable std::thread failure path on platforms where
            // exceptions are enabled without emitting try/catch for Windows.
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
            try {
                thread_ = std::thread([self = std::move(self)] { self->run(); });
            } catch (const std::system_error&) {
                finish_thread_locked();
                return false;
            }
#else
            thread_ = std::thread([self = std::move(self)] { self->run(); });
#endif
        }
    }
    condition_.notify_one();
    return true;
}

bool VideoEffectProcessor::disable(uint64_t revision) {
    if (revision == 0) return false;
    std::lock_guard<std::recursive_mutex> configure_lock(configure_mutex_);
    bool asynchronous = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_requested_) return false;
        desired_enabled_ = false;
        desired_config_ = {};
        desired_config_.abi_version = DINOX_WEBRTC_ABI_VERSION;
        desired_revision_ = revision;
        pending_frame_.reset();
        // A capture-side watchdog may have detached the logical effect path
        // while the native transform is still wedged. Off is already safe and
        // must become APPLIED immediately instead of waiting for that thread.
        asynchronous = thread_running_ && !watchdog_tripped_;
    }
    condition_.notify_one();
    return asynchronous;
}

bool VideoEffectProcessor::enqueue(
    const webrtc::VideoFrame& frame,
    uint64_t frame_id,
    uint64_t revision,
    uint64_t source_id,
    FrameIdentity identity) {
    if (frame.video_frame_buffer() == nullptr || frame_id == 0 || revision == 0 ||
            source_id == 0) return false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_requested_ || !thread_running_ || !desired_enabled_ ||
                desired_revision_ != revision) {
            return false;
        }
        diagnostics_.captured++;
        if (pending_frame_.has_value()) diagnostics_.queue_replaced++;
        pending_frame_ = PendingFrame{
            frame, frame_id, revision, source_id, desired_config_, std::move(identity)};
        diagnostics_.enqueued++;
    }
    condition_.notify_one();
    return true;
}

bool VideoEffectProcessor::degrade_if_stalled(
    const webrtc::VideoFrame& bypass_frame,
    uint64_t frame_id,
    uint64_t revision,
    uint64_t source_id,
    FrameIdentity identity) {
    if (bypass_frame.video_frame_buffer() == nullptr || frame_id == 0 ||
            revision == 0 || source_id == 0) {
        return false;
    }
    std::lock_guard<std::recursive_mutex> configure_lock(configure_mutex_);
    DegradedCallback callback;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_requested_ || watchdog_tripped_ || !thread_running_ ||
                !desired_enabled_ || desired_revision_ != revision ||
                !processing_active_ || processing_revision_ != revision ||
                std::chrono::steady_clock::now() - processing_started_ <
                    kEffectWatchdogDeadline) {
            return false;
        }
        watchdog_tripped_ = true;
        desired_enabled_ = false;
        pending_frame_.reset();
        diagnostics_.failed++;
        diagnostics_.bypassed++;
        diagnostics_.watchdog_bypass++;
        const uint64_t elapsed_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - processing_started_).count());
        diagnostics_.processing_time_total_us += elapsed_us;
        diagnostics_.processing_time_max_us = std::max(
            diagnostics_.processing_time_max_us, elapsed_us);
        diagnostics_.last_completed_monotonic_us = monotonic_time_us();
        record_processing_time_locked(elapsed_us);
        diagnostics_.effect_thread_count = 0;
        diagnostics_.effect_handle_count = 0;
        diagnostics_.effect_owned_allocated_bytes = 0;
        callback = degraded_callback_;
    }
    condition_.notify_all();
    if (runtime_degraded_callback_) {
        runtime_degraded_callback_(bypass_frame, frame_id, revision, source_id, identity);
    } else if (callback) {
        callback(bypass_frame, frame_id, revision, source_id);
    }
    return true;
}

void VideoEffectProcessor::shutdown() {
    std::unique_lock<std::recursive_mutex> configure_lock(configure_mutex_);
    std::thread thread;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_requested_ = true;
        desired_enabled_ = false;
        pending_frame_.reset();
        if (thread_.joinable()) thread = std::move(thread_);
    }
    condition_.notify_one();
    configure_lock.unlock();
    if (thread.joinable() && thread.get_id() != std::this_thread::get_id()) {
        bool completed = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            completed = condition_.wait_for(lock, kShutdownJoinDeadline, [&] {
                return !thread_running_;
            });
        }
        if (completed) {
            thread.join();
        } else {
            // The worker owns a shared reference to this processor. Detaching
            // is therefore memory-safe, while stop_requested_ suppresses all
            // later output/state callbacks. Teardown must never wait forever
            // on a wedged optional effect.
            thread.detach();
        }
    } else if (thread.joinable()) {
        thread.detach();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    diagnostics_.effect_thread_count = 0;
    diagnostics_.effect_handle_count = 0;
    diagnostics_.effect_owned_allocated_bytes = 0;
}

Diagnostics VideoEffectProcessor::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Diagnostics result = diagnostics_;
    // Logical activity ends immediately at watchdog/Off. Retained pool/scratch,
    // image leases and cancelled I/O buffers end only at actual release/reap.
    result.effect_owned_allocated_bytes = pool_buffer_bytes_ * pool_buffer_count_ +
        luma_scratch_bytes_ + fisheye_geometry_bytes_ + runtime_->owned_bytes();
    std::vector<uint64_t> samples;
    samples.reserve(processing_sample_count_);
    for (size_t index = 0; index < processing_sample_count_; ++index) {
        samples.push_back(processing_samples_[index]);
    }
    std::vector<uint64_t> p95_samples = samples;
    result.processing_time_p95_us = percentile(&p95_samples, 95);
    result.processing_time_p99_us = percentile(&samples, 99);
    return result;
}

bool VideoEffectProcessor::apply_grayscale(
    const webrtc::VideoFrame& input,
    webrtc::VideoFrame* output,
    uint64_t* out_allocated_bytes) {
    if (output == nullptr || input.video_frame_buffer() == nullptr) return false;
    webrtc::scoped_refptr<webrtc::I420BufferInterface> source =
        input.video_frame_buffer()->ToI420();
    if (source == nullptr || source->width() <= 0 || source->height() <= 0) return false;
    webrtc::scoped_refptr<webrtc::I420Buffer> grayscale =
        webrtc::I420Buffer::Create(source->width(), source->height());
    if (grayscale == nullptr) return false;

    return write_grayscale(input, source, grayscale, output, out_allocated_bytes);
}

bool VideoEffectProcessor::apply_warm_tone(
    const webrtc::VideoFrame& input,
    webrtc::VideoFrame* output,
    uint64_t* out_allocated_bytes) {
    if (output == nullptr || input.video_frame_buffer() == nullptr) return false;
    webrtc::scoped_refptr<webrtc::I420BufferInterface> source =
        input.video_frame_buffer()->ToI420();
    if (source == nullptr || source->width() <= 0 || source->height() <= 0) return false;
    webrtc::scoped_refptr<webrtc::I420Buffer> warm_tone =
        webrtc::I420Buffer::Create(source->width(), source->height());
    if (warm_tone == nullptr) return false;

    return write_warm_tone(input, source, warm_tone, output, out_allocated_bytes);
}

bool VideoEffectProcessor::apply_config(
    const webrtc::VideoFrame& input,
    const DinoXWebrtcVideoEffectConfig& config,
    webrtc::VideoFrame* output,
    uint64_t* out_allocated_bytes) {
    if (output == nullptr || input.video_frame_buffer() == nullptr ||
            !valid_config(config) || !supported_config(config)) return false;
    if (!active_config(config)) {
        *output = input;
        if (out_allocated_bytes != nullptr) *out_allocated_bytes = 0;
        return true;
    }
    auto source = input.video_frame_buffer()->ToI420();
    if (source == nullptr || source->width() <= 0 || source->height() <= 0) return false;
    auto target = webrtc::I420Buffer::Create(source->width(), source->height());
    if (target == nullptr) return false;
    // Synchronous test/reference helper: no shared mutable scratch state or
    // cached geometry/row fastpaths. Keep the scalar implementation as a pixel
    // oracle independently of the real executor's optimizations.
    std::unique_ptr<uint8_t[]> scratch;
    const size_t scratch_bytes = config.sharpness != 0 && source->width() <= kMaxSharpWidth ?
        static_cast<size_t>(source->width()) * 3 : 0;
    if (scratch_bytes != 0) scratch = std::make_unique<uint8_t[]>(scratch_bytes);
    VideoRuntime runtime(VisionPaths{});
    FrameIdentity identity;
    identity.frame.frame_id = 1;
    identity.frame.captured_monotonic_ns = vision::VisionClient::monotonic_now_ns();
    identity.frame.rotation = uint32_t(input.rotation());
    if (advanced_pixels(config)) source = runtime.prepare(input, source, config, identity);
    if (!source) return false;
    return write_config(input, config, source, target, output, out_allocated_bytes,
        scratch.get(), scratch_bytes) && runtime.finish(output, *target, config, identity);
}

void VideoEffectProcessor::run() {
    uint64_t applied_revision = 0;
    while (true) {
        std::optional<PendingFrame> pending;
        uint64_t state_revision = 0;
        DinoXWebrtcVideoEffectType state_effect = DINOX_WEBRTC_VIDEO_EFFECT_NONE;
        bool emit_enabled = false;
        bool emit_disabled = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            condition_.wait(lock, [&] {
                return stop_requested_ || !desired_enabled_ ||
                    desired_revision_ != applied_revision ||
                    pending_frame_.has_value();
            });
            if (stop_requested_) {
                buffer_pool_.Release();
                finish_thread_locked();
                return;
            }
            if (!desired_enabled_) {
                state_revision = desired_revision_;
                emit_disabled = true;
                buffer_pool_.Release();
                finish_thread_locked();
            } else if (desired_revision_ != applied_revision) {
                applied_revision = desired_revision_;
                state_revision = applied_revision;
                state_effect = desired_config_.effect_type;
                if (state_effect != DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE)
                    release_fisheye_geometry_locked();
                emit_enabled = true;
            } else if (pending_frame_.has_value()) {
                pending = std::move(pending_frame_);
                pending_frame_.reset();
                processing_active_ = true;
                processing_started_ = std::chrono::steady_clock::now();
                processing_revision_ = pending->revision;
                processing_source_id_ = pending->source_id;
            }
        }
        if (emit_disabled) {
            bool notify_disabled = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                notify_disabled = !watchdog_tripped_;
            }
            if (notify_disabled && applied_callback_) {
                applied_callback_(state_revision, DINOX_WEBRTC_VIDEO_EFFECT_NONE);
            }
            return;
        }
        if (emit_enabled && applied_callback_) {
            std::lock_guard<std::recursive_mutex> configure_lock(configure_mutex_);
            bool current = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                current = !stop_requested_ && desired_enabled_ &&
                    desired_revision_ == state_revision &&
                    desired_config_.effect_type == state_effect;
            }
            if (current) {
                applied_callback_(state_revision, state_effect);
            }
        }
        if (!pending.has_value()) continue;

        if (pending->identity.frame.frame_id == 0) {
            pending->identity.frame.frame_id = pending->frame_id;
            pending->identity.frame.captured_monotonic_ns = vision::VisionClient::monotonic_now_ns();
        }

        const auto start = std::chrono::steady_clock::now();
        const auto watchdog_deadline = start + kEffectWatchdogDeadline;
        bool watchdog_expired = false;
        if (processing_delay_for_test_us_ > 0) {
            // Deliberately non-interruptible: tests use this to model a native
            // conversion call that makes no progress. The capture-side
            // in-flight watchdog must remain able to open the direct path.
            std::this_thread::sleep_for(
                std::chrono::microseconds(processing_delay_for_test_us_));
            watchdog_expired = std::chrono::steady_clock::now() >= watchdog_deadline;
        }
        webrtc::VideoFrame output = pending->frame;
        uint64_t allocated_bytes = 0;
        webrtc::scoped_refptr<webrtc::I420BufferInterface> source_i420 =
            watchdog_expired ? nullptr : pending->frame.video_frame_buffer()->ToI420();
        webrtc::scoped_refptr<webrtc::I420Buffer> output_buffer;
        bool prepare_output = false;
        const int width = source_i420 != nullptr ? source_i420->width() : 0;
        const int height = source_i420 != nullptr ? source_i420->height() : 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            prepare_output = !stop_requested_ && desired_enabled_ &&
                desired_revision_ == pending->revision &&
                same_config(desired_config_, pending->config) && width > 0 && height > 0;
            if (!prepare_output || scratch_width_ != width || scratch_height_ != height ||
                    pending->config.sharpness == 0 || width > kMaxSharpWidth) {
                luma_scratch_.reset();
                luma_scratch_bytes_ = 0;
                scratch_width_ = prepare_output ? width : 0;
                scratch_height_ = prepare_output ? height : 0;
            }
            if (prepare_output && pending->config.sharpness != 0 && width <= kMaxSharpWidth &&
                    luma_scratch_ == nullptr) {
                luma_scratch_bytes_ = static_cast<size_t>(width) * 3;
                luma_scratch_ = std::make_unique<uint8_t[]>(luma_scratch_bytes_);
            }
            if (diagnostics_.effect_thread_count != 0) {
                diagnostics_.effect_owned_allocated_bytes =
                    pool_buffer_bytes_ * pool_buffer_count_ + luma_scratch_bytes_ +
                    fisheye_geometry_bytes_ + runtime_->owned_bytes();
            }
        }
        if (prepare_output && pending->config.effect_type == DINOX_WEBRTC_VIDEO_EFFECT_FISHEYE)
            prepare_output = prepare_fisheye_geometry(width, height, *pending);
        if (prepare_output) {
            output_buffer = buffer_pool_.CreateI420Buffer(
                width, height);
        }
        bool processed = false;
        if (!watchdog_expired && output_buffer != nullptr) {
            if (advanced_pixels(pending->config)) {
                source_i420 = runtime_->prepare(pending->frame, source_i420,
                    pending->config, pending->identity);
                pending->identity.mask_capture_ns = runtime_->mask_capture_ns();
                pending->identity.concealed = runtime_->concealed();
            } else { runtime_->release_workspace(); }
            processed = source_i420 != nullptr && write_config(pending->frame, pending->config,
                source_i420, output_buffer, &output, &allocated_bytes,
                luma_scratch_.get(), luma_scratch_bytes_, true,
                fisheye_geometry_.get(), fisheye_geometry_entries_) &&
                runtime_->finish(&output, *output_buffer, pending->config, pending->identity);
        }
        const uint64_t elapsed_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - start).count());
        watchdog_expired = watchdog_expired ||
            std::chrono::steady_clock::now() >= watchdog_deadline;
        std::lock_guard<std::recursive_mutex> configure_lock(configure_mutex_);
        bool current = false;
        DegradedCallback degraded_callback;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            current = !stop_requested_ && desired_enabled_ &&
                desired_revision_ == pending->revision &&
                same_config(desired_config_, pending->config);
            processing_active_ = false;
            processing_revision_ = 0;
            processing_source_id_ = 0;
            if (!current) continue;
            if (watchdog_expired) {
                watchdog_tripped_ = true;
                diagnostics_.failed++;
                diagnostics_.bypassed++;
                diagnostics_.watchdog_bypass++;
                desired_enabled_ = false;
                pending_frame_.reset();
                degraded_callback = degraded_callback_;
            } else if (processed) {
                diagnostics_.processed++;
                diagnostics_.frame_copy_count += advanced_pixels(pending->config) ? 2 : 1;
                if (pool_width_ != output.width() || pool_height_ != output.height()) {
                    pool_width_ = output.width();
                    pool_height_ = output.height();
                    pool_buffer_addresses_.fill(nullptr);
                    pool_buffer_count_ = 0;
                }
                bool seen = false;
                for (size_t index = 0; index < pool_buffer_count_; ++index) {
                    seen = seen || pool_buffer_addresses_[index] == output_buffer.get();
                }
                if (!seen && pool_buffer_count_ < pool_buffer_addresses_.size()) {
                    pool_buffer_addresses_[pool_buffer_count_++] = output_buffer.get();
                }
                pool_buffer_bytes_ = allocated_bytes;
                diagnostics_.effect_owned_allocated_bytes =
                    pool_buffer_bytes_ * pool_buffer_count_ + luma_scratch_bytes_ +
                    fisheye_geometry_bytes_ + runtime_->owned_bytes();
            } else {
                diagnostics_.failed++;
                diagnostics_.bypassed++;
            }
            diagnostics_.processing_time_total_us += elapsed_us;
            diagnostics_.processing_time_max_us = std::max(
                diagnostics_.processing_time_max_us, elapsed_us);
            diagnostics_.last_completed_monotonic_us = monotonic_time_us();
            record_processing_time_locked(elapsed_us);
        }
        if (current && watchdog_expired) {
            buffer_pool_.Release();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                finish_thread_locked();
            }
            if (runtime_degraded_callback_) {
                runtime_degraded_callback_(pending->frame, pending->frame_id,
                    pending->revision, pending->source_id, pending->identity);
            } else if (degraded_callback) {
                degraded_callback(
                    pending->frame, pending->frame_id,
                    pending->revision, pending->source_id);
            }
            return;
        }
        if (current && processed && (output_callback_ || runtime_output_callback_)) {
            // Fail closed: if conversion or the bounded three-buffer pool is
            // temporarily unavailable, drop this frame. Publishing the raw
            // colour frame would visibly bypass an effect that the UI reports
            // as active. The latest-wins queue supplies the next frame without
            // blocking the capture thread or growing memory.
            if (runtime_output_callback_) {
                runtime_output_callback_(output, pending->frame_id,
                    pending->revision, pending->source_id, pending->identity);
            } else {
                output_callback_(output, pending->frame_id,
                    pending->revision, pending->source_id);
            }
        }
    }
}

void VideoEffectProcessor::record_processing_time_locked(uint64_t elapsed_us) {
    processing_samples_[processing_sample_cursor_] = elapsed_us;
    processing_sample_cursor_ = (processing_sample_cursor_ + 1) % processing_samples_.size();
    processing_sample_count_ = std::min(
        processing_sample_count_ + 1, processing_samples_.size());
}

bool VideoEffectProcessor::prepare_fisheye_geometry(
    int width, int height, const PendingFrame& pending) {
    // Only the worker calls this method. Config/Stop observers read the byte
    // count under mutex_, but never free a map while this worker can read it.
    // Revisions of B/C/S/Sharpness do not change geometry. A different camera,
    // call/source generation or transform conservatively rebuilds it.
    auto binding = pending.identity.binding;
    binding.config_revision = 0;
    binding.demand = 0;
    const auto current = [&] {
        return !stop_requested_ && desired_enabled_ &&
            desired_revision_ == pending.revision &&
            same_config(desired_config_, pending.config);
    };
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!current()) { release_fisheye_geometry_locked(); return false; }
        if (fisheye_geometry_ && fisheye_width_ == width && fisheye_height_ == height &&
                fisheye_source_id_ == pending.source_id &&
                fisheye_camera_lease_ == pending.identity.camera_lease &&
                fisheye_binding_ == binding) return true;
        // Release before replacement: even changing dimensions never retains
        // two maps. Unsupported dimensions use the unchanged scalar path.
        release_fisheye_geometry_locked();
    }
    if (width <= 0 || height <= 0 || width > 65535 || height > 65535) return true;
    const int chroma_width = (width + 1) / 2;
    const int chroma_height = (height + 1) / 2;
    const uint64_t entries = static_cast<uint64_t>(width) * height +
        static_cast<uint64_t>(chroma_width) * chroma_height;
    if (entries > kMaxFisheyeGeometryBytes / sizeof(uint32_t)) return true;
    std::unique_ptr<uint32_t[]> map(new (std::nothrow) uint32_t[static_cast<size_t>(entries)]);
    if (!map) return true; // Allocation failure must not change image quality.
    uint32_t* coordinates = map.get();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!current()) return false;
        fisheye_geometry_ = std::move(map);
        fisheye_geometry_entries_ = static_cast<size_t>(entries);
        fisheye_geometry_bytes_ = static_cast<size_t>(entries) * sizeof(uint32_t);
    }
    size_t index = 0;
    for (const auto [plane_width, plane_height] :
            {std::pair{width, height}, std::pair{chroma_width, chroma_height}}) {
        for (int y = 0; y < plane_height; ++y) {
            // Cancellation is bounded by a single row. The capture/control
            // thread is never held during allocation or coordinate math.
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!current()) { release_fisheye_geometry_locked(); return false; }
            }
            for (int x = 0; x < plane_width; ++x) {
                const auto [sx, sy] = fisheye_coordinates(x, y, plane_width, plane_height);
                coordinates[index++] = static_cast<uint32_t>(sx) |
                    (static_cast<uint32_t>(sy) << 16);
            }
        }
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!current()) { release_fisheye_geometry_locked(); return false; }
    fisheye_width_ = width;
    fisheye_height_ = height;
    fisheye_source_id_ = pending.source_id;
    fisheye_camera_lease_ = pending.identity.camera_lease;
    fisheye_binding_ = binding;
    return true;
}

void VideoEffectProcessor::release_fisheye_geometry_locked() {
    fisheye_geometry_.reset();
    fisheye_geometry_entries_ = 0;
    fisheye_geometry_bytes_ = 0;
    fisheye_width_ = 0;
    fisheye_height_ = 0;
    fisheye_source_id_ = 0;
    fisheye_camera_lease_ = 0;
    fisheye_binding_ = {};
}

void VideoEffectProcessor::finish_thread_locked() {
    runtime_->release_workspace();
    release_fisheye_geometry_locked();
    luma_scratch_.reset();
    luma_scratch_bytes_ = 0;
    scratch_width_ = 0;
    scratch_height_ = 0;
    thread_running_ = false;
    diagnostics_.effect_thread_count = 0;
    diagnostics_.effect_handle_count = 0;
    diagnostics_.effect_owned_allocated_bytes = 0;
    pool_width_ = 0;
    pool_height_ = 0;
    pool_buffer_addresses_.fill(nullptr);
    pool_buffer_count_ = 0;
    pool_buffer_bytes_ = 0;
    processing_active_ = false;
    processing_revision_ = 0;
    processing_source_id_ = 0;
    condition_.notify_all();
}

}  // namespace dinox::webrtc_effects
