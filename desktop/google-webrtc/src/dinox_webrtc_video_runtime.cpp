#include "dinox_webrtc_video_runtime.hpp"
#include "dinox_webrtc_video_overlays.hpp"
#include "dinox_webrtc_video_effect_config.hpp"
#include "dinox_webrtc_video_vision_geometry.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <string>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

namespace dinox::webrtc_effects {
namespace {
namespace vc = video_compositor;
namespace vo = video_overlays;

int rounded(int value, int divisor) {
    return value >= 0 ? (value + divisor / 2) / divisor :
        -((-value + divisor / 2) / divisor);
}
uint8_t byte(int value) { return static_cast<uint8_t>(std::clamp(value, 0, 255)); }
bool full(const webrtc::VideoFrame& frame) {
    return frame.color_space() &&
        frame.color_space()->range() == webrtc::ColorSpace::RangeID::kFull;
}
bool bt709(const webrtc::VideoFrame& frame) {
    return frame.color_space() &&
        frame.color_space()->matrix() == webrtc::ColorSpace::MatrixID::kBT709;
}
bool dimensions(int width, int height) {
    return width > 0 && height > 0 && width <= vc::kMaxFrameSide &&
        height <= vc::kMaxFrameSide &&
        static_cast<uint64_t>(width) * height <= vc::kMaxFramePixels;
}

// WebRTC's I420 interface owns stride*height readable/writable bytes per
// plane. Validate dimensions/strides and the bounded total before constructing
// borrowed spans at this one external pointer/extent boundary.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#endif
vc::I420View view(const webrtc::I420BufferInterface& pixels,
                 const webrtc::VideoFrame& frame) {
    vc::I420View result;
    const int w = pixels.width(), h = pixels.height();
    if (!dimensions(w, h)) return result;
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    if (pixels.StrideY() < w || pixels.StrideU() < cw ||
            pixels.StrideV() < cw) return result;
    const uint64_t sy = static_cast<uint64_t>(pixels.StrideY()) * h;
    const uint64_t su = static_cast<uint64_t>(pixels.StrideU()) * ch;
    const uint64_t sv = static_cast<uint64_t>(pixels.StrideV()) * ch;
    if (sy + su + sv > vc::kMaxFrameBackingBytes || !pixels.DataY() ||
            !pixels.DataU() || !pixels.DataV()) return result;
    result = {w, h, full(frame) ? vc::Range::Full : vc::Range::Limited,
        bt709(frame) ? vc::Matrix::Bt709 : vc::Matrix::Bt601,
        {{pixels.DataY(), static_cast<size_t>(sy)}, pixels.StrideY()},
        {{pixels.DataU(), static_cast<size_t>(su)}, pixels.StrideU()},
        {{pixels.DataV(), static_cast<size_t>(sv)}, pixels.StrideV()}};
    return result;
}
vc::I420Output writable(webrtc::I420Buffer& pixels, const webrtc::VideoFrame& frame) {
    const auto source = view(pixels, frame);
    if (source.width == 0) return {};
    return {source.width, source.height, source.range, source.matrix,
        {{pixels.MutableDataY(), source.y.bytes.size()}, source.y.stride},
        {{pixels.MutableDataU(), source.u.bytes.size()}, source.u.stride},
        {{pixels.MutableDataV(), source.v.bytes.size()}, source.v.stride}};
}
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

vision::ContentRect letterbox(int width, int height, int target_w, int target_h) {
    const auto rect=video_vision_geometry::letterbox(width,height,target_w,target_h);
    return {uint32_t(rect.x),uint32_t(rect.y),uint32_t(rect.width),uint32_t(rect.height)};
}

bool rgb_sample(const vc::I420View& source, vision::ContentRect rect, int rotation,
                int width, int height, std::vector<uint8_t>* destination) {
    destination->resize(static_cast<size_t>(width) * height * 3);
    return video_vision_geometry::preprocess_rgb(source,rotation,width,height,
        {int(rect.x),int(rect.y),int(rect.width),int(rect.height)},*destination);
}

vo::Options overlay_options(const DinoXWebrtcVideoEffectConfig& config, bool scene) {
    vo::Options options;
    if (scene) { options.scene = static_cast<vo::Scene>(config.scene_effect); return options; }
    options.glasses = static_cast<vo::Glasses>(config.glasses_style);
    options.hat = static_cast<vo::Hat>(config.hat_style);
    options.beard = static_cast<vo::Beard>(config.beard_style);
    options.accessory = static_cast<vo::Accessory>(config.face_accessory);
    options.touch_up = config.touch_up != 0;
    options.low_light = config.low_light != 0;
    return options;
}

vo::Face projected_face(const vision::VisionResult& result, vc::Roi roi) {
    vo::Face face;
    if (!result.face) return face;
    const auto& f = *result.face;
    const auto& rect = result.frame.face_content;
    if (!rect.width || !rect.height) return face;
    const auto point = [&](double x, double y) -> vo::Point {
        const auto raw=video_vision_geometry::detector_to_raw({x,y},
            {int(rect.x),int(rect.y),int(rect.width),int(rect.height)},int(result.frame.rotation),roi);
        return {raw.x,raw.y};
    };
    face.bounds={std::numeric_limits<double>::infinity(),std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),-std::numeric_limits<double>::infinity()};
    for(const auto corner:std::array<vo::Point,4>{point(f.left,f.top),point(f.right,f.top),
            point(f.left,f.bottom),point(f.right,f.bottom)}) {
        face.bounds.left=std::min(face.bounds.left,corner.x);face.bounds.top=std::min(face.bounds.top,corner.y);
        face.bounds.right=std::max(face.bounds.right,corner.x);face.bounds.bottom=std::max(face.bounds.bottom,corner.y);
    }
    face.score = f.score;
    for (size_t i = 0; i < face.points.size(); ++i)
        face.points[i] = point(f.points[i].x, f.points[i].y);
    face.captured_ns = result.frame.captured_monotonic_ns;
    face.valid = true;
    return face;
}

// Convert premultiplied RGB to an alpha-weighted YUV contribution. Averaging
// the actual 2x2 samples retains odd edges and independent padded U/V strides.
void overlay(vc::I420Output target, const vo::Prepared& prepared) {
    const auto& options = prepared.options;
    if (!prepared.active || (prepared.particle_count == 0 &&
            (!prepared.face_usable || (options.glasses == vo::Glasses::None &&
                options.hat == vo::Hat::None && options.beard == vo::Beard::None &&
                options.accessory == vo::Accessory::None)))) return;
    const double kr = target.matrix == vc::Matrix::Bt709 ? 0.2126 : 0.299;
    const double kb = target.matrix == vc::Matrix::Bt709 ? 0.0722 : 0.114;
    const double kg = 1 - kr - kb;
    const bool limited = target.range == vc::Range::Limited;
    for (int y = 0; y < target.height; y += 2) {
        const std::array<vo::Row,2> candidates={vo::prepare_row(prepared,y),vo::prepare_row(prepared,y+1)};
        int begin=target.width,end=0;
        for (const auto& row:candidates) if (row.valid && row.end>row.begin) {
            begin=std::min(begin,row.begin);end=std::max(end,row.end);
        }
        // Preserve the original real 2x2 blocks and odd edges. Blocks with no
        // procedural/face contribution leave the already processed pixels.
        begin-=begin%2;
        for (int x = begin; x < end; x += 2) {
            double u = 0, v = 0; int alpha = 0, count = 0;
            for (int dy = 0; dy < 2 && y + dy < target.height; ++dy) {
                for (int dx = 0; dx < 2 && x + dx < target.width; ++dx) {
                    const auto p = vo::rgba_row_pixel(prepared, candidates[dy], x + dx);
                    ++count;
                    if (p.a == 0) continue; // premultiplied RGB is also zero
                    const double luma = kr * p.r + kg * p.g + kb * p.b;
                    const int contribution = static_cast<int>(std::lround(
                        limited ? luma * 219 / 255 + 16.0 * p.a / 255 : luma));
                    const size_t index = static_cast<size_t>(y + dy) * target.y.stride + x + dx;
                    target.y.bytes[index] = byte(contribution +
                        (target.y.bytes[index] * (255 - p.a) + 127) / 255);
                    const double scale = limited ? 224.0 / 255 : 1;
                    u += (p.b - luma) / (2 * (1 - kb)) * scale;
                    v += (p.r - luma) / (2 * (1 - kr)) * scale;
                    alpha += p.a;
                }
            }
            if (alpha == 0) continue;
            const int a = rounded(alpha, count);
            const size_t ui = static_cast<size_t>(y / 2) * target.u.stride + x / 2;
            const size_t vi = static_cast<size_t>(y / 2) * target.v.stride + x / 2;
            target.u.bytes[ui] = byte(static_cast<int>(std::lround(u / count)) +
                rounded(128 * a + target.u.bytes[ui] * (255 - a), 255));
            target.v.bytes[vi] = byte(static_cast<int>(std::lround(v / count)) +
                rounded(128 * a + target.v.bytes[vi] * (255 - a), 255));
        }
    }
}

std::string path_utf8(const std::filesystem::path& path) {
    const auto value = path.u8string();
    return std::string(value.begin(), value.end());
}
std::filesystem::path path_from_utf8(const std::string& value) {
    return std::filesystem::path(std::u8string(value.begin(), value.end()));
}
bool file(const std::filesystem::path& path, bool executable = false) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(path, error) || error) return false;
#if !defined(_WIN32)
    if (executable && access(path.c_str(), X_OK) != 0) return false;
