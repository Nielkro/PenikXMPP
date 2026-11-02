#ifndef DINOX_VISION_INFERENCE_HPP
#define DINOX_VISION_INFERENCE_HPP

// This runtime belongs exclusively to the isolated vision process/service.
// It must never be invoked synchronously by audio, signalling or capture.
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>
#include "face_decoder.hpp"

namespace dinox::vision {
enum class ModelTask { Segmentation, Face };
class ModelRuntime final {
 public:
    static std::unique_ptr<ModelRuntime> create(ModelTask task, const std::string& path);
    // Android supplies a bounded APK asset. Ownership moves into this isolated
    // model instance; exact length, SHA and schema are validated identically.
    static std::unique_ptr<ModelRuntime> create_from_bytes(ModelTask task,
        std::vector<uint8_t> model_bytes);
    ~ModelRuntime();
    ModelRuntime(const ModelRuntime&) = delete;
    ModelRuntime& operator=(const ModelRuntime&) = delete;
    bool segment(std::span<const uint8_t> rgb, std::span<uint8_t> mask);
    // true with no face is a valid tracking loss; false is a model failure.
    bool face(std::span<const uint8_t> rgb, const Face* previous,
        std::optional<Face>* output);
 private:
    struct Impl;
    explicit ModelRuntime(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};
} // namespace dinox::vision
#endif
