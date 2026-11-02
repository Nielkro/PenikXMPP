// Copyright 2026 DinoX contributors.
// SPDX-License-Identifier: Apache-2.0
#ifndef DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGES_HPP
#define DINOX_WEBRTC_VIDEO_BACKGROUND_IMAGES_HPP

#include "dinox_webrtc_video_compositor.hpp"
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <vector>

namespace dinox::video_background_images {
constexpr size_t kMaxSources=2,kMaxVariants=2;
constexpr int kMaxSide=1920;
constexpr uint64_t kMaxPixels=UINT64_C(2073600);
constexpr size_t kMaxInputBytes=8*1024*1024;
constexpr size_t kMaxRgbBytes=6220800;
// ceil(width/2)*ceil(height/2) includes real odd-edge samples. The even
// full-HD value is3110400; this conservative bound also covers odd dimensions.
constexpr size_t kMaxI420Bytes=3112321;
enum class PixelFormat { Rgb888, Rgba8888 }; // RGBA is straight, matted to opaque303030
enum class Builtin : uint32_t { None,LivingRoom,Office,Cafe,Stones,Food,Abstract,Beach,Sunset,Celebration,Forest };
enum class Status { Ok,InvalidInput,Unavailable,NoMemory,IdExhausted,GenerationExhausted };
struct Input {
    int width=0,height=0;
    size_t stride=0;
    PixelFormat format=PixelFormat::Rgb888;
    std::span<const uint8_t> bytes;
};
struct UploadResult { Status status=Status::Unavailable;uint32_t id=0; };

// Default allocator is process-wide; tests can inject a separate last-ID counter.
// A consumed ID is never returned again, even if staging fails or reset occurs.
class IdAllocator {
 public:
    explicit IdAllocator(uint64_t first=1) noexcept;
    std::optional<uint32_t> reserve() noexcept;
 private:
    std::atomic<uint64_t> next_;
};
IdAllocator& process_id_allocator() noexcept;

struct ImageSource;
class BackgroundImageRegistry;
class Asset final {
 public:
    uint32_t id() const noexcept;
    uint64_t generation() const noexcept;
    int width() const noexcept;
    int height() const noexcept;
    video_compositor::Range range() const noexcept;
    video_compositor::Matrix matrix() const noexcept;
    std::span<const uint8_t> rgb() const noexcept;
    video_compositor::StagedImageView view() const noexcept;
 private:
    friend class BackgroundImageRegistry;
    Asset(std::shared_ptr<const ImageSource> source,video_compositor::Range range,
        video_compositor::Matrix matrix,std::vector<uint8_t> pixels);
    std::shared_ptr<const ImageSource> source_;
    video_compositor::Range range_;
    video_compositor::Matrix matrix_;
    std::vector<uint8_t> pixels_;
};
using Lease=std::shared_ptr<const Asset>;
struct PrepareResult { Status status=Status::Unavailable;Lease lease; };

class BackgroundImageRegistry final {
 public:
    explicit BackgroundImageRegistry(IdAllocator& ids=process_id_allocator()) noexcept;
    BackgroundImageRegistry(const BackgroundImageRegistry&)=delete;
    BackgroundImageRegistry& operator=(const BackgroundImageRegistry&)=delete;
    // Control/preparation lane only. Reservations are short and generation-bound;
    // copying/rendering/conversion takes place outside the registry lock.
    UploadResult upload(Input input);
    UploadResult create_builtin(Builtin choice);
    PrepareResult prepare(uint32_t id,video_compositor::Range range,video_compositor::Matrix matrix);
    // No pixel allocation, conversion or file/model access. A returned immutable
    // lease keeps its StagedImageView valid through reset/replacement/destruction.
    Lease acquire(uint32_t id,video_compositor::Range range,video_compositor::Matrix matrix) const;
    bool contains(uint32_t id) const;
    std::shared_ptr<const ImageSource> retain_source(uint32_t id) const;
    size_t owned_pixel_bytes() const;
    // Release only the registry's obsolete format owner. Source/ID, another
    // staged image and reader-held variants remain intact and count toward2.
    void retire_other_format(uint32_t id,video_compositor::Range range,
        video_compositor::Matrix matrix);
    // Retire a staged/cancelled choice without clearing unrelated active pixels.
    // Existing reader leases remain valid; new lookup/prepare of this ID fails.
    Status discard(uint32_t id);
    Status reset();
    uint64_t generation() const;
    size_t retained_sources() const;
    size_t retained_variants() const;
 private:
    struct SourceSlot { std::weak_ptr<const ImageSource> source;uint32_t reserved_id=0;bool registered=false; };
    struct VariantSlot {
        std::weak_ptr<const Asset> asset;
        uint32_t reserved_id=0;
        uint64_t reserved_generation=0;
        int reserved_format=-1;
    };
    struct Reservation { size_t slot=0;uint32_t id=0;uint64_t generation=0; };
    std::optional<Reservation> reserve_source_locked(Status& status);
    UploadResult stage(Input input,Builtin choice);
    bool aliases_locked(std::span<const uint8_t> bytes) const;
    std::shared_ptr<const ImageSource> source_locked(uint32_t id) const;
    Lease lease_locked(uint32_t id,video_compositor::Range range,video_compositor::Matrix matrix) const;
    IdAllocator& ids_;
    mutable std::mutex mutex_;
    uint64_t generation_=1;
    bool exhausted_=false;
    std::array<SourceSlot,kMaxSources> sources_{};
    std::array<VariantSlot,kMaxVariants> variants_{};
    std::shared_ptr<const ImageSource> current_source_;
    Lease current_asset_;
};
} // namespace dinox::video_background_images
#endif