#else
    (void)executable;
#endif
    return true;
}
} // namespace

VisionPaths installed_vision_paths() {
    std::filesystem::path directory;
#if defined(_WIN32)
    HMODULE module = nullptr;
    std::array<wchar_t, 32768> path{};
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&installed_vision_paths), &module)) {
        const DWORD size = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
        if (size && size < path.size()) directory = std::filesystem::path(path.data()).parent_path();
    }
    const auto worker_name = "dinox-vision-worker.exe";
#else
    Dl_info info{};
    if (dladdr(reinterpret_cast<void*>(&installed_vision_paths), &info) && info.dli_fname)
        directory = std::filesystem::path(info.dli_fname).parent_path();
    const auto worker_name = "dinox-vision-worker";
#endif
    VisionPaths paths;
    if (directory.empty()) return paths;
    auto worker = directory / worker_name;
    auto segment = directory / "dinox-vision-models" / "selfie_segmenter_landscape-v1.tflite";
    auto face = directory / "dinox-vision-models" / "blaze_face_short_range-v1.tflite";
    const char* test = std::getenv("DINOX_WEBRTC_VISION_TEST_PATHS");
    if (test && std::string(test) == "1") {
        const char* w = std::getenv("DINOX_WEBRTC_VISION_TEST_WORKER");
        const char* s = std::getenv("DINOX_WEBRTC_VISION_TEST_SEGMENT_MODEL");
        const char* f = std::getenv("DINOX_WEBRTC_VISION_TEST_FACE_MODEL");
        if (!w || !s || !f) return paths;
        worker = path_from_utf8(w); segment = path_from_utf8(s);
        face = path_from_utf8(f);
    }
    paths.options.worker_executable = path_utf8(worker);
    paths.options.segmentation_model = path_utf8(segment);
    paths.options.face_model = path_utf8(face);
    paths.segmentation = file(worker, true) && file(segment);
    paths.face = file(worker, true) && file(face);
    return paths;
}

