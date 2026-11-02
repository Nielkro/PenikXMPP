#include "dinox_webrtc_video_compositor.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace dinox::video_compositor {
namespace {

int rounded_divide(int64_t numerator, int64_t denominator) {
    return static_cast<int>(numerator >= 0 ?
        (numerator + denominator / 2) / denominator :
        -((-numerator + denominator / 2) / denominator));
}

bool valid_rotation(int rotation) {
    return rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270;
}
std::array<double, 2> upright_point(double x, double y, int rotation) {
    switch (rotation) {
        case 90: return {1 - y, x};
        case 180: return {1 - x, 1 - y};
        case 270: return {y, 1 - x};
        default: return {x, y};
    }
}
std::array<double, 2> raw_point(double x, double y, int rotation) {
    return upright_point(x, y, (360 - rotation) % 360);
}

bool valid_format(Range range, Matrix matrix) {
    return (range == Range::Limited || range == Range::Full) &&
        (matrix == Matrix::Bt601 || matrix == Matrix::Bt709);
}

struct AddressRange {
    uintptr_t begin = 0;
    uintptr_t end = 0;
    bool valid = true;
};

template<class T> AddressRange address_range(std::span<T> bytes) {
    if (bytes.empty()) return {};
    const uintptr_t begin = reinterpret_cast<uintptr_t>(bytes.data());
    if (begin == 0 || begin % alignof(T) != 0 ||
            bytes.size() > std::numeric_limits<size_t>::max() / sizeof(T)) {
        return {0, 0, false};
    }
    const size_t size = bytes.size() * sizeof(T);
    if (size > std::numeric_limits<uintptr_t>::max() - begin) return {0, 0, false};
    return {begin, begin + size, true};
}

bool overlaps(const AddressRange& first, const AddressRange& second) {
    return first.begin < second.end && second.begin < first.end;
}

template<class T> bool valid_plane(std::span<T> bytes, int stride, int width, int height) {
    if (width <= 0 || height <= 0 || stride < width || !address_range(bytes).valid) return false;
    const uint64_t required = static_cast<uint64_t>(height - 1) * stride + width;
    return required <= bytes.size();
}

template<class T> bool valid_pixels(const T& pixels, int side, uint64_t max_pixels, size_t backing) {
    if (pixels.width <= 0 || pixels.height <= 0 || pixels.width > side || pixels.height > side ||
            static_cast<uint64_t>(pixels.width) * pixels.height > max_pixels ||
            !valid_format(pixels.range, pixels.matrix)) return false;
    const auto y_size = pixels.y.bytes.size();
    const auto u_size = pixels.u.bytes.size();
    const auto v_size = pixels.v.bytes.size();
    if (y_size > backing || u_size > backing - y_size || v_size > backing - y_size - u_size) return false;
    const int cw = (pixels.width + 1) / 2;
    const int ch = (pixels.height + 1) / 2;
    return valid_plane(pixels.y.bytes, pixels.y.stride, pixels.width, pixels.height) &&
        valid_plane(pixels.u.bytes, pixels.u.stride, cw, ch) &&
        valid_plane(pixels.v.bytes, pixels.v.stride, cw, ch);
}

bool disjoint_buffers(const I420View& source, const MaskView* mask,
        const StagedImageView* image, Scratch scratch, const I420Output& output) {
    const std::array<AddressRange, 7> reads = {address_range(source.y.bytes),
        address_range(source.u.bytes), address_range(source.v.bytes),
        mask ? address_range(mask->confidence.bytes) : AddressRange{},
        image ? address_range(image->pixels.y.bytes) : AddressRange{},
        image ? address_range(image->pixels.u.bytes) : AddressRange{},
        image ? address_range(image->pixels.v.bytes) : AddressRange{}};
    const std::array<AddressRange, 5> writes = {address_range(output.y.bytes),
        address_range(output.u.bytes), address_range(output.v.bytes),
        address_range(scratch.rows), address_range(scratch.columns)};
    for (const auto& range : reads) if (!range.valid) return false;
    for (size_t i = 0; i < writes.size(); ++i) {
        if (!writes[i].valid) return false;
        for (const auto& read : reads) if (overlaps(writes[i], read)) return false;
        for (size_t j = 0; j < i; ++j) if (overlaps(writes[i], writes[j])) return false;
    }
    return true;
}

bool valid_roi(const Roi& roi) {
    return std::isfinite(roi.center_x) && std::isfinite(roi.center_y) && std::isfinite(roi.scale) &&
        roi.scale >= kMinFramingScale && roi.scale <= 1 &&
        roi.center_x >= roi.scale / 2 && roi.center_x <= 1 - roi.scale / 2 &&
        roi.center_y >= roi.scale / 2 && roi.center_y <= 1 - roi.scale / 2;
}

bool valid_options(const Options& options) {
    if (!valid_roi(options.roi)) return false;
    switch (options.background) {
        case BackgroundMode::None:
        case BackgroundMode::Image:
            return options.blur_strength == 0 && options.solid_rgb == 0;
        case BackgroundMode::Blur:
            return options.blur_strength >= 0 && options.blur_strength <= 100 && options.solid_rgb == 0;
        case BackgroundMode::Solid:
            return options.blur_strength == 0 && options.solid_rgb <= UINT32_C(0xffffff);
    }
    return false;
}

std::array<uint8_t, 3> solid_yuv(uint32_t rgb, Range range, Matrix matrix) {
    const int r = (rgb >> 16) & 255;
    const int g = (rgb >> 8) & 255;
    const int b = rgb & 255;
    const int kr = matrix == Matrix::Bt709 ? 2126 : 2990;
    const int kb = matrix == Matrix::Bt709 ? 722 : 1140;
    const int64_t weighted_y = kr * r + (10000 - kr - kb) * g + kb * b;
    const int excursion = range == Range::Full ? 255 : 224;
    const int y = range == Range::Full ? rounded_divide(weighted_y, 10000) :
        16 + rounded_divide(weighted_y * 219, INT64_C(255) * 10000);
    const int u = 128 + rounded_divide((10000 * b - weighted_y) * excursion,
        INT64_C(2) * 255 * (10000 - kb));
    const int v = 128 + rounded_divide((10000 * r - weighted_y) * excursion,
        INT64_C(2) * 255 * (10000 - kr));
    return {static_cast<uint8_t>(std::clamp(y, 0, 255)),
        static_cast<uint8_t>(std::clamp(u, 0, 255)), static_cast<uint8_t>(std::clamp(v, 0, 255))};
}

void fill_solid(const I420Output& output, const std::array<uint8_t, 3>& color) {
    for (int y = 0; y < output.height; ++y) {
        std::fill_n(output.y.bytes.data() + y * output.y.stride, output.width, color[0]);
    }
    for (int y = 0; y < (output.height + 1) / 2; ++y) {
        std::fill_n(output.u.bytes.data() + y * output.u.stride, (output.width + 1) / 2, color[1]);
        std::fill_n(output.v.bytes.data() + y * output.v.stride, (output.width + 1) / 2, color[2]);
    }
}

double source_coordinate(int output_pixel, int dimension, double center, double scale) {
    return (center - scale / 2 + (output_pixel + 0.5) * scale / dimension) * dimension - 0.5;
}

int nearest_pixel(double coordinate, int dimension) {
    return std::clamp(static_cast<int>(std::floor(coordinate + 0.5)), 0, dimension - 1);
}

struct MaskAxis {
    int first;
    int second;
    double fraction;
};

MaskAxis mask_axis(double coordinate, int start, int size) {
    const double sample = std::clamp(start + coordinate - 0.5,
        static_cast<double>(start), static_cast<double>(start + size - 1));
    const int first = static_cast<int>(std::floor(sample));
    return {first, std::min(first + 1, start + size - 1), sample - first};
}

// These are per-invocation scalar coordinate tables, never pixels or retained
// camera/model data. Exact old operation order is preserved, including the
// zero-rotation letterbox formula. Maximum stack storage is 224 KiB.
struct Sampling {
    std::array<double, kMaxFrameSide> source_x;
    std::array<double, kMaxFrameSide> source_y;
    std::array<int, kMaxFrameSide> nearest_x;
    std::array<int, kMaxFrameSide> nearest_y;
    std::array<MaskAxis, kMaxFrameSide> mask_from_x;
    std::array<MaskAxis, kMaxFrameSide> mask_from_y;
    bool swapped;

