// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Original implementation of the BlazeFace short-range decoding algorithms.
// Algorithm references: MediaPipe commit cad7f3ab99ebf175947e40c5252c642612aae927,
// calculators/tflite/ssd_anchors_calculator.cc,
// calculators/tensor/tensors_to_detections_calculator.cc and
// calculators/util/non_max_suppression_calculator.cc (Apache-2.0).
// No MediaPipe framework, model asset or dense face mesh is embedded here.
#ifndef DINOX_VISION_FACE_DECODER_HPP
#define DINOX_VISION_FACE_DECODER_HPP

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <optional>
#include <span>

namespace dinox::vision {

struct Point {
    float x = 0;
    float y = 0;
};

struct Face {
    float score = 0;
    float left = 0;
    float top = 0;
    float right = 0;
    float bottom = 0;
    // RIGHT_EYE, LEFT_EYE, NOSE_TIP, MOUTH_CENTER,
    // RIGHT_EAR_TRAGION, LEFT_EAR_TRAGION, in that semantic order.
    std::array<Point, 6> points{};
};

namespace face_detail {
inline constexpr std::size_t kBoxes = 896;
inline constexpr std::size_t kCoordinates = 16;
inline constexpr std::size_t kNmsResults = 16;
inline constexpr float kMinimumScore = 0.5f;
inline constexpr float kOverlap = 0.3f;
inline constexpr float kCoordinateBound = 4.0f;

// The pinned graph has strides {8,16,16,16}, one aspect ratio plus one
// interpolated ratio per layer, and fixed anchor w=h=1. Equal strides are
// grouped before y/x/anchor enumeration. Scales do not change fixed-size anchors.
constexpr std::array<Point, kBoxes> make_anchors() {
    constexpr std::array<int, 4> strides{8, 16, 16, 16};
    std::array<Point, kBoxes> result{};
    std::size_t index = 0;
    std::size_t layer = 0;
    while (layer < strides.size()) {
        std::size_t end = layer + 1;
        while (end < strides.size() && strides[end] == strides[layer]) ++end;
        const int grid = 128 / strides[layer];
        const std::size_t repeats = 2 * (end - layer);
        for (int y = 0; y < grid; ++y) {
            for (int x = 0; x < grid; ++x) {
                for (std::size_t anchor = 0; anchor < repeats; ++anchor) {
                    result[index++] = Point{(x + 0.5f) / grid, (y + 0.5f) / grid};
                }
            }
        }
        layer = end;
    }
    return result;
}
inline constexpr auto kAnchors = make_anchors();

inline bool bounded(float value) {
    return std::isfinite(value) && std::fabs(value) <= kCoordinateBound;
}

inline bool usable_box(const Face& face) {
    const float width = face.right - face.left;
    const float height = face.bottom - face.top;
    return bounded(face.left) && bounded(face.top) && bounded(face.right) &&
           bounded(face.bottom) && width > 0 && height > 0 &&
           width <= kCoordinateBound && height <= kCoordinateBound;
}

inline bool usable_points(const Face& face) {
    for (const auto& point : face.points) {
        if (!bounded(point.x) || !bounded(point.y)) return false;
    }
    return true;
}

inline bool intersects_canvas(const Face& face) {
    return face.right > 0 && face.bottom > 0 && face.left < 1 && face.top < 1;
}

inline float iou(const Face& first, const Face& second) {
    if (!usable_box(first) || !usable_box(second)) return 0;
    const double width = (std::max)(0.0, static_cast<double>((std::min)(first.right, second.right)) -
                                        (std::max)(first.left, second.left));
    const double height = (std::max)(0.0, static_cast<double>((std::min)(first.bottom, second.bottom)) -
                                         (std::max)(first.top, second.top));
    const double intersection = width * height;
    const double first_area = static_cast<double>(first.right - first.left) * (first.bottom - first.top);
    const double second_area = static_cast<double>(second.right - second.left) * (second.bottom - second.top);
    const double total = first_area + second_area - intersection;
    return total > 0 ? static_cast<float>(intersection / total) : 0;
}

inline float probability(float logit) {
    const double clipped = (std::max)(-100.0, (std::min)(100.0, static_cast<double>(logit)));
    // Double avoids the float exp(100) intermediate overflow; accepted scores
    // implement the same clipped sigmoid as the pinned CPU reference.
    return static_cast<float>(1.0 / (1.0 + std::exp(-clipped)));
}
}  // namespace face_detail

// Inputs are the exact float32 [1,896,16] regressors and [1,896,1] logits.
// Output and previous are normalized DETECTOR-CANVAS coordinates, before the
// parent's inverse letterbox/crop/rotation transform. Reset previous on a source
// or transform generation change. Six approximate 2D points do not imply mesh,
// depth, person identity or individual landmark confidence.
// Any nonfinite raw element invalidates the whole result. No coordinate clamps
// are performed. The abs<=4/positive dimension<=4 checks are our integration
// bounds, not model properties. Partial canvas overlap is allowed; the parent
// must check real source-image visibility after projection before placing props.
inline std::optional<Face> decode_primary_face(
    std::span<const float> regressors, std::span<const float> logits,
    const Face* previous = nullptr) {
    using namespace face_detail;
    if (regressors.size() != kBoxes * kCoordinates || logits.size() != kBoxes) {
        return std::nullopt;
    }
    for (std::size_t i = 0; i < regressors.size(); ++i) {
        if (!std::isfinite(regressors[i])) return std::nullopt;
    }
    for (std::size_t i = 0; i < logits.size(); ++i) {
        if (!std::isfinite(logits[i])) return std::nullopt;
    }

    // Fixed storage: at most 896 candidates/groups and 16 valid canvas results.
    std::array<Face, kBoxes> candidates;
    std::array<std::size_t, kBoxes> order;
    std::size_t count = 0;
    for (std::size_t i = 0; i < kBoxes; ++i) {
        const float score = probability(logits[i]);
        if (score < kMinimumScore) continue;
        const auto raw = regressors.subspan(i * kCoordinates, kCoordinates);
        const float center_x = raw[0] / 128.0f + kAnchors[i].x;
        const float center_y = raw[1] / 128.0f + kAnchors[i].y;
        const float width = raw[2] / 128.0f;
        const float height = raw[3] / 128.0f;
        Face face;
        face.score = score;
        face.left = center_x - width / 2.0f;
        face.top = center_y - height / 2.0f;
        face.right = center_x + width / 2.0f;
        face.bottom = center_y + height / 2.0f;
        for (std::size_t point = 0; point < face.points.size(); ++point) {
            face.points[point] = Point{raw[4 + point * 2] / 128.0f + kAnchors[i].x,
                                       raw[5 + point * 2] / 128.0f + kAnchors[i].y};
        }
        if (!usable_box(face) || !usable_points(face)) continue;
        candidates[count] = face;
        order[count] = count;
        ++count;
    }
    if (count == 0) return std::nullopt;
    std::ranges::sort(std::span(order).first(count), [&](std::size_t first, std::size_t second) {
        if (candidates[first].score != candidates[second].score) {
            return candidates[first].score > candidates[second].score;
        }
        // Candidate insertion preserves original anchor ordering.
        return first < second;
    });

    std::array<Face, kNmsResults> results;
    std::size_t result_count = 0;
    for (std::size_t step = 0; count > 0 && step < kBoxes && result_count < kNmsResults; ++step) {
        const Face winner = candidates[order[0]];
        double weight = 0;
        std::array<double, 4> box_sums{};
        std::array<double, 12> point_sums{};
        std::size_t remaining = 0;
        for (std::size_t position = 0; position < count; ++position) {
            const std::size_t index = order[position];
            const Face& candidate = candidates[index];
            if (iou(winner, candidate) > kOverlap) {
                const double score = candidate.score;
                weight += score;
                box_sums[0] += candidate.left * score;
                box_sums[1] += candidate.top * score;
                box_sums[2] += candidate.right * score;
                box_sums[3] += candidate.bottom * score;
                for (std::size_t point = 0; point < candidate.points.size(); ++point) {
                    point_sums[point * 2] += candidate.points[point].x * score;
                    point_sums[point * 2 + 1] += candidate.points[point].y * score;
                }
            } else {
                // remaining <= position, so this cannot overwrite unread indices.
                order[remaining++] = index;
            }
        }
        if (!(weight > 0) || remaining == count) return std::nullopt;
        count = remaining;
        Face merged = winner;  // Preserve top original score, not an average score.
        merged.left = static_cast<float>(box_sums[0] / weight);
        merged.top = static_cast<float>(box_sums[1] / weight);
        merged.right = static_cast<float>(box_sums[2] / weight);
        merged.bottom = static_cast<float>(box_sums[3] / weight);
        for (std::size_t point = 0; point < merged.points.size(); ++point) {
            merged.points[point] = Point{static_cast<float>(point_sums[point * 2] / weight),
                                         static_cast<float>(point_sums[point * 2 + 1] / weight)};
        }
        // Geometry stays unclamped through NMS, including partial/outside boxes.
        if (usable_box(merged) && usable_points(merged) && intersects_canvas(merged)) {
            results[result_count++] = merged;
        }
    }
    if (result_count == 0) return std::nullopt;
    if (previous && usable_box(*previous)) {
        std::optional<std::size_t> best;
        float overlap = kOverlap;
        for (std::size_t i = 0; i < result_count; ++i) {
            const float value = iou(results[i], *previous);
            if (value >= kOverlap && (!best || value > overlap)) {
                best = i;
                overlap = value;
            }
        }
        if (best) return results[*best];
    }
    return results[0];
}
// Compatibility for validated TFLite tensor arrays. The raw C++ tensor API
// exposes pointer/length; nulls and lengths are rejected before constructing
// bounded views. New callers should pass the spans directly.
inline std::optional<Face> decode_primary_face(const float* regressors,
        std::size_t regressor_count, const float* logits, std::size_t logit_count,
        const Face* previous = nullptr) {
    if (!regressors || !logits || regressor_count != face_detail::kBoxes * face_detail::kCoordinates ||
            logit_count != face_detail::kBoxes) return std::nullopt;
#if defined(__clang__)
#pragma clang unsafe_buffer_usage begin
#endif
    return decode_primary_face(std::span<const float>(regressors,regressor_count),
        std::span<const float>(logits,logit_count),previous);
#if defined(__clang__)
#pragma clang unsafe_buffer_usage end
#endif
}

}  // namespace dinox::vision
#endif  // DINOX_VISION_FACE_DECODER_HPP
