#include "dinox_webrtc_video_compositor.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>
#include <span>
#include <utility>
#include <vector>

namespace vc = dinox::video_compositor;

#define CHECK(condition) \
    do { if (!(condition)) { \
        std::fprintf(stderr, "check failed: %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return false; \
    } } while (false)

struct Pixels {
    int width;
    int height;
    int ys;
    int us;
    int vs;
    vc::Range range = vc::Range::Limited;
    vc::Matrix matrix = vc::Matrix::Bt601;
    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;

    Pixels(int w, int h) : width(w), height(h), ys(w + 5), us((w + 1) / 2 + 3), vs((w + 1) / 2 + 7),
        y(ys * h + 2, 0xa3), u(us * ((h + 1) / 2) + 2, 0xd7), v(vs * ((h + 1) / 2) + 2, 0xe9) {}

    vc::I420View view() const {
        return {width, height, range, matrix, {std::span(y).subspan(1, y.size() - 2), ys},
            {std::span(u).subspan(1, u.size() - 2), us}, {std::span(v).subspan(1, v.size() - 2), vs}};
    }
    vc::I420Output output() {
        return {width, height, range, matrix, {std::span(y).subspan(1, y.size() - 2), ys},
            {std::span(u).subspan(1, u.size() - 2), us}, {std::span(v).subspan(1, v.size() - 2), vs}};
    }
    void fill(uint8_t yy, uint8_t uu, uint8_t vv) {
        for (int row = 0; row < height; ++row) std::fill_n(y.data() + 1 + row * ys, width, yy);
        for (int row = 0; row < (height + 1) / 2; ++row) {
            std::fill_n(u.data() + 1 + row * us, (width + 1) / 2, uu);
            std::fill_n(v.data() + 1 + row * vs, (width + 1) / 2, vv);
        }
    }
    bool guards() const {
        if (y.front() != 0xa3 || y.back() != 0xa3 || u.front() != 0xd7 || u.back() != 0xd7 ||
                v.front() != 0xe9 || v.back() != 0xe9) return false;
        for (int row = 0; row < height; ++row) for (int x = width; x < ys; ++x) {
            if (y[1 + row * ys + x] != 0xa3) return false;
        }
        for (int row = 0; row < (height + 1) / 2; ++row) {
            for (int x = (width + 1) / 2; x < us; ++x) if (u[1 + row * us + x] != 0xd7) return false;
            for (int x = (width + 1) / 2; x < vs; ++x) if (v[1 + row * vs + x] != 0xe9) return false;
        }
        return true;
    }
};

vc::MaskView constant_mask(std::span<const uint8_t> bytes, int w, int h) {
    return {{bytes, 1}, 1, 1, w, h, {0,0,1,1}, true};
}

bool visible_color(const Pixels& pixels, int yy, int uu, int vv) {
    for (int y = 0; y < pixels.height; ++y) for (int x = 0; x < pixels.width; ++x) {
        CHECK(pixels.y[1 + y * pixels.ys + x] == yy);
    }
    for (int y = 0; y < (pixels.height + 1) / 2; ++y) for (int x = 0; x < (pixels.width + 1) / 2; ++x) {
        CHECK(pixels.u[1 + y * pixels.us + x] == uu);
        CHECK(pixels.v[1 + y * pixels.vs + x] == vv);
    }
    CHECK(pixels.guards());
    return true;
}

bool concealment_and_validation() {
    Pixels source(3, 3);
    source.fill(235, 7, 250);
    const auto before = source;
    Pixels output(3, 3);
    vc::Options options;
    CHECK(vc::compose(source.view(), options, nullptr, nullptr, {}, output.output()) == vc::Status::Passthrough);
    CHECK(output.y[1] == 0xa3 && output.guards());
    for (const auto mode : {vc::BackgroundMode::Blur, vc::BackgroundMode::Image}) {
        options.background = mode;
        CHECK(vc::compose(source.view(), options, nullptr, nullptr, {}, output.output()) == vc::Status::Concealed);
        CHECK(visible_color(output, 57, 128, 128));
    }
    constexpr std::array<std::array<int, 3>, 4> red = {{{81,90,240}, {63,102,240}, {76,85,255}, {54,99,255}}};
    size_t color_index = 0;
    for (auto range : {vc::Range::Limited, vc::Range::Full}) for (auto matrix : {vc::Matrix::Bt601, vc::Matrix::Bt709}) {
        source.range = output.range = range;
        source.matrix = output.matrix = matrix;
        options.background = vc::BackgroundMode::Solid;
        options.solid_rgb = 0xff0000;
        CHECK(vc::compose(source.view(), options, nullptr, nullptr, {}, output.output()) == vc::Status::Concealed);
        CHECK(visible_color(output, red[color_index][0], red[color_index][1], red[color_index][2]));
        ++color_index;
        options.background = vc::BackgroundMode::Blur;
        options.solid_rgb = 0;
        CHECK(vc::compose(source.view(), options, nullptr, nullptr, {}, output.output()) == vc::Status::Concealed);
        CHECK(visible_color(output, range == vc::Range::Full ? 48 : 57, 128, 128));
    }
    source.range = output.range = vc::Range::Limited;
    source.matrix = output.matrix = vc::Matrix::Bt601;
    std::array<uint8_t, 1> opaque = {255};
    auto mask = constant_mask(opaque, 3, 3);
    options.background = vc::BackgroundMode::Solid;
    options.solid_rgb = 0;
    mask.valid = false; // The controller's stale/epoch-mismatch decision.
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    CHECK(visible_color(output, 16, 128, 128));
    mask.valid = true;
    mask.source_width = 4;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    mask.source_width = 3;
    mask.content.x = 1;
    CHECK(!vc::valid_mask(mask, 3, 3));
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    mask.content.x = 0;
    auto invalid_source = source.view();
    invalid_source.y.stride = std::numeric_limits<int>::max();
    CHECK(vc::compose(invalid_source, options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    CHECK(visible_color(output, 16, 128, 128));
    options.solid_rgb = 0x1000000;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    CHECK(visible_color(output, 57, 128, 128));
    options.solid_rgb = 0;
    options.roi.center_x = std::numeric_limits<double>::quiet_NaN();
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    options.roi = {};
    const auto output_before = output;
    auto invalid_output = output.output();
    invalid_output.v.bytes = invalid_output.v.bytes.first(1);
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, invalid_output) == vc::Status::InvalidBuffers);
    CHECK(output.y == output_before.y && output.u == output_before.u && output.v == output_before.v);
    auto aliased_mask = constant_mask(output.output().y.bytes.first(1), 3, 3);
    CHECK(vc::compose(source.view(), options, &aliased_mask, nullptr, {}, output.output()) == vc::Status::InvalidBuffers);
    vc::StagedImageView aliased_image{output.view()};
    options.background = vc::BackgroundMode::Image;
    CHECK(vc::compose(source.view(), options, &mask, &aliased_image, {}, output.output()) == vc::Status::InvalidBuffers);
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
    CHECK(visible_color(output, 57, 128, 128));
    const auto output_before_alias_checks = output;
    // Duplicate mutable scratch spans are invalid even when the destination
    // itself is disjoint. Check before either output or scratch can change.
    std::array<uint32_t, 16> storage;
    storage.fill(0xdeadbeef);
    vc::Scratch overlapping_scratch{
        std::span(reinterpret_cast<uint16_t*>(storage.data()), 16), std::span(storage)};
    options.background = vc::BackgroundMode::Blur;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, overlapping_scratch, output.output()) == vc::Status::InvalidBuffers);
    CHECK(std::all_of(storage.begin(), storage.end(), [](uint32_t value) { return value == 0xdeadbeef; }));
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, source.output()) == vc::Status::InvalidBuffers);
    invalid_output = output.output();
    invalid_output.u.bytes = invalid_output.y.bytes;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, invalid_output) == vc::Status::InvalidBuffers);
    CHECK(output.y == output_before_alias_checks.y && output.u == output_before_alias_checks.u && output.v == output_before_alias_checks.v);
    CHECK(source.y == before.y && source.u == before.u && source.v == before.v && source.guards());
    CHECK(vc::blur_scratch_requirements(4096, 100).row_samples == 4096 * 25);
    CHECK(vc::blur_scratch_requirements(4097, 100).row_samples == 0);
    CHECK(vc::blur_scratch_requirements(1, -1).column_samples == 0);
    Pixels tall_source(2, 4096);
    Pixels tall_output(2, 4096);
    options = {};
    options.background = vc::BackgroundMode::Solid;
    CHECK(vc::compose(tall_source.view(), options, nullptr, nullptr, {}, tall_output.output()) == vc::Status::Concealed);
    CHECK(visible_color(tall_output, 16, 128, 128));
    auto portrait_mask = constant_mask(opaque, 2160, 4096);
    CHECK(vc::valid_mask(portrait_mask, 2160, 4096));
    portrait_mask.source_width = 2161;
    CHECK(!vc::valid_mask(portrait_mask, 2161, 4096));
    Pixels tall_asset(2, 1920);
    CHECK(vc::valid_image(vc::StagedImageView{tall_asset.view()}));
    return true;
}