    Sampling(const I420View& source, const Options& options, const MaskView* mask)
        : swapped(mask && (mask->rotation == 90 || mask->rotation == 270)) {
        for (int x = 0; x < source.width; ++x) {
            const double sx = source_coordinate(x, source.width, options.roi.center_x, options.roi.scale);
            source_x[x] = sx;
            nearest_x[x] = nearest_pixel(sx, source.width);
            if (!mask) continue;
            const double normalized = (sx + 0.5) / source.width;
            if (swapped) {
                mask_from_x[x] = mask_axis((mask->rotation == 90 ? normalized : 1 - normalized) *
                    mask->content.height, mask->content.y, mask->content.height);
            } else {
                const double coordinate = mask->rotation == 0 ?
                    (sx + 0.5) * mask->content.width / source.width : (1 - normalized) * mask->content.width;
                mask_from_x[x] = mask_axis(coordinate, mask->content.x, mask->content.width);
            }
        }
        for (int y = 0; y < source.height; ++y) {
            const double sy = source_coordinate(y, source.height, options.roi.center_y, options.roi.scale);
            source_y[y] = sy;
            nearest_y[y] = nearest_pixel(sy, source.height);
            if (!mask) continue;
            const double normalized = (sy + 0.5) / source.height;
            if (swapped) {
                mask_from_y[y] = mask_axis((mask->rotation == 90 ? 1 - normalized : normalized) *
                    mask->content.width, mask->content.x, mask->content.width);
            } else {
                const double coordinate = mask->rotation == 0 ?
                    (sy + 0.5) * mask->content.height / source.height : (1 - normalized) * mask->content.height;
                mask_from_y[y] = mask_axis(coordinate, mask->content.y, mask->content.height);
            }
        }
    }
};

template<bool Swapped> int alpha_at(const MaskView& mask, const Sampling& sampling, int x, int y) {
    const MaskAxis& mx = Swapped ? sampling.mask_from_y[y] : sampling.mask_from_x[x];
    const MaskAxis& my = Swapped ? sampling.mask_from_x[x] : sampling.mask_from_y[y];
    const int x0 = mx.first, x1 = mx.second;
    const int y0 = my.first, y1 = my.second;
    const uint8_t* data = mask.confidence.bytes.data();
    const uint8_t top_left = data[y0 * mask.confidence.stride + x0];
    const uint8_t top_right = data[y0 * mask.confidence.stride + x1];
    const uint8_t bottom_left = data[y1 * mask.confidence.stride + x0];
    const uint8_t bottom_right = data[y1 * mask.confidence.stride + x1];
    // mask_axis() clamps each finite fraction to [0,1]. Equal byte corners
    // interpolate to that byte after rounding; double error is far below 0.5.
    if (top_left == top_right && top_left == bottom_left && top_left == bottom_right)
        return top_left;
    const double fx = mx.fraction, fy = my.fraction;
    const double top = top_left * (1 - fx) + top_right * fx;
    const double bottom = bottom_left * (1 - fx) + bottom_right * fx;
    return std::clamp(static_cast<int>(std::floor(top * (1 - fy) + bottom * fy + 0.5)), 0, 255);
}

int blend(int foreground, int background, int alpha) {
    return rounded_divide(foreground * alpha + background * (255 - alpha), 255);
}

int blur_radius(int strength) {
    return 1 + rounded_divide(11 * strength, 100);
}

// Exact edge-clamped square box: horizontal sums are retained in a bounded
// row ring and vertical columns are updated once per source row. O(pixels),
// with no radius-squared work, allocations or second full-frame image.
// Private checked boundary: compose() requires source-width*(2*r+1) uint16
// samples and source-width uint32 columns before any blur access here.
// render_plane() supplies either that storage or disjoint fused-chroma slices
// of width*(2*radius+1) samples and width columns. Thus every used blur has
// rows.size()>=width_*(2*radius_+1), columns.size()>=width_, width_>=1,
// height_>=1 and 1<=radius_<=12. prepare() clamps rows into [0,height_), and
// nearest_pixel() clamps every final column into [0,width_).
class BoxBlur {
 public:
    BoxBlur(Plane plane, int width, int height, int radius, Scratch scratch)
        : plane_(plane), width_(width), height_(height), radius_(radius),
          kernel_(2 * radius + 1), area_(kernel_ * kernel_),
          half_area_(static_cast<uint32_t>(area_ / 2)),
          reciprocal_(((UINT64_C(1) << 32) + area_ - 1) / area_),
          scratch_(scratch) { rows_.fill(-1); }

