// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Synthetic numeric goldens; no model inference or face-quality claim.
#include "face_decoder.hpp"

#include <cstdio>
#include <iostream>
#include <limits>
#include <string_view>

namespace {
using dinox::vision::Face;
using dinox::vision::Point;
constexpr std::size_t kBoxes = 896;
constexpr std::size_t kValues = kBoxes * 16;
int failures = 0;

void Check(bool condition, std::string_view label) {
    if (!condition) {
        std::cerr << "FACE_DECODER_GOLDEN_FAIL: " << label << '\n';
        ++failures;
    }
}
void Near(float actual, float expected, std::string_view label) {
    Check(std::isfinite(actual) && std::fabs(actual - expected) <= 0.00001f, label);
}

struct Raw {
    std::array<float, kValues> boxes{};
    std::array<float, kBoxes> scores;
    Raw() { scores.fill(-100.0f); }
    std::optional<Face> Decode(const Face* previous = nullptr) const {
        return dinox::vision::decode_primary_face(boxes.data(), boxes.size(), scores.data(), scores.size(), previous);
    }
};

// Independent index equations for the two official anchor groups.
Point ExpectedAnchor(std::size_t index) {
    const std::size_t cell = index < 512 ? index / 2 : (index - 512) / 6;
    const std::size_t grid = index < 512 ? 16 : 8;
    return Point{(static_cast<float>(cell % grid) + 0.5f) / grid,
                 (static_cast<float>(cell / grid) + 0.5f) / grid};
}

Face FaceAt(float score, float x, float y, float width, float height) {
    Face face;
    face.score = score;
    face.left = x - width / 2;
    face.top = y - height / 2;
    face.right = x + width / 2;
    face.bottom = y + height / 2;
    face.points = {Point{x - 0.03f, y - 0.02f}, Point{x + 0.03f, y - 0.02f},
                   Point{x, y}, Point{x, y + 0.04f}, Point{x - 0.06f, y}, Point{x + 0.06f, y}};
    return face;
}

void Put(Raw& raw, std::size_t index, const Face& face) {
    const Point anchor = ExpectedAnchor(index);
    const std::size_t offset = index * 16;
    raw.boxes[offset] = ((face.left + face.right) / 2 - anchor.x) * 128;
    raw.boxes[offset + 1] = ((face.top + face.bottom) / 2 - anchor.y) * 128;
    raw.boxes[offset + 2] = (face.right - face.left) * 128;
    raw.boxes[offset + 3] = (face.bottom - face.top) * 128;
    for (std::size_t point = 0; point < 6; ++point) {
        raw.boxes[offset + 4 + point * 2] = (face.points[point].x - anchor.x) * 128;
        raw.boxes[offset + 5 + point * 2] = (face.points[point].y - anchor.y) * 128;
    }
    raw.scores[index] = std::log(face.score / (1 - face.score));
}

void AnchorsAndManualDecode() {
    for (std::size_t i = 0; i < kBoxes; ++i) {
        const Point expected = ExpectedAnchor(i);
        Near(dinox::vision::face_detail::kAnchors[i].x, expected.x, "all 896 anchor x order");
        Near(dinox::vision::face_detail::kAnchors[i].y, expected.y, "all 896 anchor y order");
    }
    Raw raw;
    constexpr std::size_t index = 272;  // center (0.53125,0.53125)
    const std::array<float, 16> values{-4, -4, 25.6f, 25.6f, -9.12f, -7.84f,
                                      1.12f, -7.84f, -4, -4, -4, 2.4f, -16.8f, -4, 8.8f, -4};
    for (std::size_t i = 0; i < values.size(); ++i) raw.boxes[index * 16 + i] = values[i];
    raw.scores[index] = 0;  // Exact inclusive confidence boundary.
    const auto result = raw.Decode();
    Check(result.has_value(), "logit zero accepted at score 0.5");
    if (!result) return;
    Near(result->score, 0.5f, "sigmoid zero");
    Near(result->left, 0.4f, "manual XYWH left");
    Near(result->top, 0.4f, "manual XYWH top");
    Near(result->right, 0.6f, "linear width, no exp");
    Near(result->bottom, 0.6f, "linear height, no exp");
    const std::array<Point, 6> expected{Point{0.46f, 0.47f}, Point{0.54f, 0.47f},
                                       Point{0.5f, 0.5f}, Point{0.5f, 0.55f},
                                       Point{0.4f, 0.5f}, Point{0.6f, 0.5f}};
    for (std::size_t point = 0; point < 6; ++point) {
        Near(result->points[point].x, expected[point].x, "manual six-point x/order");
        Near(result->points[point].y, expected[point].y, "manual six-point y/order");
    }
    raw.scores[index] = -0.001f;
    Check(!raw.Decode(), "score below 0.5 rejected");
    raw.scores[index] = 1000;
    const auto clipped = raw.Decode();
    Check(clipped.has_value(), "positive logit still produces face");
    if (clipped) Near(clipped->score, 1.0f, "positive logit clipped safely");
    raw.scores[index] = -1000;
    Check(!raw.Decode(), "negative logit clipped safely");
}

void CornersAndWeightedNms() {
    for (const auto index : {std::size_t{0}, std::size_t{30}, std::size_t{480}, std::size_t{510}}) {
        Raw raw;
        const Point center = ExpectedAnchor(index);
        const Face expected = FaceAt(0.8f, center.x, center.y, 0.125f, 0.125f);
        Put(raw, index, expected);
        const auto result = raw.Decode();
        Check(result.has_value(), "partial corner face preserved");
        if (!result) continue;
        Near(result->left, expected.left, "corner left unclamped");
        Near(result->right, expected.right, "corner right unclamped");
        for (std::size_t point = 0; point < 6; ++point) {
            Near(result->points[point].x, expected.points[point].x, "corner six-point x");
            Near(result->points[point].y, expected.points[point].y, "corner six-point y");
        }
    }
    Raw raw;
    const Face first = FaceAt(0.8f, 0.02f, 0.5f, 0.2f, 0.2f);
    const Face second = FaceAt(0.6f, 0.03f, 0.5f, 0.2f, 0.2f);
    Put(raw, 0, first);
    Put(raw, 1, second);
    const auto result = raw.Decode();
    Check(result.has_value(), "weighted NMS returns merged face");
    if (!result) return;
    Near(result->score, 0.8f, "weighted NMS preserves top score");
    Near(result->left, (-0.08f * 0.8f - 0.07f * 0.6f) / 1.4f, "NMS merges negative left without clamping");
    Near(result->right, (0.12f * 0.8f + 0.13f * 0.6f) / 1.4f, "NMS weighted right");
    for (std::size_t point = 0; point < 6; ++point) {
        Near(result->points[point].x, (first.points[point].x * 0.8f + second.points[point].x * 0.6f) / 1.4f,
             "NMS weights all six point x values");
        Near(result->points[point].y, first.points[point].y, "NMS weights all six point y values");
    }
}

void PrimaryAndExactOverlapBoundary() {
    Raw raw;
    const Face high = FaceAt(0.95f, 0.25f, 0.25f, 0.2f, 0.2f);
    const Face low = FaceAt(0.8f, 0.75f, 0.75f, 0.2f, 0.2f);
    Put(raw, 100, high);
    Put(raw, 101, low);
    const auto top = raw.Decode();
    const auto retained = raw.Decode(&low);
    Check(top.has_value() && retained.has_value(), "two-face primary selection produces face");
    if (top) Near(top->left, high.left, "no previous chooses top score");
    if (retained) Near(retained->left, low.left, "previous geometric match retains lower-score face");
    const Face unrelated = FaceAt(0.8f, 0.5f, 0.5f, 0.1f, 0.1f);
    const auto fallback = raw.Decode(&unrelated);
    Check(fallback.has_value(), "unmatched previous produces fallback");
    if (fallback) Near(fallback->left, high.left, "unmatched previous falls back to top score");

    Raw threshold;
    const Face outer = FaceAt(0.8f, 1.0f, 0.5f, 2.0f, 1.0f);  // [0,0,2,1]
    const Face inner = FaceAt(0.6f, 0.3f, 0.5f, 0.6f, 1.0f);  // [0,0,.6,1], IoU .3
    Put(threshold, 200, outer);
    Put(threshold, 201, inner);
    const auto unchanged = threshold.Decode();
    Check(unchanged.has_value(), "IoU .3 threshold produces face");
    if (unchanged) Near(unchanged->right, 2.0f, "NMS uses strict IoU > .3, not >=");

    Raw tracking;
    Put(tracking, 200, outer);
    Put(tracking, 201, FaceAt(0.95f, 0.85f, 0.2f, 0.2f, 0.2f));
    const auto matched = tracking.Decode(&inner);
    Check(matched.has_value(), "tracking IoU .3 threshold produces face");
    if (matched) Near(matched->right, 2.0f, "tracking uses inclusive IoU >= .3");
}

void InvalidInputsAndBoundedResults() {
    Raw raw;
    Put(raw, 272, FaceAt(0.8f, 0.5f, 0.5f, 0.2f, 0.2f));
    Check(!dinox::vision::decode_primary_face(nullptr, kValues, raw.scores.data(), kBoxes), "null regressors rejected");
    Check(!dinox::vision::decode_primary_face(raw.boxes.data(), kValues, nullptr, kBoxes), "null logits rejected");
    Check(!dinox::vision::decode_primary_face(raw.boxes.data(), kValues - 1, raw.scores.data(), kBoxes), "short regressor count rejected");
    Check(!dinox::vision::decode_primary_face(raw.boxes.data(), kValues + 1, raw.scores.data(), kBoxes), "extra regressor count rejected");
    Check(!dinox::vision::decode_primary_face(raw.boxes.data(), kValues, raw.scores.data(), kBoxes - 1), "short logit count rejected");
    Check(!dinox::vision::decode_primary_face(raw.boxes.data(), kValues, raw.scores.data(), kBoxes + 1), "extra logit count rejected");
    raw.boxes[0] = std::numeric_limits<float>::quiet_NaN();
    Check(!raw.Decode(), "one NaN in unused raw candidate invalidates whole result");
    raw.boxes[0] = 0;
    raw.scores[0] = std::numeric_limits<float>::infinity();
    Check(!raw.Decode(), "one infinite raw logit invalidates whole result");
    raw.scores[0] = -100;
    raw.boxes[272 * 16 + 2] = 0;
    Check(!raw.Decode(), "zero width rejected");
    raw.boxes[272 * 16 + 2] = -1;
    Check(!raw.Decode(), "negative width rejected");
    raw.boxes[272 * 16 + 2] = std::numeric_limits<float>::max();
    Check(!raw.Decode(), "huge finite geometry rejected by integration bounds");
    Put(raw, 272, FaceAt(0.8f, 2, 2, 0.2f, 0.2f));
    Check(!raw.Decode(), "final wholly outside canvas face rejected");
    Put(raw, 272, FaceAt(0.8f, 0.5f, 0.5f, 0.2f, 0.2f));
    raw.boxes[272 * 16 + 4] = 5 * 128;
    Check(!raw.Decode(), "point outside finite coordinate bound rejected");

    Raw outside_first;
    for (std::size_t i = 0; i < 16; ++i) {
        Put(outside_first, i, FaceAt(0.9f, 1.2f + 0.15f * float(i), 0.5f, 0.02f, 0.02f));
    }
    Put(outside_first, 16, FaceAt(0.8f, 0.5f, 0.5f, 0.2f, 0.2f));
    const auto visible = outside_first.Decode();
    Check(visible.has_value(), "outside NMS groups do not consume the valid-result limit");
    if (visible) Near(visible->left, 0.4f, "seventeenth group with valid face is retained");

    Raw many;
    Face previous;
    for (std::size_t i = 0; i < 17; ++i) {
        const Face face = FaceAt(0.8f, 0.03f + static_cast<float>(i) * 0.056f, 0.5f, 0.02f, 0.02f);
        Put(many, i, face);
        if (i == 16) previous = face;
    }
    const auto capped = many.Decode(&previous);
    Check(capped.has_value(), "bounded 16-result NMS returns primary");
    if (capped) Near(capped->left, 0.02f, "seventeenth result excluded, deterministic first-anchor fallback");
}
}  // namespace

int main() {
    AnchorsAndManualDecode();
    CornersAndWeightedNms();
    PrimaryAndExactOverlapBoundary();
    InvalidInputsAndBoundedResults();
    if (failures != 0) return 1;
    std::puts("FACE_DECODER_GOLDEN_PASS: synthetic anchors/decode/NMS/primary/safety");
    return 0;
}