bool letterbox_blend_and_bounds() {
    Pixels source(3, 3);
    Pixels output(3, 3);
    constexpr uint8_t yy[9] = {16,60,125,200,235,17,255,100,0};
    constexpr uint8_t uu[4] = {100,150,200,50};
    constexpr uint8_t vv[4] = {200,130,50,240};
    for (int y = 0; y < 3; ++y) std::copy_n(yy + 3 * y, 3, source.y.data() + 1 + y * source.ys);
    for (int y = 0; y < 2; ++y) {
        std::copy_n(uu + 2 * y, 2, source.u.data() + 1 + y * source.us);
        std::copy_n(vv + 2 * y, 2, source.v.data() + 1 + y * source.vs);
    }
    const auto before = source;
    // Padding is intentionally confident. Only the true 2x2 content rectangle
    // may influence source alpha/bounds; its stride also has padding sentinels.
    std::array<uint8_t, 28> confidence;
    confidence.fill(255);
    confidence[7 + 1] = 255;
    confidence[7 + 2] = 0;
    confidence[14 + 1] = 0;
    confidence[14 + 2] = 255;
    vc::MaskView mask{{confidence, 7}, 4, 4, 3, 3, {1,1,2,2}, true};
    vc::Options options;
    options.background = vc::BackgroundMode::Solid;
    options.solid_rgb = 0x303030;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Applied);
    constexpr uint8_t expected_y[9] = {16,59,57,129,146,37,57,79,0};
    constexpr uint8_t expected_u[4] = {110,134,146,50};
    constexpr uint8_t expected_v[4] = {173,129,108,240};
    for (int y = 0; y < 3; ++y) CHECK(std::equal(expected_y + 3 * y, expected_y + 3 * y + 3,
        output.y.data() + 1 + y * output.ys));
    for (int y = 0; y < 2; ++y) {
        CHECK(std::equal(expected_u + 2 * y, expected_u + 2 * y + 2, output.u.data() + 1 + y * output.us));
        CHECK(std::equal(expected_v + 2 * y, expected_v + 2 * y + 2, output.v.data() + 1 + y * output.vs));
    }
    CHECK(output.guards() && source.y == before.y && source.u == before.u && source.v == before.v);
    auto bounds = vc::person_bounds(mask);
    CHECK(bounds && bounds->left == 0 && bounds->top == 0 && bounds->right == 1 && bounds->bottom == 1);
    confidence[14 + 2] = 0;
    bounds = vc::person_bounds(mask);
    CHECK(bounds && bounds->left == 0 && bounds->top == 0 && bounds->right == 0.5 && bounds->bottom == 0.5);
    confidence[7 + 1] = 0;
    CHECK(!vc::person_bounds(mask));
    mask.valid = false;
    CHECK(!vc::person_bounds(mask));
    return true;
}