    void advance_to_row(int y) {
        // compose() has checked this private object's scratch extents and
        // disjointness. These width-bounded column loops need no repeated
        // span indexing checks and can use the same exact integer sums.
        uint32_t* const columns = scratch_.columns.data();
        if (center_ < 0) {
            std::fill_n(columns, width_, 0);
            for (int dy = -radius_; dy <= radius_; ++dy) {
                const auto* row = prepare(std::clamp(dy, 0, height_ - 1));
                for (int column = 0; column < width_; ++column) columns[column] += row[column];
            }
            center_ = 0;
        }
        while (center_ < y) {
            const auto* old_row = prepare(std::max(center_ - radius_, 0));
            for (int column = 0; column < width_; ++column) columns[column] -= old_row[column];
            const auto* new_row = prepare(std::min(center_ + radius_ + 1, height_ - 1));
            for (int column = 0; column < width_; ++column) columns[column] += new_row[column];
            ++center_;
        }
    }

    int sample(int x, int y) {
        advance_to_row(y);
        return sample_prepared(x);
    }

    // x was clamped by nearest_pixel(); advance_to_row() has established the
    // immutable column sums for this output row. No allocations or new image.
    int sample_prepared(int x) const {
        // Exact rounded unsigned division for this bounded byte box, using a
        // prepared reciprocal instead of one integer division per pixel.
        // n<=255*625+625/2 and n*625<2^32, so ceil(2^32/area)
        // cannot move a nonintegral quotient across the next integer.
        const uint64_t numerator = static_cast<uint64_t>(scratch_.columns.data()[x]) + half_area_;
        return static_cast<int>((numerator * reciprocal_) >> 32);
    }

