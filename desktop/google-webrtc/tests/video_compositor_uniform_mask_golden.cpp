// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
// Constant mask alpha is the exact byte, across letterbox, ROI and rotation.
#include "dinox_webrtc_video_compositor.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>

namespace vc = dinox::video_compositor;
namespace {
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "COMPOSITOR_UNIFORM_MASK_FAIL %d: %s\n", __LINE__, #x); return false; } } while (false)

int blend_reference(int foreground, int background, int alpha) {
    return (foreground * alpha + background * (255 - alpha) + 127) / 255;
}

bool plane_matches(const std::vector<uint8_t>& plane, int stride,
        int width, int height, int value) {
    if (plane.front() != 0xa7 || plane.back() != 0xa7) return false;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < stride; ++x) {
            if (plane[1 + y * stride + x] != (x < width ? value : 0xa7)) return false;
        }
    }
    return true;
}

bool uniform_masks() {
    constexpr std::array<vc::Roi, 3> rois = {{{0.5, 0.5, 1},
        {0.4, 0.6, 2.0 / 3}, {0.5, 0.5, 0.9000000000000001}}};
    for (const auto dimensions : {std::array<int, 2>{1, 1}, {17, 13}, {18, 12}}) {
        const int width = dimensions[0], height = dimensions[1];
        const int cw = (width + 1) / 2, ch = (height + 1) / 2;
        const int ys = width + 5, us = cw + 3, vs = cw + 7;
        std::vector<uint8_t> sy(width * height, 173), su(cw * ch, 41), sv(cw * ch, 209);
        std::vector<uint8_t> oy(ys * height + 2, 0xa7), ou(us * ch + 2, 0xa7), ov(vs * ch + 2, 0xa7);
        std::vector<uint8_t> confidence(9 * 4, 0xa7);
        for (const auto range : {vc::Range::Limited, vc::Range::Full}) {
            for (const auto matrix : {vc::Matrix::Bt601, vc::Matrix::Bt709}) {
                const vc::I420View source{width, height, range, matrix,
                    {sy, width}, {su, cw}, {sv, cw}};
                const vc::I420Output output{width, height, range, matrix,
                    {{oy.data() + 1, oy.size() - 2}, ys},
                    {{ou.data() + 1, ou.size() - 2}, us},
                    {{ov.data() + 1, ov.size() - 2}, vs}};
                for (int rotation : {0, 90, 180, 270}) {
                    vc::MaskView mask{{confidence, 9}, 5, 4, width, height,
                        {1, 1, 3, 2}, true, rotation};
                    for (const auto roi : rois) {
                        mask.valid = true;
                        vc::Options options;
                        options.background = vc::BackgroundMode::Solid;
                        options.rotation = rotation;
                        options.roi = roi;
                        for (int alpha = 0; alpha <= 255; ++alpha) {
                            for (int y = 1; y < 3; ++y) for (int x = 1; x < 4; ++x)
                                confidence[y * 9 + x] = static_cast<uint8_t>(alpha);
                            const auto before_mask = confidence;
                            CHECK(vc::compose(source, options, &mask, nullptr, {}, output) == vc::Status::Applied);
                            CHECK(plane_matches(oy, ys, width, height,
                                blend_reference(173, range == vc::Range::Limited ? 16 : 0, alpha)));
                            CHECK(plane_matches(ou, us, cw, ch, blend_reference(41, 128, alpha)));
                            CHECK(plane_matches(ov, vs, cw, ch, blend_reference(209, 128, alpha)));
                            CHECK(confidence == before_mask);
                        }
                        mask.valid = false;
                        CHECK(vc::compose(source, options, &mask, nullptr, {}, output) == vc::Status::Concealed);
                        CHECK(plane_matches(oy, ys, width, height, range == vc::Range::Limited ? 16 : 0));
                        CHECK(plane_matches(ou, us, cw, ch, 128));
                        CHECK(plane_matches(ov, vs, cw, ch, 128));
                    }
                }
            }
        }
        CHECK(std::all_of(sy.begin(), sy.end(), [](uint8_t x) { return x == 173; }));
        CHECK(std::all_of(su.begin(), su.end(), [](uint8_t x) { return x == 41; }));
        CHECK(std::all_of(sv.begin(), sv.end(), [](uint8_t x) { return x == 209; }));
    }
    return true;
}
} // namespace

int main() {
    if (!uniform_masks()) return 1;
    std::puts("COMPOSITOR_UNIFORM_MASK_PASS: all 256 alphas, four rotations, ROI/letterbox, formats, odd/even/singleton planes, padding and stale-mask concealment");
}