int box_reference(vc::Plane plane, int w, int h, int x, int y, int radius) {
    int sum = 0;
    for (int dy = -radius; dy <= radius; ++dy) for (int dx = -radius; dx <= radius; ++dx) {
        sum += plane.bytes[std::clamp(y + dy, 0, h - 1) * plane.stride + std::clamp(x + dx, 0, w - 1)];
    }
    const int divisor = (2 * radius + 1) * (2 * radius + 1);
    return (sum + divisor / 2) / divisor;
}

bool bounded_blur() {
    const std::array<uint8_t, 1> background = {0};
    const std::array<uint8_t, 1> foreground = {255};
    uint32_t random = 0x1a43e2d5;
    const auto next = [&]() { random = random * UINT32_C(1664525) + UINT32_C(1013904223); return static_cast<uint8_t>(random >> 24); };
    for (const auto& dimensions : {std::pair{1,1}, std::pair{1,17}, std::pair{17,1}, std::pair{5,3}, std::pair{23,13}}) {
        const auto [width, height] = dimensions;
        Pixels source(width, height);
        Pixels output(width, height);
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) source.y[1 + y * source.ys + x] = next();
        for (int y = 0; y < (height + 1) / 2; ++y) for (int x = 0; x < (width + 1) / 2; ++x) {
            source.u[1 + y * source.us + x] = next(); source.v[1 + y * source.vs + x] = next();
        }
        const auto before = source;
        auto mask = constant_mask(background, width, height);
        vc::Options options;
        options.background = vc::BackgroundMode::Blur;
        for (const auto& strength_radius : {std::pair{0,1}, std::pair{50,7}, std::pair{100,12}}) {
            const auto [strength, radius] = strength_radius;
            options.blur_strength = strength;
            const auto required = vc::blur_scratch_requirements(width, strength);
            std::vector<uint16_t> rows(required.row_samples + 2, 0xfefe);
            std::vector<uint32_t> columns(required.column_samples + 2, 0xdeadbeef);
            vc::Scratch scratch{std::span(rows).subspan(1, required.row_samples), std::span(columns).subspan(1, required.column_samples)};
            CHECK(vc::compose(source.view(), options, &mask, nullptr, scratch, output.output()) == vc::Status::Applied);
            auto source_view = source.view();
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                CHECK(output.y[1 + y * output.ys + x] == box_reference(source_view.y, width, height, x, y, radius));
            }
            for (int y = 0; y < (height + 1) / 2; ++y) for (int x = 0; x < (width + 1) / 2; ++x) {
                CHECK(output.u[1 + y * output.us + x] == box_reference(source_view.u, (width + 1) / 2, (height + 1) / 2, x, y, (radius + 1) / 2));
                CHECK(output.v[1 + y * output.vs + x] == box_reference(source_view.v, (width + 1) / 2, (height + 1) / 2, x, y, (radius + 1) / 2));
            }
            CHECK(rows.front() == 0xfefe && rows.back() == 0xfefe && columns.front() == 0xdeadbeef && columns.back() == 0xdeadbeef);
            CHECK(output.guards() && source.y == before.y && source.u == before.u && source.v == before.v);
            auto keep_mask = constant_mask(foreground, width, height);
            CHECK(vc::compose(source.view(), options, &keep_mask, nullptr, scratch, output.output()) == vc::Status::Applied);
            for (int y = 0; y < height; ++y) CHECK(std::equal(source.y.data() + 1 + y * source.ys,
                source.y.data() + 1 + y * source.ys + width, output.y.data() + 1 + y * output.ys));
            scratch.rows = scratch.rows.first(required.row_samples - 1);
            CHECK(vc::compose(source.view(), options, &mask, nullptr, scratch, output.output()) == vc::Status::Concealed);
            CHECK(visible_color(output, 57, 128, 128));
        }
    }
    // A fixed 3x3 golden independently establishes edge duplication and the
    // exact square-box average before the randomized/reference cases above.
    Pixels source(3, 3);
    Pixels output(3, 3);
    for (int y = 0; y < 3; ++y) for (int x = 0; x < 3; ++x) source.y[1 + y * source.ys + x] = 9 * (3 * y + x);
    const auto required = vc::blur_scratch_requirements(3, 0);
    std::vector<uint16_t> rows(required.row_samples);
    std::vector<uint32_t> columns(required.column_samples);
    auto mask = constant_mask(background, 3, 3);
    vc::Options options;
    options.background = vc::BackgroundMode::Blur;
    CHECK(vc::compose(source.view(), options, &mask, nullptr, {rows, columns}, output.output()) == vc::Status::Applied);
    constexpr uint8_t golden[9] = {12,18,24,30,36,42,48,54,60};
    for (int y = 0; y < 3; ++y) CHECK(std::equal(golden + y * 3, golden + y * 3 + 3, output.y.data() + 1 + y * output.ys));
    return true;
}