 private:
    const uint16_t* prepare(int y) {
        const int slot = y % kernel_;
        uint16_t* sums = scratch_.rows.data() + slot * width_;
        if (rows_[slot] == y) return sums;
        const uint8_t* input = plane_.bytes.data() + y * plane_.stride;
        int sum = 0;
        for (int dx = -radius_; dx <= radius_; ++dx) sum += input[std::clamp(dx, 0, width_ - 1)];
        for (int x = 0; x < width_; ++x) {
            sums[x] = static_cast<uint16_t>(sum);
            sum += input[std::min(x + radius_ + 1, width_ - 1)] - input[std::max(x - radius_, 0)];
        }
        rows_[slot] = y;
        return sums;
    }

    Plane plane_;
    int width_;
    int height_;
    int radius_;
    int kernel_;
    int area_;
    uint32_t half_area_;
    uint64_t reciprocal_;
    Scratch scratch_;
    std::array<int, 2 * kMaxBlurRadius + 1> rows_;
    int center_ = -1;
};

// A staged background covers the source canvas without changing its aspect.
double image_coordinate(double source_pixel, int source_dimension, int image_dimension, double cover) {
    return (source_pixel + 0.5 + (image_dimension * cover - source_dimension) / 2) / cover - 0.5;
}

struct ImageSampling {
    std::array<int, kMaxFrameSide> luma_from_x;
    std::array<int, kMaxFrameSide> luma_from_y;
    std::array<std::array<int,2>, kMaxFrameSide / 2> chroma_from_x;
    std::array<std::array<int,2>, kMaxFrameSide / 2> chroma_from_y;