uint32_t vision_demand(const DinoXWebrtcVideoEffectConfig& config) {
    return ((config.background_mode != DINOX_WEBRTC_VIDEO_BACKGROUND_NONE ||
        config.framing_mode != DINOX_WEBRTC_VIDEO_FRAMING_NONE) ? vision::kSegmentDemand : 0) |
        ((config.glasses_style || config.hat_style || config.beard_style ||
        config.face_accessory || config.touch_up) ? vision::kFaceDemand : 0);
}
bool advanced_pixels(const DinoXWebrtcVideoEffectConfig& config) {
    return vision_demand(config) != 0 || config.low_light != 0;
}
VideoRuntime::VideoRuntime(VisionPaths paths) : paths_(std::move(paths)) {}
VideoRuntime::~VideoRuntime() { close(); }
void VideoRuntime::bind(const FrameIdentity& identity) {
    video_background_images::Lease retired;
    std::lock_guard<std::mutex> lock(control_mutex_);
    if (closed_) return;
    current_range_ = identity.full_range ? vc::Range::Full : vc::Range::Limited;
    current_matrix_ = identity.bt709 ? vc::Matrix::Bt709 : vc::Matrix::Bt601;
    if(active_background_id_){
        if(active_background_&&(active_background_->range()!=current_range_||
                active_background_->matrix()!=current_matrix_))retired=std::move(active_background_);
        // A staged B must survive A's source-format transition. Release only
        // A's old I420 owners, keeping its RGB source/ID and all live readers.
        backgrounds_->retire_other_format(active_background_id_,current_range_,current_matrix_);
    }
    const bool demand = identity.binding.demand != 0;
    if (demand && !client_) client_ = vision::VisionClient::create(paths_.options);
    binding_ = demand ? std::optional(identity.binding) : std::nullopt;
    if (client_) client_->set_binding(binding_);
}
void VideoRuntime::invalidate(bool camera_off) {
    std::lock_guard<std::mutex> lock(control_mutex_);
    binding_.reset();
    if(camera_off){current_range_=vc::Range::Limited;current_matrix_=vc::Matrix::Bt601;}
    if (client_) client_->set_binding(std::nullopt, !camera_off);
}
void VideoRuntime::close() {
    std::lock_guard<std::mutex> lock(control_mutex_);
    closed_ = true; binding_.reset();
    if (client_) client_->close();
    active_background_.reset();staged_background_.reset();
    active_source_.reset();staged_source_.reset();
    active_background_id_=staged_background_id_=0;
    background_preparation_.close();
}