bool staged_image_and_crop() {
    Pixels source(3, 3);
    source.fill(235, 7, 250);
    Pixels output(3, 3);
    Pixels asset(2, 2);
    asset.fill(0, 80, 180);
    asset.y[1] = 25; asset.y[2] = 50;
    asset.y[1 + asset.ys] = 75; asset.y[2 + asset.ys] = 100;
    const auto before = asset;
    vc::StagedImageView image{asset.view()};
    CHECK(vc::valid_image(image));
    const std::array<uint8_t, 1> background = {0};
    auto mask = constant_mask(background, 3, 3);
    vc::Options options;
    options.background = vc::BackgroundMode::Image;
    CHECK(vc::compose(source.view(), options, &mask, &image, {}, output.output()) == vc::Status::Applied);
    constexpr uint8_t golden[9] = {25,50,50,75,100,100,75,100,100};
    for (int y = 0; y < 3; ++y) CHECK(std::equal(golden + y * 3, golden + y * 3 + 3, output.y.data() + 1 + y * output.ys));
    for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
        CHECK(output.u[1 + y * output.us + x] == 80 && output.v[1 + y * output.vs + x] == 180);
    }
    CHECK(asset.y == before.y && asset.u == before.u && asset.v == before.v && output.guards());
    image.pixels.range = vc::Range::Full;
    CHECK(vc::compose(source.view(), options, &mask, &image, {}, output.output()) == vc::Status::Concealed);
    CHECK(visible_color(output, 57, 128, 128));
    image.pixels = asset.view();
    image.pixels.width = 1921;
    CHECK(!vc::valid_image(image));
    CHECK(vc::compose(source.view(), options, &mask, &image, {}, output.output()) == vc::Status::Concealed);
    // Aspect-cover must crop the middle of a rectangular asset, rather than
    // stretching its outer rows/columns into a differently shaped source.
    for (const bool portrait : {false, true}) {
        Pixels canvas(portrait ? 3 : 5, portrait ? 5 : 3);
        Pixels covered(canvas.width, canvas.height);
        Pixels rectangle(portrait ? 4 : 2, portrait ? 2 : 4);
        rectangle.fill(0, 80, 180);
        for (int y = 0; y < rectangle.height; ++y) for (int x = 0; x < rectangle.width; ++x) {
            rectangle.y[1 + y * rectangle.ys + x] = 10 + 50 * (portrait ? x : y) + 5 * (portrait ? y : x);
        }
        vc::StagedImageView rectangular_image{rectangle.view()};
        auto canvas_mask = constant_mask(background, canvas.width, canvas.height);
        CHECK(vc::compose(canvas.view(), options, &canvas_mask, &rectangular_image, {}, covered.output()) == vc::Status::Applied);
        constexpr int crop_indices[3] = {1,2,2};
        constexpr int expanded_indices[5] = {0,0,1,1,1};
        for (int y = 0; y < canvas.height; ++y) for (int x = 0; x < canvas.width; ++x) {
            const int cropped_axis = crop_indices[portrait ? x : y];
            const int expanded_axis = expanded_indices[portrait ? y : x];
            CHECK(covered.y[1 + y * covered.ys + x] == 10 + 50 * cropped_axis + 5 * expanded_axis);
        }
        CHECK(covered.guards() && rectangle.guards());
    }
    Pixels landscape(6, 3);
    Pixels cropped(6, 3);
    landscape.fill(0, 80, 180);
    for (int y = 0; y < 3; ++y) for (int x = 0; x < 6; ++x) landscape.y[1 + y * landscape.ys + x] = 10 * y + x;
    options = {};
    options.roi.scale = vc::kMinFramingScale;
    CHECK(vc::compose(landscape.view(), options, nullptr, nullptr, {}, cropped.output()) == vc::Status::Applied);
    constexpr uint8_t crop_x[6] = {1,2,2,3,4,4};
    for (int y = 0; y < 3; ++y) for (int x = 0; x < 6; ++x) CHECK(cropped.y[1 + y * cropped.ys + x] == 10 * y + crop_x[x]);
    CHECK(cropped.guards());
    return true;
}