    ImageSampling(const I420View& source, const Options& options, const Sampling& sampling,
                  const StagedImageView* image) {
        if (!image) return;
        const bool swapped=options.rotation==90 || options.rotation==270;
        const double cover=std::max(static_cast<double>(swapped ? source.height : source.width) / image->pixels.width,
            static_cast<double>(swapped ? source.width : source.height) / image->pixels.height);
        const auto coordinate = [&](double pixel,int dimension,bool from_x,bool chroma) {
            const int image_dimension=(from_x != swapped) ? image->pixels.width : image->pixels.height;
            double display_pixel=pixel;
            if (options.rotation) {
                double normalized=(pixel+0.5)/dimension;
                const bool inverse=options.rotation==180 || (from_x ? options.rotation==270 : options.rotation==90);
                if (inverse) normalized=1-normalized;
                display_pixel=normalized*dimension-0.5;
            }
            const double mapped=image_coordinate(display_pixel,dimension,image_dimension,cover);
            return nearest_pixel(chroma ? (mapped-0.5)/2 : mapped,
                chroma ? (image_dimension+1)/2 : image_dimension);
        };
        for (int x=0;x<source.width;++x) luma_from_x[x]=coordinate(sampling.source_x[x],source.width,true,false);
        for (int y=0;y<source.height;++y) luma_from_y[y]=coordinate(sampling.source_y[y],source.height,false,false);
        // Average the exact available source-coordinate samples in the old
        // dx/dy order. The two variants cover an odd final opposite axis.
        for (int x=0;x<(source.width+1)/2;++x) for (int rows=1;rows<=2;++rows) {
            double sum=0;int count=0;
            for (int dy=0;dy<rows;++dy) for (int dx=0;dx<2 && 2*x+dx<source.width;++dx) {
                sum+=sampling.source_x[2*x+dx];++count;
            }
            chroma_from_x[x][rows-1]=coordinate(sum/count,source.width,true,true);
        }
        for (int y=0;y<(source.height+1)/2;++y) for (int columns=1;columns<=2;++columns) {
            double sum=0;int count=0;
            for (int dy=0;dy<2 && 2*y+dy<source.height;++dy) for (int dx=0;dx<columns;++dx) {
                sum+=sampling.source_y[2*y+dy];++count;
            }
            chroma_from_y[y][columns-1]=coordinate(sum/count,source.height,false,true);
        }
    }
};

template<bool Swapped, bool Chroma, int Channels = 1> void render_plane(const I420View& source, const Options& options, const MaskView* mask,
        const StagedImageView* image, Scratch scratch, const I420Output& output,
        const Sampling& sampling, const ImageSampling& image_sampling,
        int component, int solid, int second_solid = 0) {
    static_assert(Channels == 1 || (Channels == 2 && Chroma));
    constexpr bool chroma = Chroma;
    const int pw = chroma ? (source.width + 1) / 2 : source.width;
    const int ph = chroma ? (source.height + 1) / 2 : source.height;
    const Plane plane = component == 0 ? source.y : component == 1 ? source.u : source.v;
    const uint8_t* plane_data = plane.bytes.data();
    const MutablePlane destination = component == 0 ? output.y : component == 1 ? output.u : output.v;
    const Plane second_plane = source.v;
    const MutablePlane second_destination = output.v;
    const int radius = options.background == BackgroundMode::Blur ? blur_radius(options.blur_strength) : 1;
    const int plane_radius = chroma ? (radius + 1) / 2 : radius;
    Scratch first_scratch = scratch, second_scratch{};
    if constexpr (Channels == 2) {
        if (options.background == BackgroundMode::Blur) {
            // With even source width, two chroma row rings and column arrays
            // fit in the original luma scratch. Neither extra pixels nor an
            // allocation are introduced, and each blur has disjoint storage.
            const size_t rows = static_cast<size_t>(pw) * (2 * plane_radius + 1);
            first_scratch = {scratch.rows.first(rows), scratch.columns.first(pw)};
            second_scratch = {scratch.rows.subspan(rows, rows), scratch.columns.subspan(pw, pw)};
        }
    }
    BoxBlur blurred(plane, pw, ph, plane_radius, first_scratch);
    BoxBlur second_blurred(second_plane, pw, ph, plane_radius, second_scratch);
    Plane image_plane;
    if (image != nullptr) {
        image_plane = component == 0 ? image->pixels.y : component == 1 ? image->pixels.u : image->pixels.v;
    }
    for (int y = 0; y < ph; ++y) {
        uint8_t* row = destination.bytes.data() + y * destination.stride;
        uint8_t* second_row = nullptr;
        if constexpr (Channels == 2) second_row = second_destination.bytes.data() + y * second_destination.stride;
        double row_sy = 0;
        int row_py = 0;
        if constexpr (!Chroma) {
            row_sy = sampling.source_y[y]; row_py = sampling.nearest_y[y];
        } else if constexpr (Channels == 2) {
            // Even-width fused U/V has two real columns in every block. Its
            // original sy average is consequently identical across this row.
            const int y0 = 2 * y;
            const double ly0 = sampling.source_y[y0];
            if (y0 + 1 < source.height) {
                const double ly1 = sampling.source_y[y0 + 1];
                row_sy = ((((0.0 + ly0) + ly0) + ly1) + ly1) / 4;
            } else row_sy = ((0.0 + ly0) + ly0) / 2;
            row_py = nearest_pixel((row_sy - 0.5) / 2, ph);
        }
        if constexpr (!Chroma || Channels == 2) {
            if (options.background == BackgroundMode::Blur) {
                blurred.advance_to_row(row_py);
                if constexpr (Channels == 2) second_blurred.advance_to_row(row_py);
            }
        }
        for (int x = 0; x < pw; ++x) {
            double sx = 0, sy = 0;
            int alpha_sum = 0, count = 0;
            if constexpr (!Chroma) {
                sx = sampling.source_x[x]; sy = row_sy;
                if (mask) alpha_sum = alpha_at<Swapped>(*mask, sampling, x, y);
                count = 1;
            } else if constexpr (Channels == 2) {
                // This path is selected only for even source widths. Keep the
                // original accumulation order instead of an algebraic average,
                // so near-half-pixel coordinates and odd bottom edges agree.
                const int x0 = 2 * x, y0 = 2 * y;
                const double lx0 = sampling.source_x[x0], lx1 = sampling.source_x[x0 + 1];
                if (y0 + 1 < source.height) {
                    sx = (((0.0 + lx0) + lx1) + lx0) + lx1;
                    if (mask) alpha_sum = alpha_at<Swapped>(*mask, sampling, x0, y0) +
                        alpha_at<Swapped>(*mask, sampling, x0 + 1, y0) +
                        alpha_at<Swapped>(*mask, sampling, x0, y0 + 1) +
                        alpha_at<Swapped>(*mask, sampling, x0 + 1, y0 + 1);
                    count = 4; sx /= 4;
                } else {
                    sx = (0.0 + lx0) + lx1;
                    if (mask) alpha_sum = alpha_at<Swapped>(*mask, sampling, x0, y0) +
                        alpha_at<Swapped>(*mask, sampling, x0 + 1, y0);
                    count = 2; sx /= 2;
                }
                sy = row_sy;
            } else {
                for (int dy = 0; dy < 2 && 2 * y + dy < source.height; ++dy) {
                    for (int dx = 0; dx < 2 && 2 * x + dx < source.width; ++dx) {
                        const int source_x = 2 * x + dx;
                        const int source_y = 2 * y + dy;
                        sx += sampling.source_x[source_x];
                        sy += sampling.source_y[source_y];
                        if (mask != nullptr) alpha_sum += alpha_at<Swapped>(*mask, sampling, source_x, source_y);
                        ++count;
                    }
                }
                sx /= count;
                sy /= count;
            }
            const int px = Chroma ? nearest_pixel((sx - 0.5) / 2, pw) : sampling.nearest_x[x];
            const int py = (!Chroma || Channels == 2) ? row_py : nearest_pixel((sy - 0.5) / 2, ph);
            const int foreground = plane_data[py * plane.stride + px];
            const int second_foreground = Channels == 2 ? second_plane.bytes.data()[py * second_plane.stride + px] : 0;
            if (options.background == BackgroundMode::None) {
                row[x] = static_cast<uint8_t>(foreground);
                if constexpr (Channels == 2) second_row[x] = static_cast<uint8_t>(second_foreground);
                continue;
            }
            int background = solid;
            int second_background = second_solid;
            if (options.background == BackgroundMode::Blur) {
                if constexpr (!Chroma || Channels == 2) background = blurred.sample_prepared(px);
                else background = blurred.sample(px, py);
            }
            if constexpr (Channels == 2) {
                if (options.background == BackgroundMode::Blur) second_background = second_blurred.sample_prepared(px);
            }
            if (options.background == BackgroundMode::Image) {
                const int from_x = Chroma ? image_sampling.chroma_from_x[x][std::min(2,source.height-2*y)-1] : image_sampling.luma_from_x[x];
                const int from_y = Chroma ? image_sampling.chroma_from_y[y][std::min(2,source.width-2*x)-1] : image_sampling.luma_from_y[y];
                const int bx = Swapped ? from_y : from_x;
                const int by = Swapped ? from_x : from_y;
                background = image_plane.bytes.data()[by * image_plane.stride + bx];
                if constexpr (Channels == 2) second_background = image->pixels.v.bytes.data()[by * image->pixels.v.stride + bx];
            }
            const int alpha = rounded_divide(alpha_sum, count);
            row[x] = static_cast<uint8_t>(blend(foreground, background, alpha));
            if constexpr (Channels == 2) second_row[x] = static_cast<uint8_t>(blend(second_foreground, second_background, alpha));
        }
    }
}

bool valid_bounds(const PersonBounds& bounds) {
    return std::isfinite(bounds.left) && std::isfinite(bounds.top) &&
        std::isfinite(bounds.right) && std::isfinite(bounds.bottom) &&
        bounds.left >= 0 && bounds.top >= 0 && bounds.right <= 1 && bounds.bottom <= 1 &&
        bounds.left < bounds.right && bounds.top < bounds.bottom;
}

}  // namespace