bool VideoRuntime::begin_background_stage() {
    uint32_t unused=0;
    video_background_images::Lease old_asset;
    std::shared_ptr<const video_background_images::ImageSource> old_source;
    {
        std::lock_guard lock(control_mutex_);
        if(closed_)return false;
        if(staged_background_id_!=active_background_id_)unused=staged_background_id_;
        staged_background_id_=0;old_asset=std::move(staged_background_);old_source=std::move(staged_source_);
    }
    if(unused)backgrounds_->discard(unused);
    old_asset.reset();old_source.reset();
    return true;
}
video_background_images::UploadResult VideoRuntime::background_upload(video_background_images::Input input) {
    std::lock_guard serialized(background_control_mutex_);
    if(!begin_background_stage())return {};
    auto result=backgrounds_->upload(input);
    std::lock_guard lock(control_mutex_);
    if(closed_){if(result.id)backgrounds_->discard(result.id);return {};}
    if(result.status==video_background_images::Status::Ok){staged_background_id_=result.id;
        staged_source_=backgrounds_->retain_source(result.id);}
    return result;
}
video_background_images::UploadResult VideoRuntime::background_builtin(video_background_images::Builtin choice) {
    std::lock_guard serialized(background_control_mutex_);
    if(!begin_background_stage())return {};
    auto result=backgrounds_->create_builtin(choice);
    std::lock_guard lock(control_mutex_);
    if(closed_){if(result.id)backgrounds_->discard(result.id);return {};}
    if(result.status==video_background_images::Status::Ok){staged_background_id_=result.id;
        staged_source_=backgrounds_->retain_source(result.id);}
    return result;
}
video_background_images::Status VideoRuntime::background_prepare(uint32_t id) {
    std::lock_guard serialized(background_control_mutex_);
    vc::Range range;vc::Matrix matrix;
    {std::lock_guard lock(control_mutex_);if(closed_)return video_background_images::Status::Unavailable;
        range=current_range_;matrix=current_matrix_;}
    auto result=backgrounds_->prepare(id,range,matrix);
    std::lock_guard lock(control_mutex_);
    if(closed_)return video_background_images::Status::Unavailable;
    if(result.status==video_background_images::Status::Ok){
        if(active_background_id_==id){active_background_=result.lease;
            if(staged_background_id_==id){staged_background_id_=0;staged_background_.reset();staged_source_.reset();}}
        else {staged_background_id_=id;staged_background_=result.lease;}
    }
    return result.status;
}
video_background_images::Status VideoRuntime::background_release(uint32_t id) {
    std::lock_guard serialized(background_control_mutex_);
    // Retire lookup while the owner lease still proves the ID is live. Dropping
    // the last staged/active reader first could turn a successful release into
    // a spurious Unavailable when current_asset belongs to another selection.
    const auto status=backgrounds_->discard(id);
    {std::lock_guard lock(control_mutex_);
        if(staged_background_id_==id){staged_background_id_=0;staged_background_.reset();staged_source_.reset();}
        if(active_background_id_==id){active_background_.reset();active_source_.reset();}}
    return status;
}
bool VideoRuntime::background_contains(uint32_t id) const {return backgrounds_->contains(id);}
void VideoRuntime::select_background(uint32_t id) {
    std::lock_guard lock(control_mutex_);
    active_background_id_=id;
    if(staged_background_id_==id){active_background_=std::move(staged_background_);
        active_source_=std::move(staged_source_);staged_background_id_=0;}
    else if(!active_background_||active_background_->id()!=id){active_background_.reset();active_source_.reset();}
}