bool upright_mask_and_image_rotation() {
    Pixels source(3, 2), output(3, 2);
    source.fill(111, 128, 128);
    constexpr std::array<int, 4> rotations{0,90,180,270};
    constexpr std::array<int, 4> visible_x{2,0,0,2}, visible_y{0,0,1,1};
    for (size_t i = 0; i < rotations.size(); ++i) {
        const bool swapped = rotations[i] == 90 || rotations[i] == 270;
        const int mw = swapped ? 2 : 3, mh = swapped ? 3 : 2;
        std::vector<uint8_t> confidence(size_t(mw) * mh, 0);
        confidence[size_t(mw - 1)] = 255;
        vc::MaskView mask{{confidence, mw}, mw, mh, 3, 2, {0,0,mw,mh}, true, rotations[i]};
        vc::Options options; options.background = vc::BackgroundMode::Solid; options.rotation = rotations[i];
        CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Applied);
        for (int y = 0; y < 2; ++y) for (int x = 0; x < 3; ++x)
            CHECK(output.y[1 + y * output.ys + x] == (x == visible_x[i] && y == visible_y[i] ? 111 : 16));
        const auto bounds = vc::person_bounds(mask);
        CHECK(bounds && std::abs(bounds->left - visible_x[i] / 3.0) < 1e-12 &&
            std::abs(bounds->right - (visible_x[i] + 1) / 3.0) < 1e-12 &&
            std::abs(bounds->top - visible_y[i] / 2.0) < 1e-12 &&
            std::abs(bounds->bottom - (visible_y[i] + 1) / 2.0) < 1e-12);
        options.rotation = (rotations[i] + 90) % 360;
        CHECK(vc::compose(source.view(), options, &mask, nullptr, {}, output.output()) == vc::Status::Concealed);
        CHECK(visible_color(output,16,128,128) && output.guards());
        mask.rotation = 45; CHECK(!vc::valid_mask(mask,3,2) && !vc::person_bounds(mask));
    }
    Pixels canvas(4,4), image(4,4), rendered(4,4);
    canvas.fill(111,128,128); image.fill(0,128,128);
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) image.y[1+y*image.ys+x]=20+30*y+3*x;
    vc::StagedImageView staged{image.view()};
    std::array<uint8_t,16> confidence{};
    for (int rotation : rotations) {
        vc::MaskView mask{{confidence,4},4,4,4,4,{0,0,4,4},true,rotation};
        vc::Options options; options.background=vc::BackgroundMode::Image; options.rotation=rotation;
        CHECK(vc::compose(canvas.view(),options,&mask,&staged,{},rendered.output())==vc::Status::Applied);
        for (int y=0;y<4;++y) for(int x=0;x<4;++x) {
            int ux=x,uy=y;
            if(rotation==90){ux=3-y;uy=x;}
            else if(rotation==180){ux=3-x;uy=3-y;}
            else if(rotation==270){ux=y;uy=3-x;}
            CHECK(rendered.y[1+y*rendered.ys+x]==20+30*uy+3*ux);
        }
        CHECK(rendered.guards() && image.guards());
    }
    return true;
}