bool valid_image(const StagedImageView& image) {
    return valid_pixels(image.pixels, kMaxImageSide, kMaxImagePixels, kMaxImageBackingBytes);
}

bool valid_mask(const MaskView& mask, int source_width, int source_height) {
    return mask.valid && valid_rotation(mask.rotation) && source_width > 0 && source_height > 0 && source_width <= kMaxFrameSide &&
        source_height <= kMaxFrameSide && static_cast<uint64_t>(source_width) * source_height <= kMaxFramePixels &&
        mask.source_width == source_width && mask.source_height == source_height &&
        mask.width > 0 && mask.height > 0 && mask.width <= kMaxMaskWidth && mask.height <= kMaxMaskHeight &&
        mask.content.x >= 0 && mask.content.y >= 0 && mask.content.width > 0 && mask.content.height > 0 &&
        mask.content.width <= mask.width && mask.content.height <= mask.height &&
        mask.content.x <= mask.width - mask.content.width && mask.content.y <= mask.height - mask.content.height &&
        mask.confidence.bytes.size() <= kMaxMaskBackingBytes &&
        valid_plane(mask.confidence.bytes, mask.confidence.stride, mask.width, mask.height);
}

ScratchRequirements blur_scratch_requirements(int width, int strength) {
    if (width <= 0 || width > kMaxFrameSide || strength < 0 || strength > 100) return {};
    return {static_cast<size_t>(width) * (2 * blur_radius(strength) + 1), static_cast<size_t>(width)};
}

