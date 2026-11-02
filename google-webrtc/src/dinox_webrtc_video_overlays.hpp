// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
#ifndef DINOX_WEBRTC_VIDEO_OVERLAYS_HPP
#define DINOX_WEBRTC_VIDEO_OVERLAYS_HPP

#include <array>
#include <cstddef>
#include <cstdint>

namespace dinox::video_overlays {

// SDK-free, original procedural artwork. No models, textures, allocation,
// timers, I/O or call state. The caller owns inference and publication fences.
constexpr uint64_t kMaxFaceAgeNs = UINT64_C(500000000);
constexpr size_t kMaxParticles = 32;

enum class Glasses : uint32_t { None, Sunglasses, Round, Rectangular };
enum class Hat : uint32_t { None, Cap, Cowboy, Top };
enum class Beard : uint32_t { None, Moustache, Goatee, Full };
enum class Accessory : uint32_t { None, Puppy, KaraokeMic };
enum class Scene : uint32_t { None, Fireworks, Confetti, Stars, Football };
enum class LumaRange { Full, Limited };

struct Options {
    Glasses glasses = Glasses::None;
    Hat hat = Hat::None;
    Beard beard = Beard::None;
    Accessory accessory = Accessory::None;
    Scene scene = Scene::None;
    bool touch_up = false;
    bool low_light = false;
};

struct Point { double x = 0; double y = 0; };
struct Bounds { double left = 0; double top = 0; double right = 0; double bottom = 0; };

struct Face {
    double score = 0;
    Bounds bounds;
    // Native BlazeFace order: RIGHT_EYE, LEFT_EYE, NOSE_TIP, MOUTH_CENTER,
    // RIGHT_EAR_TRAGION, LEFT_EAR_TRAGION. After inverse preprocessing these
    // address normalized source coordinates, including unclamped partial boxes.
    std::array<Point, 6> points{};
    uint64_t captured_ns = 0; // monotonic capture clock, independent of media PTS
    bool valid = false; // owner has fenced call/source/config/transform identity
};

struct Frame {
    int width = 0;
    int height = 0;
    uint64_t frame_id = 0;
    uint64_t captured_ns = 0; // same monotonic clock as Face::captured_ns
    uint64_t now_ns = 0; // owner-provided monotonic current time
    // Presentation clockwise rotation: 0/90/180/270. Face coordinates already
    // address raw pixels; only scene gravity/artwork is projected from upright.
    int rotation = 0;
};

struct LumaStats {
    uint32_t sample_count = 0; // caller computed; 1..4096, no extra model
    uint32_t mean_full_range = 0; // 0..255
};

struct Rgba {
    // Premultiplied RGBA8; r/g/b<=a. Transparent is all zero.
    uint8_t r = 0, g = 0, b = 0, a = 0;
    bool operator==(const Rgba&) const = default;
};

enum class ParticleShape { Spark, Rectangle, Star, Football };
struct Particle {
    ParticleShape shape = ParticleShape::Spark;
    Point center;
    Point axis{1, 0};
    double half_width = 0;
    double half_height = 0;
    double left = 0, top = 0, right = 0, bottom = 0;
    uint32_t rgb = 0;
    uint8_t alpha = 0;
};

struct Prepared {
    // Immutable after prepare(), borrowed by every pixel query for this frame.
    Options options;
    int width = 0, height = 0;
    bool valid = false;
    bool active = false;
    bool face_usable = false;
    Point eye_center;
    Point eye_axis{1, 0};
    double eye_distance = 0;
    Point nose_local;
    Point mouth_local;
    Bounds face_artwork_bounds;
    std::array<Particle, kMaxParticles> particles{};
    size_t particle_count = 0;
    uint16_t low_light_gain_q8 = 256;
};

bool valid_options(const Options& options);
bool is_neutral(const Options& options);
Prepared prepare(const Options& options, Frame frame,
    const Face* face = nullptr, LumaStats luma = {});

// Coordinates are unrotated source pixels. Output clips at the real source
// boundary; no raw or private-background pixels are sampled by this helper.
Rgba rgba_pixel(const Prepared& context, int x, int y);

// Borrowed scalar candidates for exactly one raw-pixel row. The caller may
// skip pixels outside [begin,end); unchanged transparent pixels need no YUV
// conversion. No image, user state, allocation or retained lookup is involved.
struct Row {
    int y = 0;
    int begin = 0, end = 0;
    std::array<uint8_t, kMaxParticles> particles{};
    size_t particle_count = 0;
    bool face_possible = false;
    bool valid = false;
};
Row prepare_row(const Prepared& context, int y);
Rgba rgba_row_pixel(const Prepared& context, const Row& row, int x);

// Conservative smoothing weight <=32/255, not a smoothing implementation.
// The future adapter supplies a bounded radius-one blur and preserves details.
uint8_t touch_up_weight(const Prepared& context, int x, int y);

// Gain only, around range-specific black with clipping to legal luma white.
// Inactive gain is exact identity, including bytes outside the nominal range.
uint8_t low_light_luma(const Prepared& context, uint8_t luma, LumaRange range);

} // namespace dinox::video_overlays
#endif
