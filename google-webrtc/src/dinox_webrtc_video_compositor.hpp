#ifndef DINOX_WEBRTC_VIDEO_COMPOSITOR_HPP
#define DINOX_WEBRTC_VIDEO_COMPOSITOR_HPP

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace dinox::video_compositor {

// Independent pixel primitives. No WebRTC, model, transport, file I/O, owned
// frame, thread or runtime-capability dependency belongs in this component.
constexpr int kMaxFrameSide = 4096;
constexpr uint64_t kMaxFramePixels = UINT64_C(8847360);
constexpr size_t kMaxFrameBackingBytes = 16 * 1024 * 1024;
constexpr int kMaxMaskWidth = 256;
constexpr int kMaxMaskHeight = 144;
constexpr size_t kMaxMaskBackingBytes = 64 * 1024;
constexpr int kMaxImageSide = 1920;
constexpr uint64_t kMaxImagePixels = UINT64_C(1920) * 1080;
constexpr size_t kMaxImageBackingBytes = 4 * 1024 * 1024;
constexpr int kMaxBlurRadius = 12;
constexpr double kMinFramingScale = 2.0 / 3.0;
constexpr uint32_t kNeutralConcealmentRgb = UINT32_C(0x303030);

enum class Range { Limited, Full };
enum class Matrix { Bt601, Bt709 };
enum class BackgroundMode { None, Blur, Solid, Image };

struct Plane {
    std::span<const uint8_t> bytes;
    int stride = 0;
};

struct MutablePlane {
    std::span<uint8_t> bytes;
    int stride = 0;
};

struct I420View {
    int width = 0;
    int height = 0;
    Range range = Range::Limited;
    Matrix matrix = Matrix::Bt601;
    Plane y;
    Plane u;
    Plane v;
};

struct I420Output {
    int width = 0;
    int height = 0;
    Range range = Range::Limited;
    Matrix matrix = Matrix::Bt601;
    MutablePlane y;
    MutablePlane u;
    MutablePlane v;
};

// Pixel-edge coordinates inside the mask, including the exact letterbox
// rectangle used by preprocessing. Padding outside this rectangle is ignored.
struct ContentRect {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
};

struct MaskView {
    Plane confidence;
    int width = 0;
    int height = 0;
    int source_width = 0;
    int source_height = 0;
    ContentRect content;
    // The controller must fence call/source/config/transform identities and
    // capture age <=500ms before setting true. Default and stale results hide
    // the entire camera frame when any background mode is selected.
    bool valid = false;
    // Clockwise metadata rotation applied by preprocessing, not to source pixels.
    int rotation = 0;
};

// Already decoded/staged, immutable pixels borrowed only for compose(). The
// registry owns IDs, leases, decode limits and preparation to the frame's
// range/matrix. This API neither accepts nor resolves filesystem paths.
struct StagedImageView {
    I420View pixels;
};

// A single normalized scale preserves source aspect ratio. Scale>=2/3 keeps
// zoom<=1.5. Coordinates address the unrotated, unmirrored source frame.
struct Roi {
    double center_x = 0.5;
    double center_y = 0.5;
    double scale = 1.0;
};

struct Options {
    BackgroundMode background = BackgroundMode::None;
    int blur_strength = 0;
    uint32_t solid_rgb = 0;
    Roi roi;
    int rotation = 0;
};

struct ScratchRequirements {
    // At 4096 pixels/radius12: 216KiB total; reused sequentially for Y/U/V.
    size_t row_samples = 0;     // uint16_t horizontal-sum ring storage
    size_t column_samples = 0;  // uint32_t vertical sums
};

struct Scratch {
    std::span<uint16_t> rows;
    std::span<uint32_t> columns;
};

enum class Status {
    Passthrough,     // original pixels; output need not be populated
    Applied,         // populated final output
    Concealed,       // populated opaque solid output; no raw-camera fallback
    InvalidBuffers, // output cannot safely be written: drop/mute, never raw
};

bool valid_image(const StagedImageView& image);
bool valid_mask(const MaskView& mask, int source_width, int source_height);
ScratchRequirements blur_scratch_requirements(int source_width, int blur_strength);

// No allocations or retained views. Scratch/output are supplied by the owner.
// Source/output/asset/mask/scratch backing ranges must not overlap. Background
// requests populate solid concealment first, retaining it on mask/image/scratch
// failures. An invalid or aliased destination returns InvalidBuffers untouched.
// Camera/image sampling uses nearest pixel centres; mask alpha is bilinear
// inside contentRect, rounded to a byte. Chroma blends use the rounded average
// of the actual available 2x2 luma alphas, including odd edges. Blur strength
// 0..100 gives radius1..12, using ceil(radius/2) on the chroma planes.
// The future native adapter copies metadata, clears updateRect, and publishes
// this same final output once before preview/MUJI fan-out. Runtime background
// capabilities remain disabled until inference and privacy fallback integrate.
Status compose(
    const I420View& source,
    const Options& options,
    const MaskView* mask,
    const StagedImageView* image,
    Scratch scratch,
    I420Output output);

struct PersonBounds {
    double left = 0;
    double top = 0;
    double right = 1;
    double bottom = 1;
};

// Union of every confident content pixel, inverse-mapped through the exact
// letterbox. Empty, invalid and unfenced masks yield no tracked bounds.
std::optional<PersonBounds> person_bounds(const MaskView& mask, uint8_t threshold = 128);

struct FramingState {
    Roi roi;
};

// Separate state; the controller resets it on call/source/transform changes.
// dt is a bounded monotonic frame interval, not a wall-clock timer. A lost
// target expands smoothly to full view; new detected people may expand the
// crop immediately to avoid excluding them while the centre moves smoothly.
Roi update_framing(
    FramingState* state,
    const std::optional<PersonBounds>& people,
    double elapsed_ms);

}  // namespace dinox::video_compositor

#endif