bool conservative_framing() {
    vc::FramingState state;
    const vc::PersonBounds stationary{0.3,0.3,0.4,0.5};
    const auto contains = [](const vc::Roi& roi, const vc::PersonBounds& bounds) {
        return roi.center_x - roi.scale / 2 <= bounds.left && roi.center_x + roi.scale / 2 >= bounds.right &&
            roi.center_y - roi.scale / 2 <= bounds.top && roi.center_y + roi.scale / 2 >= bounds.bottom;
    };
    const auto first = vc::update_framing(&state, stationary, 33);
    CHECK(first.scale < 1 && first.scale > vc::kMinFramingScale && contains(first, stationary));
    for (int frame = 0; frame < 120; ++frame) {
        const auto result = vc::update_framing(&state, stationary, 33);
        CHECK(result.scale >= vc::kMinFramingScale && result.scale <= 1 && contains(result, stationary));
    }
    CHECK(state.roi.scale < 0.667);
    const vc::PersonBounds newcomer{0.85,0.8,0.98,0.95};
    CHECK(contains(vc::update_framing(&state, newcomer, 1), newcomer));
    const vc::PersonBounds group{0.02,0.2,0.98,0.7};
    CHECK(contains(vc::update_framing(&state, group, 1), group));
    CHECK(state.roi.scale == 1 && state.roi.center_x == 0.5 && state.roi.center_y == 0.5);
    for (int frame = 0; frame < 80; ++frame) vc::update_framing(&state, stationary, 100);
    const double previous_scale = state.roi.scale;
    const auto lost = vc::update_framing(&state, std::nullopt, 33);
    CHECK(lost.scale > previous_scale && lost.scale < 1);
    const auto unchanged = vc::update_framing(&state, std::nullopt, std::numeric_limits<double>::quiet_NaN());
    CHECK(unchanged.scale == lost.scale && unchanged.center_x == lost.center_x && unchanged.center_y == lost.center_y);
    state.roi.center_x = std::numeric_limits<double>::infinity();
    CHECK(vc::update_framing(&state, std::nullopt, 0).scale == 1);
    CHECK(vc::update_framing(nullptr, stationary, 33).scale == 1);
    return true;
}

int main() {
    if (!concealment_and_validation() || !letterbox_blend_and_bounds() || !bounded_blur() ||
            !staged_image_and_crop() || !upright_mask_and_image_rotation() || !conservative_framing()) return 1;
    std::puts("video compositor goldens passed");
    return 0;
}
