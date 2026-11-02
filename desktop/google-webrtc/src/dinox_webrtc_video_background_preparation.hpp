#ifndef DINOX_WEBRTC_VIDEO_BACKGROUND_PREPARATION_HPP
#define DINOX_WEBRTC_VIDEO_BACKGROUND_PREPARATION_HPP
#include "dinox_webrtc_video_background_images.hpp"
#include <memory>

namespace dinox::video_background_images {
// Model/camera-free controller for format misses. One conversion plus one
// replaceable latest ticket, no RGB copies/FIFO. Destruction never waits on UI.
class BackgroundPreparation final {
 public:
    explicit BackgroundPreparation(std::shared_ptr<BackgroundImageRegistry> registry);
    ~BackgroundPreparation();
    void request(uint32_t id, video_compositor::Range range, video_compositor::Matrix matrix);
    void close();
 private:
    struct State;
    std::shared_ptr<State> state_;
};
}
#endif