webrtc::scoped_refptr<webrtc::I420BufferInterface> VideoRuntime::prepare(
    const webrtc::VideoFrame& frame,
    const webrtc::scoped_refptr<webrtc::I420BufferInterface>& source,
    const DinoXWebrtcVideoEffectConfig& config, const FrameIdentity& identity) {
    if (!source) return nullptr;
    const auto source_view = view(*source, frame);
    if (source_view.width == 0) return nullptr;
    if (identity.frame.width != 0 &&
            (identity.frame.width != static_cast<uint32_t>(source_view.width) ||
                identity.frame.height != static_cast<uint32_t>(source_view.height))) return nullptr;
    std::shared_ptr<vision::VisionClient> client;
    {
        std::lock_guard<std::mutex> lock(control_mutex_);
        if (closed_) return nullptr;
        if (binding_ == identity.binding) client = client_;
    }
    std::shared_ptr<const vision::VisionResult> result;
    const uint64_t now = vision::VisionClient::monotonic_now_ns();
    if (client) {
        if (auto ticket = client->reserve_sample(identity.frame, now)) {
            bool sampled=true;
            if (identity.binding.demand & vision::kSegmentDemand)
                sampled=rgb_sample(source_view, identity.frame.segment_content,int(identity.frame.rotation),256,144,&sample_segment_);
            else sample_segment_.clear();
            if (identity.binding.demand & vision::kFaceDemand)
                sampled=rgb_sample(source_view, identity.frame.face_content,int(identity.frame.rotation),128,128,&sample_face_)&&sampled;
            else sample_face_.clear();
            refresh_workspace_bytes();
            if (!sampled || !client->submit(*ticket, sample_segment_, sample_face_,
                    vision::VisionClient::monotonic_now_ns())) client->abandon(*ticket);
        }
        result = client->result_for(identity.binding, identity.frame,
            vision::VisionClient::monotonic_now_ns());
    }
    if (!workspace_ || workspace_->width() != source->width() || workspace_->height() != source->height()) {
        release_workspace();
        workspace_ = webrtc::I420Buffer::Create(source->width(), source->height());
        refresh_workspace_bytes();
    }
    if (!workspace_) return nullptr;
    vc::MaskView mask;
    if (result && result->mask.size() == 256 * 144) {
        const auto rect = result->frame.segment_content;
        mask = {{result->mask, 256}, 256, 144, source->width(), source->height(),
            {static_cast<int>(rect.x), static_cast<int>(rect.y),
                static_cast<int>(rect.width), static_cast<int>(rect.height)}, true};
        mask.rotation=int(identity.frame.rotation);
    }
    vc::Options options;
    options.background = static_cast<vc::BackgroundMode>(config.background_mode);
    options.blur_strength = config.background_strength;
    options.solid_rgb = config.background_color_rgb;
    options.rotation=int(identity.frame.rotation);
    if (framing_source_ != identity.binding.source_generation ||
            framing_transform_ != identity.binding.transform_id) {
        framing_ = {}; framing_capture_ns_ = 0;
        framing_source_ = identity.binding.source_generation;
        framing_transform_ = identity.binding.transform_id;
    }
    if (config.framing_mode == DINOX_WEBRTC_VIDEO_FRAMING_AUTO) {
        const double dt = identity.frame.captured_monotonic_ns >= framing_capture_ns_ ?
            (identity.frame.captured_monotonic_ns - framing_capture_ns_) / 1000000.0 : 0;
        options.roi = vc::update_framing(&framing_, vc::person_bounds(mask), dt);
        framing_capture_ns_ = identity.frame.captured_monotonic_ns;
    } else { framing_ = {}; framing_capture_ns_ = 0; }
    if (options.background == vc::BackgroundMode::Blur && mask.valid) {
        const auto required = vc::blur_scratch_requirements(source->width(), options.blur_strength);
        blur_rows_.resize(required.row_samples); blur_columns_.resize(required.column_samples);
    } else { std::vector<uint16_t>().swap(blur_rows_); std::vector<uint32_t>().swap(blur_columns_); }
    refresh_workspace_bytes();
    auto output = writable(*workspace_, frame);
    video_background_images::Lease image;
    vc::StagedImageView staged_image;
    if(options.background==vc::BackgroundMode::Image){
        image=backgrounds_->acquire(config.asset_id,source_view.range,source_view.matrix);
        if(image){
            staged_image=image->view();
            std::lock_guard lock(control_mutex_);
            if(active_background_id_==config.asset_id)active_background_=image;
        }else background_preparation_.request(config.asset_id,source_view.range,source_view.matrix);
    }
    const auto status = vc::compose(source_view, options, &mask, image ? &staged_image : nullptr,
        {blur_rows_, blur_columns_}, output);
    if (status == vc::Status::InvalidBuffers) return nullptr;
    if (status == vc::Status::Passthrough) {
        for (int y = 0; y < source->height(); ++y)
            std::copy_n(source_view.y.bytes.begin() + static_cast<size_t>(y) * source_view.y.stride,
                source->width(), output.y.bytes.begin() + static_cast<size_t>(y) * output.y.stride);
        for (int y = 0; y < (source->height() + 1) / 2; ++y) {
            std::copy_n(source_view.u.bytes.begin() + static_cast<size_t>(y) * source_view.u.stride,
                (source->width() + 1) / 2, output.u.bytes.begin() + static_cast<size_t>(y) * output.u.stride);
            std::copy_n(source_view.v.bytes.begin() + static_cast<size_t>(y) * source_view.v.stride,
                (source->width() + 1) / 2, output.v.bytes.begin() + static_cast<size_t>(y) * output.v.stride);
        }
    }
    // Concealed images may still receive original art, but never source-derived
    // smoothing/gain or tracked props. In particular no raw blur can leak.
    const bool concealed = status == vc::Status::Concealed;
    concealed_ = concealed;
    mask_capture_ns_ = mask.valid && result ? result->frame.captured_monotonic_ns : 0;
    auto face = result && !concealed ? projected_face(*result, options.roi) : vo::Face{};
    auto overlay_config = overlay_options(config, false);
    if (concealed) { overlay_config.touch_up = false; overlay_config.low_light = false; }
    vo::LumaStats stats;
    if (overlay_config.low_light) {
        uint64_t sum = 0;
        const int step_x = std::max(1, (source->width() + 63) / 64);
        const int step_y = std::max(1, (source->height() + 63) / 64);
        for (int y = 0; y < source->height(); y += step_y)
            for (int x = 0; x < source->width(); x += step_x) {
                const int value = output.y.bytes[static_cast<size_t>(y) * output.y.stride + x];
                sum += full(frame) ? value : std::clamp(rounded((value - 16) * 255, 219), 0, 255);
                ++stats.sample_count;
            }
        stats.mean_full_range = static_cast<uint32_t>((sum + stats.sample_count / 2) / stats.sample_count);
    }
    const vo::Frame overlay_frame{source->width(), source->height(), identity.frame.frame_id,
        identity.frame.captured_monotonic_ns, now, int(identity.frame.rotation)};
    const auto context = vo::prepare(overlay_config, overlay_frame, &face, stats);
    if (context.options.touch_up && context.face_usable) {
        // Radius-one smoothing reads an immutable original three-row ring,
        // avoiding both full-frame RGB storage and in-place neighbour feedback.
        touch_rows_.resize(static_cast<size_t>(source->width()) * 3);
        refresh_workspace_bytes();
        const auto read_row = [&](int y) {
            std::copy_n(output.y.bytes.begin() + static_cast<size_t>(y) * output.y.stride,
                source->width(), touch_rows_.begin() + static_cast<size_t>(y % 3) * source->width());
        };
        read_row(0);
        for (int y = 0; y < source->height(); ++y) {
            if (y + 1 < source->height()) read_row(y + 1);
            for (int x = 0; x < source->width(); ++x) {
                const int weight = vo::touch_up_weight(context, x, y);
                if (!weight) continue;
                int sum = 0;
                for (int dy = -1; dy <= 1; ++dy)
                    for (int dx = -1; dx <= 1; ++dx)
                        sum += touch_rows_[static_cast<size_t>(std::clamp(y + dy, 0, source->height() - 1) % 3) *
                            source->width() + std::clamp(x + dx, 0, source->width() - 1)];
                const size_t index = static_cast<size_t>(y) * output.y.stride + x;
                output.y.bytes[index] = byte(rounded(output.y.bytes[index] * (255 - weight) +
                    rounded(sum, 9) * weight, 255));
            }
        }
    } else { std::vector<uint8_t>().swap(touch_rows_); refresh_workspace_bytes(); }
    if (context.low_light_gain_q8 != 256)
        for (int y = 0; y < source->height(); ++y)
            for (int x = 0; x < source->width(); ++x) {
                const size_t i = static_cast<size_t>(y) * output.y.stride + x;
                output.y.bytes[i] = vo::low_light_luma(context, output.y.bytes[i],
                    full(frame) ? vo::LumaRange::Full : vo::LumaRange::Limited);
            }
    overlay(output, context);
    return workspace_;
}