Status compose(const I420View& source, const Options& options, const MaskView* mask,
        const StagedImageView* image, Scratch scratch, I420Output output) {
    if (!valid_pixels(output, kMaxFrameSide, kMaxFramePixels, kMaxFrameBackingBytes) ||
            !disjoint_buffers(source, mask, image, scratch, output)) return Status::InvalidBuffers;
    const bool background_selected = options.background != BackgroundMode::None;
    const uint32_t rgb = options.background == BackgroundMode::Solid && options.solid_rgb <= UINT32_C(0xffffff) ?
        options.solid_rgb : kNeutralConcealmentRgb;
    const auto color = solid_yuv(rgb, output.range, output.matrix);
    // Concealment is established before reading source/mask/image samples.
    // All subsequent failures retain this opaque output, never a raw bypass.
    if (background_selected) fill_solid(output, color);
    const Status failure = background_selected ? Status::Concealed : Status::InvalidBuffers;
    if (!valid_options(options) || !valid_rotation(options.rotation) || !valid_pixels(source, kMaxFrameSide, kMaxFramePixels, kMaxFrameBackingBytes) ||
            output.width != source.width || output.height != source.height ||
            output.range != source.range || output.matrix != source.matrix) return failure;
    if (!background_selected && options.roi.scale == 1) return Status::Passthrough;
    if (background_selected && (mask == nullptr || mask->rotation != options.rotation || !valid_mask(*mask, source.width, source.height))) return failure;
    if (options.background == BackgroundMode::Image && (image == nullptr || !valid_image(*image) ||
            image->pixels.range != source.range || image->pixels.matrix != source.matrix)) return failure;
    if (options.background == BackgroundMode::Blur) {
        const auto required = blur_scratch_requirements(source.width, options.blur_strength);
        if (scratch.rows.size() < required.row_samples || scratch.columns.size() < required.column_samples ||
                scratch.rows.size() > static_cast<size_t>(kMaxFrameSide) * (2 * kMaxBlurRadius + 1) ||
                scratch.columns.size() > kMaxFrameSide) return failure;
    }
    const Sampling sampling(source, options, background_selected ? mask : nullptr);
    const MaskView* selected_mask = background_selected ? mask : nullptr;
    const StagedImageView* selected_image = options.background == BackgroundMode::Image ? image : nullptr;
    const ImageSampling image_sampling(source,options,sampling,selected_image);
    if (sampling.swapped) {
        render_plane<true, false>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 0, color[0]);
        if (source.width % 2 == 0) render_plane<true, true, 2>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 1, color[1], color[2]);
        else {
            render_plane<true, true>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 1, color[1]);
            render_plane<true, true>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 2, color[2]);
        }
    } else {
        render_plane<false, false>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 0, color[0]);
        if (source.width % 2 == 0) render_plane<false, true, 2>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 1, color[1], color[2]);
        else {
            render_plane<false, true>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 1, color[1]);
            render_plane<false, true>(source, options, selected_mask, selected_image, scratch, output, sampling, image_sampling, 2, color[2]);
        }
    }
    return Status::Applied;
}

