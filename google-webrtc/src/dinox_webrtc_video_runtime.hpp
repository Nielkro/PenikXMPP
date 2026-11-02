#ifndef DINOX_WEBRTC_VIDEO_RUNTIME_HPP
#define DINOX_WEBRTC_VIDEO_RUNTIME_HPP

#include <memory>
#include <atomic>
#include <mutex>
#include <vector>
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "dinox_webrtc.h"
#include "dinox_webrtc_video_compositor.hpp"
#include "dinox_webrtc_video_background_preparation.hpp"
#include "../vision/vision_client.hpp"

namespace dinox::webrtc_effects {

struct VisionPaths {
    vision::VisionClientOptions options;
    bool segmentation = false;
    bool face = false;
};
// Resolve only trusted sibling installation files. Explicit test paths require
// a separate test opt-in; image IDs and configuration never supply paths.
VisionPaths installed_vision_paths();
uint32_t vision_demand(const DinoXWebrtcVideoEffectConfig& config);
bool advanced_pixels(const DinoXWebrtcVideoEffectConfig& config);
vision::ContentRect video_letterbox(int width, int height, int target_w, int target_h);

struct FrameIdentity {
    uint64_t camera_lease = 0;
    vision::VisionBinding binding;
    vision::VisionFrame frame;
    uint64_t mask_capture_ns = 0;
    bool concealed = false;
    bool full_range = false, bt709 = false;
};

// One per logical pipeline. Control methods never wait for child I/O. Pixel
// workspace belongs only to the existing effect worker, not capture/MUJI peers.
class VideoRuntime final {
 public:
    explicit VideoRuntime(VisionPaths paths);
    ~VideoRuntime();
    bool segmentation_available() const { return paths_.segmentation; }
    bool face_available() const { return paths_.face; }
    void bind(const FrameIdentity& identity);
    void invalidate(bool camera_off = false);
    void close();
    video_background_images::UploadResult background_upload(video_background_images::Input input);
    video_background_images::UploadResult background_builtin(video_background_images::Builtin choice);
    video_background_images::Status background_prepare(uint32_t id);
    video_background_images::Status background_release(uint32_t id);
    bool background_contains(uint32_t id) const;
    void select_background(uint32_t id);
    uint64_t transport_owned_bytes() const;
    // nullptr means invalid geometry/conversion: drop. Concealment is prepared
    // before any private source pixels are used when a selected mask is absent.
    webrtc::scoped_refptr<webrtc::I420BufferInterface> prepare(
        const webrtc::VideoFrame& frame,
        const webrtc::scoped_refptr<webrtc::I420BufferInterface>& source,
        const DinoXWebrtcVideoEffectConfig& config,
        const FrameIdentity& identity);
    bool finish(webrtc::VideoFrame* output, webrtc::I420Buffer& pixels,
        const DinoXWebrtcVideoEffectConfig& config, const FrameIdentity& identity);
    uint64_t owned_bytes() const;
    uint64_t mask_capture_ns() const { return mask_capture_ns_; }
    bool concealed() const { return concealed_; }
    void release_workspace(); // effect worker only, after its last pixel access

 private:
    const VisionPaths paths_;
    std::shared_ptr<video_background_images::BackgroundImageRegistry> backgrounds_ =
        std::make_shared<video_background_images::BackgroundImageRegistry>();
    video_background_images::BackgroundPreparation background_preparation_{backgrounds_};
    std::mutex background_control_mutex_;
    mutable std::mutex control_mutex_;
    std::shared_ptr<vision::VisionClient> client_;
    bool closed_ = false;
    uint32_t active_background_id_ = 0, staged_background_id_ = 0;
    video_background_images::Lease active_background_, staged_background_;
    std::shared_ptr<const video_background_images::ImageSource> active_source_, staged_source_;
    video_compositor::Range current_range_ = video_compositor::Range::Limited;
    video_compositor::Matrix current_matrix_ = video_compositor::Matrix::Bt601;
    bool begin_background_stage();
    void refresh_workspace_bytes(); // worker only; publishes numeric ownership
    std::atomic<uint64_t> workspace_bytes_{0};
    std::optional<vision::VisionBinding> binding_;
    webrtc::scoped_refptr<webrtc::I420Buffer> workspace_;
    std::vector<uint16_t> blur_rows_;
    std::vector<uint32_t> blur_columns_;
    std::vector<uint8_t> sample_segment_, sample_face_;
    std::vector<uint8_t> touch_rows_;
    video_compositor::FramingState framing_;
    uint64_t framing_source_ = 0, framing_transform_ = 0, framing_capture_ns_ = 0;
    uint64_t mask_capture_ns_ = 0;
    bool concealed_ = false;
};

} // namespace dinox::webrtc_effects
#endif