bool VideoRuntime::finish(webrtc::VideoFrame* output, webrtc::I420Buffer& pixels,
    const DinoXWebrtcVideoEffectConfig& config, const FrameIdentity& identity) {
    if (!output || !config.scene_effect) return output != nullptr;
    if (!dimensions(pixels.width(), pixels.height()) ||
            output->video_frame_buffer().get() != &pixels) return false;
    const auto context = vo::prepare(overlay_options(config, true),
        {pixels.width(), pixels.height(), identity.frame.frame_id,
            identity.frame.captured_monotonic_ns, vision::VisionClient::monotonic_now_ns(),
            int(identity.frame.rotation)});
    auto writable_view = writable(pixels, *output);
    if (writable_view.width == 0) return false;
    overlay(writable_view, context);
    return true;
}

void VideoRuntime::refresh_workspace_bytes() {
    uint64_t bytes = blur_rows_.capacity() * sizeof(uint16_t) +
        blur_columns_.capacity() * sizeof(uint32_t) +
        sample_segment_.capacity() + sample_face_.capacity() + touch_rows_.capacity();
    if (workspace_) bytes += static_cast<uint64_t>(workspace_->StrideY()) * workspace_->height() +
        static_cast<uint64_t>(workspace_->StrideU() + workspace_->StrideV()) * ((workspace_->height() + 1) / 2);
    workspace_bytes_.store(bytes,std::memory_order_release);
}
uint64_t VideoRuntime::owned_bytes() const {
    return workspace_bytes_.load(std::memory_order_acquire)+transport_owned_bytes();
}
uint64_t VideoRuntime::transport_owned_bytes() const {
    std::lock_guard lock(control_mutex_);
    uint64_t bytes=backgrounds_->owned_pixel_bytes();
    if(client_){const auto snapshot=client_->snapshot();bytes+=snapshot.owned_rgb_bytes+snapshot.cached_mask_bytes;}
    return bytes;
}
void VideoRuntime::release_workspace() {
    workspace_ = nullptr;
    std::vector<uint16_t>().swap(blur_rows_); std::vector<uint32_t>().swap(blur_columns_);
    std::vector<uint8_t>().swap(sample_segment_); std::vector<uint8_t>().swap(sample_face_);
    std::vector<uint8_t>().swap(touch_rows_);
    framing_ = {}; framing_source_ = framing_transform_ = framing_capture_ns_ = 0;
    mask_capture_ns_ = 0; concealed_ = false;
    refresh_workspace_bytes();
}

// Geometry preparation is cheap and happens before RGB conversion admission.
vision::ContentRect video_letterbox(int width, int height, int target_w, int target_h) {
    return letterbox(width, height, target_w, target_h);
}
} // namespace dinox::webrtc_effects