std::optional<PersonBounds> person_bounds(const MaskView& mask, uint8_t threshold) {
    if (!valid_mask(mask, mask.source_width, mask.source_height)) return std::nullopt;
    int left = mask.content.x + mask.content.width;
    int top = mask.content.y + mask.content.height;
    int right = mask.content.x;
    int bottom = mask.content.y;
    for (int y = mask.content.y; y < mask.content.y + mask.content.height; ++y) {
        for (int x = mask.content.x; x < mask.content.x + mask.content.width; ++x) {
            if (mask.confidence.bytes[y * mask.confidence.stride + x] < threshold) continue;
            left = std::min(left, x);
            top = std::min(top, y);
            right = std::max(right, x + 1);
            bottom = std::max(bottom, y + 1);
        }
    }
    if (left >= right || top >= bottom) return std::nullopt;
    const PersonBounds upright{static_cast<double>(left - mask.content.x) / mask.content.width,
        static_cast<double>(top - mask.content.y) / mask.content.height,
        static_cast<double>(right - mask.content.x) / mask.content.width,
        static_cast<double>(bottom - mask.content.y) / mask.content.height};
    if (mask.rotation == 0) return upright;
    PersonBounds raw{1, 1, 0, 0};
    for (double x : {upright.left, upright.right}) for (double y : {upright.top, upright.bottom}) {
        const auto point = raw_point(x, y, mask.rotation);
        raw.left = std::min(raw.left, point[0]); raw.top = std::min(raw.top, point[1]);
        raw.right = std::max(raw.right, point[0]); raw.bottom = std::max(raw.bottom, point[1]);
    }
    return raw;
}

Roi update_framing(FramingState* state, const std::optional<PersonBounds>& people, double elapsed_ms) {
    if (state == nullptr) return {};
    if (!valid_roi(state->roi)) state->roi = {};
    Roi target;
    std::optional<PersonBounds> expanded;
    if (people && valid_bounds(*people)) {
        const double room_x = (people->right - people->left) * 0.1;
        const double room_y = (people->bottom - people->top) * 0.1;
        expanded = PersonBounds{std::max(0.0, people->left - room_x), std::max(0.0, people->top - room_y),
            std::min(1.0, people->right + room_x), std::min(1.0, people->bottom + room_y)};
        target.scale = std::max({kMinFramingScale, expanded->right - expanded->left, expanded->bottom - expanded->top});
        target.center_x = std::clamp((expanded->left + expanded->right) / 2, target.scale / 2, 1 - target.scale / 2);
        target.center_y = std::clamp((expanded->top + expanded->bottom) / 2, target.scale / 2, 1 - target.scale / 2);
    }
    const double dt = std::isfinite(elapsed_ms) ? std::clamp(elapsed_ms, 0.0, 100.0) : 0;
    const double alpha = 1 - std::exp(-dt / 400);
    Roi result{state->roi.center_x + alpha * (target.center_x - state->roi.center_x),
        state->roi.center_y + alpha * (target.center_y - state->roi.center_y),
        state->roi.scale + alpha * (target.scale - state->roi.scale)};
    if (expanded) {
        // Immediate conservative expansion around the smoothed centre keeps
        // every detected person visible during movement and zoom transitions.
        result.scale = std::min(1.0, std::max({result.scale,
            2 * (result.center_x - expanded->left), 2 * (expanded->right - result.center_x),
            2 * (result.center_y - expanded->top), 2 * (expanded->bottom - result.center_y)}));
    }
    result.scale = std::clamp(result.scale, kMinFramingScale, 1.0);
    result.center_x = std::clamp(result.center_x, result.scale / 2, 1 - result.scale / 2);
    result.center_y = std::clamp(result.center_y, result.scale / 2, 1 - result.scale / 2);
    state->roi = result;
    return result;
}

}  // namespace dinox::video_compositor
